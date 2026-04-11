/// instance.zig - WebAssembly Instance
///
/// Instance is a runtime instantiation of a Module, containing the mutable state during execution.
/// It is created from a compiled Module and holds:
///   - globals:    an array of global variables copied and initialized from module.globals
///   - memory:     linear memory, either exclusively-owned or a shared reference (Threads proposal)
///   - host_funcs: resolved host functions for each imported function slot
const std = @import("std");
const core = @import("core");
const store_mod = @import("./store.zig");
const module_mod = @import("./module.zig");
const host_mod = @import("./host.zig");
const vm_mod = @import("../vm/root.zig");
const parser_mod = @import("parser");
const payload_mod = @import("payload");
const gc_mod = @import("../vm/gc/root.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const Module = module_mod.Module;
const Global = core.Global;
const GlobalType = core.GlobalType;
const Memory = core.Memory;
const SharedMemory = core.SharedMemory;
const VM = vm_mod.VM;
const ExecEnv = vm_mod.ExecEnv;
const HostInstance = host_mod.HostInstance;
pub const RawVal = vm_mod.RawVal;
/// Wasm runtime trap, carrying TrapCode and optional description
pub const Trap = vm_mod.Trap;
/// TrapCode enumeration, used to determine the type of trap in ExecResult.trap
pub const TrapCode = vm_mod.TrapCode;
/// Instance.call result: either a normal return (with optional value for void functions) or a Wasm trap
pub const ExecResult = vm_mod.ExecResult;
pub const HostFunc = host_mod.HostFunc;
pub const Linker = host_mod.Linker;
pub const Imports = Linker;

pub const InstanceError = Allocator.Error || error{
    ExportNotFound,
    /// A function import required by the module was not provided in the Imports map
    ImportNotSatisfied,
    /// A host-provided function's signature does not match the imported function type.
    ImportSignatureMismatch,
    /// Shared memory requires a maximum page count (Wasm spec).
    SharedMemoryMissingMax,
    /// The module does not declare a shared memory but a SharedMemory was provided.
    ModuleMemoryNotShared,
    /// The provided SharedMemory's capacity is smaller than what the module requires.
    SharedMemoryTooSmall,
    /// GC constant expression evaluation failed (e.g. unknown opcode, GC heap OOM).
    GcConstExprError,
};

pub const Instance = struct {
    store: *Store,
    /// Read-only module reference; the caller is responsible for ensuring the Module remains valid for the lifetime of the Instance.
    /// TODO: Upgrade to Arc(Module) to support multiple Instances sharing the same Module.
    module: *const Module,
    /// Runtime globals, copied and initialized from module.globals.
    globals: []Global,
    /// Linear memory, either exclusively owned or shared across instances (Threads proposal).
    memory: Memory,
    /// Resolved host functions for each imported function slot, in the same order as module.imported_funcs.
    /// Length == module.imported_funcs.len.
    host_funcs: []HostFunc,
    host_view: HostInstance,
    /// Tracks which data segments have been dropped via data.drop instruction.
    /// data_segments_dropped[i] == true means segment i cannot be used by memory.init.
    data_segments_dropped: []bool,
    /// Tracks which element segments have been dropped via elem.drop instruction.
    /// elem_segments_dropped[i] == true means segment i cannot be used by table.init.
    elem_segments_dropped: []bool,

    /// Instantiate a Module.
    ///
    /// Parameters:
    ///   store   — The runtime context holding the allocator and engine.
    ///   module  — A compiled read-only Module (the caller is responsible for its lifetime).
    ///   imports — Host-provided functions satisfying the module's imports.
    ///             Pass `Imports.empty` for modules with no imports.
    pub fn init(store: *Store, module: *const Module, imports: Linker) InstanceError!Instance {
        const allocator = store.allocator;

        // ── 1. copy globals ──────────────────────────────────────────
        const globals = try allocator.alloc(Global, module.globals.len);
        errdefer allocator.free(globals);

        for (module.globals, 0..) |global_init, i| {
            if (global_init.init_expr) |init_expr| {
                // Deferred GC const expr — evaluate at runtime using the store's GC heap.
                const value = evaluateGcConstExpr(
                    store.allocator,
                    &store.gc_heap,
                    init_expr,
                    globals[0..i],
                    module.composite_types,
                    module.struct_layouts,
                    module.array_layouts,
                ) catch {
                    return error.GcConstExprError;
                };
                globals[i] = Global.init(
                    GlobalType.init(global_init.mutability, global_init.value.ty),
                    value,
                );
            } else {
                globals[i] = Global.init(
                    GlobalType.init(global_init.mutability, global_init.value.ty),
                    global_init.value.value,
                );
            }
        }

        // ── 2. allocate memory ──────────────────────────────────────────────────
        var mem: Memory = if (module.memory) |mem_def| blk: {
            if (mem_def.shared) {
                const max = mem_def.max_pages orelse return error.SharedMemoryMissingMax;
                const shared = try SharedMemory.init(allocator, mem_def.min_pages, max);
                break :blk Memory.initShared(shared);
            } else {
                break :blk try Memory.initOwned(allocator, mem_def.min_pages);
            }
        } else Memory.initEmpty();
        errdefer mem.deinit();

        // ── 3. resolve host functions ────────────────────────────────────────────
        // Build a flat slice parallel to module.imported_funcs, looking up each
        // import by (module_name, func_name) in the provided Imports map.
        const host_funcs = try allocator.alloc(HostFunc, module.imported_funcs.len);
        errdefer allocator.free(host_funcs);

        for (module.imported_funcs, 0..) |def, i| {
            const hf = imports.get(def.module_name, def.func_name) orelse {
                return error.ImportNotSatisfied;
            };
            const func_type = switch (module.composite_types[def.type_index]) {
                .func_type => |ft| ft,
                else => return error.ImportSignatureMismatch,
            };
            if (!hf.matches(func_type)) {
                return error.ImportSignatureMismatch;
            }
            host_funcs[i] = hf;
        }

        const host_view = HostInstance{
            .module = module,
            .globals = globals,
            .memory = &mem,
            .tables = module.tables,
        };

        // ── 4. initialize data segment dropped flags ───────────────────────────────
        const data_segments_dropped = try allocator.alloc(bool, module.data_segments.len);
        errdefer allocator.free(data_segments_dropped);
        @memset(data_segments_dropped, false);

        // ── 5. initialize element segment dropped flags ──────────────────────────────
        const elem_segments_dropped = try allocator.alloc(bool, module.elem_segments.len);
        errdefer allocator.free(elem_segments_dropped);
        @memset(elem_segments_dropped, false);

        store.registerInstance();
        errdefer store.unregisterInstance();

        return .{
            .store = store,
            .module = module,
            .globals = globals,
            .memory = mem,
            .host_funcs = host_funcs,
            .host_view = host_view,
            .data_segments_dropped = data_segments_dropped,
            .elem_segments_dropped = elem_segments_dropped,
        };
    }

    /// Instantiate a Module using an externally-created `SharedMemory`.
    ///
    /// This is the multi-threaded variant of `init`.  All Instance values created
    /// from the same Module with the same `shared` handle will operate on the same
    /// linear memory region, enabling cross-thread communication via atomic
    /// operations (memory.atomic.store / load / rmw / cmpxchg / wait / notify).
    ///
    /// Constraints
    /// -----------
    /// - The module must declare `(memory ... shared)`.
    /// - `shared.capacity()` must be >= `module.memory.max_pages * WASM_PAGE_SIZE`.
    ///
    /// Ownership
    /// ---------
    /// `initWithSharedMemory` clones the refcount on `shared`, so the caller may
    /// freely `deinit` its own handle after instantiation.  Each Instance's
    /// `deinit` decrements the refcount; the underlying bytes are freed when the
    /// last reference is dropped.
    pub fn initWithSharedMemory(
        store: *Store,
        module: *const Module,
        imports: Linker,
        shared: SharedMemory,
    ) InstanceError!Instance {
        const allocator = store.allocator;

        // ── Validate that the module declares a shared memory ──────────────────
        const mem_def = module.memory orelse return error.ModuleMemoryNotShared;
        if (!mem_def.shared) return error.ModuleMemoryNotShared;

        const max = mem_def.max_pages orelse return error.SharedMemoryMissingMax;
        const required_capacity = @as(usize, max) * @import("core").WASM_PAGE_SIZE;
        if (shared.capacity() < required_capacity) return error.SharedMemoryTooSmall;

        // ── 1. copy globals ────────────────────────────────────────────────────
        const globals = try allocator.alloc(Global, module.globals.len);
        errdefer allocator.free(globals);

        for (module.globals, 0..) |global_init, i| {
            if (global_init.init_expr) |init_expr| {
                // Deferred GC const expr — evaluate at runtime using the store's GC heap.
                const value = evaluateGcConstExpr(
                    store.allocator,
                    &store.gc_heap,
                    init_expr,
                    globals[0..i],
                    module.composite_types,
                    module.struct_layouts,
                    module.array_layouts,
                ) catch return error.GcConstExprError;
                globals[i] = Global.init(
                    GlobalType.init(global_init.mutability, global_init.value.ty),
                    value,
                );
            } else {
                globals[i] = Global.init(
                    GlobalType.init(global_init.mutability, global_init.value.ty),
                    global_init.value.value,
                );
            }
        }

        // ── 2. wrap the provided shared memory (increments refcount) ───────────
        var mem = Memory.initShared(shared);
        errdefer mem.deinit();

        // ── 3. resolve host functions ──────────────────────────────────────────
        const host_funcs = try allocator.alloc(HostFunc, module.imported_funcs.len);
        errdefer allocator.free(host_funcs);

        for (module.imported_funcs, 0..) |def, i| {
            const hf = imports.get(def.module_name, def.func_name) orelse return error.ImportNotSatisfied;
            const func_type = switch (module.composite_types[def.type_index]) {
                .func_type => |ft| ft,
                else => return error.ImportSignatureMismatch,
            };
            if (!hf.matches(func_type)) {
                return error.ImportSignatureMismatch;
            }
            host_funcs[i] = hf;
        }

        const host_view = HostInstance{
            .module = module,
            .globals = globals,
            .memory = &mem,
            .tables = module.tables,
        };

        // ── 4. segment dropped flags ───────────────────────────────────────────
        const data_segments_dropped = try allocator.alloc(bool, module.data_segments.len);
        errdefer allocator.free(data_segments_dropped);
        @memset(data_segments_dropped, false);

        const elem_segments_dropped = try allocator.alloc(bool, module.elem_segments.len);
        errdefer allocator.free(elem_segments_dropped);
        @memset(elem_segments_dropped, false);

        store.registerInstance();
        errdefer store.unregisterInstance();

        return .{
            .store = store,
            .module = module,
            .globals = globals,
            .memory = mem,
            .host_funcs = host_funcs,
            .host_view = host_view,
            .data_segments_dropped = data_segments_dropped,
            .elem_segments_dropped = elem_segments_dropped,
        };
    }

    pub fn deinit(self: *Instance) void {
        const allocator = self.store.allocator;
        allocator.free(self.globals);
        self.memory.deinit();
        allocator.free(self.host_funcs);
        allocator.free(self.data_segments_dropped);
        allocator.free(self.elem_segments_dropped);
        self.store.unregisterInstance();
        self.* = undefined;
    }

    pub fn execEnv(self: *Instance) ExecEnv {
        // Ensure host_view.memory always points to the Instance's own memory
        // field (not a stale local from init).
        self.host_view.memory = &self.memory;
        return .{
            .store = self.store,
            .host_instance = &self.host_view,
            .globals = self.globals,
            .memory = &self.memory,
            .functions = self.module.functions,
            .host_funcs = self.host_funcs,
            .tables = self.module.tables,
            .func_type_indices = self.module.func_type_indices,
            .data_segments = self.module.data_segments,
            .data_segments_dropped = self.data_segments_dropped,
            .elem_segments = self.module.elem_segments,
            .elem_segments_dropped = self.elem_segments_dropped,
            .composite_types = self.module.composite_types,
            .struct_layouts = self.module.struct_layouts,
            .array_layouts = self.module.array_layouts,
            .type_ancestors = self.module.type_ancestors,
        };
    }

    /// Call an exported function by name.
    ///
    /// Parameters:
    ///   name — The name of the exported function
    ///   args — Function arguments
    ///
    /// Returns:
    ///   error.ExportNotFound     — The export with the given name does not exist
    ///   Allocator.Error          — Host memory allocation failure
    ///   ExecResult.ok(val)       — Normal execution completed, val is the return value (null for void functions)
    ///   ExecResult.trap(trap)    — Wasm runtime trap (e.g., out-of-bounds memory access)
    pub fn call(self: *Instance, name: []const u8, args: []const RawVal) (Allocator.Error || error{ ExportNotFound, ExportNotCallable })!ExecResult {
        const export_entry = self.module.exports.get(name) orelse return error.ExportNotFound;
        const func_index = switch (export_entry) {
            .function_index => |idx| idx,
            else => return error.ExportNotCallable,
        };
        const func = self.module.functions[func_index];
        var vm = VM.init(self.store.allocator);
        return vm.execute(func, args, self.execEnv());
    }

    /// Execute the module's start function (WebAssembly spec §4.5.4).
    ///
    /// The start function is called automatically during instantiation to perform
    /// module-level initialization (e.g. Kotlin's _initializeModule which sets up
    /// string pools and field data).  Returns null if there is no start function.
    pub fn runStartFunction(self: *Instance) Allocator.Error!?ExecResult {
        const start_idx = self.module.start_function orelse return null;
        const func = self.module.functions[start_idx];
        var vm = VM.init(self.store.allocator);
        return try vm.execute(func, &.{}, self.execEnv());
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// GC constant expression evaluator
//
// WebAssembly GC globals may use constant expressions that allocate GC objects
// (struct.new, array.new_fixed, etc.).  These cannot be evaluated at compile
// time because they require the GC heap.  This mini stack-machine interpreter
// is called during Instance.init for each global whose init_expr was deferred.
// ─────────────────────────────────────────────────────────────────────────────

const GcHeap = gc_mod.GcHeap;
const GcHeader = gc_mod.GcHeader;
const GcRefKind = core.GcRefKind;
const GcRef = core.GcRef;
const StructLayout = gc_mod.StructLayout;
const ArrayLayout = gc_mod.ArrayLayout;
const CompositeType = core.CompositeType;
const StructType = core.StructType;
const ArrayType = core.ArrayType;
const OperatorCode = payload_mod.OperatorCode;

const GcConstExprError = error{
    UnsupportedOpcode,
    GcHeapOom,
    StackUnderflow,
    BadTypeIndex,
    ParseError,
};

/// Evaluate a GC constant expression that was deferred from compile time.
///
/// Implements a minimal Wasm stack machine supporting the const-expr subset:
///   - i32.const, i64.const, f32.const, f64.const
///   - ref.null, ref.func
///   - global.get (from already-initialized globals)
///   - struct.new, struct.new_default
///   - array.new_default, array.new_fixed
///   - ref.cast (passthrough in const expr context)
///   - any.convert_extern, extern.convert_any (passthrough in const expr context)
///   - ref.i31
fn evaluateGcConstExpr(
    allocator: Allocator,
    gc_heap: *GcHeap,
    expr: []const u8,
    initialized_globals: []const Global,
    composite_types: []const CompositeType,
    struct_layouts: []const ?StructLayout,
    array_layouts: []const ?ArrayLayout,
) GcConstExprError!RawVal {
    // Operand stack for the mini interpreter — 64 entries should be more than
    // enough for any realistic constant expression.
    var stack: [64]RawVal = undefined;
    var sp: usize = 0;

    var cursor: usize = 0;

    while (cursor < expr.len) {
        const result = parser_mod.readNextOperator(allocator, expr[cursor..]) catch
            return error.ParseError;
        cursor += result.consumed;
        const info = result.info;

        switch (info.code) {
            .i32_const => {
                if (sp >= stack.len) return error.StackUnderflow;
                const val: i32 = if (info.literal) |lit| switch (lit) {
                    .number => |n| @truncate(n),
                    else => return error.UnsupportedOpcode,
                } else return error.UnsupportedOpcode;
                stack[sp] = RawVal.from(val);
                sp += 1;
            },
            .i64_const => {
                if (sp >= stack.len) return error.StackUnderflow;
                const val: i64 = if (info.literal) |lit| switch (lit) {
                    .int64 => |n| n,
                    .number => |n| n,
                    else => return error.UnsupportedOpcode,
                } else return error.UnsupportedOpcode;
                stack[sp] = RawVal.from(val);
                sp += 1;
            },
            .f32_const => {
                if (sp >= stack.len) return error.StackUnderflow;
                const val: f32 = if (info.literal) |lit| switch (lit) {
                    .bytes => |b| @bitCast(std.mem.readInt(u32, b[0..4], .little)),
                    else => return error.UnsupportedOpcode,
                } else return error.UnsupportedOpcode;
                stack[sp] = RawVal.from(val);
                sp += 1;
            },
            .f64_const => {
                if (sp >= stack.len) return error.StackUnderflow;
                const val: f64 = if (info.literal) |lit| switch (lit) {
                    .bytes => |b| @bitCast(std.mem.readInt(u64, b[0..8], .little)),
                    else => return error.UnsupportedOpcode,
                } else return error.UnsupportedOpcode;
                stack[sp] = RawVal.from(val);
                sp += 1;
            },
            .ref_null => {
                if (sp >= stack.len) return error.StackUnderflow;
                stack[sp] = RawVal.fromBits64(0);
                sp += 1;
            },
            .ref_func => {
                if (sp >= stack.len) return error.StackUnderflow;
                const func_idx = info.func_index orelse return error.UnsupportedOpcode;
                // funcref encoding: func_idx + 1 (so that func_idx=0 is not confused with null)
                stack[sp] = RawVal.fromBits64(func_idx + 1);
                sp += 1;
            },
            .global_get => {
                if (sp >= stack.len) return error.StackUnderflow;
                const global_idx = info.global_index orelse return error.UnsupportedOpcode;
                if (global_idx >= initialized_globals.len) return error.BadTypeIndex;
                stack[sp] = initialized_globals[global_idx].value;
                sp += 1;
            },
            .struct_new => {
                // ref_type is a payload HeapType (index variant) — parser stores GC struct type here
                const type_idx = if (info.ref_type) |ht| switch (ht) {
                    .index => |idx| idx,
                    else => return error.BadTypeIndex,
                } else return error.BadTypeIndex;

                if (type_idx >= composite_types.len) return error.BadTypeIndex;
                const struct_type = switch (composite_types[type_idx]) {
                    .struct_type => |st| st,
                    else => return error.BadTypeIndex,
                };
                const layout = struct_layouts[type_idx] orelse return error.BadTypeIndex;

                const num_fields = struct_type.fields.len;
                if (sp < num_fields) return error.StackUnderflow;

                const total_size = @sizeOf(GcHeader) + layout.size;
                const gc_ref = gc_heap.alloc(total_size) orelse return error.GcHeapOom;

                const header_ptr = gc_heap.getHeader(gc_ref);
                header_ptr.* = GcHeader.initFromRefKind(GcRefKind.init(GcRefKind.Struct), type_idx);

                // Pop fields in reverse order (first field was pushed first, last field is on top)
                var fi: usize = num_fields;
                while (fi > 0) {
                    fi -= 1;
                    sp -= 1;
                    gc_heap.writeField(gc_ref, struct_type, layout, @intCast(fi), stack[sp]);
                }

                stack[sp] = RawVal.fromGcRef(gc_ref);
                sp += 1;
            },
            .struct_new_default => {
                const type_idx = if (info.ref_type) |ht| switch (ht) {
                    .index => |idx| idx,
                    else => return error.BadTypeIndex,
                } else return error.BadTypeIndex;

                if (type_idx >= struct_layouts.len) return error.BadTypeIndex;
                const layout = struct_layouts[type_idx] orelse return error.BadTypeIndex;

                const total_size = @sizeOf(GcHeader) + layout.size;
                const gc_ref = gc_heap.alloc(total_size) orelse return error.GcHeapOom;

                const header_ptr = gc_heap.getHeader(gc_ref);
                header_ptr.* = GcHeader.initFromRefKind(GcRefKind.init(GcRefKind.Struct), type_idx);

                // Zero-initialize all fields
                const data = gc_heap.getBytesAt(gc_ref, @sizeOf(GcHeader));
                @memset(data[0..layout.size], 0);

                if (sp >= stack.len) return error.StackUnderflow;
                stack[sp] = RawVal.fromGcRef(gc_ref);
                sp += 1;
            },
            .array_new_default => {
                const type_idx = if (info.ref_type) |ht| switch (ht) {
                    .index => |idx| idx,
                    else => return error.BadTypeIndex,
                } else return error.BadTypeIndex;

                if (type_idx >= array_layouts.len) return error.BadTypeIndex;
                const layout = array_layouts[type_idx] orelse return error.BadTypeIndex;

                // Pop length from stack
                if (sp < 1) return error.StackUnderflow;
                sp -= 1;
                const len = stack[sp].readAs(u32);

                const total_size = layout.base_size + len * layout.elem_size;
                const gc_ref = gc_heap.alloc(total_size) orelse return error.GcHeapOom;

                const header_ptr = gc_heap.getHeader(gc_ref);
                header_ptr.* = GcHeader.initFromRefKind(GcRefKind.init(GcRefKind.Array), type_idx);

                gc_heap.setLength(gc_ref, len);

                // Zero-initialize all elements
                const data = gc_heap.getBytesAt(gc_ref, layout.base_size);
                @memset(data[0 .. len * layout.elem_size], 0);

                if (sp >= stack.len) return error.StackUnderflow;
                stack[sp] = RawVal.fromGcRef(gc_ref);
                sp += 1;
            },
            .array_new_fixed => {
                const type_idx = if (info.ref_type) |ht| switch (ht) {
                    .index => |idx| idx,
                    else => return error.BadTypeIndex,
                } else return error.BadTypeIndex;

                if (type_idx >= composite_types.len) return error.BadTypeIndex;
                const array_type = switch (composite_types[type_idx]) {
                    .array_type => |at| at,
                    else => return error.BadTypeIndex,
                };
                const layout = array_layouts[type_idx] orelse return error.BadTypeIndex;

                // len is the fixed element count from the instruction encoding
                const len = info.len orelse return error.UnsupportedOpcode;

                if (sp < len) return error.StackUnderflow;

                const total_size = layout.base_size + len * layout.elem_size;
                const gc_ref = gc_heap.alloc(total_size) orelse return error.GcHeapOom;

                const header_ptr = gc_heap.getHeader(gc_ref);
                header_ptr.* = GcHeader.initFromRefKind(GcRefKind.init(GcRefKind.Array), type_idx);

                gc_heap.setLength(gc_ref, len);

                // Pop elements in reverse order (first element was pushed first)
                var ei: usize = len;
                while (ei > 0) {
                    ei -= 1;
                    sp -= 1;
                    gc_heap.writeElem(gc_ref, array_type, layout, @intCast(ei), stack[sp]);
                }

                if (sp >= stack.len) return error.StackUnderflow;
                stack[sp] = RawVal.fromGcRef(gc_ref);
                sp += 1;
            },
            .ref_cast, .ref_cast_null => {
                // In constant expressions, ref.cast is a type assertion.
                // The value on the stack is unchanged — the cast is validated
                // structurally at compile time, not dynamically.
                if (sp < 1) return error.StackUnderflow;
                // Leave stack[sp-1] unchanged (passthrough).
            },
            .any_convert_extern, .extern_convert_any => {
                // Identity conversion in const expr context.
                if (sp < 1) return error.StackUnderflow;
            },
            .ref_i31 => {
                // Convert i32 on stack to i31ref.
                if (sp < 1) return error.StackUnderflow;
                const i32_val = stack[sp - 1].readAs(i32);
                const i31_val: i31 = @truncate(i32_val);
                stack[sp - 1] = RawVal.fromGcRef(GcRef.fromI31(i31_val));
            },
            .end => {
                // End of expression — result is top of stack.
                break;
            },
            else => {
                std.log.err("evaluateGcConstExpr: unsupported opcode 0x{x}", .{@intFromEnum(info.code)});
                return error.UnsupportedOpcode;
            },
        }
    }

    if (sp == 0) return error.StackUnderflow;
    return stack[sp - 1];
}

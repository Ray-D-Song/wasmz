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
const utils_parse = @import("../utils/parse.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const Module = module_mod.Module;
pub const ArcModule = module_mod.ArcModule;
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
    /// An active data segment's target range exceeds the linear memory size.
    DataSegmentOutOfBounds,
};

pub const Instance = struct {
    store: *Store,
    /// Reference-counted module handle; the Instance owns one strong reference.
    /// The underlying Module is freed when the last Instance (or ArcModule handle) is released.
    module: ArcModule,
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
    /// Persistent VM state (val_stack + call_stack) reused across all calls.
    /// Eliminates the per-call 16 MiB val_stack allocation.
    vm: VM,

    /// Instantiate a Module.
    ///
    /// Parameters:
    ///   store   — The runtime context holding the allocator and engine.
    ///   module  — A compiled read-only Module (the caller is responsible for its lifetime).
    ///   imports — Host-provided functions satisfying the module's imports.
    ///             Pass `Imports.empty` for modules with no imports.
    /// Instantiate a Module from an `ArcModule` handle.
    ///
    /// The Instance takes ownership of one strong reference (i.e., the caller should
    /// pass `arc.retain()` or move the arc in).  The reference is released in `deinit`.
    pub fn init(store: *Store, arc: ArcModule, imports: Linker) InstanceError!Instance {
        const module = arc.value;
        const allocator = store.allocator;

        // ── 0. resolve imported global values ───────────────────────────────────
        // Build a flat slice of RawVal for each imported global, in the order they
        // appear in the Import Section.  These values are used by global.get in
        // constant expressions (Wasm spec: global.get in const expr can only
        // reference imported globals).  Missing imported globals default to zero.
        const imported_global_values = try allocator.alloc(RawVal, module.imported_globals.len);
        defer allocator.free(imported_global_values);
        for (module.imported_globals, 0..) |def, i| {
            imported_global_values[i] = imports.getGlobal(def.module_name, def.global_name) orelse
                RawVal.fromBits64(0);
        }

        // ── 1. copy globals ──────────────────────────────────────────
        const globals = try allocator.alloc(Global, module.globals.len);
        errdefer allocator.free(globals);

        for (module.globals, 0..) |global_init, i| {
            if (global_init.init_expr) |init_expr| {
                // Deferred const expr — evaluate at runtime.
                // Pass imported_global_values so global.get can resolve imported globals.
                const value = evaluateGcConstExpr(
                    store.allocator,
                    &store.gc_heap,
                    init_expr,
                    imported_global_values,
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

        // ── 4a. apply active data segments to linear memory (WASM spec §4.5.4) ──
        // Active segments are copied into linear memory at instantiation time and
        // then implicitly dropped (they cannot be used by memory.init after this).
        {
            const mem_bytes = mem.bytes();
            for (module.data_segments, 0..) |seg, i| {
                if (seg.mode != .active) continue;
                const dst: usize = seg.offset;
                const len: usize = seg.data.len;
                if (dst + len > mem_bytes.len) return error.DataSegmentOutOfBounds;
                @memcpy(mem_bytes[dst..][0..len], seg.data);
                data_segments_dropped[i] = true;
            }
        }

        // ── 5. initialize element segment dropped flags ──────────────────────────────
        const elem_segments_dropped = try allocator.alloc(bool, module.elem_segments.len);
        errdefer allocator.free(elem_segments_dropped);
        @memset(elem_segments_dropped, false);

        store.registerInstance();
        errdefer store.unregisterInstance();

        // Register initial linear memory size into the budget.
        store.memory_budget.recordLinearGrow(mem.byteLen());

        return .{
            .store = store,
            .module = arc,
            .globals = globals,
            .memory = mem,
            .host_funcs = host_funcs,
            .host_view = host_view,
            .data_segments_dropped = data_segments_dropped,
            .elem_segments_dropped = elem_segments_dropped,
            .vm = VM.init(allocator),
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
        arc: ArcModule,
        imports: Linker,
        shared: SharedMemory,
    ) InstanceError!Instance {
        const module = arc.value;
        const allocator = store.allocator;

        // ── Validate that the module declares a shared memory ──────────────────
        const mem_def = module.memory orelse return error.ModuleMemoryNotShared;
        if (!mem_def.shared) return error.ModuleMemoryNotShared;

        const max = mem_def.max_pages orelse return error.SharedMemoryMissingMax;
        const required_capacity = @as(usize, max) * @import("core").WASM_PAGE_SIZE;
        if (shared.capacity() < required_capacity) return error.SharedMemoryTooSmall;

        // ── 1. copy globals ────────────────────────────────────────────────────
        // Resolve imported global values first for use in global.get const exprs.
        const imported_global_values_shared = try allocator.alloc(RawVal, module.imported_globals.len);
        defer allocator.free(imported_global_values_shared);
        for (module.imported_globals, 0..) |def, i| {
            imported_global_values_shared[i] = imports.getGlobal(def.module_name, def.global_name) orelse
                RawVal.fromBits64(0);
        }

        const globals = try allocator.alloc(Global, module.globals.len);
        errdefer allocator.free(globals);

        for (module.globals, 0..) |global_init, i| {
            if (global_init.init_expr) |init_expr| {
                // Deferred const expr — evaluate at runtime.
                const value = evaluateGcConstExpr(
                    store.allocator,
                    &store.gc_heap,
                    init_expr,
                    imported_global_values_shared,
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

        // ── 4a. apply active data segments to linear memory (WASM spec §4.5.4) ──
        {
            const mem_bytes = mem.bytes();
            for (module.data_segments, 0..) |seg, i| {
                if (seg.mode != .active) continue;
                const dst: usize = seg.offset;
                const len: usize = seg.data.len;
                if (dst + len > mem_bytes.len) return error.DataSegmentOutOfBounds;
                @memcpy(mem_bytes[dst..][0..len], seg.data);
                data_segments_dropped[i] = true;
            }
        }

        const elem_segments_dropped = try allocator.alloc(bool, module.elem_segments.len);
        errdefer allocator.free(elem_segments_dropped);
        @memset(elem_segments_dropped, false);

        store.registerInstance();
        errdefer store.unregisterInstance();

        // Register shared memory capacity into the budget.
        store.memory_budget.recordSharedGrow(mem.byteLen());

        return .{
            .store = store,
            .module = arc,
            .globals = globals,
            .memory = mem,
            .host_funcs = host_funcs,
            .host_view = host_view,
            .data_segments_dropped = data_segments_dropped,
            .elem_segments_dropped = elem_segments_dropped,
            .vm = VM.init(allocator),
        };
    }

    pub fn deinit(self: *Instance) void {
        const allocator = self.store.allocator;
        allocator.free(self.globals);
        self.memory.deinit();
        allocator.free(self.host_funcs);
        allocator.free(self.data_segments_dropped);
        allocator.free(self.elem_segments_dropped);
        self.vm.deinit();
        self.store.unregisterInstance();
        // Release our strong reference; call Module.deinit() if we were the last holder.
        if (self.module.releaseUnwrap()) |m| {
            var mod = m;
            mod.deinit();
        }
        self.* = undefined;
    }

    pub fn execEnv(self: *Instance) ExecEnv {
        // Ensure host_view.memory always points to the Instance's own memory
        // field (not a stale local from init).
        self.host_view.memory = &self.memory;
        const m = self.module.value;
        // Expose budget pointer if the store has a limit configured.
        const budget_ptr: ?*store_mod.MemoryBudget = if (self.store.memory_budget.limit_bytes != null)
            &self.store.memory_budget
        else
            null;
        return .{
            .store = self.store,
            .host_instance = &self.host_view,
            .globals = self.globals,
            .memory = &self.memory,
            .functions = m.functions[m.imported_funcs.len..],
            .host_funcs = self.host_funcs,
            .tables = m.tables,
            .func_type_indices = m.func_type_indices,
            .data_segments = m.data_segments,
            .data_segments_dropped = self.data_segments_dropped,
            .elem_segments = m.elem_segments,
            .elem_segments_dropped = self.elem_segments_dropped,
            .composite_types = m.composite_types,
            .struct_layouts = m.struct_layouts,
            .array_layouts = m.array_layouts,
            .type_ancestors = m.type_ancestors,
            .memory_budget = budget_ptr,
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
        const m = self.module.value;
        const export_entry = m.exports.get(name) orelse return error.ExportNotFound;
        const func_index = switch (export_entry) {
            .function_index => |idx| idx,
            else => return error.ExportNotCallable,
        };
        return self.vm.execute(&m.functions[func_index], args, self.execEnv());
    }

    /// Execute the module's start function (WebAssembly spec §4.5.4).
    ///
    /// The start function is called automatically during instantiation to perform
    /// module-level initialization (e.g. Kotlin's _initializeModule which sets up
    /// string pools and field data).  Returns null if there is no start function.
    pub fn runStartFunction(self: *Instance) Allocator.Error!?ExecResult {
        const m = self.module.value;
        const start_idx = m.start_function orelse return null;
        return try self.vm.execute(&m.functions[start_idx], &.{}, self.execEnv());
    }

    /// Initialize a Reactor module by calling its `_initialize` export (if present).
    ///
    /// WASI Reactor model lifecycle:
    ///   1. Instantiate the module (Instance.init)
    ///   2. Call Instance.initializeReactor() — runs `_initialize` once if exported
    ///   3. Call any exported function repeatedly via Instance.call()
    ///
    /// Returns null if the module does not export `_initialize`.
    /// Returns the ExecResult if `_initialize` was found and called.
    pub fn initializeReactor(self: *Instance) (Allocator.Error || error{ ExportNotFound, ExportNotCallable })!?ExecResult {
        const m = self.module.value;
        if (m.exports.get("_initialize") == null) return null;
        return try self.call("_initialize", &.{});
    }

    /// Returns true if the module is a Command module (exports `_start`).
    pub fn isCommand(self: *const Instance) bool {
        return self.module.value.exports.get("_start") != null;
    }

    /// Returns true if the module is a Reactor module (exports `_initialize` or
    /// has neither `_start` nor `_initialize`, i.e. a library).
    pub fn isReactor(self: *const Instance) bool {
        const exports = self.module.value.exports;
        // A module is considered a reactor if it has no _start, regardless of _initialize.
        return exports.get("_start") == null;
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
///   - global.get (imported globals via imported_global_values; module globals via initialized_globals)
///   - struct.new, struct.new_default
///   - array.new_default, array.new_fixed
///   - ref.cast (passthrough in const expr context)
///   - any.convert_extern, extern.convert_any (passthrough in const expr context)
///   - ref.i31
fn evaluateGcConstExpr(
    allocator: Allocator,
    gc_heap: *GcHeap,
    expr: []const u8,
    /// Values for imported globals (index 0..n_imported-1 in the global index space).
    imported_global_values: []const RawVal,
    /// Already-initialized module-defined globals (index n_imported..i-1 in the global index space).
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
            .i32_const, .i64_const, .f32_const, .f64_const, .ref_null, .ref_func => {
                if (sp >= stack.len) return error.StackUnderflow;
                stack[sp] = utils_parse.parseConstLiteral(info) catch return error.UnsupportedOpcode;
                sp += 1;
            },
            .global_get => {
                if (sp >= stack.len) return error.StackUnderflow;
                const global_idx = info.global_index orelse return error.UnsupportedOpcode;
                const n_imported = imported_global_values.len;
                if (global_idx < n_imported) {
                    // Wasm spec: const expr global.get may only reference imported globals.
                    stack[sp] = imported_global_values[global_idx];
                } else {
                    // Fallback: reference a previously-initialized module-defined global.
                    const local_idx = global_idx - n_imported;
                    if (local_idx >= initialized_globals.len) return error.BadTypeIndex;
                    stack[sp] = initialized_globals[local_idx].value;
                }
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

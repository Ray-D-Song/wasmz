/// instance.zig - WebAssembly Instance
///
/// Instance is a runtime instantiation of a Module, containing the mutable state during execution.
/// It is created from a compiled Module and holds:
///   - globals:    an array of global variables copied and initialized from module.globals
///   - memory:     linear memory, either exclusively-owned or a shared reference (Threads proposal)
///   - host_funcs: resolved host functions for each imported function slot
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const store_mod = @import("./store.zig");
const module_mod = @import("./module.zig");
const host_mod = @import("./host.zig");
const vm_mod = @import("../vm/root.zig");
const parser_mod = @import("parser");
const payload_mod = @import("payload");
const gc_mod = @import("../vm/gc/root.zig");
const utils_parse = @import("../utils/parse.zig");
const engine_mod = @import("../engine/root.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const Module = module_mod.Module;
const Engine = engine_mod.Engine;
pub const ArcModule = module_mod.ArcModule;
const Global = core.Global;
const GlobalType = core.GlobalType;
const SharedGlobal = core.SharedGlobal;
const SharedTable = core.SharedTable;
const TableEntry = core.TableEntry;
const Memory = core.Memory;
const SharedMemory = core.SharedMemory;

var next_instance_id = std.atomic.Value(usize).init(1);
const VM = vm_mod.VM;
const ExecEnv = vm_mod.ExecEnv;
const HostInstance = host_mod.HostInstance;
pub const RawVal = vm_mod.RawVal;
const SimdVal = core.SimdVal;
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
    /// A host-provided memory does not match the imported memory type.
    ImportMemoryMismatch,
    /// A host-provided global does not match the imported global type/mutability.
    ImportGlobalMismatch,
    /// A host-provided table does not match the imported table element type/limits.
    ImportTableMismatch,
    /// An active element segment's target range exceeds the table size.
    ElemSegmentOutOfBounds,
    /// memory64 linear memory is not supported on 32-bit hosts.
    Memory64UnsupportedOn32BitHost,
};

const CrossDispatchCtx = struct {
    allocator: Allocator,
    instance_id: u64,
    store: *Store,
    module: *Module,
    globals: []*Global,
    memory: Memory,
    tables: []SharedTable,
    host_funcs: []HostFunc,
    host_view: HostInstance,
    data_segments_dropped: []bool,
    elem_segments_dropped: []bool,
    memory64: bool,
    vm: VM,
    foreign_funcs: []core.ForeignFunc,
    last_trap_msg: ?[:0]u8 = null,

    fn deinit(self: *CrossDispatchCtx) void {
        if (self.last_trap_msg) |msg| self.allocator.free(msg);
        self.vm.deinit();
        self.allocator.free(self.foreign_funcs);
        self.allocator.destroy(self);
    }

    fn setTrapMsg(self: *CrossDispatchCtx, msg: []const u8) [*:0]const u8 {
        if (self.last_trap_msg) |prev| {
            self.allocator.free(prev);
            self.last_trap_msg = null;
        }
        const z = self.allocator.allocSentinel(u8, msg.len, 0) catch return "trap";
        @memcpy(z, msg);
        self.last_trap_msg = z;
        return z.ptr;
    }

    fn execEnv(self: *CrossDispatchCtx) ExecEnv {
        self.host_view.memory = &self.memory;
        self.host_view.globals = self.globals;
        self.host_view.tables = self.tables;
        const m = self.module;
        const budget_ptr: ?*store_mod.MemoryBudget = if (self.store.memory_budget.limit_bytes != null)
            &self.store.memory_budget
        else
            null;
        return .{
            .store = self.store,
            .host_instance = &self.host_view,
            .globals = self.globals,
            .memory = &self.memory,
            .functions = m.functions,
            .engine = self.store.engine,
            .module = m,
            .host_funcs = self.host_funcs,
            .tables = self.tables,
            .foreign_funcs = self.foreign_funcs,
            .instance_id = self.instance_id,
            .func_type_indices = m.func_type_indices,
            .data_segments = m.data_segments,
            .data_segments_dropped = self.data_segments_dropped,
            .elem_segments = m.elem_segments,
            .elem_segments_dropped = self.elem_segments_dropped,
            .composite_types = m.composite_types,
            .struct_layouts = m.struct_layouts,
            .array_layouts = m.array_layouts,
            .type_ancestors = m.type_ancestors,
            .type_canonical = m.type_canonical,
            .memory_budget = budget_ptr,
            .mem_trace = false,
            .memory64 = self.memory64,
        };
    }
};

fn foreignTrampoline(
    raw_ctx: ?*anyopaque,
    func_idx: u32,
    args: []const u64,
    results: []u64,
    trap_out: *?[*:0]const u8,
) bool {
    const ctx: *CrossDispatchCtx = @ptrCast(@alignCast(raw_ctx orelse {
        trap_out.* = "null cross-instance context";
        return false;
    }));
    const m = ctx.module;
    if (func_idx >= m.functions.len) {
        trap_out.* = "function index out of bounds";
        return false;
    }
    const raw_args = ctx.allocator.alloc(RawVal, args.len) catch {
        trap_out.* = "out of memory";
        return false;
    };
    defer ctx.allocator.free(raw_args);
    for (args, 0..) |bits, i| {
        raw_args[i] = RawVal.fromBits64(bits);
    }

    if (func_idx < ctx.host_funcs.len) {
        const hf = ctx.host_funcs[func_idx];
        const res_len = m.composite_types[m.func_type_indices[func_idx]].func_type.results().len;
        const host_results = ctx.allocator.alloc(RawVal, res_len) catch {
            trap_out.* = "out of memory";
            return false;
        };
        defer ctx.allocator.free(host_results);
        @memset(host_results, RawVal.fromBits64(0));

        ctx.host_view.memory = &ctx.memory;
        ctx.host_view.globals = ctx.globals;
        ctx.host_view.tables = ctx.tables;
        var hctx = host_mod.HostContext.init(ctx.store, &ctx.host_view, hf.host_data);
        hf.call(&hctx, raw_args, host_results) catch |err| switch (err) {
            error.HostTrap => {
                var t = hctx.takeTrap();
                defer t.deinit();
                const printed = t.allocPrint(ctx.allocator) catch "host trap";
                defer if (!std.mem.eql(u8, printed, "host trap")) ctx.allocator.free(printed);
                trap_out.* = ctx.setTrapMsg(printed);
                return false;
            },
            error.OutOfMemory => {
                trap_out.* = "out of memory";
                return false;
            },
        };
        const copy_n = @min(results.len, host_results.len);
        for (0..copy_n) |i| results[i] = host_results[i].low64;
        return true;
    }

    m.compileFunctionAt(ctx.store.engine, func_idx) catch {
        trap_out.* = "compilation failed";
        return false;
    };
    const encoded = &m.functions[func_idx].encoded;
    const exec_res = ctx.vm.execute(encoded, raw_args, ctx.execEnv()) catch {
        trap_out.* = "out of memory";
        return false;
    };
    switch (exec_res) {
        .ok => {
            const lr = ctx.vm.lastResults();
            const copy_n = @min(results.len, lr.len);
            for (0..copy_n) |i| results[i] = lr[i].low64;
            return true;
        },
        .trap => |t| {
            var tt = t;
            defer tt.deinit();
            const printed = tt.allocPrint(ctx.allocator) catch "trap";
            defer if (!std.mem.eql(u8, printed, "trap")) ctx.allocator.free(printed);
            trap_out.* = ctx.setTrapMsg(printed);
            return false;
        },
    }
}

fn buildCrossCtx(
    allocator: Allocator,
    instance_id: u64,
    store: *Store,
    module: *Module,
    globals: []*Global,
    memory: Memory,
    tables: []SharedTable,
    host_funcs: []HostFunc,
    data_segments_dropped: []bool,
    elem_segments_dropped: []bool,
) Allocator.Error!*CrossDispatchCtx {
    const ctx = try allocator.create(CrossDispatchCtx);
    errdefer allocator.destroy(ctx);

    const ff = try allocator.alloc(core.ForeignFunc, module.functions.len);
    errdefer allocator.free(ff);

    for (0..module.functions.len) |fi| {
        const ft = &module.composite_types[module.func_type_indices[fi]].func_type;
        ff[fi] = .{
            .ctx = ctx,
            .func_idx = @intCast(fi),
            .param_types = ft.params(),
            .result_types = ft.results(),
            .trampoline = &foreignTrampoline,
        };
    }

    ctx.* = .{
        .allocator = allocator,
        .instance_id = instance_id,
        .store = store,
        .module = module,
        .globals = globals,
        .memory = memory,
        .tables = tables,
        .host_funcs = host_funcs,
        .host_view = .{
            .module = module,
            .globals = globals,
            .memory = undefined,
            .tables = tables,
        },
        .data_segments_dropped = data_segments_dropped,
        .elem_segments_dropped = elem_segments_dropped,
        .memory64 = module.memory64(),
        .vm = VM.init(allocator),
        .foreign_funcs = ff,
    };
    ctx.host_view.memory = &ctx.memory;
    return ctx;
}

pub fn printInitError(arc: ArcModule, imports: Linker, err: InstanceError) void {
    if (builtin.single_threaded) return;
    switch (err) {
        error.ImportNotSatisfied => {
            std.debug.print("error: Failed to instantiate module: the following imports are not satisfied:\n", .{});
            for (arc.value.imported_funcs) |def| {
                if (imports.get(def.module_name, def.func_name) == null) {
                    std.debug.print("  - {s}::{s}\n", .{ def.module_name, def.func_name });
                }
            }
        },
        error.ImportSignatureMismatch => {
            std.debug.print("error: Failed to instantiate module: import signature mismatch\n", .{});
            for (arc.value.imported_funcs) |def| {
                const hf = imports.get(def.module_name, def.func_name) orelse continue;
                const func_type = switch (arc.value.composite_types[def.type_index]) {
                    .func_type => |ft| ft,
                    else => continue,
                };
                if (!hf.matches(func_type)) {
                    std.debug.print(
                        \\  - {s}::{s}
                        \\    expected: {any} -> {any}
                        \\    provided: {any} -> {any}
                        \\
                    , .{ def.module_name, def.func_name, func_type.params(), func_type.results(), hf.param_types, hf.result_types });
                }
            }
        },
        else => std.debug.print("error: Failed to instantiate module: {s}\n", .{@errorName(err)}),
    }
}

pub const Instance = struct {
    store: *Store,
    /// Unique non-zero runtime id used to distinguish local vs foreign table `funcref` entries.
    instance_id: u64,
    /// Reference-counted module handle; the Instance owns one strong reference.
    /// The underlying Module is freed when the last Instance (or ArcModule handle) is released.
    module: ArcModule,
    /// Reference-counted global handles covering the full Wasm global index space
    /// (imported globals 0..n_imported, then module-defined local globals).
    global_handles: []SharedGlobal,
    /// Direct `*Global` pointers parallel to `global_handles` for VM hot-path access.
    globals: []*Global,
    /// Heap-allocated cross-instance table dispatch context (stable across Instance value moves).
    cross_ctx: *CrossDispatchCtx,
    /// Linear memory, either refcounted `.rc` or `.shared` across instances.
    memory: Memory,
    /// Reference-counted runtime tables (imported tables first, then module-defined tables).
    tables: []SharedTable,
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
    /// When true, memory.grow events log RSS snapshots to stderr.
    /// Controlled by the --mem-trace CLI flag; defaults to false.
    mem_trace: bool = false,
    /// Number of allocations performed by this instance (excluding VM).
    alloc_count: usize = 0,
    /// When true, linear-memory addresses are i64 (memory64 proposal).
    memory64: bool = false,

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
    fn buildGlobals(
        store: *Store,
        module: *const Module,
        imports: Linker,
        allocator: Allocator,
    ) InstanceError!struct { handles: []SharedGlobal, ptrs: []*Global } {
        const n_imp = module.imported_globals.len;
        const n_loc = module.globals.len;
        const total = n_imp + n_loc;

        const handles = try allocator.alloc(SharedGlobal, total);
        errdefer allocator.free(handles);
        const ptrs = try allocator.alloc(*Global, total);
        errdefer allocator.free(ptrs);

        var inited: usize = 0;
        errdefer for (handles[0..inited]) |*h| h.deinit();

        const imp_raws = try allocator.alloc(RawVal, n_imp);
        defer allocator.free(imp_raws);

        for (module.imported_globals, 0..) |def, i| {
            if (imports.getGlobalHandle(def.module_name, def.global_name)) |gh| {
                if (!gh.valueType().eql(def.val_type) or gh.mutability() != def.mutability) {
                    return error.ImportGlobalMismatch;
                }
                handles[i] = gh.clone();
                ptrs[i] = handles[i].asGlobal();
                imp_raws[i] = gh.getRaw();
                inited += 1;
            } else if (imports.getGlobal(def.module_name, def.global_name)) |raw| {
                if (def.mutability == .Var) {
                    // Legacy value-only global import assumes const unless handle provided; wrap cleanly.
                }
                handles[i] = try SharedGlobal.init(allocator, GlobalType.init(def.mutability, def.val_type), raw, 0);
                ptrs[i] = handles[i].asGlobal();
                imp_raws[i] = raw;
                inited += 1;
            } else {
                return error.ImportNotSatisfied;
            }
        }

        for (module.globals, 0..) |global_init, i| {
            const val = if (global_init.init_expr) |init_expr| blk: {
                const gc_heap = try store.ensureGcHeap();
                break :blk evaluateGcConstExpr(
                    store.allocator,
                    gc_heap,
                    init_expr,
                    imp_raws,
                    ptrs[n_imp .. n_imp + i],
                    module.composite_types,
                    module.struct_layouts,
                    module.array_layouts,
                ) catch return error.GcConstExprError;
            } else global_init.value.value;

            const idx = n_imp + i;
            handles[idx] = try SharedGlobal.init(
                allocator,
                GlobalType.init(global_init.mutability, global_init.value.ty),
                val,
                0,
            );
            ptrs[idx] = handles[idx].asGlobal();
            inited += 1;
        }

        return .{ .handles = handles, .ptrs = ptrs };
    }

    fn buildTables(
        module: *const Module,
        imports: Linker,
        allocator: Allocator,
    ) InstanceError![]SharedTable {
        const n_imp = module.imported_tables.len;
        const total = module.table_defs.len;
        const tables = try allocator.alloc(SharedTable, total);
        errdefer allocator.free(tables);

        var inited: usize = 0;
        errdefer for (tables[0..inited]) |*t| t.deinit();

        for (module.imported_tables, 0..) |def, i| {
            const tbl = imports.getTable(def.module_name, def.table_name) orelse {
                return error.ImportNotSatisfied;
            };
            if (!tbl.elemType().eql(def.elem_type) or tbl.len() < def.min) {
                return error.ImportTableMismatch;
            }
            if (def.max) |req_max| {
                const got_max = tbl.max() orelse return error.ImportTableMismatch;
                if (got_max > req_max) return error.ImportTableMismatch;
            }
            tables[i] = tbl.clone();
            inited += 1;
        }

        var idx: usize = n_imp;
        while (idx < total) : (idx += 1) {
            const td = module.table_defs[idx];
            tables[idx] = try SharedTable.init(allocator, td.elem_type, td.min, td.max, TableEntry.null_entry);
            inited += 1;
        }

        return tables;
    }

    fn seedActiveElemSegments(
        module: *const Module,
        tables: []SharedTable,
        instance_id: u64,
        foreign_funcs: []const core.ForeignFunc,
        elem_segments_dropped: []bool,
    ) InstanceError!void {
        for (module.elem_segments, 0..) |seg, i| {
            if (seg.mode != .active) continue;
            if (seg.table_index >= tables.len) return error.ElemSegmentOutOfBounds;
            const entries = tables[seg.table_index].inner.entries;
            const dst: usize = seg.offset;
            const end = std.math.add(usize, dst, seg.func_indices.len) catch return error.ElemSegmentOutOfBounds;
            if (end > entries.len) return error.ElemSegmentOutOfBounds;
            for (seg.func_indices, 0..) |fi, j| {
                entries[dst + j] = if (fi == std.math.maxInt(u32))
                    TableEntry.null_entry
                else
                    TableEntry.fromFuncWithForeign(fi, instance_id, if (fi < foreign_funcs.len) &foreign_funcs[fi] else null);
            }
            tables[seg.table_index].inner.version +%= 1;
            elem_segments_dropped[i] = true;
        }
    }

    pub fn init(store: *Store, arc: ArcModule, imports: Linker) InstanceError!Instance {
        const module = arc.value;
        const allocator = store.allocator;
        var instance_alloc_count: usize = 0;
        const instance_id: u64 = @intCast(next_instance_id.fetchAdd(1, .monotonic));

        const g = try buildGlobals(store, module, imports, allocator);
        const global_handles = g.handles;
        const global_ptrs = g.ptrs;
        errdefer {
            for (global_handles) |*h| @constCast(h).deinit();
            allocator.free(global_handles);
            allocator.free(global_ptrs);
        }
        instance_alloc_count += 2;

        // 2. allocate memory
        if (module.memory64() and !core.platform.is_64bit) {
            return error.Memory64UnsupportedOn32BitHost;
        }

        var mem: Memory = if (module.imported_memory) |imp| blk: {
            const provided = imports.getMemory(imp.module_name, imp.memory_name) orelse {
                return error.ImportNotSatisfied;
            };
            if (imp.shared != provided.isShared()) return error.ImportMemoryMismatch;
            const min_bytes = imp.min_pages * core.WASM_PAGE_SIZE;
            if (provided.byteLen() < min_bytes) return error.ImportMemoryMismatch;
            if (imp.max_pages) |req_max| {
                const got_max = provided.maxPages() orelse return error.ImportMemoryMismatch;
                if (got_max > req_max) return error.ImportMemoryMismatch;
            }
            break :blk provided.clone();
        } else if (module.memory) |mem_def| blk: {
            if (mem_def.shared) {
                const max = mem_def.max_pages orelse return error.SharedMemoryMissingMax;
                const shared = try SharedMemory.init(allocator, store.io, mem_def.min_pages, max);
                instance_alloc_count += 1;
                break :blk Memory.initShared(shared);
            } else {
                break :blk try Memory.initRc(allocator, mem_def.min_pages, mem_def.max_pages, mem_def.memory64);
            }
        } else Memory.initEmpty();
        errdefer mem.deinit();
        if (module.imported_memory != null or module.memory != null) instance_alloc_count += 1;

        // 2b. allocate or resolve runtime tables
        const tables = try buildTables(module, imports, allocator);
        errdefer {
            for (tables) |*t| @constCast(t).deinit();
            allocator.free(tables);
        }

        // 3. resolve host functions
        const host_funcs = try allocator.alloc(HostFunc, module.imported_funcs.len);
        errdefer allocator.free(host_funcs);
        instance_alloc_count += 1;

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
            .globals = global_ptrs,
            .memory = &mem,
            .tables = tables,
        };

        // 4. initialize data segment dropped flags
        const data_segments_dropped = try allocator.alloc(bool, module.data_segments.len);
        errdefer allocator.free(data_segments_dropped);
        @memset(data_segments_dropped, false);
        instance_alloc_count += 1;

        // 4a. apply active data segments to linear memory (WASM spec §4.5.4)
        {
            const mem_bytes = mem.bytes();
            for (module.data_segments, 0..) |seg, i| {
                if (seg.mode != .active) continue;
                const dst: usize = std.math.cast(usize, seg.offset) orelse return error.DataSegmentOutOfBounds;
                const len: usize = seg.data.len;
                if (dst + len > mem_bytes.len) return error.DataSegmentOutOfBounds;
                @memcpy(mem_bytes[dst..][0..len], seg.data);
                data_segments_dropped[i] = true;
            }
        }

        // 5. initialize element segment dropped flags & apply active element segments
        const elem_segments_dropped = try allocator.alloc(bool, module.elem_segments.len);
        errdefer allocator.free(elem_segments_dropped);
        @memset(elem_segments_dropped, false);
        instance_alloc_count += 1;

        const cross_ctx = try buildCrossCtx(
            allocator,
            instance_id,
            store,
            module,
            global_ptrs,
            mem,
            tables,
            host_funcs,
            data_segments_dropped,
            elem_segments_dropped,
        );
        errdefer cross_ctx.deinit();

        try seedActiveElemSegments(module, tables, instance_id, cross_ctx.foreign_funcs, elem_segments_dropped);

        store.registerInstance();
        errdefer store.unregisterInstance();

        store.memory_budget.recordLinearGrow(mem.byteLen());

        return .{
            .store = store,
            .instance_id = instance_id,
            .module = arc,
            .global_handles = global_handles,
            .globals = global_ptrs,
            .cross_ctx = cross_ctx,
            .memory = mem,
            .tables = tables,
            .host_funcs = host_funcs,
            .host_view = host_view,
            .data_segments_dropped = data_segments_dropped,
            .elem_segments_dropped = elem_segments_dropped,
            .vm = VM.init(allocator),
            .alloc_count = instance_alloc_count,
            .memory64 = module.memory64(),
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
        var instance_alloc_count: usize = 0;

        if (module.memory64() and !core.platform.is_64bit) {
            return error.Memory64UnsupportedOn32BitHost;
        }

        // Validate that the module declares a shared memory
        const mem_def = module.memory orelse return error.ModuleMemoryNotShared;
        if (!mem_def.shared) return error.ModuleMemoryNotShared;

        const max = mem_def.max_pages orelse return error.SharedMemoryMissingMax;
        const required_capacity = @as(usize, max) * @import("core").WASM_PAGE_SIZE;
        if (shared.capacity() < required_capacity) return error.SharedMemoryTooSmall;
        const instance_id: u64 = @intCast(next_instance_id.fetchAdd(1, .monotonic));

        const g = try buildGlobals(store, module, imports, allocator);
        const global_handles = g.handles;
        const global_ptrs = g.ptrs;
        errdefer {
            for (global_handles) |*h| @constCast(h).deinit();
            allocator.free(global_handles);
            allocator.free(global_ptrs);
        }
        instance_alloc_count += 2;

        // 2. wrap the provided shared memory (increments refcount)
        var mem = Memory.initShared(shared);
        errdefer mem.deinit();
        instance_alloc_count += 1;

        const tables = try buildTables(module, imports, allocator);
        errdefer {
            for (tables) |*t| @constCast(t).deinit();
            allocator.free(tables);
        }

        // 3. resolve host functions
        const host_funcs = try allocator.alloc(HostFunc, module.imported_funcs.len);
        errdefer allocator.free(host_funcs);
        instance_alloc_count += 1;

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
            .globals = global_ptrs,
            .memory = &mem,
            .tables = tables,
        };

        // 4. segment dropped flags
        const data_segments_dropped = try allocator.alloc(bool, module.data_segments.len);
        errdefer allocator.free(data_segments_dropped);
        @memset(data_segments_dropped, false);
        instance_alloc_count += 1;

        // 4a. apply active data segments to linear memory (WASM spec §4.5.4)
        {
            const mem_bytes = mem.bytes();
            for (module.data_segments, 0..) |seg, i| {
                if (seg.mode != .active) continue;
                const dst: usize = std.math.cast(usize, seg.offset) orelse return error.DataSegmentOutOfBounds;
                const len: usize = seg.data.len;
                if (dst + len > mem_bytes.len) return error.DataSegmentOutOfBounds;
                @memcpy(mem_bytes[dst..][0..len], seg.data);
                data_segments_dropped[i] = true;
            }
        }

        const elem_segments_dropped = try allocator.alloc(bool, module.elem_segments.len);
        errdefer allocator.free(elem_segments_dropped);
        @memset(elem_segments_dropped, false);
        instance_alloc_count += 1;

        const cross_ctx = try buildCrossCtx(
            allocator,
            instance_id,
            store,
            module,
            global_ptrs,
            mem,
            tables,
            host_funcs,
            data_segments_dropped,
            elem_segments_dropped,
        );
        errdefer cross_ctx.deinit();

        try seedActiveElemSegments(module, tables, instance_id, cross_ctx.foreign_funcs, elem_segments_dropped);

        store.registerInstance();
        errdefer store.unregisterInstance();

        // Register shared memory capacity into the budget.
        store.memory_budget.recordSharedGrow(mem.byteLen());

        return .{
            .store = store,
            .instance_id = instance_id,
            .module = arc,
            .global_handles = global_handles,
            .globals = global_ptrs,
            .cross_ctx = cross_ctx,
            .memory = mem,
            .tables = tables,
            .host_funcs = host_funcs,
            .host_view = host_view,
            .data_segments_dropped = data_segments_dropped,
            .elem_segments_dropped = elem_segments_dropped,
            .vm = VM.init(allocator),
            .alloc_count = instance_alloc_count,
            .memory64 = module.memory64(),
        };
    }

    /// VM stack memory breakdown (bytes allocated, not in-use).
    pub const VmMemStats = struct {
        /// Bytes allocated for the persistent value stack.
        val_stack_bytes: usize,
        /// Number of slots in the value stack.
        val_stack_slots: usize,
        /// Bytes allocated for the persistent call stack.
        call_stack_bytes: usize,
        /// Number of frames in the call stack.
        call_stack_frames: usize,
        /// Number of allocations performed by the VM.
        vm_alloc_count: usize,
    };

    /// Return the byte sizes of the VM's persistent val_stack and call_stack.
    pub fn vmMemStats(self: *const Instance) VmMemStats {
        const CallFrameT = std.meta.Elem(@TypeOf(self.vm.call_stack));
        return .{
            .val_stack_bytes = self.vm.val_stack.len * @sizeOf(vm_mod.RawVal),
            .val_stack_slots = self.vm.val_stack.len,
            .call_stack_bytes = self.vm.call_stack.len * @sizeOf(CallFrameT),
            .call_stack_frames = self.vm.call_stack.len,
            .vm_alloc_count = self.vm.alloc_count,
        };
    }

    pub fn deinit(self: *Instance) void {
        const allocator = self.store.allocator;
        self.cross_ctx.deinit();
        for (self.global_handles) |*h| h.deinit();
        allocator.free(self.global_handles);
        allocator.free(self.globals);
        self.memory.deinit();
        for (self.tables) |*t| t.deinit();
        allocator.free(self.tables);
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
        // Ensure host_view pointers always reflect the live Instance address.
        self.host_view.memory = &self.memory;
        self.host_view.globals = self.globals;
        self.host_view.tables = self.tables;
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
            // Pass the full function index space so VM handlers can trigger lazy compilation.
            .functions = m.functions,
            .engine = self.store.engine,
            .module = m,
            .host_funcs = self.host_funcs,
            .tables = self.tables,
            .foreign_funcs = self.cross_ctx.foreign_funcs,
            .instance_id = self.instance_id,
            .func_type_indices = m.func_type_indices,
            .data_segments = m.data_segments,
            .data_segments_dropped = self.data_segments_dropped,
            .elem_segments = m.elem_segments,
            .elem_segments_dropped = self.elem_segments_dropped,
            .composite_types = m.composite_types,
            .struct_layouts = m.struct_layouts,
            .array_layouts = m.array_layouts,
            .type_ancestors = m.type_ancestors,
            .type_canonical = m.type_canonical,
            .memory_budget = budget_ptr,
            .mem_trace = self.mem_trace,
            .memory64 = self.memory64,
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
    pub fn call(self: *Instance, name: []const u8, args: []const RawVal) (module_mod.ModuleCompileError || Allocator.Error || error{ ExportNotFound, ExportNotCallable })!ExecResult {
        const m = self.module.value;
        const export_entry = m.exports.get(name) orelse return error.ExportNotFound;
        const func_index = switch (export_entry) {
            .function_index => |idx| idx,
            else => return error.ExportNotCallable,
        };
        return self.callByIndex(func_index, args);
    }

    pub fn callByIndex(self: *Instance, func_index: u32, args: []const RawVal) (module_mod.ModuleCompileError || Allocator.Error || error{ ExportNotFound, ExportNotCallable })!ExecResult {
        const m = self.module.value;
        if (func_index >= m.functions.len) return error.ExportNotFound;
        if (func_index < self.host_funcs.len) {
            // Re-exported host import function: call host function directly.
            const hf = self.host_funcs[func_index];
            const res_len = m.composite_types[m.func_type_indices[func_index]].func_type.results().len;
            const host_results = try self.store.allocator.alloc(RawVal, res_len);
            defer self.store.allocator.free(host_results);
            @memset(host_results, RawVal.fromBits64(0));

            self.host_view.memory = &self.memory;
            self.host_view.globals = self.globals;
            self.host_view.tables = self.tables;
            var ctx = host_mod.HostContext.init(self.store, &self.host_view, hf.host_data);
            hf.call(&ctx, args, host_results) catch |err| switch (err) {
                error.HostTrap => return .{ .trap = ctx.takeTrap() },
                error.OutOfMemory => return error.OutOfMemory,
            };
            try self.vm.saveLastResults(host_results);
            return .{ .ok = if (res_len > 0) host_results[0] else null };
        }
        // Lazily compile the function on first call.
        try m.compileFunctionAt(self.store.engine, func_index);
        const encoded = &m.functions[func_index].encoded;
        return self.vm.execute(encoded, args, self.execEnv());
    }

    pub fn lastResults(self: *const Instance) []const RawVal {
        return self.vm.lastResults();
    }

    pub fn foreignFuncAt(self: *const Instance, func_idx: u32) ?*const core.ForeignFunc {
        if (func_idx >= self.cross_ctx.foreign_funcs.len) return null;
        return &self.cross_ctx.foreign_funcs[func_idx];
    }

    pub fn exportGlobal(self: *const Instance, name: []const u8) ?SharedGlobal {
        const entry = self.module.value.exports.get(name) orelse return null;
        return switch (entry) {
            .global_index => |idx| if (idx < self.global_handles.len) self.global_handles[idx] else null,
            else => null,
        };
    }

    pub fn exportTable(self: *const Instance, name: []const u8) ?SharedTable {
        const entry = self.module.value.exports.get(name) orelse return null;
        return switch (entry) {
            .table_index => |idx| if (idx < self.tables.len) self.tables[idx] else null,
            else => null,
        };
    }

    pub fn exportMemory(self: *const Instance, name: []const u8) ?Memory {
        const entry = self.module.value.exports.get(name) orelse return null;
        return switch (entry) {
            .memory_index => self.memory,
            else => null,
        };
    }

    /// Execute the module's start function (WebAssembly spec §4.5.4).
    ///
    /// The start function is called automatically during instantiation to perform
    /// module-level initialization (e.g. Kotlin's _initializeModule which sets up
    /// string pools and field data).  Returns null if there is no start function.
    pub fn runStartFunction(self: *Instance) (module_mod.ModuleCompileError || Allocator.Error)!?ExecResult {
        const m = self.module.value;
        const start_idx = m.start_function orelse return null;
        try m.compileFunctionAt(self.store.engine, start_idx);
        const encoded = &m.functions[start_idx].encoded;
        return try self.vm.execute(encoded, &.{}, self.execEnv());
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
    pub fn initializeReactor(self: *Instance) (module_mod.ModuleCompileError || Allocator.Error || error{ ExportNotFound, ExportNotCallable })!?ExecResult {
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

// GC constant expression evaluator
// WebAssembly GC globals may use constant expressions that allocate GC objects
// (struct.new, array.new_fixed, etc.).  These cannot be evaluated at compile
// time because they require the GC heap.  This mini stack-machine interpreter
// is called during Instance.init for each global whose init_expr was deferred.

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
    initialized_globals: []const *Global,
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
                    gc_heap.writeField(gc_ref, struct_type, layout, @intCast(fi), SimdVal.fromScalar(stack[sp]));
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
                    gc_heap.writeElem(gc_ref, array_type, layout, @intCast(ei), SimdVal.fromScalar(stack[sp]));
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
                if (!builtin.single_threaded) {
                    std.log.err("evaluateGcConstExpr: unsupported opcode 0x{x}", .{@backingInt(info.code)});
                }
                return error.UnsupportedOpcode;
            },
        }
    }

    if (sp == 0) return error.StackUnderflow;
    return stack[sp - 1];
}

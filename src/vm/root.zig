const std = @import("std");
const ir = @import("../compiler/ir.zig");
const core = @import("core");
const host_mod = @import("../wasmz/host.zig");
const module_mod = @import("../wasmz/module.zig");
const store_mod = @import("../wasmz/store.zig");
const gc_mod = @import("./gc/root.zig");
const dispatch_mod = @import("dispatch.zig");

const EncodedFunction = ir.EncodedFunction;
const FunctionSlot = ir.FunctionSlot;
const engine_mod = @import("../engine/root.zig");
const Engine = engine_mod.Engine;
const Module = module_mod.Module;
const CompiledDataSegment = module_mod.CompiledDataSegment;
const CompiledElemSegment = module_mod.CompiledElemSegment;
const CompositeType = core.CompositeType;
const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const StructLayout = gc_mod.StructLayout;
const ArrayLayout = gc_mod.ArrayLayout;
const Memory = core.Memory;
const MemoryBudget = core.MemoryBudget;
pub const RawVal = core.raw.RawVal;
pub const Global = core.Global;
pub const Trap = core.Trap;
pub const TrapCode = core.TrapCode;
pub const HostFunc = host_mod.HostFunc;
const HostInstance = host_mod.HostInstance;

/// VM execute result either be void or Wasm trap
/// Allocation failures and other host environment errors are still propagated through Zig error unions (Allocator.Error).
pub const ExecResult = union(enum) {
    /// Normal return, ?RawVal is null for void functions
    ok: ?RawVal,
    /// Runtime trap (MemoryOutOfBounds, UnreachableCodeReached, etc.)
    trap: Trap,
};

pub const ExecEnv = struct {
    store: *Store,
    host_instance: *HostInstance,
    globals: []Global,
    /// Pointer into the Instance's Memory.  Always non-null; even a no-memory module uses
    /// an empty Memory so the pointer is valid.
    memory: *Memory,
    /// Full Wasm function index space (imports as `.import`, locals as `.pending`/`.encoded`).
    functions: []FunctionSlot,
    /// Engine reference used for lazy compilation of `.pending` function slots.
    engine: Engine,
    /// Pointer to the Module, used for lazy compilation of pending function slots.
    module: *Module,
    host_funcs: []const HostFunc,
    tables: [][]u32,
    func_type_indices: []const u32,
    data_segments: []const CompiledDataSegment,
    data_segments_dropped: []bool,
    elem_segments: []const CompiledElemSegment,
    elem_segments_dropped: []bool,
    composite_types: []const CompositeType,
    struct_layouts: []const ?StructLayout,
    array_layouts: []const ?ArrayLayout,
    /// Transitive ancestor lists for user-defined composite types.
    /// type_ancestors[i] lists all strict ancestor composite type indices of type i.
    /// Empty for types with no declared supertypes.
    type_ancestors: []const []const u32,
    /// Optional pointer to the Store's MemoryBudget for linear-memory limit enforcement.
    /// null when the Store has no limit configured.
    memory_budget: ?*MemoryBudget,
};

pub const VM = struct {
    allocator: Allocator,
    /// Persistent value stack, allocated once and reused across all execute() calls.
    /// Eliminates the per-call 16 MiB alloc/free overhead.
    val_stack: []RawVal = &[_]RawVal{},
    /// Persistent call-stack: fixed-size slice allocated once and reused.
    /// Using a raw slice + depth counter avoids ArrayList overhead on every push/pop.
    call_stack: []dispatch_mod.CallFrame = &[_]dispatch_mod.CallFrame{},

    pub fn init(allocator: Allocator) VM {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *VM) void {
        if (self.val_stack.len > 0) self.allocator.free(self.val_stack);
        if (self.call_stack.len > 0) self.allocator.free(self.call_stack);
        self.* = undefined;
    }

    /// Ensure persistent buffers are allocated (lazy, first call only).
    fn ensureBuffers(self: *VM) Allocator.Error!void {
        if (self.val_stack.len == 0) {
            self.val_stack = try self.allocator.alloc(RawVal, dispatch_mod.DEFAULT_VAL_STACK_SLOTS);
        }
        if (self.call_stack.len == 0) {
            self.call_stack = try self.allocator.alloc(dispatch_mod.CallFrame, dispatch_mod.DEFAULT_CALL_STACK_DEPTH);
        }
    }

    /// Execute an encoded function using M3 threaded dispatch.
    ///
    /// Sets up the entry call frame and dispatch state, then tail-calls the
    /// first handler.  When the handler chain terminates (via `handle_ret` or
    /// `handle_trap`), control returns here and the result is read from the
    /// dispatch state.
    pub fn execute(
        self: *VM,
        func: *const EncodedFunction,
        params: []const RawVal,
        env: ExecEnv,
    ) Allocator.Error!ExecResult {
        // Build the M3 ExecEnv (same layout, just a pointer wrapper).
        const m3_env = dispatch_mod.ExecEnv{
            .store = env.store,
            .host_instance = env.host_instance,
            .globals = env.globals,
            .memory = env.memory,
            .functions = env.functions,
            .engine = env.engine,
            .module = env.module,
            .host_funcs = env.host_funcs,
            .tables = env.tables,
            .func_type_indices = env.func_type_indices,
            .data_segments = env.data_segments,
            .data_segments_dropped = env.data_segments_dropped,
            .elem_segments = env.elem_segments,
            .elem_segments_dropped = env.elem_segments_dropped,
            .composite_types = env.composite_types,
            .struct_layouts = env.struct_layouts,
            .array_layouts = env.array_layouts,
            .type_ancestors = env.type_ancestors,
            .memory_budget = env.memory_budget,
        };

        // ── Ensure persistent buffers are allocated (lazy, first call only) ──
        try self.ensureBuffers();

        const entry_slots_len: usize = @max(
            @as(usize, @intCast(func.slots_len)),
            params.len,
        );
        // Entry frame slots start at offset 0 of the value stack.
        const entry_slots = self.val_stack[0..entry_slots_len];
        @memset(entry_slots, std.mem.zeroes(RawVal));

        for (params, 0..) |param, i| {
            entry_slots[i] = param;
        }

        // ── Build dispatch state — borrow persistent buffers ──────────────────
        var frame = dispatch_mod.DispatchState{
            .allocator = self.allocator,
            .val_stack = self.val_stack,
            .val_sp = entry_slots_len,
            .val_stack_owned = false, // VM owns val_stack
            .call_stack = self.call_stack.ptr,
            .call_depth = 0,
            .call_stack_cap = self.call_stack.len,
            .call_stack_owned = false, // VM owns call_stack
            .result = .{ .ok = null },
        };
        defer frame.deinit();

        // Push entry frame — cannot fail since depth=0 < cap=65536
        frame.callStackPush(.{
            .ip = func.code.ptr,
            .slots = entry_slots,
            .slots_sp_base = 0,
            .dst = null,
            .func = func,
        }) catch unreachable;

        const ip = func.code.ptr;
        const h: dispatch_mod.Handler = @as(*const dispatch_mod.Handler, @ptrCast(ip)).*;
        h(ip, entry_slots.ptr, &frame, &m3_env);

        return frame.result;
    }
};

/// dispatch.zig — M3 (Meta Machine) threaded-dispatch core types
///
/// Architecture overview:
///
///   Each encoded instruction occupies a variable-length slot in a flat byte
///   buffer:
///
///       [ handler: *const Handler (8 bytes, align 8) ] [ operands: N bytes ]
///
///   At the end of every handler the macro `next()` reads the handler pointer
///   from the *next* instruction and tail-calls it.  The Zig compiler emits a
///   true machine-level tail call when `@call(.always_tail, ...)` is used with
///   `callconv(.c)`.
///
///   Control never returns from a handler to its caller; instead execution
///   terminates when a special terminator handler (`handle_ret` / `handle_trap`)
///   writes its result into `DispatchState.result` and returns normally (no
///   tail-call).  `execute()` in root.zig calls the first handler and, once
///   that returns, reads the result.
const std = @import("std");
const ir = @import("../compiler/ir.zig");
const vm_root = @import("./root.zig");
const gc_mod = @import("gc/root.zig");
const core = @import("core");
const store_mod = @import("../wasmz/store.zig");
const host_mod = @import("../wasmz/host.zig");
const module_mod = @import("../wasmz/module.zig");
const encode = @import("../compiler/encode.zig");
const handlers_root = @import("./handlers/root.zig");

inline fn readOps(comptime T: type, ip: [*]u8) T {
    if (@sizeOf(T) == 0) return .{};
    const bytes = ip[HANDLER_SIZE..][0..@sizeOf(T)];
    return std.mem.bytesAsValue(T, bytes).*;
}

inline fn stride(comptime OpsT: type) usize {
    return HANDLER_SIZE + @sizeOf(OpsT);
}

const Allocator = std.mem.Allocator;
pub const RawVal = vm_root.RawVal;
pub const ExecResult = vm_root.ExecResult;
pub const Trap = vm_root.Trap;
pub const Global = vm_root.Global;
const EncodedFunction = ir.EncodedFunction;
const FunctionSlot = ir.FunctionSlot;
const engine_mod = @import("../engine/root.zig");
const Engine = engine_mod.Engine;
const Module = module_mod.Module;
const CatchHandlerEntry = ir.CatchHandlerEntry;
const Slot = ir.Slot;
const Store = store_mod.Store;
const GcHeap = gc_mod.GcHeap;
const GcRef = core.GcRef;
const StructLayout = gc_mod.StructLayout;
const ArrayLayout = gc_mod.ArrayLayout;
const Memory = core.Memory;
const MemoryBudget = core.MemoryBudget;
const CompositeType = core.CompositeType;
const HostFunc = host_mod.HostFunc;
pub const HostInstance = host_mod.HostInstance;
const CompiledDataSegment = module_mod.CompiledDataSegment;
const CompiledElemSegment = module_mod.CompiledElemSegment;

// ── Handler type ──────────────────────────────────────────────────────────────

/// The unified signature for every instruction handler.
///
/// Parameters:
///   ip    — pointer to the *current* instruction (i.e., the 8-byte handler
///            pointer field).  The handler reads its operands at ip[8..].
///            Note: ip may not be 8-byte aligned due to compact encoding.
///   slots — base pointer of the *current* call frame's register file.
///   frame — mutable shared dispatch state (call stack, EH stack, result).
///   env   — read-only execution environment (globals, memory, functions …).
///   r0    — integer accumulator: holds the most recent i32/i64 result.
///            Handlers that produce an integer result write it here AND into
///            the destination slot so that the next handler can read either.
///            Handlers that do not produce an integer result pass through the
///            incoming r0 unchanged.
///   fp0   — float accumulator: holds the most recent f32/f64 result
///            (f32 values are bit-cast to f64 for uniform storage).
///            Same write-both semantics as r0.
///
/// Calling convention: `.C` + `@call(.always_tail, …)` produces true TCO.
/// Because C calling convention is used the function must return `void`; the
/// execution result is communicated through `frame.result`.
///
/// The r0/fp0 accumulators mirror the wasm3 M3 model: they allow the CPU to
/// keep the top-of-stack integer/float value in a hardware register across
/// instruction boundaries, avoiding a slot load on every back-to-back
/// arithmetic instruction.
pub const Handler = *const fn (
    ip: [*]u8,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
    r0: u64,
    fp0: f64,
) callconv(.c) void;

// ── Execution environment (read-only) ─────────────────────────────────────────

/// Read-only view of the module instance, passed by pointer to every handler.
/// `functions` covers the *full* Wasm function index space (imports + locals).
/// Handlers use host_funcs.len to split host vs. local calls; for local calls
/// they index into `functions` directly and trigger lazy compilation when needed.
pub const ExecEnv = struct {
    store: *Store,
    host_instance: *HostInstance,
    globals: []Global,
    memory: *Memory,
    /// Full Wasm function index space (imports as `.import`, locals as `.pending`/`.encoded`).
    /// Mutable so that handlers can compile `.pending` slots in place.
    functions: []FunctionSlot,
    /// Engine reference, used to compile `.pending` function slots on first call.
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
    type_ancestors: []const []const u32,
    memory_budget: ?*MemoryBudget,
    /// When true, memory.grow events log RSS snapshots to stderr.
    /// Controlled by the --mem-trace CLI flag.
    mem_trace: bool = false,
};

// ── Call / EH frame ───────────────────────────────────────────────────────────

/// One active call frame.
///
/// In the M3 model `ip` advances through the flat `code[]` buffer rather than
/// through an `ops[]` slice; there is no integer PC index.
pub const CallFrame = struct {
    /// Pointer to the *current instruction* in the callee's code buffer.
    /// Updated before pushing a new frame so that when we pop back we know
    /// which instruction to resume.
    /// For the entry frame this is set to the first instruction (code.ptr).
    ip: [*]u8,
    /// Slice into DispatchState.val_stack for this frame's register file.
    /// Not owned; freed by restoring val_sp to slots_sp_base on pop.
    slots: []RawVal,
    /// The val_sp value before this frame's slots were allocated.
    /// Restored on pop to free the frame's register file in O(1).
    slots_sp_base: usize,
    /// Slot in the *caller* frame that receives the return value, or null for
    /// void functions (or the top-level entry frame).
    dst: ?Slot,
    /// Owned-slice reference to the callee's EncodedFunction (not owned here;
    /// the EncodedFunction outlives the frame).
    func: *const EncodedFunction,
};

/// One active try_table handler region.
pub const EhFrame = struct {
    /// call_stack depth at which this try region was registered.
    call_stack_depth: usize,
    /// Slice into the owning EncodedFunction's catch_handler_tables.
    handlers_start: u32,
    handlers_len: u32,
    /// Pointer to the owning function's catch_handler_tables slice so we do
    /// not need to carry the func pointer separately.
    handler_table: []const CatchHandlerEntry,
};

// ── Dispatch state (mutable, shared across all handlers in one invocation) ────

/// Default value-stack size in RawVal slots (8 bytes each).
/// Grows by doubling on overflow up to MAX_VAL_STACK_SLOTS.
pub const DEFAULT_VAL_STACK_SLOTS: usize = 1 * 1024;

/// Hard upper bound for the value stack (prevents infinite growth).
/// 16 Mi slots = 128 MiB — no real-world module should approach this.
pub const MAX_VAL_STACK_SLOTS: usize = 16 * 1024 * 1024;

/// Default call-stack depth (max simultaneous live Wasm call frames).
/// 1024 frames covers realistic recursion.  Grows by doubling on overflow.
pub const DEFAULT_CALL_STACK_DEPTH: usize = 1024;

/// Hard upper bound for the call stack.
pub const MAX_CALL_STACK_DEPTH: usize = 1024 * 1024;

/// Mutable state shared by every handler in a single `execute()` invocation.
pub const DispatchState = struct {
    /// Fixed-size call stack: pre-allocated slice + depth counter.
    /// Avoids ArrayList overhead (no allocator parameter on push, no capacity
    /// check path that may reallocate).  Owned by the VM and reused across calls.
    call_stack: [*]CallFrame = undefined,
    call_depth: usize = 0,
    call_stack_cap: usize = 0,
    eh_stack: std.ArrayListUnmanaged(EhFrame) = .empty,
    /// Written by `handle_ret` / `handle_trap` terminators; read by `execute()`.
    result: ExecResult = .{ .ok = null },
    allocator: Allocator,
    /// Flat contiguous value stack shared by all frames.
    /// Frames are allocated from this in O(1) by bumping val_sp.
    val_stack: []RawVal = &[_]RawVal{},
    /// Stack pointer: index of the next free slot in val_stack.
    val_sp: usize = 0,
    /// When false, deinit() does NOT free val_stack (ownership stays with the caller).
    /// Set to false when the val_stack is borrowed from a persistent VM.
    val_stack_owned: bool = true,
    /// When false, deinit() does NOT free call_stack (ownership stays with the VM).
    call_stack_owned: bool = true,
    /// Back-pointer to the owning VM, used for dynamic stack growth.
    /// null when the DispatchState owns its stacks directly (non-persistent mode).
    vm: ?*vm_root.VM = null,

    // ── Cached linear memory base/length ─────────────────────────────────
    // Avoids the `env.memory.bytes()` call (tagged-union dispatch + pointer
    // chase) on every memory load/store handler.  Updated by `memory.grow`.
    mem_base: [*]u8 = undefined,
    mem_len: usize = 0,

    /// Refresh the cached mem_base/mem_len from the canonical Memory object.
    /// Called once at execute() entry and after every successful memory.grow.
    pub inline fn refreshMemCache(self: *DispatchState, memory: *const Memory) void {
        const live = memory.bytes();
        self.mem_base = live.ptr;
        self.mem_len = live.len;
    }

    /// Return the cached memory slice without going through Memory.bytes().
    pub inline fn memSlice(self: *const DispatchState) []u8 {
        return self.mem_base[0..self.mem_len];
    }

    pub fn deinit(self: *DispatchState) void {
        // With val_stack, frames do not own their slots — nothing to free per-frame.
        if (self.call_stack_owned and self.call_stack_cap > 0)
            self.allocator.free(self.call_stack[0..self.call_stack_cap]);
        self.eh_stack.deinit(self.allocator);
        if (self.val_stack_owned and self.val_stack.len > 0) self.allocator.free(self.val_stack);
    }

    /// Push a call frame.  Grows the call stack (doubling) if needed.
    /// Returns error.StackOverflow only when MAX_CALL_STACK_DEPTH is reached.
    pub inline fn callStackPush(self: *DispatchState, frame: CallFrame) error{ StackOverflow, OutOfMemory }!void {
        if (self.call_depth >= self.call_stack_cap) {
            try self.growCallStack();
        }
        self.call_stack[self.call_depth] = frame;
        self.call_depth += 1;
    }

    /// Grow the call stack by doubling its capacity.
    /// Updates both this DispatchState and the owning VM (if any).
    fn growCallStack(self: *DispatchState) error{ StackOverflow, OutOfMemory }!void {
        const old_cap = self.call_stack_cap;
        if (old_cap >= MAX_CALL_STACK_DEPTH) return error.StackOverflow;
        const new_cap = @min(old_cap *| 2, MAX_CALL_STACK_DEPTH);
        const old_slice = self.call_stack[0..old_cap];
        const new_slice = try self.allocator.realloc(old_slice, new_cap);
        self.call_stack = new_slice.ptr;
        self.call_stack_cap = new_cap;
        // Sync back to the owning VM so subsequent execute() calls see the grown buffer.
        if (self.vm) |v| {
            v.call_stack = new_slice;
        }
    }

    /// Pop the top call frame.  Caller must ensure depth > 0.
    pub inline fn callStackPop(self: *DispatchState) CallFrame {
        self.call_depth -= 1;
        return self.call_stack[self.call_depth];
    }

    /// Return a pointer to the top call frame.  Caller must ensure depth > 0.
    pub inline fn callStackTop(self: *DispatchState) *CallFrame {
        return &self.call_stack[self.call_depth - 1];
    }

    /// Return a pointer to a frame by index.
    pub inline fn callStackAt(self: *DispatchState, idx: usize) *CallFrame {
        return &self.call_stack[idx];
    }

    /// Allocate `n` slots from the value stack.
    /// Grows the value stack (doubling) if needed.
    /// Returns error.StackOverflow only when MAX_VAL_STACK_SLOTS is reached.
    pub inline fn valStackAlloc(self: *DispatchState, n: usize) error{ StackOverflow, OutOfMemory }![]RawVal {
        if (self.val_sp + n > self.val_stack.len) {
            try self.growValStack(n);
        }
        const slice = self.val_stack[self.val_sp .. self.val_sp + n];
        self.val_sp += n;
        return slice;
    }

    /// Grow the value stack so that at least `needed` more slots are available.
    /// Doubles until large enough, then fixes up all live CallFrame.slots pointers.
    fn growValStack(self: *DispatchState, needed: usize) error{ StackOverflow, OutOfMemory }!void {
        const required = self.val_sp + needed;
        if (required > MAX_VAL_STACK_SLOTS) return error.StackOverflow;

        var new_cap = @max(self.val_stack.len *| 2, DEFAULT_VAL_STACK_SLOTS);
        while (new_cap < required) new_cap *|= 2;
        new_cap = @min(new_cap, MAX_VAL_STACK_SLOTS);

        const old_ptr = self.val_stack.ptr;
        const new_slice = try self.allocator.realloc(self.val_stack, new_cap);
        self.val_stack = new_slice;

        // Fix up every live CallFrame.slots pointer (they are sub-slices of the old buffer).
        if (new_slice.ptr != old_ptr) {
            const base_new: usize = @intFromPtr(new_slice.ptr);
            const base_old: usize = @intFromPtr(old_ptr);
            for (0..self.call_depth) |i| {
                const f = &self.call_stack[i];
                const old_frame_ptr: usize = @intFromPtr(f.slots.ptr);
                const offset = old_frame_ptr - base_old;
                const new_frame_ptr: [*]RawVal = @ptrFromInt(base_new + offset);
                f.slots = new_frame_ptr[0..f.slots.len];
            }
        }

        // Sync back to the owning VM.
        if (self.vm) |v| {
            v.val_stack = new_slice;
        }
    }

    /// Free the top `n` slots by restoring val_sp.
    pub inline fn valStackFree(self: *DispatchState, sp_base: usize) void {
        self.val_sp = sp_base;
    }

    /// Capture the current Wasm call stack into a freshly-allocated slice of
    /// `StackFrame` values, ordered innermost-first (index 0 = currently
    /// executing function, last index = entry frame).
    ///
    /// Returns null if allocation fails (the trap is still reported; the stack
    /// trace is just omitted).
    pub fn captureStackTrace(self: *const DispatchState) ?[]core.StackFrame {
        if (self.call_depth == 0) return null;
        const frames = self.allocator.alloc(core.StackFrame, self.call_depth) catch return null;
        var i: usize = 0;
        // Walk innermost → outermost (call_depth-1 downto 0)
        while (i < self.call_depth) : (i += 1) {
            const cf = &self.call_stack[self.call_depth - 1 - i];
            const code_offset: usize = if (@intFromPtr(cf.ip) >= @intFromPtr(cf.func.code.ptr))
                @intFromPtr(cf.ip) - @intFromPtr(cf.func.code.ptr)
            else
                0;
            frames[i] = .{
                .func_idx = cf.func.func_idx,
                .code_offset = code_offset,
            };
        }
        return frames;
    }
};

// ── Dispatch helper ───────────────────────────────────────────────────────────

/// Advance `ip` by `stride` bytes and tail-call the handler embedded at the
/// new position.
///
/// This must be called at the *end* of every non-terminating handler with
/// `stride = @sizeOf(*const Handler) + @sizeOf(Operands)` for that instruction.
///
/// Using `inline` ensures the tail call is always visible to the Zig backend.
pub inline fn next(
    ip: [*]u8,
    cur_stride: usize,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
    r0: u64,
    fp0: f64,
) void {
    countOp("total");
    countOp("dispatch_next");
    const next_ip = ip + cur_stride;
    const h: Handler = std.mem.bytesAsValue(Handler, next_ip[0..@sizeOf(Handler)]).*;
    @call(.always_tail, h, .{ next_ip, slots, frame, env, r0, fp0 });
}

/// Advance `ip` by `stride` bytes, read next handler, and check if it's a hot
/// local_set handler that can be fused with this operation.
/// If fused, execute local_set inline and skip one dispatch.
/// Otherwise, dispatch normally.
pub inline fn nextWithLocalSetFusion(
    ip: [*]u8,
    cur_stride: usize,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
    r0: u64,
    fp0: f64,
    value: RawVal,
) void {
    countOp("total");
    const next_ip = ip + cur_stride;
    const h: Handler = std.mem.bytesAsValue(Handler, next_ip[0..@sizeOf(Handler)]).*;

    // Check if next handler is handle_local_set
    const is_local_set = @intFromPtr(h) == @intFromPtr(&handlers_root.handle_local_set);
    if (is_local_set) {
        // Fused: inline execute local_set and skip one dispatch
        countOp("dispatch_next");
        const local_set_ops = readOps(encode.OpsLocalSet, next_ip);
        slots[local_set_ops.local] = value;

        // Advance to the instruction after local_set
        const next_stride = stride(encode.OpsLocalSet);
        const after_next_ip = next_ip + next_stride;
        const h2: Handler = std.mem.bytesAsValue(Handler, after_next_ip[0..@sizeOf(Handler)]).*;
        @call(.always_tail, h2, .{ after_next_ip, slots, frame, env, r0, fp0 });
    } else {
        // Not fused: dispatch normally
        countOp("dispatch_next");
        @call(.always_tail, h, .{ next_ip, slots, frame, env, r0, fp0 });
    }
}

/// Convenience: read the handler pointer embedded at `ip` and tail-call it
/// directly (no stride advance).  Used when a handler modifies `ip` externally
/// (jumps, calls) and wants to dispatch to whatever instruction `ip` now points
/// to.
pub inline fn dispatch(
    ip: [*]u8,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
    r0: u64,
    fp0: f64,
) void {
    countOp("total");
    countOp("dispatch_dispatch");
    const h: Handler = std.mem.bytesAsValue(Handler, ip[0..@sizeOf(Handler)]).*;
    @call(.always_tail, h, .{ ip, slots, frame, env, r0, fp0 });
}

// ── Runtime op counters (for profiling) ──────────────────────────────────────
//
// Only compiled in when `-Dprofiling=true` (i.e. `make build-debug`).
// In release builds this struct is zero-sized and all increment calls are no-ops.

const build_options = @import("build_options");

pub const op_counts_enabled = build_options.profiling;

pub const OpCounts = if (op_counts_enabled) struct {
    copy: u64 = 0,
    local_get: u64 = 0,
    local_set: u64 = 0,
    copy_jump_if_nz: u64 = 0,
    jump: u64 = 0,
    call_ret: u64 = 0,
    global: u64 = 0,
    constant: u64 = 0,
    imm: u64 = 0,
    imm_r: u64 = 0,
    unary: u64 = 0,
    conv: u64 = 0,
    cmp: u64 = 0,
    binop: u64 = 0,
    ref_select: u64 = 0,
    mem_table: u64 = 0,
    simd: u64 = 0,
    atomic: u64 = 0,
    trap_unreachable: u64 = 0,
    i32_to_local: u64 = 0,
    i64_to_local: u64 = 0,
    i32_imm_to_local: u64 = 0,
    i64_imm_to_local: u64 = 0,
    i32_local_inplace: u64 = 0,
    i64_local_inplace: u64 = 0,
    const_to_local: u64 = 0,
    load_to_local: u64 = 0,
    global_to_local: u64 = 0,
    tee_local: u64 = 0,
    cmp_to_local: u64 = 0,
    misc: u64 = 0,
    total: u64 = 0,
    dispatch_dispatch: u64 = 0,
    dispatch_next: u64 = 0,
} else struct {};

pub var op_counts: OpCounts = .{};

/// Increment a field of `op_counts` by 1. Compiles to a no-op when profiling is disabled.
pub inline fn countOp(comptime field: []const u8) void {
    if (op_counts_enabled) {
        @field(op_counts, field) += 1;
    }
}

// ── Instruction operand sizes ─────────────────────────────────────────────────
//
// Each instruction in the code stream looks like:
//
//   [ *Handler (8 bytes) ] [ Operands (0..N bytes) ]
//
// The stride of an instruction equals 8 + @sizeOf(Operands).
// All operand structs must be `extern` so their layout is deterministic.

pub const HANDLER_SIZE: usize = @sizeOf(Handler);

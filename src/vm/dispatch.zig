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
const vm_root = @import("root.zig");
const gc_mod = @import("gc/root.zig");
const core = @import("core");
const store_mod = @import("../wasmz/store.zig");
const host_mod = @import("../wasmz/host.zig");
const module_mod = @import("../wasmz/module.zig");

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
///
/// Calling convention: `.C` + `@call(.always_tail, …)` produces true TCO.
/// Because C calling convention is used the function must return `void`; the
/// execution result is communicated through `frame.result`.
pub const Handler = *const fn (
    ip: [*]u8,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
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
/// 128K slots = 1 MiB.  Grows by doubling on overflow up to MAX_VAL_STACK_SLOTS.
pub const DEFAULT_VAL_STACK_SLOTS: usize = 128 * 1024;

/// Hard upper bound for the value stack (prevents infinite growth).
/// 16 Mi slots = 128 MiB — no real-world module should approach this.
pub const MAX_VAL_STACK_SLOTS: usize = 16 * 1024 * 1024;

/// Default call-stack depth (max simultaneous live Wasm call frames).
/// 4096 frames covers realistic recursion.  Grows by doubling on overflow.
pub const DEFAULT_CALL_STACK_DEPTH: usize = 4096;

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
    stride: usize,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
) void {
    const next_ip = ip + stride;
    const h: Handler = std.mem.bytesAsValue(Handler, next_ip[0..@sizeOf(Handler)]).*;
    @call(.always_tail, h, .{ next_ip, slots, frame, env });
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
) void {
    const h: Handler = std.mem.bytesAsValue(Handler, ip[0..@sizeOf(Handler)]).*;
    @call(.always_tail, h, .{ ip, slots, frame, env });
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

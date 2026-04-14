/// handlers_call.zig — M3 threaded-dispatch call instruction handlers
///
/// call, call_indirect, return_call, return_call_indirect, call_ref, return_call_ref
const std = @import("std");
const ir = @import("../compiler/ir.zig");
const encode = @import("../compiler/encode.zig");
const dispatch = @import("dispatch.zig");
const core = @import("core");
const store_mod = @import("../wasmz/store.zig");
const host_mod = @import("../wasmz/host.zig");
const module_mod = @import("../wasmz/module.zig");

const Allocator = std.mem.Allocator;
const RawVal = dispatch.RawVal;
const Trap = dispatch.Trap;
const Handler = dispatch.Handler;
const DispatchState = dispatch.DispatchState;
const ExecEnv = dispatch.ExecEnv;
const CallFrame = dispatch.CallFrame;
const EncodedFunction = ir.EncodedFunction;
const FunctionSlot = ir.FunctionSlot;
const Store = store_mod.Store;
const HostFunc = host_mod.HostFunc;
const HostContext = host_mod.HostContext;

const HANDLER_SIZE = dispatch.HANDLER_SIZE;

const profiling = @import("../utils/profiling.zig");

// ── Helpers ──────────────────────────────────────────────────────────────────

inline fn readOps(comptime T: type, ip: [*]u8) T {
    if (@sizeOf(T) == 0) return .{};
    const bytes = ip[HANDLER_SIZE..][0..@sizeOf(T)];
    return std.mem.bytesAsValue(T, bytes).*;
}

inline fn stride(comptime OpsT: type) usize {
    return HANDLER_SIZE + @sizeOf(OpsT);
}

inline fn trapReturn(frame: *DispatchState, code: core.TrapCode) void {
    frame.result = .{ .trap = Trap.fromTrapCode(code) };
}

/// Ensure a local function slot is compiled, triggering lazy compilation if needed.
/// Returns a pointer to the EncodedFunction on success, or writes a trap and returns null.
/// `func_idx` is in the full Wasm function index space (including imports).
inline fn ensureLocalCompiled(func_idx: u32, env: *const ExecEnv, frame: *DispatchState) ?*const EncodedFunction {
    const slot = &env.functions[func_idx];
    switch (slot.*) {
        .encoded => |*ef| return ef,
        .pending => {
            env.module.compileFunctionAt(env.engine, func_idx) catch {
                trapReturn(frame, .OutOfMemory);
                return null;
            };
            return &env.functions[func_idx].encoded;
        },
        .import => unreachable, // imports are dispatched via host_funcs
    }
}

/// Allocate callee slots from the value stack.
/// Only zeroes the locals range [args_len .. args_len + locals_count) instead of the
/// entire frame.  The argument slots [0..args_len) are overwritten by the caller
/// immediately after, and the temporary slots beyond locals are SSA-style (always
/// written before read), so neither needs zeroing.
/// Returns a slice into the value stack, or null on stack overflow / OOM (trap written).
inline fn allocCalleeSlots(frame: *DispatchState, n: usize, args_len: usize, locals_count: u16) ?[]RawVal {
    const s = frame.valStackAlloc(n) catch |err| {
        trapReturn(frame, switch (err) {
            error.OutOfMemory => .OutOfMemory,
            error.StackOverflow => .StackOverflow,
        });
        return null;
    };
    // Only zero-initialise the Wasm local variables (spec requirement).
    // args_len slots are overwritten by arg copy; temp slots beyond locals are SSA.
    const locals_start = args_len;
    const locals_end = locals_start + @as(usize, locals_count);
    if (locals_end > locals_start and locals_end <= s.len) {
        @memset(s[locals_start..locals_end], std.mem.zeroes(RawVal));
    }
    return s;
}

/// Maximum number of params/results to use a stack buffer for (avoids heap alloc for most host calls).
const HOST_CALL_INLINE_MAX = 16;

/// Invoke a host function, returning the result. On failure writes trap or returns OOM.
/// Uses a stack buffer for small argument/result counts to avoid heap allocation overhead.
fn invokeHostCallInline(
    allocator: Allocator,
    store: *Store,
    host_instance: *dispatch.HostInstance,
    host_func: HostFunc,
    arg_slots: []align(1) const ir.Slot,
    slots: [*]RawVal,
    result_len: usize,
    frame: *DispatchState,
) ?RawVal {
    // Fast path: use stack buffers for small argument/result counts (common for WASI calls).
    if (arg_slots.len <= HOST_CALL_INLINE_MAX and result_len <= HOST_CALL_INLINE_MAX) {
        var params_buf: [HOST_CALL_INLINE_MAX]RawVal = undefined;
        var results_buf: [HOST_CALL_INLINE_MAX]RawVal = std.mem.zeroes([HOST_CALL_INLINE_MAX]RawVal);

        const host_params = params_buf[0..arg_slots.len];
        const host_results = results_buf[0..result_len];

        for (arg_slots, 0..) |arg_slot, i| {
            host_params[i] = slots[arg_slot];
        }

        var ctx = HostContext.init(store, host_instance, host_func.host_data);
        host_func.call(&ctx, host_params, host_results) catch |err| {
            switch (err) {
                error.HostTrap => {
                    frame.result = .{ .trap = ctx.takeTrap() };
                    return null;
                },
                error.OutOfMemory => {
                    trapReturn(frame, .OutOfMemory);
                    return null;
                },
            }
        };

        return if (result_len > 0) host_results[0] else null;
    }

    // Slow path: heap allocation for large argument/result counts.
    const host_params = allocator.alloc(RawVal, arg_slots.len) catch {
        trapReturn(frame, .OutOfMemory);
        return null;
    };
    for (arg_slots, 0..) |arg_slot, i| {
        host_params[i] = slots[arg_slot];
    }

    const host_results = allocator.alloc(RawVal, result_len) catch {
        allocator.free(host_params);
        trapReturn(frame, .OutOfMemory);
        return null;
    };
    @memset(host_results, std.mem.zeroes(RawVal));

    var ctx = HostContext.init(store, host_instance, host_func.host_data);
    host_func.call(&ctx, host_params, host_results) catch |err| {
        const ret_val: ?RawVal = switch (err) {
            error.HostTrap => {
                frame.result = .{ .trap = ctx.takeTrap() };
                allocator.free(host_params);
                allocator.free(host_results);
                return null;
            },
            error.OutOfMemory => {
                allocator.free(host_params);
                allocator.free(host_results);
                trapReturn(frame, .OutOfMemory);
                return null;
            },
        };
        _ = ret_val;
    };

    const ret = if (result_len > 0) host_results[0] else null;
    allocator.free(host_params);
    allocator.free(host_results);
    return ret;
}

// ── call ─────────────────────────────────────────────────────────────────────

pub fn handle_call(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsCall, ip);

    // Read inline arg slots directly from the bytecode stream (zero pointer chasing)
    const arg_slots = encode.readInlineArgs(encode.OpsCall, ip, ops.args_len);
    const instr_stride = encode.varStride(encode.OpsCall, ops.args_len);

    if (ops.func_idx < env.host_funcs.len) {
        // Host function call
        const host_func = env.host_funcs[ops.func_idx];
        const result_len = env.composite_types[env.func_type_indices[ops.func_idx]].func_type.results().len;

        const ret_val = invokeHostCallInline(frame.allocator, env.store, env.host_instance, host_func, arg_slots, slots, result_len, frame);

        // invokeHostCallInline returns null on failure (trap already written to frame.result).
        // It also returns null for successful void calls (result_len == 0).
        // Check the result tag to distinguish trap from void success.
        switch (frame.result) {
            .trap => return,
            .ok => {},
        }

        if (ops.dst_valid != 0) {
            if (ret_val) |rv| {
                slots[ops.dst] = rv;
            }
        }
        dispatch.next(ip, instr_stride, slots, frame, env);
    } else {
        // ── Phase 0: already done above (readOps + inline args) ──
        var t = profiling.ScopedTimer.start();
        t.lap(&profiling.call_prof.ns_read_ops);

        // ── Phase 1a: ensure compiled (lazy JIT) ──────────────────────────────
        const was_pending = if (profiling.enabled) switch (env.functions[ops.func_idx]) {
            .pending => true,
            else => false,
        } else false;
        const callee = ensureLocalCompiled(ops.func_idx, env, frame) orelse return;
        t.lap(&profiling.call_prof.ns_ensure_compiled);
        if (profiling.enabled and was_pending) profiling.call_prof.lazy_compiles += 1;

        // ── Phase 1b: allocate + zero callee slots ─────────────────────────────
        const callee_slots_len: usize = @max(@as(usize, @intCast(callee.slots_len)), arg_slots.len);
        const sp_base = frame.val_sp;
        const callee_slots = allocCalleeSlots(frame, callee_slots_len, arg_slots.len, callee.locals_count) orelse return;
        t.lap(&profiling.call_prof.ns_alloc_slots);
        if (profiling.enabled) profiling.call_prof.slots_len_sum += callee_slots_len;
        // Re-derive caller slots: valStackAlloc may have grown the buffer,
        // invalidating the handler's original `slots` parameter.
        const caller_slots_profiled = frame.callStackTop().slots.ptr;

        // ── Phase 2: copy args ─────────────────────────────────────────────────
        for (arg_slots, 0..) |arg_slot, i| {
            callee_slots[i] = caller_slots_profiled[arg_slot];
        }
        t.lap(&profiling.call_prof.ns_copy_args);

        // ── Phase 3: save ip, push frame, dispatch ────────────────────────────
        const cur = frame.callStackTop();
        cur.ip = ip + instr_stride;
        const callee_dst: ?ir.Slot = if (ops.dst_valid != 0) @intCast(ops.dst) else null;
        frame.callStackPush(.{
            .ip = callee.code.ptr,
            .slots = callee_slots,
            .slots_sp_base = sp_base,
            .dst = callee_dst,
            .func = callee,
        }) catch |err| {
            frame.valStackFree(sp_base);
            trapReturn(frame, switch (err) {
                error.OutOfMemory => .OutOfMemory,
                error.StackOverflow => .StackOverflow,
            });
            return;
        };
        t.lap(&profiling.call_prof.ns_push_dispatch);
        if (profiling.enabled) profiling.call_prof.calls += 1;

        dispatch.dispatch(callee.code.ptr, callee_slots.ptr, frame, env);
    }
}

// ── call_indirect ────────────────────────────────────────────────────────────

pub fn handle_call_indirect(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsCallIndirect, ip);

    // Read inline arg slots directly from the bytecode stream
    const arg_slots = encode.readInlineArgs(encode.OpsCallIndirect, ip, ops.args_len);
    const instr_stride = encode.varStride(encode.OpsCallIndirect, ops.args_len);

    // 1. Read runtime table index from slot
    const raw_index = slots[ops.index].readAs(u32);

    // 2. Bounds check against the table
    if (ops.table_index >= env.tables.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    const table = env.tables[ops.table_index];
    if (raw_index >= table.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }

    // 3. Resolve callee func_idx from the table
    const callee_func_idx = table[raw_index];

    // 4. Null-element check
    if (callee_func_idx == std.math.maxInt(u32)) {
        trapReturn(frame, .IndirectCallToNull);
        return;
    }

    // 5. Signature check
    if (callee_func_idx >= env.func_type_indices.len) {
        trapReturn(frame, .BadSignature);
        return;
    }
    if (env.func_type_indices[callee_func_idx] != ops.type_index) {
        trapReturn(frame, .BadSignature);
        return;
    }

    // 6. Dispatch
    if (callee_func_idx < env.host_funcs.len) {
        const host_func = env.host_funcs[callee_func_idx];
        const result_len = env.composite_types[env.func_type_indices[callee_func_idx]].func_type.results().len;

        const ret_val = invokeHostCallInline(frame.allocator, env.store, env.host_instance, host_func, arg_slots, slots, result_len, frame);

        switch (frame.result) {
            .trap => return,
            .ok => {},
        }

        if (ops.dst_valid != 0) {
            if (ret_val) |rv| {
                slots[ops.dst] = rv;
            }
        }
        dispatch.next(ip, instr_stride, slots, frame, env);
    } else {
        const callee = ensureLocalCompiled(callee_func_idx, env, frame) orelse return;
        const callee_slots_len: usize = @max(@as(usize, @intCast(callee.slots_len)), arg_slots.len);

        const sp_base = frame.val_sp;
        const callee_slots = allocCalleeSlots(frame, callee_slots_len, arg_slots.len, callee.locals_count) orelse return;
        // Re-derive caller slots: valStackAlloc may have grown the buffer,
        // invalidating the handler's original `slots` parameter.
        const caller_slots = frame.callStackTop().slots.ptr;

        for (arg_slots, 0..) |arg_slot, i| {
            callee_slots[i] = caller_slots[arg_slot];
        }

        const cur = frame.callStackTop();
        cur.ip = ip + instr_stride;

        const callee_dst: ?ir.Slot = if (ops.dst_valid != 0) @intCast(ops.dst) else null;

        frame.callStackPush(.{
            .ip = callee.code.ptr,
            .slots = callee_slots,
            .slots_sp_base = sp_base,
            .dst = callee_dst,
            .func = callee,
        }) catch |err| {
            frame.valStackFree(sp_base);
            trapReturn(frame, switch (err) {
                error.OutOfMemory => .OutOfMemory,
                error.StackOverflow => .StackOverflow,
            });
            return;
        };

        dispatch.dispatch(callee.code.ptr, callee_slots.ptr, frame, env);
    }
}

// ── return_call ──────────────────────────────────────────────────────────────

pub fn handle_return_call(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsReturnCall, ip);

    // Read inline arg slots directly from the bytecode stream
    const arg_slots = encode.readInlineArgs(encode.OpsReturnCall, ip, ops.args_len);

    const frame_idx = frame.call_depth - 1;

    if (ops.func_idx < env.host_funcs.len) {
        // Tail call to host function
        const host_func = env.host_funcs[ops.func_idx];
        const result_len = env.composite_types[env.func_type_indices[ops.func_idx]].func_type.results().len;

        const ret_val = invokeHostCallInline(frame.allocator, env.store, env.host_instance, host_func, arg_slots, slots, result_len, frame);

        switch (frame.result) {
            .trap => return,
            .ok => {},
        }

        // Pop current frame and return result to caller's caller
        const popped = frame.callStackPop();
        frame.valStackFree(popped.slots_sp_base);

        if (frame.call_depth == 0) {
            frame.result = .{ .ok = ret_val };
            return;
        }

        const caller_idx = frame.call_depth - 1;
        if (popped.dst) |dst_slot| {
            if (ret_val) |rv| {
                frame.callStackAt(caller_idx).slots[dst_slot] = rv;
            }
        }

        // Resume caller
        const caller = frame.callStackAt(caller_idx);
        dispatch.dispatch(caller.ip, caller.slots.ptr, frame, env);
    } else {
        // Tail call to local function: replace current frame
        const callee = ensureLocalCompiled(ops.func_idx, env, frame) orelse return;
        const callee_slots_len: usize = @max(@as(usize, @intCast(callee.slots_len)), arg_slots.len);

        // Allocate new slots before freeing old ones (copy args from old slots)
        const old_sp_base = frame.callStackAt(frame_idx).slots_sp_base;
        // Restore SP to where old frame started so new frame reuses that space
        frame.valStackFree(old_sp_base);
        const sp_base = frame.val_sp; // same as old_sp_base
        const callee_slots = allocCalleeSlots(frame, callee_slots_len, arg_slots.len, callee.locals_count) orelse return;
        // Re-derive caller slots: valStackAlloc may have grown the buffer,
        // invalidating the handler's original `slots` parameter.
        const caller_slots = frame.callStackTop().slots.ptr;

        for (arg_slots, 0..) |arg_slot, i| {
            callee_slots[i] = caller_slots[arg_slot];
        }

        // Preserve the dst from current frame (return to caller's caller)
        const tail_dst = frame.callStackAt(frame_idx).dst;

        // Replace current frame with callee
        frame.callStackAt(frame_idx).* = .{
            .ip = callee.code.ptr,
            .slots = callee_slots,
            .slots_sp_base = sp_base,
            .dst = tail_dst,
            .func = callee,
        };

        dispatch.dispatch(callee.code.ptr, callee_slots.ptr, frame, env);
    }
}

// ── return_call_indirect ─────────────────────────────────────────────────────

pub fn handle_return_call_indirect(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsReturnCallIndirect, ip);

    // Read inline arg slots directly from the bytecode stream
    const arg_slots = encode.readInlineArgs(encode.OpsReturnCallIndirect, ip, ops.args_len);

    const frame_idx = frame.call_depth - 1;

    // 1. Read runtime table index
    const raw_index = slots[ops.index].readAs(u32);

    // 2. Bounds check
    if (ops.table_index >= env.tables.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    const table = env.tables[ops.table_index];
    if (raw_index >= table.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }

    // 3. Resolve callee
    const callee_func_idx = table[raw_index];

    // 4. Null check
    if (callee_func_idx == std.math.maxInt(u32)) {
        trapReturn(frame, .IndirectCallToNull);
        return;
    }

    // 5. Signature check
    if (callee_func_idx >= env.func_type_indices.len) {
        trapReturn(frame, .BadSignature);
        return;
    }
    if (env.func_type_indices[callee_func_idx] != ops.type_index) {
        trapReturn(frame, .BadSignature);
        return;
    }

    // 6. Dispatch
    if (callee_func_idx < env.host_funcs.len) {
        const host_func = env.host_funcs[callee_func_idx];
        const result_len = env.composite_types[env.func_type_indices[callee_func_idx]].func_type.results().len;

        const ret_val = invokeHostCallInline(frame.allocator, env.store, env.host_instance, host_func, arg_slots, slots, result_len, frame);

        switch (frame.result) {
            .trap => return,
            .ok => {},
        }

        const popped = frame.callStackPop();
        frame.valStackFree(popped.slots_sp_base);

        if (frame.call_depth == 0) {
            frame.result = .{ .ok = ret_val };
            return;
        }

        const caller_idx = frame.call_depth - 1;
        if (popped.dst) |dst_slot| {
            if (ret_val) |rv| {
                frame.callStackAt(caller_idx).slots[dst_slot] = rv;
            }
        }

        const caller = frame.callStackAt(caller_idx);
        dispatch.dispatch(caller.ip, caller.slots.ptr, frame, env);
    } else {
        const callee = ensureLocalCompiled(callee_func_idx, env, frame) orelse return;
        const callee_slots_len: usize = @max(@as(usize, @intCast(callee.slots_len)), arg_slots.len);

        const old_sp_base = frame.callStackAt(frame_idx).slots_sp_base;
        frame.valStackFree(old_sp_base);
        const sp_base = frame.val_sp;
        const callee_slots = allocCalleeSlots(frame, callee_slots_len, arg_slots.len, callee.locals_count) orelse return;
        // Re-derive caller slots: valStackAlloc may have grown the buffer,
        // invalidating the handler's original `slots` parameter.
        const caller_slots = frame.callStackTop().slots.ptr;

        for (arg_slots, 0..) |arg_slot, i| {
            callee_slots[i] = caller_slots[arg_slot];
        }

        const tail_dst = frame.callStackAt(frame_idx).dst;

        frame.callStackAt(frame_idx).* = .{
            .ip = callee.code.ptr,
            .slots = callee_slots,
            .slots_sp_base = sp_base,
            .dst = tail_dst,
            .func = callee,
        };

        dispatch.dispatch(callee.code.ptr, callee_slots.ptr, frame, env);
    }
}

// ── call_ref ─────────────────────────────────────────────────────────────────

// ── call_ref ─────────────────────────────────────────────────────────────────

pub fn handle_call_ref(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsCallRef, ip);

    // funcref is stored as u64: null=0, func_idx+1=non-null
    const ref_bits = slots[ops.ref].readAs(u64);
    if (ref_bits == 0) {
        trapReturn(frame, .NullReference);
        return;
    }
    const callee_func_idx: u32 = @intCast(ref_bits - 1);

    // Read inline arg slots directly from the bytecode stream
    const arg_slots = encode.readInlineArgs(encode.OpsCallRef, ip, ops.args_len);
    const instr_stride = encode.varStride(encode.OpsCallRef, ops.args_len);

    // Signature check
    if (callee_func_idx >= env.func_type_indices.len) {
        trapReturn(frame, .BadSignature);
        return;
    }
    if (env.func_type_indices[callee_func_idx] != ops.type_idx) {
        trapReturn(frame, .BadSignature);
        return;
    }

    if (callee_func_idx < env.host_funcs.len) {
        const host_func = env.host_funcs[callee_func_idx];
        const result_len = env.composite_types[env.func_type_indices[callee_func_idx]].func_type.results().len;

        const ret_val = invokeHostCallInline(frame.allocator, env.store, env.host_instance, host_func, arg_slots, slots, result_len, frame);

        switch (frame.result) {
            .trap => return,
            .ok => {},
        }

        if (ops.dst_valid != 0) {
            if (ret_val) |rv| {
                slots[ops.dst] = rv;
            }
        }
        dispatch.next(ip, instr_stride, slots, frame, env);
    } else {
        const callee = ensureLocalCompiled(callee_func_idx, env, frame) orelse return;
        const callee_slots_len: usize = @max(@as(usize, @intCast(callee.slots_len)), arg_slots.len);

        const sp_base = frame.val_sp;
        const callee_slots = allocCalleeSlots(frame, callee_slots_len, arg_slots.len, callee.locals_count) orelse return;
        // Re-derive caller slots: valStackAlloc may have grown the buffer,
        // invalidating the handler's original `slots` parameter.
        const caller_slots = frame.callStackTop().slots.ptr;

        for (arg_slots, 0..) |arg_slot, i| {
            callee_slots[i] = caller_slots[arg_slot];
        }

        const cur = frame.callStackTop();
        cur.ip = ip + instr_stride;

        const callee_dst: ?ir.Slot = if (ops.dst_valid != 0) @intCast(ops.dst) else null;

        frame.callStackPush(.{
            .ip = callee.code.ptr,
            .slots = callee_slots,
            .slots_sp_base = sp_base,
            .dst = callee_dst,
            .func = callee,
        }) catch |err| {
            frame.valStackFree(sp_base);
            trapReturn(frame, switch (err) {
                error.OutOfMemory => .OutOfMemory,
                error.StackOverflow => .StackOverflow,
            });
            return;
        };

        dispatch.dispatch(callee.code.ptr, callee_slots.ptr, frame, env);
    }
}

// ── return_call_ref ──────────────────────────────────────────────────────────

pub fn handle_return_call_ref(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsReturnCallRef, ip);

    const ref_bits = slots[ops.ref].readAs(u64);
    if (ref_bits == 0) {
        trapReturn(frame, .NullReference);
        return;
    }
    const callee_func_idx: u32 = @intCast(ref_bits - 1);

    // Read inline arg slots directly from the bytecode stream
    const arg_slots = encode.readInlineArgs(encode.OpsReturnCallRef, ip, ops.args_len);

    const frame_idx = frame.call_depth - 1;

    // Signature check
    if (callee_func_idx >= env.func_type_indices.len) {
        trapReturn(frame, .BadSignature);
        return;
    }
    if (env.func_type_indices[callee_func_idx] != ops.type_idx) {
        trapReturn(frame, .BadSignature);
        return;
    }

    if (callee_func_idx < env.host_funcs.len) {
        const host_func = env.host_funcs[callee_func_idx];
        const result_len = env.composite_types[env.func_type_indices[callee_func_idx]].func_type.results().len;

        const ret_val = invokeHostCallInline(frame.allocator, env.store, env.host_instance, host_func, arg_slots, slots, result_len, frame);

        switch (frame.result) {
            .trap => return,
            .ok => {},
        }

        const popped = frame.callStackPop();
        frame.valStackFree(popped.slots_sp_base);

        if (frame.call_depth == 0) {
            frame.result = .{ .ok = ret_val };
            return;
        }

        const caller_idx = frame.call_depth - 1;
        if (popped.dst) |dst_slot| {
            if (ret_val) |rv| {
                frame.callStackAt(caller_idx).slots[dst_slot] = rv;
            }
        }

        const caller = frame.callStackAt(caller_idx);
        dispatch.dispatch(caller.ip, caller.slots.ptr, frame, env);
    } else {
        const callee = ensureLocalCompiled(callee_func_idx, env, frame) orelse return;
        const callee_slots_len: usize = @max(@as(usize, @intCast(callee.slots_len)), arg_slots.len);

        const old_sp_base = frame.callStackAt(frame_idx).slots_sp_base;
        frame.valStackFree(old_sp_base);
        const sp_base = frame.val_sp;
        const callee_slots = allocCalleeSlots(frame, callee_slots_len, arg_slots.len, callee.locals_count) orelse return;
        // Re-derive caller slots: valStackAlloc may have grown the buffer,
        // invalidating the handler's original `slots` parameter.
        const caller_slots = frame.callStackTop().slots.ptr;

        for (arg_slots, 0..) |arg_slot, i| {
            callee_slots[i] = caller_slots[arg_slot];
        }

        const tail_dst = frame.callStackAt(frame_idx).dst;

        frame.callStackAt(frame_idx).* = .{
            .ip = callee.code.ptr,
            .slots = callee_slots,
            .slots_sp_base = sp_base,
            .dst = tail_dst,
            .func = callee,
        };

        dispatch.dispatch(callee.code.ptr, callee_slots.ptr, frame, env);
    }
}

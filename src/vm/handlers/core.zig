/// core.zig — base threaded-dispatch instruction handlers
const std = @import("std");
const ir = @import("../../compiler/ir.zig");
const encode = @import("../../compiler/encode.zig");
const dispatch = @import("../dispatch.zig");
const core = @import("core");
const common = @import("common.zig");

const RawVal = dispatch.RawVal;
const Trap = dispatch.Trap;
const Global = dispatch.Global;
const Handler = dispatch.Handler;
const DispatchState = dispatch.DispatchState;
const ExecEnv = dispatch.ExecEnv;
const CallFrame = dispatch.CallFrame;
const EhFrame = dispatch.EhFrame;
const EncodedFunction = ir.EncodedFunction;
const CatchHandlerEntry = ir.CatchHandlerEntry;
const CatchHandlerKind = ir.CatchHandlerKind;
const Slot = ir.Slot;
const StorageType = core.StorageType;
const helper = core.helper;

const readOps = common.readOps;
const stride = common.stride;
const trapReturn = common.trapReturn;
const trapFromTruncateError = common.trapFromTruncateError;
const UnsignedOf = common.UnsignedOf;

pub fn handle_unreachable(
    ip: [*]u8,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
    r0: u64,
    fp0: f64,
) callconv(.c) void {
    _ = ip;
    _ = slots;
    _ = env;
    _ = r0;
    _ = fp0;
    trapReturn(frame, .UnreachableCodeReached);
}

pub fn handle_ret(
    ip: [*]u8,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
    r0: u64,
    fp0: f64,
) callconv(.c) void {
    _ = r0;
    _ = fp0;
    const ops = readOps(encode.OpsRet, ip);
    const ret_val: ?RawVal = if (ops.has_value != 0) slots[ops.value] else null;

    // Pop current frame and release its slots back to the value stack.
    const popped = frame.callStackPop();
    frame.valStackFree(popped.slots_sp_base);

    if (frame.call_depth == 0) {
        // Top-level return: write result and return (terminates dispatch chain).
        frame.result = .{ .ok = ret_val };
        return;
    }

    // Return to caller: write return value into caller's dst slot.
    const caller_idx = frame.call_depth - 1;
    if (popped.dst) |dst_slot| {
        if (ret_val) |rv| {
            frame.callStackAt(caller_idx).slots[dst_slot] = rv;
        }
    }

    // Resume caller.
    const caller = frame.callStackAt(caller_idx);
    dispatch.dispatch(caller.ip, caller.slots.ptr, frame, env, 0, 0.0);
}

// ── Fused binop+ret handlers (Peephole I) ────────────────────────────────────
// Compute result and return immediately, saving one dispatch event per call.

inline fn doRetWithVal(
    frame: *DispatchState,
    env: *const ExecEnv,
    ret_val: RawVal,
) void {
    const popped = frame.callStackPop();
    frame.valStackFree(popped.slots_sp_base);
    if (frame.call_depth == 0) {
        frame.result = .{ .ok = ret_val };
        return;
    }
    const caller_idx = frame.call_depth - 1;
    if (popped.dst) |dst_slot| {
        frame.callStackAt(caller_idx).slots[dst_slot] = ret_val;
    }
    const caller = frame.callStackAt(caller_idx);
    dispatch.dispatch(caller.ip, caller.slots.ptr, frame, env, 0, 0.0);
}

pub fn handle_i32_add_ret(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    _ = r0;
    _ = fp0;
    const ops = readOps(encode.OpsLhsRhs, ip);
    const result = slots[ops.lhs].readAs(i32) +% slots[ops.rhs].readAs(i32);
    doRetWithVal(frame, env, RawVal.from(result));
}

pub fn handle_i32_sub_ret(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    _ = r0;
    _ = fp0;
    const ops = readOps(encode.OpsLhsRhs, ip);
    const result = slots[ops.lhs].readAs(i32) -% slots[ops.rhs].readAs(i32);
    doRetWithVal(frame, env, RawVal.from(result));
}

pub fn handle_i64_add_ret(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    _ = r0;
    _ = fp0;
    const ops = readOps(encode.OpsLhsRhs, ip);
    const result = slots[ops.lhs].readAs(i64) +% slots[ops.rhs].readAs(i64);
    doRetWithVal(frame, env, RawVal.from(result));
}

pub fn handle_i64_sub_ret(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    _ = r0;
    _ = fp0;
    const ops = readOps(encode.OpsLhsRhs, ip);
    const result = slots[ops.lhs].readAs(i64) -% slots[ops.rhs].readAs(i64);
    doRetWithVal(frame, env, RawVal.from(result));
}
// ── Constants ────────────────────────────────────────────────────────────────

pub fn handle_const_i32(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    _ = r0;
    const ops = readOps(encode.OpsConstI32, ip);
    slots[ops.dst] = RawVal.from(ops.value);
    dispatch.next(ip, stride(encode.OpsConstI32), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(ops.value)))), fp0);
}

pub fn handle_const_i64(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    _ = r0;
    const ops = readOps(encode.OpsConstI64, ip);
    slots[ops.dst] = RawVal.from(ops.value);
    dispatch.next(ip, stride(encode.OpsConstI64), slots, frame, env, @as(u64, @bitCast(ops.value)), fp0);
}

pub fn handle_const_f32(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    _ = fp0;
    const ops = readOps(encode.OpsConstF32, ip);
    slots[ops.dst] = RawVal.from(ops.value);
    dispatch.next(ip, stride(encode.OpsConstF32), slots, frame, env, r0, @as(f64, @floatCast(ops.value)));
}

pub fn handle_const_f64(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    _ = fp0;
    const ops = readOps(encode.OpsConstF64, ip);
    slots[ops.dst] = RawVal.from(ops.value);
    dispatch.next(ip, stride(encode.OpsConstF64), slots, frame, env, r0, ops.value);
}

pub fn handle_const_v128(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsConstV128, ip);
    const sv = core.SimdVal.fromV128(.{ .bytes = ops.value });
    sv.toSlots(&slots[ops.dst], &slots[ops.dst + 1]);
    dispatch.next(ip, stride(encode.OpsConstV128), slots, frame, env, r0, fp0);
}

pub fn handle_const_ref_null(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsDst, ip);
    slots[ops.dst] = RawVal.fromBits64(0);
    dispatch.next(ip, stride(encode.OpsDst), slots, frame, env, r0, fp0);
}

// ── References ───────────────────────────────────────────────────────────────

pub fn handle_ref_is_null(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    _ = r0;
    const ops = readOps(encode.OpsDstSrc, ip);
    const is_null: i32 = if (slots[ops.src].readAs(u64) == 0) 1 else 0;
    slots[ops.dst] = RawVal.from(is_null);
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(is_null)))), fp0);
}

pub fn handle_ref_func(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    _ = r0;
    const ops = readOps(encode.OpsRefFunc, ip);
    slots[ops.dst] = RawVal.fromBits64(@as(u64, ops.func_idx) + 1);
    dispatch.next(ip, stride(encode.OpsRefFunc), slots, frame, env, @as(u64, ops.func_idx) + 1, fp0);
}

pub fn handle_ref_eq(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const eq: i32 = if (slots[ops.lhs].readAs(u64) == slots[ops.rhs].readAs(u64)) 1 else 0;
    slots[ops.dst] = RawVal.from(eq);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(eq)))), fp0);
}

// ── Variables ────────────────────────────────────────────────────────────────

pub fn handle_local_get(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsLocalGet, ip);
    slots[ops.dst] = slots[ops.local];
    dispatch.next(ip, stride(encode.OpsLocalGet), slots, frame, env, r0, fp0);
}

pub fn handle_local_set(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsLocalSet, ip);
    slots[ops.local] = slots[ops.src];
    dispatch.next(ip, stride(encode.OpsLocalSet), slots, frame, env, r0, fp0);
}

pub fn handle_global_get(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsGlobalGet, ip);
    slots[ops.dst] = env.globals[ops.global_idx].getRawValue();
    dispatch.next(ip, stride(encode.OpsGlobalGet), slots, frame, env, r0, fp0);
}

pub fn handle_global_set(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsGlobalSet, ip);
    env.globals[ops.global_idx].value = slots[ops.src];
    dispatch.next(ip, stride(encode.OpsGlobalSet), slots, frame, env, r0, fp0);
}

pub fn handle_copy(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsCopy, ip);
    slots[ops.dst] = slots[ops.src];
    dispatch.next(ip, stride(encode.OpsCopy), slots, frame, env, r0, fp0);
}

// ── Control flow ─────────────────────────────────────────────────────────────

pub fn handle_jump(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsJump, ip);
    // rel_target is a signed byte offset from instruction start
    const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
    dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
}

pub fn handle_jump_if_z(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsJumpIfZ, ip);
    if (slots[ops.cond].readAs(i32) == 0) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsJumpIfZ), slots, frame, env, r0, fp0);
    }
}

/// Peephole J: jump when cond != 0 (i.e. when br_if condition is true).
pub fn handle_jump_if_nz(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsJumpIfZ, ip);
    if (slots[ops.cond].readAs(i32) != 0) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsJumpIfZ), slots, frame, env, r0, fp0);
    }
}

pub fn handle_jump_table(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsJumpTable, ip);
    const idx = slots[ops.index].readAs(u32);
    const entry = if (idx < ops.targets_len) idx else ops.targets_len;
    const func = frame.callStackTop().func;
    const target = func.br_table_targets[ops.targets_start + entry];
    const target_ip: [*]u8 = func.code.ptr + target;
    dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
}

pub fn handle_select(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsSelect, ip);
    const cond = slots[ops.cond].readAs(i32);
    slots[ops.dst] = if (cond != 0) slots[ops.val1] else slots[ops.val2];
    dispatch.next(ip, stride(encode.OpsSelect), slots, frame, env, r0, fp0);
}

/// accumulator.zig — r0/fp0 accumulator handlers (*_r, acc_load, *_r_ret)
const encode = @import("../../compiler/encode/encode.zig");
const dispatch = @import("../dispatch.zig");
const core = @import("core");
const common = @import("common.zig");

const RawVal = dispatch.RawVal;
const DispatchState = dispatch.DispatchState;
const ExecEnv = dispatch.ExecEnv;
const readOps = common.readOps;
const stride = common.stride;
const helper = core.helper;

inline fn i32FromR0(r0: u64) i32 {
    return @as(i32, @truncate(@as(i64, @bitCast(r0))));
}

inline fn r0FromI32(v: i32) u64 {
    return @as(u64, @intCast(@as(u32, @bitCast(v))));
}

inline fn r0FromI64(v: i64) u64 {
    return @as(u64, @bitCast(v));
}

inline fn f32FromFp0(fp0: f64) f32 {
    return @floatCast(fp0);
}

// Accumulator preload

pub fn handle_r0_load(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("acc_load");
    _ = r0;
    const ops = readOps(encode.ops.OpsAccLoad, ip);
    const val = slots[ops.src].readAs(i64);
    dispatch.next(ip, stride(encode.ops.OpsAccLoad), slots, frame, env, @as(u64, @bitCast(val)), fp0);
}

pub fn handle_fp0_load(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("acc_load");
    _ = fp0;
    const ops = readOps(encode.ops.OpsAccLoad, ip);
    const val = slots[ops.src].readAs(f64);
    dispatch.next(ip, stride(encode.ops.OpsAccLoad), slots, frame, env, r0, val);
}

pub fn handle_i32_add_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const lhs = i32FromR0(r0); const rhs = slots[ops.rhs].readAs(i32); const result = lhs +% rhs;
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0FromI32(result), fp0);
}

pub fn handle_i32_sub_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const lhs = i32FromR0(r0); const rhs = slots[ops.rhs].readAs(i32); const result = lhs -% rhs;
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0FromI32(result), fp0);
}

pub fn handle_i32_mul_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const lhs = i32FromR0(r0); const rhs = slots[ops.rhs].readAs(i32); const result = lhs *% rhs;
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0FromI32(result), fp0);
}

pub fn handle_i32_and_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const lhs = i32FromR0(r0); const rhs = slots[ops.rhs].readAs(i32); const result = lhs & rhs;
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0FromI32(result), fp0);
}

pub fn handle_i32_or_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const lhs = i32FromR0(r0); const rhs = slots[ops.rhs].readAs(i32); const result = lhs | rhs;
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0FromI32(result), fp0);
}

pub fn handle_i32_xor_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const lhs = i32FromR0(r0); const rhs = slots[ops.rhs].readAs(i32); const result = lhs ^ rhs;
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0FromI32(result), fp0);
}

pub fn handle_i32_shl_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const lhs = i32FromR0(r0);
    const result = helper.shl(lhs, slots[ops.rhs].readAs(i32));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0FromI32(result), fp0);
}

pub fn handle_i32_shr_s_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const lhs = i32FromR0(r0);
    const result = helper.shrS(lhs, slots[ops.rhs].readAs(i32));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0FromI32(result), fp0);
}

pub fn handle_i32_shr_u_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const lhs = i32FromR0(r0);
    const result = @as(i32, @bitCast(helper.shrU(i32, @as(u32, @bitCast(lhs)), @as(u32, @bitCast(slots[ops.rhs].readAs(i32))))));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0FromI32(result), fp0);
}

pub fn handle_i64_add_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const result = @as(i64, @bitCast(r0)) +% slots[ops.rhs].readAs(i64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0FromI64(result), fp0);
}

pub fn handle_i64_sub_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const result = @as(i64, @bitCast(r0)) -% slots[ops.rhs].readAs(i64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0FromI64(result), fp0);
}

pub fn handle_i64_mul_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const result = @as(i64, @bitCast(r0)) *% slots[ops.rhs].readAs(i64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0FromI64(result), fp0);
}

pub fn handle_i64_and_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const result = @as(i64, @bitCast(r0)) & slots[ops.rhs].readAs(i64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0FromI64(result), fp0);
}

pub fn handle_i64_or_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const result = @as(i64, @bitCast(r0)) | slots[ops.rhs].readAs(i64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0FromI64(result), fp0);
}

pub fn handle_i64_xor_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const result = @as(i64, @bitCast(r0)) ^ slots[ops.rhs].readAs(i64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0FromI64(result), fp0);
}

pub fn handle_i64_shl_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const result = helper.shl(@as(i64, @bitCast(r0)), slots[ops.rhs].readAs(i64));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0FromI64(result), fp0);
}

pub fn handle_i64_shr_s_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const result = helper.shrS(@as(i64, @bitCast(r0)), slots[ops.rhs].readAs(i64));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0FromI64(result), fp0);
}

pub fn handle_i64_shr_u_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const result = @as(i64, @bitCast(helper.shrU(i64, r0, @as(u64, @bitCast(slots[ops.rhs].readAs(i64))))));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0FromI64(result), fp0);
}

pub fn handle_f32_add_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const result: f32 = f32FromFp0(fp0) + slots[ops.rhs].readAs(f32);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0, @as(f64, @floatCast(result)));
}

pub fn handle_f32_sub_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const result: f32 = f32FromFp0(fp0) - slots[ops.rhs].readAs(f32);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0, @as(f64, @floatCast(result)));
}

pub fn handle_f32_mul_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const result: f32 = f32FromFp0(fp0) * slots[ops.rhs].readAs(f32);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0, @as(f64, @floatCast(result)));
}

pub fn handle_f32_div_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const result: f32 = f32FromFp0(fp0) / slots[ops.rhs].readAs(f32);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0, @as(f64, @floatCast(result)));
}

pub fn handle_f64_add_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const result: f64 = fp0 + slots[ops.rhs].readAs(f64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0, result);
}

pub fn handle_f64_sub_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const result: f64 = fp0 - slots[ops.rhs].readAs(f64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0, result);
}

pub fn handle_f64_mul_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const result: f64 = fp0 * slots[ops.rhs].readAs(f64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0, result);
}

pub fn handle_f64_div_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    const ops = readOps(encode.ops.OpsDstRhs, ip);
    const result: f64 = fp0 / slots[ops.rhs].readAs(f64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstRhs), slots, frame, env, r0, result);
}

pub fn handle_i32_add_r_ret(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    _ = fp0;
    const ops = readOps(encode.ops.OpsRhs, ip);
    const result = i32FromR0(r0) +% slots[ops.rhs].readAs(i32);
    const func_idx = frame.callStackTop().func.func_idx;
    dispatch.retWithVal(frame, env, RawVal.from(result), func_idx);
}

pub fn handle_i32_sub_r_ret(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    _ = fp0;
    const ops = readOps(encode.ops.OpsRhs, ip);
    const result = i32FromR0(r0) -% slots[ops.rhs].readAs(i32);
    const func_idx = frame.callStackTop().func.func_idx;
    dispatch.retWithVal(frame, env, RawVal.from(result), func_idx);
}

pub fn handle_i64_add_r_ret(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    _ = fp0;
    const ops = readOps(encode.ops.OpsRhs, ip);
    const result = @as(i64, @bitCast(r0)) +% slots[ops.rhs].readAs(i64);
    const func_idx = frame.callStackTop().func.func_idx;
    dispatch.retWithVal(frame, env, RawVal.from(result), func_idx);
}

pub fn handle_i64_sub_r_ret(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    dispatch.countOp("binop_r");
    _ = fp0;
    const ops = readOps(encode.ops.OpsRhs, ip);
    const result = @as(i64, @bitCast(r0)) -% slots[ops.rhs].readAs(i64);
    const func_idx = frame.callStackTop().func.func_idx;
    dispatch.retWithVal(frame, env, RawVal.from(result), func_idx);
}


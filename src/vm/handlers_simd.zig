/// handlers_simd.zig — M3 threaded-dispatch SIMD instruction handlers
///
/// simd_unary, simd_binary, simd_ternary, simd_compare, simd_shift_scalar,
/// simd_extract_lane, simd_replace_lane, simd_shuffle, simd_load, simd_store
const std = @import("std");
const ir = @import("../compiler/ir.zig");
const encode = @import("../compiler/encode.zig");
const dispatch = @import("dispatch.zig");
const core = @import("core");
const simd = core.simd;

const RawVal = dispatch.RawVal;
const Trap = dispatch.Trap;
const Handler = dispatch.Handler;
const DispatchState = dispatch.DispatchState;
const ExecEnv = dispatch.ExecEnv;

const HANDLER_SIZE = dispatch.HANDLER_SIZE;

// ── Helpers ──────────────────────────────────────────────────────────────────

inline fn readOps(comptime T: type, ip: [*]align(8) u8) T {
    if (@sizeOf(T) == 0) return .{};
    return @as(*const T, @ptrCast(@alignCast(ip + HANDLER_SIZE))).*;
}

inline fn stride(comptime OpsT: type) usize {
    return std.mem.alignForward(usize, HANDLER_SIZE + @sizeOf(OpsT), 8);
}

inline fn trapReturn(frame: *DispatchState, code: core.TrapCode) void {
    frame.result = .{ .trap = Trap.fromTrapCode(code) };
}

inline fn effectiveAddr(slots: [*]RawVal, addr_slot: u32, offset: u32, size: usize, mem: []const u8) ?u32 {
    const base = slots[addr_slot].readAs(u32);
    const ea = base +% offset;
    if (@as(usize, ea) + size > mem.len) return null;
    return ea;
}

// ── simd_unary ───────────────────────────────────────────────────────────────

pub fn handle_simd_unary(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsSimdUnary, ip);
    const opcode: core.simd.SimdOpcode = @enumFromInt(ops.opcode);
    slots[ops.dst] = simd.executeUnary(opcode, slots[ops.src]);
    dispatch.next(ip, stride(encode.OpsSimdUnary), slots, frame, env);
}

// ── simd_binary ──────────────────────────────────────────────────────────────

pub fn handle_simd_binary(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsSimdBinary, ip);
    const opcode: core.simd.SimdOpcode = @enumFromInt(ops.opcode);
    slots[ops.dst] = simd.executeBinary(opcode, slots[ops.lhs], slots[ops.rhs]);
    dispatch.next(ip, stride(encode.OpsSimdBinary), slots, frame, env);
}

// ── simd_ternary ─────────────────────────────────────────────────────────────

pub fn handle_simd_ternary(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsSimdTernary, ip);
    const opcode: core.simd.SimdOpcode = @enumFromInt(ops.opcode);
    slots[ops.dst] = simd.executeTernary(opcode, slots[ops.first], slots[ops.second], slots[ops.third]);
    dispatch.next(ip, stride(encode.OpsSimdTernary), slots, frame, env);
}

// ── simd_compare ─────────────────────────────────────────────────────────────

pub fn handle_simd_compare(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsSimdBinary, ip);
    const opcode: core.simd.SimdOpcode = @enumFromInt(ops.opcode);
    slots[ops.dst] = simd.executeCompare(opcode, slots[ops.lhs], slots[ops.rhs]);
    dispatch.next(ip, stride(encode.OpsSimdBinary), slots, frame, env);
}

// ── simd_shift_scalar ────────────────────────────────────────────────────────

pub fn handle_simd_shift_scalar(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsSimdBinary, ip);
    const opcode: core.simd.SimdOpcode = @enumFromInt(ops.opcode);
    slots[ops.dst] = simd.executeShift(opcode, slots[ops.lhs], slots[ops.rhs]);
    dispatch.next(ip, stride(encode.OpsSimdBinary), slots, frame, env);
}

// ── simd_extract_lane ────────────────────────────────────────────────────────

pub fn handle_simd_extract_lane(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsSimdExtractLane, ip);
    const opcode: core.simd.SimdOpcode = @enumFromInt(ops.opcode);
    slots[ops.dst] = simd.extractLane(opcode, slots[ops.src], ops.lane);
    dispatch.next(ip, stride(encode.OpsSimdExtractLane), slots, frame, env);
}

// ── simd_replace_lane ────────────────────────────────────────────────────────

pub fn handle_simd_replace_lane(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsSimdReplaceLane, ip);
    const opcode: core.simd.SimdOpcode = @enumFromInt(ops.opcode);
    slots[ops.dst] = simd.replaceLane(opcode, slots[ops.src_vec], slots[ops.src_lane], ops.lane);
    dispatch.next(ip, stride(encode.OpsSimdReplaceLane), slots, frame, env);
}

// ── simd_shuffle ─────────────────────────────────────────────────────────────

pub fn handle_simd_shuffle(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsSimdShuffle, ip);
    slots[ops.dst] = simd.shuffleVectors(slots[ops.lhs], slots[ops.rhs], ops.lanes);
    dispatch.next(ip, stride(encode.OpsSimdShuffle), slots, frame, env);
}

// ── simd_load ────────────────────────────────────────────────────────────────

pub fn handle_simd_load(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsSimdLoad, ip);
    const opcode: core.simd.SimdOpcode = @enumFromInt(ops.opcode);
    const memory = env.memory.bytes();

    const access_size: usize = if (simd.isLaneLoadOpcode(opcode))
        simd.laneImmediateFromOpcode(opcode)
    else switch (opcode) {
        .v128_load => 16,
        .i16x8_load8x8_s, .i16x8_load8x8_u => 8,
        .i32x4_load16x4_s, .i32x4_load16x4_u => 8,
        .i64x2_load32x2_s, .i64x2_load32x2_u => 8,
        .v8x16_load_splat => 1,
        .v16x8_load_splat => 2,
        .v32x4_load_splat, .v128_load32_zero => 4,
        .v64x2_load_splat, .v128_load64_zero => 8,
        else => unreachable,
    };

    _ = effectiveAddr(slots, ops.addr, ops.offset, access_size, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };

    const src_vec: ?RawVal = if (ops.src_vec_valid != 0) slots[ops.src_vec] else null;

    slots[ops.dst] = RawVal.from(simd.load(
        opcode,
        memory,
        slots[ops.addr].readAs(u32),
        ops.offset,
        ops.lane,
        src_vec,
    ));
    dispatch.next(ip, stride(encode.OpsSimdLoad), slots, frame, env);
}

// ── simd_store ───────────────────────────────────────────────────────────────

pub fn handle_simd_store(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsSimdStore, ip);
    const opcode: core.simd.SimdOpcode = @enumFromInt(ops.opcode);
    const memory = env.memory.bytes();

    const access_size: usize = if (simd.isLaneStoreOpcode(opcode))
        simd.laneImmediateFromOpcode(opcode)
    else switch (opcode) {
        .v128_store => 16,
        else => unreachable,
    };

    _ = effectiveAddr(slots, ops.addr, ops.offset, access_size, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };

    simd.store(opcode, memory, slots[ops.addr].readAs(u32), ops.offset, ops.lane, slots[ops.src]);
    dispatch.next(ip, stride(encode.OpsSimdStore), slots, frame, env);
}

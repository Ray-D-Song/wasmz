/// handlers_simd.zig — M3 threaded-dispatch SIMD instruction handlers
///
/// simd_unary, simd_binary, simd_ternary, simd_compare, simd_shift_scalar,
/// simd_extract_lane, simd_replace_lane, simd_shuffle, simd_load, simd_store
const std = @import("std");
const ir = @import("../../compiler/ir.zig");
const encode = @import("../../compiler/encode/encode.zig");
const dispatch = @import("../dispatch.zig");
const core = @import("core");
const simd = core.simd;

const RawVal = dispatch.RawVal;
const SimdVal = core.SimdVal;
const Trap = dispatch.Trap;
const Handler = dispatch.Handler;
const DispatchState = dispatch.DispatchState;
const ExecEnv = dispatch.ExecEnv;

const HANDLER_SIZE = dispatch.HANDLER_SIZE;

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
    var trap = Trap.fromTrapCode(code);
    if (frame.captureStackTrace()) |trace| {
        trap.allocator = frame.allocator;
        trap.stack_trace = trace;
    }
    frame.result = .{ .trap = trap };
}

inline fn effectiveAddr(slots: [*]RawVal, addr_slot: u32, offset: u32, size: usize, mem: []const u8) ?u32 {
    const base = slots[addr_slot].readAs(u32);
    const ea = base +% offset;
    if (@as(usize, ea) + size > mem.len) return null;
    return ea;
}

/// Read a V128 from two consecutive RawVal slots.
inline fn readSimd(slots: [*]RawVal, idx: u32) SimdVal {
    return SimdVal.fromSlots(slots[idx], slots[idx + 1]);
}

/// Write a SimdVal into two consecutive RawVal slots.
inline fn writeSimd(slots: [*]RawVal, idx: u32, sv: SimdVal) void {
    sv.toSlots(&slots[idx], &slots[idx + 1]);
}

// ── simd_unary ───────────────────────────────────────────────────────────────

pub fn handle_simd_unary(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops_val = readOps(encode.ops.OpsSimdUnary, ip);
    const opcode: core.simd.SimdOpcode = @enumFromInt(ops_val.opcode);
    // splat: src is a scalar slot; all others: src is a V128 (two slots)
    const src: SimdVal = if (simd.isSplatOpcode(opcode))
        SimdVal.fromScalar(slots[ops_val.src])
    else
        readSimd(slots, ops_val.src);
    const result = simd.executeUnary(opcode, src);
    // any_true / all_true / bitmask produce a scalar result wrapped in SimdVal
    if (!simd.isVectorResultOpcode(opcode)) {
        slots[ops_val.dst] = result.toScalar();
    } else {
        writeSimd(slots, ops_val.dst, result);
    }
    dispatch.next(ip, stride(encode.ops.OpsSimdUnary), slots, frame, env, r0, fp0);
}

// ── simd_binary ──────────────────────────────────────────────────────────────

pub fn handle_simd_binary(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops_val = readOps(encode.ops.OpsSimdBinary, ip);
    const opcode: core.simd.SimdOpcode = @enumFromInt(ops_val.opcode);
    const result = simd.executeBinary(opcode, readSimd(slots, ops_val.lhs), readSimd(slots, ops_val.rhs));
    writeSimd(slots, ops_val.dst, result);
    dispatch.next(ip, stride(encode.ops.OpsSimdBinary), slots, frame, env, r0, fp0);
}

// ── simd_ternary ─────────────────────────────────────────────────────────────

pub fn handle_simd_ternary(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops_val = readOps(encode.ops.OpsSimdTernary, ip);
    const opcode: core.simd.SimdOpcode = @enumFromInt(ops_val.opcode);
    const result = simd.executeTernary(opcode, readSimd(slots, ops_val.first), readSimd(slots, ops_val.second), readSimd(slots, ops_val.third));
    writeSimd(slots, ops_val.dst, result);
    dispatch.next(ip, stride(encode.ops.OpsSimdTernary), slots, frame, env, r0, fp0);
}

// ── simd_compare ─────────────────────────────────────────────────────────────

pub fn handle_simd_compare(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops_val = readOps(encode.ops.OpsSimdBinary, ip);
    const opcode: core.simd.SimdOpcode = @enumFromInt(ops_val.opcode);
    const result = simd.executeCompare(opcode, readSimd(slots, ops_val.lhs), readSimd(slots, ops_val.rhs));
    writeSimd(slots, ops_val.dst, result);
    dispatch.next(ip, stride(encode.ops.OpsSimdBinary), slots, frame, env, r0, fp0);
}

// ── simd_shift_scalar ────────────────────────────────────────────────────────

pub fn handle_simd_shift_scalar(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops_val = readOps(encode.ops.OpsSimdBinary, ip);
    const opcode: core.simd.SimdOpcode = @enumFromInt(ops_val.opcode);
    // lhs is V128 (two slots), rhs is scalar (one slot)
    const result = simd.executeShift(opcode, readSimd(slots, ops_val.lhs), slots[ops_val.rhs]);
    writeSimd(slots, ops_val.dst, result);
    dispatch.next(ip, stride(encode.ops.OpsSimdBinary), slots, frame, env, r0, fp0);
}

// ── simd_extract_lane ────────────────────────────────────────────────────────

pub fn handle_simd_extract_lane(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops_val = readOps(encode.ops.OpsSimdExtractLane, ip);
    const opcode: core.simd.SimdOpcode = @enumFromInt(ops_val.opcode);
    // src is V128 (two slots), dst is scalar
    slots[ops_val.dst] = simd.extractLane(opcode, readSimd(slots, ops_val.src), ops_val.lane);
    dispatch.next(ip, stride(encode.ops.OpsSimdExtractLane), slots, frame, env, r0, fp0);
}

// ── simd_replace_lane ────────────────────────────────────────────────────────

pub fn handle_simd_replace_lane(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops_val = readOps(encode.ops.OpsSimdReplaceLane, ip);
    const opcode: core.simd.SimdOpcode = @enumFromInt(ops_val.opcode);
    // src_vec is V128 (two slots), src_lane is scalar (one slot)
    const result = simd.replaceLane(opcode, readSimd(slots, ops_val.src_vec), slots[ops_val.src_lane], ops_val.lane);
    writeSimd(slots, ops_val.dst, result);
    dispatch.next(ip, stride(encode.ops.OpsSimdReplaceLane), slots, frame, env, r0, fp0);
}

// ── simd_shuffle ─────────────────────────────────────────────────────────────

pub fn handle_simd_shuffle(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops_val = readOps(encode.ops.OpsSimdShuffle, ip);
    const result = simd.shuffleVectors(readSimd(slots, ops_val.lhs), readSimd(slots, ops_val.rhs), ops_val.lanes);
    writeSimd(slots, ops_val.dst, result);
    dispatch.next(ip, stride(encode.ops.OpsSimdShuffle), slots, frame, env, r0, fp0);
}

// ── simd_load ────────────────────────────────────────────────────────────────

pub fn handle_simd_load(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops_val = readOps(encode.ops.OpsSimdLoad, ip);
    const opcode: core.simd.SimdOpcode = @enumFromInt(ops_val.opcode);
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

    _ = effectiveAddr(slots, ops_val.addr, ops_val.offset, access_size, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };

    const src_vec: ?SimdVal = if (ops_val.src_vec_valid != 0) readSimd(slots, ops_val.src_vec) else null;

    const result = simd.load(
        opcode,
        memory,
        slots[ops_val.addr].readAs(u32),
        ops_val.offset,
        ops_val.lane,
        src_vec,
    );
    writeSimd(slots, ops_val.dst, result);
    dispatch.next(ip, stride(encode.ops.OpsSimdLoad), slots, frame, env, r0, fp0);
}

// ── simd_store ───────────────────────────────────────────────────────────────

pub fn handle_simd_store(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops_val = readOps(encode.ops.OpsSimdStore, ip);
    const opcode: core.simd.SimdOpcode = @enumFromInt(ops_val.opcode);
    const memory = env.memory.bytes();

    const access_size: usize = if (simd.isLaneStoreOpcode(opcode))
        simd.laneImmediateFromOpcode(opcode)
    else switch (opcode) {
        .v128_store => 16,
        else => unreachable,
    };

    _ = effectiveAddr(slots, ops_val.addr, ops_val.offset, access_size, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };

    simd.store(opcode, memory, slots[ops_val.addr].readAs(u32), ops_val.offset, ops_val.lane, readSimd(slots, ops_val.src));
    dispatch.next(ip, stride(encode.ops.OpsSimdStore), slots, frame, env, r0, fp0);
}

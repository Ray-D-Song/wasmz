const std = @import("std");
const builtin = @import("builtin");
const payload = @import("payload");
const float = @import("../float.zig");
const raw_mod = @import("../raw.zig");
const helper = @import("../value/helper.zig");
const vec = @import("../value/vec.zig");

pub const RawVal = raw_mod.RawVal;
pub const V128 = vec.V128;
pub const SimdOpcode = payload.OperatorCode;

pub const SimdShape = enum {
    i8x16,
    i16x8,
    i32x4,
    i64x2,
    f32x4,
    f64x2,
};

pub const SimdClass = enum {
    const_,
    shuffle,
    extract_lane,
    replace_lane,
    load,
    store,
    unary,
    binary,
    ternary,
    compare,
    shift,
};

pub const SimdLoadInfo = struct {
    opcode: SimdOpcode,
    offset: u32,
    lane: ?u8 = null,
};

pub const SimdStoreInfo = struct {
    opcode: SimdOpcode,
    offset: u32,
    lane: ?u8 = null,
};

pub fn isSimdOpcode(opcode: SimdOpcode) bool {
    const value = @intFromEnum(opcode);
    return value >= 0xFD000 and value < 0xFE000;
}

pub fn isRelaxedSimdOpcode(opcode: SimdOpcode) bool {
    return std.mem.indexOf(u8, @tagName(opcode), "relaxed_") != null;
}

pub fn classifyOpcode(opcode: SimdOpcode) ?SimdClass {
    if (!isSimdOpcode(opcode)) return null;

    const tag = @tagName(opcode);
    if (std.mem.eql(u8, tag, "v128_const")) return .const_;
    if (std.mem.eql(u8, tag, "i8x16_shuffle")) return .shuffle;
    if (std.mem.indexOf(u8, tag, "_extract_lane") != null) return .extract_lane;
    if (std.mem.indexOf(u8, tag, "_replace_lane") != null) return .replace_lane;
    if (std.mem.indexOf(u8, tag, "_load") != null) return .load;
    if (std.mem.indexOf(u8, tag, "_store") != null) return .store;
    if (std.mem.endsWith(u8, tag, "_shl") or std.mem.endsWith(u8, tag, "_shr_s") or std.mem.endsWith(u8, tag, "_shr_u")) return .shift;
    if (isCompareOpcode(opcode)) return .compare;
    if (isTernaryOpcode(opcode)) return .ternary;
    if (isUnaryOpcode(opcode)) return .unary;
    return .binary;
}

pub fn shapeOf(opcode: SimdOpcode) ?SimdShape {
    const tag = @tagName(opcode);
    if (std.mem.startsWith(u8, tag, "i8x16_") or std.mem.startsWith(u8, tag, "v8x16_")) return .i8x16;
    if (std.mem.startsWith(u8, tag, "i16x8_") or std.mem.startsWith(u8, tag, "v16x8_")) return .i16x8;
    if (std.mem.startsWith(u8, tag, "i32x4_") or std.mem.startsWith(u8, tag, "v32x4_")) return .i32x4;
    if (std.mem.startsWith(u8, tag, "i64x2_") or std.mem.startsWith(u8, tag, "v64x2_")) return .i64x2;
    if (std.mem.startsWith(u8, tag, "f32x4_")) return .f32x4;
    if (std.mem.startsWith(u8, tag, "f64x2_")) return .f64x2;
    return null;
}

pub fn laneCount(shape: SimdShape) usize {
    return switch (shape) {
        .i8x16 => 16,
        .i16x8 => 8,
        .i32x4, .f32x4 => 4,
        .i64x2, .f64x2 => 2,
    };
}

pub fn laneByteWidth(shape: SimdShape) usize {
    return switch (shape) {
        .i8x16 => 1,
        .i16x8 => 2,
        .i32x4, .f32x4 => 4,
        .i64x2, .f64x2 => 8,
    };
}

pub fn isLaneLoadOpcode(opcode: SimdOpcode) bool {
    return switch (opcode) {
        .v128_load8_lane, .v128_load16_lane, .v128_load32_lane, .v128_load64_lane => true,
        else => false,
    };
}

pub fn isLaneStoreOpcode(opcode: SimdOpcode) bool {
    return switch (opcode) {
        .v128_store8_lane, .v128_store16_lane, .v128_store32_lane, .v128_store64_lane => true,
        else => false,
    };
}

pub fn isVectorResultOpcode(opcode: SimdOpcode) bool {
    return switch (classifyOpcode(opcode) orelse return false) {
        .const_, .shuffle, .replace_lane, .load, .binary, .ternary, .compare, .shift => true,
        .extract_lane, .store => false,
        .unary => switch (opcode) {
            .v128_any_true,
            .i8x16_all_true,
            .i8x16_bitmask,
            .i16x8_all_true,
            .i16x8_bitmask,
            .i32x4_all_true,
            .i32x4_bitmask,
            .i64x2_all_true,
            .i64x2_bitmask,
            => false,
            else => true,
        },
    };
}

pub fn laneImmediateFromOpcode(opcode: SimdOpcode) usize {
    return switch (opcode) {
        .v128_load8_lane, .v128_store8_lane => 1,
        .v128_load16_lane, .v128_store16_lane => 2,
        .v128_load32_lane, .v128_store32_lane => 4,
        .v128_load64_lane, .v128_store64_lane => 8,
        else => unreachable,
    };
}

pub fn v128FromBytes(bytes: [16]u8) V128 {
    return .{ .bytes = bytes };
}

pub fn bytesFromV128(value: V128) [16]u8 {
    return value.bytes;
}

fn isCompareOpcode(opcode: SimdOpcode) bool {
    const tag = @tagName(opcode);
    return std.mem.endsWith(u8, tag, "_eq") or
        std.mem.endsWith(u8, tag, "_ne") or
        std.mem.endsWith(u8, tag, "_lt_s") or
        std.mem.endsWith(u8, tag, "_lt_u") or
        std.mem.endsWith(u8, tag, "_gt_s") or
        std.mem.endsWith(u8, tag, "_gt_u") or
        std.mem.endsWith(u8, tag, "_le_s") or
        std.mem.endsWith(u8, tag, "_le_u") or
        std.mem.endsWith(u8, tag, "_ge_s") or
        std.mem.endsWith(u8, tag, "_ge_u") or
        std.mem.endsWith(u8, tag, "_lt") or
        std.mem.endsWith(u8, tag, "_gt") or
        std.mem.endsWith(u8, tag, "_le") or
        std.mem.endsWith(u8, tag, "_ge");
}

fn isTernaryOpcode(opcode: SimdOpcode) bool {
    return switch (opcode) {
        .v128_bitselect,
        .f32x4_relaxed_madd,
        .f32x4_relaxed_nmadd,
        .f64x2_relaxed_madd,
        .f64x2_relaxed_nmadd,
        .i8x16_relaxed_laneselect,
        .i16x8_relaxed_laneselect,
        .i32x4_relaxed_laneselect,
        .i64x2_relaxed_laneselect,
        .i32x4_relaxed_dot_i8x16_i7x16_add_s,
        => true,
        else => false,
    };
}

fn isUnaryOpcode(opcode: SimdOpcode) bool {
    const tag = @tagName(opcode);
    if (std.mem.endsWith(u8, tag, "_splat")) return true;
    return switch (opcode) {
        .v128_not,
        .v128_any_true,
        .f32x4_demote_f64x2_zero,
        .f64x2_promote_low_f32x4,
        .i8x16_abs,
        .i8x16_neg,
        .i8x16_popcnt,
        .i8x16_all_true,
        .i8x16_bitmask,
        .i16x8_extadd_pairwise_i8x16_s,
        .i16x8_extadd_pairwise_i8x16_u,
        .i32x4_extadd_pairwise_i16x8_s,
        .i32x4_extadd_pairwise_i16x8_u,
        .i16x8_abs,
        .i16x8_neg,
        .i16x8_all_true,
        .i16x8_bitmask,
        .i16x8_extend_low_i8x16_s,
        .i16x8_extend_high_i8x16_s,
        .i16x8_extend_low_i8x16_u,
        .i16x8_extend_high_i8x16_u,
        .i32x4_abs,
        .i32x4_neg,
        .i32x4_all_true,
        .i32x4_bitmask,
        .i32x4_extend_low_i16x8_s,
        .i32x4_extend_high_i16x8_s,
        .i32x4_extend_low_i16x8_u,
        .i32x4_extend_high_i16x8_u,
        .i64x2_abs,
        .i64x2_neg,
        .i64x2_all_true,
        .i64x2_bitmask,
        .i64x2_extend_low_i32x4_s,
        .i64x2_extend_high_i32x4_s,
        .i64x2_extend_low_i32x4_u,
        .i64x2_extend_high_i32x4_u,
        .f32x4_abs,
        .f32x4_neg,
        .f32x4_sqrt,
        .f64x2_abs,
        .f64x2_neg,
        .f64x2_sqrt,
        .i32x4_trunc_sat_f32x4_s,
        .i32x4_trunc_sat_f32x4_u,
        .f32x4_convert_i32x4_s,
        .f32x4_convert_i32x4_u,
        .i32x4_trunc_sat_f64x2_s_zero,
        .i32x4_trunc_sat_f64x2_u_zero,
        .f64x2_convert_low_i32x4_s,
        .f64x2_convert_low_i32x4_u,
        .f32x4_ceil,
        .f32x4_floor,
        .f32x4_trunc,
        .f32x4_nearest,
        .f64x2_ceil,
        .f64x2_floor,
        .f64x2_trunc,
        .f64x2_nearest,
        .i32x4_relaxed_trunc_f32x4_s,
        .i32x4_relaxed_trunc_f32x4_u,
        .i32x4_relaxed_trunc_f64x2_s_zero,
        .i32x4_relaxed_trunc_f64x2_u_zero,
        => true,
        else => false,
    };
}

fn Vector(comptime T: type, comptime N: usize) type {
    return @Vector(N, T);
}

fn UnsignedLane(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .int => std.meta.Int(.unsigned, @bitSizeOf(T)),
        .float => std.meta.Int(.unsigned, @bitSizeOf(T)),
        else => @compileError("unsupported lane type"),
    };
}

fn vecFromV128(comptime T: type, comptime N: usize, value: V128) Vector(T, N) {
    const U = UnsignedLane(T);
    var bits: Vector(U, N) = @bitCast(value.bytes);
    if (@sizeOf(T) > 1 and comptime builtin.cpu.arch.endian() == .big) {
        bits = @byteSwap(bits);
    }
    return switch (@typeInfo(T)) {
        .int => if (@typeInfo(T).int.signedness == .signed) @bitCast(bits) else bits,
        .float => @bitCast(bits),
        else => unreachable,
    };
}

fn v128FromVec(comptime T: type, comptime N: usize, lanes: Vector(T, N)) V128 {
    const U = UnsignedLane(T);
    var bits: Vector(U, N) = switch (@typeInfo(T)) {
        .int => if (@typeInfo(T).int.signedness == .signed) @bitCast(lanes) else lanes,
        .float => @bitCast(lanes),
        else => unreachable,
    };
    if (@sizeOf(T) > 1 and comptime builtin.cpu.arch.endian() == .big) {
        bits = @byteSwap(bits);
    }
    return v128FromBytes(@bitCast(bits));
}

fn vectorMaskToV128(comptime T: type, comptime N: usize, mask: @Vector(N, bool)) V128 {
    const U = UnsignedLane(T);
    const ones: @Vector(N, U) = @splat(std.math.maxInt(U));
    const zeros: @Vector(N, U) = @splat(0);
    return v128FromVec(U, N, @select(U, mask, ones, zeros));
}

pub fn executeUnary(opcode: SimdOpcode, src: RawVal) RawVal {
    if (std.mem.endsWith(u8, @tagName(opcode), "_splat")) {
        return RawVal.from(splat(opcode, src));
    }

    return switch (opcode) {
        .v128_not => RawVal.from(mapBytesUnary(src.readAs(V128), struct {
            fn op(value: u8) u8 {
                return ~value;
            }
        }.op)),
        .v128_any_true => RawVal.from(@as(i32, if (anyTrue(src.readAs(V128))) 1 else 0)),
        .i8x16_abs => RawVal.from(unaryInt(i8, 16, src.readAs(V128), .abs)),
        .i8x16_neg => RawVal.from(unaryInt(i8, 16, src.readAs(V128), .neg)),
        .i8x16_popcnt => RawVal.from(unaryI8Popcnt(src.readAs(V128))),
        .i8x16_all_true => RawVal.from(@as(i32, if (allTrue(i8, 16, src.readAs(V128))) 1 else 0)),
        .i8x16_bitmask => RawVal.from(bitmask(i8, 16, src.readAs(V128))),
        .i16x8_abs => RawVal.from(unaryInt(i16, 8, src.readAs(V128), .abs)),
        .i16x8_neg => RawVal.from(unaryInt(i16, 8, src.readAs(V128), .neg)),
        .i16x8_all_true => RawVal.from(@as(i32, if (allTrue(i16, 8, src.readAs(V128))) 1 else 0)),
        .i16x8_bitmask => RawVal.from(bitmask(i16, 8, src.readAs(V128))),
        .i32x4_abs => RawVal.from(unaryInt(i32, 4, src.readAs(V128), .abs)),
        .i32x4_neg => RawVal.from(unaryInt(i32, 4, src.readAs(V128), .neg)),
        .i32x4_all_true => RawVal.from(@as(i32, if (allTrue(i32, 4, src.readAs(V128))) 1 else 0)),
        .i32x4_bitmask => RawVal.from(bitmask(i32, 4, src.readAs(V128))),
        .i64x2_abs => RawVal.from(unaryInt(i64, 2, src.readAs(V128), .abs)),
        .i64x2_neg => RawVal.from(unaryInt(i64, 2, src.readAs(V128), .neg)),
        .i64x2_all_true => RawVal.from(@as(i32, if (allTrue(i64, 2, src.readAs(V128))) 1 else 0)),
        .i64x2_bitmask => RawVal.from(bitmask(i64, 2, src.readAs(V128))),
        .f32x4_abs => RawVal.from(unaryFloat(f32, 4, src.readAs(V128), .abs)),
        .f32x4_neg => RawVal.from(unaryFloat(f32, 4, src.readAs(V128), .neg)),
        .f32x4_sqrt => RawVal.from(unaryFloat(f32, 4, src.readAs(V128), .sqrt)),
        .f32x4_ceil => RawVal.from(unaryFloat(f32, 4, src.readAs(V128), .ceil)),
        .f32x4_floor => RawVal.from(unaryFloat(f32, 4, src.readAs(V128), .floor)),
        .f32x4_trunc => RawVal.from(unaryFloat(f32, 4, src.readAs(V128), .trunc)),
        .f32x4_nearest => RawVal.from(unaryFloat(f32, 4, src.readAs(V128), .nearest)),
        .f64x2_abs => RawVal.from(unaryFloat(f64, 2, src.readAs(V128), .abs)),
        .f64x2_neg => RawVal.from(unaryFloat(f64, 2, src.readAs(V128), .neg)),
        .f64x2_sqrt => RawVal.from(unaryFloat(f64, 2, src.readAs(V128), .sqrt)),
        .f64x2_ceil => RawVal.from(unaryFloat(f64, 2, src.readAs(V128), .ceil)),
        .f64x2_floor => RawVal.from(unaryFloat(f64, 2, src.readAs(V128), .floor)),
        .f64x2_trunc => RawVal.from(unaryFloat(f64, 2, src.readAs(V128), .trunc)),
        .f64x2_nearest => RawVal.from(unaryFloat(f64, 2, src.readAs(V128), .nearest)),
        .i16x8_extadd_pairwise_i8x16_s => RawVal.from(extaddPairwise(i8, i16, 8, src.readAs(V128), true)),
        .i16x8_extadd_pairwise_i8x16_u => RawVal.from(extaddPairwise(u8, i16, 8, src.readAs(V128), false)),
        .i32x4_extadd_pairwise_i16x8_s => RawVal.from(extaddPairwise(i16, i32, 4, src.readAs(V128), true)),
        .i32x4_extadd_pairwise_i16x8_u => RawVal.from(extaddPairwise(u16, i32, 4, src.readAs(V128), false)),
        .i16x8_extend_low_i8x16_s => RawVal.from(extendHalf(i8, i16, src.readAs(V128), .low, true)),
        .i16x8_extend_high_i8x16_s => RawVal.from(extendHalf(i8, i16, src.readAs(V128), .high, true)),
        .i16x8_extend_low_i8x16_u => RawVal.from(extendHalf(u8, i16, src.readAs(V128), .low, false)),
        .i16x8_extend_high_i8x16_u => RawVal.from(extendHalf(u8, i16, src.readAs(V128), .high, false)),
        .i32x4_extend_low_i16x8_s => RawVal.from(extendHalf(i16, i32, src.readAs(V128), .low, true)),
        .i32x4_extend_high_i16x8_s => RawVal.from(extendHalf(i16, i32, src.readAs(V128), .high, true)),
        .i32x4_extend_low_i16x8_u => RawVal.from(extendHalf(u16, i32, src.readAs(V128), .low, false)),
        .i32x4_extend_high_i16x8_u => RawVal.from(extendHalf(u16, i32, src.readAs(V128), .high, false)),
        .i64x2_extend_low_i32x4_s => RawVal.from(extendHalf(i32, i64, src.readAs(V128), .low, true)),
        .i64x2_extend_high_i32x4_s => RawVal.from(extendHalf(i32, i64, src.readAs(V128), .high, true)),
        .i64x2_extend_low_i32x4_u => RawVal.from(extendHalf(u32, i64, src.readAs(V128), .low, false)),
        .i64x2_extend_high_i32x4_u => RawVal.from(extendHalf(u32, i64, src.readAs(V128), .high, false)),
        .f32x4_demote_f64x2_zero => RawVal.from(demoteF64x2Zero(src.readAs(V128))),
        .f64x2_promote_low_f32x4 => RawVal.from(promoteLowF32x4(src.readAs(V128))),
        .i32x4_trunc_sat_f32x4_s, .i32x4_relaxed_trunc_f32x4_s => RawVal.from(truncSatF32x4ToI32x4(src.readAs(V128), true)),
        .i32x4_trunc_sat_f32x4_u, .i32x4_relaxed_trunc_f32x4_u => RawVal.from(truncSatF32x4ToI32x4(src.readAs(V128), false)),
        .i32x4_trunc_sat_f64x2_s_zero, .i32x4_relaxed_trunc_f64x2_s_zero => RawVal.from(truncSatF64x2ToI32x4Zero(src.readAs(V128), true)),
        .i32x4_trunc_sat_f64x2_u_zero, .i32x4_relaxed_trunc_f64x2_u_zero => RawVal.from(truncSatF64x2ToI32x4Zero(src.readAs(V128), false)),
        .f32x4_convert_i32x4_s => RawVal.from(convertI32x4ToF32x4(src.readAs(V128), true)),
        .f32x4_convert_i32x4_u => RawVal.from(convertI32x4ToF32x4(src.readAs(V128), false)),
        .f64x2_convert_low_i32x4_s => RawVal.from(convertLowI32x4ToF64x2(src.readAs(V128), true)),
        .f64x2_convert_low_i32x4_u => RawVal.from(convertLowI32x4ToF64x2(src.readAs(V128), false)),
        else => unreachable,
    };
}

pub fn executeBinary(opcode: SimdOpcode, lhs: RawVal, rhs: RawVal) RawVal {
    return switch (opcode) {
        .v128_and => RawVal.from(bytesBinary(lhs.readAs(V128), rhs.readAs(V128), .@"and")),
        .v128_andnot => RawVal.from(bytesBinary(lhs.readAs(V128), rhs.readAs(V128), .andnot)),
        .v128_or => RawVal.from(bytesBinary(lhs.readAs(V128), rhs.readAs(V128), .@"or")),
        .v128_xor => RawVal.from(bytesBinary(lhs.readAs(V128), rhs.readAs(V128), .xor)),
        .i8x16_swizzle, .i8x16_relaxed_swizzle => RawVal.from(swizzle(lhs.readAs(V128), rhs.readAs(V128))),
        .i8x16_add => RawVal.from(binaryInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .add)),
        .i8x16_add_sat_s => RawVal.from(binaryInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .add_sat_s)),
        .i8x16_add_sat_u => RawVal.from(binaryInt(u8, 16, lhs.readAs(V128), rhs.readAs(V128), .add_sat_u)),
        .i8x16_sub => RawVal.from(binaryInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .sub)),
        .i8x16_sub_sat_s => RawVal.from(binaryInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .sub_sat_s)),
        .i8x16_sub_sat_u => RawVal.from(binaryInt(u8, 16, lhs.readAs(V128), rhs.readAs(V128), .sub_sat_u)),
        .i8x16_min_s => RawVal.from(binaryInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .min)),
        .i8x16_min_u => RawVal.from(binaryInt(u8, 16, lhs.readAs(V128), rhs.readAs(V128), .min)),
        .i8x16_max_s => RawVal.from(binaryInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .max)),
        .i8x16_max_u => RawVal.from(binaryInt(u8, 16, lhs.readAs(V128), rhs.readAs(V128), .max)),
        .i8x16_avgr_u => RawVal.from(binaryInt(u8, 16, lhs.readAs(V128), rhs.readAs(V128), .avgr_u)),
        .i16x8_q15mulr_sat_s, .i16x8_relaxed_q15mulr_s => RawVal.from(q15mulr(lhs.readAs(V128), rhs.readAs(V128))),
        .i16x8_add => RawVal.from(binaryInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .add)),
        .i16x8_add_sat_s => RawVal.from(binaryInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .add_sat_s)),
        .i16x8_add_sat_u => RawVal.from(binaryInt(u16, 8, lhs.readAs(V128), rhs.readAs(V128), .add_sat_u)),
        .i16x8_sub => RawVal.from(binaryInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .sub)),
        .i16x8_sub_sat_s => RawVal.from(binaryInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .sub_sat_s)),
        .i16x8_sub_sat_u => RawVal.from(binaryInt(u16, 8, lhs.readAs(V128), rhs.readAs(V128), .sub_sat_u)),
        .i16x8_mul => RawVal.from(binaryInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .mul)),
        .i16x8_min_s => RawVal.from(binaryInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .min)),
        .i16x8_min_u => RawVal.from(binaryInt(u16, 8, lhs.readAs(V128), rhs.readAs(V128), .min)),
        .i16x8_max_s => RawVal.from(binaryInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .max)),
        .i16x8_max_u => RawVal.from(binaryInt(u16, 8, lhs.readAs(V128), rhs.readAs(V128), .max)),
        .i16x8_avgr_u => RawVal.from(binaryInt(u16, 8, lhs.readAs(V128), rhs.readAs(V128), .avgr_u)),
        .i32x4_add => RawVal.from(binaryInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .add)),
        .i32x4_sub => RawVal.from(binaryInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .sub)),
        .i32x4_mul => RawVal.from(binaryInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .mul)),
        .i32x4_min_s => RawVal.from(binaryInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .min)),
        .i32x4_min_u => RawVal.from(binaryInt(u32, 4, lhs.readAs(V128), rhs.readAs(V128), .min)),
        .i32x4_max_s => RawVal.from(binaryInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .max)),
        .i32x4_max_u => RawVal.from(binaryInt(u32, 4, lhs.readAs(V128), rhs.readAs(V128), .max)),
        .i32x4_dot_i16x8_s => RawVal.from(dotI16x8ToI32x4(lhs.readAs(V128), rhs.readAs(V128))),
        .i64x2_add => RawVal.from(binaryInt(i64, 2, lhs.readAs(V128), rhs.readAs(V128), .add)),
        .i64x2_sub => RawVal.from(binaryInt(i64, 2, lhs.readAs(V128), rhs.readAs(V128), .sub)),
        .i64x2_mul => RawVal.from(binaryInt(i64, 2, lhs.readAs(V128), rhs.readAs(V128), .mul)),
        .f32x4_add => RawVal.from(binaryFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .add)),
        .f32x4_sub => RawVal.from(binaryFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .sub)),
        .f32x4_mul => RawVal.from(binaryFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .mul)),
        .f32x4_div => RawVal.from(binaryFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .div)),
        .f32x4_min, .f32x4_relaxed_min => RawVal.from(binaryFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .min)),
        .f32x4_max, .f32x4_relaxed_max => RawVal.from(binaryFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .max)),
        .f32x4_pmin => RawVal.from(binaryFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .pmin)),
        .f32x4_pmax => RawVal.from(binaryFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .pmax)),
        .f64x2_add => RawVal.from(binaryFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .add)),
        .f64x2_sub => RawVal.from(binaryFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .sub)),
        .f64x2_mul => RawVal.from(binaryFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .mul)),
        .f64x2_div => RawVal.from(binaryFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .div)),
        .f64x2_min, .f64x2_relaxed_min => RawVal.from(binaryFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .min)),
        .f64x2_max, .f64x2_relaxed_max => RawVal.from(binaryFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .max)),
        .f64x2_pmin => RawVal.from(binaryFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .pmin)),
        .f64x2_pmax => RawVal.from(binaryFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .pmax)),
        .i8x16_narrow_i16x8_s => RawVal.from(narrow(i16, i8, 8, lhs.readAs(V128), rhs.readAs(V128), true)),
        .i8x16_narrow_i16x8_u => RawVal.from(narrow(u16, i8, 8, lhs.readAs(V128), rhs.readAs(V128), false)),
        .i16x8_narrow_i32x4_s => RawVal.from(narrow(i32, i16, 4, lhs.readAs(V128), rhs.readAs(V128), true)),
        .i16x8_narrow_i32x4_u => RawVal.from(narrow(u32, i16, 4, lhs.readAs(V128), rhs.readAs(V128), false)),
        .i16x8_extmul_low_i8x16_s => RawVal.from(extmul(i8, i16, lhs.readAs(V128), rhs.readAs(V128), .low, true)),
        .i16x8_extmul_high_i8x16_s => RawVal.from(extmul(i8, i16, lhs.readAs(V128), rhs.readAs(V128), .high, true)),
        .i16x8_extmul_low_i8x16_u => RawVal.from(extmul(u8, i16, lhs.readAs(V128), rhs.readAs(V128), .low, false)),
        .i16x8_extmul_high_i8x16_u => RawVal.from(extmul(u8, i16, lhs.readAs(V128), rhs.readAs(V128), .high, false)),
        .i32x4_extmul_low_i16x8_s => RawVal.from(extmul(i16, i32, lhs.readAs(V128), rhs.readAs(V128), .low, true)),
        .i32x4_extmul_high_i16x8_s => RawVal.from(extmul(i16, i32, lhs.readAs(V128), rhs.readAs(V128), .high, true)),
        .i32x4_extmul_low_i16x8_u => RawVal.from(extmul(u16, i32, lhs.readAs(V128), rhs.readAs(V128), .low, false)),
        .i32x4_extmul_high_i16x8_u => RawVal.from(extmul(u16, i32, lhs.readAs(V128), rhs.readAs(V128), .high, false)),
        .i64x2_extmul_low_i32x4_s => RawVal.from(extmul(i32, i64, lhs.readAs(V128), rhs.readAs(V128), .low, true)),
        .i64x2_extmul_high_i32x4_s => RawVal.from(extmul(i32, i64, lhs.readAs(V128), rhs.readAs(V128), .high, true)),
        .i64x2_extmul_low_i32x4_u => RawVal.from(extmul(u32, i64, lhs.readAs(V128), rhs.readAs(V128), .low, false)),
        .i64x2_extmul_high_i32x4_u => RawVal.from(extmul(u32, i64, lhs.readAs(V128), rhs.readAs(V128), .high, false)),
        .i16x8_relaxed_dot_i8x16_i7x16_s => RawVal.from(relaxedDotI8x16ToI16x8(lhs.readAs(V128), rhs.readAs(V128))),
        else => unreachable,
    };
}

pub fn executeTernary(opcode: SimdOpcode, first: RawVal, second: RawVal, third: RawVal) RawVal {
    return switch (opcode) {
        .v128_bitselect,
        .i8x16_relaxed_laneselect,
        .i16x8_relaxed_laneselect,
        .i32x4_relaxed_laneselect,
        .i64x2_relaxed_laneselect,
        => RawVal.from(bitselect(first.readAs(V128), second.readAs(V128), third.readAs(V128))),
        .f32x4_relaxed_madd => RawVal.from(floatMulAddVec(f32, 4, first.readAs(V128), second.readAs(V128), third.readAs(V128), false)),
        .f32x4_relaxed_nmadd => RawVal.from(floatMulAddVec(f32, 4, first.readAs(V128), second.readAs(V128), third.readAs(V128), true)),
        .f64x2_relaxed_madd => RawVal.from(floatMulAddVec(f64, 2, first.readAs(V128), second.readAs(V128), third.readAs(V128), false)),
        .f64x2_relaxed_nmadd => RawVal.from(floatMulAddVec(f64, 2, first.readAs(V128), second.readAs(V128), third.readAs(V128), true)),
        .i32x4_relaxed_dot_i8x16_i7x16_add_s => RawVal.from(relaxedDotAddI8x16ToI32x4(first.readAs(V128), second.readAs(V128), third.readAs(V128))),
        else => unreachable,
    };
}

pub fn executeCompare(opcode: SimdOpcode, lhs: RawVal, rhs: RawVal) RawVal {
    return switch (opcode) {
        .i8x16_eq => RawVal.from(compareInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .eq)),
        .i8x16_ne => RawVal.from(compareInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .ne)),
        .i8x16_lt_s => RawVal.from(compareInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .lt)),
        .i8x16_lt_u => RawVal.from(compareInt(u8, 16, lhs.readAs(V128), rhs.readAs(V128), .lt)),
        .i8x16_gt_s => RawVal.from(compareInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .gt)),
        .i8x16_gt_u => RawVal.from(compareInt(u8, 16, lhs.readAs(V128), rhs.readAs(V128), .gt)),
        .i8x16_le_s => RawVal.from(compareInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .le)),
        .i8x16_le_u => RawVal.from(compareInt(u8, 16, lhs.readAs(V128), rhs.readAs(V128), .le)),
        .i8x16_ge_s => RawVal.from(compareInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .ge)),
        .i8x16_ge_u => RawVal.from(compareInt(u8, 16, lhs.readAs(V128), rhs.readAs(V128), .ge)),
        .i16x8_eq => RawVal.from(compareInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .eq)),
        .i16x8_ne => RawVal.from(compareInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .ne)),
        .i16x8_lt_s => RawVal.from(compareInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .lt)),
        .i16x8_lt_u => RawVal.from(compareInt(u16, 8, lhs.readAs(V128), rhs.readAs(V128), .lt)),
        .i16x8_gt_s => RawVal.from(compareInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .gt)),
        .i16x8_gt_u => RawVal.from(compareInt(u16, 8, lhs.readAs(V128), rhs.readAs(V128), .gt)),
        .i16x8_le_s => RawVal.from(compareInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .le)),
        .i16x8_le_u => RawVal.from(compareInt(u16, 8, lhs.readAs(V128), rhs.readAs(V128), .le)),
        .i16x8_ge_s => RawVal.from(compareInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .ge)),
        .i16x8_ge_u => RawVal.from(compareInt(u16, 8, lhs.readAs(V128), rhs.readAs(V128), .ge)),
        .i32x4_eq => RawVal.from(compareInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .eq)),
        .i32x4_ne => RawVal.from(compareInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .ne)),
        .i32x4_lt_s => RawVal.from(compareInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .lt)),
        .i32x4_lt_u => RawVal.from(compareInt(u32, 4, lhs.readAs(V128), rhs.readAs(V128), .lt)),
        .i32x4_gt_s => RawVal.from(compareInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .gt)),
        .i32x4_gt_u => RawVal.from(compareInt(u32, 4, lhs.readAs(V128), rhs.readAs(V128), .gt)),
        .i32x4_le_s => RawVal.from(compareInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .le)),
        .i32x4_le_u => RawVal.from(compareInt(u32, 4, lhs.readAs(V128), rhs.readAs(V128), .le)),
        .i32x4_ge_s => RawVal.from(compareInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .ge)),
        .i32x4_ge_u => RawVal.from(compareInt(u32, 4, lhs.readAs(V128), rhs.readAs(V128), .ge)),
        .i64x2_eq => RawVal.from(compareInt(i64, 2, lhs.readAs(V128), rhs.readAs(V128), .eq)),
        .i64x2_ne => RawVal.from(compareInt(i64, 2, lhs.readAs(V128), rhs.readAs(V128), .ne)),
        .i64x2_lt_s => RawVal.from(compareInt(i64, 2, lhs.readAs(V128), rhs.readAs(V128), .lt)),
        .i64x2_gt_s => RawVal.from(compareInt(i64, 2, lhs.readAs(V128), rhs.readAs(V128), .gt)),
        .i64x2_le_s => RawVal.from(compareInt(i64, 2, lhs.readAs(V128), rhs.readAs(V128), .le)),
        .i64x2_ge_s => RawVal.from(compareInt(i64, 2, lhs.readAs(V128), rhs.readAs(V128), .ge)),
        .f32x4_eq => RawVal.from(compareFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .eq)),
        .f32x4_ne => RawVal.from(compareFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .ne)),
        .f32x4_lt => RawVal.from(compareFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .lt)),
        .f32x4_gt => RawVal.from(compareFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .gt)),
        .f32x4_le => RawVal.from(compareFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .le)),
        .f32x4_ge => RawVal.from(compareFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .ge)),
        .f64x2_eq => RawVal.from(compareFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .eq)),
        .f64x2_ne => RawVal.from(compareFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .ne)),
        .f64x2_lt => RawVal.from(compareFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .lt)),
        .f64x2_gt => RawVal.from(compareFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .gt)),
        .f64x2_le => RawVal.from(compareFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .le)),
        .f64x2_ge => RawVal.from(compareFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .ge)),
        else => unreachable,
    };
}

pub fn executeShift(opcode: SimdOpcode, lhs: RawVal, rhs: RawVal) RawVal {
    const amount = rhs.readAs(u32);
    return switch (opcode) {
        .i8x16_shl => RawVal.from(shiftInt(i8, 16, lhs.readAs(V128), amount, .shl)),
        .i8x16_shr_s => RawVal.from(shiftInt(i8, 16, lhs.readAs(V128), amount, .shr_s)),
        .i8x16_shr_u => RawVal.from(shiftInt(u8, 16, lhs.readAs(V128), amount, .shr_u)),
        .i16x8_shl => RawVal.from(shiftInt(i16, 8, lhs.readAs(V128), amount, .shl)),
        .i16x8_shr_s => RawVal.from(shiftInt(i16, 8, lhs.readAs(V128), amount, .shr_s)),
        .i16x8_shr_u => RawVal.from(shiftInt(u16, 8, lhs.readAs(V128), amount, .shr_u)),
        .i32x4_shl => RawVal.from(shiftInt(i32, 4, lhs.readAs(V128), amount, .shl)),
        .i32x4_shr_s => RawVal.from(shiftInt(i32, 4, lhs.readAs(V128), amount, .shr_s)),
        .i32x4_shr_u => RawVal.from(shiftInt(u32, 4, lhs.readAs(V128), amount, .shr_u)),
        .i64x2_shl => RawVal.from(shiftInt(i64, 2, lhs.readAs(V128), amount, .shl)),
        .i64x2_shr_s => RawVal.from(shiftInt(i64, 2, lhs.readAs(V128), amount, .shr_s)),
        .i64x2_shr_u => RawVal.from(shiftInt(u64, 2, lhs.readAs(V128), amount, .shr_u)),
        else => unreachable,
    };
}

pub fn extractLane(opcode: SimdOpcode, src: RawVal, lane: u8) RawVal {
    const value = src.readAs(V128);
    return switch (opcode) {
        .i8x16_extract_lane_s => RawVal.from(@as(i32, readLane(i8, value.bytes, lane))),
        .i8x16_extract_lane_u => RawVal.from(@as(i32, readLane(u8, value.bytes, lane))),
        .i16x8_extract_lane_s => RawVal.from(@as(i32, readLane(i16, value.bytes, lane))),
        .i16x8_extract_lane_u => RawVal.from(@as(i32, readLane(u16, value.bytes, lane))),
        .i32x4_extract_lane => RawVal.from(readLane(i32, value.bytes, lane)),
        .i64x2_extract_lane => RawVal.from(readLane(i64, value.bytes, lane)),
        .f32x4_extract_lane => RawVal.from(readLane(f32, value.bytes, lane)),
        .f64x2_extract_lane => RawVal.from(readLane(f64, value.bytes, lane)),
        else => unreachable,
    };
}

pub fn replaceLane(opcode: SimdOpcode, src_vec: RawVal, src_lane: RawVal, lane: u8) RawVal {
    var out = src_vec.readAs(V128);
    switch (opcode) {
        .i8x16_replace_lane => writeLane(i8, &out.bytes, lane, src_lane.readAs(i8)),
        .i16x8_replace_lane => writeLane(i16, &out.bytes, lane, src_lane.readAs(i16)),
        .i32x4_replace_lane => writeLane(i32, &out.bytes, lane, src_lane.readAs(i32)),
        .i64x2_replace_lane => writeLane(i64, &out.bytes, lane, src_lane.readAs(i64)),
        .f32x4_replace_lane => writeLane(f32, &out.bytes, lane, src_lane.readAs(f32)),
        .f64x2_replace_lane => writeLane(f64, &out.bytes, lane, src_lane.readAs(f64)),
        else => unreachable,
    }
    return RawVal.from(out);
}

pub fn shuffleVectors(lhs: RawVal, rhs: RawVal, lanes: [16]u8) RawVal {
    return RawVal.from(shuffleBytes(lhs.readAs(V128), rhs.readAs(V128), lanes));
}

pub fn load(opcode: SimdOpcode, memory: []const u8, addr: u32, offset: u32, lane: ?u8, src_vec: ?RawVal) V128 {
    const ea = addr +% offset;
    return switch (opcode) {
        .v128_load => blk: {
            var out: [16]u8 = undefined;
            @memcpy(out[0..], memory[ea .. ea + 16]);
            break :blk v128FromBytes(out);
        },
        .i16x8_load8x8_s => wideningLoad(i8, i16, 8, memory[ea .. ea + 8], true),
        .i16x8_load8x8_u => wideningLoad(u8, i16, 8, memory[ea .. ea + 8], false),
        .i32x4_load16x4_s => wideningLoad(i16, i32, 4, memory[ea .. ea + 8], true),
        .i32x4_load16x4_u => wideningLoad(u16, i32, 4, memory[ea .. ea + 8], false),
        .i64x2_load32x2_s => wideningLoad(i32, i64, 2, memory[ea .. ea + 8], true),
        .i64x2_load32x2_u => wideningLoad(u32, i64, 2, memory[ea .. ea + 8], false),
        .v8x16_load_splat => loadSplat(u8, i8, 16, memory[ea .. ea + 1]),
        .v16x8_load_splat => loadSplat(u16, i16, 8, memory[ea .. ea + 2]),
        .v32x4_load_splat => loadSplat(u32, i32, 4, memory[ea .. ea + 4]),
        .v64x2_load_splat => loadSplat(u64, i64, 2, memory[ea .. ea + 8]),
        .v128_load32_zero => loadZeroExtended(u32, 4, memory[ea .. ea + 4]),
        .v128_load64_zero => loadZeroExtended(u64, 8, memory[ea .. ea + 8]),
        .v128_load8_lane, .v128_load16_lane, .v128_load32_lane, .v128_load64_lane => loadLane(opcode, src_vec.?.readAs(V128), memory[ea .. ea + laneImmediateFromOpcode(opcode)], lane.?),
        else => unreachable,
    };
}

pub fn store(opcode: SimdOpcode, memory: []u8, addr: u32, offset: u32, lane: ?u8, src: RawVal) void {
    const ea = addr +% offset;
    switch (opcode) {
        .v128_store => {
            const bytes = src.readAs(V128).bytes;
            @memcpy(memory[ea .. ea + 16], bytes[0..]);
        },
        .v128_store8_lane, .v128_store16_lane, .v128_store32_lane, .v128_store64_lane => {
            const bytes = laneBytes(src.readAs(V128), lane.?, laneImmediateFromOpcode(opcode));
            @memcpy(memory[ea .. ea + bytes.len], bytes[0..]);
        },
        else => unreachable,
    }
}

fn mapBytesUnary(value: V128, comptime func: fn (u8) u8) V128 {
    const lanes: @Vector(16, u8) = @bitCast(value.bytes);
    var out: @Vector(16, u8) = undefined;
    inline for (0..16) |i| out[i] = func(lanes[i]);
    return v128FromBytes(@bitCast(out));
}

fn bytesBinary(lhs: V128, rhs: V128, comptime kind: enum { @"and", andnot, @"or", xor }) V128 {
    const a: @Vector(16, u8) = @bitCast(lhs.bytes);
    const b: @Vector(16, u8) = @bitCast(rhs.bytes);
    const out: @Vector(16, u8) = switch (kind) {
        .@"and" => a & b,
        .andnot => a & ~b,
        .@"or" => a | b,
        .xor => a ^ b,
    };
    return v128FromBytes(@bitCast(out));
}

fn anyTrue(value: V128) bool {
    const lanes: @Vector(16, u8) = @bitCast(value.bytes);
    return @reduce(.Or, lanes != @as(@Vector(16, u8), @splat(0)));
}

fn splat(opcode: SimdOpcode, src: RawVal) V128 {
    return switch (shapeOf(opcode).?) {
        .i8x16 => splatGeneric(i8, 16, src.readAs(i8)),
        .i16x8 => splatGeneric(i16, 8, src.readAs(i16)),
        .i32x4 => splatGeneric(i32, 4, src.readAs(i32)),
        .i64x2 => splatGeneric(i64, 2, src.readAs(i64)),
        .f32x4 => splatGeneric(f32, 4, src.readAs(f32)),
        .f64x2 => splatGeneric(f64, 2, src.readAs(f64)),
    };
}

fn splatGeneric(comptime T: type, comptime N: usize, value: T) V128 {
    return v128FromVec(T, N, @as(Vector(T, N), @splat(value)));
}

fn readLane(comptime T: type, bytes: [16]u8, lane: u8) T {
    const width = @sizeOf(T);
    const start = @as(usize, lane) * width;
    const fixed: *const [width]u8 = @ptrCast(bytes[start .. start + width].ptr);
    return switch (@typeInfo(T)) {
        .int => {
            const U = std.meta.Int(.unsigned, @bitSizeOf(T));
            const bits = std.mem.readInt(U, fixed, .little);
            return if (@typeInfo(T).int.signedness == .signed) @as(T, @bitCast(bits)) else @as(T, bits);
        },
        .float => {
            const U = std.meta.Int(.unsigned, @bitSizeOf(T));
            const bits = std.mem.readInt(U, fixed, .little);
            return @as(T, @bitCast(bits));
        },
        else => @compileError("unsupported lane type"),
    };
}

fn writeLane(comptime T: type, bytes: *[16]u8, lane: u8, value: T) void {
    const width = @sizeOf(T);
    const start = @as(usize, lane) * width;
    const fixed: *[width]u8 = @ptrCast(bytes[start .. start + width].ptr);
    switch (@typeInfo(T)) {
        .int => {
            const U = std.meta.Int(.unsigned, @bitSizeOf(T));
            const bits: U = if (@typeInfo(T).int.signedness == .signed) @bitCast(value) else value;
            std.mem.writeInt(U, fixed, bits, .little);
        },
        .float => {
            const U = std.meta.Int(.unsigned, @bitSizeOf(T));
            std.mem.writeInt(U, fixed, @as(U, @bitCast(value)), .little);
        },
        else => @compileError("unsupported lane type"),
    }
}

fn allTrue(comptime T: type, comptime N: usize, value: V128) bool {
    const lanes = vecFromV128(T, N, value);
    const zero: Vector(T, N) = @splat(0);
    return @reduce(.And, lanes != zero);
}

fn bitmask(comptime T: type, comptime N: usize, value: V128) i32 {
    var mask: u32 = 0;
    inline for (0..N) |i| {
        const lane = readLane(T, value.bytes, @intCast(i));
        const sign = switch (@typeInfo(T)) {
            .int => @as(bool, if (@typeInfo(T).int.signedness == .signed) lane < 0 else ((lane >> (@bitSizeOf(T) - 1)) & 1) != 0),
            else => false,
        };
        if (sign) mask |= (@as(u32, 1) << @as(u5, @intCast(i)));
    }
    return @bitCast(mask);
}

fn unaryInt(comptime T: type, comptime N: usize, value: V128, comptime kind: enum { abs, neg }) V128 {
    const lanes = vecFromV128(T, N, value);
    const zero: Vector(T, N) = @splat(0);
    const results: Vector(T, N) = switch (kind) {
        .neg => zero -% lanes,
        .abs => @select(T, lanes < zero, zero -% lanes, lanes),
    };
    return v128FromVec(T, N, results);
}

fn unaryI8Popcnt(value: V128) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..16) |i| {
        const lane = readLane(u8, value.bytes, @intCast(i));
        writeLane(i8, &out, @intCast(i), @as(i8, @bitCast(@as(u8, @intCast(@popCount(lane))))));
    }
    return v128FromBytes(out);
}

fn unaryFloat(comptime T: type, comptime N: usize, value: V128, comptime kind: enum { abs, neg, ceil, floor, trunc, nearest, sqrt }) V128 {
    const lanes = vecFromV128(T, N, value);
    switch (kind) {
        .abs => return v128FromVec(T, N, @abs(lanes)),
        .neg => return v128FromVec(T, N, -lanes),
        .sqrt => return v128FromVec(T, N, @sqrt(lanes)),
        .ceil => return v128FromVec(T, N, @ceil(lanes)),
        .floor => return v128FromVec(T, N, @floor(lanes)),
        .trunc => return v128FromVec(T, N, @trunc(lanes)),
        .nearest => {},
    }

    var out = std.mem.zeroes([16]u8);
    inline for (0..N) |i| {
        const lane = readLane(T, value.bytes, @intCast(i));
        const result: T = switch (kind) {
            .abs => @abs(lane),
            .neg => -lane,
            .ceil => helper.ceil(lane),
            .floor => helper.floor(lane),
            .trunc => helper.trunc(lane),
            .nearest => helper.nearest(lane),
            .sqrt => helper.sqrt(lane),
        };
        writeLane(T, &out, @intCast(i), result);
    }
    return v128FromBytes(out);
}

fn extaddPairwise(comptime SrcT: type, comptime DstT: type, comptime N: usize, value: V128, comptime signed: bool) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..N) |i| {
        const a = readLane(SrcT, value.bytes, @intCast(i * 2));
        const b = readLane(SrcT, value.bytes, @intCast(i * 2 + 1));
        const result: DstT = if (signed)
            @as(DstT, a) + @as(DstT, b)
        else
            @as(DstT, @intCast(a)) + @as(DstT, @intCast(b));
        writeLane(DstT, &out, @intCast(i), result);
    }
    return v128FromBytes(out);
}

fn extendHalf(comptime SrcT: type, comptime DstT: type, value: V128, comptime which: enum { low, high }, comptime signed: bool) V128 {
    const src_lanes = 16 / @sizeOf(SrcT);
    const dst_lanes = 16 / @sizeOf(DstT);
    const start = if (which == .low) 0 else src_lanes / 2;
    var out = std.mem.zeroes([16]u8);
    inline for (0..dst_lanes) |i| {
        const lane = readLane(SrcT, value.bytes, @intCast(start + i));
        const result: DstT = if (signed) @as(DstT, lane) else @as(DstT, @intCast(lane));
        writeLane(DstT, &out, @intCast(i), result);
    }
    return v128FromBytes(out);
}

fn demoteF64x2Zero(value: V128) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..2) |i| writeLane(f32, &out, @intCast(i), @floatCast(readLane(f64, value.bytes, @intCast(i))));
    return v128FromBytes(out);
}

fn promoteLowF32x4(value: V128) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..2) |i| writeLane(f64, &out, @intCast(i), @floatCast(readLane(f32, value.bytes, @intCast(i))));
    return v128FromBytes(out);
}

fn truncSatF32x4ToI32x4(value: V128, comptime signed: bool) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..4) |i| {
        const lane = readLane(f32, value.bytes, @intCast(i));
        if (signed) {
            writeLane(i32, &out, @intCast(i), helper.truncateSaturateInto(i32, lane));
        } else {
            const bits = helper.truncateSaturateInto(u32, lane);
            writeLane(i32, &out, @intCast(i), @bitCast(bits));
        }
    }
    return v128FromBytes(out);
}

fn truncSatF64x2ToI32x4Zero(value: V128, comptime signed: bool) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..2) |i| {
        const lane = readLane(f64, value.bytes, @intCast(i));
        if (signed) {
            writeLane(i32, &out, @intCast(i), helper.truncateSaturateInto(i32, lane));
        } else {
            const bits = helper.truncateSaturateInto(u32, lane);
            writeLane(i32, &out, @intCast(i), @bitCast(bits));
        }
    }
    return v128FromBytes(out);
}

fn convertI32x4ToF32x4(value: V128, comptime signed: bool) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..4) |i| {
        if (signed) {
            writeLane(f32, &out, @intCast(i), @floatFromInt(readLane(i32, value.bytes, @intCast(i))));
        } else {
            writeLane(f32, &out, @intCast(i), @floatFromInt(readLane(u32, value.bytes, @intCast(i))));
        }
    }
    return v128FromBytes(out);
}

fn convertLowI32x4ToF64x2(value: V128, comptime signed: bool) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..2) |i| {
        if (signed) {
            writeLane(f64, &out, @intCast(i), @floatFromInt(readLane(i32, value.bytes, @intCast(i))));
        } else {
            writeLane(f64, &out, @intCast(i), @floatFromInt(readLane(u32, value.bytes, @intCast(i))));
        }
    }
    return v128FromBytes(out);
}

fn binaryInt(comptime T: type, comptime N: usize, lhs: V128, rhs: V128, comptime kind: enum { add, add_sat_s, add_sat_u, sub, sub_sat_s, sub_sat_u, mul, min, max, avgr_u }) V128 {
    const a = vecFromV128(T, N, lhs);
    const b = vecFromV128(T, N, rhs);
    switch (kind) {
        .add => return v128FromVec(T, N, a +% b),
        .sub => return v128FromVec(T, N, a -% b),
        .mul => return v128FromVec(T, N, a *% b),
        .min => return v128FromVec(T, N, @select(T, a < b, a, b)),
        .max => return v128FromVec(T, N, @select(T, a > b, a, b)),
        else => {},
    }

    var out = std.mem.zeroes([16]u8);
    inline for (0..N) |i| {
        const lane_a = readLane(T, lhs.bytes, @intCast(i));
        const lane_b = readLane(T, rhs.bytes, @intCast(i));
        const result: T = switch (kind) {
            .add => lane_a +% lane_b,
            .sub => lane_a -% lane_b,
            .mul => lane_a *% lane_b,
            .min => if (lane_a < lane_b) lane_a else lane_b,
            .max => if (lane_a > lane_b) lane_a else lane_b,
            .avgr_u => avgUnsigned(T, lane_a, lane_b),
            .add_sat_s => satAddSigned(T, lane_a, lane_b),
            .sub_sat_s => satSubSigned(T, lane_a, lane_b),
            .add_sat_u => satAddUnsigned(T, lane_a, lane_b),
            .sub_sat_u => satSubUnsigned(T, lane_a, lane_b),
        };
        writeLane(T, &out, @intCast(i), result);
    }
    return v128FromBytes(out);
}

fn q15mulr(lhs: V128, rhs: V128) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..8) |i| {
        const a = @as(i32, readLane(i16, lhs.bytes, @intCast(i)));
        const b = @as(i32, readLane(i16, rhs.bytes, @intCast(i)));
        const product = a * b;
        const rounded = (product + 0x4000) >> 15;
        writeLane(i16, &out, @intCast(i), clampSigned(i16, rounded));
    }
    return v128FromBytes(out);
}

fn binaryFloat(comptime T: type, comptime N: usize, lhs: V128, rhs: V128, comptime kind: enum { add, sub, mul, div, min, max, pmin, pmax }) V128 {
    const a = vecFromV128(T, N, lhs);
    const b = vecFromV128(T, N, rhs);
    switch (kind) {
        .add => return v128FromVec(T, N, a + b),
        .sub => return v128FromVec(T, N, a - b),
        .mul => return v128FromVec(T, N, a * b),
        .div => return v128FromVec(T, N, a / b),
        else => {},
    }

    var out = std.mem.zeroes([16]u8);
    inline for (0..N) |i| {
        const lane_a = readLane(T, lhs.bytes, @intCast(i));
        const lane_b = readLane(T, rhs.bytes, @intCast(i));
        const result: T = switch (kind) {
            .add => lane_a + lane_b,
            .sub => lane_a - lane_b,
            .mul => lane_a * lane_b,
            .div => lane_a / lane_b,
            .min => helper.min(lane_a, lane_b),
            .max => helper.max(lane_a, lane_b),
            .pmin => pmin(lane_a, lane_b),
            .pmax => pmax(lane_a, lane_b),
        };
        writeLane(T, &out, @intCast(i), result);
    }
    return v128FromBytes(out);
}

fn narrow(comptime SrcT: type, comptime DstT: type, comptime HalfN: usize, lhs: V128, rhs: V128, comptime signed: bool) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..HalfN) |i| {
        writeLane(DstT, &out, @intCast(i), narrowLane(SrcT, DstT, readLane(SrcT, lhs.bytes, @intCast(i)), signed));
        writeLane(DstT, &out, @intCast(HalfN + i), narrowLane(SrcT, DstT, readLane(SrcT, rhs.bytes, @intCast(i)), signed));
    }
    return v128FromBytes(out);
}

fn extmul(comptime SrcT: type, comptime DstT: type, lhs: V128, rhs: V128, comptime which: enum { low, high }, comptime signed: bool) V128 {
    const src_lanes = 16 / @sizeOf(SrcT);
    const dst_lanes = 16 / @sizeOf(DstT);
    const start = if (which == .low) 0 else src_lanes / 2;
    var out = std.mem.zeroes([16]u8);
    inline for (0..dst_lanes) |i| {
        const a = readLane(SrcT, lhs.bytes, @intCast(start + i));
        const b = readLane(SrcT, rhs.bytes, @intCast(start + i));
        const result: DstT = if (signed)
            @as(DstT, a) * @as(DstT, b)
        else
            @as(DstT, @intCast(a)) * @as(DstT, @intCast(b));
        writeLane(DstT, &out, @intCast(i), result);
    }
    return v128FromBytes(out);
}

fn dotI16x8ToI32x4(lhs: V128, rhs: V128) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..4) |i| {
        const idx = i * 2;
        const sum = @as(i32, readLane(i16, lhs.bytes, @intCast(idx))) * @as(i32, readLane(i16, rhs.bytes, @intCast(idx))) +
            @as(i32, readLane(i16, lhs.bytes, @intCast(idx + 1))) * @as(i32, readLane(i16, rhs.bytes, @intCast(idx + 1)));
        writeLane(i32, &out, @intCast(i), sum);
    }
    return v128FromBytes(out);
}

fn relaxedDotI8x16ToI16x8(lhs: V128, rhs: V128) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..8) |i| {
        const idx = i * 2;
        const sum = @as(i16, readLane(i8, lhs.bytes, @intCast(idx))) * @as(i16, readLane(i8, rhs.bytes, @intCast(idx))) +
            @as(i16, readLane(i8, lhs.bytes, @intCast(idx + 1))) * @as(i16, readLane(i8, rhs.bytes, @intCast(idx + 1)));
        writeLane(i16, &out, @intCast(i), sum);
    }
    return v128FromBytes(out);
}

fn relaxedDotAddI8x16ToI32x4(first: V128, second: V128, acc: V128) V128 {
    const dot = relaxedDotI8x16ToI16x8(first, second);
    var out = std.mem.zeroes([16]u8);
    inline for (0..4) |i| {
        const idx = i * 2;
        const sum = @as(i32, readLane(i16, dot.bytes, @intCast(idx))) + @as(i32, readLane(i16, dot.bytes, @intCast(idx + 1))) +
            readLane(i32, acc.bytes, @intCast(i));
        writeLane(i32, &out, @intCast(i), sum);
    }
    return v128FromBytes(out);
}

fn floatMulAddVec(comptime T: type, comptime N: usize, first: V128, second: V128, third: V128, comptime negate_first: bool) V128 {
    var a = vecFromV128(T, N, first);
    const b = vecFromV128(T, N, second);
    const c = vecFromV128(T, N, third);
    if (negate_first) a = -a;
    return v128FromVec(T, N, @mulAdd(Vector(T, N), a, b, c));
}

fn compareInt(comptime T: type, comptime N: usize, lhs: V128, rhs: V128, comptime kind: enum { eq, ne, lt, gt, le, ge }) V128 {
    const a = vecFromV128(T, N, lhs);
    const b = vecFromV128(T, N, rhs);
    const mask = switch (kind) {
        .eq => a == b,
        .ne => a != b,
        .lt => a < b,
        .gt => a > b,
        .le => a <= b,
        .ge => a >= b,
    };
    return vectorMaskToV128(T, N, mask);
}

fn compareFloat(comptime T: type, comptime N: usize, lhs: V128, rhs: V128, comptime kind: enum { eq, ne, lt, gt, le, ge }) V128 {
    const a = vecFromV128(T, N, lhs);
    const b = vecFromV128(T, N, rhs);
    const mask = switch (kind) {
        .eq => a == b,
        .ne => a != b,
        .lt => a < b,
        .gt => a > b,
        .le => a <= b,
        .ge => a >= b,
    };
    return vectorMaskToV128(T, N, mask);
}

fn shiftInt(comptime T: type, comptime N: usize, value: V128, amount: u32, comptime kind: enum { shl, shr_s, shr_u }) V128 {
    const ShiftT = std.math.Log2Int(T);
    const shift: ShiftT = @intCast(amount % @bitSizeOf(T));
    switch (kind) {
        .shl => {
            const lanes = vecFromV128(T, N, value);
            const shifts: @Vector(N, ShiftT) = @splat(shift);
            return v128FromVec(T, N, lanes << shifts);
        },
        .shr_s => {
            const lanes = vecFromV128(T, N, value);
            const shifts: @Vector(N, ShiftT) = @splat(shift);
            return v128FromVec(T, N, lanes >> shifts);
        },
        .shr_u => {
            const U = std.meta.Int(.unsigned, @bitSizeOf(T));
            const lanes = vecFromV128(U, N, value);
            const shifts: @Vector(N, ShiftT) = @splat(shift);
            return v128FromVec(U, N, lanes >> shifts);
        },
    }
}

fn swizzle(lhs: V128, rhs: V128) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..16) |i| {
        const idx = readLane(u8, rhs.bytes, @intCast(i));
        out[i] = if (idx < 16) lhs.bytes[idx] else 0;
    }
    return v128FromBytes(out);
}

fn shuffleBytes(lhs: V128, rhs: V128, lanes: [16]u8) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..16) |i| {
        const idx = lanes[i];
        out[i] = if (idx < 16) lhs.bytes[idx] else rhs.bytes[idx - 16];
    }
    return v128FromBytes(out);
}

fn bitselect(first: V128, second: V128, mask: V128) V128 {
    const a: @Vector(16, u8) = @bitCast(first.bytes);
    const b: @Vector(16, u8) = @bitCast(second.bytes);
    const m: @Vector(16, u8) = @bitCast(mask.bytes);
    return v128FromBytes(@bitCast((a & m) | (b & ~m)));
}

fn wideningLoad(comptime SrcT: type, comptime DstT: type, comptime N: usize, slice: []const u8, comptime signed: bool) V128 {
    var out = std.mem.zeroes([16]u8);
    var tmp = std.mem.zeroes([16]u8);
    @memcpy(tmp[0..slice.len], slice);
    inline for (0..N) |i| {
        const lane = readLane(SrcT, tmp, @intCast(i));
        const widened: DstT = if (signed) @as(DstT, lane) else @as(DstT, @intCast(lane));
        writeLane(DstT, &out, @intCast(i), widened);
    }
    return v128FromBytes(out);
}

fn loadSplat(comptime SrcT: type, comptime DstT: type, comptime N: usize, slice: []const u8) V128 {
    var tmp = std.mem.zeroes([16]u8);
    @memcpy(tmp[0..slice.len], slice);
    const lane = readLane(SrcT, tmp, 0);
    return splatGeneric(DstT, N, @as(DstT, @bitCast(lane)));
}

fn loadZeroExtended(comptime T: type, comptime width: usize, slice: []const u8) V128 {
    _ = T;
    _ = width;
    var out = std.mem.zeroes([16]u8);
    @memcpy(out[0..slice.len], slice);
    return v128FromBytes(out);
}

fn loadLane(opcode: SimdOpcode, value: V128, slice: []const u8, lane: u8) V128 {
    var out = value;
    const width = laneImmediateFromOpcode(opcode);
    const start = @as(usize, lane) * width;
    @memcpy(out.bytes[start .. start + width], slice[0..width]);
    return out;
}

fn laneBytes(value: V128, lane: u8, width: usize) [8]u8 {
    var out = std.mem.zeroes([8]u8);
    const start = @as(usize, lane) * width;
    @memcpy(out[0..width], value.bytes[start .. start + width]);
    return out;
}

fn setMaskLane(bytes: *[16]u8, lane: u8, width: usize, ok: bool) void {
    const start = @as(usize, lane) * width;
    @memset(bytes[start .. start + width], if (ok) 0xFF else 0x00);
}

fn satAddSigned(comptime T: type, lhs: T, rhs: T) T {
    const Wide = std.meta.Int(.signed, @bitSizeOf(T) * 2);
    const sum = @as(Wide, lhs) + @as(Wide, rhs);
    return clampSigned(T, sum);
}

fn satSubSigned(comptime T: type, lhs: T, rhs: T) T {
    const Wide = std.meta.Int(.signed, @bitSizeOf(T) * 2);
    const diff = @as(Wide, lhs) - @as(Wide, rhs);
    return clampSigned(T, diff);
}

fn satAddUnsigned(comptime T: type, lhs: T, rhs: T) T {
    const Wide = std.meta.Int(.unsigned, @bitSizeOf(T) * 2);
    const sum = @as(Wide, lhs) + @as(Wide, rhs);
    return if (sum > std.math.maxInt(T)) std.math.maxInt(T) else @as(T, @intCast(sum));
}

fn satSubUnsigned(comptime T: type, lhs: T, rhs: T) T {
    return if (lhs < rhs) 0 else lhs - rhs;
}

fn avgUnsigned(comptime T: type, lhs: T, rhs: T) T {
    const Wide = std.meta.Int(.unsigned, @bitSizeOf(T) * 2);
    return @as(T, @intCast((@as(Wide, lhs) + @as(Wide, rhs) + 1) >> 1));
}

fn clampSigned(comptime T: type, value: anytype) T {
    if (value > std.math.maxInt(T)) return std.math.maxInt(T);
    if (value < std.math.minInt(T)) return std.math.minInt(T);
    return @as(T, @intCast(value));
}

fn narrowLane(comptime SrcT: type, comptime DstT: type, value: SrcT, comptime signed: bool) DstT {
    if (signed) {
        return clampSigned(DstT, value);
    }
    const SrcU = std.meta.Int(.unsigned, @bitSizeOf(SrcT));
    const DstU = std.meta.Int(.unsigned, @bitSizeOf(DstT));
    const as_unsigned = @as(SrcU, @intCast(value));
    if (as_unsigned > std.math.maxInt(DstU)) {
        return @as(DstT, @bitCast(@as(DstU, std.math.maxInt(DstU))));
    }
    return @as(DstT, @bitCast(@as(DstU, @intCast(as_unsigned))));
}

fn pmin(lhs: anytype, rhs: @TypeOf(lhs)) @TypeOf(lhs) {
    if (std.math.isNan(lhs)) return rhs;
    if (std.math.isNan(rhs)) return lhs;
    return if (lhs < rhs) lhs else rhs;
}

fn pmax(lhs: anytype, rhs: @TypeOf(lhs)) @TypeOf(lhs) {
    const T = @TypeOf(lhs);
    _ = T;
    if (std.math.isNan(lhs)) return rhs;
    if (std.math.isNan(rhs)) return lhs;
    return if (lhs > rhs) lhs else rhs;
}

test "classify representative simd opcodes" {
    try std.testing.expectEqual(SimdClass.const_, classifyOpcode(.v128_const).?);
    try std.testing.expectEqual(SimdClass.load, classifyOpcode(.v128_load).?);
    try std.testing.expectEqual(SimdClass.shift, classifyOpcode(.i16x8_shr_u).?);
    try std.testing.expectEqual(SimdClass.compare, classifyOpcode(.f32x4_ge).?);
    try std.testing.expectEqual(SimdClass.ternary, classifyOpcode(.v128_bitselect).?);
}

test "execute simple integer simd pipeline" {
    const lanes = splatGeneric(i32, 4, 3);
    const added = executeBinary(.i32x4_add, RawVal.from(lanes), RawVal.from(splatGeneric(i32, 4, 4)));
    const replaced = replaceLane(.i32x4_replace_lane, added, RawVal.from(@as(i32, 99)), 2);
    try std.testing.expectEqual(@as(i32, 7), extractLane(.i32x4_extract_lane, added, 0).readAs(i32));
    try std.testing.expectEqual(@as(i32, 99), extractLane(.i32x4_extract_lane, replaced, 2).readAs(i32));
}

test "load/store lane roundtrip" {
    var memory = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0xaa, 0xbb, 0xcc, 0xdd };
    const base = splatGeneric(i16, 8, 0);
    const loaded = load(.v128_load16_lane, memory[0..], 0, 0, 1, RawVal.from(base));
    try std.testing.expectEqual(@as(i32, 0x2211), extractLane(.i16x8_extract_lane_u, RawVal.from(loaded), 1).readAs(i32));

    var out = [_]u8{0} ** 8;
    store(.v128_store16_lane, out[0..], 0, 0, 1, RawVal.from(loaded));
    try std.testing.expectEqualSlices(u8, memory[0..2], out[0..2]);
}

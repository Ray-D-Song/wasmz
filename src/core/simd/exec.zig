// SIMD public execution dispatchers.
//
// These are the entry points called by the VM dispatcher (vm/root.zig).
// Each function takes a SimdOpcode and RawVal operands, dispatches to the
// appropriate helper in ops.zig / memory.zig, and returns a RawVal.
const std = @import("std");
const raw_mod = @import("../raw.zig");
const classify = @import("classify.zig");
const ops = @import("ops.zig");
const mem_ops = @import("memory.zig");

pub const RawVal = raw_mod.RawVal;
const V128 = ops.V128;
const SimdOpcode = classify.SimdOpcode;

/// Dispatches a unary SIMD operation. Handles splat, bitwise not, integer/float
/// unary ops, type conversions, extending, and pairwise addition.
pub fn executeUnary(opcode: SimdOpcode, src: RawVal) RawVal {
    return switch (opcode) {
        // splat
        .i8x16_splat => RawVal.from(splat(opcode, src)),
        .i16x8_splat => RawVal.from(splat(opcode, src)),
        .i32x4_splat => RawVal.from(splat(opcode, src)),
        .i64x2_splat => RawVal.from(splat(opcode, src)),
        .f32x4_splat => RawVal.from(splat(opcode, src)),
        .f64x2_splat => RawVal.from(splat(opcode, src)),
        // bitwise / boolean
        .v128_not => RawVal.from(ops.mapBytesUnary(src.readAs(V128), struct {
            fn op(value: u8) u8 {
                return ~value;
            }
        }.op)),
        .v128_any_true => RawVal.from(@as(i32, if (ops.anyTrue(src.readAs(V128))) 1 else 0)),
        // i8x16 unary
        .i8x16_abs => RawVal.from(ops.unaryInt(i8, 16, src.readAs(V128), .abs)),
        .i8x16_neg => RawVal.from(ops.unaryInt(i8, 16, src.readAs(V128), .neg)),
        .i8x16_popcnt => RawVal.from(ops.unaryI8Popcnt(src.readAs(V128))),
        .i8x16_all_true => RawVal.from(@as(i32, if (ops.allTrue(i8, 16, src.readAs(V128))) 1 else 0)),
        .i8x16_bitmask => RawVal.from(ops.bitmask(i8, 16, src.readAs(V128))),
        // i16x8 unary
        .i16x8_abs => RawVal.from(ops.unaryInt(i16, 8, src.readAs(V128), .abs)),
        .i16x8_neg => RawVal.from(ops.unaryInt(i16, 8, src.readAs(V128), .neg)),
        .i16x8_all_true => RawVal.from(@as(i32, if (ops.allTrue(i16, 8, src.readAs(V128))) 1 else 0)),
        .i16x8_bitmask => RawVal.from(ops.bitmask(i16, 8, src.readAs(V128))),
        // i32x4 unary
        .i32x4_abs => RawVal.from(ops.unaryInt(i32, 4, src.readAs(V128), .abs)),
        .i32x4_neg => RawVal.from(ops.unaryInt(i32, 4, src.readAs(V128), .neg)),
        .i32x4_all_true => RawVal.from(@as(i32, if (ops.allTrue(i32, 4, src.readAs(V128))) 1 else 0)),
        .i32x4_bitmask => RawVal.from(ops.bitmask(i32, 4, src.readAs(V128))),
        // i64x2 unary
        .i64x2_abs => RawVal.from(ops.unaryInt(i64, 2, src.readAs(V128), .abs)),
        .i64x2_neg => RawVal.from(ops.unaryInt(i64, 2, src.readAs(V128), .neg)),
        .i64x2_all_true => RawVal.from(@as(i32, if (ops.allTrue(i64, 2, src.readAs(V128))) 1 else 0)),
        .i64x2_bitmask => RawVal.from(ops.bitmask(i64, 2, src.readAs(V128))),
        // f32x4 unary
        .f32x4_abs => RawVal.from(ops.unaryFloat(f32, 4, src.readAs(V128), .abs)),
        .f32x4_neg => RawVal.from(ops.unaryFloat(f32, 4, src.readAs(V128), .neg)),
        .f32x4_sqrt => RawVal.from(ops.unaryFloat(f32, 4, src.readAs(V128), .sqrt)),
        .f32x4_ceil => RawVal.from(ops.unaryFloat(f32, 4, src.readAs(V128), .ceil)),
        .f32x4_floor => RawVal.from(ops.unaryFloat(f32, 4, src.readAs(V128), .floor)),
        .f32x4_trunc => RawVal.from(ops.unaryFloat(f32, 4, src.readAs(V128), .trunc)),
        .f32x4_nearest => RawVal.from(ops.unaryFloat(f32, 4, src.readAs(V128), .nearest)),
        // f64x2 unary
        .f64x2_abs => RawVal.from(ops.unaryFloat(f64, 2, src.readAs(V128), .abs)),
        .f64x2_neg => RawVal.from(ops.unaryFloat(f64, 2, src.readAs(V128), .neg)),
        .f64x2_sqrt => RawVal.from(ops.unaryFloat(f64, 2, src.readAs(V128), .sqrt)),
        .f64x2_ceil => RawVal.from(ops.unaryFloat(f64, 2, src.readAs(V128), .ceil)),
        .f64x2_floor => RawVal.from(ops.unaryFloat(f64, 2, src.readAs(V128), .floor)),
        .f64x2_trunc => RawVal.from(ops.unaryFloat(f64, 2, src.readAs(V128), .trunc)),
        .f64x2_nearest => RawVal.from(ops.unaryFloat(f64, 2, src.readAs(V128), .nearest)),
        // extadd pairwise (Fix 9: signedness from SrcT)
        .i16x8_extadd_pairwise_i8x16_s => RawVal.from(ops.extaddPairwise(i8, i16, 8, src.readAs(V128))),
        .i16x8_extadd_pairwise_i8x16_u => RawVal.from(ops.extaddPairwise(u8, u16, 8, src.readAs(V128))),
        .i32x4_extadd_pairwise_i16x8_s => RawVal.from(ops.extaddPairwise(i16, i32, 4, src.readAs(V128))),
        .i32x4_extadd_pairwise_i16x8_u => RawVal.from(ops.extaddPairwise(u16, u32, 4, src.readAs(V128))),
        // extend half (Fix 9: signedness from SrcT)
        .i16x8_extend_low_i8x16_s => RawVal.from(ops.extendHalf(i8, i16, src.readAs(V128), .low)),
        .i16x8_extend_high_i8x16_s => RawVal.from(ops.extendHalf(i8, i16, src.readAs(V128), .high)),
        .i16x8_extend_low_i8x16_u => RawVal.from(ops.extendHalf(u8, i16, src.readAs(V128), .low)),
        .i16x8_extend_high_i8x16_u => RawVal.from(ops.extendHalf(u8, i16, src.readAs(V128), .high)),
        .i32x4_extend_low_i16x8_s => RawVal.from(ops.extendHalf(i16, i32, src.readAs(V128), .low)),
        .i32x4_extend_high_i16x8_s => RawVal.from(ops.extendHalf(i16, i32, src.readAs(V128), .high)),
        .i32x4_extend_low_i16x8_u => RawVal.from(ops.extendHalf(u16, i32, src.readAs(V128), .low)),
        .i32x4_extend_high_i16x8_u => RawVal.from(ops.extendHalf(u16, i32, src.readAs(V128), .high)),
        .i64x2_extend_low_i32x4_s => RawVal.from(ops.extendHalf(i32, i64, src.readAs(V128), .low)),
        .i64x2_extend_high_i32x4_s => RawVal.from(ops.extendHalf(i32, i64, src.readAs(V128), .high)),
        .i64x2_extend_low_i32x4_u => RawVal.from(ops.extendHalf(u32, i64, src.readAs(V128), .low)),
        .i64x2_extend_high_i32x4_u => RawVal.from(ops.extendHalf(u32, i64, src.readAs(V128), .high)),
        // conversions
        .f32x4_demote_f64x2_zero => RawVal.from(ops.demoteF64x2Zero(src.readAs(V128))),
        .f64x2_promote_low_f32x4 => RawVal.from(ops.promoteLowF32x4(src.readAs(V128))),
        .i32x4_trunc_sat_f32x4_s, .i32x4_relaxed_trunc_f32x4_s => RawVal.from(ops.truncSatF32x4ToI32x4(src.readAs(V128), true)),
        .i32x4_trunc_sat_f32x4_u, .i32x4_relaxed_trunc_f32x4_u => RawVal.from(ops.truncSatF32x4ToI32x4(src.readAs(V128), false)),
        .i32x4_trunc_sat_f64x2_s_zero, .i32x4_relaxed_trunc_f64x2_s_zero => RawVal.from(ops.truncSatF64x2ToI32x4Zero(src.readAs(V128), true)),
        .i32x4_trunc_sat_f64x2_u_zero, .i32x4_relaxed_trunc_f64x2_u_zero => RawVal.from(ops.truncSatF64x2ToI32x4Zero(src.readAs(V128), false)),
        .f32x4_convert_i32x4_s => RawVal.from(ops.convertI32x4ToF32x4(src.readAs(V128), true)),
        .f32x4_convert_i32x4_u => RawVal.from(ops.convertI32x4ToF32x4(src.readAs(V128), false)),
        .f64x2_convert_low_i32x4_s => RawVal.from(ops.convertLowI32x4ToF64x2(src.readAs(V128), true)),
        .f64x2_convert_low_i32x4_u => RawVal.from(ops.convertLowI32x4ToF64x2(src.readAs(V128), false)),
        else => unreachable,
    };
}

/// Dispatches a binary SIMD operation. Covers bitwise, integer/float arithmetic,
/// saturating arithmetic, narrowing, extended multiplication, and dot products.
pub fn executeBinary(opcode: SimdOpcode, lhs: RawVal, rhs: RawVal) RawVal {
    return switch (opcode) {
        .v128_and => RawVal.from(ops.bytesBinary(lhs.readAs(V128), rhs.readAs(V128), .@"and")),
        .v128_andnot => RawVal.from(ops.bytesBinary(lhs.readAs(V128), rhs.readAs(V128), .andnot)),
        .v128_or => RawVal.from(ops.bytesBinary(lhs.readAs(V128), rhs.readAs(V128), .@"or")),
        .v128_xor => RawVal.from(ops.bytesBinary(lhs.readAs(V128), rhs.readAs(V128), .xor)),
        .i8x16_swizzle, .i8x16_relaxed_swizzle => RawVal.from(ops.swizzle(lhs.readAs(V128), rhs.readAs(V128))),
        // i8x16 binary (Fix 5: unified add_sat/sub_sat)
        .i8x16_add => RawVal.from(ops.binaryInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .add)),
        .i8x16_add_sat_s => RawVal.from(ops.binaryInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .add_sat)),
        .i8x16_add_sat_u => RawVal.from(ops.binaryInt(u8, 16, lhs.readAs(V128), rhs.readAs(V128), .add_sat)),
        .i8x16_sub => RawVal.from(ops.binaryInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .sub)),
        .i8x16_sub_sat_s => RawVal.from(ops.binaryInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .sub_sat)),
        .i8x16_sub_sat_u => RawVal.from(ops.binaryInt(u8, 16, lhs.readAs(V128), rhs.readAs(V128), .sub_sat)),
        .i8x16_min_s => RawVal.from(ops.binaryInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .min)),
        .i8x16_min_u => RawVal.from(ops.binaryInt(u8, 16, lhs.readAs(V128), rhs.readAs(V128), .min)),
        .i8x16_max_s => RawVal.from(ops.binaryInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .max)),
        .i8x16_max_u => RawVal.from(ops.binaryInt(u8, 16, lhs.readAs(V128), rhs.readAs(V128), .max)),
        .i8x16_avgr_u => RawVal.from(ops.binaryInt(u8, 16, lhs.readAs(V128), rhs.readAs(V128), .avgr_u)),
        // i16x8 binary
        .i16x8_q15mulr_sat_s, .i16x8_relaxed_q15mulr_s => RawVal.from(ops.q15mulr(lhs.readAs(V128), rhs.readAs(V128))),
        .i16x8_add => RawVal.from(ops.binaryInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .add)),
        .i16x8_add_sat_s => RawVal.from(ops.binaryInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .add_sat)),
        .i16x8_add_sat_u => RawVal.from(ops.binaryInt(u16, 8, lhs.readAs(V128), rhs.readAs(V128), .add_sat)),
        .i16x8_sub => RawVal.from(ops.binaryInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .sub)),
        .i16x8_sub_sat_s => RawVal.from(ops.binaryInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .sub_sat)),
        .i16x8_sub_sat_u => RawVal.from(ops.binaryInt(u16, 8, lhs.readAs(V128), rhs.readAs(V128), .sub_sat)),
        .i16x8_mul => RawVal.from(ops.binaryInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .mul)),
        .i16x8_min_s => RawVal.from(ops.binaryInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .min)),
        .i16x8_min_u => RawVal.from(ops.binaryInt(u16, 8, lhs.readAs(V128), rhs.readAs(V128), .min)),
        .i16x8_max_s => RawVal.from(ops.binaryInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .max)),
        .i16x8_max_u => RawVal.from(ops.binaryInt(u16, 8, lhs.readAs(V128), rhs.readAs(V128), .max)),
        .i16x8_avgr_u => RawVal.from(ops.binaryInt(u16, 8, lhs.readAs(V128), rhs.readAs(V128), .avgr_u)),
        // i32x4 binary
        .i32x4_add => RawVal.from(ops.binaryInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .add)),
        .i32x4_sub => RawVal.from(ops.binaryInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .sub)),
        .i32x4_mul => RawVal.from(ops.binaryInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .mul)),
        .i32x4_min_s => RawVal.from(ops.binaryInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .min)),
        .i32x4_min_u => RawVal.from(ops.binaryInt(u32, 4, lhs.readAs(V128), rhs.readAs(V128), .min)),
        .i32x4_max_s => RawVal.from(ops.binaryInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .max)),
        .i32x4_max_u => RawVal.from(ops.binaryInt(u32, 4, lhs.readAs(V128), rhs.readAs(V128), .max)),
        .i32x4_dot_i16x8_s => RawVal.from(ops.dotI16x8ToI32x4(lhs.readAs(V128), rhs.readAs(V128))),
        // i64x2 binary
        .i64x2_add => RawVal.from(ops.binaryInt(i64, 2, lhs.readAs(V128), rhs.readAs(V128), .add)),
        .i64x2_sub => RawVal.from(ops.binaryInt(i64, 2, lhs.readAs(V128), rhs.readAs(V128), .sub)),
        .i64x2_mul => RawVal.from(ops.binaryInt(i64, 2, lhs.readAs(V128), rhs.readAs(V128), .mul)),
        // f32x4 binary
        .f32x4_add => RawVal.from(ops.binaryFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .add)),
        .f32x4_sub => RawVal.from(ops.binaryFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .sub)),
        .f32x4_mul => RawVal.from(ops.binaryFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .mul)),
        .f32x4_div => RawVal.from(ops.binaryFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .div)),
        .f32x4_min, .f32x4_relaxed_min => RawVal.from(ops.binaryFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .min)),
        .f32x4_max, .f32x4_relaxed_max => RawVal.from(ops.binaryFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .max)),
        .f32x4_pmin => RawVal.from(ops.binaryFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .pmin)),
        .f32x4_pmax => RawVal.from(ops.binaryFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .pmax)),
        // f64x2 binary
        .f64x2_add => RawVal.from(ops.binaryFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .add)),
        .f64x2_sub => RawVal.from(ops.binaryFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .sub)),
        .f64x2_mul => RawVal.from(ops.binaryFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .mul)),
        .f64x2_div => RawVal.from(ops.binaryFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .div)),
        .f64x2_min, .f64x2_relaxed_min => RawVal.from(ops.binaryFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .min)),
        .f64x2_max, .f64x2_relaxed_max => RawVal.from(ops.binaryFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .max)),
        .f64x2_pmin => RawVal.from(ops.binaryFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .pmin)),
        .f64x2_pmax => RawVal.from(ops.binaryFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .pmax)),
        // narrow (Fix 9: signedness from SrcT)
        .i8x16_narrow_i16x8_s => RawVal.from(ops.narrow(i16, i8, 8, lhs.readAs(V128), rhs.readAs(V128))),
        .i8x16_narrow_i16x8_u => RawVal.from(ops.narrow(u16, i8, 8, lhs.readAs(V128), rhs.readAs(V128))),
        .i16x8_narrow_i32x4_s => RawVal.from(ops.narrow(i32, i16, 4, lhs.readAs(V128), rhs.readAs(V128))),
        .i16x8_narrow_i32x4_u => RawVal.from(ops.narrow(u32, i16, 4, lhs.readAs(V128), rhs.readAs(V128))),
        // extmul (Fix 9: signedness from SrcT)
        .i16x8_extmul_low_i8x16_s => RawVal.from(ops.extmul(i8, i16, lhs.readAs(V128), rhs.readAs(V128), .low)),
        .i16x8_extmul_high_i8x16_s => RawVal.from(ops.extmul(i8, i16, lhs.readAs(V128), rhs.readAs(V128), .high)),
        .i16x8_extmul_low_i8x16_u => RawVal.from(ops.extmul(u8, i16, lhs.readAs(V128), rhs.readAs(V128), .low)),
        .i16x8_extmul_high_i8x16_u => RawVal.from(ops.extmul(u8, i16, lhs.readAs(V128), rhs.readAs(V128), .high)),
        .i32x4_extmul_low_i16x8_s => RawVal.from(ops.extmul(i16, i32, lhs.readAs(V128), rhs.readAs(V128), .low)),
        .i32x4_extmul_high_i16x8_s => RawVal.from(ops.extmul(i16, i32, lhs.readAs(V128), rhs.readAs(V128), .high)),
        .i32x4_extmul_low_i16x8_u => RawVal.from(ops.extmul(u16, i32, lhs.readAs(V128), rhs.readAs(V128), .low)),
        .i32x4_extmul_high_i16x8_u => RawVal.from(ops.extmul(u16, i32, lhs.readAs(V128), rhs.readAs(V128), .high)),
        .i64x2_extmul_low_i32x4_s => RawVal.from(ops.extmul(i32, i64, lhs.readAs(V128), rhs.readAs(V128), .low)),
        .i64x2_extmul_high_i32x4_s => RawVal.from(ops.extmul(i32, i64, lhs.readAs(V128), rhs.readAs(V128), .high)),
        .i64x2_extmul_low_i32x4_u => RawVal.from(ops.extmul(u32, i64, lhs.readAs(V128), rhs.readAs(V128), .low)),
        .i64x2_extmul_high_i32x4_u => RawVal.from(ops.extmul(u32, i64, lhs.readAs(V128), rhs.readAs(V128), .high)),
        // relaxed dot
        .i16x8_relaxed_dot_i8x16_i7x16_s => RawVal.from(ops.relaxedDotI8x16ToI16x8(lhs.readAs(V128), rhs.readAs(V128))),
        else => unreachable,
    };
}

/// Dispatches a ternary SIMD operation: bitselect, relaxed lane-select,
/// relaxed fused multiply-add, and relaxed dot-product-add.
pub fn executeTernary(opcode: SimdOpcode, first: RawVal, second: RawVal, third: RawVal) RawVal {
    return switch (opcode) {
        .v128_bitselect,
        .i8x16_relaxed_laneselect,
        .i16x8_relaxed_laneselect,
        .i32x4_relaxed_laneselect,
        .i64x2_relaxed_laneselect,
        => RawVal.from(ops.bitselect(first.readAs(V128), second.readAs(V128), third.readAs(V128))),
        .f32x4_relaxed_madd => RawVal.from(ops.floatMulAddVec(f32, 4, first.readAs(V128), second.readAs(V128), third.readAs(V128), false)),
        .f32x4_relaxed_nmadd => RawVal.from(ops.floatMulAddVec(f32, 4, first.readAs(V128), second.readAs(V128), third.readAs(V128), true)),
        .f64x2_relaxed_madd => RawVal.from(ops.floatMulAddVec(f64, 2, first.readAs(V128), second.readAs(V128), third.readAs(V128), false)),
        .f64x2_relaxed_nmadd => RawVal.from(ops.floatMulAddVec(f64, 2, first.readAs(V128), second.readAs(V128), third.readAs(V128), true)),
        .i32x4_relaxed_dot_i8x16_i7x16_add_s => RawVal.from(ops.relaxedDotAddI8x16ToI32x4(first.readAs(V128), second.readAs(V128), third.readAs(V128))),
        else => unreachable,
    };
}

/// Dispatches a SIMD comparison. Returns V128 with all-ones / all-zeros lanes.
pub fn executeCompare(opcode: SimdOpcode, lhs: RawVal, rhs: RawVal) RawVal {
    return switch (opcode) {
        .i8x16_eq => RawVal.from(ops.compareInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .eq)),
        .i8x16_ne => RawVal.from(ops.compareInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .ne)),
        .i8x16_lt_s => RawVal.from(ops.compareInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .lt)),
        .i8x16_lt_u => RawVal.from(ops.compareInt(u8, 16, lhs.readAs(V128), rhs.readAs(V128), .lt)),
        .i8x16_gt_s => RawVal.from(ops.compareInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .gt)),
        .i8x16_gt_u => RawVal.from(ops.compareInt(u8, 16, lhs.readAs(V128), rhs.readAs(V128), .gt)),
        .i8x16_le_s => RawVal.from(ops.compareInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .le)),
        .i8x16_le_u => RawVal.from(ops.compareInt(u8, 16, lhs.readAs(V128), rhs.readAs(V128), .le)),
        .i8x16_ge_s => RawVal.from(ops.compareInt(i8, 16, lhs.readAs(V128), rhs.readAs(V128), .ge)),
        .i8x16_ge_u => RawVal.from(ops.compareInt(u8, 16, lhs.readAs(V128), rhs.readAs(V128), .ge)),
        .i16x8_eq => RawVal.from(ops.compareInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .eq)),
        .i16x8_ne => RawVal.from(ops.compareInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .ne)),
        .i16x8_lt_s => RawVal.from(ops.compareInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .lt)),
        .i16x8_lt_u => RawVal.from(ops.compareInt(u16, 8, lhs.readAs(V128), rhs.readAs(V128), .lt)),
        .i16x8_gt_s => RawVal.from(ops.compareInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .gt)),
        .i16x8_gt_u => RawVal.from(ops.compareInt(u16, 8, lhs.readAs(V128), rhs.readAs(V128), .gt)),
        .i16x8_le_s => RawVal.from(ops.compareInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .le)),
        .i16x8_le_u => RawVal.from(ops.compareInt(u16, 8, lhs.readAs(V128), rhs.readAs(V128), .le)),
        .i16x8_ge_s => RawVal.from(ops.compareInt(i16, 8, lhs.readAs(V128), rhs.readAs(V128), .ge)),
        .i16x8_ge_u => RawVal.from(ops.compareInt(u16, 8, lhs.readAs(V128), rhs.readAs(V128), .ge)),
        .i32x4_eq => RawVal.from(ops.compareInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .eq)),
        .i32x4_ne => RawVal.from(ops.compareInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .ne)),
        .i32x4_lt_s => RawVal.from(ops.compareInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .lt)),
        .i32x4_lt_u => RawVal.from(ops.compareInt(u32, 4, lhs.readAs(V128), rhs.readAs(V128), .lt)),
        .i32x4_gt_s => RawVal.from(ops.compareInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .gt)),
        .i32x4_gt_u => RawVal.from(ops.compareInt(u32, 4, lhs.readAs(V128), rhs.readAs(V128), .gt)),
        .i32x4_le_s => RawVal.from(ops.compareInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .le)),
        .i32x4_le_u => RawVal.from(ops.compareInt(u32, 4, lhs.readAs(V128), rhs.readAs(V128), .le)),
        .i32x4_ge_s => RawVal.from(ops.compareInt(i32, 4, lhs.readAs(V128), rhs.readAs(V128), .ge)),
        .i32x4_ge_u => RawVal.from(ops.compareInt(u32, 4, lhs.readAs(V128), rhs.readAs(V128), .ge)),
        .i64x2_eq => RawVal.from(ops.compareInt(i64, 2, lhs.readAs(V128), rhs.readAs(V128), .eq)),
        .i64x2_ne => RawVal.from(ops.compareInt(i64, 2, lhs.readAs(V128), rhs.readAs(V128), .ne)),
        .i64x2_lt_s => RawVal.from(ops.compareInt(i64, 2, lhs.readAs(V128), rhs.readAs(V128), .lt)),
        .i64x2_gt_s => RawVal.from(ops.compareInt(i64, 2, lhs.readAs(V128), rhs.readAs(V128), .gt)),
        .i64x2_le_s => RawVal.from(ops.compareInt(i64, 2, lhs.readAs(V128), rhs.readAs(V128), .le)),
        .i64x2_ge_s => RawVal.from(ops.compareInt(i64, 2, lhs.readAs(V128), rhs.readAs(V128), .ge)),
        .f32x4_eq => RawVal.from(ops.compareFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .eq)),
        .f32x4_ne => RawVal.from(ops.compareFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .ne)),
        .f32x4_lt => RawVal.from(ops.compareFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .lt)),
        .f32x4_gt => RawVal.from(ops.compareFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .gt)),
        .f32x4_le => RawVal.from(ops.compareFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .le)),
        .f32x4_ge => RawVal.from(ops.compareFloat(f32, 4, lhs.readAs(V128), rhs.readAs(V128), .ge)),
        .f64x2_eq => RawVal.from(ops.compareFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .eq)),
        .f64x2_ne => RawVal.from(ops.compareFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .ne)),
        .f64x2_lt => RawVal.from(ops.compareFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .lt)),
        .f64x2_gt => RawVal.from(ops.compareFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .gt)),
        .f64x2_le => RawVal.from(ops.compareFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .le)),
        .f64x2_ge => RawVal.from(ops.compareFloat(f64, 2, lhs.readAs(V128), rhs.readAs(V128), .ge)),
        else => unreachable,
    };
}

/// Dispatches a SIMD shift operation. The shift amount (rhs) is a scalar u32,
/// masked to the lane bit-width by the spec.
pub fn executeShift(opcode: SimdOpcode, lhs: RawVal, rhs: RawVal) RawVal {
    const amount = rhs.readAs(u32);
    return switch (opcode) {
        .i8x16_shl => RawVal.from(ops.shiftInt(i8, 16, lhs.readAs(V128), amount, .shl)),
        .i8x16_shr_s => RawVal.from(ops.shiftInt(i8, 16, lhs.readAs(V128), amount, .shr_s)),
        .i8x16_shr_u => RawVal.from(ops.shiftInt(u8, 16, lhs.readAs(V128), amount, .shr_u)),
        .i16x8_shl => RawVal.from(ops.shiftInt(i16, 8, lhs.readAs(V128), amount, .shl)),
        .i16x8_shr_s => RawVal.from(ops.shiftInt(i16, 8, lhs.readAs(V128), amount, .shr_s)),
        .i16x8_shr_u => RawVal.from(ops.shiftInt(u16, 8, lhs.readAs(V128), amount, .shr_u)),
        .i32x4_shl => RawVal.from(ops.shiftInt(i32, 4, lhs.readAs(V128), amount, .shl)),
        .i32x4_shr_s => RawVal.from(ops.shiftInt(i32, 4, lhs.readAs(V128), amount, .shr_s)),
        .i32x4_shr_u => RawVal.from(ops.shiftInt(u32, 4, lhs.readAs(V128), amount, .shr_u)),
        .i64x2_shl => RawVal.from(ops.shiftInt(i64, 2, lhs.readAs(V128), amount, .shl)),
        .i64x2_shr_s => RawVal.from(ops.shiftInt(i64, 2, lhs.readAs(V128), amount, .shr_s)),
        .i64x2_shr_u => RawVal.from(ops.shiftInt(u64, 2, lhs.readAs(V128), amount, .shr_u)),
        else => unreachable,
    };
}

/// Extracts a scalar value from the specified lane of a V128 vector.
/// The result is sign- or zero-extended to i32 for sub-32-bit lanes.
pub fn extractLane(opcode: SimdOpcode, src: RawVal, lane: u8) RawVal {
    const value = src.readAs(V128);
    return switch (opcode) {
        .i8x16_extract_lane_s => RawVal.from(@as(i32, ops.readLane(i8, value.bytes, lane))),
        .i8x16_extract_lane_u => RawVal.from(@as(i32, ops.readLane(u8, value.bytes, lane))),
        .i16x8_extract_lane_s => RawVal.from(@as(i32, ops.readLane(i16, value.bytes, lane))),
        .i16x8_extract_lane_u => RawVal.from(@as(i32, ops.readLane(u16, value.bytes, lane))),
        .i32x4_extract_lane => RawVal.from(ops.readLane(i32, value.bytes, lane)),
        .i64x2_extract_lane => RawVal.from(ops.readLane(i64, value.bytes, lane)),
        .f32x4_extract_lane => RawVal.from(ops.readLane(f32, value.bytes, lane)),
        .f64x2_extract_lane => RawVal.from(ops.readLane(f64, value.bytes, lane)),
        else => unreachable,
    };
}

/// Replaces a single lane in src_vec with the scalar src_lane value.
pub fn replaceLane(opcode: SimdOpcode, src_vec: RawVal, src_lane: RawVal, lane: u8) RawVal {
    var out = src_vec.readAs(V128);
    switch (opcode) {
        .i8x16_replace_lane => ops.writeLane(i8, &out.bytes, lane, src_lane.readAs(i8)),
        .i16x8_replace_lane => ops.writeLane(i16, &out.bytes, lane, src_lane.readAs(i16)),
        .i32x4_replace_lane => ops.writeLane(i32, &out.bytes, lane, src_lane.readAs(i32)),
        .i64x2_replace_lane => ops.writeLane(i64, &out.bytes, lane, src_lane.readAs(i64)),
        .f32x4_replace_lane => ops.writeLane(f32, &out.bytes, lane, src_lane.readAs(f32)),
        .f64x2_replace_lane => ops.writeLane(f64, &out.bytes, lane, src_lane.readAs(f64)),
        else => unreachable,
    }
    return RawVal.from(out);
}

/// i8x16.shuffle: selects bytes from the concatenation of lhs and rhs
/// using the 16-byte immediate `lanes` as indices (0..31).
pub fn shuffleVectors(lhs: RawVal, rhs: RawVal, lanes_arr: [16]u8) RawVal {
    return RawVal.from(ops.shuffleBytes(lhs.readAs(V128), rhs.readAs(V128), lanes_arr));
}

/// Loads a V128 from memory. Delegates to memory.zig, converting RawVal src_vec to V128.
pub fn load(opcode: SimdOpcode, memory: []const u8, addr: u32, offset: u32, lane: ?u8, src_vec: ?RawVal) V128 {
    const sv: ?V128 = if (src_vec) |sv| sv.readAs(V128) else null;
    return mem_ops.load(opcode, memory, addr, offset, lane, sv);
}

/// Stores a V128 to memory. Delegates to memory.zig, converting RawVal src to V128.
pub fn store(opcode: SimdOpcode, memory: []u8, addr: u32, offset: u32, lane: ?u8, src: RawVal) void {
    mem_ops.store(opcode, memory, addr, offset, lane, src.readAs(V128));
}

/// Creates a V128 where all lanes are filled with the same scalar value.
fn splat(opcode: SimdOpcode, src: RawVal) V128 {
    return switch (classify.shapeOf(opcode).?) {
        .i8x16 => ops.splatGeneric(i8, 16, src.readAs(i8)),
        .i16x8 => ops.splatGeneric(i16, 8, src.readAs(i16)),
        .i32x4 => ops.splatGeneric(i32, 4, src.readAs(i32)),
        .i64x2 => ops.splatGeneric(i64, 2, src.readAs(i64)),
        .f32x4 => ops.splatGeneric(f32, 4, src.readAs(f32)),
        .f64x2 => ops.splatGeneric(f64, 2, src.readAs(f64)),
    };
}

test "execute simple integer simd pipeline" {
    const lanes = ops.splatGeneric(i32, 4, 3);
    const added = executeBinary(.i32x4_add, RawVal.from(lanes), RawVal.from(ops.splatGeneric(i32, 4, 4)));
    const replaced = replaceLane(.i32x4_replace_lane, added, RawVal.from(@as(i32, 99)), 2);
    try std.testing.expectEqual(@as(i32, 7), extractLane(.i32x4_extract_lane, added, 0).readAs(i32));
    try std.testing.expectEqual(@as(i32, 99), extractLane(.i32x4_extract_lane, replaced, 2).readAs(i32));
}

test "load/store lane roundtrip" {
    var memory = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0xaa, 0xbb, 0xcc, 0xdd };
    const base = ops.splatGeneric(i16, 8, 0);
    const loaded = load(.v128_load16_lane, memory[0..], 0, 0, 1, RawVal.from(base));
    try std.testing.expectEqual(@as(i32, 0x2211), extractLane(.i16x8_extract_lane_u, RawVal.from(loaded), 1).readAs(i32));

    var out = [_]u8{0} ** 8;
    store(.v128_store16_lane, out[0..], 0, 0, 1, RawVal.from(loaded));
    try std.testing.expectEqualSlices(u8, memory[0..2], out[0..2]);
}

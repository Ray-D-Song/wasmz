// SIMD public execution dispatchers.
// These are the entry points called by the VM dispatcher (vm/root.zig).
// Each function takes a SimdOpcode and SimdVal operands, dispatches to the
// appropriate helper in ops.zig / memory.zig, and returns a SimdVal.
// Scalar results (e.g. extractLane, any_true, bitmask) return RawVal.
// Scalar inputs (e.g. executeShift rhs, replaceLane src_lane, splat src) use RawVal.
const std = @import("std");
const raw_mod = @import("../raw.zig");
const classify = @import("classify.zig");
const ops = @import("ops.zig");
const mem_ops = @import("memory.zig");

pub const RawVal = raw_mod.RawVal;
pub const SimdVal = raw_mod.SimdVal;
const V128 = ops.V128;
const SimdOpcode = classify.SimdOpcode;

// Conversion helpers

inline fn sv2v(s: SimdVal) V128 {
    return s.toV128();
}

inline fn v2sv(v: V128) SimdVal {
    return SimdVal.fromV128(v);
}

// Public API

/// Dispatches a unary SIMD operation. Handles splat, bitwise not, integer/float
/// unary ops, type conversions, extending, and pairwise addition.
///
/// Splat is the one exception: its `src` operand carries a *scalar* value in a
/// SimdVal wrapper (the low 8 bytes hold the scalar, the high 8 bytes are ignored
/// on read).  Handlers pass `SimdVal.fromSlots(slots[ops.src], slots[ops.src+1])`
/// for V128 sources, but for splat the slot is a plain RawVal promoted to SimdVal.
pub fn executeUnary(opcode: SimdOpcode, src: SimdVal) SimdVal {
    return switch (opcode) {
        // splat — src carries scalar in low 8 bytes (slots[ops.src] only)
        .i8x16_splat => v2sv(splatScalar(opcode, src.toScalar())),
        .i16x8_splat => v2sv(splatScalar(opcode, src.toScalar())),
        .i32x4_splat => v2sv(splatScalar(opcode, src.toScalar())),
        .i64x2_splat => v2sv(splatScalar(opcode, src.toScalar())),
        .f32x4_splat => v2sv(splatScalar(opcode, src.toScalar())),
        .f64x2_splat => v2sv(splatScalar(opcode, src.toScalar())),
        // bitwise / boolean → scalar result wrapped in SimdVal
        .v128_not => v2sv(ops.mapBytesUnary(sv2v(src), struct {
            fn op(value: u8) u8 {
                return ~value;
            }
        }.op)),
        .v128_any_true => SimdVal.fromScalar(RawVal.from(@as(i32, if (ops.anyTrue(sv2v(src))) 1 else 0))),
        // i8x16 unary
        .i8x16_abs => v2sv(ops.i8x16Abs(sv2v(src))),
        .i8x16_neg => v2sv(ops.i8x16Neg(sv2v(src))),
        .i8x16_popcnt => v2sv(ops.unaryI8Popcnt(sv2v(src))),
        .i8x16_all_true => SimdVal.fromScalar(RawVal.from(@as(i32, if (ops.i8x16AllTrue(sv2v(src))) 1 else 0))),
        .i8x16_bitmask => SimdVal.fromScalar(RawVal.from(ops.i8x16Bitmask(sv2v(src)))),
        // i16x8 unary
        .i16x8_abs => v2sv(ops.i16x8Abs(sv2v(src))),
        .i16x8_neg => v2sv(ops.i16x8Neg(sv2v(src))),
        .i16x8_all_true => SimdVal.fromScalar(RawVal.from(@as(i32, if (ops.i16x8AllTrue(sv2v(src))) 1 else 0))),
        .i16x8_bitmask => SimdVal.fromScalar(RawVal.from(ops.i16x8Bitmask(sv2v(src)))),
        // i32x4 unary
        .i32x4_abs => v2sv(ops.i32x4Abs(sv2v(src))),
        .i32x4_neg => v2sv(ops.i32x4Neg(sv2v(src))),
        .i32x4_all_true => SimdVal.fromScalar(RawVal.from(@as(i32, if (ops.i32x4AllTrue(sv2v(src))) 1 else 0))),
        .i32x4_bitmask => SimdVal.fromScalar(RawVal.from(ops.i32x4Bitmask(sv2v(src)))),
        // i64x2 unary
        .i64x2_abs => v2sv(ops.i64x2Abs(sv2v(src))),
        .i64x2_neg => v2sv(ops.i64x2Neg(sv2v(src))),
        .i64x2_all_true => SimdVal.fromScalar(RawVal.from(@as(i32, if (ops.i64x2AllTrue(sv2v(src))) 1 else 0))),
        .i64x2_bitmask => SimdVal.fromScalar(RawVal.from(ops.i64x2Bitmask(sv2v(src)))),
        // f32x4 unary
        .f32x4_abs => v2sv(ops.f32x4Abs(sv2v(src))),
        .f32x4_neg => v2sv(ops.f32x4Neg(sv2v(src))),
        .f32x4_sqrt => v2sv(ops.f32x4Sqrt(sv2v(src))),
        .f32x4_ceil => v2sv(ops.f32x4Ceil(sv2v(src))),
        .f32x4_floor => v2sv(ops.f32x4Floor(sv2v(src))),
        .f32x4_trunc => v2sv(ops.f32x4Trunc(sv2v(src))),
        .f32x4_nearest => v2sv(ops.f32x4Nearest(sv2v(src))),
        // f64x2 unary
        .f64x2_abs => v2sv(ops.f64x2Abs(sv2v(src))),
        .f64x2_neg => v2sv(ops.f64x2Neg(sv2v(src))),
        .f64x2_sqrt => v2sv(ops.f64x2Sqrt(sv2v(src))),
        .f64x2_ceil => v2sv(ops.f64x2Ceil(sv2v(src))),
        .f64x2_floor => v2sv(ops.f64x2Floor(sv2v(src))),
        .f64x2_trunc => v2sv(ops.f64x2Trunc(sv2v(src))),
        .f64x2_nearest => v2sv(ops.f64x2Nearest(sv2v(src))),
        // extadd pairwise
        .i16x8_extadd_pairwise_i8x16_s => v2sv(ops.i16x8ExtaddPairwiseI8x16S(sv2v(src))),
        .i16x8_extadd_pairwise_i8x16_u => v2sv(ops.i16x8ExtaddPairwiseI8x16U(sv2v(src))),
        .i32x4_extadd_pairwise_i16x8_s => v2sv(ops.i32x4ExtaddPairwiseI16x8S(sv2v(src))),
        .i32x4_extadd_pairwise_i16x8_u => v2sv(ops.i32x4ExtaddPairwiseI16x8U(sv2v(src))),
        // extend half
        .i16x8_extend_low_i8x16_s => v2sv(ops.i16x8ExtendLowI8x16S(sv2v(src))),
        .i16x8_extend_high_i8x16_s => v2sv(ops.i16x8ExtendHighI8x16S(sv2v(src))),
        .i16x8_extend_low_i8x16_u => v2sv(ops.i16x8ExtendLowI8x16U(sv2v(src))),
        .i16x8_extend_high_i8x16_u => v2sv(ops.i16x8ExtendHighI8x16U(sv2v(src))),
        .i32x4_extend_low_i16x8_s => v2sv(ops.i32x4ExtendLowI16x8S(sv2v(src))),
        .i32x4_extend_high_i16x8_s => v2sv(ops.i32x4ExtendHighI16x8S(sv2v(src))),
        .i32x4_extend_low_i16x8_u => v2sv(ops.i32x4ExtendLowI16x8U(sv2v(src))),
        .i32x4_extend_high_i16x8_u => v2sv(ops.i32x4ExtendHighI16x8U(sv2v(src))),
        .i64x2_extend_low_i32x4_s => v2sv(ops.i64x2ExtendLowI32x4S(sv2v(src))),
        .i64x2_extend_high_i32x4_s => v2sv(ops.i64x2ExtendHighI32x4S(sv2v(src))),
        .i64x2_extend_low_i32x4_u => v2sv(ops.i64x2ExtendLowI32x4U(sv2v(src))),
        .i64x2_extend_high_i32x4_u => v2sv(ops.i64x2ExtendHighI32x4U(sv2v(src))),
        // conversions
        .f32x4_demote_f64x2_zero => v2sv(ops.demoteF64x2Zero(sv2v(src))),
        .f64x2_promote_low_f32x4 => v2sv(ops.promoteLowF32x4(sv2v(src))),
        .i32x4_trunc_sat_f32x4_s, .i32x4_relaxed_trunc_f32x4_s => v2sv(ops.i32x4RelaxedTruncF32x4S(sv2v(src))),
        .i32x4_trunc_sat_f32x4_u, .i32x4_relaxed_trunc_f32x4_u => v2sv(ops.i32x4RelaxedTruncF32x4U(sv2v(src))),
        .i32x4_trunc_sat_f64x2_s_zero, .i32x4_relaxed_trunc_f64x2_s_zero => v2sv(ops.i32x4RelaxedTruncF64x2SZero(sv2v(src))),
        .i32x4_trunc_sat_f64x2_u_zero, .i32x4_relaxed_trunc_f64x2_u_zero => v2sv(ops.i32x4RelaxedTruncF64x2UZero(sv2v(src))),
        .f32x4_convert_i32x4_s => v2sv(ops.f32x4ConvertI32x4S(sv2v(src))),
        .f32x4_convert_i32x4_u => v2sv(ops.f32x4ConvertI32x4U(sv2v(src))),
        .f64x2_convert_low_i32x4_s => v2sv(ops.f64x2ConvertLowI32x4S(sv2v(src))),
        .f64x2_convert_low_i32x4_u => v2sv(ops.f64x2ConvertLowI32x4U(sv2v(src))),
        else => unreachable,
    };
}

/// Dispatches a binary SIMD operation. Covers bitwise, integer/float arithmetic,
/// saturating arithmetic, narrowing, extended multiplication, and dot products.
pub fn executeBinary(opcode: SimdOpcode, lhs: SimdVal, rhs: SimdVal) SimdVal {
    return v2sv(switch (opcode) {
        .v128_and => ops.bytesBinary(sv2v(lhs), sv2v(rhs), .@"and"),
        .v128_andnot => ops.bytesBinary(sv2v(lhs), sv2v(rhs), .andnot),
        .v128_or => ops.bytesBinary(sv2v(lhs), sv2v(rhs), .@"or"),
        .v128_xor => ops.bytesBinary(sv2v(lhs), sv2v(rhs), .xor),
        .i8x16_swizzle, .i8x16_relaxed_swizzle => ops.swizzle(sv2v(lhs), sv2v(rhs)),
        // i8x16 binary
        .i8x16_add => ops.i8x16Add(sv2v(lhs), sv2v(rhs)),
        .i8x16_add_sat_s => ops.i8x16AddSatS(sv2v(lhs), sv2v(rhs)),
        .i8x16_add_sat_u => ops.i8x16AddSatU(sv2v(lhs), sv2v(rhs)),
        .i8x16_sub => ops.i8x16Sub(sv2v(lhs), sv2v(rhs)),
        .i8x16_sub_sat_s => ops.i8x16SubSatS(sv2v(lhs), sv2v(rhs)),
        .i8x16_sub_sat_u => ops.i8x16SubSatU(sv2v(lhs), sv2v(rhs)),
        .i8x16_min_s => ops.i8x16MinS(sv2v(lhs), sv2v(rhs)),
        .i8x16_min_u => ops.i8x16MinU(sv2v(lhs), sv2v(rhs)),
        .i8x16_max_s => ops.i8x16MaxS(sv2v(lhs), sv2v(rhs)),
        .i8x16_max_u => ops.i8x16MaxU(sv2v(lhs), sv2v(rhs)),
        .i8x16_avgr_u => ops.i8x16AvgrU(sv2v(lhs), sv2v(rhs)),
        // i16x8 binary
        .i16x8_q15mulr_sat_s, .i16x8_relaxed_q15mulr_s => ops.q15mulr(sv2v(lhs), sv2v(rhs)),
        .i16x8_add => ops.i16x8Add(sv2v(lhs), sv2v(rhs)),
        .i16x8_add_sat_s => ops.i16x8AddSatS(sv2v(lhs), sv2v(rhs)),
        .i16x8_add_sat_u => ops.i16x8AddSatU(sv2v(lhs), sv2v(rhs)),
        .i16x8_sub => ops.i16x8Sub(sv2v(lhs), sv2v(rhs)),
        .i16x8_sub_sat_s => ops.i16x8SubSatS(sv2v(lhs), sv2v(rhs)),
        .i16x8_sub_sat_u => ops.i16x8SubSatU(sv2v(lhs), sv2v(rhs)),
        .i16x8_mul => ops.i16x8Mul(sv2v(lhs), sv2v(rhs)),
        .i16x8_min_s => ops.i16x8MinS(sv2v(lhs), sv2v(rhs)),
        .i16x8_min_u => ops.i16x8MinU(sv2v(lhs), sv2v(rhs)),
        .i16x8_max_s => ops.i16x8MaxS(sv2v(lhs), sv2v(rhs)),
        .i16x8_max_u => ops.i16x8MaxU(sv2v(lhs), sv2v(rhs)),
        .i16x8_avgr_u => ops.i16x8AvgrU(sv2v(lhs), sv2v(rhs)),
        // i32x4 binary
        .i32x4_add => ops.i32x4Add(sv2v(lhs), sv2v(rhs)),
        .i32x4_sub => ops.i32x4Sub(sv2v(lhs), sv2v(rhs)),
        .i32x4_mul => ops.i32x4Mul(sv2v(lhs), sv2v(rhs)),
        .i32x4_min_s => ops.i32x4MinS(sv2v(lhs), sv2v(rhs)),
        .i32x4_min_u => ops.i32x4MinU(sv2v(lhs), sv2v(rhs)),
        .i32x4_max_s => ops.i32x4MaxS(sv2v(lhs), sv2v(rhs)),
        .i32x4_max_u => ops.i32x4MaxU(sv2v(lhs), sv2v(rhs)),
        .i32x4_dot_i16x8_s => ops.dotI16x8ToI32x4(sv2v(lhs), sv2v(rhs)),
        // i64x2 binary
        .i64x2_add => ops.i64x2Add(sv2v(lhs), sv2v(rhs)),
        .i64x2_sub => ops.i64x2Sub(sv2v(lhs), sv2v(rhs)),
        .i64x2_mul => ops.i64x2Mul(sv2v(lhs), sv2v(rhs)),
        // f32x4 binary
        .f32x4_add => ops.f32x4Add(sv2v(lhs), sv2v(rhs)),
        .f32x4_sub => ops.f32x4Sub(sv2v(lhs), sv2v(rhs)),
        .f32x4_mul => ops.f32x4Mul(sv2v(lhs), sv2v(rhs)),
        .f32x4_div => ops.f32x4Div(sv2v(lhs), sv2v(rhs)),
        .f32x4_min, .f32x4_relaxed_min => ops.f32x4RelaxedMin(sv2v(lhs), sv2v(rhs)),
        .f32x4_max, .f32x4_relaxed_max => ops.f32x4RelaxedMax(sv2v(lhs), sv2v(rhs)),
        .f32x4_pmin => ops.f32x4Pmin(sv2v(lhs), sv2v(rhs)),
        .f32x4_pmax => ops.f32x4Pmax(sv2v(lhs), sv2v(rhs)),
        // f64x2 binary
        .f64x2_add => ops.f64x2Add(sv2v(lhs), sv2v(rhs)),
        .f64x2_sub => ops.f64x2Sub(sv2v(lhs), sv2v(rhs)),
        .f64x2_mul => ops.f64x2Mul(sv2v(lhs), sv2v(rhs)),
        .f64x2_div => ops.f64x2Div(sv2v(lhs), sv2v(rhs)),
        .f64x2_min, .f64x2_relaxed_min => ops.f64x2RelaxedMin(sv2v(lhs), sv2v(rhs)),
        .f64x2_max, .f64x2_relaxed_max => ops.f64x2RelaxedMax(sv2v(lhs), sv2v(rhs)),
        .f64x2_pmin => ops.f64x2Pmin(sv2v(lhs), sv2v(rhs)),
        .f64x2_pmax => ops.f64x2Pmax(sv2v(lhs), sv2v(rhs)),
        // narrow
        .i8x16_narrow_i16x8_s => ops.i8x16NarrowI16x8S(sv2v(lhs), sv2v(rhs)),
        .i8x16_narrow_i16x8_u => ops.i8x16NarrowI16x8U(sv2v(lhs), sv2v(rhs)),
        .i16x8_narrow_i32x4_s => ops.i16x8NarrowI32x4S(sv2v(lhs), sv2v(rhs)),
        .i16x8_narrow_i32x4_u => ops.i16x8NarrowI32x4U(sv2v(lhs), sv2v(rhs)),
        // extmul
        .i16x8_extmul_low_i8x16_s => ops.i16x8ExtmulLowI8x16S(sv2v(lhs), sv2v(rhs)),
        .i16x8_extmul_high_i8x16_s => ops.i16x8ExtmulHighI8x16S(sv2v(lhs), sv2v(rhs)),
        .i16x8_extmul_low_i8x16_u => ops.i16x8ExtmulLowI8x16U(sv2v(lhs), sv2v(rhs)),
        .i16x8_extmul_high_i8x16_u => ops.i16x8ExtmulHighI8x16U(sv2v(lhs), sv2v(rhs)),
        .i32x4_extmul_low_i16x8_s => ops.i32x4ExtmulLowI16x8S(sv2v(lhs), sv2v(rhs)),
        .i32x4_extmul_high_i16x8_s => ops.i32x4ExtmulHighI16x8S(sv2v(lhs), sv2v(rhs)),
        .i32x4_extmul_low_i16x8_u => ops.i32x4ExtmulLowI16x8U(sv2v(lhs), sv2v(rhs)),
        .i32x4_extmul_high_i16x8_u => ops.i32x4ExtmulHighI16x8U(sv2v(lhs), sv2v(rhs)),
        .i64x2_extmul_low_i32x4_s => ops.i64x2ExtmulLowI32x4S(sv2v(lhs), sv2v(rhs)),
        .i64x2_extmul_high_i32x4_s => ops.i64x2ExtmulHighI32x4S(sv2v(lhs), sv2v(rhs)),
        .i64x2_extmul_low_i32x4_u => ops.i64x2ExtmulLowI32x4U(sv2v(lhs), sv2v(rhs)),
        .i64x2_extmul_high_i32x4_u => ops.i64x2ExtmulHighI32x4U(sv2v(lhs), sv2v(rhs)),
        // relaxed dot
        .i16x8_relaxed_dot_i8x16_i7x16_s => ops.relaxedDotI8x16ToI16x8(sv2v(lhs), sv2v(rhs)),
        else => unreachable,
    });
}

/// Dispatches a ternary SIMD operation: bitselect, relaxed lane-select,
/// relaxed fused multiply-add, and relaxed dot-product-add.
pub fn executeTernary(opcode: SimdOpcode, first: SimdVal, second: SimdVal, third: SimdVal) SimdVal {
    return v2sv(switch (opcode) {
        .v128_bitselect,
        .i8x16_relaxed_laneselect,
        .i16x8_relaxed_laneselect,
        .i32x4_relaxed_laneselect,
        .i64x2_relaxed_laneselect,
        => ops.bitselect(sv2v(first), sv2v(second), sv2v(third)),
        .f32x4_relaxed_madd => ops.f32x4RelaxedMadd(sv2v(first), sv2v(second), sv2v(third)),
        .f32x4_relaxed_nmadd => ops.f32x4RelaxedNmadd(sv2v(first), sv2v(second), sv2v(third)),
        .f64x2_relaxed_madd => ops.f64x2RelaxedMadd(sv2v(first), sv2v(second), sv2v(third)),
        .f64x2_relaxed_nmadd => ops.f64x2RelaxedNmadd(sv2v(first), sv2v(second), sv2v(third)),
        .i32x4_relaxed_dot_i8x16_i7x16_add_s => ops.relaxedDotAddI8x16ToI32x4(sv2v(first), sv2v(second), sv2v(third)),
        else => unreachable,
    });
}

/// Dispatches a SIMD comparison. Returns SimdVal with all-ones / all-zeros lanes.
pub fn executeCompare(opcode: SimdOpcode, lhs: SimdVal, rhs: SimdVal) SimdVal {
    return v2sv(switch (opcode) {
        .i8x16_eq => ops.i8x16Eq(sv2v(lhs), sv2v(rhs)),
        .i8x16_ne => ops.i8x16Ne(sv2v(lhs), sv2v(rhs)),
        .i8x16_lt_s => ops.i8x16LtS(sv2v(lhs), sv2v(rhs)),
        .i8x16_lt_u => ops.i8x16LtU(sv2v(lhs), sv2v(rhs)),
        .i8x16_gt_s => ops.i8x16GtS(sv2v(lhs), sv2v(rhs)),
        .i8x16_gt_u => ops.i8x16GtU(sv2v(lhs), sv2v(rhs)),
        .i8x16_le_s => ops.i8x16LeS(sv2v(lhs), sv2v(rhs)),
        .i8x16_le_u => ops.i8x16LeU(sv2v(lhs), sv2v(rhs)),
        .i8x16_ge_s => ops.i8x16GeS(sv2v(lhs), sv2v(rhs)),
        .i8x16_ge_u => ops.i8x16GeU(sv2v(lhs), sv2v(rhs)),
        .i16x8_eq => ops.i16x8Eq(sv2v(lhs), sv2v(rhs)),
        .i16x8_ne => ops.i16x8Ne(sv2v(lhs), sv2v(rhs)),
        .i16x8_lt_s => ops.i16x8LtS(sv2v(lhs), sv2v(rhs)),
        .i16x8_lt_u => ops.i16x8LtU(sv2v(lhs), sv2v(rhs)),
        .i16x8_gt_s => ops.i16x8GtS(sv2v(lhs), sv2v(rhs)),
        .i16x8_gt_u => ops.i16x8GtU(sv2v(lhs), sv2v(rhs)),
        .i16x8_le_s => ops.i16x8LeS(sv2v(lhs), sv2v(rhs)),
        .i16x8_le_u => ops.i16x8LeU(sv2v(lhs), sv2v(rhs)),
        .i16x8_ge_s => ops.i16x8GeS(sv2v(lhs), sv2v(rhs)),
        .i16x8_ge_u => ops.i16x8GeU(sv2v(lhs), sv2v(rhs)),
        .i32x4_eq => ops.i32x4Eq(sv2v(lhs), sv2v(rhs)),
        .i32x4_ne => ops.i32x4Ne(sv2v(lhs), sv2v(rhs)),
        .i32x4_lt_s => ops.i32x4LtS(sv2v(lhs), sv2v(rhs)),
        .i32x4_lt_u => ops.i32x4LtU(sv2v(lhs), sv2v(rhs)),
        .i32x4_gt_s => ops.i32x4GtS(sv2v(lhs), sv2v(rhs)),
        .i32x4_gt_u => ops.i32x4GtU(sv2v(lhs), sv2v(rhs)),
        .i32x4_le_s => ops.i32x4LeS(sv2v(lhs), sv2v(rhs)),
        .i32x4_le_u => ops.i32x4LeU(sv2v(lhs), sv2v(rhs)),
        .i32x4_ge_s => ops.i32x4GeS(sv2v(lhs), sv2v(rhs)),
        .i32x4_ge_u => ops.i32x4GeU(sv2v(lhs), sv2v(rhs)),
        .i64x2_eq => ops.i64x2Eq(sv2v(lhs), sv2v(rhs)),
        .i64x2_ne => ops.i64x2Ne(sv2v(lhs), sv2v(rhs)),
        .i64x2_lt_s => ops.i64x2LtS(sv2v(lhs), sv2v(rhs)),
        .i64x2_gt_s => ops.i64x2GtS(sv2v(lhs), sv2v(rhs)),
        .i64x2_le_s => ops.i64x2LeS(sv2v(lhs), sv2v(rhs)),
        .i64x2_ge_s => ops.i64x2GeS(sv2v(lhs), sv2v(rhs)),
        .f32x4_eq => ops.f32x4Eq(sv2v(lhs), sv2v(rhs)),
        .f32x4_ne => ops.f32x4Ne(sv2v(lhs), sv2v(rhs)),
        .f32x4_lt => ops.f32x4Lt(sv2v(lhs), sv2v(rhs)),
        .f32x4_gt => ops.f32x4Gt(sv2v(lhs), sv2v(rhs)),
        .f32x4_le => ops.f32x4Le(sv2v(lhs), sv2v(rhs)),
        .f32x4_ge => ops.f32x4Ge(sv2v(lhs), sv2v(rhs)),
        .f64x2_eq => ops.f64x2Eq(sv2v(lhs), sv2v(rhs)),
        .f64x2_ne => ops.f64x2Ne(sv2v(lhs), sv2v(rhs)),
        .f64x2_lt => ops.f64x2Lt(sv2v(lhs), sv2v(rhs)),
        .f64x2_gt => ops.f64x2Gt(sv2v(lhs), sv2v(rhs)),
        .f64x2_le => ops.f64x2Le(sv2v(lhs), sv2v(rhs)),
        .f64x2_ge => ops.f64x2Ge(sv2v(lhs), sv2v(rhs)),
        else => unreachable,
    });
}

/// Dispatches a SIMD shift operation. The shift amount (rhs) is a scalar u32
/// (stored in a RawVal), masked to the lane bit-width by the spec.
pub fn executeShift(opcode: SimdOpcode, lhs: SimdVal, rhs: RawVal) SimdVal {
    const amount = rhs.readAs(u32);
    return v2sv(switch (opcode) {
        .i8x16_shl => ops.i8x16Shl(sv2v(lhs), amount),
        .i8x16_shr_s => ops.i8x16ShrS(sv2v(lhs), amount),
        .i8x16_shr_u => ops.i8x16ShrU(sv2v(lhs), amount),
        .i16x8_shl => ops.i16x8Shl(sv2v(lhs), amount),
        .i16x8_shr_s => ops.i16x8ShrS(sv2v(lhs), amount),
        .i16x8_shr_u => ops.i16x8ShrU(sv2v(lhs), amount),
        .i32x4_shl => ops.i32x4Shl(sv2v(lhs), amount),
        .i32x4_shr_s => ops.i32x4ShrS(sv2v(lhs), amount),
        .i32x4_shr_u => ops.i32x4ShrU(sv2v(lhs), amount),
        .i64x2_shl => ops.i64x2Shl(sv2v(lhs), amount),
        .i64x2_shr_s => ops.i64x2ShrS(sv2v(lhs), amount),
        .i64x2_shr_u => ops.i64x2ShrU(sv2v(lhs), amount),
        else => unreachable,
    });
}

/// Extracts a scalar value from the specified lane of a V128 vector.
/// The result is sign- or zero-extended to i32 for sub-32-bit lanes.
/// Returns a RawVal (scalar result).
pub fn extractLane(opcode: SimdOpcode, src: SimdVal, lane: u8) RawVal {
    const value = sv2v(src);
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

/// Replaces a single lane in src_vec with the scalar src_lane value (RawVal).
/// Returns a SimdVal.
pub fn replaceLane(opcode: SimdOpcode, src_vec: SimdVal, src_lane: RawVal, lane: u8) SimdVal {
    var out = sv2v(src_vec);
    switch (opcode) {
        .i8x16_replace_lane => ops.writeLane(i8, &out.bytes, lane, src_lane.readAs(i8)),
        .i16x8_replace_lane => ops.writeLane(i16, &out.bytes, lane, src_lane.readAs(i16)),
        .i32x4_replace_lane => ops.writeLane(i32, &out.bytes, lane, src_lane.readAs(i32)),
        .i64x2_replace_lane => ops.writeLane(i64, &out.bytes, lane, src_lane.readAs(i64)),
        .f32x4_replace_lane => ops.writeLane(f32, &out.bytes, lane, src_lane.readAs(f32)),
        .f64x2_replace_lane => ops.writeLane(f64, &out.bytes, lane, src_lane.readAs(f64)),
        else => unreachable,
    }
    return v2sv(out);
}

/// i8x16.shuffle: selects bytes from the concatenation of lhs and rhs
/// using the 16-byte immediate `lanes` as indices (0..31).
pub fn shuffleVectors(lhs: SimdVal, rhs: SimdVal, lanes_arr: [16]u8) SimdVal {
    return v2sv(ops.shuffleBytes(sv2v(lhs), sv2v(rhs), lanes_arr));
}

/// Loads a V128 from memory. Returns a SimdVal.
pub fn load(opcode: SimdOpcode, memory: []const u8, addr: u64, offset: u32, lane: ?u8, src_vec: ?SimdVal) SimdVal {
    const sv: ?V128 = if (src_vec) |sv| sv.toV128() else null;
    return v2sv(mem_ops.load(opcode, memory, addr, offset, lane, sv));
}

/// Stores a V128 to memory from a SimdVal.
pub fn store(opcode: SimdOpcode, memory: []u8, addr: u64, offset: u32, lane: ?u8, src: SimdVal) void {
    mem_ops.store(opcode, memory, addr, offset, lane, src.toV128());
}

// Private helpers

/// Creates a V128 where all lanes are filled with the same scalar value.
/// `scalar` carries the scalar value in its low 8 bytes (as a RawVal).
fn splatScalar(opcode: SimdOpcode, scalar: RawVal) V128 {
    return switch (classify.shapeOf(opcode).?) {
        .i8x16 => ops.i8x16Splat(scalar.readAs(i8)),
        .i16x8 => ops.i16x8Splat(scalar.readAs(i16)),
        .i32x4 => ops.i32x4Splat(scalar.readAs(i32)),
        .i64x2 => ops.i64x2Splat(scalar.readAs(i64)),
        .f32x4 => ops.f32x4Splat(scalar.readAs(f32)),
        .f64x2 => ops.f64x2Splat(scalar.readAs(f64)),
    };
}

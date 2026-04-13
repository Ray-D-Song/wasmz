// SIMD public execution dispatchers.
//
// These are the entry points called by the VM dispatcher (vm/root.zig).
// Each function takes a SimdOpcode and SimdVal operands, dispatches to the
// appropriate helper in ops.zig / memory.zig, and returns a SimdVal.
//
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

// ── Conversion helpers ────────────────────────────────────────────────────────

inline fn sv2v(s: SimdVal) V128 {
    return s.toV128();
}

inline fn v2sv(v: V128) SimdVal {
    return SimdVal.fromV128(v);
}

// ── Public API ────────────────────────────────────────────────────────────────

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
        .i8x16_abs => v2sv(ops.unaryInt(i8, 16, sv2v(src), .abs)),
        .i8x16_neg => v2sv(ops.unaryInt(i8, 16, sv2v(src), .neg)),
        .i8x16_popcnt => v2sv(ops.unaryI8Popcnt(sv2v(src))),
        .i8x16_all_true => SimdVal.fromScalar(RawVal.from(@as(i32, if (ops.allTrue(i8, 16, sv2v(src))) 1 else 0))),
        .i8x16_bitmask => SimdVal.fromScalar(RawVal.from(ops.bitmask(i8, 16, sv2v(src)))),
        // i16x8 unary
        .i16x8_abs => v2sv(ops.unaryInt(i16, 8, sv2v(src), .abs)),
        .i16x8_neg => v2sv(ops.unaryInt(i16, 8, sv2v(src), .neg)),
        .i16x8_all_true => SimdVal.fromScalar(RawVal.from(@as(i32, if (ops.allTrue(i16, 8, sv2v(src))) 1 else 0))),
        .i16x8_bitmask => SimdVal.fromScalar(RawVal.from(ops.bitmask(i16, 8, sv2v(src)))),
        // i32x4 unary
        .i32x4_abs => v2sv(ops.unaryInt(i32, 4, sv2v(src), .abs)),
        .i32x4_neg => v2sv(ops.unaryInt(i32, 4, sv2v(src), .neg)),
        .i32x4_all_true => SimdVal.fromScalar(RawVal.from(@as(i32, if (ops.allTrue(i32, 4, sv2v(src))) 1 else 0))),
        .i32x4_bitmask => SimdVal.fromScalar(RawVal.from(ops.bitmask(i32, 4, sv2v(src)))),
        // i64x2 unary
        .i64x2_abs => v2sv(ops.unaryInt(i64, 2, sv2v(src), .abs)),
        .i64x2_neg => v2sv(ops.unaryInt(i64, 2, sv2v(src), .neg)),
        .i64x2_all_true => SimdVal.fromScalar(RawVal.from(@as(i32, if (ops.allTrue(i64, 2, sv2v(src))) 1 else 0))),
        .i64x2_bitmask => SimdVal.fromScalar(RawVal.from(ops.bitmask(i64, 2, sv2v(src)))),
        // f32x4 unary
        .f32x4_abs => v2sv(ops.unaryFloat(f32, 4, sv2v(src), .abs)),
        .f32x4_neg => v2sv(ops.unaryFloat(f32, 4, sv2v(src), .neg)),
        .f32x4_sqrt => v2sv(ops.unaryFloat(f32, 4, sv2v(src), .sqrt)),
        .f32x4_ceil => v2sv(ops.unaryFloat(f32, 4, sv2v(src), .ceil)),
        .f32x4_floor => v2sv(ops.unaryFloat(f32, 4, sv2v(src), .floor)),
        .f32x4_trunc => v2sv(ops.unaryFloat(f32, 4, sv2v(src), .trunc)),
        .f32x4_nearest => v2sv(ops.unaryFloat(f32, 4, sv2v(src), .nearest)),
        // f64x2 unary
        .f64x2_abs => v2sv(ops.unaryFloat(f64, 2, sv2v(src), .abs)),
        .f64x2_neg => v2sv(ops.unaryFloat(f64, 2, sv2v(src), .neg)),
        .f64x2_sqrt => v2sv(ops.unaryFloat(f64, 2, sv2v(src), .sqrt)),
        .f64x2_ceil => v2sv(ops.unaryFloat(f64, 2, sv2v(src), .ceil)),
        .f64x2_floor => v2sv(ops.unaryFloat(f64, 2, sv2v(src), .floor)),
        .f64x2_trunc => v2sv(ops.unaryFloat(f64, 2, sv2v(src), .trunc)),
        .f64x2_nearest => v2sv(ops.unaryFloat(f64, 2, sv2v(src), .nearest)),
        // extadd pairwise
        .i16x8_extadd_pairwise_i8x16_s => v2sv(ops.extaddPairwise(i8, i16, 8, sv2v(src))),
        .i16x8_extadd_pairwise_i8x16_u => v2sv(ops.extaddPairwise(u8, u16, 8, sv2v(src))),
        .i32x4_extadd_pairwise_i16x8_s => v2sv(ops.extaddPairwise(i16, i32, 4, sv2v(src))),
        .i32x4_extadd_pairwise_i16x8_u => v2sv(ops.extaddPairwise(u16, u32, 4, sv2v(src))),
        // extend half
        .i16x8_extend_low_i8x16_s => v2sv(ops.extendHalf(i8, i16, sv2v(src), .low)),
        .i16x8_extend_high_i8x16_s => v2sv(ops.extendHalf(i8, i16, sv2v(src), .high)),
        .i16x8_extend_low_i8x16_u => v2sv(ops.extendHalf(u8, i16, sv2v(src), .low)),
        .i16x8_extend_high_i8x16_u => v2sv(ops.extendHalf(u8, i16, sv2v(src), .high)),
        .i32x4_extend_low_i16x8_s => v2sv(ops.extendHalf(i16, i32, sv2v(src), .low)),
        .i32x4_extend_high_i16x8_s => v2sv(ops.extendHalf(i16, i32, sv2v(src), .high)),
        .i32x4_extend_low_i16x8_u => v2sv(ops.extendHalf(u16, i32, sv2v(src), .low)),
        .i32x4_extend_high_i16x8_u => v2sv(ops.extendHalf(u16, i32, sv2v(src), .high)),
        .i64x2_extend_low_i32x4_s => v2sv(ops.extendHalf(i32, i64, sv2v(src), .low)),
        .i64x2_extend_high_i32x4_s => v2sv(ops.extendHalf(i32, i64, sv2v(src), .high)),
        .i64x2_extend_low_i32x4_u => v2sv(ops.extendHalf(u32, i64, sv2v(src), .low)),
        .i64x2_extend_high_i32x4_u => v2sv(ops.extendHalf(u32, i64, sv2v(src), .high)),
        // conversions
        .f32x4_demote_f64x2_zero => v2sv(ops.demoteF64x2Zero(sv2v(src))),
        .f64x2_promote_low_f32x4 => v2sv(ops.promoteLowF32x4(sv2v(src))),
        .i32x4_trunc_sat_f32x4_s, .i32x4_relaxed_trunc_f32x4_s => v2sv(ops.truncSatF32x4ToI32x4(sv2v(src), true)),
        .i32x4_trunc_sat_f32x4_u, .i32x4_relaxed_trunc_f32x4_u => v2sv(ops.truncSatF32x4ToI32x4(sv2v(src), false)),
        .i32x4_trunc_sat_f64x2_s_zero, .i32x4_relaxed_trunc_f64x2_s_zero => v2sv(ops.truncSatF64x2ToI32x4Zero(sv2v(src), true)),
        .i32x4_trunc_sat_f64x2_u_zero, .i32x4_relaxed_trunc_f64x2_u_zero => v2sv(ops.truncSatF64x2ToI32x4Zero(sv2v(src), false)),
        .f32x4_convert_i32x4_s => v2sv(ops.convertI32x4ToF32x4(sv2v(src), true)),
        .f32x4_convert_i32x4_u => v2sv(ops.convertI32x4ToF32x4(sv2v(src), false)),
        .f64x2_convert_low_i32x4_s => v2sv(ops.convertLowI32x4ToF64x2(sv2v(src), true)),
        .f64x2_convert_low_i32x4_u => v2sv(ops.convertLowI32x4ToF64x2(sv2v(src), false)),
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
        .i8x16_add => ops.binaryInt(i8, 16, sv2v(lhs), sv2v(rhs), .add),
        .i8x16_add_sat_s => ops.binaryInt(i8, 16, sv2v(lhs), sv2v(rhs), .add_sat),
        .i8x16_add_sat_u => ops.binaryInt(u8, 16, sv2v(lhs), sv2v(rhs), .add_sat),
        .i8x16_sub => ops.binaryInt(i8, 16, sv2v(lhs), sv2v(rhs), .sub),
        .i8x16_sub_sat_s => ops.binaryInt(i8, 16, sv2v(lhs), sv2v(rhs), .sub_sat),
        .i8x16_sub_sat_u => ops.binaryInt(u8, 16, sv2v(lhs), sv2v(rhs), .sub_sat),
        .i8x16_min_s => ops.binaryInt(i8, 16, sv2v(lhs), sv2v(rhs), .min),
        .i8x16_min_u => ops.binaryInt(u8, 16, sv2v(lhs), sv2v(rhs), .min),
        .i8x16_max_s => ops.binaryInt(i8, 16, sv2v(lhs), sv2v(rhs), .max),
        .i8x16_max_u => ops.binaryInt(u8, 16, sv2v(lhs), sv2v(rhs), .max),
        .i8x16_avgr_u => ops.binaryInt(u8, 16, sv2v(lhs), sv2v(rhs), .avgr_u),
        // i16x8 binary
        .i16x8_q15mulr_sat_s, .i16x8_relaxed_q15mulr_s => ops.q15mulr(sv2v(lhs), sv2v(rhs)),
        .i16x8_add => ops.binaryInt(i16, 8, sv2v(lhs), sv2v(rhs), .add),
        .i16x8_add_sat_s => ops.binaryInt(i16, 8, sv2v(lhs), sv2v(rhs), .add_sat),
        .i16x8_add_sat_u => ops.binaryInt(u16, 8, sv2v(lhs), sv2v(rhs), .add_sat),
        .i16x8_sub => ops.binaryInt(i16, 8, sv2v(lhs), sv2v(rhs), .sub),
        .i16x8_sub_sat_s => ops.binaryInt(i16, 8, sv2v(lhs), sv2v(rhs), .sub_sat),
        .i16x8_sub_sat_u => ops.binaryInt(u16, 8, sv2v(lhs), sv2v(rhs), .sub_sat),
        .i16x8_mul => ops.binaryInt(i16, 8, sv2v(lhs), sv2v(rhs), .mul),
        .i16x8_min_s => ops.binaryInt(i16, 8, sv2v(lhs), sv2v(rhs), .min),
        .i16x8_min_u => ops.binaryInt(u16, 8, sv2v(lhs), sv2v(rhs), .min),
        .i16x8_max_s => ops.binaryInt(i16, 8, sv2v(lhs), sv2v(rhs), .max),
        .i16x8_max_u => ops.binaryInt(u16, 8, sv2v(lhs), sv2v(rhs), .max),
        .i16x8_avgr_u => ops.binaryInt(u16, 8, sv2v(lhs), sv2v(rhs), .avgr_u),
        // i32x4 binary
        .i32x4_add => ops.binaryInt(i32, 4, sv2v(lhs), sv2v(rhs), .add),
        .i32x4_sub => ops.binaryInt(i32, 4, sv2v(lhs), sv2v(rhs), .sub),
        .i32x4_mul => ops.binaryInt(i32, 4, sv2v(lhs), sv2v(rhs), .mul),
        .i32x4_min_s => ops.binaryInt(i32, 4, sv2v(lhs), sv2v(rhs), .min),
        .i32x4_min_u => ops.binaryInt(u32, 4, sv2v(lhs), sv2v(rhs), .min),
        .i32x4_max_s => ops.binaryInt(i32, 4, sv2v(lhs), sv2v(rhs), .max),
        .i32x4_max_u => ops.binaryInt(u32, 4, sv2v(lhs), sv2v(rhs), .max),
        .i32x4_dot_i16x8_s => ops.dotI16x8ToI32x4(sv2v(lhs), sv2v(rhs)),
        // i64x2 binary
        .i64x2_add => ops.binaryInt(i64, 2, sv2v(lhs), sv2v(rhs), .add),
        .i64x2_sub => ops.binaryInt(i64, 2, sv2v(lhs), sv2v(rhs), .sub),
        .i64x2_mul => ops.binaryInt(i64, 2, sv2v(lhs), sv2v(rhs), .mul),
        // f32x4 binary
        .f32x4_add => ops.binaryFloat(f32, 4, sv2v(lhs), sv2v(rhs), .add),
        .f32x4_sub => ops.binaryFloat(f32, 4, sv2v(lhs), sv2v(rhs), .sub),
        .f32x4_mul => ops.binaryFloat(f32, 4, sv2v(lhs), sv2v(rhs), .mul),
        .f32x4_div => ops.binaryFloat(f32, 4, sv2v(lhs), sv2v(rhs), .div),
        .f32x4_min, .f32x4_relaxed_min => ops.binaryFloat(f32, 4, sv2v(lhs), sv2v(rhs), .min),
        .f32x4_max, .f32x4_relaxed_max => ops.binaryFloat(f32, 4, sv2v(lhs), sv2v(rhs), .max),
        .f32x4_pmin => ops.binaryFloat(f32, 4, sv2v(lhs), sv2v(rhs), .pmin),
        .f32x4_pmax => ops.binaryFloat(f32, 4, sv2v(lhs), sv2v(rhs), .pmax),
        // f64x2 binary
        .f64x2_add => ops.binaryFloat(f64, 2, sv2v(lhs), sv2v(rhs), .add),
        .f64x2_sub => ops.binaryFloat(f64, 2, sv2v(lhs), sv2v(rhs), .sub),
        .f64x2_mul => ops.binaryFloat(f64, 2, sv2v(lhs), sv2v(rhs), .mul),
        .f64x2_div => ops.binaryFloat(f64, 2, sv2v(lhs), sv2v(rhs), .div),
        .f64x2_min, .f64x2_relaxed_min => ops.binaryFloat(f64, 2, sv2v(lhs), sv2v(rhs), .min),
        .f64x2_max, .f64x2_relaxed_max => ops.binaryFloat(f64, 2, sv2v(lhs), sv2v(rhs), .max),
        .f64x2_pmin => ops.binaryFloat(f64, 2, sv2v(lhs), sv2v(rhs), .pmin),
        .f64x2_pmax => ops.binaryFloat(f64, 2, sv2v(lhs), sv2v(rhs), .pmax),
        // narrow
        .i8x16_narrow_i16x8_s => ops.narrow(i16, i8, 8, sv2v(lhs), sv2v(rhs)),
        .i8x16_narrow_i16x8_u => ops.narrow(u16, i8, 8, sv2v(lhs), sv2v(rhs)),
        .i16x8_narrow_i32x4_s => ops.narrow(i32, i16, 4, sv2v(lhs), sv2v(rhs)),
        .i16x8_narrow_i32x4_u => ops.narrow(u32, i16, 4, sv2v(lhs), sv2v(rhs)),
        // extmul
        .i16x8_extmul_low_i8x16_s => ops.extmul(i8, i16, sv2v(lhs), sv2v(rhs), .low),
        .i16x8_extmul_high_i8x16_s => ops.extmul(i8, i16, sv2v(lhs), sv2v(rhs), .high),
        .i16x8_extmul_low_i8x16_u => ops.extmul(u8, i16, sv2v(lhs), sv2v(rhs), .low),
        .i16x8_extmul_high_i8x16_u => ops.extmul(u8, i16, sv2v(lhs), sv2v(rhs), .high),
        .i32x4_extmul_low_i16x8_s => ops.extmul(i16, i32, sv2v(lhs), sv2v(rhs), .low),
        .i32x4_extmul_high_i16x8_s => ops.extmul(i16, i32, sv2v(lhs), sv2v(rhs), .high),
        .i32x4_extmul_low_i16x8_u => ops.extmul(u16, i32, sv2v(lhs), sv2v(rhs), .low),
        .i32x4_extmul_high_i16x8_u => ops.extmul(u16, i32, sv2v(lhs), sv2v(rhs), .high),
        .i64x2_extmul_low_i32x4_s => ops.extmul(i32, i64, sv2v(lhs), sv2v(rhs), .low),
        .i64x2_extmul_high_i32x4_s => ops.extmul(i32, i64, sv2v(lhs), sv2v(rhs), .high),
        .i64x2_extmul_low_i32x4_u => ops.extmul(u32, i64, sv2v(lhs), sv2v(rhs), .low),
        .i64x2_extmul_high_i32x4_u => ops.extmul(u32, i64, sv2v(lhs), sv2v(rhs), .high),
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
        .f32x4_relaxed_madd => ops.floatMulAddVec(f32, 4, sv2v(first), sv2v(second), sv2v(third), false),
        .f32x4_relaxed_nmadd => ops.floatMulAddVec(f32, 4, sv2v(first), sv2v(second), sv2v(third), true),
        .f64x2_relaxed_madd => ops.floatMulAddVec(f64, 2, sv2v(first), sv2v(second), sv2v(third), false),
        .f64x2_relaxed_nmadd => ops.floatMulAddVec(f64, 2, sv2v(first), sv2v(second), sv2v(third), true),
        .i32x4_relaxed_dot_i8x16_i7x16_add_s => ops.relaxedDotAddI8x16ToI32x4(sv2v(first), sv2v(second), sv2v(third)),
        else => unreachable,
    });
}

/// Dispatches a SIMD comparison. Returns SimdVal with all-ones / all-zeros lanes.
pub fn executeCompare(opcode: SimdOpcode, lhs: SimdVal, rhs: SimdVal) SimdVal {
    return v2sv(switch (opcode) {
        .i8x16_eq => ops.compareInt(i8, 16, sv2v(lhs), sv2v(rhs), .eq),
        .i8x16_ne => ops.compareInt(i8, 16, sv2v(lhs), sv2v(rhs), .ne),
        .i8x16_lt_s => ops.compareInt(i8, 16, sv2v(lhs), sv2v(rhs), .lt),
        .i8x16_lt_u => ops.compareInt(u8, 16, sv2v(lhs), sv2v(rhs), .lt),
        .i8x16_gt_s => ops.compareInt(i8, 16, sv2v(lhs), sv2v(rhs), .gt),
        .i8x16_gt_u => ops.compareInt(u8, 16, sv2v(lhs), sv2v(rhs), .gt),
        .i8x16_le_s => ops.compareInt(i8, 16, sv2v(lhs), sv2v(rhs), .le),
        .i8x16_le_u => ops.compareInt(u8, 16, sv2v(lhs), sv2v(rhs), .le),
        .i8x16_ge_s => ops.compareInt(i8, 16, sv2v(lhs), sv2v(rhs), .ge),
        .i8x16_ge_u => ops.compareInt(u8, 16, sv2v(lhs), sv2v(rhs), .ge),
        .i16x8_eq => ops.compareInt(i16, 8, sv2v(lhs), sv2v(rhs), .eq),
        .i16x8_ne => ops.compareInt(i16, 8, sv2v(lhs), sv2v(rhs), .ne),
        .i16x8_lt_s => ops.compareInt(i16, 8, sv2v(lhs), sv2v(rhs), .lt),
        .i16x8_lt_u => ops.compareInt(u16, 8, sv2v(lhs), sv2v(rhs), .lt),
        .i16x8_gt_s => ops.compareInt(i16, 8, sv2v(lhs), sv2v(rhs), .gt),
        .i16x8_gt_u => ops.compareInt(u16, 8, sv2v(lhs), sv2v(rhs), .gt),
        .i16x8_le_s => ops.compareInt(i16, 8, sv2v(lhs), sv2v(rhs), .le),
        .i16x8_le_u => ops.compareInt(u16, 8, sv2v(lhs), sv2v(rhs), .le),
        .i16x8_ge_s => ops.compareInt(i16, 8, sv2v(lhs), sv2v(rhs), .ge),
        .i16x8_ge_u => ops.compareInt(u16, 8, sv2v(lhs), sv2v(rhs), .ge),
        .i32x4_eq => ops.compareInt(i32, 4, sv2v(lhs), sv2v(rhs), .eq),
        .i32x4_ne => ops.compareInt(i32, 4, sv2v(lhs), sv2v(rhs), .ne),
        .i32x4_lt_s => ops.compareInt(i32, 4, sv2v(lhs), sv2v(rhs), .lt),
        .i32x4_lt_u => ops.compareInt(u32, 4, sv2v(lhs), sv2v(rhs), .lt),
        .i32x4_gt_s => ops.compareInt(i32, 4, sv2v(lhs), sv2v(rhs), .gt),
        .i32x4_gt_u => ops.compareInt(u32, 4, sv2v(lhs), sv2v(rhs), .gt),
        .i32x4_le_s => ops.compareInt(i32, 4, sv2v(lhs), sv2v(rhs), .le),
        .i32x4_le_u => ops.compareInt(u32, 4, sv2v(lhs), sv2v(rhs), .le),
        .i32x4_ge_s => ops.compareInt(i32, 4, sv2v(lhs), sv2v(rhs), .ge),
        .i32x4_ge_u => ops.compareInt(u32, 4, sv2v(lhs), sv2v(rhs), .ge),
        .i64x2_eq => ops.compareInt(i64, 2, sv2v(lhs), sv2v(rhs), .eq),
        .i64x2_ne => ops.compareInt(i64, 2, sv2v(lhs), sv2v(rhs), .ne),
        .i64x2_lt_s => ops.compareInt(i64, 2, sv2v(lhs), sv2v(rhs), .lt),
        .i64x2_gt_s => ops.compareInt(i64, 2, sv2v(lhs), sv2v(rhs), .gt),
        .i64x2_le_s => ops.compareInt(i64, 2, sv2v(lhs), sv2v(rhs), .le),
        .i64x2_ge_s => ops.compareInt(i64, 2, sv2v(lhs), sv2v(rhs), .ge),
        .f32x4_eq => ops.compareFloat(f32, 4, sv2v(lhs), sv2v(rhs), .eq),
        .f32x4_ne => ops.compareFloat(f32, 4, sv2v(lhs), sv2v(rhs), .ne),
        .f32x4_lt => ops.compareFloat(f32, 4, sv2v(lhs), sv2v(rhs), .lt),
        .f32x4_gt => ops.compareFloat(f32, 4, sv2v(lhs), sv2v(rhs), .gt),
        .f32x4_le => ops.compareFloat(f32, 4, sv2v(lhs), sv2v(rhs), .le),
        .f32x4_ge => ops.compareFloat(f32, 4, sv2v(lhs), sv2v(rhs), .ge),
        .f64x2_eq => ops.compareFloat(f64, 2, sv2v(lhs), sv2v(rhs), .eq),
        .f64x2_ne => ops.compareFloat(f64, 2, sv2v(lhs), sv2v(rhs), .ne),
        .f64x2_lt => ops.compareFloat(f64, 2, sv2v(lhs), sv2v(rhs), .lt),
        .f64x2_gt => ops.compareFloat(f64, 2, sv2v(lhs), sv2v(rhs), .gt),
        .f64x2_le => ops.compareFloat(f64, 2, sv2v(lhs), sv2v(rhs), .le),
        .f64x2_ge => ops.compareFloat(f64, 2, sv2v(lhs), sv2v(rhs), .ge),
        else => unreachable,
    });
}

/// Dispatches a SIMD shift operation. The shift amount (rhs) is a scalar u32
/// (stored in a RawVal), masked to the lane bit-width by the spec.
pub fn executeShift(opcode: SimdOpcode, lhs: SimdVal, rhs: RawVal) SimdVal {
    const amount = rhs.readAs(u32);
    return v2sv(switch (opcode) {
        .i8x16_shl => ops.shiftInt(i8, 16, sv2v(lhs), amount, .shl),
        .i8x16_shr_s => ops.shiftInt(i8, 16, sv2v(lhs), amount, .shr_s),
        .i8x16_shr_u => ops.shiftInt(u8, 16, sv2v(lhs), amount, .shr_u),
        .i16x8_shl => ops.shiftInt(i16, 8, sv2v(lhs), amount, .shl),
        .i16x8_shr_s => ops.shiftInt(i16, 8, sv2v(lhs), amount, .shr_s),
        .i16x8_shr_u => ops.shiftInt(u16, 8, sv2v(lhs), amount, .shr_u),
        .i32x4_shl => ops.shiftInt(i32, 4, sv2v(lhs), amount, .shl),
        .i32x4_shr_s => ops.shiftInt(i32, 4, sv2v(lhs), amount, .shr_s),
        .i32x4_shr_u => ops.shiftInt(u32, 4, sv2v(lhs), amount, .shr_u),
        .i64x2_shl => ops.shiftInt(i64, 2, sv2v(lhs), amount, .shl),
        .i64x2_shr_s => ops.shiftInt(i64, 2, sv2v(lhs), amount, .shr_s),
        .i64x2_shr_u => ops.shiftInt(u64, 2, sv2v(lhs), amount, .shr_u),
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
pub fn load(opcode: SimdOpcode, memory: []const u8, addr: u32, offset: u32, lane: ?u8, src_vec: ?SimdVal) SimdVal {
    const sv: ?V128 = if (src_vec) |sv| sv.toV128() else null;
    return v2sv(mem_ops.load(opcode, memory, addr, offset, lane, sv));
}

/// Stores a V128 to memory from a SimdVal.
pub fn store(opcode: SimdOpcode, memory: []u8, addr: u32, offset: u32, lane: ?u8, src: SimdVal) void {
    mem_ops.store(opcode, memory, addr, offset, lane, src.toV128());
}

// ── Private helpers ───────────────────────────────────────────────────────────

/// Creates a V128 where all lanes are filled with the same scalar value.
/// `scalar` carries the scalar value in its low 8 bytes (as a RawVal).
fn splatScalar(opcode: SimdOpcode, scalar: RawVal) V128 {
    return switch (classify.shapeOf(opcode).?) {
        .i8x16 => ops.splatGeneric(i8, 16, scalar.readAs(i8)),
        .i16x8 => ops.splatGeneric(i16, 8, scalar.readAs(i16)),
        .i32x4 => ops.splatGeneric(i32, 4, scalar.readAs(i32)),
        .i64x2 => ops.splatGeneric(i64, 2, scalar.readAs(i64)),
        .f32x4 => ops.splatGeneric(f32, 4, scalar.readAs(f32)),
        .f64x2 => ops.splatGeneric(f64, 2, scalar.readAs(f64)),
    };
}

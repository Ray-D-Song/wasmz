// SIMD opcode classification and shape inference.
//
// Provides O(1) switch-based classification of SIMD opcodes into categories
// (unary, binary, ternary, compare, shift, load, store, etc.) and shape
// inference (i8x16, i16x8, i32x4, i64x2, f32x4, f64x2).
//
// All functions here operate purely on the SimdOpcode enum; no vector
// arithmetic or memory access is performed.
const std = @import("std");
const payload = @import("payload");

pub const SimdOpcode = payload.OperatorCode;

/// Lane interpretation shape for a SIMD vector (e.g. 4 lanes of i32).
pub const SimdShape = enum {
    i8x16,
    i16x8,
    i32x4,
    i64x2,
    f32x4,
    f64x2,
};

/// High-level classification of SIMD opcodes used by the compiler pipeline
/// to decide which WasmOp / IR variant to emit.
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

/// IR payload for SIMD load instructions; `lane` is non-null only for
/// v128.loadN_lane variants that merge loaded data into a specific lane.
pub const SimdLoadInfo = struct {
    opcode: SimdOpcode,
    offset: u32,
    lane: ?u8 = null,
};

/// IR payload for SIMD store instructions; `lane` is non-null only for
/// v128.storeN_lane variants that extract a specific lane to memory.
pub const SimdStoreInfo = struct {
    opcode: SimdOpcode,
    offset: u32,
    lane: ?u8 = null,
};

/// Returns true if the opcode falls within the SIMD numeric range (0xFD000..0xFE000).
pub fn isSimdOpcode(opcode: SimdOpcode) bool {
    const value = @intFromEnum(opcode);
    return value >= 0xFD000 and value < 0xFE000;
}

/// Detects relaxed-SIMD opcodes via switch on known relaxed opcodes.
pub fn isRelaxedSimdOpcode(opcode: SimdOpcode) bool {
    return switch (opcode) {
        .i8x16_relaxed_swizzle,
        .i32x4_relaxed_trunc_f32x4_s,
        .i32x4_relaxed_trunc_f32x4_u,
        .i32x4_relaxed_trunc_f64x2_s_zero,
        .i32x4_relaxed_trunc_f64x2_u_zero,
        .f32x4_relaxed_madd,
        .f32x4_relaxed_nmadd,
        .f64x2_relaxed_madd,
        .f64x2_relaxed_nmadd,
        .i8x16_relaxed_laneselect,
        .i16x8_relaxed_laneselect,
        .i32x4_relaxed_laneselect,
        .i64x2_relaxed_laneselect,
        .f32x4_relaxed_min,
        .f32x4_relaxed_max,
        .f64x2_relaxed_min,
        .f64x2_relaxed_max,
        .i16x8_relaxed_q15mulr_s,
        .i16x8_relaxed_dot_i8x16_i7x16_s,
        .i32x4_relaxed_dot_i8x16_i7x16_add_s,
        => true,
        else => false,
    };
}

/// Classifies a SIMD opcode into one of 11 categories so the compiler can
/// emit the appropriate IR node. Uses O(1) switch dispatch.
pub fn classifyOpcode(opcode: SimdOpcode) ?SimdClass {
    if (!isSimdOpcode(opcode)) return null;
    return switch (opcode) {
        // const
        .v128_const => .const_,
        // shuffle
        .i8x16_shuffle => .shuffle,
        // extract_lane
        .i8x16_extract_lane_s,
        .i8x16_extract_lane_u,
        .i16x8_extract_lane_s,
        .i16x8_extract_lane_u,
        .i32x4_extract_lane,
        .i64x2_extract_lane,
        .f32x4_extract_lane,
        .f64x2_extract_lane,
        => .extract_lane,
        // replace_lane
        .i8x16_replace_lane,
        .i16x8_replace_lane,
        .i32x4_replace_lane,
        .i64x2_replace_lane,
        .f32x4_replace_lane,
        .f64x2_replace_lane,
        => .replace_lane,
        // load
        .v128_load,
        .i16x8_load8x8_s,
        .i16x8_load8x8_u,
        .i32x4_load16x4_s,
        .i32x4_load16x4_u,
        .i64x2_load32x2_s,
        .i64x2_load32x2_u,
        .v8x16_load_splat,
        .v16x8_load_splat,
        .v32x4_load_splat,
        .v64x2_load_splat,
        .v128_load32_zero,
        .v128_load64_zero,
        .v128_load8_lane,
        .v128_load16_lane,
        .v128_load32_lane,
        .v128_load64_lane,
        => .load,
        // store
        .v128_store,
        .v128_store8_lane,
        .v128_store16_lane,
        .v128_store32_lane,
        .v128_store64_lane,
        => .store,
        // shift
        .i8x16_shl,
        .i8x16_shr_s,
        .i8x16_shr_u,
        .i16x8_shl,
        .i16x8_shr_s,
        .i16x8_shr_u,
        .i32x4_shl,
        .i32x4_shr_s,
        .i32x4_shr_u,
        .i64x2_shl,
        .i64x2_shr_s,
        .i64x2_shr_u,
        => .shift,
        // compare (integer)
        .i8x16_eq,
        .i8x16_ne,
        .i8x16_lt_s,
        .i8x16_lt_u,
        .i8x16_gt_s,
        .i8x16_gt_u,
        .i8x16_le_s,
        .i8x16_le_u,
        .i8x16_ge_s,
        .i8x16_ge_u,
        .i16x8_eq,
        .i16x8_ne,
        .i16x8_lt_s,
        .i16x8_lt_u,
        .i16x8_gt_s,
        .i16x8_gt_u,
        .i16x8_le_s,
        .i16x8_le_u,
        .i16x8_ge_s,
        .i16x8_ge_u,
        .i32x4_eq,
        .i32x4_ne,
        .i32x4_lt_s,
        .i32x4_lt_u,
        .i32x4_gt_s,
        .i32x4_gt_u,
        .i32x4_le_s,
        .i32x4_le_u,
        .i32x4_ge_s,
        .i32x4_ge_u,
        .i64x2_eq,
        .i64x2_ne,
        .i64x2_lt_s,
        .i64x2_gt_s,
        .i64x2_le_s,
        .i64x2_ge_s,
        // compare (float)
        .f32x4_eq,
        .f32x4_ne,
        .f32x4_lt,
        .f32x4_gt,
        .f32x4_le,
        .f32x4_ge,
        .f64x2_eq,
        .f64x2_ne,
        .f64x2_lt,
        .f64x2_gt,
        .f64x2_le,
        .f64x2_ge,
        => .compare,
        // ternary
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
        => .ternary,
        // unary (splat)
        .i8x16_splat,
        .i16x8_splat,
        .i32x4_splat,
        .i64x2_splat,
        .f32x4_splat,
        .f64x2_splat,
        // unary (bitwise / boolean reduction)
        .v128_not,
        .v128_any_true,
        // unary (integer)
        .i8x16_abs,
        .i8x16_neg,
        .i8x16_popcnt,
        .i8x16_all_true,
        .i8x16_bitmask,
        .i16x8_abs,
        .i16x8_neg,
        .i16x8_all_true,
        .i16x8_bitmask,
        .i32x4_abs,
        .i32x4_neg,
        .i32x4_all_true,
        .i32x4_bitmask,
        .i64x2_abs,
        .i64x2_neg,
        .i64x2_all_true,
        .i64x2_bitmask,
        // unary (float)
        .f32x4_abs,
        .f32x4_neg,
        .f32x4_sqrt,
        .f32x4_ceil,
        .f32x4_floor,
        .f32x4_trunc,
        .f32x4_nearest,
        .f64x2_abs,
        .f64x2_neg,
        .f64x2_sqrt,
        .f64x2_ceil,
        .f64x2_floor,
        .f64x2_trunc,
        .f64x2_nearest,
        // unary (extend pairwise)
        .i16x8_extadd_pairwise_i8x16_s,
        .i16x8_extadd_pairwise_i8x16_u,
        .i32x4_extadd_pairwise_i16x8_s,
        .i32x4_extadd_pairwise_i16x8_u,
        // unary (extend half)
        .i16x8_extend_low_i8x16_s,
        .i16x8_extend_high_i8x16_s,
        .i16x8_extend_low_i8x16_u,
        .i16x8_extend_high_i8x16_u,
        .i32x4_extend_low_i16x8_s,
        .i32x4_extend_high_i16x8_s,
        .i32x4_extend_low_i16x8_u,
        .i32x4_extend_high_i16x8_u,
        .i64x2_extend_low_i32x4_s,
        .i64x2_extend_high_i32x4_s,
        .i64x2_extend_low_i32x4_u,
        .i64x2_extend_high_i32x4_u,
        // unary (conversions)
        .f32x4_demote_f64x2_zero,
        .f64x2_promote_low_f32x4,
        .i32x4_trunc_sat_f32x4_s,
        .i32x4_trunc_sat_f32x4_u,
        .i32x4_trunc_sat_f64x2_s_zero,
        .i32x4_trunc_sat_f64x2_u_zero,
        .f32x4_convert_i32x4_s,
        .f32x4_convert_i32x4_u,
        .f64x2_convert_low_i32x4_s,
        .f64x2_convert_low_i32x4_u,
        // unary (relaxed conversions)
        .i32x4_relaxed_trunc_f32x4_s,
        .i32x4_relaxed_trunc_f32x4_u,
        .i32x4_relaxed_trunc_f64x2_s_zero,
        .i32x4_relaxed_trunc_f64x2_u_zero,
        => .unary,
        // everything else in SIMD range is binary
        else => .binary,
    };
}

/// Infers the SIMD lane shape from the opcode's tag name prefix (e.g. "i32x4_" -> .i32x4).
/// Kept string-based because it would require listing hundreds of opcodes in a switch
/// and follows a consistent naming convention.
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

/// Returns the number of lanes for a given shape (e.g. i8x16 -> 16, f64x2 -> 2).
pub fn laneCount(shape: SimdShape) usize {
    return switch (shape) {
        .i8x16 => 16,
        .i16x8 => 8,
        .i32x4, .f32x4 => 4,
        .i64x2, .f64x2 => 2,
    };
}

/// Returns the byte width of a single lane (e.g. i8x16 -> 1, f64x2 -> 8).
pub fn laneByteWidth(shape: SimdShape) usize {
    return switch (shape) {
        .i8x16 => 1,
        .i16x8 => 2,
        .i32x4, .f32x4 => 4,
        .i64x2, .f64x2 => 8,
    };
}

/// Returns true for v128.loadN_lane opcodes (load a value and insert into one lane).
pub fn isLaneLoadOpcode(opcode: SimdOpcode) bool {
    return switch (opcode) {
        .v128_load8_lane, .v128_load16_lane, .v128_load32_lane, .v128_load64_lane => true,
        else => false,
    };
}

/// Returns true for v128.storeN_lane opcodes (extract one lane and store to memory).
pub fn isLaneStoreOpcode(opcode: SimdOpcode) bool {
    return switch (opcode) {
        .v128_store8_lane, .v128_store16_lane, .v128_store32_lane, .v128_store64_lane => true,
        else => false,
    };
}

/// Returns true if the opcode produces a V128 result (as opposed to an i32 scalar
/// like bitmask/all_true, or void like store).
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

/// Returns the byte width of the memory access for lane load/store opcodes.
pub fn laneImmediateFromOpcode(opcode: SimdOpcode) usize {
    return switch (opcode) {
        .v128_load8_lane, .v128_store8_lane => 1,
        .v128_load16_lane, .v128_store16_lane => 2,
        .v128_load32_lane, .v128_store32_lane => 4,
        .v128_load64_lane, .v128_store64_lane => 8,
        else => unreachable,
    };
}

test "classify representative simd opcodes" {
    try std.testing.expectEqual(SimdClass.const_, classifyOpcode(.v128_const).?);
    try std.testing.expectEqual(SimdClass.load, classifyOpcode(.v128_load).?);
    try std.testing.expectEqual(SimdClass.shift, classifyOpcode(.i16x8_shr_u).?);
    try std.testing.expectEqual(SimdClass.compare, classifyOpcode(.f32x4_ge).?);
    try std.testing.expectEqual(SimdClass.ternary, classifyOpcode(.v128_bitselect).?);
}

// SIMD vector operation helpers.
//
// Pure arithmetic, logic, comparison, and conversion functions that operate
// on V128 values.  None of these functions reference SimdOpcode -- they are
// parameterised by lane type T and lane count N, and by comptime-enum
// selectors for the operation kind.
//
// The public surface is consumed exclusively by exec.zig (the dispatcher).
const std = @import("std");
const builtin = @import("builtin");
const helper = @import("../value/helper.zig");
const vec = @import("../value/vec.zig");

pub const V128 = vec.V128;

/// Shorthand for Zig's fixed-size SIMD vector type.
fn Vector(comptime T: type, comptime N: usize) type {
    return @Vector(N, T);
}

/// Maps a lane type to its unsigned integer counterpart with the same bit width.
/// Used as the "raw bits" type for endian-aware reinterpretation.
fn UnsignedLane(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .int => std.meta.Int(.unsigned, @bitSizeOf(T)),
        .float => std.meta.Int(.unsigned, @bitSizeOf(T)),
        else => @compileError("unsupported lane type"),
    };
}

/// Interprets V128 bytes as an N-element @Vector(N, T).
/// On big-endian targets, byte-swaps each lane so that the wasm little-endian
/// byte order is preserved.
pub fn vecFromV128(comptime T: type, comptime N: usize, value: V128) Vector(T, N) {
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

/// Packs an N-element @Vector(N, T) back into V128 bytes.
/// Performs byte-swap on big-endian targets to maintain little-endian storage.
pub fn v128FromVec(comptime T: type, comptime N: usize, lanes: Vector(T, N)) V128 {
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

/// Converts a boolean mask vector into V128 where true lanes are all-ones
/// and false lanes are all-zeros (wasm comparison result format).
pub fn vectorMaskToV128(comptime T: type, comptime N: usize, mask: @Vector(N, bool)) V128 {
    const U = UnsignedLane(T);
    const ones: @Vector(N, U) = @splat(std.math.maxInt(U));
    const zeros: @Vector(N, U) = @splat(0);
    return v128FromVec(U, N, @select(U, mask, ones, zeros));
}

pub fn v128FromBytes(bytes: [16]u8) V128 {
    return .{ .bytes = bytes };
}

pub fn bytesFromV128(value: V128) [16]u8 {
    return value.bytes;
}

/// Reads a single typed lane from the raw byte array (little-endian).
pub fn readLane(comptime T: type, bytes: [16]u8, lane: u8) T {
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

/// Writes a single typed lane into the raw byte array (little-endian).
pub fn writeLane(comptime T: type, bytes: *[16]u8, lane: u8, value: T) void {
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

/// Applies a scalar byte->byte function to every byte of a V128 (used for v128.not).
pub fn mapBytesUnary(value: V128, comptime func: fn (u8) u8) V128 {
    const lanes: @Vector(16, u8) = @bitCast(value.bytes);
    var out: @Vector(16, u8) = undefined;
    inline for (0..16) |i| out[i] = func(lanes[i]);
    return v128FromBytes(@bitCast(out));
}

/// Byte-level bitwise binary operations (and, andnot, or, xor).
/// Operates on the raw 16-byte representation without lane interpretation.
pub fn bytesBinary(lhs: V128, rhs: V128, comptime kind: enum { @"and", andnot, @"or", xor }) V128 {
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

/// v128.any_true: returns true if any byte in the vector is non-zero.
pub fn anyTrue(value: V128) bool {
    const lanes: @Vector(16, u8) = @bitCast(value.bytes);
    return @reduce(.Or, lanes != @as(@Vector(16, u8), @splat(0)));
}

/// Returns true if all lanes are non-zero (iNxM.all_true).
pub fn allTrue(comptime T: type, comptime N: usize, value: V128) bool {
    const lanes = vecFromV128(T, N, value);
    const zero: Vector(T, N) = @splat(0);
    return @reduce(.And, lanes != zero);
}

/// v128.bitselect: per-bit mux -- result = (first & mask) | (second & ~mask).
pub fn bitselect(first: V128, second: V128, mask: V128) V128 {
    const a: @Vector(16, u8) = @bitCast(first.bytes);
    const b: @Vector(16, u8) = @bitCast(second.bytes);
    const m: @Vector(16, u8) = @bitCast(mask.bytes);
    return v128FromBytes(@bitCast((a & m) | (b & ~m)));
}

/// Creates a V128 where all lanes are filled with the same scalar value.
pub fn splatGeneric(comptime T: type, comptime N: usize, value: T) V128 {
    return v128FromVec(T, N, @as(Vector(T, N), @splat(value)));
}

/// Extracts the sign bit of each lane into a scalar bitmask (iNxM.bitmask).
/// Uses @Vector comparison for hardware SIMD acceleration.
pub fn bitmask(comptime T: type, comptime N: usize, value: V128) i32 {
    const lanes = vecFromV128(T, N, value);
    const zero: Vector(T, N) = @splat(0);
    // lanes < zero produces a bool vector where true = sign bit set
    const sign_bits: @Vector(N, u1) = @bitCast(lanes < zero);
    // Pack the u1 vector into a small unsigned integer
    const MaskInt = std.meta.Int(.unsigned, N);
    const mask_uint: MaskInt = @bitCast(sign_bits);
    return @as(i32, @intCast(mask_uint));
}

/// Integer unary operations: abs (wrapping) and neg (wrapping).
/// Uses @Vector arithmetic for hardware SIMD acceleration.
pub fn unaryInt(comptime T: type, comptime N: usize, value: V128, comptime kind: enum { abs, neg }) V128 {
    const lanes = vecFromV128(T, N, value);
    const zero: Vector(T, N) = @splat(0);
    const results: Vector(T, N) = switch (kind) {
        .neg => zero -% lanes,
        .abs => @select(T, lanes < zero, zero -% lanes, lanes),
    };
    return v128FromVec(T, N, results);
}

/// i8x16.popcnt: population count per byte lane.
pub fn unaryI8Popcnt(value: V128) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..16) |i| {
        const lane = readLane(u8, value.bytes, @intCast(i));
        writeLane(i8, &out, @intCast(i), @as(i8, @bitCast(@as(u8, @intCast(@popCount(lane))))));
    }
    return v128FromBytes(out);
}

/// Float unary operations: abs, neg, sqrt, ceil, floor, trunc, nearest.
/// Uses @Vector builtins for all except `nearest`, which requires scalar
/// fallback for the "round ties to even" semantics that @round doesn't provide.
pub fn unaryFloat(comptime T: type, comptime N: usize, value: V128, comptime kind: enum { abs, neg, ceil, floor, trunc, nearest, sqrt }) V128 {
    const lanes = vecFromV128(T, N, value);
    return switch (kind) {
        .abs => v128FromVec(T, N, @abs(lanes)),
        .neg => v128FromVec(T, N, -lanes),
        .sqrt => v128FromVec(T, N, @sqrt(lanes)),
        .ceil => v128FromVec(T, N, @ceil(lanes)),
        .floor => v128FromVec(T, N, @floor(lanes)),
        .trunc => v128FromVec(T, N, @trunc(lanes)),
        .nearest => blk: {
            // Scalar fallback: helper.nearest implements round-ties-to-even.
            var out = std.mem.zeroes([16]u8);
            inline for (0..N) |i| {
                const lane = readLane(T, value.bytes, @intCast(i));
                writeLane(T, &out, @intCast(i), helper.nearest(lane));
            }
            break :blk v128FromBytes(out);
        },
    };
}

/// Integer binary operations. Simple ops (add, sub, mul, min, max) and
/// saturating ops (add_sat, sub_sat) use @Vector directly. avgr_u uses
/// the vectorised identity: avgr(a,b) = (a | b) - ((a ^ b) >> 1).
pub fn binaryInt(comptime T: type, comptime N: usize, lhs: V128, rhs: V128, comptime kind: enum { add, add_sat, sub, sub_sat, mul, min, max, avgr_u }) V128 {
    const a = vecFromV128(T, N, lhs);
    const b = vecFromV128(T, N, rhs);
    return switch (kind) {
        .add => v128FromVec(T, N, a +% b),
        .sub => v128FromVec(T, N, a -% b),
        .mul => v128FromVec(T, N, a *% b),
        .min => v128FromVec(T, N, @select(T, a < b, a, b)),
        .max => v128FromVec(T, N, @select(T, a > b, a, b)),
        // Fix 5: saturating arithmetic using Zig's +| / -| operators on @Vector
        .add_sat => v128FromVec(T, N, a +| b),
        .sub_sat => v128FromVec(T, N, a -| b),
        // Fix 5: vectorised avgr_u using identity: avgr(a,b) = (a | b) - ((a ^ b) >> 1)
        .avgr_u => blk: {
            const ShiftT = std.math.Log2Int(T);
            const shifts: @Vector(N, ShiftT) = @splat(1);
            break :blk v128FromVec(T, N, (a | b) - ((a ^ b) >> shifts));
        },
    };
}

/// i16x8.q15mulr_sat_s: fixed-point Q15 multiplication with rounding and saturation.
/// Computes (a * b + 0x4000) >> 15, clamped to i16 range.
pub fn q15mulr(lhs: V128, rhs: V128) V128 {
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

/// Float binary operations. add/sub/mul/div use @Vector directly.
/// min/max use scalar helper (special NaN/signed-zero semantics).
/// pmin/pmax use @Vector comparison with @select (correct IEEE NaN propagation).
pub fn binaryFloat(comptime T: type, comptime N: usize, lhs: V128, rhs: V128, comptime kind: enum { add, sub, mul, div, min, max, pmin, pmax }) V128 {
    const a = vecFromV128(T, N, lhs);
    const b = vecFromV128(T, N, rhs);
    return switch (kind) {
        .add => v128FromVec(T, N, a + b),
        .sub => v128FromVec(T, N, a - b),
        .mul => v128FromVec(T, N, a * b),
        .div => v128FromVec(T, N, a / b),
        // Fix 1: pmin(a,b) = if (b < a) b else a  (IEEE: NaN < x is always false)
        .pmin => v128FromVec(T, N, @select(T, b < a, b, a)),
        // Fix 1: pmax(a,b) = if (a < b) b else a  (IEEE: x < NaN is always false)
        .pmax => v128FromVec(T, N, @select(T, a < b, b, a)),
        // min/max have special NaN propagation and signed-zero semantics;
        // must use scalar helper.
        .min, .max => blk: {
            var out = std.mem.zeroes([16]u8);
            inline for (0..N) |i| {
                const lane_a = readLane(T, lhs.bytes, @intCast(i));
                const lane_b = readLane(T, rhs.bytes, @intCast(i));
                const result: T = if (kind == .min) helper.min(lane_a, lane_b) else helper.max(lane_a, lane_b);
                writeLane(T, &out, @intCast(i), result);
            }
            break :blk v128FromBytes(out);
        },
    };
}

/// Integer lane-wise comparison. Returns V128 with all-1s / all-0s per lane.
pub fn compareInt(comptime T: type, comptime N: usize, lhs: V128, rhs: V128, comptime kind: enum { eq, ne, lt, gt, le, ge }) V128 {
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

/// Float lane-wise comparison. NaN comparisons follow IEEE 754: NaN != NaN, etc.
pub fn compareFloat(comptime T: type, comptime N: usize, lhs: V128, rhs: V128, comptime kind: enum { eq, ne, lt, gt, le, ge }) V128 {
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

/// Integer shift operations. The shift amount is masked to lane bit-width by the spec.
/// Uses @Vector shift operators for hardware SIMD.
pub fn shiftInt(comptime T: type, comptime N: usize, value: V128, amount: u32, comptime kind: enum { shl, shr_s, shr_u }) V128 {
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

/// i8x16.swizzle: rearranges bytes of lhs using indices from rhs.
/// Out-of-range indices (>= 16) produce 0.
pub fn swizzle(lhs: V128, rhs: V128) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..16) |i| {
        const idx = readLane(u8, rhs.bytes, @intCast(i));
        out[i] = if (idx < 16) lhs.bytes[idx] else 0;
    }
    return v128FromBytes(out);
}

/// i8x16.shuffle: selects bytes from the concatenation of lhs||rhs (indices 0..31).
pub fn shuffleBytes(lhs: V128, rhs: V128, lanes_arr: [16]u8) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..16) |i| {
        const idx = lanes_arr[i];
        out[i] = if (idx < 16) lhs.bytes[idx] else rhs.bytes[idx - 16];
    }
    return v128FromBytes(out);
}

/// Pairwise addition with widening: adds adjacent pairs of narrow lanes into
/// wider result lanes (e.g. i16x8.extadd_pairwise_i8x16_s).
pub fn extaddPairwise(comptime SrcT: type, comptime DstT: type, comptime N: usize, value: V128) V128 {
    const signed = @typeInfo(SrcT).int.signedness == .signed;
    // Wider type that holds pairs as DstT lanes
    const PairT = std.meta.Int(if (signed) .signed else .unsigned, @bitSizeOf(DstT));
    const PairVec = @Vector(N, PairT);

    // Read the vector as N lanes of the wider (pair) type.
    // Each pair lane contains two adjacent SrcT values packed together.
    const pairs = vecFromV128(PairT, N, value);

    // Extract low and high halves of each pair via shift/mask.
    const bits = @bitSizeOf(SrcT);
    const shift_amt: @Vector(N, std.math.Log2Int(PairT)) = @splat(bits);

    if (signed) {
        // Sign-extend low byte: (pairs << bits) >> bits
        const low: PairVec = (pairs << shift_amt) >> shift_amt;
        // High byte: arithmetic shift right
        const high: PairVec = pairs >> shift_amt;
        return v128FromVec(PairT, N, low + high);
    } else {
        // Unsigned: mask low, shift high
        const mask_val: PairT = (@as(PairT, 1) << @intCast(bits)) - 1;
        const mask: PairVec = @splat(mask_val);
        const low: PairVec = pairs & mask;
        const high: PairVec = pairs >> shift_amt;
        return v128FromVec(PairT, N, low + high);
    }
}

/// Widen the low or high half of narrow lanes into wider lanes
/// (e.g. i32x4.extend_low_i16x8_s).
pub fn extendHalf(comptime SrcT: type, comptime DstT: type, value: V128, comptime which: enum { low, high }) V128 {
    const signed = @typeInfo(SrcT).int.signedness == .signed;
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

/// Narrows wide lanes into half-width lanes with saturation, concatenating
/// lhs (-> low half) and rhs (-> high half) results.
pub fn narrow(comptime SrcT: type, comptime DstT: type, comptime HalfN: usize, lhs: V128, rhs: V128) V128 {
    const signed = @typeInfo(SrcT).int.signedness == .signed;
    var out = std.mem.zeroes([16]u8);
    inline for (0..HalfN) |i| {
        writeLane(DstT, &out, @intCast(i), narrowLane(SrcT, DstT, readLane(SrcT, lhs.bytes, @intCast(i)), signed));
        writeLane(DstT, &out, @intCast(HalfN + i), narrowLane(SrcT, DstT, readLane(SrcT, rhs.bytes, @intCast(i)), signed));
    }
    return v128FromBytes(out);
}

/// Extended (widening) multiplication: multiplies the low or high half of
/// narrow source lanes, producing wider result lanes.
pub fn extmul(comptime SrcT: type, comptime DstT: type, lhs: V128, rhs: V128, comptime which: enum { low, high }) V128 {
    const signed = @typeInfo(SrcT).int.signedness == .signed;
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

/// f32x4.demote_f64x2_zero: demotes two f64 lanes to f32, zero-fills lanes 2-3.
pub fn demoteF64x2Zero(value: V128) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..2) |i| writeLane(f32, &out, @intCast(i), @floatCast(readLane(f64, value.bytes, @intCast(i))));
    return v128FromBytes(out);
}

/// f64x2.promote_low_f32x4: promotes the two low f32 lanes to f64.
pub fn promoteLowF32x4(value: V128) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..2) |i| writeLane(f64, &out, @intCast(i), @floatCast(readLane(f32, value.bytes, @intCast(i))));
    return v128FromBytes(out);
}

pub fn truncSatF32x4ToI32x4(value: V128, comptime signed: bool) V128 {
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

pub fn truncSatF64x2ToI32x4Zero(value: V128, comptime signed: bool) V128 {
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

pub fn convertI32x4ToF32x4(value: V128, comptime signed: bool) V128 {
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

pub fn convertLowI32x4ToF64x2(value: V128, comptime signed: bool) V128 {
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

/// i32x4.dot_i16x8_s: signed dot product of i16 pairs, accumulated into i32 lanes.
pub fn dotI16x8ToI32x4(lhs: V128, rhs: V128) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..4) |i| {
        const idx = i * 2;
        const sum = @as(i32, readLane(i16, lhs.bytes, @intCast(idx))) * @as(i32, readLane(i16, rhs.bytes, @intCast(idx))) +
            @as(i32, readLane(i16, lhs.bytes, @intCast(idx + 1))) * @as(i32, readLane(i16, rhs.bytes, @intCast(idx + 1)));
        writeLane(i32, &out, @intCast(i), sum);
    }
    return v128FromBytes(out);
}

/// Relaxed i16x8 dot product of i8 pairs (relaxed_dot_i8x16_i7x16_s).
pub fn relaxedDotI8x16ToI16x8(lhs: V128, rhs: V128) V128 {
    var out = std.mem.zeroes([16]u8);
    inline for (0..8) |i| {
        const idx = i * 2;
        const sum = @as(i16, readLane(i8, lhs.bytes, @intCast(idx))) * @as(i16, readLane(i8, rhs.bytes, @intCast(idx))) +
            @as(i16, readLane(i8, lhs.bytes, @intCast(idx + 1))) * @as(i16, readLane(i8, rhs.bytes, @intCast(idx + 1)));
        writeLane(i16, &out, @intCast(i), sum);
    }
    return v128FromBytes(out);
}

/// Relaxed i32x4 dot-product-accumulate: dot(i8, i8) -> i16, pairwise add -> i32, + acc.
pub fn relaxedDotAddI8x16ToI32x4(first: V128, second: V128, acc: V128) V128 {
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

/// Fused multiply-add / negative-multiply-add for float vectors.
/// Uses Zig's @mulAdd which maps to hardware FMA where available.
pub fn floatMulAddVec(comptime T: type, comptime N: usize, first: V128, second: V128, third: V128, comptime negate_first: bool) V128 {
    var a = vecFromV128(T, N, first);
    const b = vecFromV128(T, N, second);
    const c = vecFromV128(T, N, third);
    if (negate_first) a = -a;
    return v128FromVec(T, N, @mulAdd(Vector(T, N), a, b, c));
}

/// Clamps a wide value to the signed range of T.
pub fn clampSigned(comptime T: type, value: anytype) T {
    if (value > std.math.maxInt(T)) return std.math.maxInt(T);
    if (value < std.math.minInt(T)) return std.math.minInt(T);
    return @as(T, @intCast(value));
}

/// Narrows a single lane value with saturation (signed or unsigned clamping).
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

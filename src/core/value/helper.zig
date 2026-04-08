const std = @import("std");

pub const TruncateError = error{
    NaN,
    OutOfRange,
};

// Tries to truncate a floating-point value into an integer of type T (i32 or i64).
// Returns the truncated integer if successful,
// or an error if the value is NaN or out of range.
pub fn tryTruncateInto(comptime T: type, value: anytype) TruncateError!T {
    const Src = @TypeOf(value);

    comptime {
        if (Src != f32 and Src != f64) {
            @compileError("tryTruncateInto only supports f32/f64");
        }
    }

    if (std.math.isNan(value)) {
        return TruncateError.NaN;
    }

    const truncated = @trunc(value);

    // Use float-cast boundaries to avoid precision loss when comparing:
    // e.g. maxInt(i32)=2147483647 rounds up to 2147483648.0 in f32,
    // so `truncated > maxInt(T)` would miss 2147483648.0 itself.
    const float_min: Src = @floatFromInt(std.math.minInt(T));
    const float_max: Src = @floatFromInt(@as(i128, std.math.maxInt(T)) + 1);
    if (truncated < float_min or truncated >= float_max) {
        return TruncateError.OutOfRange;
    }

    return @intFromFloat(truncated);
}

// Similar to tryTruncateInto,
// but instead of returning an error on out-of-range values,
// it saturates to the min/max integer value.
pub fn truncateSaturateInto(comptime T: type, value: anytype) T {
    const Src = @TypeOf(value);

    comptime {
        if (Src != f32 and Src != f64) {
            @compileError("truncateSaturateInto only supports f32/f64");
        }
    }

    if (std.math.isNan(value)) {
        return 0;
    }

    const truncated = @trunc(value);

    const float_min: Src = @floatFromInt(std.math.minInt(T));
    const float_max: Src = @floatFromInt(@as(i128, std.math.maxInt(T)) + 1);
    if (truncated < float_min) {
        return std.math.minInt(T);
    } else if (truncated >= float_max) {
        return std.math.maxInt(T);
    } else {
        return @intFromFloat(truncated);
    }
}

// Sign-extends `value` from `From` back into the type of `value`.
pub fn signExtendFrom(comptime From: type, value: anytype) @TypeOf(value) {
    const To = @TypeOf(value);

    comptime {
        const from_info = @typeInfo(From);
        const to_info = @typeInfo(To);

        if (from_info != .int or from_info.int.signedness != .signed) {
            @compileError("From must be a signed integer type");
        }
        if (to_info != .int or to_info.int.signedness != .signed) {
            @compileError("value must be a signed integer type");
        }
        if (@bitSizeOf(From) > @bitSizeOf(To)) {
            @compileError("From must not be wider than value's type");
        }
    }

    const ToUnsigned = std.meta.Int(.unsigned, @bitSizeOf(To));
    const FromUnsigned = std.meta.Int(.unsigned, @bitSizeOf(From));

    const raw: ToUnsigned = @bitCast(value);
    const narrowed_bits: FromUnsigned = @truncate(raw);
    const narrowed: From = @bitCast(narrowed_bits);

    return @as(To, narrowed);
}

fn UnsignedOf(comptime T: type) type {
    const info = @typeInfo(T).int;
    return std.meta.Int(.unsigned, info.bits);
}

fn ensureSignedInt(comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .int or info.int.signedness != .signed) {
        @compileError("expected signed integer type");
    }
}

fn ensureInt(comptime T: type) void {
    if (@typeInfo(T) != .int) {
        @compileError("expected integer type");
    }
}

fn ensureFloat(comptime T: type) void {
    if (@typeInfo(T) != .float) {
        @compileError("expected float type");
    }
}

// Returns `true` if `value` is zero.
pub fn isZero(value: anytype) bool {
    const T = @TypeOf(value);
    comptime ensureSignedInt(T);
    return value == 0;
}

// Counts leading zero bits in the binary representation of `value`.
pub fn leadingZeros(value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    comptime ensureSignedInt(T);
    return @as(T, @intCast(@clz(@as(UnsignedOf(T), @bitCast(value)))));
}

// Counts trailing zero bits in the binary representation of `value`.
pub fn trailingZeros(value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    comptime ensureSignedInt(T);
    return @as(T, @intCast(@ctz(@as(UnsignedOf(T), @bitCast(value)))));
}

// Counts the number of one bits in the binary representation of `value`.
pub fn countOnes(value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    comptime ensureSignedInt(T);
    return @as(T, @intCast(@popCount(@as(UnsignedOf(T), @bitCast(value)))));
}

// Shifts `lhs` to the left by the wrapped shift amount in `rhs`.
pub fn shl(lhs: anytype, rhs: @TypeOf(lhs)) @TypeOf(lhs) {
    const T = @TypeOf(lhs);
    comptime ensureSignedInt(T);
    const amount: std.math.Log2Int(T) = @truncate(@as(UnsignedOf(T), @bitCast(rhs)));
    return lhs << amount;
}

// Performs an arithmetic right shift on `lhs` by the wrapped shift amount in `rhs`.
pub fn shrS(lhs: anytype, rhs: @TypeOf(lhs)) @TypeOf(lhs) {
    const T = @TypeOf(lhs);
    comptime ensureSignedInt(T);
    const amount: std.math.Log2Int(T) = @truncate(@as(UnsignedOf(T), @bitCast(rhs)));
    return lhs >> amount;
}

// Performs a logical right shift on `lhs` by the wrapped shift amount in `rhs`.
pub fn shrU(comptime T: type, lhs: UnsignedOf(T), rhs: UnsignedOf(T)) UnsignedOf(T) {
    comptime ensureSignedInt(T);
    const amount: std.math.Log2Int(UnsignedOf(T)) = @truncate(rhs);
    return lhs >> amount;
}

// Rotates the bits of `lhs` to the left by the wrapped shift amount in `rhs`.
pub fn rotl(lhs: anytype, rhs: @TypeOf(lhs)) @TypeOf(lhs) {
    const T = @TypeOf(lhs);
    comptime ensureSignedInt(T);
    const U = UnsignedOf(T);
    const amount: std.math.Log2Int(U) = @truncate(@as(U, @bitCast(rhs)));
    return @bitCast(std.math.rotl(U, @as(U, @bitCast(lhs)), amount));
}

// Rotates the bits of `lhs` to the right by the wrapped shift amount in `rhs`.
pub fn rotr(lhs: anytype, rhs: @TypeOf(lhs)) @TypeOf(lhs) {
    const T = @TypeOf(lhs);
    comptime ensureSignedInt(T);
    const U = UnsignedOf(T);
    const amount: std.math.Log2Int(U) = @truncate(@as(U, @bitCast(rhs)));
    return @bitCast(std.math.rotr(U, @as(U, @bitCast(lhs)), amount));
}

pub const IntDivError = error{
    IntegerDivisionByZero,
    IntegerOverflow,
};

// Divides `lhs` by `rhs` using signed integer semantics.
pub fn divS(lhs: anytype, rhs: @TypeOf(lhs)) IntDivError!@TypeOf(lhs) {
    const T = @TypeOf(lhs);
    comptime ensureSignedInt(T);
    if (rhs == 0) {
        return error.IntegerDivisionByZero;
    }
    if (lhs == std.math.minInt(T) and rhs == -1) {
        return error.IntegerOverflow;
    }
    return @divTrunc(lhs, rhs);
}

// Divides `lhs` by `rhs` using unsigned integer semantics.
pub fn divU(comptime T: type, lhs: UnsignedOf(T), rhs: UnsignedOf(T)) error{IntegerDivisionByZero}!UnsignedOf(T) {
    comptime ensureSignedInt(T);
    if (rhs == 0) {
        return error.IntegerDivisionByZero;
    }
    return @divTrunc(lhs, rhs);
}

// Computes the signed integer remainder of `lhs` divided by `rhs`.
pub fn remS(lhs: anytype, rhs: @TypeOf(lhs)) error{IntegerDivisionByZero}!@TypeOf(lhs) {
    const T = @TypeOf(lhs);
    comptime ensureSignedInt(T);
    if (rhs == 0) {
        return error.IntegerDivisionByZero;
    }
    // Wasm spec: rem_s(INT_MIN, -1) == 0 (no trap, unlike div_s)
    if (lhs == std.math.minInt(T) and rhs == -1) return @as(T, 0);
    return @rem(lhs, rhs);
}

// Computes the unsigned integer remainder of `lhs` divided by `rhs`.
pub fn remU(comptime T: type, lhs: UnsignedOf(T), rhs: UnsignedOf(T)) error{IntegerDivisionByZero}!UnsignedOf(T) {
    comptime ensureSignedInt(T);
    if (rhs == 0) {
        return error.IntegerDivisionByZero;
    }
    return @rem(lhs, rhs);
}

// Returns the absolute value of `value`.
pub fn abs(value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    comptime ensureFloat(T);
    return @abs(value);
}

// Returns the greatest integer less than or equal to `value`.
pub fn floor(value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    comptime ensureFloat(T);
    return @floor(value);
}

// Returns the smallest integer greater than or equal to `value`.
pub fn ceil(value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    comptime ensureFloat(T);
    return @ceil(value);
}

// Returns the integer part of `value` by truncating towards zero.
pub fn trunc(value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    comptime ensureFloat(T);
    return @trunc(value);
}

// Returns the nearest integer to `value` with ties rounded to even.
pub fn nearest(value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    comptime ensureFloat(T);
    const rounded = @round(value);
    if (@abs(value - @trunc(value)) != 0.5) {
        return rounded;
    }
    const rem = @mod(rounded, @as(T, 2.0));
    if (rem == 1.0) {
        return @floor(value);
    } else if (rem == -1.0) {
        return @ceil(value);
    } else {
        return rounded;
    }
}

// Returns the square root of `value`.
pub fn sqrt(value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    comptime ensureFloat(T);
    return @sqrt(value);
}

// Returns the minimum of `lhs` and `rhs` using Wasm min semantics.
pub fn min(lhs: anytype, rhs: @TypeOf(lhs)) @TypeOf(lhs) {
    const T = @TypeOf(lhs);
    comptime ensureFloat(T);
    if (lhs < rhs) {
        return lhs;
    } else if (rhs < lhs) {
        return rhs;
    } else if (lhs == rhs) {
        if (std.math.signbit(lhs) and !std.math.signbit(rhs)) {
            return lhs;
        }
        return rhs;
    } else {
        return lhs + rhs;
    }
}

// Returns the maximum of `lhs` and `rhs` using Wasm max semantics.
pub fn max(lhs: anytype, rhs: @TypeOf(lhs)) @TypeOf(lhs) {
    const T = @TypeOf(lhs);
    comptime ensureFloat(T);
    if (lhs > rhs) {
        return lhs;
    } else if (rhs > lhs) {
        return rhs;
    } else if (lhs == rhs) {
        if (!std.math.signbit(lhs) and std.math.signbit(rhs)) {
            return lhs;
        }
        return rhs;
    } else {
        return lhs + rhs;
    }
}

// Returns `lhs` with the sign bit copied from `rhs`.
pub fn copySign(lhs: anytype, rhs: @TypeOf(lhs)) @TypeOf(lhs) {
    const T = @TypeOf(lhs);
    comptime ensureFloat(T);
    return std.math.copysign(lhs, rhs);
}

// Float only function
pub fn floatMulAdd(lhs: anytype, mid: @TypeOf(lhs), rhs: @TypeOf(lhs)) @TypeOf(lhs) {
    const T = @TypeOf(lhs);
    comptime ensureFloat(T);
    return @mulAdd(T, lhs, mid, rhs);
}

test "wasm_float_min_regression" {
    try std.testing.expectEqual(@as(u32, 0x8000_0000), @as(u32, @bitCast(min(@as(f32, -0.0), @as(f32, 0.0)))));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), @as(u32, @bitCast(min(@as(f32, 0.0), @as(f32, -0.0)))));
}

test "wasm_float_max_regression" {
    try std.testing.expectEqual(@as(u32, 0x0000_0000), @as(u32, @bitCast(max(@as(f32, -0.0), @as(f32, 0.0)))));
    try std.testing.expectEqual(@as(u32, 0x0000_0000), @as(u32, @bitCast(max(@as(f32, 0.0), @as(f32, -0.0)))));
}

test "copysign_regression" {
    const nan_neg: f32 = @bitCast(@as(u32, 0xFFC00000));
    try std.testing.expect(std.math.isNan(nan_neg));
    try std.testing.expectEqual(@as(u32, 0x7FC00000), @as(u32, @bitCast(copySign(nan_neg, @as(f32, 0.0)))));
}

test "try_truncate_into_f32_i32_boundary" {
    // 2^31 as f32 must overflow i32
    try std.testing.expectError(error.OutOfRange, tryTruncateInto(i32, @as(f32, 2147483648.0)));
    // Largest representable f32 that truncates within i32 range (2^31 - 128)
    try std.testing.expectEqual(@as(i32, 2147483520), try tryTruncateInto(i32, @as(f32, 2147483520.0)));
    // NaN must error
    try std.testing.expectError(error.NaN, tryTruncateInto(i32, std.math.nan(f32)));
    // -1.0 must overflow u32
    try std.testing.expectError(error.OutOfRange, tryTruncateInto(u32, @as(f32, -1.0)));
    // +inf must overflow
    try std.testing.expectError(error.OutOfRange, tryTruncateInto(i32, std.math.inf(f32)));
}

test "float_mul_add" {
    try std.testing.expectEqual(@as(f32, 10.0), floatMulAdd(@as(f32, 2.0), @as(f32, 3.0), @as(f32, 4.0)));
    try std.testing.expectEqual(@as(f64, 10.0), floatMulAdd(@as(f64, 2.0), @as(f64, 3.0), @as(f64, 4.0)));
}

const std = @import("std");

// A wrapper around floating-point values that provides bitwise equality and formatting.
// Because Wasm's floating-point semantics are based on the raw bits, not the value,
// this is used to represent `f32` and `f64` values in Wasm.
fn FloatWrapper(comptime Prim: type, comptime Bits: type) type {
    return struct {
        bits: Bits,

        const Self = @This();

        pub fn fromBits(bits: Bits) Self {
            return .{ .bits = bits };
        }

        pub fn toBits(self: Self) Bits {
            return self.bits;
        }

        pub fn fromFloat(value: Prim) Self {
            return .{ .bits = @bitCast(value) };
        }

        pub fn toFloat(self: Self) Prim {
            return @as(Prim, @bitCast(self.bits));
        }

        // Compare by bare floating-point semantics, not bits
        pub fn eql(self: Self, other: Self) bool {
            return self.toFloat() == other.toFloat();
        }

        // Return null when encountering NaN.
        pub fn partialCmp(self: Self, other: Self) ?std.math.Order {
            const lhs = self.toFloat();
            const rhs = other.toFloat();
            if (std.math.isNan(lhs) or std.math.isNan(rhs)) return null;
            return std.math.order(lhs, rhs);
        }

        // Print bits when NaN.
        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            const value = self.toFloat();
            if (std.math.isNan(value)) {
                try writer.print("nan:0x{X}", .{self.toBits()});
                return;
            }
            try writer.print("{}", .{value});
        }
    };
}

pub const F32 = FloatWrapper(f32, u32);
pub const F64 = FloatWrapper(f64, u64);

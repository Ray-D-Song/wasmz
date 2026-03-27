const std = @import("std");

// The Wasm `simd` proposal's `v128` type.
pub const V128 = extern struct {
    bytes: [16]u8,

    // Creates a `V128` from a `u128`.
    pub fn fromU128(value: u128) V128 {
        const le_value = std.mem.nativeToLittle(u128, value);
        return .{
            .bytes = @bitCast(le_value),
        };
    }

    // Returns `self` as a `u128`.
    pub fn asU128(self: V128) u128 {
        const le_value: u128 = @bitCast(self.bytes);
        return std.mem.littleToNative(u128, le_value);
    }
};

// The Wasm `simd` proposal's `v128` type.
pub const V128 = extern struct {
    bytes: [16]u8,

    // Creates a `V128` from a `u128` (Zig 0.17 `@bitCast` maps LSB to byte 0).
    pub fn fromU128(value: u128) V128 {
        return .{ .bytes = @bitCast(value) };
    }

    // Returns `self` as a `u128`.
    pub fn asU128(self: V128) u128 {
        return @bitCast(self.bytes);
    }
};

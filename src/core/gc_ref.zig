const std = @import("std");

/// GcRef is the runtime representation of a WASM GC reference value.
///
/// Encoding scheme (u32):
/// - 0x00000000: Null reference (null_value sentinel)
/// - 0xNNNNNNN1: i31 (small integer), bit 0 = 1 as discriminator
/// - 0xNNNNNNN0: Heap object index, bit 0 = 0 (even value, non-zero)
///
/// Advantages over raw pointers (u64):
/// - More compact (32-bit index vs 64-bit pointer)
/// - GC can move objects without updating references
/// - Safer: no exposed memory addresses
pub const GcRef = enum(u32) {
    Null = 0,
    _,

    const Self = @This();

    /// Sentinel value for null references.
    pub const null_value: Self = @enumFromInt(0);

    /// Encodes an i31 (31-bit small integer) into a GcRef.
    /// Encoding: (value << 1) | 1
    /// No heap allocation needed - value is stored inline.
    pub fn fromI31(value: i31) Self {
        const extended: i32 = value;
        const encoded = (@as(u32, @bitCast(extended)) << 1) | 1;
        return @enumFromInt(encoded);
    }

    /// Creates a GcRef from a heap object index.
    /// The index must be even (bit 0 = 0) and non-zero.
    pub fn fromHeapIndex(index: u32) Self {
        std.debug.assert(index & 1 == 0);
        std.debug.assert(index != 0);
        return @enumFromInt(index);
    }

    /// Returns true if this is a null reference.
    pub fn isNull(self: Self) bool {
        return @intFromEnum(self) == 0;
    }

    /// Returns true if this is an i31 (small integer).
    /// Discriminated by bit 0 = 1.
    pub fn isI31(self: Self) bool {
        const bits = @intFromEnum(self);
        return bits != 0 and (bits & 1) == 1;
    }

    /// Returns true if this is a heap object reference.
    /// Discriminated by bit 0 = 0 and non-zero.
    pub fn isHeapRef(self: Self) bool {
        const bits = @intFromEnum(self);
        return bits != 0 and (bits & 1) == 0;
    }

    /// Decodes and returns the i31 value, or null if not an i31.
    pub fn asI31(self: Self) ?i31 {
        if (!self.isI31()) return null;
        const bits = @intFromEnum(self);
        const shifted = @as(i32, @bitCast(bits >> 1));
        return @as(i31, @truncate(shifted));
    }

    /// Returns the heap object index, or null if not a heap reference.
    pub fn asHeapIndex(self: Self) ?u32 {
        if (!self.isHeapRef()) return null;
        return @intFromEnum(self);
    }

    /// Creates a GcRef from raw bits (u32).
    pub fn encode(bits: u32) Self {
        return @enumFromInt(bits);
    }

    /// Returns the raw bits (u32) of this GcRef.
    pub fn decode(self: Self) u32 {
        return @intFromEnum(self);
    }
};

test "GcRef i31 encoding" {
    const ref = GcRef.fromI31(42);
    try std.testing.expect(ref.isI31());
    try std.testing.expect(!ref.isNull());
    try std.testing.expect(!ref.isHeapRef());
    try std.testing.expectEqual(@as(i31, 42), ref.asI31().?);
}

test "GcRef negative i31" {
    const ref = GcRef.fromI31(-100);
    try std.testing.expect(ref.isI31());
    try std.testing.expectEqual(@as(i31, -100), ref.asI31().?);
}

test "GcRef heap index" {
    const ref = GcRef.fromHeapIndex(4);
    try std.testing.expect(ref.isHeapRef());
    try std.testing.expect(!ref.isI31());
    try std.testing.expect(!ref.isNull());
    try std.testing.expectEqual(@as(u32, 4), ref.asHeapIndex().?);
}

test "GcRef null" {
    const ref = GcRef.null_value;
    try std.testing.expect(ref.isNull());
    try std.testing.expect(!ref.isI31());
    try std.testing.expect(!ref.isHeapRef());
    try std.testing.expect(ref.asI31() == null);
    try std.testing.expect(ref.asHeapIndex() == null);
}

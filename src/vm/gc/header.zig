const std = @import("std");
const GcRefKind = @import("core").GcRefKind;

/// Kind bits layout:
/// - High 6 bits (bits 31-26): GcKind for subtype checking
/// - Low 26 bits (bits 25-0): Reserved for GC metadata (mark bits, etc.)
pub const GcKind = struct {
    pub const Any: u32 = @as(u32, GcRefKind.Any) << 26;
    pub const Eq: u32 = @as(u32, GcRefKind.Eq) << 26;
    pub const I31: u32 = @as(u32, GcRefKind.I31) << 26;
    pub const Struct: u32 = @as(u32, GcRefKind.Struct) << 26;
    pub const Array: u32 = @as(u32, GcRefKind.Array) << 26;
    pub const None: u32 = @as(u32, GcRefKind.None) << 26;
    pub const Func: u32 = @as(u32, GcRefKind.Func) << 26;
    pub const Extern: u32 = @as(u32, GcRefKind.Extern) << 26;

    /// Extract the kind bits (high 6 bits) from kind_bits.
    pub fn extractKind(bits: u32) u6 {
        return @intCast(bits >> 26);
    }

    /// Check if a GcRef is a subtype of another using kind bits.
    pub fn isSubtypeOf(a_bits: u32, b_bits: u32) bool {
        const a_kind = extractKind(a_bits);
        const b_kind = extractKind(b_bits);
        return (a_kind & b_kind) == b_kind;
    }
};

/// GcHeader is the object header for GC-managed objects on the heap.
/// Total size: 8 bytes.
pub const GcHeader = struct {
    /// High 6 bits = GcKind, low 26 bits = GC metadata
    kind_bits: u32,
    /// Type index for concrete types, or reserved for abstract types
    type_index: u32,

    pub fn init(kind: u32, type_index: u32) GcHeader {
        return .{
            .kind_bits = kind,
            .type_index = type_index,
        };
    }

    pub fn initFromRefKind(ref_kind: GcRefKind, type_index: u32) GcHeader {
        return init(@as(u32, ref_kind.bits) << 26, type_index);
    }

    pub fn getKind(self: GcHeader) u6 {
        return GcKind.extractKind(self.kind_bits);
    }

    pub fn isSubtypeOf(self: GcHeader, kind_bits: u32) bool {
        return GcKind.isSubtypeOf(self.kind_bits, kind_bits);
    }
};

test "GcKind subtype checking" {
    try std.testing.expect(GcKind.isSubtypeOf(GcKind.Eq, GcKind.Any));
    try std.testing.expect(GcKind.isSubtypeOf(GcKind.Struct, GcKind.Eq));
    try std.testing.expect(GcKind.isSubtypeOf(GcKind.Struct, GcKind.Any));
    try std.testing.expect(GcKind.isSubtypeOf(GcKind.Array, GcKind.Eq));
    try std.testing.expect(!GcKind.isSubtypeOf(GcKind.Any, GcKind.Eq));
    try std.testing.expect(!GcKind.isSubtypeOf(GcKind.Struct, GcKind.Array));
}

test "GcHeader" {
    const header = GcHeader.initFromRefKind(GcRefKind.init(GcRefKind.Struct), 42);
    try std.testing.expectEqual(@as(u6, GcRefKind.Struct), header.getKind());
    try std.testing.expectEqual(@as(u32, 42), header.type_index);
    try std.testing.expect(header.isSubtypeOf(GcKind.Eq));
    try std.testing.expect(header.isSubtypeOf(GcKind.Any));
}

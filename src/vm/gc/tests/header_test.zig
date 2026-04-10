const std = @import("std");
const testing = std.testing;

const core = @import("core");
const header_mod = @import("../header.zig");

const GcKind = header_mod.GcKind;
const GcHeader = header_mod.GcHeader;
const GcRefKind = core.GcRefKind;

test "GcKind subtype checking" {
    try testing.expect(GcKind.isSubtypeOf(GcKind.Eq, GcKind.Any));
    try testing.expect(GcKind.isSubtypeOf(GcKind.Struct, GcKind.Eq));
    try testing.expect(GcKind.isSubtypeOf(GcKind.Struct, GcKind.Any));
    try testing.expect(GcKind.isSubtypeOf(GcKind.Array, GcKind.Eq));
    try testing.expect(!GcKind.isSubtypeOf(GcKind.Any, GcKind.Eq));
    try testing.expect(!GcKind.isSubtypeOf(GcKind.Struct, GcKind.Array));
}

test "GcHeader" {
    const header = GcHeader.initFromRefKind(GcRefKind.init(GcRefKind.Struct), 42);
    try testing.expectEqual(@as(u6, GcRefKind.Struct), header.getKind());
    try testing.expectEqual(@as(u32, 42), header.type_index);
    try testing.expect(header.isSubtypeOf(GcKind.Eq));
    try testing.expect(header.isSubtypeOf(GcKind.Any));
}

test "GcHeader mark bit" {
    var header = GcHeader.initFromRefKind(GcRefKind.init(GcRefKind.Struct), 42);
    try testing.expect(!header.isMarked());

    header.setMark();
    try testing.expect(header.isMarked());

    header.clearMark();
    try testing.expect(!header.isMarked());
}

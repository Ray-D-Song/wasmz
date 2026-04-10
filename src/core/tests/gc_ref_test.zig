const std = @import("std");
const testing = std.testing;

const gc_ref_mod = @import("../gc_ref.zig");

const GcRef = gc_ref_mod.GcRef;

test "GcRef i31 encoding" {
    const ref = GcRef.fromI31(42);
    try testing.expect(ref.isI31());
    try testing.expect(!ref.isNull());
    try testing.expect(!ref.isHeapRef());
    try testing.expectEqual(@as(i31, 42), ref.asI31().?);
}

test "GcRef negative i31" {
    const ref = GcRef.fromI31(-100);
    try testing.expect(ref.isI31());
    try testing.expectEqual(@as(i31, -100), ref.asI31().?);
}

test "GcRef heap index" {
    const ref = GcRef.fromHeapIndex(4);
    try testing.expect(ref.isHeapRef());
    try testing.expect(!ref.isI31());
    try testing.expect(!ref.isNull());
    try testing.expectEqual(@as(u32, 4), ref.asHeapIndex().?);
}

test "GcRef null" {
    const ref = GcRef.null_value;
    try testing.expect(ref.isNull());
    try testing.expect(!ref.isI31());
    try testing.expect(!ref.isHeapRef());
    try testing.expect(ref.asI31() == null);
    try testing.expect(ref.asHeapIndex() == null);
}

const std = @import("std");
const testing = std.testing;

const heap_type_mod = @import("../heap_type.zig");

const GcRefKind = heap_type_mod.GcRefKind;

test "GcRefKind subtype checking" {
    const any_kind = GcRefKind.init(GcRefKind.Any);
    const eq_kind = GcRefKind.init(GcRefKind.Eq);
    const struct_kind = GcRefKind.init(GcRefKind.Struct);
    const array_kind = GcRefKind.init(GcRefKind.Array);
    const i31_kind = GcRefKind.init(GcRefKind.I31);

    try testing.expect(eq_kind.isSubtypeOf(any_kind));
    try testing.expect(struct_kind.isSubtypeOf(eq_kind));
    try testing.expect(struct_kind.isSubtypeOf(any_kind));
    try testing.expect(array_kind.isSubtypeOf(eq_kind));
    try testing.expect(i31_kind.isSubtypeOf(eq_kind));
    try testing.expect(!struct_kind.isSubtypeOf(array_kind));
    try testing.expect(!any_kind.isSubtypeOf(eq_kind));
}

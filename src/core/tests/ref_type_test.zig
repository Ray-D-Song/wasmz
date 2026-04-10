const std = @import("std");
const testing = std.testing;

const ref_type_mod = @import("../ref_type.zig");

const RefType = ref_type_mod.RefType;

test "RefType subtype checking" {
    const func = RefType.funcref();
    const any = RefType.anyref();
    const eq = RefType.eqref();
    const struct_ref = RefType.structref();

    try testing.expect(func.isSubtypeOf(func));
    try testing.expect(!func.isSubtypeOf(any));

    try testing.expect(struct_ref.isSubtypeOf(eq));
    try testing.expect(struct_ref.isSubtypeOf(any));
    try testing.expect(!eq.isSubtypeOf(struct_ref));
}

test "RefType nullability" {
    const nullable_func = RefType.init(true, .Func);
    const non_nullable_func = RefType.init(false, .Func);

    try testing.expect(non_nullable_func.isSubtypeOf(nullable_func));
    try testing.expect(!nullable_func.isSubtypeOf(non_nullable_func));
}

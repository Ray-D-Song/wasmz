const std = @import("std");
const heap_type = @import("./heap_type.zig");
const HeapType = heap_type.HeapType;
const GcRefKind = heap_type.GcRefKind;

pub const RefType = struct {
    nullable: bool,
    heap_type: HeapType,

    pub fn init(nullable: bool, heap_type_val: HeapType) RefType {
        return .{
            .nullable = nullable,
            .heap_type = heap_type_val,
        };
    }

    pub fn funcref() RefType {
        return init(true, .Func);
    }

    pub fn externref() RefType {
        return init(true, .Extern);
    }

    pub fn anyref() RefType {
        return init(true, .Any);
    }

    pub fn eqref() RefType {
        return init(true, .Eq);
    }

    pub fn i31ref() RefType {
        return init(false, .I31);
    }

    pub fn structref() RefType {
        return init(true, .Struct);
    }

    pub fn arrayref() RefType {
        return init(true, .Array);
    }

    pub fn nullref() RefType {
        return init(true, .None);
    }

    pub fn nullfuncref() RefType {
        return init(true, .NoFunc);
    }

    pub fn nullexternref() RefType {
        return init(true, .NoExtern);
    }

    pub fn isSubtypeOf(self: RefType, other: RefType) bool {
        if (!self.isHeapSubtypeOf(other.heap_type)) {
            return false;
        }
        if (self.nullable and !other.nullable) {
            return false;
        }
        return true;
    }

    fn isHeapSubtypeOf(self: RefType, other: HeapType) bool {
        const self_kind = heap_type.gcRefKindFromHeapType(self.heap_type);
        const other_kind = heap_type.gcRefKindFromHeapType(other);

        if (self_kind == null or other_kind == null) {
            return self.heap_type == other;
        }

        if (self.heap_type.isConcrete() and other.isConcrete()) {
            return self.heap_type == other;
        }

        if (self.heap_type.isConcrete()) {
            return self_kind.?.isSubtypeOf(other_kind.?);
        }

        return self_kind.?.isSubtypeOf(other_kind.?);
    }
};

test "RefType subtype checking" {
    const func = RefType.funcref();
    const any = RefType.anyref();
    const eq = RefType.eqref();
    const struct_ref = RefType.structref();

    try std.testing.expect(func.isSubtypeOf(func));
    try std.testing.expect(!func.isSubtypeOf(any));

    try std.testing.expect(struct_ref.isSubtypeOf(eq));
    try std.testing.expect(struct_ref.isSubtypeOf(any));
    try std.testing.expect(!eq.isSubtypeOf(struct_ref));
}

test "RefType nullability" {
    const nullable_func = RefType.init(true, .Func);
    const non_nullable_func = RefType.init(false, .Func);

    try std.testing.expect(non_nullable_func.isSubtypeOf(nullable_func));
    try std.testing.expect(!nullable_func.isSubtypeOf(non_nullable_func));
}

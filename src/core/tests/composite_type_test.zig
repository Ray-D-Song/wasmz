const std = @import("std");
const testing = std.testing;

const composite_mod = @import("../composite_type.zig");
const core = @import("core");

const StorageType = composite_mod.StorageType;
const FieldType = composite_mod.FieldType;
const StructType = composite_mod.StructType;
const ArrayType = composite_mod.ArrayType;
const CompositeType = composite_mod.CompositeType;
const ValType = core.ValType;

test "CompositeType struct" {
    const allocator = testing.allocator;

    const fields = try allocator.alloc(FieldType, 2);
    fields[0] = .{ .storage_type = .{ .valtype = ValType.I32 }, .mutable = false };
    fields[1] = .{ .storage_type = .{ .packed_type = .I8 }, .mutable = true };

    const struct_ty = StructType{ .fields = fields };
    const composite: CompositeType = .{ .struct_type = struct_ty };

    try testing.expectEqual(@as(usize, 2), composite.struct_type.fields.len);
    try testing.expect(!composite.struct_type.fields[0].mutable);
    try testing.expect(composite.struct_type.fields[1].mutable);

    composite.deinit(allocator);
}

test "CompositeType array" {
    const array_ty = ArrayType{ .field = .{ .storage_type = .{ .valtype = ValType.I64 }, .mutable = false } };
    const composite: CompositeType = .{ .array_type = array_ty };

    try testing.expectEqual(ValType.I64, composite.array_type.field.storage_type.valtype);
}

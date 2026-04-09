const std = @import("std");
const ValType = @import("./value/type.zig").ValType;
const FuncType = @import("./func_type.zig").FuncType;

pub const PackedType = enum {
    I8,
    I16,
};

pub const StorageType = union(enum) {
    valtype: ValType,
    packed_type: PackedType,
};

pub const FieldType = struct {
    storage_type: StorageType,
    mutable: bool,
};

pub const StructType = struct {
    fields: []const FieldType,

    pub fn deinit(self: StructType, allocator: std.mem.Allocator) void {
        allocator.free(self.fields);
    }
};

pub const ArrayType = struct {
    field: FieldType,
};

pub const CompositeType = union(enum) {
    func: FuncType,
    struct_type: StructType,
    array_type: ArrayType,

    pub fn deinit(self: CompositeType, allocator: std.mem.Allocator) void {
        switch (self) {
            .func => |f| f.deinit(allocator),
            .struct_type => |s| s.deinit(allocator),
            .array_type => {},
        }
    }
};

test "CompositeType struct" {
    const allocator = std.testing.allocator;

    const fields = try allocator.alloc(FieldType, 2);
    fields[0] = .{ .storage_type = .{ .valtype = ValType.I32 }, .mutable = false };
    fields[1] = .{ .storage_type = .{ .packed_type = .I8 }, .mutable = true };

    const struct_ty = StructType{ .fields = fields };
    const composite: CompositeType = .{ .struct_type = struct_ty };

    try std.testing.expectEqual(@as(usize, 2), composite.struct_type.fields.len);
    try std.testing.expect(!composite.struct_type.fields[0].mutable);
    try std.testing.expect(composite.struct_type.fields[1].mutable);

    composite.deinit(allocator);
}

test "CompositeType array" {
    const array_ty = ArrayType{ .field = .{ .storage_type = .{ .valtype = ValType.I64 }, .mutable = false } };
    const composite: CompositeType = .{ .array_type = array_ty };

    try std.testing.expectEqual(ValType.I64, composite.array_type.field.storage_type.valtype);
}

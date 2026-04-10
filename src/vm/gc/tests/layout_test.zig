const std = @import("std");
const testing = std.testing;

const core = @import("core");
const layout_mod = @import("../layout.zig");

const StorageType = core.StorageType;
const FieldType = core.FieldType;
const StructType = core.StructType;
const ArrayType = core.ArrayType;
const GcHeader = @import("../header.zig").GcHeader;

test "storageTypeSize" {
    try testing.expectEqual(@as(u32, 4), layout_mod.storageTypeSize(.{ .valtype = .I32 }));
    try testing.expectEqual(@as(u32, 8), layout_mod.storageTypeSize(.{ .valtype = .I64 }));
    try testing.expectEqual(@as(u32, 16), layout_mod.storageTypeSize(.{ .valtype = .V128 }));
    try testing.expectEqual(@as(u32, 1), layout_mod.storageTypeSize(.{ .packed_type = .I8 }));
    try testing.expectEqual(@as(u32, 2), layout_mod.storageTypeSize(.{ .packed_type = .I16 }));
}

test "computeStructLayout" {
    const allocator = testing.allocator;

    const fields = try allocator.alloc(FieldType, 3);
    defer allocator.free(fields);

    fields[0] = .{ .storage_type = .{ .valtype = .I32 }, .mutable = false };
    fields[1] = .{ .storage_type = .{ .valtype = .I64 }, .mutable = true };
    fields[2] = .{ .storage_type = .{ .valtype = .I32 }, .mutable = false };

    const struct_type = StructType{ .fields = fields };
    const layout = try layout_mod.computeStructLayout(struct_type, allocator);
    defer layout.deinit(allocator);

    try testing.expectEqual(@as(u32, 0), layout.field_offsets[0]);
    try testing.expectEqual(@as(u32, 8), layout.field_offsets[1]);
    try testing.expectEqual(@as(u32, 16), layout.field_offsets[2]);
    try testing.expectEqual(@as(u32, 24), layout.size);
}

test "computeArrayLayout" {
    const array_type = ArrayType{
        .field = .{ .storage_type = .{ .valtype = .I32 }, .mutable = false },
    };
    const layout = layout_mod.computeArrayLayout(array_type);

    try testing.expectEqual(@as(u32, @sizeOf(GcHeader) + 4), layout.base_size);
    try testing.expectEqual(@as(u32, 4), layout.elem_size);
    try testing.expect(!layout.elem_is_gc_ref);
}

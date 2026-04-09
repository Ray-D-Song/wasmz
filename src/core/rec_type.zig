const std = @import("std");
const CompositeType = @import("./composite_type.zig").CompositeType;

pub const SubType = struct {
    is_final: bool,
    supertype_indices: []const u32,
    composite_type: CompositeType,

    pub fn deinit(self: SubType, allocator: std.mem.Allocator) void {
        allocator.free(self.supertype_indices);
        self.composite_type.deinit(allocator);
    }
};

pub const RecType = struct {
    sub_types: []const SubType,

    pub fn deinit(self: RecType, allocator: std.mem.Allocator) void {
        for (self.sub_types) |sub| {
            sub.deinit(allocator);
        }
        allocator.free(self.sub_types);
    }
};

test "RecType and SubType" {
    const allocator = std.testing.allocator;

    const supertype_indices = try allocator.dupe(u32, &[_]u32{0});
    errdefer allocator.free(supertype_indices);

    const struct_fields = try allocator.alloc(@import("./composite_type.zig").FieldType, 1);
    struct_fields[0] = .{
        .storage_type = .{ .valtype = @import("./value/type.zig").ValType.I32 },
        .mutable = false,
    };

    const composite: CompositeType = .{
        .struct_type = .{ .fields = struct_fields },
    };

    const sub_type: SubType = .{
        .is_final = false,
        .supertype_indices = supertype_indices,
        .composite_type = composite,
    };

    const sub_types = try allocator.dupe(SubType, &[_]SubType{sub_type});
    errdefer allocator.free(sub_types);

    const rec_type = RecType{ .sub_types = sub_types };

    try std.testing.expectEqual(@as(usize, 1), rec_type.sub_types.len);
    try std.testing.expect(!rec_type.sub_types[0].is_final);
    try std.testing.expectEqual(@as(u32, 0), rec_type.sub_types[0].supertype_indices[0]);

    rec_type.deinit(allocator);
}

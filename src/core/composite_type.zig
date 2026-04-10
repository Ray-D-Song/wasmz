const std = @import("std");
const ValType = @import("./value/type.zig").ValType;

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
    struct_type: StructType,
    array_type: ArrayType,

    pub fn deinit(self: CompositeType, allocator: std.mem.Allocator) void {
        switch (self) {
            .struct_type => |s| s.deinit(allocator),
            .array_type => {},
        }
    }
};

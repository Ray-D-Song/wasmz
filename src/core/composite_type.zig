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

/// Wasm composite type — the unified type index space of the Type Section.
/// In the GC proposal, the type section contains func, struct, and array types
/// sharing a single index space: `comptype ::= functype | structtype | arraytype`.
pub const CompositeType = union(enum) {
    func_type: FuncType,
    struct_type: StructType,
    array_type: ArrayType,

    pub fn deinit(self: CompositeType, allocator: std.mem.Allocator) void {
        switch (self) {
            .func_type => |f| f.deinit(allocator),
            .struct_type => |s| s.deinit(allocator),
            .array_type => {},
        }
    }
};

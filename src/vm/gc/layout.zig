const std = @import("std");
const core = @import("core");

const StorageType = core.StorageType;
const PackedType = core.PackedType;
const StructType = core.StructType;
const ArrayType = core.ArrayType;
const ValType = core.ValType;
const FieldType = core.FieldType;
const GcHeader = @import("./header.zig").GcHeader;

/// StructLayout contains the memory layout for a struct type.
pub const StructLayout = struct {
    /// Total size of the struct in bytes.
    size: u32,
    /// Byte offset for each field.
    field_offsets: []const u32,
    /// Indices of fields that contain GC references (need tracing).
    gc_ref_fields: []const u32,

    pub fn deinit(self: StructLayout, allocator: std.mem.Allocator) void {
        allocator.free(self.field_offsets);
        allocator.free(self.gc_ref_fields);
    }
};

/// ArrayLayout contains the memory layout for an array type.
pub const ArrayLayout = struct {
    /// Base size including header and length field (in bytes).
    /// Layout: [GcHeader (8 bytes)][length: u32 (4 bytes)][elements...]
    base_size: u32,
    /// Size of each element (in bytes).
    elem_size: u32,
    /// Whether elements are GC references (need tracing).
    elem_is_gc_ref: bool,
};

/// Returns the size in bytes for a storage type.
pub fn storageTypeSize(storage_type: StorageType) u32 {
    return switch (storage_type) {
        .valtype => |v| valTypeSize(v),
        .packed_type => |p| switch (p) {
            .I8 => 1,
            .I16 => 2,
        },
    };
}

/// Returns the size in bytes for a value type.
pub fn valTypeSize(val_type: ValType) u32 {
    return switch (val_type) {
        .I32 => 4,
        .I64 => 8,
        .F32 => 4,
        .F64 => 8,
        .V128 => 16,
        .Ref => 4,
    };
}

/// Returns true if the storage type is a GC reference.
pub fn isGcRef(storage_type: StorageType) bool {
    return switch (storage_type) {
        .valtype => |v| switch (v) {
            .Ref => true,
            else => false,
        },
        .packed_type => false,
    };
}

/// Computes the struct layout from a StructType.
pub fn computeStructLayout(struct_type: StructType, allocator: std.mem.Allocator) std.mem.Allocator.Error!StructLayout {
    const fields = struct_type.fields;
    var current_offset: u32 = 0;

    const field_offsets = try allocator.alloc(u32, fields.len);
    errdefer allocator.free(field_offsets);

    var gc_ref_count: usize = 0;
    for (fields) |field| {
        if (isGcRef(field.storage_type)) {
            gc_ref_count += 1;
        }
    }

    const gc_ref_fields = try allocator.alloc(u32, gc_ref_count);
    errdefer allocator.free(gc_ref_fields);

    var gc_ref_idx: usize = 0;
    for (fields, 0..) |field, i| {
        const field_size = storageTypeSize(field.storage_type);
        const alignment = fieldAlignment(field.storage_type);

        current_offset = std.mem.alignForward(u32, current_offset, alignment);
        field_offsets[i] = current_offset;

        if (isGcRef(field.storage_type)) {
            gc_ref_fields[gc_ref_idx] = @intCast(i);
            gc_ref_idx += 1;
        }

        current_offset += field_size;
    }

    const total_alignment = structAlignment(fields);
    const total_size = std.mem.alignForward(u32, current_offset, total_alignment);

    return .{
        .size = total_size,
        .field_offsets = field_offsets,
        .gc_ref_fields = gc_ref_fields,
    };
}

/// Computes the array layout from an ArrayType.
pub fn computeArrayLayout(array_type: ArrayType) ArrayLayout {
    const elem_size = storageTypeSize(array_type.field.storage_type);
    const is_ref = isGcRef(array_type.field.storage_type);
    const header_size: u32 = @sizeOf(GcHeader);

    // base_size includes GcHeader (8 bytes) plus the 4-byte array length field.
    // Element data starts immediately after: offset = base_size + index * elem_size.
    return .{
        .base_size = header_size + 4,
        .elem_size = elem_size,
        .elem_is_gc_ref = is_ref,
    };
}

/// Returns the alignment requirement for a storage type.
fn fieldAlignment(storage_type: StorageType) u32 {
    return switch (storage_type) {
        .valtype => |v| valTypeAlignment(v),
        .packed_type => |p| switch (p) {
            .I8 => 1,
            .I16 => 2,
        },
    };
}

/// Returns the alignment requirement for a value type.
fn valTypeAlignment(val_type: ValType) u32 {
    return switch (val_type) {
        .I32 => 4,
        .I64 => 8,
        .F32 => 4,
        .F64 => 8,
        .V128 => 16,
        .Ref => 4,
    };
}

/// Returns the alignment requirement for a struct (maximum of field alignments).
fn structAlignment(fields: []const FieldType) u32 {
    var max_align: u32 = 1;
    for (fields) |field| {
        const align_val = fieldAlignment(field.storage_type);
        if (align_val > max_align) {
            max_align = align_val;
        }
    }
    return max_align;
}

test "storageTypeSize" {
    try std.testing.expectEqual(@as(u32, 4), storageTypeSize(.{ .valtype = .I32 }));
    try std.testing.expectEqual(@as(u32, 8), storageTypeSize(.{ .valtype = .I64 }));
    try std.testing.expectEqual(@as(u32, 16), storageTypeSize(.{ .valtype = .V128 }));
    try std.testing.expectEqual(@as(u32, 1), storageTypeSize(.{ .packed_type = .I8 }));
    try std.testing.expectEqual(@as(u32, 2), storageTypeSize(.{ .packed_type = .I16 }));
}

test "computeStructLayout" {
    const allocator = std.testing.allocator;

    const fields = try allocator.alloc(FieldType, 3);
    defer allocator.free(fields);

    fields[0] = .{ .storage_type = .{ .valtype = .I32 }, .mutable = false };
    fields[1] = .{ .storage_type = .{ .valtype = .I64 }, .mutable = true };
    fields[2] = .{ .storage_type = .{ .valtype = .I32 }, .mutable = false };

    const struct_type = StructType{ .fields = fields };
    const layout = try computeStructLayout(struct_type, allocator);
    defer layout.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), layout.field_offsets[0]);
    try std.testing.expectEqual(@as(u32, 8), layout.field_offsets[1]);
    try std.testing.expectEqual(@as(u32, 16), layout.field_offsets[2]);
    try std.testing.expectEqual(@as(u32, 24), layout.size);
}

test "computeArrayLayout" {
    const array_type = ArrayType{
        .field = .{ .storage_type = .{ .valtype = .I32 }, .mutable = false },
    };
    const layout = computeArrayLayout(array_type);

    try std.testing.expectEqual(@as(u32, @sizeOf(GcHeader) + 4), layout.base_size);
    try std.testing.expectEqual(@as(u32, 4), layout.elem_size);
    try std.testing.expect(!layout.elem_is_gc_ref);
}

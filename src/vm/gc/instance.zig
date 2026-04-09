const std = @import("std");
const core = @import("core");

const RawVal = core.RawVal;
const ValType = core.ValType;
const GcRef = core.GcRef;
const StorageType = core.StorageType;
const PackedType = core.PackedType;
const StructType = core.StructType;
const ArrayType = core.ArrayType;
const GcHeader = @import("./header.zig").GcHeader;
const StructLayout = @import("./layout.zig").StructLayout;
const ArrayLayout = @import("./layout.zig").ArrayLayout;
const storageTypeSize = @import("./layout.zig").storageTypeSize;

/// GC heap type - raw bytes storage.
pub const GcHeap = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, initial_size: usize) std.mem.Allocator.Error!GcHeap {
        const bytes = try allocator.alloc(u8, initial_size);
        return .{
            .bytes = bytes,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GcHeap) void {
        self.allocator.free(self.bytes);
    }

    pub fn allocObject(self: *GcHeap, size: u32) std.mem.Allocator.Error!GcRef {
        const start = self.bytes.len;
        const new_size = start + size;
        if (new_size > self.bytes.len) {
            self.bytes = try self.allocator.realloc(self.bytes, new_size);
        }
        return GcRef.fromHeapIndex(@as(u32, @intCast(start)));
    }

    pub fn getHeader(self: GcHeap, base: GcRef) *GcHeader {
        const ptr: [*]u8 = &self.bytes[base.asHeapIndex().?];
        return @ptrCast(@alignCast(ptr));
    }

    pub fn getBytes(self: GcHeap, offset: u32) []u8 {
        return self.bytes[offset..];
    }

    pub fn getBytesAt(self: GcHeap, base: GcRef, offset: u32) []u8 {
        const base_offset = base.asHeapIndex().?;
        return self.bytes[base_offset + offset ..];
    }
};

/// Reads a struct field value from the heap.
pub fn readField(
    heap: GcHeap,
    base: GcRef,
    struct_type: StructType,
    layout: StructLayout,
    field_idx: u32,
) RawVal {
    const offset = layout.field_offsets[field_idx];
    const storage_type = struct_type.fields[field_idx].storage_type;
    return readStorageType(heap, base, offset, storage_type);
}

/// Writes a struct field value to the heap.
pub fn writeField(
    heap: GcHeap,
    base: GcRef,
    struct_type: StructType,
    layout: StructLayout,
    field_idx: u32,
    value: RawVal,
) void {
    const offset = layout.field_offsets[field_idx];
    const storage_type = struct_type.fields[field_idx].storage_type;
    writeStorageType(heap, base, offset, storage_type, value);
}

/// Reads an array element from the heap.
pub fn readElem(
    heap: GcHeap,
    base: GcRef,
    array_type: ArrayType,
    layout: ArrayLayout,
    index: u32,
) RawVal {
    const elem_offset = layout.base_size + index * layout.elem_size;
    const storage_type = array_type.field.storage_type;
    return readStorageType(heap, base, elem_offset, storage_type);
}

/// Writes an array element to the heap.
pub fn writeElem(
    heap: GcHeap,
    base: GcRef,
    array_type: ArrayType,
    layout: ArrayLayout,
    index: u32,
    value: RawVal,
) void {
    const elem_offset = layout.base_size + index * layout.elem_size;
    const storage_type = array_type.field.storage_type;
    writeStorageType(heap, base, elem_offset, storage_type, value);
}

/// Gets the length of an array (stored after header).
pub fn getLength(heap: GcHeap, base: GcRef) u32 {
    const bytes = heap.getBytesAt(base, @sizeOf(GcHeader));
    return std.mem.readInt(u32, bytes[0..4], .little);
}

/// Sets the length of an array.
pub fn setLength(heap: GcHeap, base: GcRef, length: u32) void {
    const bytes = heap.getBytesAt(base, @sizeOf(GcHeader));
    std.mem.writeInt(u32, bytes[0..4], length, .little);
}

/// Reads a value from heap based on storage type.
fn readStorageType(heap: GcHeap, base: GcRef, offset: u32, storage_type: StorageType) RawVal {
    const bytes = heap.getBytesAt(base, offset);
    return switch (storage_type) {
        .valtype => |v| switch (v) {
            .I32 => RawVal.from(std.mem.readInt(i32, bytes[0..4], .little)),
            .I64 => RawVal.from(std.mem.readInt(i64, bytes[0..8], .little)),
            .F32 => RawVal.from(std.mem.readInt(u32, bytes[0..4], .little)),
            .F64 => RawVal.from(std.mem.readInt(u64, bytes[0..8], .little)),
            .V128 => blk: {
                const low = std.mem.readInt(u64, bytes[0..8], .little);
                const high = std.mem.readInt(u64, bytes[8..16], .little);
                break :blk RawVal{ .low64 = low, .high64 = high };
            },
            .Ref => RawVal.fromGcRef(GcRef.encode(std.mem.readInt(u32, bytes[0..4], .little))),
        },
        .packed_type => |p| switch (p) {
            .I8 => RawVal.from(@as(i32, @as(i8, @bitCast(bytes[0])))),
            .I16 => RawVal.from(@as(i32, @as(i16, @bitCast(std.mem.readInt(u16, bytes[0..2], .little))))),
        },
    };
}

/// Writes a value to heap based on storage type.
fn writeStorageType(heap: GcHeap, base: GcRef, offset: u32, storage_type: StorageType, value: RawVal) void {
    const bytes = heap.getBytesAt(base, offset);
    switch (storage_type) {
        .valtype => |v| switch (v) {
            .I32 => std.mem.writeInt(i32, bytes[0..4], value.readAs(i32), .little),
            .I64 => std.mem.writeInt(i64, bytes[0..8], value.readAs(i64), .little),
            .F32 => std.mem.writeInt(u32, bytes[0..4], value.readAs(u32), .little),
            .F64 => std.mem.writeInt(u64, bytes[0..8], value.readAs(u64), .little),
            .V128 => {
                std.mem.writeInt(u64, bytes[0..8], value.low64, .little);
                std.mem.writeInt(u64, bytes[8..16], value.high64, .little);
            },
            .Ref => std.mem.writeInt(u32, bytes[0..4], value.readAsGcRef().decode(), .little),
        },
        .packed_type => |p| switch (p) {
            .I8 => bytes[0] = @truncate(@as(u32, @bitCast(value.readAs(i32)))),
            .I16 => std.mem.writeInt(u16, bytes[0..2], @truncate(@as(u32, @bitCast(value.readAs(i32)))), .little),
        },
    }
}

test "read/write packed types" {
    const allocator = std.testing.allocator;
    var heap = try GcHeap.init(allocator, 1024);
    defer heap.deinit();

    const ref = try heap.allocObject(16);

    // Write and read i8 with sign extension
    writeStorageType(heap, ref, 0, .{ .packed_type = .I8 }, RawVal.from(@as(i32, -42)));
    const i8_val = readStorageType(heap, ref, 0, .{ .packed_type = .I8 });
    try std.testing.expectEqual(@as(i32, -42), i8_val.readAs(i32));

    // Write and read i16 with sign extension
    writeStorageType(heap, ref, 2, .{ .packed_type = .I16 }, RawVal.from(@as(i32, -1000)));
    const i16_val = readStorageType(heap, ref, 2, .{ .packed_type = .I16 });
    try std.testing.expectEqual(@as(i32, -1000), i16_val.readAs(i32));
}

test "array length" {
    const allocator = std.testing.allocator;
    var heap = try GcHeap.init(allocator, 1024);
    defer heap.deinit();

    const ref = try heap.allocObject(12);
    setLength(heap, ref, 100);
    try std.testing.expectEqual(@as(u32, 100), getLength(heap, ref));
}

test "read/write i32 field" {
    const allocator = std.testing.allocator;
    var heap = try GcHeap.init(allocator, 1024);
    defer heap.deinit();

    const ref = try heap.allocObject(16);

    writeStorageType(heap, ref, 0, .{ .valtype = .I32 }, RawVal.from(@as(i32, 12345)));
    const val = readStorageType(heap, ref, 0, .{ .valtype = .I32 });
    try std.testing.expectEqual(@as(i32, 12345), val.readAs(i32));
}

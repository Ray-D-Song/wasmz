/// GC Heap Allocator - A simple free-list based memory allocator for GC-managed objects.
///
/// This module provides the foundation for WASM GC heap allocation without the
/// actual garbage collection logic. Objects are allocated from a contiguous byte
/// buffer and tracked via a free-list for reuse.
const std = @import("std");
const core = @import("core");

const GcRef = core.GcRef;
const RawVal = core.RawVal;
const StorageType = core.StorageType;
const StructType = core.StructType;
const ArrayType = core.ArrayType;
const GcHeader = @import("./header.zig").GcHeader;
const StructLayout = @import("./layout.zig").StructLayout;
const ArrayLayout = @import("./layout.zig").ArrayLayout;

/// Minimum alignment for all allocations (8 bytes for GcHeader).
const MIN_ALIGNMENT: u32 = 8;
const HEADER_SIZE: u32 = @sizeOf(GcHeader);

/// Default initial heap size (4 KB = one page).
/// Chosen as a conservative default for WASM GC workloads:
///   - Matches common OS page size for efficient memory management
///   - Small enough to not waste memory for simple modules
///   - Grows exponentially (2x) when needed
pub const INITIAL_HEAP_SIZE: u32 = 4 * 1024;

/// Sentinel value for null/invalid indices in the free list.
pub const NULL_INDEX: u32 = 0;

/// A node in the free list, stored inline within the heap buffer.
/// Represents a contiguous block of free memory.
pub const FreeBlock = struct {
    /// Size of this free block in bytes.
    size: u32,
    /// Index of the next free block, or NULL_INDEX if this is the last.
    next: u32,
};

/// Singly-linked list of free blocks.
pub const FreeList = struct {
    /// Index of the first free block, or NULL_INDEX if empty.
    head: u32 = NULL_INDEX,

    const Self = @This();

    pub fn isEmpty(self: Self) bool {
        return self.head == NULL_INDEX;
    }
};

/// The GC heap - a contiguous byte buffer with free-list allocation.
///
/// Memory Layout:
///   [FreeBlock or Object data][FreeBlock or Object data]...
///
/// Allocation Strategy:
///   1. Search free list for a block >= requested size
///   2. If found: split block if remaining space >= FreeBlock size, or use whole block
///   3. If not found: bump-allocate by extending the buffer
///
/// All allocations are aligned to MIN_ALIGNMENT (8 bytes).
pub const GcHeap = struct {
    /// The raw byte buffer backing the heap.
    bytes: []u8,
    /// Linked list of free blocks available for reuse.
    free_list: FreeList,
    /// Allocator used to grow the buffer when needed.
    allocator: std.mem.Allocator,
    /// Total bytes currently in use (for statistics).
    used: u32,

    const Self = @This();

    /// Initializes a new GC heap with the default initial capacity (INITIAL_HEAP_SIZE).
    pub fn initDefault(allocator: std.mem.Allocator) std.mem.Allocator.Error!Self {
        return init(allocator, INITIAL_HEAP_SIZE);
    }

    /// Initializes a new GC heap with the given initial capacity.
    /// The initial buffer starts empty and will be allocated via bump allocation.
    pub fn init(allocator: std.mem.Allocator, initial_size: u32) std.mem.Allocator.Error!Self {
        const aligned_size = alignUp(initial_size);
        const bytes = try allocator.alloc(u8, aligned_size);

        return .{
            .bytes = bytes,
            .free_list = .{},
            .allocator = allocator,
            .used = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.bytes);
    }

    /// Allocates a block of memory of the given size.
    /// Returns a GcRef pointing to the allocated block, or null if allocation failed.
    ///
    /// The returned index is guaranteed to be:
    ///   - 8-byte aligned
    ///   - Non-zero (suitable for GcRef.fromHeapIndex)
    pub fn alloc(self: *Self, size: u32) ?GcRef {
        if (size == 0) return null;

        const aligned_size = alignUp(size);
        const total_size = aligned_size;

        if (self.free_list.isEmpty()) {
            return self.bumpAlloc(total_size);
        }

        var prev_idx: u32 = NULL_INDEX;
        var curr_idx = self.free_list.head;

        while (curr_idx != NULL_INDEX) {
            const block = self.getFreeBlock(curr_idx);

            if (block.size >= total_size) {
                const remaining = block.size - total_size;

                // Split the block if there's enough space for another FreeBlock
                if (remaining >= @sizeOf(FreeBlock)) {
                    const new_block_idx = curr_idx + total_size;
                    self.setFreeBlock(new_block_idx, .{
                        .size = remaining,
                        .next = block.next,
                    });

                    if (prev_idx == NULL_INDEX) {
                        self.free_list.head = new_block_idx;
                    } else {
                        var prev_block = self.getFreeBlock(prev_idx);
                        prev_block.next = new_block_idx;
                        self.setFreeBlock(prev_idx, prev_block);
                    }
                } else {
                    // Use the whole block (internal fragmentation acceptable)
                    if (prev_idx == NULL_INDEX) {
                        self.free_list.head = block.next;
                    } else {
                        var prev_block = self.getFreeBlock(prev_idx);
                        prev_block.next = block.next;
                        self.setFreeBlock(prev_idx, prev_block);
                    }
                }

                self.used += total_size;
                return GcRef.fromHeapIndex(curr_idx);
            }

            prev_idx = curr_idx;
            curr_idx = block.next;
        }

        return self.bumpAlloc(total_size);
    }

    /// Frees a previously allocated block, returning it to the free list.
    /// The caller must provide the original size used for allocation.
    pub fn free(self: *Self, index: u32, size: u32) void {
        if (index == NULL_INDEX) return;

        const aligned_size = alignUp(size);
        self.used -= aligned_size;

        self.addFreeBlock(index, aligned_size);
    }

    /// Returns a slice of the object data at the given index.
    pub fn objectData(self: Self, index: u32, size: u32) []u8 {
        std.debug.assert(index < self.bytes.len);
        const end = @min(index + size, self.bytes.len);
        return self.bytes[index..end];
    }

    /// Returns a pointer to the GcHeader at the given index.
    /// The caller must ensure the index points to a valid object.
    pub fn header(self: Self, index: u32) *GcHeader {
        std.debug.assert(index + @sizeOf(GcHeader) <= self.bytes.len);
        const ptr: [*]u8 = @ptrCast(&self.bytes[index]);
        return @ptrCast(@alignCast(ptr));
    }

    /// Returns the total capacity of the heap in bytes.
    pub fn totalSize(self: Self) u32 {
        return @intCast(self.bytes.len);
    }

    /// Returns the number of bytes currently allocated.
    pub fn usedSize(self: Self) u32 {
        return self.used;
    }

    /// Returns the number of bytes available for allocation.
    pub fn availableSize(self: Self) u32 {
        return self.totalSize() - self.used;
    }

    /// Returns a pointer to the GcHeader for the object referenced by base.
    pub fn getHeader(self: Self, base: GcRef) *GcHeader {
        return self.header(base.asHeapIndex().?);
    }

    /// Returns a slice of bytes starting at the given offset.
    pub fn getBytes(self: Self, offset: u32) []u8 {
        return self.bytes[offset..];
    }

    /// Returns a slice of bytes starting at base + offset.
    pub fn getBytesAt(self: Self, base: GcRef, offset: u32) []u8 {
        const base_offset = base.asHeapIndex().?;
        return self.bytes[base_offset + offset ..];
    }

    /// Reads a struct field value from the heap.
    pub fn readField(
        self: Self,
        base: GcRef,
        struct_type: StructType,
        layout: StructLayout,
        field_idx: u32,
    ) RawVal {
        const offset = layout.field_offsets[field_idx];
        const storage_type = struct_type.fields[field_idx].storage_type;
        return self.readStorageType(base, offset, storage_type);
    }

    /// Writes a struct field value to the heap.
    pub fn writeField(
        self: Self,
        base: GcRef,
        struct_type: StructType,
        layout: StructLayout,
        field_idx: u32,
        value: RawVal,
    ) void {
        const offset = layout.field_offsets[field_idx];
        const storage_type = struct_type.fields[field_idx].storage_type;
        self.writeStorageType(base, offset, storage_type, value);
    }

    /// Reads an array element from the heap.
    pub fn readElem(
        self: Self,
        base: GcRef,
        array_type: ArrayType,
        layout: ArrayLayout,
        index: u32,
    ) RawVal {
        const elem_offset = layout.base_size + index * layout.elem_size;
        const storage_type = array_type.field.storage_type;
        return self.readStorageType(base, elem_offset, storage_type);
    }

    /// Writes an array element to the heap.
    pub fn writeElem(
        self: Self,
        base: GcRef,
        array_type: ArrayType,
        layout: ArrayLayout,
        index: u32,
        value: RawVal,
    ) void {
        const elem_offset = layout.base_size + index * layout.elem_size;
        const storage_type = array_type.field.storage_type;
        self.writeStorageType(base, elem_offset, storage_type, value);
    }

    /// Gets the length of an array (stored after header).
    pub fn getLength(self: Self, base: GcRef) u32 {
        const bytes = self.getBytesAt(base, @sizeOf(GcHeader));
        return std.mem.readInt(u32, bytes[0..4], .little);
    }

    /// Sets the length of an array.
    pub fn setLength(self: Self, base: GcRef, length: u32) void {
        const bytes = self.getBytesAt(base, @sizeOf(GcHeader));
        std.mem.writeInt(u32, bytes[0..4], length, .little);
    }

    /// Reads a value from heap based on storage type.
    fn readStorageType(self: Self, base: GcRef, offset: u32, storage_type: StorageType) RawVal {
        const bytes = self.getBytesAt(base, offset);
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
    fn writeStorageType(self: Self, base: GcRef, offset: u32, storage_type: StorageType, value: RawVal) void {
        const bytes = self.getBytesAt(base, offset);
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

    /// Bump allocation: allocates from the current buffer by incrementing the used pointer.
    /// Grows the heap by 2x (or at least enough to satisfy the request) when full.
    /// Used as fallback when no suitable free block exists.
    ///
    /// Note: GcRef reserves index 0 for null, so we skip the first 8 bytes.
    fn bumpAlloc(self: *Self, size: u32) ?GcRef {
        // Ensure we don't allocate at index 0 (reserved for null in GcRef)
        if (self.used == 0) {
            self.used = MIN_ALIGNMENT;
        }

        const offset = self.used;

        // Check if we have enough space in the current buffer
        if (offset + size > self.bytes.len) {
            // Need to grow the buffer
            const current_size = @as(u32, @intCast(self.bytes.len));
            const min_needed = offset + size;
            const double_size = current_size * 2;
            const new_len = alignUp(@max(min_needed, double_size));

            self.bytes = self.allocator.realloc(self.bytes, new_len) catch return null;
        }

        self.used += size;
        return GcRef.fromHeapIndex(offset);
    }

    /// Reads a FreeBlock from the heap buffer at the given index.
    fn getFreeBlock(self: Self, index: u32) FreeBlock {
        std.debug.assert(index + @sizeOf(FreeBlock) <= self.bytes.len);
        const ptr: [*]const u8 = @ptrCast(&self.bytes[index]);
        return @as(*const FreeBlock, @ptrCast(@alignCast(ptr))).*;
    }

    /// Writes a FreeBlock to the heap buffer at the given index.
    fn setFreeBlock(self: Self, index: u32, block: FreeBlock) void {
        std.debug.assert(index + @sizeOf(FreeBlock) <= self.bytes.len);
        const ptr: [*]u8 = @ptrCast(&self.bytes[index]);
        @as(*FreeBlock, @ptrCast(@alignCast(ptr))).* = block;
    }

    /// Adds a free block to the head of the free list.
    fn addFreeBlock(self: *Self, index: u32, size: u32) void {
        if (size < @sizeOf(FreeBlock)) return;

        self.setFreeBlock(index, .{
            .size = size,
            .next = self.free_list.head,
        });
        self.free_list.head = index;
    }

    /// Rounds up size to the nearest multiple of MIN_ALIGNMENT.
    fn alignUp(size: u32) u32 {
        return (size + MIN_ALIGNMENT - 1) & ~(MIN_ALIGNMENT - 1);
    }
};

test "GcHeap basic allocation" {
    const allocator = std.testing.allocator;
    var heap = try GcHeap.initDefault(allocator);
    defer heap.deinit();

    const ref1 = heap.alloc(16).?;
    try std.testing.expect(ref1.isHeapRef());
    // First allocation starts at index 8 (index 0 is reserved for null)
    try std.testing.expectEqual(@as(u32, 8), ref1.asHeapIndex().?);

    const ref2 = heap.alloc(32).?;
    try std.testing.expect(ref2.isHeapRef());
    try std.testing.expectEqual(@as(u32, 24), ref2.asHeapIndex().?);
}

test "GcHeap free and reuse" {
    const allocator = std.testing.allocator;
    var heap = try GcHeap.initDefault(allocator);
    defer heap.deinit();

    const ref1 = heap.alloc(16).?;
    const idx1 = ref1.asHeapIndex().?;

    heap.free(idx1, 16);

    const ref2 = heap.alloc(16).?;
    try std.testing.expectEqual(idx1, ref2.asHeapIndex().?);
}

test "GcHeap alignment" {
    const allocator = std.testing.allocator;
    var heap = try GcHeap.initDefault(allocator);
    defer heap.deinit();

    const ref1 = heap.alloc(5).?;
    const idx1 = ref1.asHeapIndex().?;
    try std.testing.expect(idx1 % 8 == 0);
    try std.testing.expectEqual(@as(u32, 8), idx1);

    const ref2 = heap.alloc(3).?;
    const idx2 = ref2.asHeapIndex().?;
    try std.testing.expect(idx2 % 8 == 0);
    try std.testing.expectEqual(@as(u32, 16), idx2);
}

test "GcHeap header access" {
    const allocator = std.testing.allocator;
    var heap = try GcHeap.initDefault(allocator);
    defer heap.deinit();

    const ref = heap.alloc(24).?;
    const idx = ref.asHeapIndex().?;

    const h = heap.header(idx);
    h.type_index = 42;

    try std.testing.expectEqual(@as(u32, 42), heap.header(idx).type_index);
}

test "GcHeap objectData access" {
    const allocator = std.testing.allocator;
    var heap = try GcHeap.initDefault(allocator);
    defer heap.deinit();

    const ref = heap.alloc(16).?;
    const idx = ref.asHeapIndex().?;

    const data = heap.objectData(idx, 16);
    @memset(data, 0xAB);

    try std.testing.expectEqual(@as(u8, 0xAB), heap.bytes[idx]);
    try std.testing.expectEqual(@as(u8, 0xAB), heap.bytes[idx + 15]);
}

test "GcHeap exponential growth" {
    const allocator = std.testing.allocator;
    var heap = try GcHeap.init(allocator, 128);
    defer heap.deinit();

    // Initial size: 128
    try std.testing.expectEqual(@as(u32, 128), heap.totalSize());

    // First allocation at index 8 (skip 0 for null)
    _ = heap.alloc(32).?;
    try std.testing.expectEqual(@as(u32, 128), heap.totalSize());

    // Second allocation should trigger growth (8 + 32 + 64 = 104, still < 128)
    _ = heap.alloc(64).?;
    try std.testing.expectEqual(@as(u32, 128), heap.totalSize());

    // Third allocation: 8 + 32 + 64 + 64 = 168 > 128, triggers 2x growth (128 -> 256)
    _ = heap.alloc(64).?;
    try std.testing.expectEqual(@as(u32, 256), heap.totalSize());
}

test "GcHeap read/write packed types" {
    const allocator = std.testing.allocator;
    var heap = try GcHeap.init(allocator, 256);
    defer heap.deinit();

    const ref = heap.alloc(16).?;

    // Write and read i8 with sign extension
    heap.writeStorageType(ref, 0, .{ .packed_type = .I8 }, RawVal.from(@as(i32, -42)));
    const i8_val = heap.readStorageType(ref, 0, .{ .packed_type = .I8 });
    try std.testing.expectEqual(@as(i32, -42), i8_val.readAs(i32));

    // Write and read i16 with sign extension
    heap.writeStorageType(ref, 2, .{ .packed_type = .I16 }, RawVal.from(@as(i32, -1000)));
    const i16_val = heap.readStorageType(ref, 2, .{ .packed_type = .I16 });
    try std.testing.expectEqual(@as(i32, -1000), i16_val.readAs(i32));
}

test "GcHeap array length" {
    const allocator = std.testing.allocator;
    var heap = try GcHeap.init(allocator, 256);
    defer heap.deinit();

    const ref = heap.alloc(12).?;
    heap.setLength(ref, 100);
    try std.testing.expectEqual(@as(u32, 100), heap.getLength(ref));
}

test "GcHeap read/write i32" {
    const allocator = std.testing.allocator;
    var heap = try GcHeap.init(allocator, 256);
    defer heap.deinit();

    const ref = heap.alloc(16).?;

    heap.writeStorageType(ref, 0, .{ .valtype = .I32 }, RawVal.from(@as(i32, 12345)));
    const val = heap.readStorageType(ref, 0, .{ .valtype = .I32 });
    try std.testing.expectEqual(@as(i32, 12345), val.readAs(i32));
}

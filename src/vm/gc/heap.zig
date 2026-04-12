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
const GcKind = @import("./header.zig").GcKind;
const StructLayout = @import("./layout.zig").StructLayout;
const ArrayLayout = @import("./layout.zig").ArrayLayout;
const MemoryBudget = core.MemoryBudget;

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

/// Tracks information about each allocated object for GC.
pub const AllocationInfo = struct {
    /// Heap index where the object starts.
    index: u32,
    /// Total allocated size including header and padding.
    size: u32,
};

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
    /// Tracks all live allocations for GC traversal.
    live_objects: std.ArrayListUnmanaged(AllocationInfo),
    /// Optional pointer to the store's MemoryBudget for limit enforcement.
    /// null when no budget is configured (unlimited mode).
    budget: ?*MemoryBudget,

    const Self = @This();

    /// Initializes a new GC heap with the default initial capacity (INITIAL_HEAP_SIZE).
    pub fn initDefault(allocator: std.mem.Allocator, budget: ?*MemoryBudget) std.mem.Allocator.Error!Self {
        return init(allocator, INITIAL_HEAP_SIZE, budget);
    }

    /// Initializes a new GC heap with the given initial capacity.
    /// The initial buffer starts empty and will be allocated via bump allocation.
    pub fn init(allocator: std.mem.Allocator, initial_size: u32, budget: ?*MemoryBudget) std.mem.Allocator.Error!Self {
        const aligned_size = alignUp(initial_size);
        const bytes = try allocator.alloc(u8, aligned_size);

        if (budget) |b| {
            b.recordGcGrow(aligned_size);
        }

        return .{
            .bytes = bytes,
            .free_list = .{},
            .allocator = allocator,
            .used = 0,
            .live_objects = .{},
            .budget = budget,
        };
    }

    pub fn deinit(self: *Self) void {
        self.live_objects.deinit(self.allocator);
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
            const result = self.bumpAlloc(total_size) orelse return null;
            self.trackAllocation(result, total_size);
            return result;
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
                const result = GcRef.fromHeapIndex(curr_idx);
                self.trackAllocation(result, total_size);
                return result;
            }

            prev_idx = curr_idx;
            curr_idx = block.next;
        }

        const result = self.bumpAlloc(total_size) orelse return null;
        self.trackAllocation(result, total_size);
        return result;
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
    /// Note: field_offsets are relative to the struct payload (after GcHeader),
    /// so we add HEADER_SIZE to get the absolute offset from the object base.
    pub fn readField(
        self: Self,
        base: GcRef,
        struct_type: StructType,
        layout: StructLayout,
        field_idx: u32,
    ) RawVal {
        const offset = HEADER_SIZE + layout.field_offsets[field_idx];
        const storage_type = struct_type.fields[field_idx].storage_type;
        return self.readStorageType(base, offset, storage_type);
    }

    /// Writes a struct field value to the heap.
    /// Note: field_offsets are relative to the struct payload (after GcHeader),
    /// so we add HEADER_SIZE to get the absolute offset from the object base.
    pub fn writeField(
        self: Self,
        base: GcRef,
        struct_type: StructType,
        layout: StructLayout,
        field_idx: u32,
        value: RawVal,
    ) void {
        const offset = HEADER_SIZE + layout.field_offsets[field_idx];
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

    /// Reads a value from heap based on storage type, zero-extending packed types.
    /// Used by struct.get_u and array.get_u instructions.
    fn readStorageTypeUnsigned(self: Self, base: GcRef, offset: u32, storage_type: StorageType) RawVal {
        const bytes = self.getBytesAt(base, offset);
        return switch (storage_type) {
            // Non-packed types: same as signed read (zero-extension doesn't apply).
            .valtype => self.readStorageType(base, offset, storage_type),
            // Packed types: zero-extend (treat as unsigned u8/u16).
            .packed_type => |p| switch (p) {
                .I8 => RawVal.from(@as(i32, @as(u8, bytes[0]))),
                .I16 => RawVal.from(@as(i32, @as(u16, std.mem.readInt(u16, bytes[0..2], .little)))),
            },
        };
    }

    /// Reads a struct field value from the heap, zero-extending packed types.
    pub fn readFieldUnsigned(
        self: Self,
        base: GcRef,
        struct_type: StructType,
        layout: StructLayout,
        field_idx: u32,
    ) RawVal {
        const offset = HEADER_SIZE + layout.field_offsets[field_idx];
        const storage_type = struct_type.fields[field_idx].storage_type;
        return self.readStorageTypeUnsigned(base, offset, storage_type);
    }

    /// Reads an array element from the heap, zero-extending packed types.
    pub fn readElemUnsigned(
        self: Self,
        base: GcRef,
        array_type: ArrayType,
        layout: ArrayLayout,
        index: u32,
    ) RawVal {
        const elem_offset = layout.base_size + index * layout.elem_size;
        const storage_type = array_type.field.storage_type;
        return self.readStorageTypeUnsigned(base, elem_offset, storage_type);
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

            // Enforce memory budget before growing.
            const additional = new_len - current_size;
            if (self.budget) |b| {
                if (!b.canGrow(additional)) return null;
            }

            self.bytes = self.allocator.realloc(self.bytes, new_len) catch return null;

            // Update budget with new capacity.
            if (self.budget) |b| {
                b.recordGcGrow(new_len);
            }
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

    /// Tracks an allocation in the live_objects list.
    fn trackAllocation(self: *Self, ref: GcRef, size: u32) void {
        self.live_objects.append(self.allocator, .{
            .index = ref.asHeapIndex() orelse return,
            .size = size,
        }) catch {};
    }

    // ── Exception object helpers ────────────────────────────────────────────────
    //
    // Exception object layout on the heap (all fields little-endian):
    //   Offset  0: GcHeader (8 bytes) — kind_bits=GcKind.Exception, type_index=tag_index
    //   Offset  8: u32 arg_count
    //   Offset 12: u32 _pad (reserved, must be 0)
    //   Offset 16: RawVal[arg_count]  (each RawVal = 16 bytes)

    pub const EXCEPTION_ARGS_OFFSET: u32 = 16;

    /// Allocate an exception object for the given tag and argument values.
    /// Returns a GcRef pointing to the new object, or null on OOM.
    pub fn allocException(self: *Self, tag_index: u32, args: []const RawVal) ?GcRef {
        const n: u32 = @intCast(args.len);
        const total: u32 = EXCEPTION_ARGS_OFFSET + n * @sizeOf(RawVal);
        const ref = self.alloc(total) orelse return null;

        // Write header
        const hdr = self.getHeader(ref);
        hdr.kind_bits = GcKind.Exception;
        hdr.type_index = tag_index;

        // Write arg_count
        const base = ref.asHeapIndex().?;
        std.mem.writeInt(u32, self.bytes[base + 8 ..][0..4], n, .little);
        // Padding
        std.mem.writeInt(u32, self.bytes[base + 12 ..][0..4], 0, .little);

        // Write arg values
        for (args, 0..) |val, i| {
            const off = EXCEPTION_ARGS_OFFSET + @as(u32, @intCast(i)) * @sizeOf(RawVal);
            std.mem.writeInt(u64, self.bytes[base + off ..][0..8], val.low64, .little);
            std.mem.writeInt(u64, self.bytes[base + off + 8 ..][0..8], val.high64, .little);
        }

        return ref;
    }

    /// Return the tag index of an exception object.
    pub fn exceptionTagIndex(self: Self, ref: GcRef) u32 {
        return self.getHeader(ref).type_index;
    }

    /// Return the number of arguments stored in an exception object.
    pub fn exceptionArgCount(self: Self, ref: GcRef) u32 {
        const base = ref.asHeapIndex().?;
        return std.mem.readInt(u32, self.bytes[base + 8 ..][0..4], .little);
    }

    /// Return the i-th argument of an exception object.
    pub fn exceptionArg(self: Self, ref: GcRef, i: u32) RawVal {
        const base = ref.asHeapIndex().?;
        const off = EXCEPTION_ARGS_OFFSET + i * @sizeOf(RawVal);
        const low = std.mem.readInt(u64, self.bytes[base + off ..][0..8], .little);
        const high = std.mem.readInt(u64, self.bytes[base + off + 8 ..][0..8], .little);
        return .{ .low64 = low, .high64 = high };
    }

    /// GC entry point - performs mark-and-sweep collection.
    ///
    /// Parameters:
    ///   roots:           slice of GcRef values that are directly reachable (call frame slots, globals).
    ///   composite_types: type descriptors indexed by type_index stored in each object's GcHeader.
    ///   struct_layouts:  per-type struct layout (null if the type is not a struct).
    ///   array_layouts:   per-type array layout  (null if the type is not an array).
    ///
    /// Algorithm: tri-color mark-and-sweep with an explicit worklist to avoid stack overflow.
    pub fn collect(
        self: *Self,
        roots: []const GcRef,
        composite_types: []const @import("core").CompositeType,
        struct_layouts: []const ?StructLayout,
        array_layouts: []const ?ArrayLayout,
    ) void {
        // ── Phase 1: Mark ───────────────────────────────────────────────────
        // Use an explicit ArrayListUnmanaged as the worklist so we never overflow
        // the native call stack regardless of object graph depth.
        var worklist = std.ArrayListUnmanaged(u32){};
        defer worklist.deinit(self.allocator);

        // Seed the worklist with all heap references found in the root set.
        for (roots) |ref| {
            if (ref.isHeapRef()) {
                const idx = ref.asHeapIndex().?;
                const hdr = self.header(idx);
                if (!hdr.isMarked()) {
                    hdr.setMark();
                    worklist.append(self.allocator, idx) catch {};
                }
            }
        }

        // BFS/iterative DFS: process each reachable object and enqueue its referents.
        while (worklist.items.len > 0) {
            const obj_idx = worklist.pop().?;
            const hdr = self.header(obj_idx);
            const type_index = hdr.type_index;

            // Exception objects: trace all RawVal args that contain GC references.
            if ((hdr.kind_bits & ~GcKind.MARK_BIT) == GcKind.Exception) {
                const base_ref = GcRef.fromHeapIndex(obj_idx);
                const arg_count = self.exceptionArgCount(base_ref);
                for (0..arg_count) |ai| {
                    const arg = self.exceptionArg(base_ref, @intCast(ai));
                    const child_ref = GcRef.encode(@as(u32, @truncate(arg.low64)));
                    if (child_ref.isHeapRef()) {
                        const child_idx = child_ref.asHeapIndex().?;
                        const child_hdr = self.header(child_idx);
                        if (!child_hdr.isMarked()) {
                            child_hdr.setMark();
                            worklist.append(self.allocator, child_idx) catch {};
                        }
                    }
                }
                continue;
            }

            // Only user-defined composite types carry child references we need to trace.
            // Abstract heap types (i31, extern, func, …) have no children.
            if (type_index >= composite_types.len) continue;

            switch (composite_types[type_index]) {
                .struct_type => |st| {
                    // Walk only the fields that contain GC references.
                    if (type_index < struct_layouts.len) {
                        if (struct_layouts[type_index]) |layout| {
                            for (layout.gc_ref_fields) |field_idx| {
                                // field_offsets are relative to payload; add HEADER_SIZE for absolute offset
                                const field_offset = HEADER_SIZE + layout.field_offsets[field_idx];
                                _ = st; // struct_type used for type info above
                                const bytes = self.getBytesAt(GcRef.fromHeapIndex(obj_idx), field_offset);
                                const raw_bits = std.mem.readInt(u32, bytes[0..4], .little);
                                const child_ref = GcRef.encode(raw_bits);
                                if (child_ref.isHeapRef()) {
                                    const child_idx = child_ref.asHeapIndex().?;
                                    const child_hdr = self.header(child_idx);
                                    if (!child_hdr.isMarked()) {
                                        child_hdr.setMark();
                                        worklist.append(self.allocator, child_idx) catch {};
                                    }
                                }
                            }
                        }
                    }
                },
                .array_type => {
                    // Walk element refs only when the element type is a GC reference.
                    if (type_index < array_layouts.len) {
                        if (array_layouts[type_index]) |layout| {
                            if (layout.elem_is_gc_ref) {
                                const base_ref = GcRef.fromHeapIndex(obj_idx);
                                const length = self.getLength(base_ref);
                                for (0..length) |i| {
                                    const elem_offset = layout.base_size + @as(u32, @intCast(i)) * layout.elem_size;
                                    const bytes = self.getBytesAt(base_ref, elem_offset);
                                    const raw_bits = std.mem.readInt(u32, bytes[0..4], .little);
                                    const child_ref = GcRef.encode(raw_bits);
                                    if (child_ref.isHeapRef()) {
                                        const child_idx = child_ref.asHeapIndex().?;
                                        const child_hdr = self.header(child_idx);
                                        if (!child_hdr.isMarked()) {
                                            child_hdr.setMark();
                                            worklist.append(self.allocator, child_idx) catch {};
                                        }
                                    }
                                }
                            }
                        }
                    }
                },
                .func_type => {
                    // Function types carry no GC child references — nothing to trace.
                },
            }
        }

        // ── Phase 2: Sweep ──────────────────────────────────────────────────
        // Iterate live_objects in reverse so swap-remove doesn't skip entries.
        var i: usize = self.live_objects.items.len;
        while (i > 0) {
            i -= 1;
            const info = self.live_objects.items[i];
            const hdr = self.header(info.index);
            if (hdr.isMarked()) {
                // Still live — clear mark bit for next GC cycle.
                hdr.clearMark();
            } else {
                // Unreachable — free the block and remove from live list.
                self.free(info.index, info.size);
                _ = self.live_objects.swapRemove(i);
            }
        }
    }
};

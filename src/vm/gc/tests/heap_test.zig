const std = @import("std");
const testing = std.testing;

const core = @import("core");
const heap_mod = @import("../heap.zig");

const GcHeap = heap_mod.GcHeap;
const GcRef = core.GcRef;
const RawVal = core.RawVal;
const StorageType = core.StorageType;
const GcHeader = @import("../header.zig").GcHeader;

test "GcHeap basic allocation" {
    var heap = try GcHeap.initDefault(testing.allocator);
    defer heap.deinit();

    const ref1 = heap.alloc(16).?;
    try testing.expect(ref1.isHeapRef());
    try testing.expectEqual(@as(u32, 8), ref1.asHeapIndex().?);

    const ref2 = heap.alloc(32).?;
    try testing.expect(ref2.isHeapRef());
    try testing.expectEqual(@as(u32, 24), ref2.asHeapIndex().?);
}

test "GcHeap free and reuse" {
    var heap = try GcHeap.initDefault(testing.allocator);
    defer heap.deinit();

    const ref1 = heap.alloc(16).?;
    const idx1 = ref1.asHeapIndex().?;

    heap.free(idx1, 16);

    const ref2 = heap.alloc(16).?;
    try testing.expectEqual(idx1, ref2.asHeapIndex().?);
}

test "GcHeap alignment" {
    var heap = try GcHeap.initDefault(testing.allocator);
    defer heap.deinit();

    const ref1 = heap.alloc(5).?;
    const idx1 = ref1.asHeapIndex().?;
    try testing.expect(idx1 % 8 == 0);
    try testing.expectEqual(@as(u32, 8), idx1);

    const ref2 = heap.alloc(3).?;
    const idx2 = ref2.asHeapIndex().?;
    try testing.expect(idx2 % 8 == 0);
    try testing.expectEqual(@as(u32, 16), idx2);
}

test "GcHeap header access" {
    var heap = try GcHeap.initDefault(testing.allocator);
    defer heap.deinit();

    const ref = heap.alloc(24).?;
    const idx = ref.asHeapIndex().?;

    const h = heap.header(idx);
    h.type_index = 42;

    try testing.expectEqual(@as(u32, 42), heap.header(idx).type_index);
}

test "GcHeap objectData access" {
    var heap = try GcHeap.initDefault(testing.allocator);
    defer heap.deinit();

    const ref = heap.alloc(16).?;
    const idx = ref.asHeapIndex().?;

    const data = heap.objectData(idx, 16);
    @memset(data, 0xAB);

    try testing.expectEqual(@as(u8, 0xAB), heap.bytes[idx]);
    try testing.expectEqual(@as(u8, 0xAB), heap.bytes[idx + 15]);
}

test "GcHeap exponential growth" {
    var heap = try GcHeap.init(testing.allocator, 128);
    defer heap.deinit();

    try testing.expectEqual(@as(u32, 128), heap.totalSize());

    _ = heap.alloc(32).?;
    try testing.expectEqual(@as(u32, 128), heap.totalSize());

    _ = heap.alloc(64).?;
    try testing.expectEqual(@as(u32, 128), heap.totalSize());

    _ = heap.alloc(64).?;
    try testing.expectEqual(@as(u32, 256), heap.totalSize());
}

test "GcHeap read/write packed types" {
    var heap = try GcHeap.init(testing.allocator, 256);
    defer heap.deinit();

    const ref = heap.alloc(16).?;

    heap.writeStorageType(ref, 0, .{ .packed_type = .I8 }, RawVal.from(@as(i32, -42)));
    const i8_val = heap.readStorageType(ref, 0, .{ .packed_type = .I8 });
    try testing.expectEqual(@as(i32, -42), i8_val.readAs(i32));

    heap.writeStorageType(ref, 2, .{ .packed_type = .I16 }, RawVal.from(@as(i32, -1000)));
    const i16_val = heap.readStorageType(ref, 2, .{ .packed_type = .I16 });
    try testing.expectEqual(@as(i32, -1000), i16_val.readAs(i32));
}

test "GcHeap array length" {
    var heap = try GcHeap.init(testing.allocator, 256);
    defer heap.deinit();

    const ref = heap.alloc(12).?;
    heap.setLength(ref, 100);
    try testing.expectEqual(@as(u32, 100), heap.getLength(ref));
}

test "GcHeap read/write i32" {
    var heap = try GcHeap.init(testing.allocator, 256);
    defer heap.deinit();

    const ref = heap.alloc(16).?;

    heap.writeStorageType(ref, 0, .{ .valtype = .I32 }, RawVal.from(@as(i32, 12345)));
    const val = heap.readStorageType(ref, 0, .{ .valtype = .I32 });
    try testing.expectEqual(@as(i32, 12345), val.readAs(i32));
}

test "GcHeap live object tracking" {
    var heap = try GcHeap.initDefault(testing.allocator);
    defer heap.deinit();

    try testing.expectEqual(@as(usize, 0), heap.live_objects.items.len);

    _ = heap.alloc(16).?;
    try testing.expectEqual(@as(usize, 1), heap.live_objects.items.len);

    _ = heap.alloc(32).?;
    try testing.expectEqual(@as(usize, 2), heap.live_objects.items.len);

    const info0 = heap.live_objects.items[0];
    try testing.expectEqual(@as(u32, 8), info0.index);
    try testing.expectEqual(@as(u32, 16), info0.size);

    const info1 = heap.live_objects.items[1];
    try testing.expectEqual(@as(u32, 24), info1.index);
    try testing.expectEqual(@as(u32, 32), info1.size);
}

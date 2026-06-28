const std = @import("std");
const testing = std.testing;
const core = @import("core");

const Memory = core.Memory;
const WASM_PAGE_SIZE = core.WASM_PAGE_SIZE;

test "owned memory: u64 page count and grow" {
    var mem = try Memory.initOwnedWithMax(testing.allocator, 1, 4, false);
    defer mem.deinit();

    try testing.expectEqual(@as(u64, 1), mem.pageCount());
    try testing.expectEqual(@as(u64, WASM_PAGE_SIZE), mem.byteLen());

    const old = mem.grow(1);
    try testing.expectEqual(@as(u64, 1), old);
    try testing.expectEqual(@as(u64, 2), mem.pageCount());
    try testing.expectEqual(@as(u64, 2 * WASM_PAGE_SIZE), mem.byteLen());
}

test "owned memory: grow failure returns maxInt(u64)" {
    var mem = try Memory.initOwnedWithMax(testing.allocator, 1, 2, false);
    defer mem.deinit();

    _ = mem.grow(1);
    const failed = mem.grow(1);
    try testing.expectEqual(std.math.maxInt(u64), failed);
}

test "memory64 heap-backed memory grows without mmap max" {
    if (!core.platform.is_64bit) return error.SkipZigTest;

    var mem = try Memory.initOwnedWithMax(testing.allocator, 1, null, true);
    defer mem.deinit();

    try testing.expectEqual(@as(u64, 1), mem.pageCount());
    const old = mem.grow(2);
    try testing.expectEqual(@as(u64, 1), old);
    try testing.expectEqual(@as(u64, 3), mem.pageCount());
}

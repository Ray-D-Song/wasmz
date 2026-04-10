const std = @import("std");
const testing = std.testing;

const engine_pkg = @import("../../engine/root.zig");
const config_pkg = @import("../../engine/config.zig");
const store_mod = @import("../store.zig");
const gc_mod = @import("../../vm/gc/root.zig");

const Store = store_mod.Store;

test "Store initializes GC heap" {
    var engine = try engine_pkg.Engine.init(testing.allocator, config_pkg.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    try testing.expect(store.gc_heap.totalSize() >= gc_mod.INITIAL_HEAP_SIZE);

    const ref = store.gc_heap.alloc(32) orelse return error.AllocationFailed;
    try testing.expect(ref.isHeapRef());
    try testing.expect(ref.asHeapIndex().? >= 8);
}

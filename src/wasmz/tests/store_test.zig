const std = @import("std");
const testing = std.testing;

const engine_pkg = @import("../../engine/root.zig");
const config_pkg = @import("../../engine/config.zig");
const store_mod = @import("../store.zig");
const gc_mod = @import("../../vm/gc/root.zig");

const Store = store_mod.Store;

test "Store initializes GC heap lazily" {
    var engine = try engine_pkg.Engine.init(testing.allocator, config_pkg.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    // GC heap should not be initialized until needed
    try testing.expect(store.gc_heap == null);

    // Initialize GC heap on demand
    const gc_heap = try store.ensureGcHeap();
    try testing.expect(gc_heap.totalSize() >= gc_mod.INITIAL_HEAP_SIZE);

    const ref = gc_heap.alloc(32) orelse return error.AllocationFailed;
    try testing.expect(ref.isHeapRef());
    try testing.expect(ref.asHeapIndex().? >= 8);
}

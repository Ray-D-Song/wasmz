const std = @import("std");
const wasmz = @import("wasmz");
const profiling = wasmz.profiling;

const Store = wasmz.Store;
const Instance = wasmz.Instance;

pub const MemStatsCtx = struct {
    store: ?*Store = null,
    instance: ?*Instance = null,
};

pub fn onExitMemStats(_: u32, data: ?*anyopaque) void {
    if (data) |d| {
        const ctx: *MemStatsCtx = @ptrCast(@alignCast(d));
        if (ctx.store != null and ctx.instance != null) {
            printMemStats(ctx.store.?, ctx.instance.?);
        }
    }
}

pub fn onExitProfiling(_: u32, _: ?*anyopaque) void {
    profiling.printReport();
}

pub fn printMemStats(store: *Store, instance: *Instance) void {
    const linear_bytes = instance.memory.byteLen();
    const linear_pages = instance.memory.pageCount();
    const gc_used = store.gc_heap.usedSize();
    const gc_cap = store.gc_heap.totalSize();
    const shared_bytes = store.memory_budget.shared_bytes;
    const total = linear_bytes + gc_cap + shared_bytes;

    const linear_mb = @as(f64, @floatFromInt(linear_bytes)) / (1024.0 * 1024.0);
    const gc_cap_mb = @as(f64, @floatFromInt(gc_cap)) / (1024.0 * 1024.0);
    const gc_used_kb = @as(f64, @floatFromInt(gc_used)) / 1024.0;
    const gc_cap_kb = @as(f64, @floatFromInt(gc_cap)) / 1024.0;
    const shared_mb = @as(f64, @floatFromInt(shared_bytes)) / (1024.0 * 1024.0);
    const total_mb = @as(f64, @floatFromInt(total)) / (1024.0 * 1024.0);

    const shared_annotation: []const u8 = if (shared_bytes == 0) "(none)" else "";

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.print(
        "Memory usage:\n" ++
            "  Linear memory:  {d:.2} MB  ({d} pages)\n" ++
            "  GC heap:        {d:.2} MB  (used {d:.1} KB / capacity {d:.1} KB)\n" ++
            "  Shared memory:  {d:.2} MB  {s}\n" ++
            "  \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n" ++
            "  Total:          {d:.2} MB\n",
        .{
            linear_mb,
            linear_pages,
            gc_cap_mb,
            gc_used_kb,
            gc_cap_kb,
            shared_mb,
            shared_annotation,
            total_mb,
        },
    ) catch {};
    std.fs.File.stderr().writeAll(fbs.getWritten()) catch {};
}

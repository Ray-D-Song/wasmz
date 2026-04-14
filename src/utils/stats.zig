const std = @import("std");
const wasmz = @import("wasmz");
const profiling = wasmz.profiling;
const rss = @import("rss.zig");

const Store = wasmz.Store;
const Instance = wasmz.Instance;

pub const MemStatsCtx = struct {
    store: ?*Store = null,
    instance: ?*Instance = null,
};

/// Context for the mem-trace on-exit callback (proc_exit path).
pub const MemTraceCtx = struct {
    label: []const u8 = "proc_exit",
    prev_rss: *usize,
};

pub fn onExitMemTrace(_: u32, data: ?*anyopaque) void {
    if (data) |d| {
        const ctx: *MemTraceCtx = @ptrCast(@alignCast(d));
        const cur = rss.currentRssBytes();
        const cur_mb = @as(f64, @floatFromInt(cur)) / (1024.0 * 1024.0);
        const delta_bytes: i64 = @as(i64, @intCast(cur)) - @as(i64, @intCast(ctx.prev_rss.*));
        const delta_mb = @as(f64, @floatFromInt(delta_bytes)) / (1024.0 * 1024.0);
        const sign: []const u8 = if (delta_bytes >= 0) "+" else "";
        std.debug.print(
            "[mem-trace] {s:<22}  RSS {d:.1} MB  ({s}{d:.1} MB)\n",
            .{ ctx.label, cur_mb, sign, delta_mb },
        );
        ctx.prev_rss.* = cur;
    }
}

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

/// Combined on-exit context: handles mem-trace + mem-stats + profiling in
/// a single proc_exit callback so only one setOnExit slot is needed.
pub const OnExitCtx = struct {
    // mem-trace
    mem_trace: bool = false,
    trace_label: []const u8 = "proc_exit (_start)",
    prev_rss: ?*usize = null,
    // mem-stats
    mem_stats: bool = false,
    store: ?*Store = null,
    instance: ?*Instance = null,
    // profiling
    do_profiling: bool = false,
};

pub fn onExitCombined(_: u32, data: ?*anyopaque) void {
    if (data == null) return;
    const ctx: *OnExitCtx = @ptrCast(@alignCast(data.?));
    if (ctx.do_profiling) profiling.printReport();
    if (ctx.mem_stats) {
        if (ctx.store != null and ctx.instance != null)
            printMemStats(ctx.store.?, ctx.instance.?);
    }
    if (ctx.mem_trace) {
        if (ctx.prev_rss) |prev| {
            const cur = rss.currentRssBytes();
            const cur_mb = @as(f64, @floatFromInt(cur)) / (1024.0 * 1024.0);
            const delta_bytes: i64 = @as(i64, @intCast(cur)) - @as(i64, @intCast(prev.*));
            const delta_mb = @as(f64, @floatFromInt(delta_bytes)) / (1024.0 * 1024.0);
            const sign: []const u8 = if (delta_bytes >= 0) "+" else "";
            std.debug.print(
                "[mem-trace] {s:<22}  RSS {d:.1} MB  ({s}{d:.1} MB)\n",
                .{ ctx.trace_label, cur_mb, sign, delta_mb },
            );
            prev.* = cur;
        }
    }
}

pub fn printMemStats(store: *Store, instance: *Instance) void {
    // ── runtime memory (store / instance) ────────────────────────────────────
    const linear_bytes = instance.memory.byteLen();
    const linear_pages = instance.memory.pageCount();
    const gc_used = store.gc_heap.usedSize();
    const gc_cap = store.gc_heap.totalSize();
    const shared_bytes = store.memory_budget.shared_bytes;

    // ── VM stacks ─────────────────────────────────────────────────────────────
    const vm = instance.vmMemStats();

    // ── module memory ─────────────────────────────────────────────────────────
    const ms = instance.module.value.memStats();

    // ── totals ────────────────────────────────────────────────────────────────
    const runtime_total = linear_bytes + gc_cap + shared_bytes +
        vm.val_stack_bytes + vm.call_stack_bytes;
    const module_total = ms.total();
    const grand_total = runtime_total + module_total;

    // ── formatting helpers ────────────────────────────────────────────────────
    const mb = struct {
        fn f(b: usize) f64 {
            return @as(f64, @floatFromInt(b)) / (1024.0 * 1024.0);
        }
    }.f;
    const kb = struct {
        fn f(b: usize) f64 {
            return @as(f64, @floatFromInt(b)) / 1024.0;
        }
    }.f;

    const shared_annotation: []const u8 = if (shared_bytes == 0) "(none)" else "";

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.print(
        \\Memory usage:
        \\
        \\  Runtime
        \\  ─────────────────────────────────────────
        \\  Linear memory:     {d:.2} MB  ({d} pages)
        \\  GC heap:           {d:.2} MB  (used {d:.1} KB / cap {d:.1} KB)
        \\  Shared memory:     {d:.2} MB  {s}
        \\  VM val_stack:      {d:.2} MB  ({d} slots)
        \\  VM call_stack:     {d:.2} MB  ({d} frames)
        \\  ─────────────────────────────────────────
        \\  Runtime subtotal:  {d:.2} MB
        \\
        \\  Module
        \\  ─────────────────────────────────────────
        \\  Pending bodies:    {d:.2} MB  ({d} funcs, raw Wasm bytecode)
        \\  Encoded code:      {d:.2} MB  ({d} funcs, threaded-dispatch)
        \\  Encoded aux:       {d:.1} KB  (br_table / eh tables)
        \\  Data segments:     {d:.2} MB  (passive only after instantiation)
        \\  ─────────────────────────────────────────
        \\  Module subtotal:   {d:.2} MB
        \\
        \\  ═════════════════════════════════════════
        \\  Grand total:       {d:.2} MB
        \\
    ,
        .{
            // Runtime
            mb(linear_bytes),          linear_pages,
            mb(gc_cap),                kb(gc_used),
            kb(gc_cap),                mb(shared_bytes),
            shared_annotation,         mb(vm.val_stack_bytes),
            vm.val_stack_slots,        mb(vm.call_stack_bytes),
            vm.call_stack_frames,      mb(runtime_total),
            // Module
            mb(ms.pending_body_bytes), ms.pending_count,
            mb(ms.encoded_code_bytes), ms.encoded_count,
            kb(ms.encoded_aux_bytes),  mb(ms.data_segment_bytes),
            mb(module_total),
            // Grand total
                     mb(grand_total),
        },
    ) catch {};
    std.fs.File.stderr().writeAll(fbs.getWritten()) catch {};
}

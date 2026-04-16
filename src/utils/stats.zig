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

pub const PhaseDiagCtx = struct {
    enabled: bool = false,
    t0_ns: i128 = 0,
    after_mmap_ns: i128 = 0,
    after_compile_ns: i128 = 0,
    after_store_ns: i128 = 0,
    after_instantiate_ns: i128 = 0,
    after_run_start_ns: i128 = 0,
    enter_start_ns: i128 = 0,
    after_start_ns: i128 = 0,
};

inline fn nsToMs(delta_ns: i128) f64 {
    if (delta_ns <= 0) return 0.0;
    return @as(f64, @floatFromInt(delta_ns)) / 1_000_000.0;
}

pub fn printPhaseDiag(ctx: *const PhaseDiagCtx, reason: []const u8) void {
    if (!ctx.enabled) return;

    const now_ns = std.time.nanoTimestamp();
    const mmap_done = if (ctx.after_mmap_ns != 0) ctx.after_mmap_ns else now_ns;
    const compile_done = if (ctx.after_compile_ns != 0) ctx.after_compile_ns else now_ns;
    const store_done = if (ctx.after_store_ns != 0) ctx.after_store_ns else now_ns;
    const instantiate_done = if (ctx.after_instantiate_ns != 0) ctx.after_instantiate_ns else now_ns;
    const run_start_done = if (ctx.after_run_start_ns != 0) ctx.after_run_start_ns else now_ns;
    const start_enter = if (ctx.enter_start_ns != 0) ctx.enter_start_ns else now_ns;
    const start_done = if (ctx.after_start_ns != 0) ctx.after_start_ns else now_ns;

    std.debug.print(
        \\[phase-diag] wasmz exit={s}
        \\[phase-diag]   open+mmap     : {d:8.3} ms
        \\[phase-diag]   compile       : {d:8.3} ms
        \\[phase-diag]   store+linker  : {d:8.3} ms
        \\[phase-diag]   instantiate   : {d:8.3} ms
        \\[phase-diag]   runStart      : {d:8.3} ms
        \\[phase-diag]   _start        : {d:8.3} ms
        \\[phase-diag]   total         : {d:8.3} ms
        \\
    , .{
        reason,
        nsToMs(mmap_done - ctx.t0_ns),
        nsToMs(compile_done - mmap_done),
        nsToMs(store_done - compile_done),
        nsToMs(instantiate_done - store_done),
        nsToMs(run_start_done - instantiate_done),
        nsToMs(start_done - start_enter),
        nsToMs(start_done - ctx.t0_ns),
    });
}

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
    // phase timing
    phase_diag: ?*const PhaseDiagCtx = null,
};

pub fn onExitCombined(exit_code: u32, data: ?*anyopaque) void {
    if (data == null) return;
    const ctx: *OnExitCtx = @ptrCast(@alignCast(data.?));
    if (ctx.phase_diag) |diag| {
        var reason_buf: [32]u8 = undefined;
        const reason = std.fmt.bufPrint(&reason_buf, "proc_exit({d})", .{exit_code}) catch "proc_exit";
        printPhaseDiag(diag, reason);
    }
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
    const gc_heap = store.gc_heap;
    const gc_used = if (gc_heap) |h| h.usedSize() else 0;
    const gc_cap = if (gc_heap) |h| h.totalSize() else 0;
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

    // ── allocation counts ─────────────────────────────────────────────────────
    const gc_alloc_count = if (gc_heap) |h| h.alloc_count else 0;
    const vm_alloc_count = vm.vm_alloc_count;
    const instance_alloc_count = instance.alloc_count;
    const total_alloc_count = gc_alloc_count + vm_alloc_count + instance_alloc_count;

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
        \\  Allocations
        \\  ─────────────────────────────────────────
        \\  Instance:           {d}
        \\  VM (val/call stack): {d}
        \\  GC heap:            {d}
        \\  ─────────────────────────────────────────
        \\  Total:              {d}
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
            // Allocation counts
            instance_alloc_count,      vm_alloc_count,
            gc_alloc_count,            total_alloc_count,
        },
    ) catch {};
    std.fs.File.stderr().writeAll(fbs.getWritten()) catch {};
}

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

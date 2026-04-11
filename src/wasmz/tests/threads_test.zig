/// threads_test.zig – Phase F end-to-end multi-thread integration test.
///
/// Scenario
/// --------
/// Two OS threads each hold a separate Instance that shares a single
/// SharedMemory region.  They communicate through the Wasm linear memory:
///
///   Thread A  — calls `wait(expected=0, timeout=-1)` which parks on
///               memory.atomic.wait32 at address 0 until notified.
///
///   Main      — sleeps briefly, then calls `set(42)` (atomic store) and
///               `notify(1)` to wake Thread A.
///
///   Expected  — Thread A returns from `wait` with result 0 (ok / woken).
///               `get()` on the main-thread instance reads back 42.
///
/// The Wasm module was compiled from:
///
///   (module
///     (memory (export "mem") 1 2 shared)
///     (func (export "get") (result i32)
///       i32.const 0
///       i32.atomic.load)
///     (func (export "set") (param i32)
///       i32.const 0
///       local.get 0
///       i32.atomic.store)
///     (func (export "wait") (param i32 i64) (result i32)
///       i32.const 0
///       local.get 0
///       local.get 1
///       memory.atomic.wait32)
///     (func (export "notify") (param i32) (result i32)
///       i32.const 0
///       local.get 0
///       memory.atomic.notify)
///   )
const std = @import("std");
const testing = std.testing;

const engine_mod = @import("../../engine/root.zig");
const config_mod = @import("../../engine/config.zig");
const store_mod = @import("../store.zig");
const module_mod = @import("../module.zig");
const instance_mod = @import("../instance.zig");
const core = @import("core");

const Store = store_mod.Store;
const Module = module_mod.Module;
const ArcModule = module_mod.ArcModule;
const Instance = instance_mod.Instance;
const Linker = instance_mod.Linker;
const RawVal = instance_mod.RawVal;
const SharedMemory = core.SharedMemory;
const WASM_PAGE_SIZE = core.WASM_PAGE_SIZE;

/// Wasm module with shared memory + atomic get/set/wait/notify.
/// Produced by: wat2wasm --enable-threads threaded.wat
const THREADED_WASM = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x14, 0x04, 0x60,
    0x00, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x02, 0x7f, 0x7e, 0x01,
    0x7f, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x03, 0x05, 0x04, 0x00, 0x01, 0x02,
    0x03, 0x05, 0x04, 0x01, 0x03, 0x01, 0x02, 0x07, 0x23, 0x05, 0x03, 0x6d,
    0x65, 0x6d, 0x02, 0x00, 0x03, 0x67, 0x65, 0x74, 0x00, 0x00, 0x03, 0x73,
    0x65, 0x74, 0x00, 0x01, 0x04, 0x77, 0x61, 0x69, 0x74, 0x00, 0x02, 0x06,
    0x6e, 0x6f, 0x74, 0x69, 0x66, 0x79, 0x00, 0x03, 0x0a, 0x2d, 0x04, 0x08,
    0x00, 0x41, 0x00, 0xfe, 0x10, 0x02, 0x00, 0x0b, 0x0a, 0x00, 0x41, 0x00,
    0x20, 0x00, 0xfe, 0x17, 0x02, 0x00, 0x0b, 0x0c, 0x00, 0x41, 0x00, 0x20,
    0x00, 0x20, 0x01, 0xfe, 0x01, 0x02, 0x00, 0x0b, 0x0a, 0x00, 0x41, 0x00,
    0x20, 0x00, 0xfe, 0x00, 0x02, 0x00, 0x0b,
};

// ── Helper: thread context ────────────────────────────────────────────────────

const WaiterCtx = struct {
    /// Result from `wait(expected=0, timeout=-1)`: 0=ok, 1=not_equal, 2=timed_out.
    result: std.atomic.Value(i32),
    /// Pointer to the waiter's own Instance (allocated on the calling stack).
    instance_ptr: *Instance,

    fn run(ctx: *WaiterCtx) void {
        // wait(expected=0, timeout=-1 meaning infinite)
        const args = [_]RawVal{
            RawVal.from(@as(i32, 0)), // expected
            RawVal.from(@as(i64, -1)), // timeout (negative = infinite)
        };
        const exec_r = ctx.instance_ptr.call("wait", &args) catch {
            ctx.result.store(-1, .release);
            return;
        };
        const val = switch (exec_r) {
            .ok => |v| if (v) |rv| rv.readAs(i32) else -1,
            .trap => -2,
        };
        ctx.result.store(val, .release);
    }
};

// ── Test ──────────────────────────────────────────────────────────────────────

test "multi-thread: shared memory wait/notify round-trip via Wasm instance" {
    const allocator = testing.allocator;

    var engine = try engine_mod.Engine.init(allocator, config_mod.Config{});
    defer engine.deinit();

    // Compile the threaded module once; both instances share a Module reference.
    var arc = try Module.compileArc(engine, &THREADED_WASM);
    defer if (arc.releaseUnwrap()) |m| {
        var mm = m;
        mm.deinit();
    };

    // Create a single SharedMemory to be shared by both instances.
    // The module declares min=1 max=2 shared, so capacity must be >= 2 pages.
    var shared = try SharedMemory.init(allocator, 1, 2);
    defer shared.deinit();

    // ── Store A (waiter thread) ───────────────────────────────────────────────
    var store_a = try Store.init(allocator, engine);
    defer store_a.deinit();
    var instance_a = try Instance.initWithSharedMemory(&store_a, arc.retain(), Linker.empty, shared);
    defer instance_a.deinit();

    // ── Store B (main thread notifier) ────────────────────────────────────────
    var store_b = try Store.init(allocator, engine);
    defer store_b.deinit();
    var instance_b = try Instance.initWithSharedMemory(&store_b, arc.retain(), Linker.empty, shared);
    defer instance_b.deinit();

    // ── Spawn waiter thread ───────────────────────────────────────────────────
    var ctx = WaiterCtx{
        .result = std.atomic.Value(i32).init(-99),
        .instance_ptr = &instance_a,
    };
    const waiter = try std.Thread.spawn(.{}, WaiterCtx.run, .{&ctx});

    // Give the waiter time to park inside wait32.
    std.Thread.sleep(20 * std.time.ns_per_ms);

    // ── Main thread: set value then notify ────────────────────────────────────
    const set_args = [_]RawVal{RawVal.from(@as(i32, 42))};
    const set_r = try instance_b.call("set", &set_args);
    try testing.expect(set_r == .ok);

    const notify_args = [_]RawVal{RawVal.from(@as(i32, 1))};
    const notify_r = try instance_b.call("notify", &notify_args);
    const woken = switch (notify_r) {
        .ok => |v| if (v) |rv| rv.readAs(i32) else 0,
        .trap => -1,
    };

    waiter.join();

    // ── Verify results ────────────────────────────────────────────────────────

    // notify should have woken exactly 1 waiter.
    try testing.expectEqual(@as(i32, 1), woken);

    // The waiter should have returned 0 ("ok" — woken by notify, not mismatch/timeout).
    try testing.expectEqual(@as(i32, 0), ctx.result.load(.acquire));

    // Reading back the value from instance_b should show 42.
    const get_r = try instance_b.call("get", &[_]RawVal{});
    const got = switch (get_r) {
        .ok => |v| if (v) |rv| rv.readAs(i32) else -1,
        .trap => -2,
    };
    try testing.expectEqual(@as(i32, 42), got);
}

// ── Bonus: memory.size and memory.grow integration ───────────────────────────

test "memory.size returns current page count" {
    const allocator = testing.allocator;

    var engine = try engine_mod.Engine.init(allocator, config_mod.Config{});
    defer engine.deinit();

    var arc = try Module.compileArc(engine, &THREADED_WASM);
    defer if (arc.releaseUnwrap()) |m| {
        var mm = m;
        mm.deinit();
    };

    var shared = try SharedMemory.init(allocator, 1, 2);
    defer shared.deinit();

    var store = try Store.init(allocator, engine);
    defer store.deinit();

    var instance = try Instance.initWithSharedMemory(&store, arc.retain(), Linker.empty, shared);
    defer instance.deinit();

    // Verify we started with 1 page.
    try testing.expectEqual(@as(u32, 1), instance.memory.pageCount());
}

test "SharedMemory.grow atomically advances current_size" {
    var sm = try SharedMemory.init(testing.allocator, 1, 4);
    defer sm.deinit();

    try testing.expectEqual(@as(usize, WASM_PAGE_SIZE), sm.bytes().len);

    const old = sm.grow(2);
    try testing.expectEqual(@as(u32, 1), old); // old page count was 1
    try testing.expectEqual(@as(usize, 3 * WASM_PAGE_SIZE), sm.bytes().len);

    // Cannot exceed max (4 pages), so grow by 2 more should fail.
    const fail = sm.grow(2);
    try testing.expectEqual(std.math.maxInt(u32), fail);
    try testing.expectEqual(@as(usize, 3 * WASM_PAGE_SIZE), sm.bytes().len);
}

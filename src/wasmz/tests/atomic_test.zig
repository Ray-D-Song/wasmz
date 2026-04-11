/// atomic_test.zig – Tests for Phase E: wait / notify on shared memory.
///
/// Coverage:
///   1. Memory.notify on non-shared memory → 0 woken
///   2. Memory.wait32/64 on non-shared memory → .not_equal immediately
///   3. SharedMemory.notify with no waiters → 0
///   4. SharedMemory.wait32 with mismatched value → .not_equal immediately
///   5. SharedMemory.wait64 with mismatched value → .not_equal immediately
///   6. SharedMemory.wait32 with zero timeout → .timed_out (value matches, but instant timeout)
///   7. wait32 / notify round-trip across two OS threads
const std = @import("std");
const testing = std.testing;
const core = @import("core");

const Memory = core.Memory;
const SharedMemory = core.SharedMemory;
const WaitResult = core.WaitResult;
const WASM_PAGE_SIZE = core.WASM_PAGE_SIZE;

// ── 1. notify on non-shared memory ───────────────────────────────────────────

test "Memory.notify on owned memory returns 0" {
    var mem = try Memory.initOwned(testing.allocator, 1);
    defer mem.deinit();
    const woken = mem.notify(0, 10);
    try testing.expectEqual(@as(u32, 0), woken);
}

// ── 2. wait on non-shared memory ─────────────────────────────────────────────

test "Memory.wait32 on owned memory returns not_equal" {
    var mem = try Memory.initOwned(testing.allocator, 1);
    defer mem.deinit();
    const result = mem.wait32(0, 0, -1);
    try testing.expectEqual(WaitResult.not_equal, result);
}

test "Memory.wait64 on owned memory returns not_equal" {
    var mem = try Memory.initOwned(testing.allocator, 1);
    defer mem.deinit();
    const result = mem.wait64(0, 0, -1);
    try testing.expectEqual(WaitResult.not_equal, result);
}

// ── 3. notify with no waiters ─────────────────────────────────────────────────

test "SharedMemory.notify with no waiters returns 0" {
    var sm = try SharedMemory.init(testing.allocator, 1, 2);
    defer sm.deinit();
    const woken = sm.notify(0, 10);
    try testing.expectEqual(@as(u32, 0), woken);
}

// ── 4. wait32 – mismatched value ──────────────────────────────────────────────

test "SharedMemory.wait32 returns not_equal when value differs" {
    var sm = try SharedMemory.init(testing.allocator, 1, 2);
    defer sm.deinit();

    // mem[0] is 0; we wait for value 99 → mismatch detected under the lock.
    const result = sm.wait32(0, 99, -1);
    try testing.expectEqual(WaitResult.not_equal, result);
}

// ── 5. wait64 – mismatched value ──────────────────────────────────────────────

test "SharedMemory.wait64 returns not_equal when value differs" {
    var sm = try SharedMemory.init(testing.allocator, 1, 2);
    defer sm.deinit();

    const result = sm.wait64(0, 0xDEADBEEF_CAFEBABE, -1);
    try testing.expectEqual(WaitResult.not_equal, result);
}

// ── 6. wait32 – zero timeout → timed_out ─────────────────────────────────────

test "SharedMemory.wait32 with zero timeout and matching value returns timed_out" {
    var sm = try SharedMemory.init(testing.allocator, 1, 2);
    defer sm.deinit();

    // Value matches (both 0); use a 0-nanosecond timeout so we never truly block.
    const result = sm.wait32(0, 0, 0);
    try testing.expectEqual(WaitResult.timed_out, result);
}

// ── 7. Cross-thread wait32 / notify round-trip ────────────────────────────────
//
// Thread A: wait32 on address 0, expected value 0, no timeout
// Main thread: sleep a little, write 1 to address 0, then notify
// Expected: Thread A wakes with result .ok
//
// We use a second atomic flag so the main thread can verify Thread A woke up.

const WaitCtx = struct {
    sm: *SharedMemory,
    result: std.atomic.Value(i32),

    fn run(ctx: *WaitCtx) void {
        // addr=0, expected=0, infinite timeout
        const r = ctx.sm.wait32(0, 0, -1);
        ctx.result.store(@intFromEnum(r), .release);
    }
};

test "SharedMemory wait32/notify cross-thread round-trip" {
    var sm = try SharedMemory.init(testing.allocator, 1, 2);
    defer sm.deinit();

    var ctx = WaitCtx{
        .sm = &sm,
        .result = std.atomic.Value(i32).init(-1),
    };

    const thread = try std.Thread.spawn(.{}, WaitCtx.run, .{&ctx});

    // Give the waiter thread time to park inside wait32.
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Write a non-zero value so wait32 re-checks and sees a change, then notify.
    const mem_bytes = sm.bytes();
    @atomicStore(u32, @as(*u32, @ptrCast(@alignCast(mem_bytes.ptr))), 1, .seq_cst);
    const woken = sm.notify(0, 1);

    thread.join();

    // Exactly one waiter should have been woken.
    try testing.expectEqual(@as(u32, 1), woken);
    // The waiter returns .ok (it was woken by notify, not a value mismatch).
    try testing.expectEqual(@as(i32, @intFromEnum(WaitResult.ok)), ctx.result.load(.acquire));
}

/// profiling.zig — Conditional call-phase profiling utilities.
///
/// When `profiling` is enabled (via `-Dprofiling=true`), this module provides
/// a `ScopedTimer` that accumulates nanoseconds into `CallProfiling` counters
/// and a `printReport` function that dumps a summary to stderr.
///
/// When profiling is disabled (the default), every API compiles to a no-op
/// with zero runtime cost.
const std = @import("std");
const build_options = @import("build_options");

pub const enabled = build_options.profiling;

// ── Call profiling counters ──────────────────────────────────────────────────

pub const CallProfiling = struct {
    calls: u64 = 0,
    ns_read_ops: u64 = 0,
    ns_alloc_slots: u64 = 0,
    ns_copy_args: u64 = 0,
    ns_push_dispatch: u64 = 0,

    pub fn total(self: CallProfiling) u64 {
        return self.ns_read_ops + self.ns_alloc_slots + self.ns_copy_args + self.ns_push_dispatch;
    }
};

pub var call_prof: CallProfiling = .{};

// ── Scoped timer ─────────────────────────────────────────────────────────────

/// A lightweight lap timer that accumulates into `CallProfiling` fields.
/// When profiling is disabled the struct is zero-sized and all methods are no-ops.
pub const ScopedTimer = if (enabled) struct {
    timer: std.time.Timer,

    pub fn start() @This() {
        return .{ .timer = std.time.Timer.start() catch unreachable };
    }

    pub inline fn lap(self: *@This(), dest: *u64) void {
        dest.* += self.timer.lap();
    }
} else struct {
    pub inline fn start() @This() {
        return .{};
    }

    pub inline fn lap(self: *@This(), _: *u64) void {
        _ = self;
    }
};

// ── Report ───────────────────────────────────────────────────────────────────

pub fn printReport() void {
    if (!enabled) return;

    const c = call_prof;
    if (c.calls == 0) return;
    const t = c.total();
    std.debug.print(
        \\
        \\=== handle_call profiling ({d} local calls) ===
        \\  read_ops + top + slice : {d:>10} ns  ({d:.1}%)
        \\  allocCalleeSlots       : {d:>10} ns  ({d:.1}%)
        \\  copy args              : {d:>10} ns  ({d:.1}%)
        \\  push + dispatch        : {d:>10} ns  ({d:.1}%)
        \\  TOTAL measured         : {d:>10} ns
        \\  avg per call           : {d:.1} ns
        \\
    , .{
        c.calls,
        c.ns_read_ops,
        pct(c.ns_read_ops, t),
        c.ns_alloc_slots,
        pct(c.ns_alloc_slots, t),
        c.ns_copy_args,
        pct(c.ns_copy_args, t),
        c.ns_push_dispatch,
        pct(c.ns_push_dispatch, t),
        t,
        if (c.calls > 0) @as(f64, @floatFromInt(t)) / @as(f64, @floatFromInt(c.calls)) else 0.0,
    });
}

inline fn pct(part: u64, total: u64) f64 {
    if (total == 0) return 0.0;
    return @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(total)) * 100.0;
}

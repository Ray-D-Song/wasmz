const std = @import("std");
const Io = std.Io;
const core = @import("core");
const wasmz = @import("wasmz");
const types = @import("./types.zig");

const RawVal = core.RawVal;
const HostContext = wasmz.HostContext;

pub const ClockSource = struct {
    ctx: ?*anyopaque = null,
    now_fn: *const fn (?*anyopaque) u64,
    resolution_ns: u64 = 1,

    pub fn realtime() ClockSource {
        return .{ .now_fn = default_realtime_now, .resolution_ns = 1 };
    }

    pub fn monotonic() ClockSource {
        return .{ .now_fn = default_monotonic_now, .resolution_ns = 1 };
    }

    pub fn now(self: ClockSource) u64 {
        return self.now_fn(self.ctx);
    }

    fn getIo() Io {
        var t: Io.Threaded = .init_single_threaded;
        return t.io();
    }

    fn default_realtime_now(_: ?*anyopaque) u64 {
        const ts = Io.Timestamp.now(getIo(), .real);
        return @intCast(@max(ts.nanoseconds, 0));
    }

    fn default_monotonic_now(_: ?*anyopaque) u64 {
        const ts = Io.Timestamp.now(getIo(), .awake);
        return @intCast(@max(ts.nanoseconds, 0));
    }
};

pub const Clock = struct {
    realtime: ClockSource,
    monotonic: ClockSource,

    pub fn init() Clock {
        return .{
            .realtime = ClockSource.realtime(),
            .monotonic = ClockSource.monotonic(),
        };
    }

    pub fn setRealtime(self: *Clock, source: ClockSource) void {
        self.realtime = source;
    }

    pub fn setMonotonic(self: *Clock, source: ClockSource) void {
        self.monotonic = source;
    }

    pub fn clockResGet(self: *Clock, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const resolution = switch (clockId(params[0])) {
            .realtime => self.realtime.resolution_ns,
            .monotonic => self.monotonic.resolution_ns,
            else => {
                types.writeErrno(results, .inval);
                return;
            },
        };
        try ctx.writeValue(params[1].readAs(u32), resolution);
        types.writeErrno(results, .success);
    }

    pub fn clockTimeGet(self: *Clock, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        _ = params[1].readAs(u64);

        const now = switch (clockId(params[0])) {
            .realtime => self.realtime.now(),
            .monotonic => self.monotonic.now(),
            else => {
                types.writeErrno(results, .inval);
                return;
            },
        };
        try ctx.writeValue(params[2].readAs(u32), now);
        types.writeErrno(results, .success);
    }
};

fn clockId(raw: RawVal) types.ClockId {
    return std.enums.fromInt(types.ClockId, raw.readAs(u32)) orelse .thread_cputime_id;
}

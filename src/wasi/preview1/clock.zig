const core = @import("core");
const wasmz = @import("wasmz");
const host_root = @import("./host.zig");
const types = @import("./types.zig");

const RawVal = core.RawVal;
const HostContext = wasmz.HostContext;

pub fn clockResGet(self: *host_root.Host, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const resolution = switch (clockId(params[0])) {
        .realtime => self.realtime_clock.resolution_ns,
        .monotonic => self.monotonic_clock.resolution_ns,
        else => {
            types.writeErrno(results, .inval);
            return;
        },
    };
    try ctx.writeValue(params[1].readAs(u32), resolution);
    types.writeErrno(results, .success);
}

pub fn clockTimeGet(self: *host_root.Host, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    _ = params[1].readAs(u64); // precision is accepted but unused for the minimal host.

    const now = switch (clockId(params[0])) {
        .realtime => self.realtime_clock.now(),
        .monotonic => self.monotonic_clock.now(),
        else => {
            types.writeErrno(results, .inval);
            return;
        },
    };
    try ctx.writeValue(params[2].readAs(u32), now);
    types.writeErrno(results, .success);
}

fn clockId(raw: RawVal) types.ClockId {
    return std.meta.intToEnum(types.ClockId, raw.readAs(u32)) catch .thread_cputime_id;
}

const std = @import("std");

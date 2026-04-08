const core = @import("core");
const wasmz = @import("wasmz");
const host_root = @import("./host.zig");
const types = @import("./types.zig");

const RawVal = core.RawVal;
const HostContext = wasmz.HostContext;

pub fn fdWrite(self: *host_root.Host, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const fd = params[0].readAs(u32);
    const iovs_ptr = params[1].readAs(u32);
    const iovs_len = params[2].readAs(u32);
    const nwritten_ptr = params[3].readAs(u32);

    const output = switch (fd) {
        1 => &self.stdout,
        2 => &self.stderr,
        else => {
            types.writeErrno(results, .badf);
            return;
        },
    };

    const iovs = try ctx.readSlice(iovs_ptr, iovs_len, types.Ciovec);
    var total_written: u32 = 0;
    for (iovs) |iov| {
        const bytes = try ctx.readBytes(iov.buf, iov.buf_len);
        output.writeAll(bytes) catch {
            types.writeErrno(results, .io);
            return;
        };
        total_written +%= iov.buf_len;
    }

    try ctx.writeValue(nwritten_ptr, total_written);
    types.writeErrno(results, .success);
}

pub fn fdSeek(self: *host_root.Host, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    _ = self;
    const fd = params[0].readAs(u32);
    const offset = params[1].readAs(i64);
    const whence: types.Whence = @enumFromInt(params[2].readAs(u32));
    const newoffset_ptr = params[3].readAs(u32);

    _ = offset;
    _ = whence;

    const result: i64 = result: {
        switch (fd) {
            0, 1, 2 => break :result -1,
            else => break :result -1,
        }
    };

    if (result < 0) {
        types.writeErrno(results, .spi);
        return;
    }

    try ctx.writeValue(newoffset_ptr, @as(u64, @intCast(result)));
    types.writeErrno(results, .success);
}

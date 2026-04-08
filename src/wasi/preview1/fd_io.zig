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

pub fn fdFilestatGet(self: *host_root.Host, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    _ = self;
    const fd = params[0].readAs(u32);
    const buf_ptr = params[1].readAs(u32);

    const stat: types.Filestat = switch (fd) {
        0 => .{
            .dev = 0,
            .ino = 0,
            .filetype = .character_device,
            .nlink = 1,
            .size = 0,
            .atim = 0,
            .mtim = 0,
            .ctim = 0,
        },
        1, 2 => .{
            .dev = 0,
            .ino = fd,
            .filetype = .character_device,
            .nlink = 1,
            .size = 0,
            .atim = 0,
            .mtim = 0,
            .ctim = 0,
        },
        else => {
            types.writeErrno(results, .badf);
            return;
        },
    };

    try ctx.writeBytes(buf_ptr, std.mem.asBytes(&stat));
    types.writeErrno(results, .success);
}

pub fn fdRead(self: *host_root.Host, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    _ = self;
    const fd = params[0].readAs(u32);
    const iovs_ptr = params[1].readAs(u32);
    const iovs_len = params[2].readAs(u32);
    const nread_ptr = params[3].readAs(u32);

    if (fd != 0) {
        types.writeErrno(results, .badf);
        return;
    }

    const iovs = try ctx.readSlice(iovs_ptr, iovs_len, types.Iovec);
    var total_read: u32 = 0;

    for (iovs) |iov| {
        const buf = iov.buf;
        const buf_len = iov.buf_len;
        const guest_mem = ctx.memory() orelse {
            types.writeErrno(results, .fault);
            return;
        };

        if (buf >= guest_mem.len) {
            types.writeErrno(results, .fault);
            return;
        }

        const bytes_to_read = @min(buf_len, @as(u32, @intCast(guest_mem.len - buf)));
        const read_buf = guest_mem[buf .. buf + bytes_to_read];

        const bytes_read = std.fs.File.stdin().read(read_buf) catch {
            types.writeErrno(results, .io);
            return;
        };

        total_read +%= @intCast(bytes_read);
        if (bytes_read < buf_len) break;
    }

    try ctx.writeValue(nread_ptr, total_read);
    types.writeErrno(results, .success);
}

pub fn fdPwrite(self: *host_root.Host, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    _ = self;
    _ = ctx;
    const fd = params[0].readAs(u32);
    const iovs_ptr = params[1].readAs(u32);
    const iovs_len = params[2].readAs(u32);
    const offset = params[3].readAs(i64);
    const nwritten_ptr = params[4].readAs(u32);

    _ = iovs_ptr;
    _ = iovs_len;
    _ = offset;
    _ = nwritten_ptr;

    switch (fd) {
        0, 1, 2 => {
            types.writeErrno(results, .spi);
        },
        else => {
            types.writeErrno(results, .badf);
        },
    }
}

const std = @import("std");

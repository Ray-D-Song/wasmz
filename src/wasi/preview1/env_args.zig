const core = @import("core");
const wasmz = @import("wasmz");
const host_root = @import("./host.zig");
const types = @import("./types.zig");

const RawVal = core.RawVal;
const HostContext = wasmz.HostContext;

pub fn argsSizesGet(self: *host_root.Host, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    try ctx.writeValue(paramsArg(params, 0), @as(types.Size, @intCast(self.args.len)));
    try ctx.writeValue(paramsArg(params, 1), totalByteLen(self.args));
    types.writeErrno(results, .success);
}

pub fn argsGet(self: *host_root.Host, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    try writeStringList(ctx, self.args, paramsArg(params, 0), paramsArg(params, 1));
    types.writeErrno(results, .success);
}

pub fn environSizesGet(self: *host_root.Host, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    try ctx.writeValue(paramsArg(params, 0), @as(types.Size, @intCast(self.env.len)));
    try ctx.writeValue(paramsArg(params, 1), totalEnvByteLen(self.env));
    types.writeErrno(results, .success);
}

pub fn environGet(self: *host_root.Host, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const ptrs_base = paramsArg(params, 0);
    var buf_cursor = paramsArg(params, 1);

    for (self.env, 0..) |entry, index| {
        try ctx.writeValue(ptrs_base + @as(u32, @intCast(index * @sizeOf(u32))), buf_cursor);
        try ctx.writeBytes(buf_cursor, entry.key);
        buf_cursor +%= @as(u32, @intCast(entry.key.len));
        try ctx.writeBytes(buf_cursor, "=");
        buf_cursor +%= 1;
        try ctx.writeBytes(buf_cursor, entry.value);
        buf_cursor +%= @as(u32, @intCast(entry.value.len));
        try ctx.writeBytes(buf_cursor, &[_]u8{0});
        buf_cursor +%= 1;
    }

    types.writeErrno(results, .success);
}

fn writeStringList(ctx: *HostContext, items: []const []const u8, ptrs_base: u32, buf_base: u32) wasmz.HostError!void {
    var buf_cursor = buf_base;
    for (items, 0..) |item, index| {
        try ctx.writeValue(ptrs_base + @as(u32, @intCast(index * @sizeOf(u32))), buf_cursor);
        try ctx.writeBytes(buf_cursor, item);
        buf_cursor +%= @as(u32, @intCast(item.len));
        try ctx.writeBytes(buf_cursor, &[_]u8{0});
        buf_cursor +%= 1;
    }
}

fn totalByteLen(items: []const []const u8) types.Size {
    var total: usize = 0;
    for (items) |item| {
        total += item.len + 1;
    }
    return @intCast(total);
}

fn totalEnvByteLen(items: []const host_root.EnvVar) types.Size {
    var total: usize = 0;
    for (items) |item| {
        total += item.key.len + 1 + item.value.len + 1;
    }
    return @intCast(total);
}

fn paramsArg(params: []const RawVal, index: usize) u32 {
    return params[index].readAs(u32);
}

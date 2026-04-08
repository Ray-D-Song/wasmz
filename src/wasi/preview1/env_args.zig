const std = @import("std");
const core = @import("core");
const wasmz = @import("wasmz");
const types = @import("./types.zig");

const Allocator = std.mem.Allocator;
const RawVal = core.RawVal;
const HostContext = wasmz.HostContext;

pub const EnvVar = struct {
    key: []const u8,
    value: []const u8,
};

pub const EnvArgs = struct {
    args: []const []const u8,
    env: []const EnvVar,
    allocator: Allocator,

    pub fn init(allocator: Allocator) EnvArgs {
        return .{
            .args = &.{},
            .env = &.{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EnvArgs) void {
        freeArgs(self.allocator, self.args);
        freeEnv(self.allocator, self.env);
        self.* = undefined;
    }

    pub fn setArgs(self: *EnvArgs, args: []const []const u8) Allocator.Error!void {
        freeArgs(self.allocator, self.args);
        self.args = try dupStringList(self.allocator, args);
    }

    pub fn setEnv(self: *EnvArgs, env: []const EnvVar) Allocator.Error!void {
        freeEnv(self.allocator, self.env);
        self.env = try dupEnvList(self.allocator, env);
    }

    pub fn argsSizesGet(self: *EnvArgs, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        try ctx.writeValue(paramsArg(params, 0), @as(types.Size, @intCast(self.args.len)));
        try ctx.writeValue(paramsArg(params, 1), totalByteLen(self.args));
        types.writeErrno(results, .success);
    }

    pub fn argsGet(self: *EnvArgs, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        try writeStringList(ctx, self.args, paramsArg(params, 0), paramsArg(params, 1));
        types.writeErrno(results, .success);
    }

    pub fn environSizesGet(self: *EnvArgs, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        try ctx.writeValue(paramsArg(params, 0), @as(types.Size, @intCast(self.env.len)));
        try ctx.writeValue(paramsArg(params, 1), totalEnvByteLen(self.env));
        types.writeErrno(results, .success);
    }

    pub fn environGet(self: *EnvArgs, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
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
};

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

fn totalEnvByteLen(items: []const EnvVar) types.Size {
    var total: usize = 0;
    for (items) |item| {
        total += item.key.len + 1 + item.value.len + 1;
    }
    return @intCast(total);
}

fn paramsArg(params: []const RawVal, index: usize) u32 {
    return params[index].readAs(u32);
}

fn dupStringList(allocator: Allocator, items: []const []const u8) Allocator.Error![]const []const u8 {
    const duped = try allocator.alloc([]const u8, items.len);
    errdefer allocator.free(duped);

    var initialized: usize = 0;
    errdefer {
        for (duped[0..initialized]) |item| allocator.free(item);
    }

    for (items, 0..) |item, index| {
        duped[index] = try allocator.dupe(u8, item);
        initialized += 1;
    }

    return duped;
}

fn freeArgs(allocator: Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn dupEnvList(allocator: Allocator, items: []const EnvVar) Allocator.Error![]const EnvVar {
    const duped = try allocator.alloc(EnvVar, items.len);
    errdefer allocator.free(duped);

    var initialized: usize = 0;
    errdefer {
        for (duped[0..initialized]) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
    }

    for (items, 0..) |item, index| {
        duped[index] = .{
            .key = try allocator.dupe(u8, item.key),
            .value = try allocator.dupe(u8, item.value),
        };
        initialized += 1;
    }

    return duped;
}

fn freeEnv(allocator: Allocator, items: []const EnvVar) void {
    for (items) |entry| {
        allocator.free(entry.key);
        allocator.free(entry.value);
    }
    allocator.free(items);
}

const std = @import("std");
const core = @import("core");
const wasmz = @import("wasmz");
const types = @import("./types.zig");
const env_args = @import("./env_args.zig");
const clock = @import("./clock.zig");
const fd_io = @import("./fd_io.zig");

const Allocator = std.mem.Allocator;
const RawVal = core.RawVal;
const ValType = core.ValType;
const Linker = wasmz.Linker;
const HostContext = wasmz.HostContext;

pub const WriteError = error{Io};

pub const Output = struct {
    ctx: ?*anyopaque,
    write_fn: *const fn (?*anyopaque, bytes: []const u8) WriteError!void,

    pub fn stdout() Output {
        return .{ .ctx = null, .write_fn = write_stdout };
    }

    pub fn stderr() Output {
        return .{ .ctx = null, .write_fn = write_stderr };
    }

    pub fn writeAll(self: Output, bytes: []const u8) WriteError!void {
        return self.write_fn(self.ctx, bytes);
    }

    fn write_stdout(_: ?*anyopaque, bytes: []const u8) WriteError!void {
        std.fs.File.stdout().writeAll(bytes) catch return error.Io;
    }

    fn write_stderr(_: ?*anyopaque, bytes: []const u8) WriteError!void {
        std.fs.File.stderr().writeAll(bytes) catch return error.Io;
    }
};

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

    fn default_realtime_now(_: ?*anyopaque) u64 {
        const ts = std.time.nanoTimestamp();
        return @intCast(@max(ts, 0));
    }

    fn default_monotonic_now(_: ?*anyopaque) u64 {
        const ts = std.time.nanoTimestamp();
        return @intCast(@max(ts, 0));
    }
};

pub const EnvVar = struct {
    key: []const u8,
    value: []const u8,
};

pub const Host = struct {
    allocator: Allocator,
    args: []const []const u8,
    env: []const EnvVar,
    stdout: Output,
    stderr: Output,
    realtime_clock: ClockSource,
    monotonic_clock: ClockSource,

    pub fn init(allocator: Allocator) Host {
        return .{
            .allocator = allocator,
            .args = &.{},
            .env = &.{},
            .stdout = Output.stdout(),
            .stderr = Output.stderr(),
            .realtime_clock = ClockSource.realtime(),
            .monotonic_clock = ClockSource.monotonic(),
        };
    }

    pub fn deinit(self: *Host) void {
        freeArgs(self.allocator, self.args);
        freeEnv(self.allocator, self.env);
        self.* = undefined;
    }

    pub fn setArgs(self: *Host, args: []const []const u8) Allocator.Error!void {
        freeArgs(self.allocator, self.args);
        self.args = try dupStringList(self.allocator, args);
    }

    pub fn setEnv(self: *Host, env: []const EnvVar) Allocator.Error!void {
        freeEnv(self.allocator, self.env);
        self.env = try dupEnvList(self.allocator, env);
    }

    pub fn setStdout(self: *Host, output: Output) void {
        self.stdout = output;
    }

    pub fn setStderr(self: *Host, output: Output) void {
        self.stderr = output;
    }

    pub fn addToLinker(self: *Host, linker: *Linker, allocator: Allocator) Allocator.Error!void {
        try linker.define(allocator, types.module_name, "args_sizes_get", HostFunc.init(
            self,
            argsSizesGet,
            &[_]ValType{ .I32, .I32 },
            &[_]ValType{.I32},
        ));
        try linker.define(allocator, types.module_name, "args_get", HostFunc.init(
            self,
            argsGet,
            &[_]ValType{ .I32, .I32 },
            &[_]ValType{.I32},
        ));
        try linker.define(allocator, types.module_name, "environ_sizes_get", HostFunc.init(
            self,
            environSizesGet,
            &[_]ValType{ .I32, .I32 },
            &[_]ValType{.I32},
        ));
        try linker.define(allocator, types.module_name, "environ_get", HostFunc.init(
            self,
            environGet,
            &[_]ValType{ .I32, .I32 },
            &[_]ValType{.I32},
        ));
        try linker.define(allocator, types.module_name, "clock_res_get", HostFunc.init(
            self,
            clockResGet,
            &[_]ValType{ .I32, .I32 },
            &[_]ValType{.I32},
        ));
        try linker.define(allocator, types.module_name, "clock_time_get", HostFunc.init(
            self,
            clockTimeGet,
            &[_]ValType{ .I32, .I64, .I32 },
            &[_]ValType{.I32},
        ));
        try linker.define(allocator, types.module_name, "fd_write", HostFunc.init(
            self,
            fdWrite,
            &[_]ValType{ .I32, .I32, .I32, .I32 },
            &[_]ValType{.I32},
        ));
        try linker.define(allocator, types.module_name, "fd_seek", HostFunc.init(
            self,
            fdSeek,
            &[_]ValType{ .I32, .I64, .I32, .I32 },
            &[_]ValType{.I32},
        ));
    }
};

const HostFunc = wasmz.HostFunc;

fn argsSizesGet(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    return env_args.argsSizesGet(castHost(host_data), ctx, params, results);
}

fn argsGet(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    return env_args.argsGet(castHost(host_data), ctx, params, results);
}

fn environSizesGet(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    return env_args.environSizesGet(castHost(host_data), ctx, params, results);
}

fn environGet(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    return env_args.environGet(castHost(host_data), ctx, params, results);
}

fn clockResGet(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    return clock.clockResGet(castHost(host_data), ctx, params, results);
}

fn clockTimeGet(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    return clock.clockTimeGet(castHost(host_data), ctx, params, results);
}

fn fdWrite(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    return fd_io.fdWrite(castHost(host_data), ctx, params, results);
}

fn fdSeek(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    return fd_io.fdSeek(castHost(host_data), ctx, params, results);
}

fn castHost(host_data: ?*anyopaque) *Host {
    return @ptrCast(@alignCast(host_data.?));
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

test "preview1 args and env write guest memory correctly" {
    const testing = std.testing;

    var engine = try wasmz.Engine.init(testing.allocator, wasmz.Config{});
    defer engine.deinit();

    var store = wasmz.Store.init(testing.allocator, engine);
    defer store.deinit();

    var host = Host.init(testing.allocator);
    defer host.deinit();
    try host.setArgs(&.{ "echo", "hello" });
    try host.setEnv(&.{.{ .key = "A", .value = "1" }});

    var linker = Linker.empty;
    defer linker.deinit(testing.allocator);
    try host.addToLinker(&linker, testing.allocator);

    var module = try wasmz.Module.compile(engine, &[_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60,
        0x00, 0x00, 0x03, 0x02,
        0x01, 0x00, 0x0a, 0x04,
        0x01, 0x02, 0x00, 0x0b,
    });
    defer module.deinit();

    var globals = [_]core.Global{};
    const memory = try testing.allocator.alloc(u8, 128);
    defer testing.allocator.free(memory);
    @memset(memory, 0);
    const tables = [_][]const u32{};
    var host_instance = wasmz.HostInstance{
        .module = &module,
        .globals = globals[0..],
        .memory = memory,
        .tables = tables[0..],
    };

    var ctx = HostContext.init(&store, &host_instance, &host);
    var results = [_]RawVal{RawVal.from(@as(i32, -1))};

    const args_sizes = linker.get(types.module_name, "args_sizes_get").?;
    try args_sizes.call(&ctx, &.{ RawVal.from(@as(i32, 0)), RawVal.from(@as(i32, 4)) }, &results);
    try testing.expectEqual(@as(i32, 0), results[0].readAs(i32));
    try testing.expectEqual(@as(u32, 2), try ctx.readValue(0, u32));
    try testing.expectEqual(@as(u32, 11), try ctx.readValue(4, u32));

    const args_get_func = linker.get(types.module_name, "args_get").?;
    try args_get_func.call(&ctx, &.{ RawVal.from(@as(i32, 8)), RawVal.from(@as(i32, 24)) }, &results);
    try testing.expectEqualStrings("echo", try ctx.readBytes(24, 4));
    try testing.expectEqualStrings("hello", try ctx.readBytes(29, 5));

    const env_sizes = linker.get(types.module_name, "environ_sizes_get").?;
    try env_sizes.call(&ctx, &.{ RawVal.from(@as(i32, 40)), RawVal.from(@as(i32, 44)) }, &results);
    try testing.expectEqual(@as(u32, 1), try ctx.readValue(40, u32));
    try testing.expectEqual(@as(u32, 4), try ctx.readValue(44, u32));

    const env_get_func = linker.get(types.module_name, "environ_get").?;
    try env_get_func.call(&ctx, &.{ RawVal.from(@as(i32, 48)), RawVal.from(@as(i32, 56)) }, &results);
    try testing.expectEqual(@as(u32, 56), try ctx.readValue(48, u32));
    try testing.expectEqualStrings("A=1", try ctx.readBytes(56, 3));
}

test "preview1 clock and fd_write use host implementations" {
    const testing = std.testing;

    var engine = try wasmz.Engine.init(testing.allocator, wasmz.Config{});
    defer engine.deinit();

    var store = wasmz.Store.init(testing.allocator, engine);
    defer store.deinit();

    var sink = std.ArrayList(u8){};
    defer sink.deinit(testing.allocator);

    const Sink = struct {
        fn write(ctx: ?*anyopaque, bytes: []const u8) WriteError!void {
            var list: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx.?));
            list.appendSlice(testing.allocator, bytes) catch return error.Io;
        }
    };

    var host = Host.init(testing.allocator);
    defer host.deinit();
    host.setStdout(.{ .ctx = &sink, .write_fn = Sink.write });
    host.realtime_clock = .{ .ctx = null, .now_fn = struct {
        fn now(_: ?*anyopaque) u64 {
            return 1234;
        }
    }.now, .resolution_ns = 99 };

    var linker = Linker.empty;
    defer linker.deinit(testing.allocator);
    try host.addToLinker(&linker, testing.allocator);

    var module = try wasmz.Module.compile(engine, &[_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60,
        0x00, 0x00, 0x03, 0x02,
        0x01, 0x00, 0x0a, 0x04,
        0x01, 0x02, 0x00, 0x0b,
    });
    defer module.deinit();

    var globals = [_]core.Global{};
    const memory = try testing.allocator.alloc(u8, 128);
    defer testing.allocator.free(memory);
    @memset(memory, 0);
    const tables = [_][]const u32{};
    var host_instance = wasmz.HostInstance{
        .module = &module,
        .globals = globals[0..],
        .memory = memory,
        .tables = tables[0..],
    };
    var ctx = HostContext.init(&store, &host_instance, &host);
    var results = [_]RawVal{RawVal.from(@as(i32, -1))};

    const clock_func = linker.get(types.module_name, "clock_time_get").?;
    try clock_func.call(&ctx, &.{ RawVal.from(@as(i32, 0)), RawVal.from(@as(i64, 0)), RawVal.from(@as(i32, 0)) }, &results);
    try testing.expectEqual(@as(u64, 1234), try ctx.readValue(0, u64));

    const clock_res_func = linker.get(types.module_name, "clock_res_get").?;
    try clock_res_func.call(&ctx, &.{ RawVal.from(@as(i32, 0)), RawVal.from(@as(i32, 24)) }, &results);
    try testing.expectEqual(@as(u64, 99), try ctx.readValue(24, u64));

    const bytes = "hello";
    @memcpy(memory[32..][0..bytes.len], bytes);
    try ctx.writeValue(8, types.Ciovec{ .buf = 32, .buf_len = bytes.len });
    const fd_write_func = linker.get(types.module_name, "fd_write").?;
    try fd_write_func.call(&ctx, &.{ RawVal.from(@as(i32, 1)), RawVal.from(@as(i32, 8)), RawVal.from(@as(i32, 1)), RawVal.from(@as(i32, 16)) }, &results);
    try testing.expectEqualStrings("hello", sink.items);
    try testing.expectEqual(@as(u32, bytes.len), try ctx.readValue(16, u32));
}

test "preview1 linker only registers implemented imports" {
    const testing = std.testing;

    var engine = try wasmz.Engine.init(testing.allocator, wasmz.Config{});
    defer engine.deinit();

    var store = wasmz.Store.init(testing.allocator, engine);
    defer store.deinit();

    var host = Host.init(testing.allocator);
    defer host.deinit();

    var linker = Linker.empty;
    defer linker.deinit(testing.allocator);
    try host.addToLinker(&linker, testing.allocator);

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01,
        0x7f, 0x02, 0x25, 0x01, 0x16, 'w',  'a',  's',
        'i',  '_',  's',  'n',  'a',  'p',  's',  'h',
        'o',  't',  '_',  'p',  'r',  'e',  'v',  'i',
        'e',  'w',  '1',  0x0a, 'r',  'a',  'n',  'd',
        'o',  'm',  '_',  'g',  'e',  't',  0x00, 0x00,
        0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03,
        'r',  'u',  'n',  0x00, 0x01, 0x0a, 0x08, 0x01,
        0x06, 0x00, 0x41, 0x00, 0x41, 0x00, 0x10, 0x00,
        0x0b,
    };

    var module = try wasmz.Module.compile(engine, &wasm);
    defer module.deinit();

    try testing.expectError(error.ImportNotSatisfied, wasmz.Instance.init(&store, &module, linker));
}

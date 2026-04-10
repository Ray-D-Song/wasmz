const std = @import("std");
const testing = std.testing;

const core = @import("core");
const wasmz = @import("wasmz");
const types = @import("../types.zig");
const host_mod = @import("../host.zig");

const RawVal = core.RawVal;
const Linker = wasmz.Linker;
const HostContext = wasmz.HostContext;

test "preview1 args and env write guest memory correctly" {
    var engine = try wasmz.Engine.init(testing.allocator, wasmz.Config{});
    defer engine.deinit();

    var store = try wasmz.Store.init(testing.allocator, engine);
    defer store.deinit();

    var host = host_mod.Host.init(testing.allocator);
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
    var engine = try wasmz.Engine.init(testing.allocator, wasmz.Config{});
    defer engine.deinit();

    var store = try wasmz.Store.init(testing.allocator, engine);
    defer store.deinit();

    var sink = std.ArrayList(u8){};
    defer sink.deinit(testing.allocator);

    const Sink = struct {
        fn write(ctx: ?*anyopaque, bytes: []const u8) host_mod.fd_io.WriteError!void {
            var list: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx.?));
            list.appendSlice(testing.allocator, bytes) catch return error.Io;
        }
    };

    var host = host_mod.Host.init(testing.allocator);
    defer host.deinit();
    host.setStdout(.{ .ctx = &sink, .write_fn = Sink.write });
    host.setRealtimeClock(.{ .ctx = null, .now_fn = struct {
        fn now(_: ?*anyopaque) u64 {
            return 1234;
        }
    }.now, .resolution_ns = 99 });

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
    var engine = try wasmz.Engine.init(testing.allocator, wasmz.Config{});
    defer engine.deinit();

    var store = try wasmz.Store.init(testing.allocator, engine);
    defer store.deinit();

    var host = host_mod.Host.init(testing.allocator);
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

test "preview1 file operations" {
    var engine = try wasmz.Engine.init(testing.allocator, wasmz.Config{});
    defer engine.deinit();

    var store = try wasmz.Store.init(testing.allocator, engine);
    defer store.deinit();

    var host = host_mod.Host.init(testing.allocator);
    defer host.deinit();

    const preopen_fd = try host.addPreopen(".");

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
    const memory = try testing.allocator.alloc(u8, 4096);
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

    const fd_prestat_get_func = linker.get(types.module_name, "fd_prestat_get").?;
    try fd_prestat_get_func.call(&ctx, &.{ RawVal.from(@as(u32, preopen_fd)), RawVal.from(@as(u32, 0)) }, &results);
    try testing.expectEqual(@as(i32, 0), results[0].readAs(i32));

    const Prestat = extern struct {
        pr_type: packed struct(u32) { tag: u32 = 0 },
        u: extern union {
            dir: extern struct {
                pr_len: u32,
            },
        },
    };
    const prestat: Prestat = @bitCast(try ctx.readValue(0, u64));
    try testing.expectEqual(@as(u32, 1), prestat.pr_type.tag);
    try testing.expectEqual(@as(u32, 1), prestat.u.dir.pr_len);

    const fd_fdstat_get_func = linker.get(types.module_name, "fd_fdstat_get").?;
    try fd_fdstat_get_func.call(&ctx, &.{ RawVal.from(@as(u32, preopen_fd)), RawVal.from(@as(u32, 16)) }, &results);
    try testing.expectEqual(@as(i32, 0), results[0].readAs(i32));
}

const std = @import("std");
const testing = std.testing;
const core = @import("core");
const engine_mod = @import("../../engine/root.zig");
const config_mod = @import("../../engine/config.zig");
const store_mod = @import("../store.zig");
const module_mod = @import("../module.zig");
const instance_mod = @import("../instance.zig");
const host_mod = @import("../host.zig");

const Engine = engine_mod.Engine;
const Store = store_mod.Store;
const Module = module_mod.Module;
const Instance = instance_mod.Instance;
const Linker = host_mod.Linker;
const Memory = core.Memory;
const RawVal = core.RawVal;
const TrapCode = core.TrapCode;

fn compileArc(bytes: []const u8, engine: Engine) !module_mod.ArcModule {
    return Module.compileArc(engine, bytes);
}

fn releaseArc(arc: module_mod.ArcModule) void {
    if (arc.releaseUnwrap()) |m| {
        var mod = m;
        mod.deinit();
    }
}

/// Issue #10: i32.load at i64 address 2^32 must trap, not alias offset 0.
const memory64_oob_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    // type section: () -> i32
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
    // function section
    0x03, 0x02, 0x01, 0x00,
    // memory section: memory64, 1 page
    0x05, 0x03, 0x01, 0x04, 0x01,
    // export "f"
    0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
    // code section (body size 0x16 = 22 bytes)
    0x0a, 0x18, 0x01, 0x16, 0x00,
    0x42, 0x00,
    0x41, 0xd5, 0xaa, 0xd5, 0xaa, 0x05,
    0x36, 0x02, 0x00,
    0x42, 0x80, 0x80, 0x80, 0x80, 0x10,
    0x28, 0x02, 0x00,
    0x0b,
};

test "memory64: OOB i64 address 2^32 traps (issue #10)" {
    var engine = try Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    var arc = try compileArc(&memory64_oob_wasm, engine);
    defer releaseArc(arc);

    try testing.expect(arc.value.memory64());

    var instance = try Instance.init(&store, arc.retain(), Linker.empty);
    defer instance.deinit();

    try testing.expect(instance.memory64);

    const exec_r = try instance.call("f", &.{});
    var trap = exec_r.trap;
    defer trap.deinit();
    try testing.expectEqual(TrapCode.MemoryOutOfBounds, trap.trapCode().?);
}

test "memory64: in-bounds i64 load/store works" {
    var engine = try Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    // () -> i32: store 42 at offset 8, load from offset 8
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
        0x03, 0x02, 0x01, 0x00,
        0x05, 0x03, 0x01, 0x04, 0x01,
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
        0x0a, 0x10, 0x01, 0x0e, 0x00,
        0x42, 0x08,
        0x41, 0x2a,
        0x36, 0x02, 0x00,
        0x42, 0x08,
        0x28, 0x02, 0x00,
        0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Linker.empty);
    defer instance.deinit();

    const exec_r = try instance.call("f", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 42), result.readAs(i32));
}

test "memory64: imported memory satisfies module import" {
    var engine = try Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
        0x02, 0x0c, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x03, 0x6d, 0x65, 0x6d, 0x02, 0x00, 0x01,
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    var mem = try Memory.initOwnedWithMax(testing.allocator, 1, null, false);
    defer mem.deinit();

    var linker = Linker.empty;
    defer linker.deinit(testing.allocator);
    try linker.defineMemory(testing.allocator, "env", "mem", mem);

    var instance = try Instance.init(&store, arc.retain(), linker);
    defer instance.deinit();

    const exec_r = try instance.call("f", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 42), result.readAs(i32));
}

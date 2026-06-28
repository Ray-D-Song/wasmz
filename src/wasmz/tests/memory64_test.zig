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

const memory64_module_header = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
    0x03, 0x02, 0x01, 0x00,
    0x05, 0x03, 0x01, 0x04, 0x01,
    0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
};

fn memory64TrapModule(comptime body: []const u8) [memory64_module_header.len + 4 + body.len]u8 {
    comptime {
        if (body.len > 127 or (1 + 1 + body.len) > 127) {
            @compileError("memory64TrapModule: body too large for single-byte LEB lengths");
        }
    }
    var out: [memory64_module_header.len + 4 + body.len]u8 = undefined;
    @memcpy(out[0..memory64_module_header.len], &memory64_module_header);
    out[memory64_module_header.len] = 0x0a;
    out[memory64_module_header.len + 1] = @intCast(1 + 1 + body.len);
    out[memory64_module_header.len + 2] = 1;
    out[memory64_module_header.len + 3] = @intCast(body.len);
    @memcpy(out[memory64_module_header.len + 4 ..], body);
    return out;
}

fn expectMemory64Trap(comptime body: []const u8) !void {
    const wasm = memory64TrapModule(body);

    var engine = try Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    try testing.expect(arc.value.memory64());

    var instance = try Instance.init(&store, arc.retain(), Linker.empty);
    defer instance.deinit();

    const exec_r = try instance.call("f", &.{});
    var trap = exec_r.trap;
    defer trap.deinit();
    try testing.expectEqual(TrapCode.MemoryOutOfBounds, trap.trapCode().?);
}

/// store 7 @ 0, load @ 2^32 — must trap instead of reading offset 0.
const memory64_oob_load_body = [_]u8{
    0x00,
    0x42, 0x00,
    0x41, 0x07,
    0x36, 0x02, 0x00,
    0x42, 0x80, 0x80, 0x80, 0x80, 0x10,
    0x28, 0x02, 0x00,
    0x0b,
};

/// store 7 @ 0, then store 99 @ 2^32 — must trap without clobbering offset 0.
const memory64_oob_store_body = [_]u8{
    0x00,
    0x42, 0x00,
    0x41, 0x07,
    0x36, 0x02, 0x00,
    0x42, 0x80, 0x80, 0x80, 0x80, 0x10,
    0x41, 0x63,
    0x36, 0x02, 0x00,
    0x0b,
};

/// i32.load @ i64.const 2^32 with memarg offset 8.
const memory64_oob_load_offset_body = [_]u8{
    0x00,
    0x42, 0x80, 0x80, 0x80, 0x80, 0x10,
    0x28, 0x02, 0x08,
    0x0b,
};

/// i32.load @ i64.const 131072 (> 65536, < 2^32) on a 1-page memory64 module.
const memory64_oob_below_2gb_body = [_]u8{
    0x00,
    0x42, 0x80, 0x80, 0x08,
    0x28, 0x02, 0x00,
    0x0b,
};

test "memory64: OOB i64 address 2^32 traps (issue #10)" {
    try expectMemory64Trap(&memory64_oob_load_body);
}

test "memory64: OOB store at 2^32 traps without aliasing offset 0 (issue #10)" {
    const wasm = memory64TrapModule(&memory64_oob_store_body);

    var engine = try Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Linker.empty);
    defer instance.deinit();

    const exec_r = try instance.call("f", &.{});
    var trap = exec_r.trap;
    defer trap.deinit();
    try testing.expectEqual(TrapCode.MemoryOutOfBounds, trap.trapCode().?);

    const mem = instance.memory.bytes();
    try testing.expectEqual(@as(i32, 7), @as(*align(1) const i32, @ptrCast(mem.ptr)).*);
}

test "memory64: OOB load at 2^32 with offset 8 traps (issue #10)" {
    try expectMemory64Trap(&memory64_oob_load_offset_body);
}

test "memory64: OOB load at 131072 traps (issue #10)" {
    try expectMemory64Trap(&memory64_oob_below_2gb_body);
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

const std = @import("std");
const testing = std.testing;

const engine_mod = @import("../../engine/root.zig");
const config_mod = @import("../../engine/config.zig");
const store_mod = @import("../store.zig");
const module_mod = @import("../module.zig");
const host_mod = @import("../host.zig");
const core = @import("core");

const Store = store_mod.Store;
const Module = module_mod.Module;
const HostInstance = host_mod.HostInstance;
const HostContext = host_mod.HostContext;
const Global = core.Global;
const TrapCode = core.TrapCode;

test "HostContext userData and hostData cast opaque pointers" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var user_value: i32 = 7;
    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();
    store.setUserData(&user_value);

    var host_value: i32 = 42;
    var globals = [_]Global{};
    var memory = [_]u8{ 1, 2, 3 };
    var tables = [_][]u32{};
    var dummy_module = try Module.compile(engine, &[_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60,
        0x00, 0x00, 0x03, 0x02,
        0x01, 0x00, 0x0a, 0x04,
        0x01, 0x02, 0x00, 0x0b,
    });
    defer dummy_module.deinit();

    var host_instance = HostInstance{
        .module = &dummy_module,
        .globals = globals[0..],
        .memory = memory[0..],
        .tables = tables[0..],
    };
    var ctx = HostContext.init(&store, &host_instance, &host_value);

    try testing.expectEqual(@as(i32, 7), ctx.user_data(i32).?.*);
    try testing.expectEqual(@as(i32, 42), ctx.host_data(i32).?.*);
}

test "HostContext readBytes traps on out of bounds" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    var globals = [_]Global{};
    var memory = [_]u8{ 1, 2, 3 };
    var tables = [_][]u32{};
    var dummy_module = try Module.compile(engine, &[_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60,
        0x00, 0x00, 0x03, 0x02,
        0x01, 0x00, 0x0a, 0x04,
        0x01, 0x02, 0x00, 0x0b,
    });
    defer dummy_module.deinit();

    var host_instance = HostInstance{
        .module = &dummy_module,
        .globals = globals[0..],
        .memory = memory[0..],
        .tables = tables[0..],
    };
    var ctx = HostContext.init(&store, &host_instance, null);

    try testing.expectError(error.HostTrap, ctx.readBytes(2, 2));
    const trap = ctx.takeTrap();
    try testing.expectEqual(@as(?TrapCode, .MemoryOutOfBounds), trap.trapCode());
}

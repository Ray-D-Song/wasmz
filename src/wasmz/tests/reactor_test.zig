/// reactor_test.zig — Zig unit tests for the Reactor model API
///
/// Tests:
///   1. isReactor() returns true for a module without _start
///   2. isCommand() returns false for same module
///   3. initializeReactor() calls _initialize and sets global state
///   4. initializeReactor() returns null (not found) for a plain library module
///   5. call() works after initializeReactor()
///   6. fib computation correctness via Instance.call
const std = @import("std");
const testing = std.testing;

const engine_mod = @import("../../engine/root.zig");
const config_mod = @import("../../engine/config.zig");
const store_mod = @import("../store.zig");
const module_mod = @import("../module.zig");
const instance_mod = @import("../instance.zig");
const host_mod = @import("../host.zig");

const Store = store_mod.Store;
const Module = module_mod.Module;
const ArcModule = module_mod.ArcModule;
const Instance = instance_mod.Instance;
const Linker = host_mod.Linker;
const RawVal = instance_mod.RawVal;

/// Load the pre-compiled reactor_add.wasm fixture.
/// This module:
///   - Has NO _start (reactor / library model)
///   - Exports _initialize, add(i32,i32)->i32, fib(i32)->i32, is_initialized()->i32
const reactor_add_wasm = @embedFile("fixtures/reactor_add.wasm");

fn makeEngine() !engine_mod.Engine {
    return engine_mod.Engine.init(testing.allocator, config_mod.Config{});
}

fn compileArc(bytes: []const u8, engine: engine_mod.Engine) !ArcModule {
    return Module.compileArc(engine, bytes);
}

fn releaseArc(arc: ArcModule) void {
    if (arc.releaseUnwrap()) |m| {
        var mod = m;
        mod.deinit();
    }
}

// ── Test 1: isReactor / isCommand ─────────────────────────────────────────────

test "reactor: isReactor() true, isCommand() false for no-_start module" {
    var engine = try makeEngine();
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    var arc = try compileArc(reactor_add_wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Linker.empty);
    defer instance.deinit();

    try testing.expect(instance.isReactor());
    try testing.expect(!instance.isCommand());
}

// ── Test 2: isCommand() true for a module with _start ─────────────────────────

test "reactor: isCommand() true for module with _start export" {
    // Minimal wasm with only a _start export (no-op)
    // (module (func (export "_start")))
    const command_wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
        0x01, 0x00, 0x07, 0x08, 0x01, 0x06, 0x5f, 0x73,
        0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x04,
        0x01, 0x02, 0x00, 0x0b,
    };

    var engine = try makeEngine();
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    var arc = try compileArc(&command_wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Linker.empty);
    defer instance.deinit();

    try testing.expect(instance.isCommand());
    try testing.expect(!instance.isReactor());
}

// ── Test 3: initializeReactor() calls _initialize ────────────────────────────

test "reactor: initializeReactor() invokes _initialize and sets global" {
    var engine = try makeEngine();
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    var arc = try compileArc(reactor_add_wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Linker.empty);
    defer instance.deinit();

    // Before _initialize: is_initialized should return 0
    {
        const r = try instance.call("is_initialized", &.{});
        const val = r.ok orelse return error.MissingReturn;
        try testing.expectEqual(@as(i32, 0), val.readAs(i32));
    }

    // Call initializeReactor
    const init_result = try instance.initializeReactor();
    // Should return a result (not null) because _initialize exists
    try testing.expect(init_result != null);
    switch (init_result.?) {
        .ok => {},
        .trap => return error.InitTrap,
    }

    // After _initialize: is_initialized should return 1
    {
        const r = try instance.call("is_initialized", &.{});
        const val = r.ok orelse return error.MissingReturn;
        try testing.expectEqual(@as(i32, 1), val.readAs(i32));
    }
}

// ── Test 4: initializeReactor() returns null for module without _initialize ───

test "reactor: initializeReactor() returns null when no _initialize export" {
    // Minimal module with only `add` export, no _initialize
    const add_wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01,
        0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
        0x03, 'a',  'd',  'd',  0x00, 0x00, 0x0a, 0x09,
        0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a,
        0x0b,
    };

    var engine = try makeEngine();
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    var arc = try compileArc(&add_wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Linker.empty);
    defer instance.deinit();

    const result = try instance.initializeReactor();
    // Should be null: no _initialize export
    try testing.expectEqual(@as(?@TypeOf(result.?), null), result);
}

// ── Test 5: add() correctness after initializeReactor ─────────────────────────

test "reactor: add() returns correct value after initializeReactor" {
    var engine = try makeEngine();
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    var arc = try compileArc(reactor_add_wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Linker.empty);
    defer instance.deinit();

    _ = try instance.initializeReactor();

    const args = [_]RawVal{ RawVal.from(@as(i32, 19)), RawVal.from(@as(i32, 23)) };
    const r = try instance.call("add", &args);
    const val = r.ok orelse return error.MissingReturn;
    try testing.expectEqual(@as(i32, 42), val.readAs(i32));
}

// ── Test 6: fib() correctness ─────────────────────────────────────────────────

test "reactor: fib() correctness: fib(10) == 55" {
    var engine = try makeEngine();
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    var arc = try compileArc(reactor_add_wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Linker.empty);
    defer instance.deinit();

    _ = try instance.initializeReactor();

    const cases = [_]struct { n: i32, expected: i32 }{
        .{ .n = 0, .expected = 0 },
        .{ .n = 1, .expected = 1 },
        .{ .n = 2, .expected = 1 },
        .{ .n = 5, .expected = 5 },
        .{ .n = 10, .expected = 55 },
        .{ .n = 20, .expected = 6765 },
    };

    for (cases) |c| {
        const args = [_]RawVal{RawVal.from(c.n)};
        const r = try instance.call("fib", &args);
        const val = r.ok orelse return error.MissingReturn;
        try testing.expectEqual(c.expected, val.readAs(i32));
    }
}

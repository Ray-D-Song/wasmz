/// Exception-handling tests for the new proposal (try_table / throw / throw_ref)
/// and the legacy proposal (try / catch / catch_all / rethrow).
const std = @import("std");
const testing = std.testing;

const engine_mod = @import("../../engine/root.zig");
const config_mod = @import("../../engine/config.zig");
const store_mod = @import("../store.zig");
const module_mod = @import("../module.zig");
const instance_mod = @import("../instance.zig");
const host_mod = @import("../host.zig");
const vm_mod = @import("../../vm/root.zig");
const core = @import("core");

const Store = store_mod.Store;
const Module = module_mod.Module;
const Instance = instance_mod.Instance;
const Linker = host_mod.Linker;
const RawVal = vm_mod.RawVal;
const TrapCode = vm_mod.TrapCode;

// ── Fixtures ──────────────────────────────────────────────────────────────────

/// New proposal: try_table + catch $t → returns i32 payload (42)
const eh_new_catch_wasm = @embedFile("fixtures/eh_new_catch.wasm");

/// New proposal: catch_ref + throw_ref → rethrows, should trap UnhandledException
const eh_new_throw_ref_wasm = @embedFile("fixtures/eh_new_throw_ref.wasm");

/// New proposal: catch_ref delivers [payload, exnref] into a multi-value block → returns payload
const eh_new_catch_ref_wasm = @embedFile("fixtures/eh_new_catch_ref.wasm");

/// Legacy proposal: try/catch $t → returns i32 payload (42)
const eh_legacy_catch_wasm = @embedFile("fixtures/eh_legacy_catch.wasm");

/// Legacy proposal: try/catch_all returns constant 99
const eh_legacy_catch_all_wasm = @embedFile("fixtures/eh_legacy_catch_all.wasm");

/// Legacy proposal: inner catch_all rethrows (rethrow 0) → outer catch $t returns 42
const eh_legacy_rethrow_wasm = @embedFile("fixtures/eh_legacy_rethrow.wasm");

// ── New proposal tests ────────────────────────────────────────────────────────

test "EH new: try_table catches thrown exception and returns payload" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    var module = try Module.compile(engine, eh_new_catch_wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Linker.empty);
    defer instance.deinit();

    const exec_r = try instance.call("run", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 42), result.readAs(i32));
}

test "EH new: throw_ref rethrows exception causing UnhandledException trap" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    var module = try Module.compile(engine, eh_new_throw_ref_wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Linker.empty);
    defer instance.deinit();

    const exec_r = try instance.call("run", &.{});
    switch (exec_r) {
        .ok => return error.ExpectedTrap,
        .trap => |t| {
            const code = t.trapCode() orelse return error.ExpectedTrapCode;
            try testing.expectEqual(TrapCode.UnhandledException, code);
        },
    }
}

// ── Legacy proposal tests ─────────────────────────────────────────────────────

test "EH legacy: try/catch catches thrown exception and returns payload" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    var module = try Module.compile(engine, eh_legacy_catch_wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Linker.empty);
    defer instance.deinit();

    const exec_r = try instance.call("run", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 42), result.readAs(i32));
}

test "EH legacy: try/catch_all catches any exception and returns constant" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    var module = try Module.compile(engine, eh_legacy_catch_all_wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Linker.empty);
    defer instance.deinit();

    const exec_r = try instance.call("run", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 99), result.readAs(i32));
}

test "EH legacy: rethrow propagates exception to outer catch" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    var module = try Module.compile(engine, eh_legacy_rethrow_wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Linker.empty);
    defer instance.deinit();

    const exec_r = try instance.call("run", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 42), result.readAs(i32));
}

test "EH new: catch_ref delivers [payload, exnref] into multi-value block, drop exnref returns payload" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    var module = try Module.compile(engine, eh_new_catch_ref_wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Linker.empty);
    defer instance.deinit();

    const exec_r = try instance.call("run", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 42), result.readAs(i32));
}

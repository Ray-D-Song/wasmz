/// Multi-value block type tests.
/// Tests that blocks with a type-indexed block type (multiple results) work correctly.
const std = @import("std");
const testing = std.testing;

const engine_mod = @import("../../engine/root.zig");
const config_mod = @import("../../engine/config.zig");
const store_mod = @import("../store.zig");
const module_mod = @import("../module.zig");
const instance_mod = @import("../instance.zig");
const host_mod = @import("../host.zig");
const vm_mod = @import("../../vm/root.zig");

const Store = store_mod.Store;
const Module = module_mod.Module;
const Instance = instance_mod.Instance;
const Linker = host_mod.Linker;
const RawVal = vm_mod.RawVal;

// ── Fixtures ──────────────────────────────────────────────────────────────────

/// Multi-value block: block (type $two_i32) yields (i32, i32), then i32.add → i32.
const multi_value_block_wasm = @embedFile("fixtures/multi_value_block.wasm");

// ── Tests ─────────────────────────────────────────────────────────────────────

test "multi-value block: block yields two i32 values that are then added" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    var module = try Module.compile(engine, multi_value_block_wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Linker.empty);
    defer instance.deinit();

    // block pushes (10, 32) onto the stack; i32.add produces 42.
    const exec_r = try instance.call("run", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 42), result.readAs(i32));
}

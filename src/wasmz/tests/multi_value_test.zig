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
const core = @import("core");

const Store = store_mod.Store;
const Module = module_mod.Module;
const ArcModule = module_mod.ArcModule;
const Instance = instance_mod.Instance;
const Linker = host_mod.Linker;
const RawVal = vm_mod.RawVal;

// Fixtures

/// Multi-value block: block (type $two_i32) yields (i32, i32), then i32.add → i32.
const multi_value_block_wasm = @embedFile("fixtures/multi_value_block.wasm");

// Tests

test "multi-value block: block yields two i32 values that are then added" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    var arc = try Module.compileArc(engine, multi_value_block_wasm);
    defer if (arc.releaseUnwrap()) |m| {
        var mm = m;
        mm.deinit();
    };

    var instance = try Instance.init(&store, arc.retain(), Linker.empty);
    defer instance.deinit();

    // block pushes (10, 32) onto the stack; i32.add produces 42.
    const exec_r = try instance.call("run", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 42), result.readAs(i32));
}

fn hostPair(_: ?*anyopaque, _: *host_mod.HostContext, params: []const RawVal, results: []RawVal) host_mod.HostError!void {
    const x = params[0].readAs(i32);
    results[0] = RawVal.from(x + 10);
    results[1] = RawVal.from(@as(i64, x) * 100);
}

test "multi-value function return and multi-value host import" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // Type section: [0]=(i32)->(i32,i64), [1]=(i32,i32)->(i32,i32), [2]=(i32)->(i64,i32)
        0x01, 0x14, 0x03,
        0x60, 0x01, 0x7f, 0x02, 0x7f, 0x7e,
        0x60, 0x02, 0x7f, 0x7f, 0x02, 0x7f, 0x7f,
        0x60, 0x01, 0x7f, 0x02, 0x7e, 0x7f,
        // Import section: env.pair func type 0
        0x02, 0x0b, 0x01,
        0x03, 'e', 'n', 'v', 0x04, 'p', 'a', 'i', 'r', 0x00, 0x00,
        // Function section: swap(1), use_pair(2)
        0x03, 0x03, 0x02, 0x01, 0x02,
        // Export section
        0x07, 0x13, 0x02,
        0x04, 's', 'w', 'a', 'p', 0x00, 0x01,
        0x08, 'u', 's', 'e', '_', 'p', 'a', 'i', 'r', 0x00, 0x02,
        // Code section
        0x0a, 0x1c, 0x02,
        // swap: local.get 1, local.get 0, return, end
        0x07, 0x00, 0x20, 0x01, 0x20, 0x00, 0x0f, 0x0b,
        // use_pair: locals(i32, i64), call 0, local.set 2, local.set 1, local.get 2, local.get 1, end
        0x12, 0x02, 0x01, 0x7f, 0x01, 0x7e,
        0x20, 0x00, 0x10, 0x00, 0x21, 0x02, 0x21, 0x01, 0x20, 0x02, 0x20, 0x01, 0x0b,
    };

    var arc = try Module.compileArc(engine, &wasm);
    defer if (arc.releaseUnwrap()) |m| {
        var mm = m;
        mm.deinit();
    };

    const param_types = [_]core.ValType{.I32};
    const result_types = [_]core.ValType{ .I32, .I64 };
    var linker = Linker.empty;
    defer linker.deinit(testing.allocator);
    try linker.define(testing.allocator, "env", "pair", host_mod.HostFunc.init(null, &hostPair, &param_types, &result_types));

    var instance = try Instance.init(&store, arc.retain(), linker);
    defer instance.deinit();

    const swap_r = try instance.call("swap", &.{ RawVal.from(@as(i32, 11)), RawVal.from(@as(i32, 22)) });
    try testing.expect(swap_r == .ok);
    const swap_res = instance.lastResults();
    try testing.expectEqual(@as(usize, 2), swap_res.len);
    try testing.expectEqual(@as(i32, 22), swap_res[0].readAs(i32));
    try testing.expectEqual(@as(i32, 11), swap_res[1].readAs(i32));

    const pair_r = try instance.call("use_pair", &.{RawVal.from(@as(i32, 7))});
    try testing.expect(pair_r == .ok);
    const pair_res = instance.lastResults();
    try testing.expectEqual(@as(usize, 2), pair_res.len);
    try testing.expectEqual(@as(i64, 700), pair_res[0].readAs(i64));
    try testing.expectEqual(@as(i32, 17), pair_res[1].readAs(i32));
}

/// Regression tests for operand-stack entries that alias a local which a later
/// local.set / local.tee overwrites.
///
/// Two separate defects produced wrong results here:
///   * lowering pushed the local's slot itself onto the operand stack, so
///     writing the local retroactively changed values already on the stack;
///   * the runtime local.set fusion in `dispatch.nextWithLocalSetFusion` stored
///     the value the previous instruction had just computed instead of reading
///     the local.set source slot.
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

const local_alias_wasm = @embedFile("fixtures/local_alias.wasm");

fn callI32(name: []const u8, args: []const RawVal) !i32 {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    var arc = try Module.compileArc(engine, local_alias_wasm);
    defer if (arc.releaseUnwrap()) |m| {
        var mm = m;
        mm.deinit();
    };

    var instance = try Instance.init(&store, arc.retain(), Linker.empty);
    defer instance.deinit();

    const exec_r = try instance.call(name, args);
    const result = exec_r.ok orelse return error.MissingReturnValue;
    return result.readAs(i32);
}

test "stack value keeps the local's pre-tee contents" {
    const got = try callI32("alias_after_tee", &.{
        RawVal.from(@as(i32, 0x1ff)),
        RawVal.from(@as(i32, 7)),
    });
    try testing.expectEqual(@as(i32, 7), got);
}

test "crc16 rounds read locals as they were before the tee" {
    try testing.expectEqual(@as(i32, -4095), try callI32("crc16_two_rounds", &.{
        RawVal.from(@as(i32, 0)),
        RawVal.from(@as(i32, 1)),
    }));
    try testing.expectEqual(@as(i32, -24575), try callI32("crc16_two_rounds", &.{
        RawVal.from(@as(i32, 0)),
        RawVal.from(@as(i32, 2)),
    }));
    try testing.expectEqual(@as(i32, -24574), try callI32("crc16_two_rounds", &.{
        RawVal.from(@as(i32, 7)),
        RawVal.from(@as(i32, 13)),
    }));
    try testing.expectEqual(@as(i32, 16383), try callI32("crc16_two_rounds", &.{
        RawVal.from(@as(i32, 255)),
        RawVal.from(@as(i32, 65535)),
    }));
}

/// Regression tests for binding operand-stack values into block/loop label
/// slots.
///
/// Lowering used to rename a label slot onto the slot of the first value bound
/// into it, which is only sound when that slot is an SSA temporary the binding
/// consumes. Renaming it onto a local's slot turned every later phi copy into a
/// write to the local, and renaming it during a `br_if` or `br_table` (both of
/// which only peek) let those copies overwrite a value still live on the
/// operand stack. Expected values come from wasmi.
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

const label_slots_wasm = @embedFile("fixtures/label_slots.wasm");

fn callI32(name: []const u8, a: i32, b: i32) !i32 {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    var arc = try Module.compileArc(engine, label_slots_wasm);
    defer if (arc.releaseUnwrap()) |m| {
        var mm = m;
        mm.deinit();
    };

    var instance = try Instance.init(&store, arc.retain(), Linker.empty);
    defer instance.deinit();

    const exec_r = try instance.call(name, &.{ RawVal.from(a), RawVal.from(b) });
    const result = exec_r.ok orelse return error.MissingReturnValue;
    return result.readAs(i32);
}

test "block result bound from a local is not renamed onto it" {
    try testing.expectEqual(@as(i32, 100), try callI32("block_result_from_local", 0, 3));
    try testing.expectEqual(@as(i32, 7007), try callI32("block_result_from_local", 7, 3));
    try testing.expectEqual(@as(i32, 5005), try callI32("block_result_from_local", 5, 0));
}

test "br_table targets do not rename onto the shared operand" {
    try testing.expectEqual(@as(i32, 11), try callI32("br_table_shared_value", 0, 1));
    try testing.expectEqual(@as(i32, 111), try callI32("br_table_shared_value", 1, 1));
    try testing.expectEqual(@as(i32, 114), try callI32("br_table_shared_value", 2, 4));
    try testing.expectEqual(@as(i32, 114), try callI32("br_table_shared_value", 9, 4));
}

test "insertion sort over a short slice" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    var arc = try Module.compileArc(engine, label_slots_wasm);
    defer if (arc.releaseUnwrap()) |m| {
        var mm = m;
        mm.deinit();
    };

    var instance = try Instance.init(&store, arc.retain(), Linker.empty);
    defer instance.deinit();

    const base: i32 = 1024;
    const values = [_]i64{ 9, 3, 7, 1, 8, 2, 6, 4 };
    for (values, 0..) |v, i| {
        _ = try instance.call("store", &.{
            RawVal.from(base + @as(i32, @intCast(i)) * 8),
            RawVal.from(v),
        });
    }
    _ = try instance.call("isort", &.{
        RawVal.from(base),
        RawVal.from(@as(i32, values.len)),
    });

    const expected = [_]i64{ 1, 2, 3, 4, 6, 7, 8, 9 };
    for (expected, 0..) |want, i| {
        const exec_r = try instance.call("load", &.{
            RawVal.from(base + @as(i32, @intCast(i)) * 8),
        });
        const got = (exec_r.ok orelse return error.MissingReturnValue).readAs(i64);
        try testing.expectEqual(want, got);
    }
}

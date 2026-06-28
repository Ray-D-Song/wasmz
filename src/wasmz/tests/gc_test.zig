/// GC control-flow tests (br_on_cast value forwarding, etc.)
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
const ArcModule = module_mod.ArcModule;
const Instance = instance_mod.Instance;
const Linker = host_mod.Linker;
const RawVal = vm_mod.RawVal;

fn releaseArc(arc: ArcModule) void {
    if (arc.releaseUnwrap()) |m| {
        var mm = m;
        mm.deinit();
    }
}

/// Issue #7: br_on_cast must forward the cast operand to the taken branch label
const br_on_cast_forward_wasm = @embedFile("fixtures/br_on_cast_forward.wasm");

/// Issue #6: structurally identical separately-declared struct types
const ref_test_struct_equiv_wasm = @embedFile("fixtures/ref_test_struct_equiv.wasm");
const ref_test_struct_final_mismatch_wasm = @embedFile("fixtures/ref_test_struct_final_mismatch.wasm");

/// Issue #5: funcref ref.test/cast against concrete and structurally equivalent func types
const ref_test_funcref_concrete_wasm = @embedFile("fixtures/ref_test_funcref_concrete.wasm");
const ref_test_funcref_equiv_wasm = @embedFile("fixtures/ref_test_funcref_equiv.wasm");
const call_ref_via_cast_wasm = @embedFile("fixtures/call_ref_via_cast.wasm");

fn callExported(arc: ArcModule, store: *Store, name: []const u8) !RawVal {
    var instance = try Instance.init(store, arc.retain(), Linker.empty);
    defer instance.deinit();
    const exec_r = try instance.call(name, &.{});
    return exec_r.ok orelse return error.MissingReturnValue;
}

test "GC issue #7: br_on_cast forwards non-null ref to label (ref.is_null)" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const arc = try module_mod.Module.compileArc(engine, br_on_cast_forward_wasm);
    defer releaseArc(arc);

    const result = try callExported(arc, &store, "is_null");
    try testing.expectEqual(@as(i32, 0), result.readAs(i32));
}

test "GC issue #7: br_on_cast forwarded ref is readable (struct.get)" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const arc = try module_mod.Module.compileArc(engine, br_on_cast_forward_wasm);
    defer releaseArc(arc);

    const result = try callExported(arc, &store, "get_field");
    try testing.expectEqual(@as(i32, 42), result.readAs(i32));
}

test "GC issue #6: ref.test matches structurally equivalent separate struct type" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const arc = try module_mod.Module.compileArc(engine, ref_test_struct_equiv_wasm);
    defer releaseArc(arc);

    const a_on_b = try callExported(arc, &store, "test_a_on_b");
    try testing.expectEqual(@as(i32, 1), a_on_b.readAs(i32));

    const b_on_a = try callExported(arc, &store, "test_b_on_a");
    try testing.expectEqual(@as(i32, 1), b_on_a.readAs(i32));
}

test "GC issue #6: ref.test rejects finality mismatch between struct types" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const arc = try module_mod.Module.compileArc(engine, ref_test_struct_final_mismatch_wasm);
    defer releaseArc(arc);

    const result = try callExported(arc, &store, "f");
    try testing.expectEqual(@as(i32, 0), result.readAs(i32));
}

test "GC issue #5: ref.test matches concrete funcref type" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const arc = try module_mod.Module.compileArc(engine, ref_test_funcref_concrete_wasm);
    defer releaseArc(arc);

    const concrete = try callExported(arc, &store, "test_concrete");
    try testing.expectEqual(@as(i32, 1), concrete.readAs(i32));

    const abstract = try callExported(arc, &store, "test_abstract");
    try testing.expectEqual(@as(i32, 1), abstract.readAs(i32));
}

test "GC issue #5: ref.test matches structurally equivalent func type" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const arc = try module_mod.Module.compileArc(engine, ref_test_funcref_equiv_wasm);
    defer releaseArc(arc);

    const result = try callExported(arc, &store, "test_a_on_b");
    try testing.expectEqual(@as(i32, 1), result.readAs(i32));
}

test "GC issue #5: call_ref after ref.cast to equivalent func type" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const arc = try module_mod.Module.compileArc(engine, call_ref_via_cast_wasm);
    defer releaseArc(arc);

    const result = try callExported(arc, &store, "call_via_cast");
    try testing.expectEqual(@as(i32, 42), result.readAs(i32));
}

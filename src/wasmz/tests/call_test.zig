/// Call / tail-call regression tests
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

/// Minimal repro: tail-call copies arg slot 3 into callee slot 0 (same val_stack base),
/// then must still read arg slot 0 — forward copy clobbers it (issue #2).
const return_call_indirect_overlap_wasm = @embedFile("fixtures/return_call_indirect_overlap.wasm");

/// wasm-benchmark vtable_dispatch workload (full integration check; too heavy for Debug).
const vtable_dispatch_wasm = @embedFile("fixtures/vtable_dispatch.wasm");

fn callExported(arc: ArcModule, store: *Store, name: []const u8, args: []const RawVal) !i32 {
    var instance = try Instance.init(store, arc.retain(), Linker.empty);
    defer instance.deinit();
    const exec_r = try instance.call(name, args);
    const rv = exec_r.ok orelse return error.MissingReturnValue;
    return rv.readAs(i32);
}

test "call issue #2: return_call_indirect overlapping tail-call args" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const arc = try module_mod.Module.compileArc(engine, return_call_indirect_overlap_wasm);
    defer releaseArc(arc);

    const result = try callExported(arc, &store, "run", &.{});
    try testing.expectEqual(@as(i32, 222), result);
}

test "call issue #2: vtable_mono wasm-benchmark regression" {
    if (@import("builtin").mode != .ReleaseFast) return;

    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const arc = try module_mod.Module.compileArc(engine, vtable_dispatch_wasm);
    defer releaseArc(arc);

    const mono = try callExported(arc, &store, "vtable_mono", &.{RawVal.from(@as(i32, 49578))});
    try testing.expectEqual(@as(i32, -318559695), mono);

    const bi = try callExported(arc, &store, "vtable_bi", &.{RawVal.from(@as(i32, 49578))});
    try testing.expectEqual(@as(i32, -208336512), bi);
}

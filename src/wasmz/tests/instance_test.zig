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
const Imports = host_mod.Linker;
const Linker = host_mod.Linker;
const HostFunc = host_mod.HostFunc;
const RawVal = vm_mod.RawVal;
const TrapCode = vm_mod.TrapCode;

/// Compile a module and wrap it in an ArcModule.
/// The caller owns the returned ArcModule; call releaseArc(arc) to free.
fn compileArc(bytes: []const u8, engine: engine_mod.Engine) !ArcModule {
    return Module.compileArc(engine, bytes);
}

/// Release an ArcModule, calling Module.deinit() when the last ref is dropped.
fn releaseArc(arc: ArcModule) void {
    if (arc.releaseUnwrap()) |m| {
        var mod = m;
        mod.deinit();
    }
}

test "Instance.call executes exported function end-to-end" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const add_wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01,
        0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
        0x03, 'a',  'd',  'd',  0x00, 0x00, 0x0a, 0x09,
        0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a,
        0x0b,
    };

    var arc = try compileArc(&add_wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Imports.empty);
    defer instance.deinit();

    const args = [_]RawVal{
        RawVal.from(@as(i32, 20)),
        RawVal.from(@as(i32, 22)),
    };
    const exec_r = try instance.call("add", &args);
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 42), result.readAs(i32));
}

test "Instance.init allocates globals and memory" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60,
        0x00, 0x00, 0x03, 0x02,
        0x01, 0x00, 0x06, 0x06,
        0x01, 0x7f, 0x00, 0x41,
        0x2a, 0x0b, 0x05, 0x03,
        0x01, 0x00, 0x01, 0x0a,
        0x04, 0x01, 0x02, 0x00,
        0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Imports.empty);
    defer instance.deinit();

    try testing.expectEqual(@as(usize, 1), instance.globals.len);
    try testing.expectEqual(@as(i32, 42), instance.globals[0].getRawValue().readAs(i32));

    try testing.expectEqual(@as(usize, 65536), instance.memory.byteLen());
    try testing.expectEqual(@as(u8, 0), instance.memory.bytes()[0]);
    try testing.expectEqual(@as(u8, 0), instance.memory.bytes()[65535]);
}

test "Instance.init with no memory section" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
        0x01, 0x00, 0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Imports.empty);
    defer instance.deinit();

    try testing.expectEqual(@as(usize, 0), instance.globals.len);
    try testing.expectEqual(@as(usize, 0), instance.memory.byteLen());
}

test "Instance.call supports inter-function calls (double via add)" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x0c, 0x02, 0x60, 0x02, 0x7f, 0x7f, 0x01,
        0x7f, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x03, 0x03,
        0x02, 0x00, 0x01, 0x07, 0x0a, 0x01, 0x06, 0x64,
        0x6f, 0x75, 0x62, 0x6c, 0x65, 0x00, 0x01, 0x0a,
        0x12, 0x02, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01,
        0x6a, 0x0b, 0x08, 0x00, 0x20, 0x00, 0x20, 0x00,
        0x10, 0x00, 0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Imports.empty);
    defer instance.deinit();

    const args = [_]RawVal{RawVal.from(@as(i32, 7))};
    const exec_r = try instance.call("double", &args);
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 14), result.readAs(i32));
}

test "Instance.call: i32.store and i32.load round-trip" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01,
        0x7f, 0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01,
        0x00, 0x01, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00,
        0x00, 0x0a, 0x10, 0x01, 0x0e, 0x00, 0x20, 0x00,
        0x20, 0x01, 0x36, 0x02, 0x00, 0x20, 0x00, 0x28,
        0x02, 0x00, 0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Imports.empty);
    defer instance.deinit();

    const addr = RawVal.from(@as(i32, 8));
    const val = RawVal.from(@as(i32, @bitCast(@as(u32, 0xDEADBEEF))));
    const exec_r = try instance.call("f", &.{ addr, val });
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, @bitCast(@as(u32, 0xDEADBEEF))), result.readAs(i32));
}

test "Instance.call: i32.store8, i32.load8_u, i32.load8_s" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0b, 0x02, 0x60,
        0x02, 0x7f, 0x7f, 0x00, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x03, 0x04, 0x03,
        0x00, 0x01, 0x01, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x1c, 0x03, 0x06,
        0x73, 0x74, 0x6f, 0x72, 0x65, 0x38, 0x00, 0x00, 0x06, 0x6c, 0x6f, 0x61,
        0x64, 0x38, 0x75, 0x00, 0x01, 0x06, 0x6c, 0x6f, 0x61, 0x64, 0x38, 0x73,
        0x00, 0x02, 0x0a, 0x1b, 0x03, 0x09, 0x00, 0x20, 0x00, 0x20, 0x01, 0x3a,
        0x00, 0x00, 0x0b, 0x07, 0x00, 0x20, 0x00, 0x2d, 0x00, 0x00, 0x0b, 0x07,
        0x00, 0x20, 0x00, 0x2c, 0x00, 0x00, 0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Imports.empty);
    defer instance.deinit();

    const addr = RawVal.from(@as(i32, 4));
    const store_r = try instance.call("store8", &.{ addr, RawVal.from(@as(i32, 0xFF)) });
    try testing.expectEqual(@as(?RawVal, null), store_r.ok);

    const r_u = (try instance.call("load8u", &.{addr})).ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 255), r_u.readAs(i32));

    const r_s = (try instance.call("load8s", &.{addr})).ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, -1), r_s.readAs(i32));
}

test "Instance.call: memory out-of-bounds returns trap" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
        0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01, 0x00,
        0x01, 0x07, 0x05, 0x01, 0x01, 'f',  0x00, 0x00,
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x28,
        0x02, 0x00, 0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Imports.empty);
    defer instance.deinit();

    const oob_addr = RawVal.from(@as(i32, 65533));
    const exec_r = try instance.call("f", &.{oob_addr});
    var trap0 = exec_r.trap;
    defer trap0.deinit();
    try testing.expectEqual(TrapCode.MemoryOutOfBounds, trap0.trapCode().?);
}

test "Instance: host function import (env.add_one) is called correctly" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
        0x02, 0x0f, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x07,
        0x61, 0x64, 0x64, 0x5f, 0x6f, 0x6e, 0x65, 0x00,
        0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
        0x03, 0x72, 0x75, 0x6e, 0x00, 0x01, 0x0a, 0x08,
        0x01, 0x06, 0x00, 0x20, 0x00, 0x10, 0x00, 0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    try testing.expectEqual(@as(usize, 1), arc.value.imported_funcs.len);
    try testing.expectEqualStrings("env", arc.value.imported_funcs[0].module_name);
    try testing.expectEqualStrings("add_one", arc.value.imported_funcs[0].func_name);

    const HostCtx = struct {
        fn add_one(
            _: ?*anyopaque,
            _: *host_mod.HostContext,
            params: []const RawVal,
            results: []RawVal,
        ) host_mod.HostError!void {
            const x = params[0].readAs(i32);
            results[0] = RawVal.from(x + 1);
        }
    };

    var imports = Imports.empty;
    defer imports.deinit(testing.allocator);
    try imports.define(
        testing.allocator,
        "env",
        "add_one",
        HostFunc.init(
            null,
            HostCtx.add_one,
            &[_]core.ValType{.I32},
            &[_]core.ValType{.I32},
        ),
    );

    var instance = try Instance.init(&store, arc.retain(), imports);
    defer instance.deinit();

    const exec_r = try instance.call("run", &.{RawVal.from(@as(i32, 41))});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 42), result.readAs(i32));
}

test "Instance: host function trap propagates to caller" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
        0x02, 0x0f, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x07,
        0x61, 0x64, 0x64, 0x5f, 0x6f, 0x6e, 0x65, 0x00,
        0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
        0x03, 0x72, 0x75, 0x6e, 0x00, 0x01, 0x0a, 0x08,
        0x01, 0x06, 0x00, 0x20, 0x00, 0x10, 0x00, 0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    const HostCtx = struct {
        fn always_trap(
            _: ?*anyopaque,
            ctx: *host_mod.HostContext,
            _: []const RawVal,
            _: []RawVal,
        ) host_mod.HostError!void {
            return ctx.raiseTrap(vm_mod.Trap.fromTrapCode(.UnreachableCodeReached));
        }
    };

    var imports = Imports.empty;
    defer imports.deinit(testing.allocator);
    try imports.define(
        testing.allocator,
        "env",
        "add_one",
        HostFunc.init(
            null,
            HostCtx.always_trap,
            &[_]core.ValType{.I32},
            &[_]core.ValType{.I32},
        ),
    );

    var instance = try Instance.init(&store, arc.retain(), imports);
    defer instance.deinit();

    const exec_r = try instance.call("run", &.{RawVal.from(@as(i32, 0))});
    var trap1 = exec_r.trap;
    defer trap1.deinit();
    try testing.expectEqual(TrapCode.UnreachableCodeReached, trap1.trapCode().?);
}

test "Instance.call: unreachable instruction returns UnreachableCodeReached trap" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
        0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 'f',  0x00,
        0x00, 0x0a, 0x05, 0x01, 0x03, 0x00, 0x00, 0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Imports.empty);
    defer instance.deinit();

    const exec_r = try instance.call("f", &.{});
    var trap2 = exec_r.trap;
    defer trap2.deinit();
    try testing.expectEqual(TrapCode.UnreachableCodeReached, trap2.trapCode().?);
}

test "Instance.init returns ImportNotSatisfied when import is missing" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm2 = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
        0x02, 0x0f, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x07,
        0x61, 0x64, 0x64, 0x5f, 0x6f, 0x6e, 0x65, 0x00,
        0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
        0x03, 0x72, 0x75, 0x6e, 0x00, 0x01, 0x0a, 0x08,
        0x01, 0x06, 0x00, 0x20, 0x00, 0x10, 0x00, 0x0b,
    };

    var arc2 = try compileArc(&wasm2, engine);
    defer releaseArc(arc2);

    const result = blk: {
        const retained = arc2.retain();
        const r = Instance.init(&store, retained, Imports.empty);
        if (r) |_| {} else |_| {
            releaseArc(retained);
        }
        break :blk r;
    };
    try testing.expectError(error.ImportNotSatisfied, result);
}

test "Instance.init returns ImportSignatureMismatch when host signature differs" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
        0x02, 0x0f, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x07,
        0x61, 0x64, 0x64, 0x5f, 0x6f, 0x6e, 0x65, 0x00,
        0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
        0x03, 0x72, 0x75, 0x6e, 0x00, 0x01, 0x0a, 0x08,
        0x01, 0x06, 0x00, 0x20, 0x00, 0x10, 0x00, 0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    const HostCtx = struct {
        fn wrong_sig(
            _: ?*anyopaque,
            _: *host_mod.HostContext,
            _: []const RawVal,
            _: []RawVal,
        ) host_mod.HostError!void {}
    };

    var linker = Linker.empty;
    defer linker.deinit(testing.allocator);
    try linker.define(
        testing.allocator,
        "env",
        "add_one",
        HostFunc.init(
            null,
            HostCtx.wrong_sig,
            &.{},
            &[_]core.ValType{.I32},
        ),
    );

    const sig_result = blk: {
        const retained = arc.retain();
        const r = Instance.init(&store, retained, linker);
        if (r) |_| {} else |_| {
            releaseArc(retained);
        }
        break :blk r;
    };
    try testing.expectError(error.ImportSignatureMismatch, sig_result);
}

test "Instance.call: table.size returns initial table element count" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x04, 0x04, 0x01, 0x70, 0x00,
        0x03, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, 0x0a, 0x07, 0x01, 0x05,
        0x00, 0xfc, 0x10, 0x00, 0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Imports.empty);
    defer instance.deinit();

    const exec_r = try instance.call("f", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 3), result.readAs(i32));
}

test "Instance.call: table.grow returns old size on success" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x04, 0x04, 0x01, 0x70, 0x00,
        0x02, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, 0x0a, 0x0b, 0x01, 0x09,
        0x00, 0xd0, 0x70, 0x41, 0x03, 0xfc, 0x0f, 0x00, 0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Imports.empty);
    defer instance.deinit();

    const exec_r = try instance.call("f", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 2), result.readAs(i32));
}

test "Instance.call: table.get returns non-null for populated element" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x04, 0x03, 0x00, 0x00, 0x00, 0x04, 0x04, 0x01,
        0x70, 0x00, 0x02, 0x07, 0x1a, 0x02, 0x0b, 0x67, 0x65, 0x74, 0x5f, 0x6e,
        0x6f, 0x6e, 0x6e, 0x75, 0x6c, 0x6c, 0x00, 0x01, 0x08, 0x67, 0x65, 0x74,
        0x5f, 0x6e, 0x75, 0x6c, 0x6c, 0x00, 0x02, 0x09, 0x07, 0x01, 0x00, 0x41,
        0x00, 0x0b, 0x01, 0x00, 0x0a, 0x19, 0x03, 0x04, 0x00, 0x41, 0x2a, 0x0b,
        0x0a, 0x00, 0x41, 0x00, 0x25, 0x00, 0xd1, 0x41, 0x01, 0x73, 0x0b, 0x07,
        0x00, 0x41, 0x01, 0x25, 0x00, 0xd1, 0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Imports.empty);
    defer instance.deinit();

    const r1 = try instance.call("get_nonnull", &.{});
    const v1 = r1.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 1), v1.readAs(i32));

    const r2 = try instance.call("get_null", &.{});
    const v2 = r2.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 1), v2.readAs(i32));
}

test "Instance.call: table.set then table.get roundtrip" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x03, 0x02, 0x00, 0x00, 0x04, 0x04, 0x01, 0x70,
        0x00, 0x02, 0x07, 0x11, 0x01, 0x0d, 0x73, 0x65, 0x74, 0x5f, 0x61, 0x6e,
        0x64, 0x5f, 0x63, 0x68, 0x65, 0x63, 0x6b, 0x00, 0x01, 0x09, 0x05, 0x01,
        0x01, 0x00, 0x01, 0x00, 0x0a, 0x18, 0x02, 0x05, 0x00, 0x41, 0xe3, 0x00,
        0x0b, 0x10, 0x00, 0x41, 0x00, 0xd2, 0x00, 0x26, 0x00, 0x41, 0x00, 0x25,
        0x00, 0xd1, 0x41, 0x01, 0x73, 0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Imports.empty);
    defer instance.deinit();

    const exec_r = try instance.call("set_and_check", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 1), result.readAs(i32));
}

test "Instance.call: table.fill sets elements and table.get reads non-null" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x03, 0x02, 0x00, 0x00, 0x04, 0x04, 0x01, 0x70,
        0x00, 0x04, 0x07, 0x12, 0x01, 0x0e, 0x66, 0x69, 0x6c, 0x6c, 0x5f, 0x61,
        0x6e, 0x64, 0x5f, 0x63, 0x68, 0x65, 0x63, 0x6b, 0x00, 0x01, 0x09, 0x05,
        0x01, 0x01, 0x00, 0x01, 0x00, 0x0a, 0x1a, 0x02, 0x04, 0x00, 0x41, 0x37,
        0x0b, 0x13, 0x00, 0x41, 0x01, 0xd2, 0x00, 0x41, 0x02, 0xfc, 0x11, 0x00,
        0x41, 0x02, 0x25, 0x00, 0xd1, 0x41, 0x01, 0x73, 0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Imports.empty);
    defer instance.deinit();

    const exec_r = try instance.call("fill_and_check", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 1), result.readAs(i32));
}

test "Instance.call: table.copy copies elements within same table" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x03, 0x02, 0x00, 0x00, 0x04, 0x04, 0x01, 0x70,
        0x00, 0x04, 0x07, 0x12, 0x01, 0x0e, 0x63, 0x6f, 0x70, 0x79, 0x5f, 0x61,
        0x6e, 0x64, 0x5f, 0x63, 0x68, 0x65, 0x63, 0x6b, 0x00, 0x01, 0x09, 0x07,
        0x01, 0x00, 0x41, 0x00, 0x0b, 0x01, 0x00, 0x0a, 0x1c, 0x02, 0x05, 0x00,
        0x41, 0xcd, 0x00, 0x0b, 0x14, 0x00, 0x41, 0x02, 0x41, 0x00, 0x41, 0x01,
        0xfc, 0x0e, 0x00, 0x00, 0x41, 0x02, 0x25, 0x00, 0xd1, 0x41, 0x01, 0x73,
        0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Imports.empty);
    defer instance.deinit();

    const exec_r = try instance.call("copy_and_check", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 1), result.readAs(i32));
}

test "Instance.call: table.init copies from passive element segment" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x03, 0x02, 0x00, 0x00, 0x04, 0x04, 0x01, 0x70,
        0x00, 0x04, 0x07, 0x12, 0x01, 0x0e, 0x69, 0x6e, 0x69, 0x74, 0x5f, 0x61,
        0x6e, 0x64, 0x5f, 0x63, 0x68, 0x65, 0x63, 0x6b, 0x00, 0x01, 0x09, 0x05,
        0x01, 0x01, 0x00, 0x01, 0x00, 0x0a, 0x1c, 0x02, 0x05, 0x00, 0x41, 0xd8,
        0x00, 0x0b, 0x14, 0x00, 0x41, 0x02, 0x41, 0x00, 0x41, 0x01, 0xfc, 0x0c,
        0x00, 0x00, 0x41, 0x02, 0x25, 0x00, 0xd1, 0x41, 0x01, 0x73, 0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Imports.empty);
    defer instance.deinit();

    const exec_r = try instance.call("init_and_check", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 1), result.readAs(i32));
}

test "Instance.call: elem.drop makes table.init trap" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x03, 0x02, 0x00, 0x00, 0x04, 0x04, 0x01, 0x70,
        0x00, 0x04, 0x07, 0x12, 0x01, 0x0e, 0x64, 0x72, 0x6f, 0x70, 0x5f, 0x74,
        0x68, 0x65, 0x6e, 0x5f, 0x69, 0x6e, 0x69, 0x74, 0x00, 0x01, 0x09, 0x05,
        0x01, 0x01, 0x00, 0x01, 0x00, 0x0a, 0x19, 0x02, 0x04, 0x00, 0x41, 0x0b,
        0x0b, 0x12, 0x00, 0xfc, 0x0d, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x01,
        0xfc, 0x0c, 0x00, 0x00, 0x41, 0xe3, 0x00, 0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Imports.empty);
    defer instance.deinit();

    const exec_r = try instance.call("drop_then_init", &.{});
    var trap3 = exec_r.trap;
    defer trap3.deinit();
    try testing.expectEqual(TrapCode.TableOutOfBounds, trap3.trapCode().?);
}

/// Issue #4: i31ref / funcref globals defer const expr without struct/array types
const global_i31ref_wasm = @embedFile("fixtures/global_i31ref.wasm");
const global_funcref_wasm = @embedFile("fixtures/global_funcref.wasm");

test "Instance issue #4: i31ref global initialized by ref.i31" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    var arc = try compileArc(global_i31ref_wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Imports.empty);
    defer instance.deinit();

    const exec_r = try instance.call("f", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 42), result.readAs(i32));
}

test "Instance issue #4: funcref global initialized by ref.func" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    var arc = try compileArc(global_funcref_wasm, engine);
    defer releaseArc(arc);

    var instance = try Instance.init(&store, arc.retain(), Imports.empty);
    defer instance.deinit();

    const exec_r = try instance.call("is_null", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 0), result.readAs(i32));
}

fn reentrantHostCb(_: ?*anyopaque, ctx: *host_mod.HostContext, params: []const RawVal, results: []RawVal) host_mod.HostError!void {
    const inst = ctx.host_data(Instance) orelse return ctx.raiseTrap(vm_mod.Trap.hostMessage("missing instance"));
    const x = params[0].readAs(i32);
    const inner = inst.call("leaf", &.{RawVal.from(x + 1)}) catch return ctx.raiseTrap(vm_mod.Trap.hostMessage("reentrant call failed"));
    const val = switch (inner) {
        .ok => |ov| (ov orelse return ctx.raiseTrap(vm_mod.Trap.hostMessage("missing value"))).readAs(i32),
        .trap => |*t| {
            @constCast(t).deinit();
            return ctx.raiseTrap(vm_mod.Trap.hostMessage("inner trap"));
        },
    };
    results[0] = RawVal.from(val * 10);
}

test "Instance.call: reentrant call from host import preserves outer frame" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    // Import env.reenter(i32)->i32 (idx 0)
    // Func 1 (outer): (x) -> x + reenter(x)
    // Func 2 (leaf): (y) -> y * 2
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
        0x02, 0x0e, 0x01, 0x03, 'e', 'n', 'v', 0x07, 'r', 'e', 'e', 'n', 't', 'e', 'r', 0x00, 0x00,
        0x03, 0x03, 0x02, 0x00, 0x00,
        0x07, 0x10, 0x02,
        0x05, 'o', 'u', 't', 'e', 'r', 0x00, 0x01,
        0x04, 'l', 'e', 'a', 'f', 0x00, 0x02,
        0x0a, 0x15, 0x02,
        // outer: local.get 0, local.get 0, call 0, i32.add, end
        0x09, 0x00, 0x20, 0x00, 0x20, 0x00, 0x10, 0x00, 0x6a, 0x0b,
        // leaf: local.get 0, i32.const 2, i32.mul, end
        0x07, 0x00, 0x20, 0x00, 0x41, 0x02, 0x6c, 0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    const i32_t = [_]core.ValType{.I32};
    var linker = Linker.empty;
    defer linker.deinit(testing.allocator);
    try linker.define(testing.allocator, "env", "reenter", HostFunc.init(null, &reentrantHostCb, &i32_t, &i32_t));

    var instance = try Instance.init(&store, arc.retain(), linker);
    defer instance.deinit();
    instance.host_funcs[0].host_data = @ptrCast(&instance);

    // outer(5) = 5 + (((5 + 1) * 2) * 10) = 5 + 120 = 125
    const exec_r = try instance.call("outer", &.{RawVal.from(@as(i32, 5))});
    const res = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 125), res.readAs(i32));
}

test "SharedGlobal, SharedTable cross-instance call_indirect, and RcMemory grow_seq" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    // Module A:
    //   type 0: (i32)->i32, type 1: (i32)->()
    //   func 0: (x)->x*3
    //   func 1: (idx, arg)-> call_indirect(type 0)(arg, idx)
    //   func 2: (delta)-> memory.grow(delta)
    //   table 0: 2..4 funcref, active elem at 0 = [func 0]
    //   memory 0: 1..4
    //   global 0: mut i32 = 42
    //   exports: g=global0, m=mem0, t=table0, call_tbl=func1, mem_grow=func2
    const wasm_a = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // Type: [0]=(i32)->i32, [1]=(i32,i32)->i32
        0x01, 0x0c, 0x02,
        0x60, 0x01, 0x7f, 0x01, 0x7f,
        0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
        // Func: [0]=type0, [1]=type1, [2]=type0
        0x03, 0x04, 0x03, 0x00, 0x01, 0x00,
        // Table: funcref 2..4
        0x04, 0x05, 0x01, 0x70, 0x01, 0x02, 0x04,
        // Memory: 1..4
        0x05, 0x04, 0x01, 0x01, 0x01, 0x04,
        // Global: mut i32 = 42
        0x06, 0x06, 0x01, 0x7f, 0x01, 0x41, 0x2a, 0x0b,
        // Export: g, m, t, call_tbl, mem_grow
        0x07, 0x23, 0x05,
        0x01, 'g', 0x03, 0x00,
        0x01, 'm', 0x02, 0x00,
        0x01, 't', 0x01, 0x00,
        0x08, 'c', 'a', 'l', 'l', '_', 't', 'b', 'l', 0x00, 0x01,
        0x08, 'm', 'e', 'm', '_', 'g', 'r', 'o', 'w', 0x00, 0x02,
        // Elem: table 0 offset 0 -> [func 0]
        0x09, 0x07, 0x01, 0x00, 0x41, 0x00, 0x0b, 0x01, 0x00,
        // Code:
        0x0a, 0x1a, 0x03,
        // func 0: local.get 0, i32.const 3, i32.mul, end
        0x07, 0x00, 0x20, 0x00, 0x41, 0x03, 0x6c, 0x0b,
        // func 1 (idx, arg): local.get 1, local.get 0, call_indirect type 0 table 0, end
        0x09, 0x00, 0x20, 0x01, 0x20, 0x00, 0x11, 0x00, 0x00, 0x0b,
        // func 2 (delta): local.get 0, memory.grow 0, end
        0x06, 0x00, 0x20, 0x00, 0x40, 0x00, 0x0b,
    };

    // Module B:
    //   imports: env.g (mut i32), env.t (funcref 2..4), env.m (mem 1..4)
    //   func 0: (x)->x+10
    //   func 1: (idx, arg)-> call_indirect(type 0)(arg, idx)
    //   func 2: (v)-> global.set 0; global.get 0
    //   elem: table 0 offset 1 -> [func 0]
    //   exports: call_tbl=func1, bump=func2
    const wasm_b = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x0c, 0x02,
        0x60, 0x01, 0x7f, 0x01, 0x7f,
        0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
        // Import: env.g (mut i32), env.t (funcref 2..4), env.m (1..4)
        0x02, 0x1f, 0x03,
        0x03, 'e', 'n', 'v', 0x01, 'g', 0x03, 0x7f, 0x01,
        0x03, 'e', 'n', 'v', 0x01, 't', 0x01, 0x70, 0x01, 0x02, 0x04,
        0x03, 'e', 'n', 'v', 0x01, 'm', 0x02, 0x01, 0x01, 0x04,
        // Func: [0]=type0, [1]=type1, [2]=type0
        0x03, 0x04, 0x03, 0x00, 0x01, 0x00,
        // Export: call_tbl=func1, bump=func2
        0x07, 0x13, 0x02,
        0x08, 'c', 'a', 'l', 'l', '_', 't', 'b', 'l', 0x00, 0x01,
        0x04, 'b', 'u', 'm', 'p', 0x00, 0x02,
        // Elem: table 0 offset 1 -> [func 0]
        0x09, 0x07, 0x01, 0x00, 0x41, 0x01, 0x0b, 0x01, 0x00,
        // Code:
        0x0a, 0x1f, 0x03,
        // func 0: local.get 0, i32.const 10, i32.add, end
        0x07, 0x00, 0x20, 0x00, 0x41, 0x0a, 0x6a, 0x0b,
        // func 1: local.get 1, local.get 0, call_indirect type 0 table 0, end
        0x09, 0x00, 0x20, 0x01, 0x20, 0x00, 0x11, 0x00, 0x00, 0x0b,
        // func 2: global.get 0, local.get 0, i32.add, global.set 0, global.get 0, end
        0x0b, 0x00, 0x23, 0x00, 0x20, 0x00, 0x6a, 0x24, 0x00, 0x23, 0x00, 0x0b,
    };

    var arc_a = try compileArc(&wasm_a, engine);
    defer releaseArc(arc_a);
    var arc_b = try compileArc(&wasm_b, engine);
    defer releaseArc(arc_b);

    var inst_a = try Instance.init(&store, arc_a.retain(), Imports.empty);
    defer inst_a.deinit();

    var linker_b = Linker.empty;
    defer linker_b.deinit(testing.allocator);
    var g_exp = inst_a.exportGlobal("g").?;
    const m_exp = inst_a.exportMemory("m").?;
    const t_exp = inst_a.exportTable("t").?;
    try linker_b.defineGlobalHandle(testing.allocator, "env", "g", g_exp);
    try linker_b.defineMemory(testing.allocator, "env", "m", m_exp);
    try linker_b.defineTable(testing.allocator, "env", "t", t_exp);

    var inst_b = try Instance.init(&store, arc_b.retain(), linker_b);
    defer inst_b.deinit();

    // Cross-instance call_indirect: B invokes slot 0 (A's x*3), A invokes slot 1 (B's x+10)
    const call_ba = try inst_b.call("call_tbl", &.{ RawVal.from(@as(i32, 0)), RawVal.from(@as(i32, 7)) });
    const r_ba = switch (call_ba) {
        .ok => |v| v.?,
        .trap => |t| {
            var tt = t;
            defer tt.deinit();
            const msg = tt.allocPrint(testing.allocator) catch "trap";
            defer testing.allocator.free(msg);
            std.debug.print("inst_b call_tbl trapped: {s}\n", .{msg});
            return error.UnexpectedTrap;
        },
    };
    try testing.expectEqual(@as(i32, 21), r_ba.readAs(i32));
    const r_ab = (try inst_a.call("call_tbl", &.{ RawVal.from(@as(i32, 1)), RawVal.from(@as(i32, 7)) })).ok.?;
    try testing.expectEqual(@as(i32, 17), r_ab.readAs(i32));

    // SharedGlobal mutation observed across instances
    const r_g = (try inst_b.call("bump", &.{RawVal.from(@as(i32, 8))})).ok.?;
    try testing.expectEqual(@as(i32, 50), r_g.readAs(i32));
    try testing.expectEqual(@as(i32, 50), g_exp.getRaw().readAs(i32));
    try testing.expectEqual(@as(i32, 50), inst_a.globals[0].getRawValue().readAs(i32));

    // RcMemory grow(0) bumps grow_seq; grow(1) visible in both handles
    const seq0 = inst_a.memory.growSeq();
    _ = try inst_a.call("mem_grow", &.{RawVal.from(@as(i32, 0))});
    try testing.expectEqual(seq0 + 1, inst_a.memory.growSeq());
    const prev = (try inst_a.call("mem_grow", &.{RawVal.from(@as(i32, 1))})).ok.?;
    try testing.expectEqual(@as(i32, 1), prev.readAs(i32));
    try testing.expectEqual(seq0 + 2, inst_a.memory.growSeq());
    try testing.expectEqual(@as(usize, 2), inst_b.memory.pageCount());
}

test "SharedTable: externref table get, set, grow across host and guest" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine, std.Io.Threaded.global_single_threaded.io());
    defer store.deinit();

    // Module with imported externref table 1..4: get_ref(idx)->externref, set_ref(idx, ref)
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x0c, 0x02,
        0x60, 0x01, 0x7f, 0x01, 0x6f,
        0x60, 0x02, 0x7f, 0x6f, 0x00,
        // Import env.ext_tbl (externref 1..4)
        0x02, 0x12, 0x01, 0x03, 'e', 'n', 'v', 0x07, 'e', 'x', 't', '_', 't', 'b', 'l', 0x01, 0x6f, 0x01, 0x01, 0x04,
        0x03, 0x03, 0x02, 0x00, 0x01,
        0x07, 0x15, 0x02,
        0x07, 'g', 'e', 't', '_', 'r', 'e', 'f', 0x00, 0x00,
        0x07, 's', 'e', 't', '_', 'r', 'e', 'f', 0x00, 0x01,
        0x0a, 0x11, 0x02,
        // get_ref: local.get 0, table.get 0, end
        0x06, 0x00, 0x20, 0x00, 0x25, 0x00, 0x0b,
        // set_ref: local.get 0, local.get 1, table.set 0, end
        0x08, 0x00, 0x20, 0x00, 0x20, 0x01, 0x26, 0x00, 0x0b,
    };

    var arc = try compileArc(&wasm, engine);
    defer releaseArc(arc);

    var tbl = try core.SharedTable.init(testing.allocator, core.ValType.externref(), 1, 4, core.TableEntry.fromExternRef(99));
    defer tbl.deinit();

    var linker = Linker.empty;
    defer linker.deinit(testing.allocator);
    try linker.defineTable(testing.allocator, "env", "ext_tbl", tbl);

    var instance = try Instance.init(&store, arc.retain(), linker);
    defer instance.deinit();

    const r0 = (try instance.call("get_ref", &.{RawVal.from(@as(i32, 0))})).ok.?;
    try testing.expectEqual(@as(u64, 99), r0.low64);

    _ = try instance.call("set_ref", &.{ RawVal.from(@as(i32, 0)), RawVal.fromBits64(777) });
    try testing.expectEqual(@as(u64, 777), tbl.get(0).?.raw);

    const prev_len = tbl.grow(2, core.TableEntry.fromExternRef(555)).?;
    try testing.expectEqual(@as(u32, 1), prev_len);
    const r2 = (try instance.call("get_ref", &.{RawVal.from(@as(i32, 2))})).ok.?;
    try testing.expectEqual(@as(u64, 555), r2.low64);
}

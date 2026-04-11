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
const Imports = host_mod.Linker;
const Linker = host_mod.Linker;
const HostFunc = host_mod.HostFunc;
const RawVal = vm_mod.RawVal;
const TrapCode = vm_mod.TrapCode;

test "Instance.call executes exported function end-to-end" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    const add_wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01,
        0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
        0x03, 'a',  'd',  'd',  0x00, 0x00, 0x0a, 0x09,
        0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a,
        0x0b,
    };

    var module = try Module.compile(engine, &add_wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
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

    var store = try Store.init(testing.allocator, engine);
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

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
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

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
        0x01, 0x00, 0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
    };

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
    defer instance.deinit();

    try testing.expectEqual(@as(usize, 0), instance.globals.len);
    try testing.expectEqual(@as(usize, 0), instance.memory.byteLen());
}

test "Instance.call supports inter-function calls (double via add)" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
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

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
    defer instance.deinit();

    const args = [_]RawVal{RawVal.from(@as(i32, 7))};
    const exec_r = try instance.call("double", &args);
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 14), result.readAs(i32));
}

test "Instance.call: i32.store and i32.load round-trip" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
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

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
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

    var store = try Store.init(testing.allocator, engine);
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

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
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

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
        0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01, 0x00,
        0x01, 0x07, 0x05, 0x01, 0x01, 'f',  0x00, 0x00,
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x28,
        0x02, 0x00, 0x0b,
    };

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
    defer instance.deinit();

    const oob_addr = RawVal.from(@as(i32, 65533));
    const exec_r = try instance.call("f", &.{oob_addr});
    try testing.expectEqual(TrapCode.MemoryOutOfBounds, exec_r.trap.trapCode().?);
}

test "Instance: host function import (env.add_one) is called correctly" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
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

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    try testing.expectEqual(@as(usize, 1), module.imported_funcs.len);
    try testing.expectEqualStrings("env", module.imported_funcs[0].module_name);
    try testing.expectEqualStrings("add_one", module.imported_funcs[0].func_name);

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

    var instance = try Instance.init(&store, &module, imports);
    defer instance.deinit();

    const exec_r = try instance.call("run", &.{RawVal.from(@as(i32, 41))});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 42), result.readAs(i32));
}

test "Instance: host function trap propagates to caller" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
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

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

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

    var instance = try Instance.init(&store, &module, imports);
    defer instance.deinit();

    const exec_r = try instance.call("run", &.{RawVal.from(@as(i32, 0))});
    try testing.expectEqual(TrapCode.UnreachableCodeReached, exec_r.trap.trapCode().?);
}

test "Instance.call: unreachable instruction returns UnreachableCodeReached trap" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
        0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 'f',  0x00,
        0x00, 0x0a, 0x05, 0x01, 0x03, 0x00, 0x00, 0x0b,
    };

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
    defer instance.deinit();

    const exec_r = try instance.call("f", &.{});
    try testing.expectEqual(TrapCode.UnreachableCodeReached, exec_r.trap.trapCode().?);
}

test "Instance.init returns ImportNotSatisfied when import is missing" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
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

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    const result = Instance.init(&store, &module, Imports.empty);
    try testing.expectError(error.ImportNotSatisfied, result);
}

test "Instance.init returns ImportSignatureMismatch when host signature differs" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
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

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

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

    try testing.expectError(error.ImportSignatureMismatch, Instance.init(&store, &module, linker));
}

test "Instance.call: table.size returns initial table element count" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x04, 0x04, 0x01, 0x70, 0x00,
        0x03, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, 0x0a, 0x07, 0x01, 0x05,
        0x00, 0xfc, 0x10, 0x00, 0x0b,
    };

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
    defer instance.deinit();

    const exec_r = try instance.call("f", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 3), result.readAs(i32));
}

test "Instance.call: table.grow returns old size on success" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x04, 0x04, 0x01, 0x70, 0x00,
        0x02, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, 0x0a, 0x0b, 0x01, 0x09,
        0x00, 0xd0, 0x70, 0x41, 0x03, 0xfc, 0x0f, 0x00, 0x0b,
    };

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
    defer instance.deinit();

    const exec_r = try instance.call("f", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 2), result.readAs(i32));
}

test "Instance.call: table.get returns non-null for populated element" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
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

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
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

    var store = try Store.init(testing.allocator, engine);
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

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
    defer instance.deinit();

    const exec_r = try instance.call("set_and_check", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 1), result.readAs(i32));
}

test "Instance.call: table.fill sets elements and table.get reads non-null" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
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

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
    defer instance.deinit();

    const exec_r = try instance.call("fill_and_check", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 1), result.readAs(i32));
}

test "Instance.call: table.copy copies elements within same table" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
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

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
    defer instance.deinit();

    const exec_r = try instance.call("copy_and_check", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 1), result.readAs(i32));
}

test "Instance.call: table.init copies from passive element segment" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
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

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
    defer instance.deinit();

    const exec_r = try instance.call("init_and_check", &.{});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 1), result.readAs(i32));
}

test "Instance.call: elem.drop makes table.init trap" {
    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = try Store.init(testing.allocator, engine);
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

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
    defer instance.deinit();

    const exec_r = try instance.call("drop_then_init", &.{});
    try testing.expectEqual(TrapCode.TableOutOfBounds, exec_r.trap.trapCode().?);
}

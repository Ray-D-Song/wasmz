const std = @import("std");
const testing = std.testing;

const VM = @import("../../vm/root.zig").VM;
const ExecEnv = @import("../../vm/root.zig").ExecEnv;
const Config = @import("../../engine/config.zig").Config;
const Store = @import("../store.zig").Store;
const HostInstance = @import("../host.zig").HostInstance;
const module_mod = @import("../module.zig");
const engine_mod = @import("../../engine/root.zig");
const payload_mod = @import("payload");
const core = @import("core");

const Module = module_mod.Module;
const Engine = engine_mod.Engine;
const Global = core.Global;
const Mutability = core.Mutability;

test "module.compile builds exported function bodies" {
    const exported_const_wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07,
        0x05, 0x01, 0x01, 'f',
        0x00, 0x00, 0x0a, 0x06,
        0x01, 0x04, 0x00, 0x41,
        0x01, 0x0b,
    };

    var engine = try Engine.init(testing.allocator, Config{});
    defer engine.deinit();

    var module = try Module.compile(engine, &exported_const_wasm);
    defer module.deinit();

    try testing.expectEqual(@as(usize, 1), module.functions.len);
    try testing.expectEqual(@as(usize, 1), module.func_types.len);
    try testing.expectEqual(@as(usize, 1), module.exports.count());

    const export_entry = module.exports.get("f") orelse return error.MissingExport;
    try testing.expectEqual(@as(u32, 0), export_entry.function_index);

    var vm = VM.init(testing.allocator);
    var store = try Store.init(testing.allocator, engine);
    defer store.deinit();
    var globals = [_]Global{};
    var memory: [0]u8 = .{};
    var tables = [_][]u32{};
    var host_instance = HostInstance{
        .module = &module,
        .globals = globals[0..],
        .memory = memory[0..],
        .tables = tables[0..],
    };
    var data_segments_dropped = [_]bool{};
    var elem_segments_dropped = [_]bool{};
    const exec_env = ExecEnv{
        .store = &store,
        .host_instance = &host_instance,
        .globals = globals[0..],
        .memory = memory[0..],
        .functions = &.{},
        .func_types = module.func_types,
        .host_funcs = &.{},
        .tables = tables[0..],
        .func_type_indices = &.{},
        .data_segments = module.data_segments,
        .data_segments_dropped = data_segments_dropped[0..],
        .elem_segments = module.elem_segments,
        .elem_segments_dropped = elem_segments_dropped[0..],
        .composite_types = module.composite_types,
        .struct_layouts = module.struct_layouts,
        .array_layouts = module.array_layouts,
        .type_ancestors = module.type_ancestors,
    };
    const result = (try vm.execute(
        module.functions[@intCast(export_entry.function_index)],
        &.{},
        exec_env,
    )).ok orelse {
        return error.MissingReturnValue;
    };
    try testing.expectEqual(@as(i32, 1), result.readAs(i32));
}

test "module.compile captures global initializers" {
    const global_module_wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x06, 0x06, 0x01, 0x7f,
        0x00, 0x41, 0x2a, 0x0b,
        0x07, 0x05, 0x01, 0x01,
        'g',  0x03, 0x00,
    };

    var engine = try Engine.init(testing.allocator, Config{});
    defer engine.deinit();

    var module = try Module.compile(engine, &global_module_wasm);
    defer module.deinit();

    try testing.expectEqual(@as(usize, 1), module.globals.len);
    try testing.expectEqual(Mutability.Const, module.globals[0].mutability);
    try testing.expectEqual(core.ValType.I32, module.globals[0].value.valType());
    try testing.expectEqual(@as(i32, 42), module.globals[0].value.into(i32));
    try testing.expectEqual(@as(usize, 0), module.functions.len);
}

test "module.compile handles active element segment with non-zero offset" {
    var engine = try engine_mod.Engine.init(testing.allocator, Config{});
    defer engine.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x03, 0x02, 0x00, 0x00, 0x04, 0x04, 0x01, 0x70,
        0x00, 0x08, 0x09, 0x08, 0x01, 0x00, 0x41, 0x03,
        0x0b, 0x02, 0x00, 0x01, 0x0a, 0x0a, 0x02, 0x04,
        0x00, 0x41, 0x2a, 0x0b, 0x04, 0x00, 0x41, 0x58,
        0x0b,
    };

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    try testing.expectEqual(@as(usize, 1), module.elem_segments.len);
    try testing.expectEqual(payload_mod.ElementMode.active, module.elem_segments[0].mode);
    try testing.expectEqual(@as(u32, 3), module.elem_segments[0].offset);
    try testing.expectEqualSlices(u32, &[_]u32{ 0, 1 }, module.elem_segments[0].func_indices);

    try testing.expectEqual(@as(usize, 1), module.tables.len);
    try testing.expectEqual(@as(usize, 8), module.tables[0].len);

    try testing.expectEqual(std.math.maxInt(u32), module.tables[0][0]);
    try testing.expectEqual(std.math.maxInt(u32), module.tables[0][1]);
    try testing.expectEqual(std.math.maxInt(u32), module.tables[0][2]);

    try testing.expectEqual(@as(u32, 0), module.tables[0][3]);
    try testing.expectEqual(@as(u32, 1), module.tables[0][4]);

    try testing.expectEqual(std.math.maxInt(u32), module.tables[0][5]);
    try testing.expectEqual(std.math.maxInt(u32), module.tables[0][6]);
    try testing.expectEqual(std.math.maxInt(u32), module.tables[0][7]);
}

test "compileFunctionBody rejects simd when disabled" {
    const body = [_]u8{
        0xfd, 0x0c,
    } ++ ([_]u8{0} ** 16) ++ [_]u8{0x0b};

    try testing.expectError(error.DisabledSimd, module_mod.compileFunctionBody(
        testing.allocator,
        0,
        body[0..],
        .{ .simd = false },
        .{
            .func_types = &.{},
            .type_indices = &.{},
            .import_type_indices = &.{},
            .import_count = 0,
        },
        &.{},
        .none,
    ));
}

test "compileFunctionBody rejects relaxed simd when disabled" {
    const zero_vec = [_]u8{ 0xfd, 0x0c } ++ ([_]u8{0} ** 16);
    const body = zero_vec ++ zero_vec ++ [_]u8{
        0xfd, 0x80, 0x02,
        0x0b,
    };

    try testing.expectError(error.DisabledRelaxedSimd, module_mod.compileFunctionBody(
        testing.allocator,
        0,
        body[0..],
        .{ .relaxed_simd = false },
        .{
            .func_types = &.{},
            .type_indices = &.{},
            .import_type_indices = &.{},
            .import_count = 0,
        },
        &.{},
        .none,
    ));
}

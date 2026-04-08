const std = @import("std");
const testing = std.testing;

const parser_mod = @import("parser");
const payload_mod = @import("payload");
const lower_mod = @import("../../compiler/lower.zig");
const ir_mod = @import("../../compiler/ir.zig");
const vm_mod = @import("../../vm/mod.zig");
const module_mod = @import("../../wasmz/module.zig");
const store_mod = @import("../../wasmz/store.zig");
const host_mod = @import("../../wasmz/host.zig");
const engine_mod = @import("../../engine/mod.zig");
const config_mod = @import("../../engine/config.zig");
const core = @import("core");

const Parser = parser_mod.Parser;
const Type = payload_mod.Type;
const Lower = lower_mod.Lower;
const WasmOp = lower_mod.WasmOp;
const CompiledFunction = ir_mod.CompiledFunction;
const VM = vm_mod.VM;
const RawVal = vm_mod.RawVal;
const ValType = core.ValType;
const Global = core.Global;
const TrapCode = core.TrapCode;
const Store = store_mod.Store;
const HostInstance = host_mod.HostInstance;
const Engine = engine_mod.Engine;
const Config = config_mod.Config;
const compileFunctionBody = module_mod.compileFunctionBody;
const FuncTypeResolver = module_mod.FuncTypeResolver;

const empty_resolver = FuncTypeResolver{
    .func_types = &.{},
    .type_indices = &.{},
    .import_type_indices = &.{},
    .import_count = 0,
};

const simple_add_wasm: []const u8 = @embedFile("fixtures/simple_add.wasm");
const local_tee_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d,
    0x01, 0x00, 0x00, 0x00,
    0x01, 0x06, 0x01, 0x60,
    0x01, 0x7f, 0x01, 0x7f,
    0x03, 0x02, 0x01, 0x00,
    0x0a, 0x08, 0x01, 0x06,
    0x00, 0x20, 0x00, 0x22,
    0x00, 0x0b,
};
const trunc_f64_s_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d,
    0x01, 0x00, 0x00, 0x00,
    0x01, 0x06, 0x01, 0x60,
    0x01, 0x7c, 0x01, 0x7f,
    0x03, 0x02, 0x01, 0x00,
    0x0a, 0x07, 0x01, 0x05,
    0x00, 0x20, 0x00, 0xaa,
    0x0b,
};
const extend8_s_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d,
    0x01, 0x00, 0x00, 0x00,
    0x01, 0x06, 0x01, 0x60,
    0x01, 0x7f, 0x01, 0x7f,
    0x03, 0x02, 0x01, 0x00,
    0x0a, 0x07, 0x01, 0x05,
    0x00, 0x20, 0x00, 0xc0,
    0x0b,
};
const empty_runtime_module_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d,
    0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60,
    0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x0a, 0x04,
    0x01, 0x02, 0x00, 0x0b,
};

const ParsedFunction = struct {
    params: []ValType,
    results: []ValType,
    reserved_slots: u32,
    body_expr: []const u8,
};

fn readVarU32(bytes: []const u8, cursor: *usize) !u32 {
    var result: u32 = 0;
    var shift: u6 = 0;

    while (true) {
        if (cursor.* >= bytes.len) return error.UnexpectedEof;
        const byte = bytes[cursor.*];
        cursor.* += 1;

        result |= @as(u32, byte & 0x7f) << @as(u5, @intCast(shift));
        if ((byte & 0x80) == 0) return result;
        shift += 7;
        if (shift >= 32) return error.InvalidLeb128;
    }
}

fn toValType(typ: Type) !ValType {
    return switch (typ) {
        .kind => |kind| switch (kind) {
            .i32 => .I32,
            .i64 => .I64,
            .f32 => .F32,
            .f64 => .F64,
            else => error.UnsupportedType,
        },
        else => error.UnsupportedType,
    };
}

fn findFunctionExprBytes(wasm: []const u8) ![]const u8 {
    if (wasm.len < 8) return error.UnexpectedEof;

    var cursor: usize = 8;
    while (cursor < wasm.len) {
        const section_id = wasm[cursor];
        cursor += 1;

        const section_size = try readVarU32(wasm, &cursor);
        const section_end = cursor + @as(usize, @intCast(section_size));
        if (section_end > wasm.len) return error.UnexpectedEof;

        if (section_id != 10) {
            cursor = section_end;
            continue;
        }

        var body_cursor = cursor;
        const func_count = try readVarU32(wasm, &body_cursor);
        if (func_count == 0) return error.NoFunctionBody;

        const body_size = try readVarU32(wasm, &body_cursor);
        const body_end = body_cursor + @as(usize, @intCast(body_size));
        if (body_end > section_end) return error.UnexpectedEof;

        const local_group_count = try readVarU32(wasm, &body_cursor);
        var local_index: u32 = 0;
        while (local_index < local_group_count) : (local_index += 1) {
            _ = try readVarU32(wasm, &body_cursor);
            if (body_cursor >= body_end) return error.UnexpectedEof;
            body_cursor += 1;
        }

        return wasm[body_cursor..body_end];
    }

    return error.CodeSectionNotFound;
}

fn parse_single_function_module(allocator: std.mem.Allocator, wasm: []const u8) !ParsedFunction {
    var parser = Parser.init(allocator);
    const payloads = try parser.parseAll(wasm);

    var function_type_index: ?u32 = null;
    var params: []ValType = &.{};
    var results: []ValType = &.{};
    var explicit_local_count: u32 = 0;

    for (payloads) |payload| {
        switch (payload) {
            .function_entry => |entry| {
                if (function_type_index == null) {
                    function_type_index = entry.type_index;
                }
            },
            .function_info => |info| {
                for (info.locals) |local_group| {
                    explicit_local_count += local_group.count;
                }
            },
            else => {},
        }
    }

    if (function_type_index == null) return error.FunctionTypeNotFound;

    var current_type_index: u32 = 0;
    var found_signature = false;
    find_signature: for (payloads) |payload| {
        switch (payload) {
            .type_entry => |entry| {
                if (current_type_index == function_type_index.?) {
                    params = try allocator.alloc(ValType, entry.params.len);
                    errdefer allocator.free(params);
                    for (entry.params, 0..) |param, index| {
                        params[index] = try toValType(param);
                    }

                    results = try allocator.alloc(ValType, entry.returns.len);
                    errdefer allocator.free(results);
                    for (entry.returns, 0..) |result, index| {
                        results[index] = try toValType(result);
                    }
                    found_signature = true;
                    break :find_signature;
                }
                current_type_index += 1;
            },
            else => {},
        }
    }

    if (!found_signature) return error.SignatureNotFound;

    const body_expr = try findFunctionExprBytes(wasm);
    const expr_len = parser_mod.testing.consumeExpression(body_expr);
    try testing.expectEqual(body_expr.len, expr_len);

    return .{
        .params = params,
        .results = results,
        .reserved_slots = @as(u32, @intCast(params.len)) + explicit_local_count,
        .body_expr = body_expr,
    };
}

fn lowerParsedFunction(allocator: std.mem.Allocator, reserved_slots: u32, body_expr: []const u8) !CompiledFunction {
    return try compileFunctionBody(allocator, reserved_slots, body_expr, empty_resolver);
}

fn executeUnaryOp(op: WasmOp, param: RawVal) !vm_mod.ExecResult {
    var lower = Lower.initWithReservedSlots(testing.allocator, 1);
    defer lower.deinit();

    const ops = [_]WasmOp{
        .{ .local_get = 0 },
        op,
        .ret,
    };
    for (ops) |item| {
        try lower.lowerOp(item);
    }

    var vm = VM.init(testing.allocator);
    const params = [_]RawVal{param};
    return try executeWithEmptyRuntime(&vm, lower.compiled, &params);
}

fn executeWithEmptyRuntime(
    vm: *VM,
    compiled: CompiledFunction,
    params: []const RawVal,
) !vm_mod.ExecResult {
    var engine = try Engine.init(testing.allocator, Config{});
    defer engine.deinit();

    var store = Store.init(testing.allocator, engine);
    defer store.deinit();

    var module = try module_mod.Module.compile(engine, &empty_runtime_module_wasm);
    defer module.deinit();

    var globals = [_]Global{};
    var memory: [0]u8 = .{};
    const tables = [_][]const u32{};
    var host_instance = HostInstance{
        .module = &module,
        .globals = globals[0..],
        .memory = memory[0..],
        .tables = tables[0..],
    };

    return try vm.execute(
        compiled,
        params,
        &store,
        &host_instance,
        globals[0..],
        memory[0..],
        &.{},
        &.{},
        &.{},
        tables[0..],
        &.{},
        &.{},
        &.{},
    );
}

fn expectUnaryResult(comptime T: type, op: WasmOp, param: RawVal, expected: T) !void {
    const exec_result = try executeUnaryOp(op, param);
    const result = exec_result.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(expected, result.readAs(T));
}

fn expectUnaryBitsResult(comptime T: type, op: WasmOp, param: RawVal, expected_bits: T) !void {
    const exec_result = try executeUnaryOp(op, param);
    const result = exec_result.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(expected_bits, result.readAs(T));
}

fn expectUnaryTrap(op: WasmOp, param: RawVal, expected: TrapCode) !void {
    const exec_result = try executeUnaryOp(op, param);
    switch (exec_result) {
        .trap => |trap| try testing.expectEqual(expected, trap.trapCode().?),
        .ok => return error.ExpectedTrap,
    }
}

test "simple_add fixture runs through parser lower ir vm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parse_single_function_module(arena.allocator(), simple_add_wasm);
    try testing.expectEqual(@as(usize, 2), parsed.params.len);
    try testing.expectEqual(@as(usize, 1), parsed.results.len);
    try testing.expectEqual(@as(u32, 2), parsed.reserved_slots);
    try testing.expectEqual(ValType.I32, parsed.params[0]);
    try testing.expectEqual(ValType.I32, parsed.params[1]);
    try testing.expectEqual(ValType.I32, parsed.results[0]);

    var compiled = try lowerParsedFunction(testing.allocator, parsed.reserved_slots, parsed.body_expr);
    defer compiled.ops.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), compiled.ops.items.len);

    var vm = VM.init(testing.allocator);
    const params = [_]RawVal{
        RawVal.from(@as(i32, 20)),
        RawVal.from(@as(i32, 22)),
    };
    const result = (try executeWithEmptyRuntime(&vm, compiled, &params)).ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 42), result.readAs(i32));
}

test "local_tee module runs through parser lower ir vm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parse_single_function_module(arena.allocator(), &local_tee_wasm);
    try testing.expectEqual(@as(usize, 1), parsed.params.len);
    try testing.expectEqual(@as(usize, 1), parsed.results.len);
    try testing.expectEqual(@as(u32, 1), parsed.reserved_slots);
    try testing.expectEqual(ValType.I32, parsed.params[0]);
    try testing.expectEqual(ValType.I32, parsed.results[0]);

    var compiled = try lowerParsedFunction(testing.allocator, parsed.reserved_slots, parsed.body_expr);
    defer compiled.ops.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), compiled.ops.items.len);

    var vm = VM.init(testing.allocator);
    const params = [_]RawVal{
        RawVal.from(@as(i32, 9)),
    };
    const result = (try executeWithEmptyRuntime(&vm, compiled, &params)).ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 9), result.readAs(i32));
}

test "countdown loop: block+loop+br_if runs correctly through lower and vm" {
    // Wasm equivalent (counts down from N to 0, returns 0):
    //   block
    //     loop
    //       local.get 0
    //       i32.eqz
    //       br_if 1       ; exit outer block when counter == 0
    //       local.get 0
    //       i32.const 1
    //       i32.sub
    //       local.set 0
    //       br 0          ; back to loop top
    //     end
    //   end
    //   local.get 0
    //   ret

    var lower = Lower.initWithReservedSlots(testing.allocator, 1);
    defer lower.deinit();

    const ops = [_]WasmOp{
        .{ .block = null },
        .{ .loop = null },
        .{ .local_get = 0 },
        .i32_eqz,
        .{ .br_if = 1 },
        .{ .local_get = 0 },
        .{ .i32_const = 1 },
        .i32_sub,
        .{ .local_set = 0 },
        .{ .br = 0 },
        .end, // end loop
        .end, // end block
        .{ .local_get = 0 },
        .ret,
    };
    for (ops) |o| try lower.lowerOp(o);

    var vm = VM.init(testing.allocator);

    // Start at 3, should return 0.
    const params3 = [_]RawVal{RawVal.from(@as(i32, 3))};
    const r3 = (try executeWithEmptyRuntime(&vm, lower.compiled, &params3)).ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 0), r3.readAs(i32));

    // Start at 0, loop never runs, should return 0.
    const params0 = [_]RawVal{RawVal.from(@as(i32, 0))};
    const r0 = (try executeWithEmptyRuntime(&vm, lower.compiled, &params0)).ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 0), r0.readAs(i32));
}

test "if-else selects correct branch at runtime" {
    // Wasm equivalent:
    //   local.get 0     ; condition
    //   if (result i32)
    //     i32.const 10
    //   else
    //     i32.const 20
    //   end
    //   ret

    var lower = Lower.initWithReservedSlots(testing.allocator, 1);
    defer lower.deinit();

    const ops = [_]WasmOp{
        .{ .local_get = 0 },
        .{ .if_ = .I32 },
        .{ .i32_const = 10 },
        .else_,
        .{ .i32_const = 20 },
        .end,
        .ret,
    };
    for (ops) |o| try lower.lowerOp(o);

    var vm = VM.init(testing.allocator);

    // Non-zero condition → then branch → 10
    const params_true = [_]RawVal{RawVal.from(@as(i32, 1))};
    const r_true = (try executeWithEmptyRuntime(&vm, lower.compiled, &params_true)).ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 10), r_true.readAs(i32));

    // Zero condition → else branch → 20
    const params_false = [_]RawVal{RawVal.from(@as(i32, 0))};
    const r_false = (try executeWithEmptyRuntime(&vm, lower.compiled, &params_false)).ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 20), r_false.readAs(i32));
}

test "numeric conversion instructions execute correctly" {
    try expectUnaryBitsResult(u32, .i32_wrap_i64, RawVal.from(@as(i64, @bitCast(@as(u64, 0x1234_5678_9abc_def0)))), 0x9abc_def0);
    try expectUnaryResult(i64, .i64_extend_i32_s, RawVal.from(@as(i32, -1)), -1);
    try expectUnaryBitsResult(u64, .i64_extend_i32_u, RawVal.from(@as(i32, -1)), 0x0000_0000_ffff_ffff);
    try expectUnaryResult(f32, .f32_convert_i64_u, RawVal.from(@as(i64, std.math.minInt(i64))), @as(f32, 9_223_372_036_854_775_808.0));
    try expectUnaryResult(f64, .f64_convert_i32_s, RawVal.from(@as(i32, -123)), @as(f64, -123.0));
    try expectUnaryResult(f32, .f32_demote_f64, RawVal.from(@as(f64, 42.25)), @as(f32, 42.25));
    try expectUnaryResult(f64, .f64_promote_f32, RawVal.from(@as(f32, -13.5)), @as(f64, -13.5));
}

test "reinterpret instructions preserve bit patterns" {
    try expectUnaryBitsResult(u32, .i32_reinterpret_f32, RawVal.from(@as(f32, @bitCast(@as(u32, 0x4049_0fdb)))), 0x4049_0fdb);
    try expectUnaryBitsResult(u64, .i64_reinterpret_f64, RawVal.from(@as(f64, @bitCast(@as(u64, 0x4009_21fb_5444_2d18)))), 0x4009_21fb_5444_2d18);
    try expectUnaryBitsResult(u32, .f32_reinterpret_i32, RawVal.from(@as(i32, @bitCast(@as(u32, 0x7fc0_0000)))), 0x7fc0_0000);
    try expectUnaryBitsResult(u64, .f64_reinterpret_i64, RawVal.from(@as(i64, @bitCast(@as(u64, 0x7ff8_0000_0000_0000)))), 0x7ff8_0000_0000_0000);
}

test "sign-extension instructions extend from narrow signed widths" {
    try expectUnaryResult(i32, .i32_extend8_s, RawVal.from(@as(i32, @bitCast(@as(u32, 0x0000_0080)))), -128);
    try expectUnaryResult(i32, .i32_extend16_s, RawVal.from(@as(i32, @bitCast(@as(u32, 0x0000_8000)))), -32768);
    try expectUnaryResult(i64, .i64_extend8_s, RawVal.from(@as(i64, @bitCast(@as(u64, 0x0000_0000_0000_0080)))), -128);
    try expectUnaryResult(i64, .i64_extend16_s, RawVal.from(@as(i64, @bitCast(@as(u64, 0x0000_0000_0000_8000)))), -32768);
    try expectUnaryResult(i64, .i64_extend32_s, RawVal.from(@as(i64, @bitCast(@as(u64, 0x0000_0000_8000_0000)))), -2147483648);
}

test "truncation instructions map NaN and range failures to wasm trap codes" {
    try expectUnaryTrap(.i32_trunc_f32_s, RawVal.from(std.math.nan(f32)), .BadConversionToInteger);
    try expectUnaryTrap(.i32_trunc_f32_s, RawVal.from(@as(f32, 2147483648.0)), .IntegerOverflow);
}

test "real wasm conversion opcode runs through parser lower and vm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parse_single_function_module(arena.allocator(), &trunc_f64_s_wasm);
    var compiled = try lowerParsedFunction(testing.allocator, parsed.reserved_slots, parsed.body_expr);
    defer compiled.ops.deinit(testing.allocator);

    var vm = VM.init(testing.allocator);
    const params = [_]RawVal{RawVal.from(@as(f64, 42.9))};
    const result = (try executeWithEmptyRuntime(&vm, compiled, &params)).ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 42), result.readAs(i32));
}

test "real wasm sign-extension opcode runs through parser lower and vm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parse_single_function_module(arena.allocator(), &extend8_s_wasm);
    var compiled = try lowerParsedFunction(testing.allocator, parsed.reserved_slots, parsed.body_expr);
    defer compiled.ops.deinit(testing.allocator);

    var vm = VM.init(testing.allocator);
    const params = [_]RawVal{RawVal.from(@as(i32, @bitCast(@as(u32, 0x0000_0080))))};
    const result = (try executeWithEmptyRuntime(&vm, compiled, &params)).ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, -128), result.readAs(i32));
}

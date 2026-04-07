const std = @import("std");
const testing = std.testing;

const parser_mod = @import("parser");
const payload_mod = @import("payload");
const lower_mod = @import("../../compiler/lower.zig");
const ir_mod = @import("../../compiler/ir.zig");
const vm_mod = @import("../../vm/mod.zig");
const module_mod = @import("../../wasmz/module.zig");
const core = @import("core");

const Parser = parser_mod.Parser;
const Type = payload_mod.Type;
const Lower = lower_mod.Lower;
const WasmOp = lower_mod.WasmOp;
const CompiledFunction = ir_mod.CompiledFunction;
const VM = vm_mod.VM;
const RawVal = vm_mod.RawVal;
const ValType = core.ValType;
const compileFunctionBody = module_mod.compileFunctionBody;
const FuncTypeResolver = module_mod.FuncTypeResolver;

const empty_resolver = FuncTypeResolver{
    .func_types = &.{},
    .type_indices = &.{},
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
    const payloads = try parser.parse_all(wasm);

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
    const expr_len = parser_mod.testing.consume_expression(body_expr);
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
    const result = (try vm.execute(compiled, &params, &.{}, &.{}, &.{})).ok orelse return error.MissingReturnValue;
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
    const result = (try vm.execute(compiled, &params, &.{}, &.{}, &.{})).ok orelse return error.MissingReturnValue;
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

    var lower = Lower.init_with_reserved_slots(testing.allocator, 1);
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
    for (ops) |o| try lower.lower_op(o);

    var vm = VM.init(testing.allocator);

    // Start at 3, should return 0.
    const params3 = [_]RawVal{RawVal.from(@as(i32, 3))};
    const r3 = (try vm.execute(lower.compiled, &params3, &.{}, &.{}, &.{})).ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 0), r3.readAs(i32));

    // Start at 0, loop never runs, should return 0.
    const params0 = [_]RawVal{RawVal.from(@as(i32, 0))};
    const r0 = (try vm.execute(lower.compiled, &params0, &.{}, &.{}, &.{})).ok orelse return error.MissingReturnValue;
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

    var lower = Lower.init_with_reserved_slots(testing.allocator, 1);
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
    for (ops) |o| try lower.lower_op(o);

    var vm = VM.init(testing.allocator);

    // Non-zero condition → then branch → 10
    const params_true = [_]RawVal{RawVal.from(@as(i32, 1))};
    const r_true = (try vm.execute(lower.compiled, &params_true, &.{}, &.{}, &.{})).ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 10), r_true.readAs(i32));

    // Zero condition → else branch → 20
    const params_false = [_]RawVal{RawVal.from(@as(i32, 0))};
    const r_false = (try vm.execute(lower.compiled, &params_false, &.{}, &.{}, &.{})).ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 20), r_false.readAs(i32));
}

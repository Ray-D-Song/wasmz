const std = @import("std");
const testing = std.testing;

const parser_mod = @import("parser");
const payload_mod = @import("payload");
const lower_mod = @import("../../compiler/lower.zig");
const vm_mod = @import("../../vm/mod.zig");
const value_type_mod = @import("../../core/value/type.zig");

const Parser = parser_mod.Parser;
const Type = payload_mod.Type;
const Lower = lower_mod.Lower;
const WasmOp = lower_mod.WasmOp;
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const ValType = value_type_mod.ValType;

const simple_add_wasm: []const u8 = @embedFile("fixtures/simple_add.wasm");

const ParsedFunction = struct {
    params: []ValType,
    results: []ValType,
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

fn parseSimpleAddModule(allocator: std.mem.Allocator, wasm: []const u8) !ParsedFunction {
    var parser = Parser.init(allocator);
    const payloads = try parser.parse_all(wasm);

    var function_type_index: ?u32 = null;
    var params: []ValType = &.{};
    var results: []ValType = &.{};

    for (payloads) |payload| {
        switch (payload) {
            .function_entry => |entry| {
                if (function_type_index == null) {
                    function_type_index = entry.type_index;
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
        .body_expr = body_expr,
    };
}

fn lowerParsedFunction(allocator: std.mem.Allocator, body_expr: []const u8) !Lower {
    var lower = Lower.init(allocator);
    errdefer lower.deinit();

    var cursor: usize = 0;
    while (cursor < body_expr.len) {
        const parsed = parser_mod.testing.read_next_operator(body_expr[cursor..]);
        cursor += parsed.consumed;

        const lowered_op = switch (parsed.info.code) {
            .local_get => WasmOp{ .local_get = parsed.info.local_index.? },
            .i32_add => WasmOp.i32_add,
            .end => WasmOp.ret,
            else => return error.UnsupportedOperator,
        };
        try lower.lowerOp(lowered_op);
    }

    return lower;
}

test "simple_add fixture runs through parser lower ir vm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseSimpleAddModule(arena.allocator(), simple_add_wasm);
    try testing.expectEqual(@as(usize, 2), parsed.params.len);
    try testing.expectEqual(@as(usize, 1), parsed.results.len);
    try testing.expectEqual(ValType.I32, parsed.params[0]);
    try testing.expectEqual(ValType.I32, parsed.params[1]);
    try testing.expectEqual(ValType.I32, parsed.results[0]);

    var lower = try lowerParsedFunction(testing.allocator, parsed.body_expr);
    defer lower.deinit();

    try testing.expectEqual(@as(usize, 4), lower.compiled.ops.items.len);

    var vm = VM.init(testing.allocator);
    const params = [_]Value{
        .{ .i32 = 20 },
        .{ .i32 = 22 },
    };
    const result = (try vm.execute(lower.compiled, &params)) orelse return error.MissingReturnValue;

    switch (result) {
        .i32 => |value| try testing.expectEqual(@as(i32, 42), value),
    }
}

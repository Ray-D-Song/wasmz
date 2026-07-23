const std = @import("std");
const testing = std.testing;

const handler_table_mod = @import("../handler_table.zig");
const handlers = @import("../handlers/root.zig");
const handlers_acc = @import("../handlers/accumulator.zig");

const Handler = @import("../../compiler/encode/table.zig").Handler;

fn expectHandler(field: Handler, expected: Handler) !void {
    try testing.expect(@intFromPtr(field) == @intFromPtr(expected));
}

test "handler_table wires normal scalar handlers" {
    const t = handler_table_mod.handler_table;
    try expectHandler(t.i32_add, &handlers.handle_i32_add);
    try expectHandler(t.i32_eq, &handlers.handle_i32_eq);
    try expectHandler(t.i32_clz, &handlers.handle_i32_clz);
}

test "handler_table wires imm fusion handlers" {
    const t = handler_table_mod.handler_table;
    try expectHandler(t.i32_add_imm, &handlers.handle_i32_add_imm);
    try expectHandler(t.i32_eq_imm, &handlers.handle_i32_eq_imm);
    try expectHandler(t.i32_add_imm_r, &handlers.handle_i32_add_imm_r);
}

test "handler_table wires accumulator r-path handlers" {
    const t = handler_table_mod.handler_table;
    try expectHandler(t.i32_add_r, &handlers_acc.handle_i32_add_r);
    try expectHandler(t.r0_load, &handlers_acc.handle_r0_load);
}

test "static handlers are non-null" {
    const t = handler_table_mod.handler_table;
    const imm_handlers = [_]Handler{
        t.i32_add_imm,
        t.i32_sub_imm,
        t.i32_eq_imm,
        t.i32_add_imm_r,
        t.i32_add_r,
        t.i32_clz,
    };
    for (imm_handlers) |h| {
        try testing.expect(@intFromPtr(h) != 0);
    }
}

const std = @import("std");
const testing = std.testing;

const lower_mod = @import("../lower.zig");
const ir = @import("../ir.zig");

const Lower = lower_mod.Lower;
const LowerError = lower_mod.LowerError;
const WasmOp = lower_mod.WasmOp;
const Op = ir.Op;

test "lower simple add function into slot IR" {
    var lower = Lower.init_with_reserved_slots(testing.allocator, 2);
    defer lower.deinit();

    const ops = [_]WasmOp{
        .{ .local_get = 0 },
        .{ .local_get = 1 },
        .i32_add,
        .ret,
    };

    for (ops) |op| {
        try lower.lower_op(op);
    }

    try testing.expectEqual(@as(u32, 3), lower.compiled.slots_len);
    try testing.expectEqual(@as(usize, 2), lower.compiled.ops.items.len);

    switch (lower.compiled.ops.items[0]) {
        .i32_add => |got| {
            try testing.expectEqual(@as(u32, 2), got.dst);
            try testing.expectEqual(@as(u32, 0), got.lhs);
            try testing.expectEqual(@as(u32, 1), got.rhs);
        },
        else => return error.UnexpectedOpTag,
    }

    switch (lower.compiled.ops.items[1]) {
        .ret => |got| {
            try testing.expectEqual(@as(?u32, 2), got.value);
        },
        else => return error.UnexpectedOpTag,
    }
}

test "lower reports stack underflow for i32_add without operands" {
    var lower = Lower.init_with_reserved_slots(testing.allocator, 0);
    defer lower.deinit();

    try testing.expectError(LowerError.StackUnderflow, lower.lower_op(.i32_add));
    try testing.expectEqual(@as(usize, 0), lower.compiled.ops.items.len);
}

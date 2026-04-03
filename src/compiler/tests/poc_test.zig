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

test "lower local_set consumes the top stack value" {
    var lower = Lower.init_with_reserved_slots(testing.allocator, 1);
    defer lower.deinit();

    const ops = [_]WasmOp{
        .{ .i32_const = 7 },
        .{ .local_set = 0 },
        .ret,
    };

    for (ops) |op| {
        try lower.lower_op(op);
    }

    try testing.expectEqual(@as(u32, 2), lower.compiled.slots_len);
    try testing.expectEqual(@as(usize, 3), lower.compiled.ops.items.len);

    switch (lower.compiled.ops.items[0]) {
        .const_i32 => |got| {
            try testing.expectEqual(@as(u32, 1), got.dst);
            try testing.expectEqual(@as(i32, 7), got.value);
        },
        else => return error.UnexpectedOpTag,
    }

    switch (lower.compiled.ops.items[1]) {
        .local_set => |got| {
            try testing.expectEqual(@as(u32, 0), got.local);
            try testing.expectEqual(@as(u32, 1), got.src);
        },
        else => return error.UnexpectedOpTag,
    }

    switch (lower.compiled.ops.items[2]) {
        .ret => |got| {
            try testing.expectEqual(@as(?u32, null), got.value);
        },
        else => return error.UnexpectedOpTag,
    }
}

test "lower local_tee writes local and keeps the top stack value" {
    var lower = Lower.init_with_reserved_slots(testing.allocator, 1);
    defer lower.deinit();

    const ops = [_]WasmOp{
        .{ .i32_const = 7 },
        .{ .local_tee = 0 },
        .ret,
    };

    for (ops) |op| {
        try lower.lower_op(op);
    }

    try testing.expectEqual(@as(u32, 2), lower.compiled.slots_len);
    try testing.expectEqual(@as(usize, 3), lower.compiled.ops.items.len);

    switch (lower.compiled.ops.items[0]) {
        .const_i32 => |got| {
            try testing.expectEqual(@as(u32, 1), got.dst);
            try testing.expectEqual(@as(i32, 7), got.value);
        },
        else => return error.UnexpectedOpTag,
    }

    switch (lower.compiled.ops.items[1]) {
        .local_set => |got| {
            try testing.expectEqual(@as(u32, 0), got.local);
            try testing.expectEqual(@as(u32, 1), got.src);
        },
        else => return error.UnexpectedOpTag,
    }

    switch (lower.compiled.ops.items[2]) {
        .ret => |got| {
            try testing.expectEqual(@as(?u32, 1), got.value);
        },
        else => return error.UnexpectedOpTag,
    }
}

test "lower drop consumes the top stack value without emitting IR" {
    var lower = Lower.init_with_reserved_slots(testing.allocator, 0);
    defer lower.deinit();

    const ops = [_]WasmOp{
        .{ .i32_const = 7 },
        .drop,
        .ret,
    };

    for (ops) |op| {
        try lower.lower_op(op);
    }

    try testing.expectEqual(@as(u32, 1), lower.compiled.slots_len);
    try testing.expectEqual(@as(usize, 2), lower.compiled.ops.items.len);

    switch (lower.compiled.ops.items[0]) {
        .const_i32 => |got| {
            try testing.expectEqual(@as(u32, 0), got.dst);
            try testing.expectEqual(@as(i32, 7), got.value);
        },
        else => return error.UnexpectedOpTag,
    }

    switch (lower.compiled.ops.items[1]) {
        .ret => |got| {
            try testing.expectEqual(@as(?u32, null), got.value);
        },
        else => return error.UnexpectedOpTag,
    }
}

test "lower i32_sub into slot IR" {
    var lower = Lower.init_with_reserved_slots(testing.allocator, 2);
    defer lower.deinit();

    const ops = [_]WasmOp{
        .{ .local_get = 0 },
        .{ .local_get = 1 },
        .i32_sub,
        .ret,
    };

    for (ops) |op| {
        try lower.lower_op(op);
    }

    try testing.expectEqual(@as(u32, 3), lower.compiled.slots_len);
    try testing.expectEqual(@as(usize, 2), lower.compiled.ops.items.len);

    switch (lower.compiled.ops.items[0]) {
        .i32_sub => |got| {
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

test "lower i32_mul into slot IR" {
    var lower = Lower.init_with_reserved_slots(testing.allocator, 2);
    defer lower.deinit();

    const ops = [_]WasmOp{
        .{ .local_get = 0 },
        .{ .local_get = 1 },
        .i32_mul,
        .ret,
    };

    for (ops) |op| {
        try lower.lower_op(op);
    }

    try testing.expectEqual(@as(u32, 3), lower.compiled.slots_len);
    try testing.expectEqual(@as(usize, 2), lower.compiled.ops.items.len);

    switch (lower.compiled.ops.items[0]) {
        .i32_mul => |got| {
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

test "lower i32_eqz into slot IR" {
    var lower = Lower.init_with_reserved_slots(testing.allocator, 1);
    defer lower.deinit();

    const ops = [_]WasmOp{
        .{ .local_get = 0 },
        .i32_eqz,
        .ret,
    };

    for (ops) |op| {
        try lower.lower_op(op);
    }

    try testing.expectEqual(@as(u32, 2), lower.compiled.slots_len);
    try testing.expectEqual(@as(usize, 2), lower.compiled.ops.items.len);

    switch (lower.compiled.ops.items[0]) {
        .i32_eqz => |got| {
            try testing.expectEqual(@as(u32, 1), got.dst);
            try testing.expectEqual(@as(u32, 0), got.src);
        },
        else => return error.UnexpectedOpTag,
    }

    switch (lower.compiled.ops.items[1]) {
        .ret => |got| {
            try testing.expectEqual(@as(?u32, 1), got.value);
        },
        else => return error.UnexpectedOpTag,
    }
}

test "lower i32_eq into slot IR" {
    var lower = Lower.init_with_reserved_slots(testing.allocator, 2);
    defer lower.deinit();

    const ops = [_]WasmOp{
        .{ .local_get = 0 },
        .{ .local_get = 1 },
        .i32_eq,
        .ret,
    };

    for (ops) |op| {
        try lower.lower_op(op);
    }

    try testing.expectEqual(@as(u32, 3), lower.compiled.slots_len);
    try testing.expectEqual(@as(usize, 2), lower.compiled.ops.items.len);

    switch (lower.compiled.ops.items[0]) {
        .i32_eq => |got| {
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

test "lower i32_ne into slot IR" {
    var lower = Lower.init_with_reserved_slots(testing.allocator, 2);
    defer lower.deinit();

    const ops = [_]WasmOp{
        .{ .local_get = 0 },
        .{ .local_get = 1 },
        .i32_ne,
        .ret,
    };

    for (ops) |op| {
        try lower.lower_op(op);
    }

    try testing.expectEqual(@as(u32, 3), lower.compiled.slots_len);
    try testing.expectEqual(@as(usize, 2), lower.compiled.ops.items.len);

    switch (lower.compiled.ops.items[0]) {
        .i32_ne => |got| {
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

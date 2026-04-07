const std = @import("std");
const testing = std.testing;

const lower_mod = @import("../lower.zig");
const ir = @import("../ir.zig");

const Lower = lower_mod.Lower;
const LowerError = lower_mod.LowerError;
const WasmOp = lower_mod.WasmOp;
const Op = ir.Op;

fn expect_binary_cmp_lowered(op: WasmOp, comptime tag: std.meta.Tag(Op)) !void {
    var lower = Lower.init_with_reserved_slots(testing.allocator, 2);
    defer lower.deinit();

    const ops = [_]WasmOp{
        .{ .local_get = 0 },
        .{ .local_get = 1 },
        op,
        .ret,
    };

    for (ops) |item| {
        try lower.lower_op(item);
    }

    try testing.expectEqual(@as(u32, 3), lower.compiled.slots_len);
    try testing.expectEqual(@as(usize, 2), lower.compiled.ops.items.len);

    try testing.expectEqual(tag, std.meta.activeTag(lower.compiled.ops.items[0]));
    try testing.expectEqual(.ret, std.meta.activeTag(lower.compiled.ops.items[1]));
}

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

test "lower i32 comparison family into slot IR" {
    try expect_binary_cmp_lowered(.i32_lt_s, .i32_lt_s);
    try expect_binary_cmp_lowered(.i32_lt_u, .i32_lt_u);
    try expect_binary_cmp_lowered(.i32_gt_s, .i32_gt_s);
    try expect_binary_cmp_lowered(.i32_gt_u, .i32_gt_u);
    try expect_binary_cmp_lowered(.i32_le_s, .i32_le_s);
    try expect_binary_cmp_lowered(.i32_le_u, .i32_le_u);
    try expect_binary_cmp_lowered(.i32_ge_s, .i32_ge_s);
    try expect_binary_cmp_lowered(.i32_ge_u, .i32_ge_u);
}

// ── Control flow tests ────────────────────────────────────────────────────────

test "lower block with void result and br exits cleanly" {
    // Wasm equivalent:
    //   block
    //     br 0
    //   end
    //   i32.const 1
    //   ret
    var lower = Lower.init_with_reserved_slots(testing.allocator, 0);
    defer lower.deinit();

    const ops = [_]WasmOp{
        .{ .block = null },
        .{ .br = 0 },
        .end,
        .{ .i32_const = 1 },
        .ret,
    };
    for (ops) |o| try lower.lower_op(o);

    // Expected IR:
    //   [0] jump -> 1        (br 0: jump to after-block)
    //   [1] const_i32 1      (i32.const 1)
    //   [2] ret { value = slot }
    try testing.expectEqual(@as(usize, 3), lower.compiled.ops.items.len);
    switch (lower.compiled.ops.items[0]) {
        .jump => |j| try testing.expectEqual(@as(u32, 1), j.target),
        else => return error.UnexpectedOpTag,
    }
    switch (lower.compiled.ops.items[1]) {
        .const_i32 => {},
        else => return error.UnexpectedOpTag,
    }
    switch (lower.compiled.ops.items[2]) {
        .ret => {},
        else => return error.UnexpectedOpTag,
    }
}

test "lower if without else: skips body when condition is zero" {
    // Wasm equivalent (void if, no else):
    //   local.get 0
    //   if
    //     nop  (represented here as const_i32 99 + drop)
    //   end
    //   ret (void)
    var lower = Lower.init_with_reserved_slots(testing.allocator, 1);
    defer lower.deinit();

    const ops = [_]WasmOp{
        .{ .local_get = 0 },
        .{ .if_ = null },
        .{ .i32_const = 99 },
        .drop,
        .end, // close if
        .ret,
    };
    for (ops) |o| try lower.lower_op(o);

    // IR:
    //   [0] jump_if_z cond=0, target=3   (if: skip body when 0)
    //   [1] const_i32 99  dst=1
    //   [2] (drop = nothing emitted)      <- wait, drop emits nothing
    //   actually the end emits nothing for void if
    //   [2] ret { null }
    // Since drop emits no op, items.len == 3
    try testing.expectEqual(@as(usize, 3), lower.compiled.ops.items.len);
    switch (lower.compiled.ops.items[0]) {
        .jump_if_z => |j| {
            try testing.expectEqual(@as(u32, 0), j.cond);
            // target must point past the block: index 2 (ret)
            try testing.expectEqual(@as(u32, 2), j.target);
        },
        else => return error.UnexpectedOpTag,
    }
    switch (lower.compiled.ops.items[1]) {
        .const_i32 => |c| try testing.expectEqual(@as(i32, 99), c.value),
        else => return error.UnexpectedOpTag,
    }
    switch (lower.compiled.ops.items[2]) {
        .ret => |r| try testing.expectEqual(@as(?u32, null), r.value),
        else => return error.UnexpectedOpTag,
    }
}

test "lower if-else selects correct branch" {
    // Wasm equivalent (returns i32):
    //   local.get 0        ; condition
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

    // Expected IR (result_slot = 1, allocated when if_ opens):
    //   [0] jump_if_z cond=0, target=4   ; skip then-body if cond==0
    //   [1] const_i32 10, dst=2
    //   [2] copy dst=1, src=2            ; write then result into result_slot
    //   [3] jump target=6                ; skip else-body
    //   [4] const_i32 20, dst=3
    //   [5] copy dst=1, src=3            ; write else result into result_slot
    //   [6] ret { value=1 }
    try testing.expectEqual(@as(usize, 7), lower.compiled.ops.items.len);

    switch (lower.compiled.ops.items[0]) {
        .jump_if_z => |j| try testing.expectEqual(@as(u32, 4), j.target),
        else => return error.UnexpectedOpTag,
    }
    switch (lower.compiled.ops.items[2]) {
        .copy => |c| {
            try testing.expectEqual(@as(u32, 1), c.dst); // result_slot
            try testing.expectEqual(@as(u32, 2), c.src); // then value
        },
        else => return error.UnexpectedOpTag,
    }
    switch (lower.compiled.ops.items[3]) {
        .jump => |j| try testing.expectEqual(@as(u32, 6), j.target),
        else => return error.UnexpectedOpTag,
    }
    switch (lower.compiled.ops.items[6]) {
        .ret => |r| try testing.expectEqual(@as(?u32, 1), r.value),
        else => return error.UnexpectedOpTag,
    }
}

test "lower loop with br_if: IR structure has backward jump" {
    // Wasm equivalent (count down from param 0 to 0, returns 0):
    //   block
    //     loop                       ; header at some pc H
    //       local.get 0
    //       i32.eqz
    //       br_if 1                  ; exit outer block when counter==0
    //       local.get 0
    //       i32.const 1
    //       i32.sub
    //       local.set 0
    //       br 0                     ; unconditional back-edge to H
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

    // The loop header is op index 0 (no ops emitted for block or loop themselves).
    // br 0 (back-edge) must be a `jump` with target=0.
    // br_if 1 is:
    //   jump_if_z cond=eqz_dst, target=<skip the unconditional jump below>
    //   jump -> <outer block end>
    // The final `ret` must exist.

    // Find the unconditional backward jump (br 0 → loop header at pc 0).
    var found_back_edge = false;
    for (lower.compiled.ops.items) |item| {
        switch (item) {
            .jump => |j| {
                if (j.target == 0) {
                    found_back_edge = true;
                    break;
                }
            },
            else => {},
        }
    }
    try testing.expect(found_back_edge);

    // The last op must be ret.
    const last = lower.compiled.ops.items[lower.compiled.ops.items.len - 1];
    try testing.expectEqual(std.meta.Tag(Op).ret, std.meta.activeTag(last));
}

const std = @import("std");
const testing = std.testing;
const lower_mod = @import("../lower.zig");
const ir = @import("../ir.zig");
const core = @import("core");

const Lower = lower_mod.Lower;
const WasmOp = lower_mod.WasmOp;
const Op = ir.Op;
const ValType = core.ValType;

const StaticLowerCase = struct {
    name: []const u8,
    reserved_slots: ir.Slot,
    val_types: []const ValType,
    ops: []const WasmOp,
    expect_tags: []const std.meta.Tag(Op),
    expect_const_i32: ?i32 = null,
};

fn initLower(allocator: std.mem.Allocator, val_types: []const ValType, reserved: ir.Slot) Lower {
    var lower = Lower.initWithReservedSlots(allocator, reserved, 0);
    lower.local_val_types = val_types;
    return lower;
}

fn runCase(case: StaticLowerCase) !void {
    var lower = initLower(testing.allocator, case.val_types, case.reserved_slots);
    defer lower.deinit();
    try lower.pushFunctionFrame(0);

    for (case.ops) |op| try lower.lowerOp(op);

    try testing.expectEqual(case.expect_tags.len, lower.compiled.ops.items.len);
    for (case.expect_tags, 0..) |tag, i| {
        try testing.expectEqual(tag, std.meta.activeTag(lower.compiled.ops.items[i]));
    }

    if (case.expect_const_i32) |expected| {
        switch (lower.compiled.ops.items[0]) {
            .const_i32 => |c| try testing.expectEqual(expected, c.value),
            else => return error.UnexpectedOpTag,
        }
    }
}

const cases = [_]StaticLowerCase{
    .{
        .name = "i32_add const fold",
        .reserved_slots = 0,
        .val_types = &.{},
        .ops = &.{
            .{ .i32_const = 3 },
            .{ .i32_const = 5 },
            .i32_add,
        },
        .expect_tags = &.{.const_i32},
        .expect_const_i32 = 8,
    },
    .{
        .name = "i32_add_imm fusion",
        .reserved_slots = 1,
        .val_types = &.{.I32},
        .ops = &.{
            .{ .local_get = 0 },
            .{ .i32_const = 5 },
            .i32_add,
        },
        .expect_tags = &.{ .r0_load, .i32_add_imm },
    },
    .{
        .name = "i32_add_r fusion",
        .reserved_slots = 2,
        .val_types = &.{ .I32, .I32 },
        .ops = &.{
            .{ .local_get = 0 },
            .{ .global_get = 0 },
            .i32_add,
        },
        .expect_tags = &.{ .r0_load, .global_get, .i32_add_r },
    },
    .{
        .name = "i32_eq compare imm",
        .reserved_slots = 1,
        .val_types = &.{.I32},
        .ops = &.{
            .{ .local_get = 0 },
            .{ .i32_const = 42 },
            .i32_eq,
        },
        .expect_tags = &.{ .r0_load, .i32_eq_imm },
    },
    .{
        .name = "i32_eq const fold",
        .reserved_slots = 0,
        .val_types = &.{},
        .ops = &.{
            .{ .i32_const = 7 },
            .{ .i32_const = 7 },
            .i32_eq,
        },
        .expect_tags = &.{.const_i32},
        .expect_const_i32 = 1,
    },
    .{
        .name = "i32_clz unary fold",
        .reserved_slots = 0,
        .val_types = &.{},
        .ops = &.{
            .{ .i32_const = 8 },
            .i32_clz,
        },
        .expect_tags = &.{.const_i32},
        .expect_const_i32 = 28,
    },
};

test "static lowering regression cases" {
    for (cases) |case| {
        try runCase(case);
    }
}

const std = @import("std");
const testing = std.testing;
const lower_mod = @import("../lower.zig");
const core = @import("core");

const Lower = lower_mod.Lower;
const ValType = core.ValType;

fn initLower(allocator: std.mem.Allocator, val_types: []const ValType) Lower {
    var lower = Lower.initWithReservedSlots(allocator, @intCast(val_types.len), 0);
    lower.local_val_types = val_types;
    return lower;
}

test "emit i32_add_r when lhs is in r0" {
    const allocator = testing.allocator;
    const val_types = [_]ValType{ .I32, .I32 };
    var lower = initLower(allocator, &val_types);
    defer lower.deinit();
    try lower.pushFunctionFrame(0);

    // local.get writes lhs into r0; global.get pushes rhs without clobbering r0.
    const ops = [_]lower_mod.WasmOp{
        .{ .local_get = 0 },
        .{ .global_get = 0 },
        .i32_add,
    };
    for (ops) |op| try lower.lowerOp(op);

    var found_r = false;
    for (lower.compiled.ops.items) |compiled| {
        if (compiled == .i32_add_r) found_r = true;
    }
    try testing.expect(found_r);
}

test "local.get emits r0_load for i32 local" {
    const allocator = testing.allocator;
    const val_types = [_]ValType{.I32};
    var lower = initLower(allocator, &val_types);
    defer lower.deinit();
    try lower.pushFunctionFrame(0);

    try lower.lowerOp(.{ .local_get = 0 });

    var found_load = false;
    for (lower.compiled.ops.items) |compiled| {
        if (compiled == .r0_load) found_load = true;
    }
    try testing.expect(found_load);
}
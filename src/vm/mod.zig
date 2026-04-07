const std = @import("std");
const ir = @import("../compiler/ir.zig");
const core = @import("core");

const CompiledFunction = ir.CompiledFunction;
const Allocator = std.mem.Allocator;
pub const RawVal = core.raw.RawVal;

pub const Frame = struct {
    slots: []RawVal,
};

pub const VM = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) VM {
        return .{ .allocator = allocator };
    }

    pub fn execute(self: *VM, func: CompiledFunction, params: []const RawVal) !?RawVal {
        const slots_len: usize = @max(
            @as(usize, @intCast(func.slots_len)),
            params.len,
        );
        var slots = try self.allocator.alloc(RawVal, slots_len);
        defer self.allocator.free(slots);

        for (params, 0..) |param, index| {
            slots[index] = param;
        }

        var pc: usize = 0;
        while (pc < func.ops.items.len) {
            const op = func.ops.items[pc];
            pc += 1;
            switch (op) {
                .const_i32 => |inst| {
                    slots[inst.dst] = RawVal.from(inst.value);
                },
                .local_get => |inst| {
                    slots[inst.dst] = slots[inst.local];
                },
                .local_set => |inst| {
                    slots[inst.local] = slots[inst.src];
                },
                .copy => |inst| {
                    slots[inst.dst] = slots[inst.src];
                },
                .jump => |inst| {
                    pc = inst.target;
                },
                .jump_if_z => |inst| {
                    if (slots[inst.cond].readAs(i32) == 0) {
                        pc = inst.target;
                    }
                },
                .i32_add => |inst| {
                    const lhs = slots[inst.lhs].readAs(i32);
                    const rhs = slots[inst.rhs].readAs(i32);
                    slots[inst.dst] = RawVal.from(lhs +% rhs);
                },
                .i32_sub => |inst| {
                    const lhs = slots[inst.lhs].readAs(i32);
                    const rhs = slots[inst.rhs].readAs(i32);
                    slots[inst.dst] = RawVal.from(lhs -% rhs);
                },
                .i32_mul => |inst| {
                    const lhs = slots[inst.lhs].readAs(i32);
                    const rhs = slots[inst.rhs].readAs(i32);
                    slots[inst.dst] = RawVal.from(lhs *% rhs);
                },
                .i32_eqz => |inst| {
                    const src = slots[inst.src].readAs(i32);
                    slots[inst.dst] = RawVal.from(@as(i32, if (src == 0) 1 else 0));
                },
                .i32_eq => |inst| {
                    const lhs = slots[inst.lhs].readAs(i32);
                    const rhs = slots[inst.rhs].readAs(i32);
                    slots[inst.dst] = RawVal.from(@as(i32, if (lhs == rhs) 1 else 0));
                },
                .i32_ne => |inst| {
                    const lhs = slots[inst.lhs].readAs(i32);
                    const rhs = slots[inst.rhs].readAs(i32);
                    slots[inst.dst] = RawVal.from(@as(i32, if (lhs != rhs) 1 else 0));
                },
                .i32_lt_s => |inst| {
                    const lhs = slots[inst.lhs].readAs(i32);
                    const rhs = slots[inst.rhs].readAs(i32);
                    slots[inst.dst] = RawVal.from(@as(i32, if (lhs < rhs) 1 else 0));
                },
                .i32_lt_u => |inst| {
                    const lhs = slots[inst.lhs].readAs(u32);
                    const rhs = slots[inst.rhs].readAs(u32);
                    slots[inst.dst] = RawVal.from(@as(i32, if (lhs < rhs) 1 else 0));
                },
                .i32_gt_s => |inst| {
                    const lhs = slots[inst.lhs].readAs(i32);
                    const rhs = slots[inst.rhs].readAs(i32);
                    slots[inst.dst] = RawVal.from(@as(i32, if (lhs > rhs) 1 else 0));
                },
                .i32_gt_u => |inst| {
                    const lhs = slots[inst.lhs].readAs(u32);
                    const rhs = slots[inst.rhs].readAs(u32);
                    slots[inst.dst] = RawVal.from(@as(i32, if (lhs > rhs) 1 else 0));
                },
                .i32_le_s => |inst| {
                    const lhs = slots[inst.lhs].readAs(i32);
                    const rhs = slots[inst.rhs].readAs(i32);
                    slots[inst.dst] = RawVal.from(@as(i32, if (lhs <= rhs) 1 else 0));
                },
                .i32_le_u => |inst| {
                    const lhs = slots[inst.lhs].readAs(u32);
                    const rhs = slots[inst.rhs].readAs(u32);
                    slots[inst.dst] = RawVal.from(@as(i32, if (lhs <= rhs) 1 else 0));
                },
                .i32_ge_s => |inst| {
                    const lhs = slots[inst.lhs].readAs(i32);
                    const rhs = slots[inst.rhs].readAs(i32);
                    slots[inst.dst] = RawVal.from(@as(i32, if (lhs >= rhs) 1 else 0));
                },
                .i32_ge_u => |inst| {
                    const lhs = slots[inst.lhs].readAs(u32);
                    const rhs = slots[inst.rhs].readAs(u32);
                    slots[inst.dst] = RawVal.from(@as(i32, if (lhs >= rhs) 1 else 0));
                },
                .ret => |inst| {
                    return if (inst.value) |slot| slots[slot] else null;
                },
            }
        }

        return null;
    }
};

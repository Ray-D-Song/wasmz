const std = @import("std");
const ir = @import("../compiler/ir.zig");

const CompiledFunction = ir.CompiledFunction;
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    i32: i32,
};

pub const Frame = struct {
    slots: []Value,
};

pub const VM = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) VM {
        return .{ .allocator = allocator };
    }

    pub fn execute(self: *VM, func: CompiledFunction, params: []const Value) !?Value {
        const slots_len: usize = @max(
            @as(usize, @intCast(func.slots_len)),
            params.len,
        );
        var slots = try self.allocator.alloc(Value, slots_len);
        defer self.allocator.free(slots);

        for (params, 0..) |param, index| {
            slots[index] = param;
        }

        for (func.ops.items) |op| {
            switch (op) {
                .const_i32 => |inst| {
                    slots[inst.dst] = .{ .i32 = inst.value };
                },
                .local_get => |inst| {
                    slots[inst.dst] = slots[inst.local];
                },
                .local_set => |inst| {
                    slots[inst.local] = slots[inst.src];
                },
                .i32_add => |inst| {
                    const lhs = slots[inst.lhs].i32;
                    const rhs = slots[inst.rhs].i32;
                    slots[inst.dst] = .{ .i32 = lhs + rhs };
                },
                .ret => |inst| {
                    return if (inst.value) |slot| slots[slot] else null;
                },
            }
        }

        return null;
    }
};

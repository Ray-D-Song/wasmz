// input:
// Function signature
// locals information
// operator sequence produced by the parser

// output:
// CompiledFunction { slots_len, ops }
const std = @import("std");
const ir = @import("./ir.zig");
const ValueStack = @import("./value_stack.zig").ValueStack;

const Allocator = std.mem.Allocator;
const Slot = ir.Slot;
const Op = ir.Op;
const CompiledFunction = ir.CompiledFunction;

pub const LowerError = error{
    StackUnderflow,
};

pub const WasmOp = union(enum) {
    local_get: u32,
    local_set: u32,
    i32_const: i32,
    i32_add,
    ret,
};

pub const Lower = struct {
    allocator: Allocator,
    compiled: CompiledFunction = .{
        .slots_len = 0,
        .ops = .empty,
    },
    stack: ValueStack = .{},
    next_slot: Slot = 0,

    pub fn init(allocator: Allocator) Lower {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Lower) void {
        self.stack.deinit(self.allocator);
        self.compiled.ops.deinit(self.allocator);
    }

    fn allocSlot(self: *Lower) Slot {
        const slot = self.next_slot;
        self.next_slot += 1;
        if (self.compiled.slots_len < self.next_slot) {
            self.compiled.slots_len = self.next_slot;
        }
        return slot;
    }

    fn emit(self: *Lower, op: Op) !void {
        try self.compiled.ops.append(self.allocator, op);
    }

    fn popSlot(self: *Lower) LowerError!Slot {
        return self.stack.pop() orelse error.StackUnderflow;
    }

    pub fn lowerOp(self: *Lower, op: WasmOp) !void {
        switch (op) {
            .local_get => |local| {
                const dst = self.allocSlot();
                try self.emit(.{ .local_get = .{ .dst = dst, .local = local } });
                try self.stack.push(self.allocator, dst);
            },
            .local_set => |local| {
                const src = try self.popSlot();
                try self.emit(.{ .local_set = .{ .local = local, .src = src } });
            },
            .i32_const => |value| {
                const dst = self.allocSlot();
                try self.emit(.{ .const_i32 = .{ .dst = dst, .value = value } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_add => {
                const rhs = try self.popSlot();
                const lhs = try self.popSlot();
                const dst = self.allocSlot();
                try self.emit(.{ .i32_add = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },
            .ret => {
                const value = self.stack.pop();
                try self.emit(.{ .ret = .{ .value = value } });
            },
        }
    }

    pub fn finish(self: *Lower) CompiledFunction {
        return self.compiled;
    }
};

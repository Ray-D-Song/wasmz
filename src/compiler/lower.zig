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
    drop,
    local_get: u32,
    local_set: u32,
    local_tee: u32,
    i32_const: i32,
    i32_add,
    i32_sub,
    i32_mul,
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

    pub fn init_with_reserved_slots(allocator: Allocator, reserved_slots: u32) Lower {
        return .{
            .allocator = allocator,
            .compiled = .{
                .slots_len = reserved_slots,
                .ops = .empty,
            },
            .next_slot = reserved_slots,
        };
    }

    pub fn deinit(self: *Lower) void {
        self.stack.deinit(self.allocator);
        self.compiled.ops.deinit(self.allocator);
    }

    fn alloc_slot(self: *Lower) Slot {
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

    fn pop_slot(self: *Lower) LowerError!Slot {
        return self.stack.pop() orelse error.StackUnderflow;
    }

    fn local_to_slot(_: *Lower, local: u32) Slot {
        return local;
    }

    pub fn lower_op(self: *Lower, op: WasmOp) !void {
        switch (op) {
            .drop => {
                _ = try self.pop_slot();
            },
            .local_get => |local| {
                try self.stack.push(self.allocator, self.local_to_slot(local));
            },
            .local_set => |local| {
                const src = try self.pop_slot();
                try self.emit(.{ .local_set = .{ .local = local, .src = src } });
            },
            .local_tee => |local| {
                const src = self.stack.peek() orelse return error.StackUnderflow;
                try self.emit(.{ .local_set = .{ .local = local, .src = src } });
            },
            .i32_const => |value| {
                const dst = self.alloc_slot();
                try self.emit(.{ .const_i32 = .{ .dst = dst, .value = value } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_add => {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_add = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_sub => {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_sub = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_mul => {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_mul = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
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

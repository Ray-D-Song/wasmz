const std = @import("std");
const Slot = @import("./ir.zig").Slot;

pub const ValueStack = struct {
    slots: std.ArrayListUnmanaged(Slot) = .empty,

    pub fn deinit(self: *ValueStack, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
    }

    pub fn push(self: *ValueStack, allocator: std.mem.Allocator, slot: Slot) !void {
        try self.slots.append(allocator, slot);
    }

    pub fn pop(self: *ValueStack) ?Slot {
        return self.slots.pop();
    }

    pub fn peek(self: *const ValueStack) ?Slot {
        if (self.slots.items.len == 0) return null;
        return self.slots.items[self.slots.items.len - 1];
    }

    pub fn len(self: *const ValueStack) usize {
        return self.slots.items.len;
    }
};

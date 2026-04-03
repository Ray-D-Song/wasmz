const std = @import("std");

pub const Slot = u32;

pub const Op = union(enum) {
    const_i32: struct {
        dst: Slot,
        value: i32,
    },
    local_get: struct {
        dst: Slot,
        local: u32,
    },
    local_set: struct {
        local: u32,
        src: Slot,
    },
    i32_add: struct {
        dst: Slot,
        lhs: Slot,
        rhs: Slot,
    },
    ret: struct {
        value: ?Slot,
    },
};

pub const CompiledFunction = struct {
    slots_len: u32,
    ops: std.ArrayListUnmanaged(Op),
};

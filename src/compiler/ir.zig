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
    i32_sub: struct {
        dst: Slot,
        lhs: Slot,
        rhs: Slot,
    },
    i32_mul: struct {
        dst: Slot,
        lhs: Slot,
        rhs: Slot,
    },
    i32_eqz: struct {
        dst: Slot,
        src: Slot,
    },
    i32_eq: struct {
        dst: Slot,
        lhs: Slot,
        rhs: Slot,
    },
    i32_ne: struct {
        dst: Slot,
        lhs: Slot,
        rhs: Slot,
    },
    i32_lt_s: struct {
        dst: Slot,
        lhs: Slot,
        rhs: Slot,
    },
    i32_lt_u: struct {
        dst: Slot,
        lhs: Slot,
        rhs: Slot,
    },
    i32_gt_s: struct {
        dst: Slot,
        lhs: Slot,
        rhs: Slot,
    },
    i32_gt_u: struct {
        dst: Slot,
        lhs: Slot,
        rhs: Slot,
    },
    i32_le_s: struct {
        dst: Slot,
        lhs: Slot,
        rhs: Slot,
    },
    i32_le_u: struct {
        dst: Slot,
        lhs: Slot,
        rhs: Slot,
    },
    i32_ge_s: struct {
        dst: Slot,
        lhs: Slot,
        rhs: Slot,
    },
    i32_ge_u: struct {
        dst: Slot,
        lhs: Slot,
        rhs: Slot,
    },
    /// Unconditional jump. `target` is an index into CompiledFunction.ops.
    jump: struct {
        target: u32,
    },
    /// Jump if `cond` slot holds an i32 equal to zero. `target` is an op index.
    jump_if_z: struct {
        cond: Slot,
        target: u32,
    },
    /// Copy `src` slot into `dst` slot (used to write block results).
    copy: struct {
        dst: Slot,
        src: Slot,
    },
    ret: struct {
        value: ?Slot,
    },
};

pub const CompiledFunction = struct {
    slots_len: u32,
    ops: std.ArrayListUnmanaged(Op),
};

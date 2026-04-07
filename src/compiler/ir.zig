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
    /// Read value from global and write it into `dst` slot
    global_get: struct {
        dst: Slot,
        global_idx: u32,
    },
    /// Write value from `src` slot into global
    global_set: struct {
        src: Slot,
        global_idx: u32,
    },
    ret: struct {
        value: ?Slot,
    },

    // ── Memory load/store instructions ──────────────────────────────────────────
    // All load/store instructions share the same memory immediate: (align, offset).
    // `addr` is the slot holding the base address (i32), `offset` is the static immediate offset.
    // The effective address = addr_value + offset.

    /// i32.load — load 4 bytes from memory (little-endian) as i32, write into `dst`
    i32_load: struct { dst: Slot, addr: Slot, offset: u32 },
    /// i32.load8_s — load 1 byte from memory, sign-extend to i32, write into `dst`
    i32_load8_s: struct { dst: Slot, addr: Slot, offset: u32 },
    /// i32.load8_u — load 1 byte from memory, zero-extend to i32, write into `dst`
    i32_load8_u: struct { dst: Slot, addr: Slot, offset: u32 },
    /// i32.load16_s — load 2 bytes from memory (little-endian), sign-extend to i32, write into `dst`
    i32_load16_s: struct { dst: Slot, addr: Slot, offset: u32 },
    /// i32.load16_u — load 2 bytes from memory (little-endian), zero-extend to i32, write into `dst`
    i32_load16_u: struct { dst: Slot, addr: Slot, offset: u32 },

    /// i32.store — store 4-byte i32 value from `src` slot to memory at (addr + offset)
    i32_store: struct { addr: Slot, src: Slot, offset: u32 },
    /// i32.store8 — store lowest 8 bits of i32 from `src` to memory
    i32_store8: struct { addr: Slot, src: Slot, offset: u32 },
    /// i32.store16 — store lowest 16 bits of i32 from `src` to memory (little-endian)
    i32_store16: struct { addr: Slot, src: Slot, offset: u32 },
    /// direct fn call
    ///
    /// args slots are stored in CompiledFunction.call_args, indexed by (args_start, args_len).
    /// This allows us to avoid per-call allocations for argument lists and instead reuse a single contiguous array for all call arguments.
    call: struct {
        /// result slot (void functions have null)
        dst: ?Slot,
        /// Index of the callee function in module.functions
        func_idx: u32,
        /// Starting offset of the argument slots in CompiledFunction.call_args
        args_start: u32,
        args_len: u32,
    },
};

pub const CompiledFunction = struct {
    slots_len: u32,
    ops: std.ArrayListUnmanaged(Op),
    /// All call instruction argument slots are stored here (concatenated in call order).
    /// Op.call indexes into the corresponding argument slot segment using (args_start, args_len).
    call_args: std.ArrayListUnmanaged(Slot),
};

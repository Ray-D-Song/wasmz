const std = @import("std");

pub const Slot = u32;

// ── Generic Operation Types ─────────────────────────────────────────────────────

/// Binary operation: applies to all add/sub/mul/and/or/xor/shl/shr/div/rem operations, etc.
/// Generic over the value type (i32, i64, f32, f64)
pub fn BinaryOp(comptime T: type) type {
    return struct {
        dst: Slot,
        lhs: Slot,
        rhs: Slot,

        pub const ValueType = T;
    };
}

/// Unary operation: applies to clz/ctz/popcnt/eqz operations, etc.
/// Generic over the value type (i32, i64)
pub fn UnaryOp(comptime T: type) type {
    return struct {
        dst: Slot,
        src: Slot,

        pub const ValueType = T;
    };
}

/// Compare operation: result is always i32, but input can be any type
/// Generic over the input value type (i32, i64, f32, f64)
pub fn CompareOp(comptime InputT: type) type {
    return struct {
        dst: Slot,
        lhs: Slot,
        rhs: Slot,

        pub const InputType = InputT;
        pub const ResultType = i32;
    };
}

// ── Main Op Union ──────────────────────────────────────────────────────────────

pub const Op = union(enum) {
    /// Trap immediately with UnreachableCodeReached
    unreachable_,

    // ── Constants ───────────────────────────────────────────────────────────────
    const_i32: struct {
        dst: Slot,
        value: i32,
    },
    const_i64: struct {
        dst: Slot,
        value: i64,
    },
    const_f32: struct {
        dst: Slot,
        value: f32,
    },
    const_f64: struct {
        dst: Slot,
        value: f64,
    },

    // ── Variable access ─────────────────────────────────────────────────────────
    local_get: struct {
        dst: Slot,
        local: u32,
    },
    local_set: struct {
        local: u32,
        src: Slot,
    },

    // ── i32 arithmetic operations (using generic BinaryOp) ──────────────────────
    i32_add: BinaryOp(i32),
    i32_sub: BinaryOp(i32),
    i32_mul: BinaryOp(i32),
    // div_s / rem_s may trap: IntegerDivisionByZero (rhs==0) or IntegerOverflow (INT_MIN/-1).
    // div_u / rem_u may trap: IntegerDivisionByZero (rhs==0).
    i32_div_s: BinaryOp(i32),
    i32_div_u: BinaryOp(i32),
    i32_rem_s: BinaryOp(i32),
    i32_rem_u: BinaryOp(i32),
    // bitwise
    i32_and: BinaryOp(i32),
    i32_or: BinaryOp(i32),
    i32_xor: BinaryOp(i32),
    // shift / rotate (Wasm spec: shift amount = rhs & 0x1f mod 32)
    i32_shl: BinaryOp(i32),
    i32_shr_s: BinaryOp(i32),
    i32_shr_u: BinaryOp(i32),
    i32_rotl: BinaryOp(i32),
    i32_rotr: BinaryOp(i32),

    // ── i64 arithmetic operations ───────────────────────────────────────────────
    i64_add: BinaryOp(i64),
    i64_sub: BinaryOp(i64),
    i64_mul: BinaryOp(i64),
    i64_div_s: BinaryOp(i64),
    i64_div_u: BinaryOp(i64),
    i64_rem_s: BinaryOp(i64),
    i64_rem_u: BinaryOp(i64),
    i64_and: BinaryOp(i64),
    i64_or: BinaryOp(i64),
    i64_xor: BinaryOp(i64),
    i64_shl: BinaryOp(i64),
    i64_shr_s: BinaryOp(i64),
    i64_shr_u: BinaryOp(i64),
    i64_rotl: BinaryOp(i64),
    i64_rotr: BinaryOp(i64),

    // ── f32 arithmetic operations ───────────────────────────────────────────────
    f32_add: BinaryOp(f32),
    f32_sub: BinaryOp(f32),
    f32_mul: BinaryOp(f32),
    f32_div: BinaryOp(f32),
    f32_min: BinaryOp(f32),
    f32_max: BinaryOp(f32),
    f32_copysign: BinaryOp(f32),

    // ── f64 arithmetic operations ───────────────────────────────────────────────
    f64_add: BinaryOp(f64),
    f64_sub: BinaryOp(f64),
    f64_mul: BinaryOp(f64),
    f64_div: BinaryOp(f64),
    f64_min: BinaryOp(f64),
    f64_max: BinaryOp(f64),
    f64_copysign: BinaryOp(f64),

    // ── i32 unary operations (using generic UnaryOp) ────────────────────────────
    i32_clz: UnaryOp(i32),
    i32_ctz: UnaryOp(i32),
    i32_popcnt: UnaryOp(i32),

    // ── i64 unary operations ────────────────────────────────────────────────────
    i64_clz: UnaryOp(i64),
    i64_ctz: UnaryOp(i64),
    i64_popcnt: UnaryOp(i64),

    // ── f32 unary operations ────────────────────────────────────────────────────
    f32_abs: UnaryOp(f32),
    f32_neg: UnaryOp(f32),
    f32_ceil: UnaryOp(f32),
    f32_floor: UnaryOp(f32),
    f32_trunc: UnaryOp(f32),
    f32_nearest: UnaryOp(f32),
    f32_sqrt: UnaryOp(f32),

    // ── f64 unary operations ────────────────────────────────────────────────────
    f64_abs: UnaryOp(f64),
    f64_neg: UnaryOp(f64),
    f64_ceil: UnaryOp(f64),
    f64_floor: UnaryOp(f64),
    f64_trunc: UnaryOp(f64),
    f64_nearest: UnaryOp(f64),
    f64_sqrt: UnaryOp(f64),

    // ── i32 comparison operations (using generic CompareOp) ─────────────────────
    i32_eqz: UnaryOp(i32), // special: unary, result is i32
    i32_eq: CompareOp(i32),
    i32_ne: CompareOp(i32),
    i32_lt_s: CompareOp(i32),
    i32_lt_u: CompareOp(i32),
    i32_gt_s: CompareOp(i32),
    i32_gt_u: CompareOp(i32),
    i32_le_s: CompareOp(i32),
    i32_le_u: CompareOp(i32),
    i32_ge_s: CompareOp(i32),
    i32_ge_u: CompareOp(i32),

    // ── i64 comparison operations ───────────────────────────────────────────────
    i64_eqz: UnaryOp(i64), // special: unary, result is i32
    i64_eq: CompareOp(i64),
    i64_ne: CompareOp(i64),
    i64_lt_s: CompareOp(i64),
    i64_lt_u: CompareOp(i64),
    i64_gt_s: CompareOp(i64),
    i64_gt_u: CompareOp(i64),
    i64_le_s: CompareOp(i64),
    i64_le_u: CompareOp(i64),
    i64_ge_s: CompareOp(i64),
    i64_ge_u: CompareOp(i64),

    // ── f32 comparison operations ───────────────────────────────────────────────
    f32_eq: CompareOp(f32),
    f32_ne: CompareOp(f32),
    f32_lt: CompareOp(f32),
    f32_gt: CompareOp(f32),
    f32_le: CompareOp(f32),
    f32_ge: CompareOp(f32),

    // ── f64 comparison operations ───────────────────────────────────────────────
    f64_eq: CompareOp(f64),
    f64_ne: CompareOp(f64),
    f64_lt: CompareOp(f64),
    f64_gt: CompareOp(f64),
    f64_le: CompareOp(f64),
    f64_ge: CompareOp(f64),
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

    // ── i32 load instructions ───────────────────────────────────────────────────
    i32_load: struct { dst: Slot, addr: Slot, offset: u32 },
    i32_load8_s: struct { dst: Slot, addr: Slot, offset: u32 },
    i32_load8_u: struct { dst: Slot, addr: Slot, offset: u32 },
    i32_load16_s: struct { dst: Slot, addr: Slot, offset: u32 },
    i32_load16_u: struct { dst: Slot, addr: Slot, offset: u32 },

    // ── i64 load instructions ───────────────────────────────────────────────────
    i64_load: struct { dst: Slot, addr: Slot, offset: u32 },
    i64_load8_s: struct { dst: Slot, addr: Slot, offset: u32 },
    i64_load8_u: struct { dst: Slot, addr: Slot, offset: u32 },
    i64_load16_s: struct { dst: Slot, addr: Slot, offset: u32 },
    i64_load16_u: struct { dst: Slot, addr: Slot, offset: u32 },
    i64_load32_s: struct { dst: Slot, addr: Slot, offset: u32 },
    i64_load32_u: struct { dst: Slot, addr: Slot, offset: u32 },

    // ── f32/f64 load instructions ───────────────────────────────────────────────
    f32_load: struct { dst: Slot, addr: Slot, offset: u32 },
    f64_load: struct { dst: Slot, addr: Slot, offset: u32 },

    // ── i32 store instructions ──────────────────────────────────────────────────
    i32_store: struct { addr: Slot, src: Slot, offset: u32 },
    i32_store8: struct { addr: Slot, src: Slot, offset: u32 },
    i32_store16: struct { addr: Slot, src: Slot, offset: u32 },

    // ── i64 store instructions ──────────────────────────────────────────────────
    i64_store: struct { addr: Slot, src: Slot, offset: u32 },
    i64_store8: struct { addr: Slot, src: Slot, offset: u32 },
    i64_store16: struct { addr: Slot, src: Slot, offset: u32 },
    i64_store32: struct { addr: Slot, src: Slot, offset: u32 },

    // ── f32/f64 store instructions ──────────────────────────────────────────────
    f32_store: struct { addr: Slot, src: Slot, offset: u32 },
    f64_store: struct { addr: Slot, src: Slot, offset: u32 },
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
    /// Indirect function call via table.
    /// The callee function index is read at runtime from tables[table_index][index_slot].
    /// Runtime checks: TableOutOfBounds, IndirectCallToNull, BadSignature.
    call_indirect: struct {
        /// result slot (void functions have null)
        dst: ?Slot,
        /// Slot holding the runtime table index (i32, interpreted as u32)
        index: Slot,
        /// Type section index — used for runtime signature check
        type_index: u32,
        /// Which table to look up (always 0 in MVP)
        table_index: u32,
        /// Starting offset of the argument slots in CompiledFunction.call_args
        args_start: u32,
        args_len: u32,
    },
    /// Conditional select: if cond != 0 write val1 to dst, else write val2 to dst.
    /// Wasm stack order: val1 pushed first, val2 second, cond last (TOS).
    select: struct {
        dst: Slot,
        val1: Slot,
        val2: Slot,
        cond: Slot,
    },
    /// Multi-way jump table (br_table lowered form).
    /// `index` slot holds the branch index. If index >= targets_len, use the default.
    /// Indexed targets:  br_table_targets[targets_start + 0 .. targets_start + targets_len]
    /// Default target:   br_table_targets[targets_start + targets_len]
    /// So total entries reserved = targets_len + 1.
    jump_table: struct {
        index: Slot,
        /// Starting offset into CompiledFunction.br_table_targets
        targets_start: u32,
        /// Number of indexed targets (not counting the default)
        targets_len: u32,
    },

    // ── Bulk memory instructions ─────────────────────────────────────────────────
    /// memory.init: Copy data from a data segment to linear memory.
    /// `dst_addr` slot holds the destination memory address.
    /// `src_offset` slot holds the offset within the data segment.
    /// `len` slot holds the number of bytes to copy.
    memory_init: struct {
        segment_idx: u32,
        dst_addr: Slot,
        src_offset: Slot,
        len: Slot,
    },
    /// data.drop: Mark a data segment as dropped (no longer usable).
    data_drop: struct {
        segment_idx: u32,
    },
    /// memory.copy: Copy bytes within linear memory.
    /// `dst_addr` slot holds the destination address.
    /// `src_addr` slot holds the source address.
    /// `len` slot holds the number of bytes to copy.
    memory_copy: struct {
        dst_addr: Slot,
        src_addr: Slot,
        len: Slot,
    },
    /// memory.fill: Fill memory region with a byte value.
    /// `dst_addr` slot holds the destination address.
    /// `value` slot holds the byte value to fill.
    /// `len` slot holds the number of bytes to fill.
    memory_fill: struct {
        dst_addr: Slot,
        value: Slot,
        len: Slot,
    },
};

pub const CompiledFunction = struct {
    slots_len: u32,
    ops: std.ArrayListUnmanaged(Op),
    /// All call instruction argument slots are stored here (concatenated in call order).
    /// Op.call indexes into the corresponding argument slot segment using (args_start, args_len).
    call_args: std.ArrayListUnmanaged(Slot),
    /// Resolved target PCs for jump_table (br_table) ops.
    /// Each jump_table op indexes into this with (targets_start, targets_len).
    br_table_targets: std.ArrayListUnmanaged(u32),
};

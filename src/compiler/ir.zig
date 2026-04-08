const std = @import("std");

pub const Slot = u32;

pub const Op = union(enum) {
    /// Trap immediately with UnreachableCodeReached
    unreachable_,
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

    // ── i32 integer division / remainder ────────────────────────────────────────
    // div_s / rem_s may trap: IntegerDivisionByZero (rhs==0) or IntegerOverflow (INT_MIN/-1).
    // div_u / rem_u may trap: IntegerDivisionByZero (rhs==0).
    i32_div_s: struct { dst: Slot, lhs: Slot, rhs: Slot },
    i32_div_u: struct { dst: Slot, lhs: Slot, rhs: Slot },
    i32_rem_s: struct { dst: Slot, lhs: Slot, rhs: Slot },
    i32_rem_u: struct { dst: Slot, lhs: Slot, rhs: Slot },

    // ── i32 bitwise operations ───────────────────────────────────────────────────
    i32_and: struct { dst: Slot, lhs: Slot, rhs: Slot },
    i32_or: struct { dst: Slot, lhs: Slot, rhs: Slot },
    i32_xor: struct { dst: Slot, lhs: Slot, rhs: Slot },

    // ── i32 shift / rotate ───────────────────────────────────────────────────────
    // Wasm spec: shift amount = rhs & 0x1f (mod 32).
    i32_shl: struct { dst: Slot, lhs: Slot, rhs: Slot },
    i32_shr_s: struct { dst: Slot, lhs: Slot, rhs: Slot },
    i32_shr_u: struct { dst: Slot, lhs: Slot, rhs: Slot },
    i32_rotl: struct { dst: Slot, lhs: Slot, rhs: Slot },
    i32_rotr: struct { dst: Slot, lhs: Slot, rhs: Slot },

    // ── i32 unary bit-counting ───────────────────────────────────────────────────
    i32_clz: struct { dst: Slot, src: Slot },
    i32_ctz: struct { dst: Slot, src: Slot },
    i32_popcnt: struct { dst: Slot, src: Slot },

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

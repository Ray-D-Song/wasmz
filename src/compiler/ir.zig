const std = @import("std");
const core = @import("core");

const simd = core.simd;
const SimdOpcode = simd.SimdOpcode;
const V128 = simd.V128;
const HeapType = core.HeapType;

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

/// Conversion operation: consumes one source value and produces one destination value.
/// Generic over source and destination types.
pub fn ConvertOp(comptime SrcT: type, comptime DstT: type) type {
    return struct {
        dst: Slot,
        src: Slot,

        pub const SrcType = SrcT;
        pub const DstType = DstT;
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

pub const SimdUnaryOp = struct {
    dst: Slot,
    opcode: SimdOpcode,
    src: Slot,
};

pub const SimdBinaryOp = struct {
    dst: Slot,
    opcode: SimdOpcode,
    lhs: Slot,
    rhs: Slot,
};

pub const SimdTernaryOp = struct {
    dst: Slot,
    opcode: SimdOpcode,
    first: Slot,
    second: Slot,
    third: Slot,
};

pub const SimdShiftScalarOp = struct {
    dst: Slot,
    opcode: SimdOpcode,
    lhs: Slot,
    rhs: Slot,
};

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
    const_v128: struct {
        dst: Slot,
        value: V128,
    },

    // ── Reference type constants ─────────────────────────────────────────────────
    /// ref.null: push a null reference.
    ///
    /// All reference types (funcref, externref, anyref, eqref, structref, …) share
    /// a single null sentinel: **low64 = 0**.
    ///
    /// funcref values are encoded as `func_idx + 1` by `ref_func` so that
    /// func_idx=0 is never confused with null.
    const_ref_null: struct {
        dst: Slot,
    },
    /// ref.is_null: test whether the reference in `src` is null (low64 == 0).
    /// Writes i32 1 to `dst` if null, else i32 0.
    ref_is_null: struct {
        dst: Slot,
        src: Slot,
    },
    /// ref.func: push a reference to function `func_idx`.
    /// The function index is stored as u64 in low64.
    ref_func: struct {
        dst: Slot,
        func_idx: u32,
    },
    /// ref.eq: compare two references for equality.
    /// Writes i32 1 to `dst` if lhs and rhs have the same low64 bits, else i32 0.
    ref_eq: struct {
        dst: Slot,
        lhs: Slot,
        rhs: Slot,
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

    // ── Numeric conversion and reinterpret operations ────────────────────────
    i32_wrap_i64: ConvertOp(i64, i32),
    i32_trunc_f32_s: ConvertOp(f32, i32),
    i32_trunc_f32_u: ConvertOp(f32, i32),
    i32_trunc_f64_s: ConvertOp(f64, i32),
    i32_trunc_f64_u: ConvertOp(f64, i32),
    i64_extend_i32_s: ConvertOp(i32, i64),
    i64_extend_i32_u: ConvertOp(i32, i64),
    i64_trunc_f32_s: ConvertOp(f32, i64),
    i64_trunc_f32_u: ConvertOp(f32, i64),
    i64_trunc_f64_s: ConvertOp(f64, i64),
    i64_trunc_f64_u: ConvertOp(f64, i64),
    i32_trunc_sat_f32_s: ConvertOp(f32, i32),
    i32_trunc_sat_f32_u: ConvertOp(f32, i32),
    i32_trunc_sat_f64_s: ConvertOp(f64, i32),
    i32_trunc_sat_f64_u: ConvertOp(f64, i32),
    i64_trunc_sat_f32_s: ConvertOp(f32, i64),
    i64_trunc_sat_f32_u: ConvertOp(f32, i64),
    i64_trunc_sat_f64_s: ConvertOp(f64, i64),
    i64_trunc_sat_f64_u: ConvertOp(f64, i64),
    f32_convert_i32_s: ConvertOp(i32, f32),
    f32_convert_i32_u: ConvertOp(i32, f32),
    f32_convert_i64_s: ConvertOp(i64, f32),
    f32_convert_i64_u: ConvertOp(i64, f32),
    f32_demote_f64: ConvertOp(f64, f32),
    f64_convert_i32_s: ConvertOp(i32, f64),
    f64_convert_i32_u: ConvertOp(i32, f64),
    f64_convert_i64_s: ConvertOp(i64, f64),
    f64_convert_i64_u: ConvertOp(i64, f64),
    f64_promote_f32: ConvertOp(f32, f64),
    i32_reinterpret_f32: ConvertOp(f32, i32),
    i64_reinterpret_f64: ConvertOp(f64, i64),
    f32_reinterpret_i32: ConvertOp(i32, f32),
    f64_reinterpret_i64: ConvertOp(i64, f64),

    // ── Sign-extension operations ────────────────────────────────────────────
    i32_extend8_s: ConvertOp(i32, i32),
    i32_extend16_s: ConvertOp(i32, i32),
    i64_extend8_s: ConvertOp(i64, i64),
    i64_extend16_s: ConvertOp(i64, i64),
    i64_extend32_s: ConvertOp(i64, i64),

    // ── SIMD operations ───────────────────────────────────────────────────────
    simd_unary: SimdUnaryOp,
    simd_binary: SimdBinaryOp,
    simd_ternary: SimdTernaryOp,
    simd_compare: SimdBinaryOp,
    simd_shift_scalar: SimdShiftScalarOp,
    simd_extract_lane: struct {
        dst: Slot,
        opcode: SimdOpcode,
        src: Slot,
        lane: u8,
    },
    simd_replace_lane: struct {
        dst: Slot,
        opcode: SimdOpcode,
        src_vec: Slot,
        src_lane: Slot,
        lane: u8,
    },
    simd_shuffle: struct {
        dst: Slot,
        lhs: Slot,
        rhs: Slot,
        lanes: [16]u8,
    },
    simd_load: struct {
        dst: Slot,
        opcode: SimdOpcode,
        addr: Slot,
        offset: u32,
        lane: ?u8,
        src_vec: ?Slot,
    },
    simd_store: struct {
        opcode: SimdOpcode,
        addr: Slot,
        src: Slot,
        offset: u32,
        lane: ?u8,
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
    /// Tail call: direct function call that reuses the current stack frame.
    /// Unlike regular call, this does not create a new frame; instead it replaces
    /// the current frame with the callee, passing the return value to the caller's caller.
    return_call: struct {
        /// Index of the callee function in module.functions
        func_idx: u32,
        /// Starting offset of the argument slots in CompiledFunction.call_args
        args_start: u32,
        args_len: u32,
    },
    /// Tail call indirect: indirect function call via table that reuses the current stack frame.
    return_call_indirect: struct {
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

    // ── Table instructions ────────────────────────────────────────────────────────
    /// table.get: read the element at `index` from table `table_index`.
    /// Traps if `index` is out of bounds.
    /// Pushes the funcref value (u32 func_idx, or maxInt(u32) for null) into `dst`.
    table_get: struct {
        dst: Slot,
        table_index: u32,
        index: Slot,
    },
    /// table.set: write `value` (funcref as u32) into table `table_index` at position `index`.
    /// Traps if `index` is out of bounds.
    table_set: struct {
        table_index: u32,
        index: Slot,
        value: Slot,
    },
    /// table.size: push i32 current element count of table `table_index`.
    table_size: struct {
        dst: Slot,
        table_index: u32,
    },
    /// table.grow: grow table `table_index` by `delta` elements initialised to `init`.
    /// Pushes i32 old size on success, or -1 if growth fails.
    table_grow: struct {
        dst: Slot,
        table_index: u32,
        init: Slot,
        delta: Slot,
    },
    /// table.fill: fill `len` elements of table `table_index` starting at `dst_idx` with `value`.
    /// Traps if the range is out of bounds.
    table_fill: struct {
        table_index: u32,
        dst_idx: Slot,
        value: Slot,
        len: Slot,
    },
    /// table.copy: copy `len` elements from table `src_table` starting at `src_idx`
    /// into table `dst_table` starting at `dst_idx`.
    /// Traps if either range is out of bounds.
    table_copy: struct {
        dst_table: u32,
        src_table: u32,
        dst_idx: Slot,
        src_idx: Slot,
        len: Slot,
    },
    /// table.init: copy `len` elements from passive element segment `segment_idx`
    /// (starting at offset `src_offset`) into table `table_index` at position `dst_idx`.
    /// Traps if either range is out of bounds or the segment has been dropped.
    table_init: struct {
        table_index: u32,
        segment_idx: u32,
        dst_idx: Slot,
        src_offset: Slot,
        len: Slot,
    },
    /// elem.drop: mark element segment `segment_idx` as dropped (no longer usable by table.init).
    elem_drop: struct {
        segment_idx: u32,
    },

    // ── GC Struct instructions ─────────────────────────────────────────────────────
    /// struct.new: allocate struct and initialize with N field values from slots.
    /// Fields are popped from stack in reverse order (last field = TOS).
    /// args_start/args_len index into CompiledFunction.call_args.
    struct_new: struct {
        dst: Slot,
        type_idx: u32,
        args_start: u32,
        args_len: u32,
    },
    /// struct.new_default: allocate struct with default field values (0/null).
    struct_new_default: struct {
        dst: Slot,
        type_idx: u32,
    },
    /// struct.get: read field value from struct reference.
    struct_get: struct {
        dst: Slot,
        ref: Slot,
        type_idx: u32,
        field_idx: u32,
    },
    /// struct.get_s: read signed field value (for packed types i8/i16, sign-extended).
    struct_get_s: struct {
        dst: Slot,
        ref: Slot,
        type_idx: u32,
        field_idx: u32,
    },
    /// struct.get_u: read unsigned field value (for packed types i8/i16, zero-extended).
    struct_get_u: struct {
        dst: Slot,
        ref: Slot,
        type_idx: u32,
        field_idx: u32,
    },
    /// struct.set: write value to struct field.
    struct_set: struct {
        ref: Slot,
        value: Slot,
        type_idx: u32,
        field_idx: u32,
    },

    // ── GC Array instructions ──────────────────────────────────────────────────────
    /// array.new: allocate array with `len` copies of `init` value.
    array_new: struct {
        dst: Slot,
        init: Slot,
        len: Slot,
        type_idx: u32,
    },
    /// array.new_default: allocate array with default element values.
    array_new_default: struct {
        dst: Slot,
        len: Slot,
        type_idx: u32,
    },
    /// array.new_fixed: allocate fixed-size array from N elements on stack.
    /// Elements are popped in reverse order (last element = TOS).
    array_new_fixed: struct {
        dst: Slot,
        type_idx: u32,
        args_start: u32,
        args_len: u32,
    },
    /// array.new_data: allocate array from data segment.
    array_new_data: struct {
        dst: Slot,
        offset: Slot,
        len: Slot,
        type_idx: u32,
        data_idx: u32,
    },
    /// array.new_elem: allocate array from element segment.
    array_new_elem: struct {
        dst: Slot,
        offset: Slot,
        len: Slot,
        type_idx: u32,
        elem_idx: u32,
    },
    /// array.get: read element at index from array reference.
    array_get: struct {
        dst: Slot,
        ref: Slot,
        index: Slot,
        type_idx: u32,
    },
    /// array.get_s: read signed element (for packed types, sign-extended).
    array_get_s: struct {
        dst: Slot,
        ref: Slot,
        index: Slot,
        type_idx: u32,
    },
    /// array.get_u: read unsigned element (for packed types, zero-extended).
    array_get_u: struct {
        dst: Slot,
        ref: Slot,
        index: Slot,
        type_idx: u32,
    },
    /// array.set: write value to array element at index.
    array_set: struct {
        ref: Slot,
        index: Slot,
        value: Slot,
        type_idx: u32,
    },
    /// array.len: read array length (i32).
    array_len: struct {
        dst: Slot,
        ref: Slot,
    },
    /// array.fill: fill array region with value.
    array_fill: struct {
        ref: Slot,
        offset: Slot,
        value: Slot,
        n: Slot,
        type_idx: u32,
    },
    /// array.copy: copy elements from src array to dst array.
    array_copy: struct {
        dst_ref: Slot,
        dst_offset: Slot,
        src_ref: Slot,
        src_offset: Slot,
        n: Slot,
        dst_type_idx: u32,
        src_type_idx: u32,
    },
    /// array.init_data: initialize array from data segment.
    array_init_data: struct {
        ref: Slot,
        d: Slot,
        s: Slot,
        n: Slot,
        type_idx: u32,
        data_idx: u32,
    },
    /// array.init_elem: initialize array from element segment.
    array_init_elem: struct {
        ref: Slot,
        d: Slot,
        s: Slot,
        n: Slot,
        type_idx: u32,
        elem_idx: u32,
    },

    // ── GC i31 instructions ────────────────────────────────────────────────────────
    /// ref.i31: pack i32 value into i31ref.
    ref_i31: struct {
        dst: Slot,
        value: Slot,
    },
    /// i31.get_s: extract signed i31 value (sign-extended to i32).
    i31_get_s: struct {
        dst: Slot,
        ref: Slot,
    },
    /// i31.get_u: extract unsigned i31 value (zero-extended to i32).
    i31_get_u: struct {
        dst: Slot,
        ref: Slot,
    },

    // ── GC Type Test/Cast instructions ─────────────────────────────────────────────
    /// ref.test: test if reference matches type (returns i32 0/1).
    ref_test: struct {
        dst: Slot,
        ref: Slot,
        type_idx: u32,
    },
    /// ref.cast: cast reference to type (traps on failure).
    ref_cast: struct {
        dst: Slot,
        ref: Slot,
        type_idx: u32,
    },
    /// ref.as_non_null: cast nullable ref to non-null (traps if null).
    ref_as_non_null: struct {
        dst: Slot,
        ref: Slot,
    },

    // ── GC Control Flow instructions ────────────────────────────────────────────────
    /// br_on_null: branch if ref is null (ref consumed), else continue with ref.
    br_on_null: struct {
        ref: Slot,
        target: u32,
    },
    /// br_on_non_null: branch if ref is non-null (ref pushed back), else continue.
    br_on_non_null: struct {
        ref: Slot,
        target: u32,
    },
    /// br_on_cast: branch if ref can be cast to target type.
    br_on_cast: struct {
        ref: Slot,
        target: u32,
        from_type_idx: u32,
        to_type_idx: u32,
    },
    /// br_on_cast_fail: branch if ref CANNOT be cast to target type.
    br_on_cast_fail: struct {
        ref: Slot,
        target: u32,
        from_type_idx: u32,
        to_type_idx: u32,
    },

    // ── GC Call instructions ───────────────────────────────────────────────────────
    /// call_ref: indirect call via funcref.
    call_ref: struct {
        dst: ?Slot,
        ref: Slot,
        type_idx: u32,
        args_start: u32,
        args_len: u32,
    },
    /// return_call_ref: tail call via funcref.
    return_call_ref: struct {
        ref: Slot,
        type_idx: u32,
        args_start: u32,
        args_len: u32,
    },

    // ── GC Extern/Any conversion instructions ──────────────────────────────────────
    /// any.convert_extern: convert externref to anyref.
    any_convert_extern: struct {
        dst: Slot,
        ref: Slot,
    },
    /// extern.convert_any: convert anyref to externref.
    extern_convert_any: struct {
        dst: Slot,
        ref: Slot,
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

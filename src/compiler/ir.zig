const std = @import("std");
const core = @import("core");

const simd = core.simd;
const SimdOpcode = simd.SimdOpcode;
const V128 = simd.V128;
const HeapType = core.HeapType;

pub const Slot = u16;

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

/// Fused: binop with immediate rhs — replaces `const_i32 { dst=T, value=K }` + `i32_xxx { dst=D, lhs=S, rhs=T }`.
/// `{ dst: Slot, lhs: Slot, imm: i32 }` — 12 bytes → stride 24 (same as OpsDstLhsRhs).
pub fn BinaryOpImm(comptime T: type) type {
    return struct {
        dst: Slot,
        lhs: Slot,
        imm: T,

        pub const ValueType = T;
    };
}

/// r0 variant of BinaryOpImm: lhs is read from the r0 accumulator register,
/// so no `lhs` slot field is needed.  Saves one 16-bit field per instruction
/// and one memory load per execution.
pub fn BinaryOpImmR0(comptime T: type) type {
    return struct {
        dst: Slot,
        imm: T,

        pub const ValueType = T;
    };
}

/// Fused: compare + jump_if_z — replaces `i32_xxx_cmp { dst=C, lhs=A, rhs=B }` + `jump_if_z { cond=C, rel=R }`.
/// Jumps to `target` (op-index, converted to relative byte offset at encode time)
/// when the comparison is FALSE (i.e. jump when compare result == 0).
pub fn CompareJumpOp(comptime InputT: type) type {
    return struct {
        lhs: Slot,
        rhs: Slot,
        /// Op-index of the jump target (converted to relative byte offset by the encoder).
        target: u32,

        pub const InputType = InputT;
    };
}

/// Fused: binop result written directly into a local slot — replaces `i32_xxx { dst=T, lhs=A, rhs=B }` + `local_set { local=L, src=T }`.
/// `{ local: Slot, lhs: Slot, rhs: Slot }` — 12 bytes → stride 24 (same as OpsDstLhsRhs).
pub fn BinaryOpToLocal(comptime T: type) type {
    return struct {
        local: Slot,
        lhs: Slot,
        rhs: Slot,

        pub const ValueType = T;
    };
}

/// Fused: binop + local_tee — writes result to both a stack slot and a local.
/// `{ dst: Slot, local: Slot, lhs: Slot, rhs: Slot }` — 8 bytes → stride 16.
pub fn BinaryOpTeeLocal(comptime T: type) type {
    return struct {
        dst: Slot,
        local: Slot,
        lhs: Slot,
        rhs: Slot,

        pub const ValueType = T;
    };
}

/// Fused: comparison + local_set — writes i32 comparison result directly into a local slot.
/// `{ local: Slot, lhs: Slot, rhs: Slot }` — 12 bytes → stride 24.
pub fn CompareOpToLocal(comptime InputT: type) type {
    return struct {
        local: Slot,
        lhs: Slot,
        rhs: Slot,

        pub const InputType = InputT;
        pub const ValueType = i32;
    };
}

/// Fused: const + binop + local_set → binop_imm_to_local (Candidate E).
/// i32: `{ local: Slot, lhs: Slot, imm: i32 }` — 12 bytes → stride 24.
/// i64: `{ local: Slot, lhs: Slot, imm: i64 }` (encoder adds padding) → stride 32.
pub fn BinaryOpImmToLocal(comptime T: type) type {
    return struct {
        local: Slot,
        lhs: Slot,
        imm: T,

        pub const ValueType = T;
    };
}

/// Fused: local_get + binop_imm + local_set where dst local == src local (Candidate H).
/// i32: `{ local: Slot, imm: i32 }` — 8 bytes → stride 16.
/// i64: `{ local: Slot, imm: i64 }` (encoder adds padding) → stride 24.
pub fn LocalInplace(comptime T: type) type {
    return struct {
        local: Slot,
        imm: T,

        pub const ValueType = T;
    };
}

/// Fused: const + local_set → write constant directly to local.
/// Same layout as LocalInplace but different semantic name for clarity.
pub fn ConstToLocal(comptime T: type) type {
    return struct {
        local: Slot,
        value: T,

        pub const ValueType = T;
    };
}

/// Fused: const + compare + br_if → compare_imm_jump_if_false (Candidate G).
/// Jumps to `target` when comparison is FALSE.
/// i32: `{ lhs: Slot, imm: i32, target: u32 }`.
/// i64: `{ lhs: Slot, imm: i64, target: u32 }` (encoder adds padding).
pub fn CompareImmJumpOp(comptime InputT: type) type {
    return struct {
        lhs: Slot,
        imm: InputT,
        /// Op-index of the jump target (converted to relative byte offset by encoder).
        target: u32,

        pub const InputType = InputT;
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

// ── Atomic operation helper types ─────────────────────────────────────────────

/// Natural access width for atomic load/store/rmw/cmpxchg operations.
/// The value indicates the number of bytes accessed in memory; values narrower
/// than the Wasm result type are zero-extended into the destination slot.
pub const AtomicWidth = enum(u8) {
    /// 1-byte access (i32_atomic_load8_u / i32_atomic_rmw8_* / …)
    @"8" = 1,
    /// 2-byte access
    @"16" = 2,
    /// 4-byte access (i32_atomic_load / i64_atomic_load32_* / …)
    @"32" = 4,
    /// 8-byte access (i64_atomic_load / …)
    @"64" = 8,

    pub fn byteSize(self: AtomicWidth) usize {
        return switch (self) {
            .@"8" => 1,
            .@"16" => 2,
            .@"32" => 4,
            .@"64" => 8,
        };
    }
};

/// Whether the result slot is treated as i32 or i64 by the caller.
pub const AtomicType = enum { i32, i64 };

/// The read-modify-write operation applied by atomic.rmw.
pub const AtomicRmwOp = enum { add, sub, @"and", @"or", xor, xchg };

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
        local: Slot,
    },
    local_set: struct {
        local: Slot,
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

    // ── Fused: binop with immediate rhs (C: const_i32 + binop → xxx_imm) ─────
    // i32 arithmetic-imm: rhs is an i32 literal embedded in the instruction
    i32_add_imm: BinaryOpImm(i32),
    i32_sub_imm: BinaryOpImm(i32),
    i32_mul_imm: BinaryOpImm(i32),
    i32_and_imm: BinaryOpImm(i32),
    i32_or_imm: BinaryOpImm(i32),
    i32_xor_imm: BinaryOpImm(i32),
    i32_shl_imm: BinaryOpImm(i32),
    i32_shr_s_imm: BinaryOpImm(i32),
    i32_shr_u_imm: BinaryOpImm(i32),
    // i32 compare-imm: produces an i32 boolean
    i32_eq_imm: BinaryOpImm(i32),
    i32_ne_imm: BinaryOpImm(i32),
    i32_lt_s_imm: BinaryOpImm(i32),
    i32_lt_u_imm: BinaryOpImm(i32),
    i32_gt_s_imm: BinaryOpImm(i32),
    i32_gt_u_imm: BinaryOpImm(i32),
    i32_le_s_imm: BinaryOpImm(i32),
    i32_le_u_imm: BinaryOpImm(i32),
    i32_ge_s_imm: BinaryOpImm(i32),
    i32_ge_u_imm: BinaryOpImm(i32),
    // i64 arithmetic-imm: rhs is an i64 literal embedded in the instruction
    i64_add_imm: BinaryOpImm(i64),
    i64_sub_imm: BinaryOpImm(i64),
    i64_mul_imm: BinaryOpImm(i64),
    i64_and_imm: BinaryOpImm(i64),
    i64_or_imm: BinaryOpImm(i64),
    i64_xor_imm: BinaryOpImm(i64),
    i64_shl_imm: BinaryOpImm(i64),
    i64_shr_s_imm: BinaryOpImm(i64),
    i64_shr_u_imm: BinaryOpImm(i64),
    // i64 compare-imm: produces an i32 boolean
    i64_eq_imm: BinaryOpImm(i64),
    i64_ne_imm: BinaryOpImm(i64),
    i64_lt_s_imm: BinaryOpImm(i64),
    i64_lt_u_imm: BinaryOpImm(i64),
    i64_gt_s_imm: BinaryOpImm(i64),
    i64_gt_u_imm: BinaryOpImm(i64),
    i64_le_s_imm: BinaryOpImm(i64),
    i64_le_u_imm: BinaryOpImm(i64),
    i64_ge_s_imm: BinaryOpImm(i64),
    i64_ge_u_imm: BinaryOpImm(i64),

    // ── r0 variants: lhs comes from r0 accumulator, no lhs slot in encoding ──
    // i32 arithmetic-imm r0: lhs = r0
    i32_add_imm_r: BinaryOpImmR0(i32),
    i32_sub_imm_r: BinaryOpImmR0(i32),
    i32_mul_imm_r: BinaryOpImmR0(i32),
    i32_and_imm_r: BinaryOpImmR0(i32),
    i32_or_imm_r: BinaryOpImmR0(i32),
    i32_xor_imm_r: BinaryOpImmR0(i32),
    i32_shl_imm_r: BinaryOpImmR0(i32),
    i32_shr_s_imm_r: BinaryOpImmR0(i32),
    i32_shr_u_imm_r: BinaryOpImmR0(i32),
    // i64 arithmetic-imm r0: lhs = r0
    i64_add_imm_r: BinaryOpImmR0(i64),
    i64_sub_imm_r: BinaryOpImmR0(i64),
    i64_mul_imm_r: BinaryOpImmR0(i64),
    i64_and_imm_r: BinaryOpImmR0(i64),
    i64_or_imm_r: BinaryOpImmR0(i64),
    i64_xor_imm_r: BinaryOpImmR0(i64),
    i64_shl_imm_r: BinaryOpImmR0(i64),
    i64_shr_s_imm_r: BinaryOpImmR0(i64),
    i64_shr_u_imm_r: BinaryOpImmR0(i64),

    // ── Fused: compare + jump_if_z (F: cmp + branch → cmp_jump) ─────────────
    // Jumps to rel_target (from instruction start) when the comparison is FALSE.
    // i32 compare-jump variants
    i32_eq_jump_if_false: CompareJumpOp(i32),
    i32_ne_jump_if_false: CompareJumpOp(i32),
    i32_lt_s_jump_if_false: CompareJumpOp(i32),
    i32_lt_u_jump_if_false: CompareJumpOp(i32),
    i32_gt_s_jump_if_false: CompareJumpOp(i32),
    i32_gt_u_jump_if_false: CompareJumpOp(i32),
    i32_le_s_jump_if_false: CompareJumpOp(i32),
    i32_le_u_jump_if_false: CompareJumpOp(i32),
    i32_ge_s_jump_if_false: CompareJumpOp(i32),
    i32_ge_u_jump_if_false: CompareJumpOp(i32),
    // i32 eqz-jump (unary: jumps when src != 0, i.e. when eqz is false)
    i32_eqz_jump_if_false: struct { src: Slot, target: u32 },
    // i64 compare-jump variants
    i64_eq_jump_if_false: CompareJumpOp(i64),
    i64_ne_jump_if_false: CompareJumpOp(i64),
    i64_lt_s_jump_if_false: CompareJumpOp(i64),
    i64_lt_u_jump_if_false: CompareJumpOp(i64),
    i64_gt_s_jump_if_false: CompareJumpOp(i64),
    i64_gt_u_jump_if_false: CompareJumpOp(i64),
    i64_le_s_jump_if_false: CompareJumpOp(i64),
    i64_le_u_jump_if_false: CompareJumpOp(i64),
    i64_ge_s_jump_if_false: CompareJumpOp(i64),
    i64_ge_u_jump_if_false: CompareJumpOp(i64),
    // i64 eqz-jump (unary: jumps when src != 0, i.e. when eqz is false)
    i64_eqz_jump_if_false: struct { src: Slot, target: u32 },

    // ── Fused: compare + jump_if_true (J: cmp + br_if → cmp_jump_if_true) ────
    // Peephole J: replaces the 2-op pattern:
    //   compare_jump_if_false → continue_pc
    //   jump → target
    // with a single op that jumps to `target` when the comparison is TRUE.
    // i32 compare-jump-if-true variants
    i32_eq_jump_if_true: CompareJumpOp(i32),
    i32_ne_jump_if_true: CompareJumpOp(i32),
    i32_lt_s_jump_if_true: CompareJumpOp(i32),
    i32_lt_u_jump_if_true: CompareJumpOp(i32),
    i32_gt_s_jump_if_true: CompareJumpOp(i32),
    i32_gt_u_jump_if_true: CompareJumpOp(i32),
    i32_le_s_jump_if_true: CompareJumpOp(i32),
    i32_le_u_jump_if_true: CompareJumpOp(i32),
    i32_ge_s_jump_if_true: CompareJumpOp(i32),
    i32_ge_u_jump_if_true: CompareJumpOp(i32),
    // i32 eqz-jump-if-true (unary: jumps when src == 0, i.e. when eqz is true)
    i32_eqz_jump_if_true: struct { src: Slot, target: u32 },
    // i64 compare-jump-if-true variants
    i64_eq_jump_if_true: CompareJumpOp(i64),
    i64_ne_jump_if_true: CompareJumpOp(i64),
    i64_lt_s_jump_if_true: CompareJumpOp(i64),
    i64_lt_u_jump_if_true: CompareJumpOp(i64),
    i64_gt_s_jump_if_true: CompareJumpOp(i64),
    i64_gt_u_jump_if_true: CompareJumpOp(i64),
    i64_le_s_jump_if_true: CompareJumpOp(i64),
    i64_le_u_jump_if_true: CompareJumpOp(i64),
    i64_ge_s_jump_if_true: CompareJumpOp(i64),
    i64_ge_u_jump_if_true: CompareJumpOp(i64),
    // i64 eqz-jump-if-true (unary: jumps when src == 0, i.e. when eqz is true)
    i64_eqz_jump_if_true: struct { src: Slot, target: u32 },

    // ── Fused: binop result to local (D: binop + local_set → binop_to_local) ─
    i32_add_to_local: BinaryOpToLocal(i32),
    i32_sub_to_local: BinaryOpToLocal(i32),
    i32_mul_to_local: BinaryOpToLocal(i32),
    i32_and_to_local: BinaryOpToLocal(i32),
    i32_or_to_local: BinaryOpToLocal(i32),
    i32_xor_to_local: BinaryOpToLocal(i32),
    i32_shl_to_local: BinaryOpToLocal(i32),
    i32_shr_s_to_local: BinaryOpToLocal(i32),
    i32_shr_u_to_local: BinaryOpToLocal(i32),
    // i64 binop-to-local variants
    i64_add_to_local: BinaryOpToLocal(i64),
    i64_sub_to_local: BinaryOpToLocal(i64),
    i64_mul_to_local: BinaryOpToLocal(i64),
    i64_and_to_local: BinaryOpToLocal(i64),
    i64_or_to_local: BinaryOpToLocal(i64),
    i64_xor_to_local: BinaryOpToLocal(i64),
    i64_shl_to_local: BinaryOpToLocal(i64),
    i64_shr_s_to_local: BinaryOpToLocal(i64),
    i64_shr_u_to_local: BinaryOpToLocal(i64),

    // ── Fused: binop + local_tee → binop_tee_local ────────────────────────
    i32_add_tee_local: BinaryOpTeeLocal(i32),
    i32_sub_tee_local: BinaryOpTeeLocal(i32),
    i32_mul_tee_local: BinaryOpTeeLocal(i32),
    i32_and_tee_local: BinaryOpTeeLocal(i32),
    i32_or_tee_local: BinaryOpTeeLocal(i32),
    i32_xor_tee_local: BinaryOpTeeLocal(i32),
    i32_shl_tee_local: BinaryOpTeeLocal(i32),
    i32_shr_s_tee_local: BinaryOpTeeLocal(i32),
    i32_shr_u_tee_local: BinaryOpTeeLocal(i32),
    i64_add_tee_local: BinaryOpTeeLocal(i64),
    i64_sub_tee_local: BinaryOpTeeLocal(i64),
    i64_mul_tee_local: BinaryOpTeeLocal(i64),
    i64_and_tee_local: BinaryOpTeeLocal(i64),
    i64_or_tee_local: BinaryOpTeeLocal(i64),
    i64_xor_tee_local: BinaryOpTeeLocal(i64),
    i64_shl_tee_local: BinaryOpTeeLocal(i64),
    i64_shr_s_tee_local: BinaryOpTeeLocal(i64),
    i64_shr_u_tee_local: BinaryOpTeeLocal(i64),

    // ── Fused: comparison + local_set (cmp_to_local) ──────────────────────
    i32_eq_to_local: CompareOpToLocal(i32),
    i32_ne_to_local: CompareOpToLocal(i32),
    i32_lt_s_to_local: CompareOpToLocal(i32),
    i32_lt_u_to_local: CompareOpToLocal(i32),
    i32_gt_s_to_local: CompareOpToLocal(i32),
    i32_gt_u_to_local: CompareOpToLocal(i32),
    i32_le_s_to_local: CompareOpToLocal(i32),
    i32_le_u_to_local: CompareOpToLocal(i32),
    i32_ge_s_to_local: CompareOpToLocal(i32),
    i32_ge_u_to_local: CompareOpToLocal(i32),
    i64_eq_to_local: CompareOpToLocal(i64),
    i64_ne_to_local: CompareOpToLocal(i64),
    i64_lt_s_to_local: CompareOpToLocal(i64),
    i64_lt_u_to_local: CompareOpToLocal(i64),
    i64_gt_s_to_local: CompareOpToLocal(i64),
    i64_gt_u_to_local: CompareOpToLocal(i64),
    i64_le_s_to_local: CompareOpToLocal(i64),
    i64_le_u_to_local: CompareOpToLocal(i64),
    i64_ge_s_to_local: CompareOpToLocal(i64),
    i64_ge_u_to_local: CompareOpToLocal(i64),

    // ── Fused: binop-imm-to-local (E: const + binop + local_set → binop_imm_to_local) ──
    // i32 arithmetic-imm-to-local
    i32_add_imm_to_local: BinaryOpImmToLocal(i32),
    i32_sub_imm_to_local: BinaryOpImmToLocal(i32),
    i32_mul_imm_to_local: BinaryOpImmToLocal(i32),
    i32_and_imm_to_local: BinaryOpImmToLocal(i32),
    i32_or_imm_to_local: BinaryOpImmToLocal(i32),
    i32_xor_imm_to_local: BinaryOpImmToLocal(i32),
    i32_shl_imm_to_local: BinaryOpImmToLocal(i32),
    i32_shr_s_imm_to_local: BinaryOpImmToLocal(i32),
    i32_shr_u_imm_to_local: BinaryOpImmToLocal(i32),
    // i64 arithmetic-imm-to-local
    i64_add_imm_to_local: BinaryOpImmToLocal(i64),
    i64_sub_imm_to_local: BinaryOpImmToLocal(i64),
    i64_mul_imm_to_local: BinaryOpImmToLocal(i64),
    i64_and_imm_to_local: BinaryOpImmToLocal(i64),
    i64_or_imm_to_local: BinaryOpImmToLocal(i64),
    i64_xor_imm_to_local: BinaryOpImmToLocal(i64),
    i64_shl_imm_to_local: BinaryOpImmToLocal(i64),
    i64_shr_s_imm_to_local: BinaryOpImmToLocal(i64),
    i64_shr_u_imm_to_local: BinaryOpImmToLocal(i64),

    // ── Fused: local inplace (H: local_get + binop_imm + local_set, same local) ──
    // i32 local-inplace
    i32_add_local_inplace: LocalInplace(i32),
    i32_sub_local_inplace: LocalInplace(i32),
    i32_mul_local_inplace: LocalInplace(i32),
    i32_and_local_inplace: LocalInplace(i32),
    i32_or_local_inplace: LocalInplace(i32),
    i32_xor_local_inplace: LocalInplace(i32),
    i32_shl_local_inplace: LocalInplace(i32),
    i32_shr_s_local_inplace: LocalInplace(i32),
    i32_shr_u_local_inplace: LocalInplace(i32),
    // i64 local-inplace
    i64_add_local_inplace: LocalInplace(i64),
    i64_sub_local_inplace: LocalInplace(i64),
    i64_mul_local_inplace: LocalInplace(i64),
    i64_and_local_inplace: LocalInplace(i64),
    i64_or_local_inplace: LocalInplace(i64),
    i64_xor_local_inplace: LocalInplace(i64),
    i64_shl_local_inplace: LocalInplace(i64),
    i64_shr_s_local_inplace: LocalInplace(i64),
    i64_shr_u_local_inplace: LocalInplace(i64),

    // ── Fused: const + local_set → const_to_local (just write constant to local) ──
    i32_const_to_local: ConstToLocal(i32),
    i64_const_to_local: ConstToLocal(i64),

    // ── Superinstruction: i32_imm + local_set → imm_to_local ──────────────────
    // Combines: (const_i32 writes to tmp) + (local_set copies tmp to local)
    // Into: single instruction that writes imm directly to local, preserving src.
    i32_imm_to_local: struct { local: Slot, src: Slot, imm: i32 },
    i64_imm_to_local: struct { local: Slot, src: Slot, imm: i64 },

    // ── Fused: global_get + local_set → global_get_to_local ──
    global_get_to_local: struct {
        local: Slot,
        global_idx: u32,
    },

    // ── Fused: i32/i64 load + local_set → load_to_local ──
    i32_load_to_local: struct { local: Slot, addr: Slot, offset: u32 },
    i64_load_to_local: struct { local: Slot, addr: Slot, offset: u32 },

    // ── Fused: compare-imm + jump_if_false (G: const + compare + br_if) ─────
    // i32 compare-imm-jump
    i32_eq_imm_jump_if_false: CompareImmJumpOp(i32),
    i32_ne_imm_jump_if_false: CompareImmJumpOp(i32),
    i32_lt_s_imm_jump_if_false: CompareImmJumpOp(i32),
    i32_lt_u_imm_jump_if_false: CompareImmJumpOp(i32),
    i32_gt_s_imm_jump_if_false: CompareImmJumpOp(i32),
    i32_gt_u_imm_jump_if_false: CompareImmJumpOp(i32),
    i32_le_s_imm_jump_if_false: CompareImmJumpOp(i32),
    i32_le_u_imm_jump_if_false: CompareImmJumpOp(i32),
    i32_ge_s_imm_jump_if_false: CompareImmJumpOp(i32),
    i32_ge_u_imm_jump_if_false: CompareImmJumpOp(i32),
    // i64 compare-imm-jump
    i64_eq_imm_jump_if_false: CompareImmJumpOp(i64),
    i64_ne_imm_jump_if_false: CompareImmJumpOp(i64),
    i64_lt_s_imm_jump_if_false: CompareImmJumpOp(i64),
    i64_lt_u_imm_jump_if_false: CompareImmJumpOp(i64),
    i64_gt_s_imm_jump_if_false: CompareImmJumpOp(i64),
    i64_gt_u_imm_jump_if_false: CompareImmJumpOp(i64),
    i64_le_s_imm_jump_if_false: CompareImmJumpOp(i64),
    i64_le_u_imm_jump_if_false: CompareImmJumpOp(i64),
    i64_ge_s_imm_jump_if_false: CompareImmJumpOp(i64),
    i64_ge_u_imm_jump_if_false: CompareImmJumpOp(i64),

    // ── Fused: compare-imm + jump_if_true (J-imm: const + compare + br_if, true branch) ─
    // i32 compare-imm-jump, true-branch
    i32_eq_imm_jump_if_true: CompareImmJumpOp(i32),
    i32_ne_imm_jump_if_true: CompareImmJumpOp(i32),
    i32_lt_s_imm_jump_if_true: CompareImmJumpOp(i32),
    i32_lt_u_imm_jump_if_true: CompareImmJumpOp(i32),
    i32_gt_s_imm_jump_if_true: CompareImmJumpOp(i32),
    i32_gt_u_imm_jump_if_true: CompareImmJumpOp(i32),
    i32_le_s_imm_jump_if_true: CompareImmJumpOp(i32),
    i32_le_u_imm_jump_if_true: CompareImmJumpOp(i32),
    i32_ge_s_imm_jump_if_true: CompareImmJumpOp(i32),
    i32_ge_u_imm_jump_if_true: CompareImmJumpOp(i32),
    // i64 compare-imm-jump, true-branch
    i64_eq_imm_jump_if_true: CompareImmJumpOp(i64),
    i64_ne_imm_jump_if_true: CompareImmJumpOp(i64),
    i64_lt_s_imm_jump_if_true: CompareImmJumpOp(i64),
    i64_lt_u_imm_jump_if_true: CompareImmJumpOp(i64),
    i64_gt_s_imm_jump_if_true: CompareImmJumpOp(i64),
    i64_gt_u_imm_jump_if_true: CompareImmJumpOp(i64),
    i64_le_s_imm_jump_if_true: CompareImmJumpOp(i64),
    i64_le_u_imm_jump_if_true: CompareImmJumpOp(i64),
    i64_ge_s_imm_jump_if_true: CompareImmJumpOp(i64),
    i64_ge_u_imm_jump_if_true: CompareImmJumpOp(i64),

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
    /// Jump if `cond` slot holds a non-zero i32. `target` is an op index.
    /// Peephole J: replaces `jump_if_z cond → skip` + `jump → target`.
    jump_if_nz: struct {
        cond: Slot,
        target: u32,
    },
    /// Copy `src` slot into `dst` slot (used to write block results).
    copy: struct {
        dst: Slot,
        src: Slot,
    },
    /// Peephole K: fused copy + conditional jump (br_if with single result value).
    /// Equivalent to wasm3's PreserveSetSlot: copy src→dst, then jump to `target` if cond != 0.
    /// Replaces the two-instruction sequence: `copy { dst, src }` + `jump_if_nz { cond, target }`.
    copy_jump_if_nz: struct {
        dst: Slot,
        src: Slot,
        cond: Slot,
        /// Op-index of the jump target (converted to relative byte offset by encoder).
        target: u32,
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

    // ── Fused binop+ret: compute result and return immediately ─────────────────
    // Peephole I: final binop whose result is immediately returned.
    // Saves one dispatch event per non-base recursive call.
    i32_add_ret: struct { lhs: Slot, rhs: Slot },
    i32_sub_ret: struct { lhs: Slot, rhs: Slot },
    i64_add_ret: struct { lhs: Slot, rhs: Slot },
    i64_sub_ret: struct { lhs: Slot, rhs: Slot },

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
    /// Fused: call + local_set → result written directly to local slot.
    /// Replaces: `call { dst=T } + local_set { local=L, src=T }`
    /// Into: single instruction that writes result directly to local, saving one dispatch.
    call_to_local: struct {
        /// Index of the local slot to write result to
        local: Slot,
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

    /// memory.size: push current memory size in pages (i32).
    memory_size: struct {
        dst: Slot,
    },
    /// memory.grow: attempt to grow memory by `delta` pages.
    /// Pushes the old size on success, or -1 on failure.
    memory_grow: struct {
        dst: Slot,
        delta: Slot,
    },

    // ── Atomic memory instructions (Wasm Threads proposal) ───────────────────────
    //
    // All atomic ops require natural alignment (ea % access_size == 0); misalignment
    // traps with UnalignedAtomicAccess.
    //
    // Naming convention mirrors the Wasm opcode names exactly so that grep-based
    // cross-references work.  Parametric IR types (AtomicWidth / AtomicRmwOp) keep
    // the Op union compact.

    /// Atomic load: dst = atomicLoad(mem[addr + offset], width/type)
    /// Produces i32 for 32-bit-or-narrower results, i64 for 64-bit results.
    atomic_load: struct {
        dst: Slot,
        addr: Slot,
        offset: u32,
        width: AtomicWidth,
        /// true = result sign-extended or zero-extended to i64, false = i32
        ty: AtomicType,
    },

    /// Atomic store: atomicStore(mem[addr + offset], src, width)
    atomic_store: struct {
        addr: Slot,
        src: Slot,
        offset: u32,
        width: AtomicWidth,
        ty: AtomicType,
    },

    /// Atomic RMW: dst = atomicRmw(op, mem[addr + offset], src, width)
    /// Produces the *old* value before the operation.
    atomic_rmw: struct {
        dst: Slot,
        addr: Slot,
        src: Slot,
        offset: u32,
        op: AtomicRmwOp,
        width: AtomicWidth,
        ty: AtomicType,
    },

    /// Atomic compare-exchange: dst = atomicCmpxchg(mem[addr + offset], expected, replacement, width)
    /// Produces the *old* value.
    atomic_cmpxchg: struct {
        dst: Slot,
        addr: Slot,
        expected: Slot,
        replacement: Slot,
        offset: u32,
        width: AtomicWidth,
        ty: AtomicType,
    },

    /// atomic.fence: sequentially-consistent full memory fence.
    /// No operands; order = .seq_cst as required by the Threads spec.
    atomic_fence,

    /// memory.atomic.notify: wake waiters on the given address.
    /// dst = notify(mem[addr + offset], count)
    /// Returns number of waiters woken (i32).
    atomic_notify: struct {
        dst: Slot,
        addr: Slot,
        count: Slot,
        offset: u32,
    },

    /// memory.atomic.wait32: block until mem[addr+offset] != expected or timeout expires.
    /// dst = wait32(mem[addr + offset], expected_i32, timeout_i64)
    /// Returns i32: 0 = woken, 1 = not-equal, 2 = timed out.
    atomic_wait32: struct {
        dst: Slot,
        addr: Slot,
        expected: Slot,
        timeout: Slot,
        offset: u32,
    },

    /// memory.atomic.wait64: same as wait32 but expected value is i64.
    atomic_wait64: struct {
        dst: Slot,
        addr: Slot,
        expected: Slot,
        timeout: Slot,
        offset: u32,
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
    /// ref.test / ref.test_null: test if reference matches type (returns i32 0/1).
    /// nullable=true means the target is (ref null ht): a null ref counts as a match.
    ref_test: struct {
        dst: Slot,
        ref: Slot,
        type_idx: u32,
        nullable: bool,
    },
    /// ref.cast / ref.cast_null: cast reference to type (traps on failure for non-nullable).
    /// nullable=true means the target is (ref null ht): a null ref passes without trapping.
    ref_cast: struct {
        dst: Slot,
        ref: Slot,
        type_idx: u32,
        nullable: bool,
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
    /// to_nullable=true: a null ref also satisfies the cast (target is ref null ht).
    br_on_cast: struct {
        ref: Slot,
        target: u32,
        from_type_idx: u32,
        to_type_idx: u32,
        to_nullable: bool,
    },
    /// br_on_cast_fail: branch if ref CANNOT be cast to target type.
    /// to_nullable=true: a null ref satisfies the cast and does NOT branch.
    br_on_cast_fail: struct {
        ref: Slot,
        target: u32,
        from_type_idx: u32,
        to_type_idx: u32,
        to_nullable: bool,
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

    // ── Exception Handling instructions ───────────────────────────────────────────
    /// throw: allocate exception with tag `tag_index` and args, then unwind.
    /// Args are stored in CompiledFunction.call_args (reusing that pool).
    throw: struct {
        tag_index: u32,
        args_start: u32,
        args_len: u32,
    },
    /// throw_ref: re-throw an existing exception reference from `ref` slot.
    throw_ref: struct {
        ref: Slot,
    },
    /// try_table_enter: announce the start of a try_table region and register its handlers.
    /// Handlers are stored in CompiledFunction.catch_handler_tables indexed by
    /// (handlers_start, handlers_len).  `end_target` is the op index just after
    /// the last handler arm (where normal flow resumes after the try block exits).
    try_table_enter: struct {
        handlers_start: u32,
        handlers_len: u32,
        /// Op index of the instruction immediately after this try region's body
        /// (the point normal/non-exception control flow jumps to).
        end_target: u32,
    },
    /// try_table_leave: pop the innermost handler frame and jump to `target`.
    /// Emitted at the end of every try-table body (for both normal exit and
    /// each catch arm's cleanup edge).
    try_table_leave: struct {
        target: u32,
    },
};

/// A single catch arm inside a try_table block.
pub const CatchHandlerKind = enum(u8) {
    /// catch <tag> — tag payload values written to `dst_slots[0..dst_slots_len]`
    catch_tag,
    /// catch_ref <tag> — tag payload values written to `dst_slots[0..dst_slots_len]`,
    /// then the exnref written to `dst_ref`.
    /// Per spec: branch target receives [tag_values... exnref].
    catch_tag_ref,
    /// catch_all — no tag check, no value push (dst_slots unused)
    catch_all,
    /// catch_all_ref — no tag check, exnref written to `dst_ref`
    catch_all_ref,
};

pub const CatchHandlerEntry = struct {
    kind: CatchHandlerKind,
    /// Tag index to match (unused for catch_all / catch_all_ref).
    tag_index: u32,
    /// Op index to jump to when this handler fires.
    target: u32,
    /// For catch_tag / catch_tag_ref: starting index in the function's call_args pool
    /// for the extracted tag payload slots.
    dst_slots_start: u32,
    /// Number of payload slots (== tag arity for catch_tag / catch_tag_ref; 0 for others).
    dst_slots_len: u32,
    /// For catch_tag_ref / catch_all_ref: slot that receives the exnref.
    dst_ref: Slot,
};

pub const CompiledFunction = struct {
    slots_len: Slot,
    /// Number of local variable slots (excluding parameters).
    /// Used to limit @memset in allocCalleeSlots to only the locals range.
    locals_count: u16,
    ops: std.ArrayListUnmanaged(Op),
    /// All call instruction argument slots are stored here (concatenated in call order).
    /// Op.call indexes into the corresponding argument slot segment using (args_start, args_len).
    /// Op.throw also indexes here for its exception payload arguments.
    call_args: std.ArrayListUnmanaged(Slot),
    /// Resolved target PCs for jump_table (br_table) ops.
    /// Each jump_table op indexes into this with (targets_start, targets_len).
    br_table_targets: std.ArrayListUnmanaged(u32),
    /// Catch handler tables for try_table_enter ops.
    /// Each try_table_enter indexes into this with (handlers_start, handlers_len).
    catch_handler_tables: std.ArrayListUnmanaged(CatchHandlerEntry),
};

/// Lazy compilation metadata for a not-yet-compiled local function.
///
/// `body` is an owned copy of the function body bytes.  This allows the module
/// compiler to stream the original Wasm input without retaining the full
/// module in memory solely for lazy compilation.
pub const PendingFunction = struct {
    /// Raw Wasm bytecode of the function body.
    body: []const u8,
    /// When true, `body` was allocated with the module allocator and must be
    /// freed with `allocator.free(body)` after compilation.  When false, `body`
    /// is a borrowed slice into the caller's long-lived input buffer and must
    /// NOT be freed (compile(bytes) / mmap path).
    body_owned: bool,
    /// Index into Module.composite_types giving the function's FuncType.
    type_index: u32,
    /// Total value-stack slots needed (params + locals).
    reserved_slots: Slot,
    /// Number of local variable slots (excluding parameters).
    locals_count: u16,
};

/// A slot in Module.functions[]: either a host-import placeholder, a not-yet-compiled
/// local function, or a fully compiled (encoded) local function.
pub const FunctionSlot = union(enum) {
    /// Imported function — dispatched through Instance.host_funcs[]; never executed via M3.
    import,
    /// Local function that has not been compiled yet.
    pending: PendingFunction,
    /// Local function that has been compiled into M3 threaded-dispatch bytecode.
    encoded: EncodedFunction,

    /// Return a pointer to the EncodedFunction, or null if not yet compiled.
    pub fn getEncoded(self: *const FunctionSlot) ?*const EncodedFunction {
        return switch (self.*) {
            .encoded => |*ef| ef,
            else => null,
        };
    }

    /// Free any owned heap memory held by this slot.
    ///
    /// For `.pending` slots whose `body_owned` flag is true, the body bytes are
    /// freed here.  Borrowed bodies (compile(bytes) / mmap path) are left alone.
    pub fn deinit(self: *FunctionSlot, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .encoded => |*ef| ef.deinit(allocator),
            .pending => |*pf| if (pf.body_owned) allocator.free(pf.body),
            .import => {},
        }
        self.* = undefined;
    }
};

/// Encoded (M3 threaded-dispatch) form of a compiled function.
///
/// Layout of `code`:
///   For each instruction:
///     [ handler_ptr: *const fn (8 bytes, align 8) ] [ operands: packed bytes ]
///     For call/throw/struct_new/array_new_fixed: operands include inline arg slot u32s.
///
/// Jump targets stored inside `code` are byte offsets from the start of `code[]`.
///
/// The auxiliary tables (`eh_dst_slots`, `br_table_targets`, `catch_handler_tables`)
/// are owned slices migrated from CompiledFunction during encoding.
pub const EncodedFunction = struct {
    /// Flat bytecode stream; 8-byte aligned.
    code: []align(8) u8,
    /// Number of register slots required for this function's frame.
    slots_len: Slot,
    /// Number of local variable slots (excluding parameters).
    /// Used to limit @memset in allocCalleeSlots to only the locals range.
    locals_count: u16,
    /// The Wasm function index in the module's full function index space
    /// (imports + locals).  Set by Module.compileFunctionAt so that call
    /// stack walks can report which function a frame belongs to.
    func_idx: u32 = 0,
    /// Destination slot lists for exception handler catch arms (catch_tag / catch_tag_ref).
    /// CatchHandlerEntry.dst_slots_start/dst_slots_len index into this array.
    eh_dst_slots: []Slot,
    /// Branch targets for jump_table (br_table) ops.
    /// Stored as byte offsets into `code`.
    /// Indexed by (targets_start, targets_len) embedded in the instruction's operand bytes.
    br_table_targets: []u32,
    /// Catch handler entries for try_table_enter ops.
    /// CatchHandlerEntry.target is a byte offset into `code` after encoding.
    /// Indexed by (handlers_start, handlers_len) embedded in the instruction's operand bytes.
    catch_handler_tables: []CatchHandlerEntry,

    pub fn deinit(self: *EncodedFunction, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.eh_dst_slots);
        allocator.free(self.br_table_targets);
        allocator.free(self.catch_handler_tables);
        self.* = undefined;
    }
};

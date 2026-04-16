/// encode.zig — translate CompiledFunction (Op[]) → EncodedFunction (M3 bytecode)
///
/// The encoder converts the register-based IR produced by lower.zig into the
/// flat threaded-dispatch bytecode consumed by the M3 interpreter in handlers.zig.
///
/// Bytecode layout for each instruction:
///
///   [ handler_ptr: *const Handler (8 bytes, align 8) ]
///   [ operands: extern struct, variable size ]
///
/// All jump targets stored in Op structs are **op indices**; the encoder
/// converts them to **byte offsets** relative to the start of code[].
///
/// The three auxiliary tables (call_args, br_table_targets, catch_handler_tables)
/// are copied verbatim from CompiledFunction except that catch_handler_tables
/// entries have their `.target` field (op index → byte offset) patched.
const std = @import("std");
const ir = @import("ir.zig");
const dispatch = @import("../vm/dispatch.zig");

const Allocator = std.mem.Allocator;
const Op = ir.Op;
const Slot = ir.Slot;
const CompiledFunction = ir.CompiledFunction;
const EncodedFunction = ir.EncodedFunction;
const CatchHandlerEntry = ir.CatchHandlerEntry;
const Handler = dispatch.Handler;
const HANDLER_SIZE = dispatch.HANDLER_SIZE;

// ── Operand structs ───────────────────────────────────────────────────────────
//
// Every handler reads its operands as a concrete `extern` struct immediately
// after the 8-byte handler pointer.  The naming convention is:
//
//   Ops<opname> — operands for the `opname` instruction
//
// Structs that share the same layout are aliased.
// Slot fields use the `Slot` type alias (u16) for compact encoding;
// non-slot fields (offsets, indices, immediates) remain u32/i32.

/// No operands (e.g. unreachable_, atomic_fence).
pub const OpsNone = extern struct {};

/// Single destination slot (e.g. memory_size, const_ref_null).
pub const OpsDst = extern struct { dst: Slot };

/// Destination + one source slot.
pub const OpsDstSrc = extern struct { dst: Slot, src: Slot };

/// Two source slots (branch on condition, ref_eq).
pub const OpsDstLhsRhs = extern struct { dst: Slot, lhs: Slot, rhs: Slot };

/// const_i32
pub const OpsConstI32 = extern struct { dst: Slot, _pad: u16 = 0, value: i32 };

/// const_i64
pub const OpsConstI64 = extern struct { dst: Slot, _pad: [6]u8 = [_]u8{0} ** 6, value: i64 };

/// const_f32
pub const OpsConstF32 = extern struct { dst: Slot, _pad: u16 = 0, value: f32 };

/// const_f64
pub const OpsConstF64 = extern struct { dst: Slot, _pad: [6]u8 = [_]u8{0} ** 6, value: f64 };

/// const_v128 — 16-byte value + 2-byte dst
pub const OpsConstV128 = extern struct { dst: Slot, _pad: [14]u8 = [_]u8{0} ** 14, value: [16]u8 };

/// local_get / local_set
pub const OpsLocalGet = extern struct { dst: Slot, local: Slot };
pub const OpsLocalSet = extern struct { local: Slot, src: Slot };

/// global_get / global_set
pub const OpsGlobalGet = extern struct { dst: Slot, _pad: u16 = 0, global_idx: u32 };
pub const OpsGlobalSet = extern struct { src: Slot, _pad: u16 = 0, global_idx: u32 };

/// copy
pub const OpsCopy = extern struct { dst: Slot, src: Slot };

/// copy_jump_if_nz: fused copy + conditional branch (Peephole K).
/// slots[dst] = slots[src]; if slots[cond] != 0 jump to target.
pub const OpsCopyJumpIfNz = extern struct { dst: Slot, src: Slot, cond: Slot, _pad: u16 = 0, rel_target: i32 };

/// jump: signed byte offset relative to instruction start
pub const OpsJump = extern struct { rel_target: i32 };

/// jump_if_z: signed byte offset relative to instruction start
pub const OpsJumpIfZ = extern struct { cond: Slot, _pad: u16 = 0, rel_target: i32 };

/// i32_xxx_imm: fused binop/compare with immediate rhs.
pub const OpsBinopImm = extern struct { dst: Slot, lhs: Slot, imm: i32 };

/// i64_xxx_imm: fused i64 binop with immediate rhs.
pub const OpsBinopImm64 = extern struct { dst: Slot, lhs: Slot, _pad: u32 = 0, imm: i64 };

/// i32_xxx_imm_r: r0 variant — lhs comes from r0 accumulator register.
pub const OpsBinopImmR0 = extern struct { dst: Slot, _pad: u16 = 0, imm: i32 };

/// i64_xxx_imm_r: r0 variant — lhs comes from r0 accumulator register.
pub const OpsBinopImmR064 = extern struct { dst: Slot, _pad: [6]u8 = [_]u8{0} ** 6, imm: i64 };

/// i32_xxx_jump_if_false: fused compare+branch.
pub const OpsCompareJump = extern struct { lhs: Slot, rhs: Slot, rel_target: i32 };

/// i32_eqz_jump_if_false: fused eqz+branch.
pub const OpsEqzJump = extern struct { src: Slot, _pad: u16 = 0, rel_target: i32 };

/// i32_xxx_to_local: fused binop→local_set.
pub const OpsBinopToLocal = extern struct { local: Slot, lhs: Slot, rhs: Slot };

/// binop + local_tee: result written to both a stack slot and a local.
pub const OpsBinopTeeLocal = extern struct { dst: Slot, local: Slot, lhs: Slot, rhs: Slot };

/// comparison + local_set: fused cmp→local_set. Same layout as OpsBinopToLocal.
pub const OpsCmpToLocal = extern struct { local: Slot, lhs: Slot, rhs: Slot };

/// i32_xxx_imm_to_local: fused const+binop→local_set (Candidate E, i32).
pub const OpsBinopImmToLocal = extern struct { local: Slot, lhs: Slot, imm: i32 };

/// i64_xxx_imm_to_local: fused const+binop→local_set (Candidate E, i64).
pub const OpsBinopImmToLocal64 = extern struct { local: Slot, lhs: Slot, _pad: u32 = 0, imm: i64 };

/// i32_xxx_local_inplace: fused local_get+binop_imm+local_set same local (Candidate H, i32).
pub const OpsLocalInplace = extern struct { local: Slot, _pad: u16 = 0, imm: i32 };

/// i64_xxx_local_inplace: fused local_get+binop_imm+local_set same local (Candidate H, i64).
pub const OpsLocalInplace64 = extern struct { local: Slot, _pad: [6]u8 = [_]u8{0} ** 6, imm: i64 };

/// i32_const_to_local: fused const_i32 + local_set.
pub const OpsConstToLocal32 = extern struct { local: Slot, _pad: u16 = 0, value: i32 };

/// i64_const_to_local: fused const_i64 + local_set.
pub const OpsConstToLocal64 = extern struct { local: Slot, _pad: [6]u8 = [_]u8{0} ** 6, value: i64 };

/// fused: i32_imm + local_set → imm_to_local (superinstruction)
/// Writes the immediate to local directly, skipping the temp slot.
/// Layout: { local: Slot, src: Slot, imm: i32 }
pub const OpsImm32ToLocal = extern struct { local: Slot, src: Slot, imm: i32 };

/// fused: i64_imm + local_set → imm_to_local (superinstruction)
pub const OpsImm64ToLocal = extern struct { local: Slot, src: Slot, _pad: [6]u8 = [_]u8{0} ** 6, imm: i64 };

/// global_get_to_local: fused global_get + local_set.
pub const OpsGlobalGetToLocal = extern struct { local: Slot, _pad: u16 = 0, global_idx: u32 };

/// load_to_local: fused load + local_set (same layout for i32/i64).
pub const OpsLoadToLocal = extern struct { local: Slot, addr: Slot, offset: u32 };

/// i32_xxx_imm_jump_if_false: fused const+compare+br_if (Candidate G, i32).
pub const OpsCompareImmJump = extern struct { lhs: Slot, _pad: u16 = 0, imm: i32, rel_target: i32 };

/// i64_xxx_imm_jump_if_false: fused const+compare+br_if (Candidate G, i64).
pub const OpsCompareImmJump64 = extern struct { lhs: Slot, _pad: [6]u8 = [_]u8{0} ** 6, imm: i64, rel_target: i32, _pad2: u32 = 0 };

/// jump_table
pub const OpsJumpTable = extern struct { index: Slot, _pad: u16 = 0, targets_start: u32, targets_len: u32 };

/// select
pub const OpsSelect = extern struct { dst: Slot, val1: Slot, val2: Slot, cond: Slot };

/// ret
pub const OpsRet = extern struct {
    /// 0 = void return, 1 = has value
    has_value: u16,
    value: Slot,
};

/// binop_ret: fused binary op + return (Peephole I)
pub const OpsLhsRhs = extern struct { lhs: Slot, rhs: Slot };

/// ref_func
pub const OpsRefFunc = extern struct { dst: Slot, _pad: u16 = 0, func_idx: u32 };

/// ref_test / ref_cast
pub const OpsRefTest = extern struct { dst: Slot, ref: Slot, type_idx: u32, nullable: u32 };

/// ref_as_non_null
pub const OpsRefAsNonNull = extern struct { dst: Slot, ref: Slot };

/// br_on_null / br_on_non_null: signed byte offset relative to instruction start
pub const OpsBrOnNull = extern struct { ref: Slot, _pad: u16 = 0, rel_target: i32 };

/// br_on_cast / br_on_cast_fail: signed byte offset relative to instruction start
pub const OpsBrOnCast = extern struct { ref: Slot, _pad: u16 = 0, rel_target: i32, from_type_idx: u32, to_type_idx: u32, to_nullable: u32 };

/// ref_i31 / i31_get_s / i31_get_u
pub const OpsRefI31 = extern struct { dst: Slot, value: Slot };
pub const OpsI31Get = extern struct { dst: Slot, ref: Slot };

/// Memory load: i32_load, i64_load, f32_load, f64_load, etc.
pub const OpsLoad = extern struct { dst: Slot, addr: Slot, offset: u32 };

/// Memory store
pub const OpsStore = extern struct { addr: Slot, src: Slot, offset: u32 };

/// memory_size
pub const OpsMemorySize = extern struct { dst: Slot };

/// memory_grow
pub const OpsMemoryGrow = extern struct { dst: Slot, delta: Slot };

/// memory_init
pub const OpsMemoryInit = extern struct { dst_addr: Slot, src_offset: Slot, len: Slot, _pad: u16 = 0, segment_idx: u32 };

/// data_drop
pub const OpsDataDrop = extern struct { segment_idx: u32 };

/// memory_copy
pub const OpsMemoryCopy = extern struct { dst_addr: Slot, src_addr: Slot, len: Slot };

/// memory_fill
pub const OpsMemoryFill = extern struct { dst_addr: Slot, value: Slot, len: Slot };

/// call — args_len inline Slot arg slots follow immediately after this struct
pub const OpsCall = extern struct { dst: Slot, dst_valid: u16, func_idx: u32, args_len: u32 };

/// call_indirect — args_len inline Slot arg slots follow immediately after this struct
pub const OpsCallIndirect = extern struct { dst: Slot, index: Slot, dst_valid: u16, _pad: u16 = 0, type_index: u32, table_index: u32, args_len: u32 };

/// return_call — args_len inline Slot arg slots follow immediately after this struct
pub const OpsReturnCall = extern struct { func_idx: u32, args_len: u32 };

/// return_call_indirect — args_len inline Slot arg slots follow immediately after this struct
pub const OpsReturnCallIndirect = extern struct { index: Slot, _pad: u16 = 0, type_index: u32, table_index: u32, args_len: u32 };

/// call_ref — args_len inline Slot arg slots follow immediately after this struct
pub const OpsCallRef = extern struct { dst: Slot, ref: Slot, dst_valid: u16, _pad: u16 = 0, type_idx: u32, args_len: u32 };

/// return_call_ref — args_len inline Slot arg slots follow immediately after this struct
pub const OpsReturnCallRef = extern struct { ref: Slot, _pad: u16 = 0, type_idx: u32, args_len: u32 };

/// Atomic load/store
pub const OpsAtomicLoad = extern struct { dst: Slot, addr: Slot, offset: u32, width: u8, ty: u8, _pad: u16 = 0 };
pub const OpsAtomicStore = extern struct { addr: Slot, src: Slot, offset: u32, width: u8, ty: u8, _pad: u16 = 0 };
pub const OpsAtomicRmw = extern struct { dst: Slot, addr: Slot, src: Slot, _pad: u16 = 0, offset: u32, op: u8, width: u8, ty: u8, _pad2: u8 = 0 };
pub const OpsAtomicCmpxchg = extern struct { dst: Slot, addr: Slot, expected: Slot, replacement: Slot, offset: u32, width: u8, ty: u8, _pad: u16 = 0 };
pub const OpsAtomicNotify = extern struct { dst: Slot, addr: Slot, count: Slot, _pad: u16 = 0, offset: u32 };
pub const OpsAtomicWait32 = extern struct { dst: Slot, addr: Slot, expected: Slot, timeout: Slot, offset: u32 };
pub const OpsAtomicWait64 = extern struct { dst: Slot, addr: Slot, expected: Slot, timeout: Slot, offset: u32 };

/// Table ops
pub const OpsTableGet = extern struct { dst: Slot, index: Slot, table_index: u32 };
pub const OpsTableSet = extern struct { index: Slot, value: Slot, table_index: u32 };
pub const OpsTableSize = extern struct { dst: Slot, _pad: u16 = 0, table_index: u32 };
pub const OpsTableGrow = extern struct { dst: Slot, init: Slot, delta: Slot, _pad: u16 = 0, table_index: u32 };
pub const OpsTableFill = extern struct { dst_idx: Slot, value: Slot, len: Slot, _pad: u16 = 0, table_index: u32 };
pub const OpsTableCopy = extern struct { dst_idx: Slot, src_idx: Slot, len: Slot, _pad: u16 = 0, dst_table: u32, src_table: u32 };
pub const OpsTableInit = extern struct { dst_idx: Slot, src_offset: Slot, len: Slot, _pad: u16 = 0, table_index: u32, segment_idx: u32 };
pub const OpsElemDrop = extern struct { segment_idx: u32 };

/// GC struct ops — args_len inline Slot arg slots follow immediately after OpsStructNew
pub const OpsStructNew = extern struct { dst: Slot, _pad: u16 = 0, type_idx: u32, args_len: u32 };
pub const OpsStructNewDefault = extern struct { dst: Slot, _pad: u16 = 0, type_idx: u32 };
pub const OpsStructGet = extern struct { dst: Slot, ref: Slot, type_idx: u32, field_idx: u32 };
pub const OpsStructSet = extern struct { ref: Slot, value: Slot, type_idx: u32, field_idx: u32 };

/// GC array ops
pub const OpsArrayNew = extern struct { dst: Slot, init: Slot, len: Slot, _pad: u16 = 0, type_idx: u32 };
pub const OpsArrayNewDefault = extern struct { dst: Slot, len: Slot, type_idx: u32 };
/// GC array ops — args_len inline Slot arg slots follow immediately after OpsArrayNewFixed
pub const OpsArrayNewFixed = extern struct { dst: Slot, _pad: u16 = 0, type_idx: u32, args_len: u32 };
pub const OpsArrayNewData = extern struct { dst: Slot, offset: Slot, len: Slot, _pad: u16 = 0, type_idx: u32, data_idx: u32 };
pub const OpsArrayNewElem = extern struct { dst: Slot, offset: Slot, len: Slot, _pad: u16 = 0, type_idx: u32, elem_idx: u32 };
pub const OpsArrayGet = extern struct { dst: Slot, ref: Slot, index: Slot, _pad: u16 = 0, type_idx: u32 };
pub const OpsArraySet = extern struct { ref: Slot, index: Slot, value: Slot, _pad: u16 = 0, type_idx: u32 };
pub const OpsArrayLen = extern struct { dst: Slot, ref: Slot };
pub const OpsArrayFill = extern struct { ref: Slot, offset: Slot, value: Slot, n: Slot, type_idx: u32 };
pub const OpsArrayCopy = extern struct { dst_ref: Slot, dst_offset: Slot, src_ref: Slot, src_offset: Slot, n: Slot, _pad: u16 = 0, dst_type_idx: u32, src_type_idx: u32 };
pub const OpsArrayInitData = extern struct { ref: Slot, d: Slot, s: Slot, n: Slot, type_idx: u32, data_idx: u32 };
pub const OpsArrayInitElem = extern struct { ref: Slot, d: Slot, s: Slot, n: Slot, type_idx: u32, elem_idx: u32 };

/// any_convert_extern / extern_convert_any
pub const OpsConvertRef = extern struct { dst: Slot, ref: Slot };

/// EH ops — args_len inline Slot arg slots follow immediately after OpsThrow
pub const OpsThrow = extern struct { tag_index: u32, args_len: u32 };
pub const OpsThrowRef = extern struct { ref: Slot };
pub const OpsTryTableEnter = extern struct { handlers_start: u32, handlers_len: u32, end_target: u32 };
pub const OpsTryTableLeave = extern struct { rel_target: i32 };

/// SIMD unary/binary/ternary/compare/shift
pub const OpsSimdUnary = extern struct { dst: Slot, src: Slot, opcode: u32 };
pub const OpsSimdBinary = extern struct { dst: Slot, lhs: Slot, rhs: Slot, _pad: u16 = 0, opcode: u32 };
pub const OpsSimdTernary = extern struct { dst: Slot, first: Slot, second: Slot, third: Slot, opcode: u32 };
pub const OpsSimdExtractLane = extern struct { dst: Slot, src: Slot, opcode: u32, lane: u8, _pad2: [3]u8 = [_]u8{0} ** 3 };
pub const OpsSimdReplaceLane = extern struct { dst: Slot, src_vec: Slot, src_lane: Slot, _pad: u16 = 0, opcode: u32, lane: u8, _pad2: [3]u8 = [_]u8{0} ** 3 };
pub const OpsSimdShuffle = extern struct { dst: Slot, lhs: Slot, rhs: Slot, _pad: u16 = 0, lanes: [16]u8 };
pub const OpsSimdLoad = extern struct { dst: Slot, addr: Slot, src_vec: Slot, _pad: u16 = 0, opcode: u32, offset: u32, lane_valid: u8, lane: u8, src_vec_valid: u8, _pad2: u8 = 0 };
pub const OpsSimdStore = extern struct { addr: Slot, src: Slot, opcode: u32, offset: u32, lane_valid: u8, lane: u8, _pad: [2]u8 = [_]u8{0} ** 2 };

// ── Instruction size helpers ──────────────────────────────────────────────────

/// Read the inline arg slot array that follows a fixed-size ops struct in the bytecode stream.
/// `ip` is the instruction pointer (pointing to the handler pointer).
/// Returns a slice of Slot (u16) slot indices.
/// Note: May read unaligned values due to compact encoding (safe on x86_64/aarch64).
pub inline fn readInlineArgs(comptime OpsT: type, ip: [*]u8, args_len: u32) []align(1) const Slot {
    const offset = HANDLER_SIZE + @sizeOf(OpsT);
    const ptr: [*]align(1) const Slot = @ptrCast(ip + offset);
    return ptr[0..args_len];
}

/// Compute the byte stride of a variable-length instruction (handler + ops + inline args).
pub inline fn varStride(comptime OpsT: type, args_len: u32) usize {
    return HANDLER_SIZE + @sizeOf(OpsT) + @as(usize, args_len) * @sizeOf(Slot);
}

/// Returns the byte size of one encoded instruction (handler pointer + operands).
pub fn instrSize(op: Op) usize {
    const ops_size: usize = switch (op) {
        .unreachable_ => @sizeOf(OpsNone),
        .const_i32 => @sizeOf(OpsConstI32),
        .const_i64 => @sizeOf(OpsConstI64),
        .const_f32 => @sizeOf(OpsConstF32),
        .const_f64 => @sizeOf(OpsConstF64),
        .const_v128 => @sizeOf(OpsConstV128),
        .const_ref_null => @sizeOf(OpsDst),
        .ref_is_null => @sizeOf(OpsDstSrc),
        .ref_func => @sizeOf(OpsRefFunc),
        .ref_eq => @sizeOf(OpsDstLhsRhs),
        .local_get => @sizeOf(OpsLocalGet),
        .local_set => @sizeOf(OpsLocalSet),
        .global_get => @sizeOf(OpsGlobalGet),
        .global_set => @sizeOf(OpsGlobalSet),
        .copy => @sizeOf(OpsCopy),
        .copy_jump_if_nz => @sizeOf(OpsCopyJumpIfNz),
        .jump => @sizeOf(OpsJump),
        .jump_if_z => @sizeOf(OpsJumpIfZ),
        .jump_if_nz => @sizeOf(OpsJumpIfZ),
        .jump_table => @sizeOf(OpsJumpTable),
        .select => @sizeOf(OpsSelect),
        .ret => @sizeOf(OpsRet),
        // Fused binop+ret (Peephole I)
        .i32_add_ret, .i32_sub_ret, .i64_add_ret, .i64_sub_ret => @sizeOf(OpsLhsRhs),

        // i32 binary
        .i32_add,
        .i32_sub,
        .i32_mul,
        .i32_div_s,
        .i32_div_u,
        .i32_rem_s,
        .i32_rem_u,
        .i32_and,
        .i32_or,
        .i32_xor,
        .i32_shl,
        .i32_shr_s,
        .i32_shr_u,
        .i32_rotl,
        .i32_rotr,
        // i64 binary
        .i64_add,
        .i64_sub,
        .i64_mul,
        .i64_div_s,
        .i64_div_u,
        .i64_rem_s,
        .i64_rem_u,
        .i64_and,
        .i64_or,
        .i64_xor,
        .i64_shl,
        .i64_shr_s,
        .i64_shr_u,
        .i64_rotl,
        .i64_rotr,
        // f32 binary
        .f32_add,
        .f32_sub,
        .f32_mul,
        .f32_div,
        .f32_min,
        .f32_max,
        .f32_copysign,
        // f64 binary
        .f64_add,
        .f64_sub,
        .f64_mul,
        .f64_div,
        .f64_min,
        .f64_max,
        .f64_copysign,
        // i32 comparisons
        .i32_eq,
        .i32_ne,
        .i32_lt_s,
        .i32_lt_u,
        .i32_gt_s,
        .i32_gt_u,
        .i32_le_s,
        .i32_le_u,
        .i32_ge_s,
        .i32_ge_u,
        // i64 comparisons
        .i64_eq,
        .i64_ne,
        .i64_lt_s,
        .i64_lt_u,
        .i64_gt_s,
        .i64_gt_u,
        .i64_le_s,
        .i64_le_u,
        .i64_ge_s,
        .i64_ge_u,
        // f32 comparisons
        .f32_eq,
        .f32_ne,
        .f32_lt,
        .f32_gt,
        .f32_le,
        .f32_ge,
        // f64 comparisons
        .f64_eq,
        .f64_ne,
        .f64_lt,
        .f64_gt,
        .f64_le,
        .f64_ge,
        => @sizeOf(OpsDstLhsRhs),

        // i32 unary
        .i32_clz,
        .i32_ctz,
        .i32_popcnt,
        .i32_eqz,
        // i64 unary
        .i64_clz,
        .i64_ctz,
        .i64_popcnt,
        .i64_eqz,
        // f32 unary
        .f32_abs,
        .f32_neg,
        .f32_ceil,
        .f32_floor,
        .f32_trunc,
        .f32_nearest,
        .f32_sqrt,
        // f64 unary
        .f64_abs,
        .f64_neg,
        .f64_ceil,
        .f64_floor,
        .f64_trunc,
        .f64_nearest,
        .f64_sqrt,
        // conversions (all share dst+src layout)
        .i32_wrap_i64,
        .i32_trunc_f32_s,
        .i32_trunc_f32_u,
        .i32_trunc_f64_s,
        .i32_trunc_f64_u,
        .i64_extend_i32_s,
        .i64_extend_i32_u,
        .i64_trunc_f32_s,
        .i64_trunc_f32_u,
        .i64_trunc_f64_s,
        .i64_trunc_f64_u,
        .i32_trunc_sat_f32_s,
        .i32_trunc_sat_f32_u,
        .i32_trunc_sat_f64_s,
        .i32_trunc_sat_f64_u,
        .i64_trunc_sat_f32_s,
        .i64_trunc_sat_f32_u,
        .i64_trunc_sat_f64_s,
        .i64_trunc_sat_f64_u,
        .f32_convert_i32_s,
        .f32_convert_i32_u,
        .f32_convert_i64_s,
        .f32_convert_i64_u,
        .f32_demote_f64,
        .f64_promote_f32,
        .f64_convert_i32_s,
        .f64_convert_i32_u,
        .f64_convert_i64_s,
        .f64_convert_i64_u,
        .i32_reinterpret_f32,
        .i64_reinterpret_f64,
        .f32_reinterpret_i32,
        .f64_reinterpret_i64,
        .i32_extend8_s,
        .i32_extend16_s,
        .i64_extend8_s,
        .i64_extend16_s,
        .i64_extend32_s,
        => @sizeOf(OpsDstSrc),

        // fused binop-imm (Candidate C)
        .i32_add_imm,
        .i32_sub_imm,
        .i32_mul_imm,
        .i32_and_imm,
        .i32_or_imm,
        .i32_xor_imm,
        .i32_shl_imm,
        .i32_shr_s_imm,
        .i32_shr_u_imm,
        .i32_eq_imm,
        .i32_ne_imm,
        .i32_lt_s_imm,
        .i32_lt_u_imm,
        .i32_gt_s_imm,
        .i32_gt_u_imm,
        .i32_le_s_imm,
        .i32_le_u_imm,
        .i32_ge_s_imm,
        .i32_ge_u_imm,
        => @sizeOf(OpsBinopImm),

        // fused i64 binop-imm (Candidate C, i64)
        .i64_add_imm,
        .i64_sub_imm,
        .i64_mul_imm,
        .i64_and_imm,
        .i64_or_imm,
        .i64_xor_imm,
        .i64_shl_imm,
        .i64_shr_s_imm,
        .i64_shr_u_imm,
        .i64_eq_imm,
        .i64_ne_imm,
        .i64_lt_s_imm,
        .i64_lt_u_imm,
        .i64_gt_s_imm,
        .i64_gt_u_imm,
        .i64_le_s_imm,
        .i64_le_u_imm,
        .i64_ge_s_imm,
        .i64_ge_u_imm,
        => @sizeOf(OpsBinopImm64),

        // r0 variants: i32 binop-imm-r (no lhs slot)
        .i32_add_imm_r,
        .i32_sub_imm_r,
        .i32_mul_imm_r,
        .i32_and_imm_r,
        .i32_or_imm_r,
        .i32_xor_imm_r,
        .i32_shl_imm_r,
        .i32_shr_s_imm_r,
        .i32_shr_u_imm_r,
        => @sizeOf(OpsBinopImmR0),

        // r0 variants: i64 binop-imm-r (no lhs slot)
        .i64_add_imm_r,
        .i64_sub_imm_r,
        .i64_mul_imm_r,
        .i64_and_imm_r,
        .i64_or_imm_r,
        .i64_xor_imm_r,
        .i64_shl_imm_r,
        .i64_shr_s_imm_r,
        .i64_shr_u_imm_r,
        => @sizeOf(OpsBinopImmR064),

        // fused compare-jump (Candidate F)
        .i32_eq_jump_if_false,
        .i32_ne_jump_if_false,
        .i32_lt_s_jump_if_false,
        .i32_lt_u_jump_if_false,
        .i32_gt_s_jump_if_false,
        .i32_gt_u_jump_if_false,
        .i32_le_s_jump_if_false,
        .i32_le_u_jump_if_false,
        .i32_ge_s_jump_if_false,
        .i32_ge_u_jump_if_false,
        => @sizeOf(OpsCompareJump),

        .i32_eqz_jump_if_false => @sizeOf(OpsEqzJump),

        // fused i64 compare-jump (Candidate F, i64)
        .i64_eq_jump_if_false,
        .i64_ne_jump_if_false,
        .i64_lt_s_jump_if_false,
        .i64_lt_u_jump_if_false,
        .i64_gt_s_jump_if_false,
        .i64_gt_u_jump_if_false,
        .i64_le_s_jump_if_false,
        .i64_le_u_jump_if_false,
        .i64_ge_s_jump_if_false,
        .i64_ge_u_jump_if_false,
        => @sizeOf(OpsCompareJump),

        .i64_eqz_jump_if_false => @sizeOf(OpsEqzJump),

        // fused compare-jump-if-true (Peephole J)
        .i32_eq_jump_if_true,
        .i32_ne_jump_if_true,
        .i32_lt_s_jump_if_true,
        .i32_lt_u_jump_if_true,
        .i32_gt_s_jump_if_true,
        .i32_gt_u_jump_if_true,
        .i32_le_s_jump_if_true,
        .i32_le_u_jump_if_true,
        .i32_ge_s_jump_if_true,
        .i32_ge_u_jump_if_true,
        => @sizeOf(OpsCompareJump),

        .i32_eqz_jump_if_true => @sizeOf(OpsEqzJump),

        .i64_eq_jump_if_true,
        .i64_ne_jump_if_true,
        .i64_lt_s_jump_if_true,
        .i64_lt_u_jump_if_true,
        .i64_gt_s_jump_if_true,
        .i64_gt_u_jump_if_true,
        .i64_le_s_jump_if_true,
        .i64_le_u_jump_if_true,
        .i64_ge_s_jump_if_true,
        .i64_ge_u_jump_if_true,
        => @sizeOf(OpsCompareJump),

        .i64_eqz_jump_if_true => @sizeOf(OpsEqzJump),

        // fused binop-to-local (Candidate D)
        .i32_add_to_local,
        .i32_sub_to_local,
        .i32_mul_to_local,
        .i32_and_to_local,
        .i32_or_to_local,
        .i32_xor_to_local,
        .i32_shl_to_local,
        .i32_shr_s_to_local,
        .i32_shr_u_to_local,
        => @sizeOf(OpsBinopToLocal),

        // fused i64 binop-to-local (Candidate D, i64)
        .i64_add_to_local,
        .i64_sub_to_local,
        .i64_mul_to_local,
        .i64_and_to_local,
        .i64_or_to_local,
        .i64_xor_to_local,
        .i64_shl_to_local,
        .i64_shr_s_to_local,
        .i64_shr_u_to_local,
        => @sizeOf(OpsBinopToLocal),

        // fused binop + local_tee
        .i32_add_tee_local,
        .i32_sub_tee_local,
        .i32_mul_tee_local,
        .i32_and_tee_local,
        .i32_or_tee_local,
        .i32_xor_tee_local,
        .i32_shl_tee_local,
        .i32_shr_s_tee_local,
        .i32_shr_u_tee_local,
        => @sizeOf(OpsBinopTeeLocal),

        .i64_add_tee_local,
        .i64_sub_tee_local,
        .i64_mul_tee_local,
        .i64_and_tee_local,
        .i64_or_tee_local,
        .i64_xor_tee_local,
        .i64_shl_tee_local,
        .i64_shr_s_tee_local,
        .i64_shr_u_tee_local,
        => @sizeOf(OpsBinopTeeLocal),

        // fused cmp-to-local
        .i32_eq_to_local,
        .i32_ne_to_local,
        .i32_lt_s_to_local,
        .i32_lt_u_to_local,
        .i32_gt_s_to_local,
        .i32_gt_u_to_local,
        .i32_le_s_to_local,
        .i32_le_u_to_local,
        .i32_ge_s_to_local,
        .i32_ge_u_to_local,
        .i64_eq_to_local,
        .i64_ne_to_local,
        .i64_lt_s_to_local,
        .i64_lt_u_to_local,
        .i64_gt_s_to_local,
        .i64_gt_u_to_local,
        .i64_le_s_to_local,
        .i64_le_u_to_local,
        .i64_ge_s_to_local,
        .i64_ge_u_to_local,
        => @sizeOf(OpsCmpToLocal),

        // fused i32 binop-imm-to-local (Candidate E, i32)
        .i32_add_imm_to_local,
        .i32_sub_imm_to_local,
        .i32_mul_imm_to_local,
        .i32_and_imm_to_local,
        .i32_or_imm_to_local,
        .i32_xor_imm_to_local,
        .i32_shl_imm_to_local,
        .i32_shr_s_imm_to_local,
        .i32_shr_u_imm_to_local,
        => @sizeOf(OpsBinopImmToLocal),

        // fused i64 binop-imm-to-local (Candidate E, i64)
        .i64_add_imm_to_local,
        .i64_sub_imm_to_local,
        .i64_mul_imm_to_local,
        .i64_and_imm_to_local,
        .i64_or_imm_to_local,
        .i64_xor_imm_to_local,
        .i64_shl_imm_to_local,
        .i64_shr_s_imm_to_local,
        .i64_shr_u_imm_to_local,
        => @sizeOf(OpsBinopImmToLocal64),

        // fused i32 local-inplace (Candidate H, i32)
        .i32_add_local_inplace,
        .i32_sub_local_inplace,
        .i32_mul_local_inplace,
        .i32_and_local_inplace,
        .i32_or_local_inplace,
        .i32_xor_local_inplace,
        .i32_shl_local_inplace,
        .i32_shr_s_local_inplace,
        .i32_shr_u_local_inplace,
        => @sizeOf(OpsLocalInplace),

        // fused i64 local-inplace (Candidate H, i64)
        .i64_add_local_inplace,
        .i64_sub_local_inplace,
        .i64_mul_local_inplace,
        .i64_and_local_inplace,
        .i64_or_local_inplace,
        .i64_xor_local_inplace,
        .i64_shl_local_inplace,
        .i64_shr_s_local_inplace,
        .i64_shr_u_local_inplace,
        => @sizeOf(OpsLocalInplace64),

        // fused const-to-local
        .i32_const_to_local,
        => @sizeOf(OpsConstToLocal32),

        .i64_const_to_local,
        => @sizeOf(OpsConstToLocal64),

        // fused imm-to-local (superinstruction: i32_imm + local_set)
        .i32_imm_to_local,
        => @sizeOf(OpsImm32ToLocal),

        .i64_imm_to_local,
        => @sizeOf(OpsImm64ToLocal),

        // fused global_get-to-local
        .global_get_to_local,
        => @sizeOf(OpsGlobalGetToLocal),

        // fused load-to-local
        .i32_load_to_local,
        .i64_load_to_local,
        => @sizeOf(OpsLoadToLocal),

        // fused i32 compare-imm-jump (Candidate G, i32)
        .i32_eq_imm_jump_if_false,
        .i32_ne_imm_jump_if_false,
        .i32_lt_s_imm_jump_if_false,
        .i32_lt_u_imm_jump_if_false,
        .i32_gt_s_imm_jump_if_false,
        .i32_gt_u_imm_jump_if_false,
        .i32_le_s_imm_jump_if_false,
        .i32_le_u_imm_jump_if_false,
        .i32_ge_s_imm_jump_if_false,
        .i32_ge_u_imm_jump_if_false,
        => @sizeOf(OpsCompareImmJump),

        // fused i64 compare-imm-jump (Candidate G, i64)
        .i64_eq_imm_jump_if_false,
        .i64_ne_imm_jump_if_false,
        .i64_lt_s_imm_jump_if_false,
        .i64_lt_u_imm_jump_if_false,
        .i64_gt_s_imm_jump_if_false,
        .i64_gt_u_imm_jump_if_false,
        .i64_le_s_imm_jump_if_false,
        .i64_le_u_imm_jump_if_false,
        .i64_ge_s_imm_jump_if_false,
        .i64_ge_u_imm_jump_if_false,
        => @sizeOf(OpsCompareImmJump64),

        // fused i32 compare-imm-jump, true-branch (Candidate J-imm, i32)
        .i32_eq_imm_jump_if_true,
        .i32_ne_imm_jump_if_true,
        .i32_lt_s_imm_jump_if_true,
        .i32_lt_u_imm_jump_if_true,
        .i32_gt_s_imm_jump_if_true,
        .i32_gt_u_imm_jump_if_true,
        .i32_le_s_imm_jump_if_true,
        .i32_le_u_imm_jump_if_true,
        .i32_ge_s_imm_jump_if_true,
        .i32_ge_u_imm_jump_if_true,
        => @sizeOf(OpsCompareImmJump),

        // fused i64 compare-imm-jump, true-branch (Candidate J-imm, i64)
        .i64_eq_imm_jump_if_true,
        .i64_ne_imm_jump_if_true,
        .i64_lt_s_imm_jump_if_true,
        .i64_lt_u_imm_jump_if_true,
        .i64_gt_s_imm_jump_if_true,
        .i64_gt_u_imm_jump_if_true,
        .i64_le_s_imm_jump_if_true,
        .i64_le_u_imm_jump_if_true,
        .i64_ge_s_imm_jump_if_true,
        .i64_ge_u_imm_jump_if_true,
        => @sizeOf(OpsCompareImmJump64),

        // memory loads
        .i32_load,
        .i32_load8_s,
        .i32_load8_u,
        .i32_load16_s,
        .i32_load16_u,
        .i64_load,
        .i64_load8_s,
        .i64_load8_u,
        .i64_load16_s,
        .i64_load16_u,
        .i64_load32_s,
        .i64_load32_u,
        .f32_load,
        .f64_load,
        => @sizeOf(OpsLoad),

        // memory stores
        .i32_store,
        .i32_store8,
        .i32_store16,
        .i64_store,
        .i64_store8,
        .i64_store16,
        .i64_store32,
        .f32_store,
        .f64_store,
        => @sizeOf(OpsStore),

        .memory_size => @sizeOf(OpsMemorySize),
        .memory_grow => @sizeOf(OpsMemoryGrow),
        .memory_init => @sizeOf(OpsMemoryInit),
        .data_drop => @sizeOf(OpsDataDrop),
        .memory_copy => @sizeOf(OpsMemoryCopy),
        .memory_fill => @sizeOf(OpsMemoryFill),

        .call => |inst| @sizeOf(OpsCall) + @as(usize, inst.args_len) * @sizeOf(Slot),
        .call_indirect => |inst| @sizeOf(OpsCallIndirect) + @as(usize, inst.args_len) * @sizeOf(Slot),
        .return_call => |inst| @sizeOf(OpsReturnCall) + @as(usize, inst.args_len) * @sizeOf(Slot),
        .return_call_indirect => |inst| @sizeOf(OpsReturnCallIndirect) + @as(usize, inst.args_len) * @sizeOf(Slot),
        .call_ref => |inst| @sizeOf(OpsCallRef) + @as(usize, inst.args_len) * @sizeOf(Slot),
        .return_call_ref => |inst| @sizeOf(OpsReturnCallRef) + @as(usize, inst.args_len) * @sizeOf(Slot),

        .atomic_load => @sizeOf(OpsAtomicLoad),
        .atomic_store => @sizeOf(OpsAtomicStore),
        .atomic_rmw => @sizeOf(OpsAtomicRmw),
        .atomic_cmpxchg => @sizeOf(OpsAtomicCmpxchg),
        .atomic_fence => @sizeOf(OpsNone),
        .atomic_notify => @sizeOf(OpsAtomicNotify),
        .atomic_wait32 => @sizeOf(OpsAtomicWait32),
        .atomic_wait64 => @sizeOf(OpsAtomicWait64),

        .table_get => @sizeOf(OpsTableGet),
        .table_set => @sizeOf(OpsTableSet),
        .table_size => @sizeOf(OpsTableSize),
        .table_grow => @sizeOf(OpsTableGrow),
        .table_fill => @sizeOf(OpsTableFill),
        .table_copy => @sizeOf(OpsTableCopy),
        .table_init => @sizeOf(OpsTableInit),
        .elem_drop => @sizeOf(OpsElemDrop),

        .struct_new => |inst| @sizeOf(OpsStructNew) + @as(usize, inst.args_len) * @sizeOf(Slot),
        .struct_new_default => @sizeOf(OpsStructNewDefault),
        .struct_get, .struct_get_s, .struct_get_u => @sizeOf(OpsStructGet),
        .struct_set => @sizeOf(OpsStructSet),

        .array_new => @sizeOf(OpsArrayNew),
        .array_new_default => @sizeOf(OpsArrayNewDefault),
        .array_new_fixed => |inst| @sizeOf(OpsArrayNewFixed) + @as(usize, inst.args_len) * @sizeOf(Slot),
        .array_new_data => @sizeOf(OpsArrayNewData),
        .array_new_elem => @sizeOf(OpsArrayNewElem),
        .array_get, .array_get_s, .array_get_u => @sizeOf(OpsArrayGet),
        .array_set => @sizeOf(OpsArraySet),
        .array_len => @sizeOf(OpsArrayLen),
        .array_fill => @sizeOf(OpsArrayFill),
        .array_copy => @sizeOf(OpsArrayCopy),
        .array_init_data => @sizeOf(OpsArrayInitData),
        .array_init_elem => @sizeOf(OpsArrayInitElem),

        .ref_i31 => @sizeOf(OpsRefI31),
        .i31_get_s, .i31_get_u => @sizeOf(OpsI31Get),

        .ref_test, .ref_cast => @sizeOf(OpsRefTest),
        .ref_as_non_null => @sizeOf(OpsRefAsNonNull),
        .br_on_null, .br_on_non_null => @sizeOf(OpsBrOnNull),
        .br_on_cast, .br_on_cast_fail => @sizeOf(OpsBrOnCast),

        .any_convert_extern, .extern_convert_any => @sizeOf(OpsConvertRef),

        .throw => |inst| @sizeOf(OpsThrow) + @as(usize, inst.args_len) * @sizeOf(Slot),
        .throw_ref => @sizeOf(OpsThrowRef),
        .try_table_enter => @sizeOf(OpsTryTableEnter),
        .try_table_leave => @sizeOf(OpsTryTableLeave),

        .simd_unary, .simd_compare => @sizeOf(OpsSimdUnary),
        .simd_binary, .simd_shift_scalar => @sizeOf(OpsSimdBinary),
        .simd_ternary => @sizeOf(OpsSimdTernary),
        .simd_extract_lane => @sizeOf(OpsSimdExtractLane),
        .simd_replace_lane => @sizeOf(OpsSimdReplaceLane),
        .simd_shuffle => @sizeOf(OpsSimdShuffle),
        .simd_load => @sizeOf(OpsSimdLoad),
        .simd_store => @sizeOf(OpsSimdStore),
    };
    return HANDLER_SIZE + ops_size;
}

// ── Handler table ─────────────────────────────────────────────────────────────

/// Maps each Op tag to the corresponding handler function pointer.
/// Provided by handlers.zig and passed to `encode()`.
pub const HandlerTable = struct {
    unreachable_: Handler,
    const_i32: Handler,
    const_i64: Handler,
    const_f32: Handler,
    const_f64: Handler,
    const_v128: Handler,
    const_ref_null: Handler,
    ref_is_null: Handler,
    ref_func: Handler,
    ref_eq: Handler,
    local_get: Handler,
    local_set: Handler,
    global_get: Handler,
    global_set: Handler,
    copy: Handler,
    /// Peephole K: fused copy + conditional branch
    copy_jump_if_nz: Handler,
    jump: Handler,
    jump_if_z: Handler,
    jump_if_nz: Handler,
    jump_table: Handler,
    select: Handler,
    ret: Handler,
    // Fused binop+ret (Peephole I)
    i32_add_ret: Handler,
    i32_sub_ret: Handler,
    i64_add_ret: Handler,
    i64_sub_ret: Handler,
    // i32 binary
    i32_add: Handler,
    i32_sub: Handler,
    i32_mul: Handler,
    i32_div_s: Handler,
    i32_div_u: Handler,
    i32_rem_s: Handler,
    i32_rem_u: Handler,
    i32_and: Handler,
    i32_or: Handler,
    i32_xor: Handler,
    i32_shl: Handler,
    i32_shr_s: Handler,
    i32_shr_u: Handler,
    i32_rotl: Handler,
    i32_rotr: Handler,
    // i64 binary
    i64_add: Handler,
    i64_sub: Handler,
    i64_mul: Handler,
    i64_div_s: Handler,
    i64_div_u: Handler,
    i64_rem_s: Handler,
    i64_rem_u: Handler,
    i64_and: Handler,
    i64_or: Handler,
    i64_xor: Handler,
    i64_shl: Handler,
    i64_shr_s: Handler,
    i64_shr_u: Handler,
    i64_rotl: Handler,
    i64_rotr: Handler,
    // f32 binary
    f32_add: Handler,
    f32_sub: Handler,
    f32_mul: Handler,
    f32_div: Handler,
    f32_min: Handler,
    f32_max: Handler,
    f32_copysign: Handler,
    // f64 binary
    f64_add: Handler,
    f64_sub: Handler,
    f64_mul: Handler,
    f64_div: Handler,
    f64_min: Handler,
    f64_max: Handler,
    f64_copysign: Handler,
    // i32 unary
    i32_clz: Handler,
    i32_ctz: Handler,
    i32_popcnt: Handler,
    i32_eqz: Handler,
    // i64 unary
    i64_clz: Handler,
    i64_ctz: Handler,
    i64_popcnt: Handler,
    i64_eqz: Handler,
    // f32 unary
    f32_abs: Handler,
    f32_neg: Handler,
    f32_ceil: Handler,
    f32_floor: Handler,
    f32_trunc: Handler,
    f32_nearest: Handler,
    f32_sqrt: Handler,
    // f64 unary
    f64_abs: Handler,
    f64_neg: Handler,
    f64_ceil: Handler,
    f64_floor: Handler,
    f64_trunc: Handler,
    f64_nearest: Handler,
    f64_sqrt: Handler,
    // i32 comparisons
    i32_eq: Handler,
    i32_ne: Handler,
    i32_lt_s: Handler,
    i32_lt_u: Handler,
    i32_gt_s: Handler,
    i32_gt_u: Handler,
    i32_le_s: Handler,
    i32_le_u: Handler,
    i32_ge_s: Handler,
    i32_ge_u: Handler,
    // i64 comparisons
    i64_eq: Handler,
    i64_ne: Handler,
    i64_lt_s: Handler,
    i64_lt_u: Handler,
    i64_gt_s: Handler,
    i64_gt_u: Handler,
    i64_le_s: Handler,
    i64_le_u: Handler,
    i64_ge_s: Handler,
    i64_ge_u: Handler,
    // f32/f64 comparisons
    f32_eq: Handler,
    f32_ne: Handler,
    f32_lt: Handler,
    f32_gt: Handler,
    f32_le: Handler,
    f32_ge: Handler,
    f64_eq: Handler,
    f64_ne: Handler,
    f64_lt: Handler,
    f64_gt: Handler,
    f64_le: Handler,
    f64_ge: Handler,
    // conversions
    i32_wrap_i64: Handler,
    i32_trunc_f32_s: Handler,
    i32_trunc_f32_u: Handler,
    i32_trunc_f64_s: Handler,
    i32_trunc_f64_u: Handler,
    i64_extend_i32_s: Handler,
    i64_extend_i32_u: Handler,
    i64_trunc_f32_s: Handler,
    i64_trunc_f32_u: Handler,
    i64_trunc_f64_s: Handler,
    i64_trunc_f64_u: Handler,
    i32_trunc_sat_f32_s: Handler,
    i32_trunc_sat_f32_u: Handler,
    i32_trunc_sat_f64_s: Handler,
    i32_trunc_sat_f64_u: Handler,
    i64_trunc_sat_f32_s: Handler,
    i64_trunc_sat_f32_u: Handler,
    i64_trunc_sat_f64_s: Handler,
    i64_trunc_sat_f64_u: Handler,
    f32_convert_i32_s: Handler,
    f32_convert_i32_u: Handler,
    f32_convert_i64_s: Handler,
    f32_convert_i64_u: Handler,
    f32_demote_f64: Handler,
    f64_promote_f32: Handler,
    f64_convert_i32_s: Handler,
    f64_convert_i32_u: Handler,
    f64_convert_i64_s: Handler,
    f64_convert_i64_u: Handler,
    i32_reinterpret_f32: Handler,
    i64_reinterpret_f64: Handler,
    f32_reinterpret_i32: Handler,
    f64_reinterpret_i64: Handler,
    i32_extend8_s: Handler,
    i32_extend16_s: Handler,
    i64_extend8_s: Handler,
    i64_extend16_s: Handler,
    i64_extend32_s: Handler,
    // memory loads
    i32_load: Handler,
    i32_load8_s: Handler,
    i32_load8_u: Handler,
    i32_load16_s: Handler,
    i32_load16_u: Handler,
    i64_load: Handler,
    i64_load8_s: Handler,
    i64_load8_u: Handler,
    i64_load16_s: Handler,
    i64_load16_u: Handler,
    i64_load32_s: Handler,
    i64_load32_u: Handler,
    f32_load: Handler,
    f64_load: Handler,
    // memory stores
    i32_store: Handler,
    i32_store8: Handler,
    i32_store16: Handler,
    i64_store: Handler,
    i64_store8: Handler,
    i64_store16: Handler,
    i64_store32: Handler,
    f32_store: Handler,
    f64_store: Handler,
    // memory misc
    memory_size: Handler,
    memory_grow: Handler,
    memory_init: Handler,
    data_drop: Handler,
    memory_copy: Handler,
    memory_fill: Handler,
    // calls
    call: Handler,
    call_indirect: Handler,
    return_call: Handler,
    return_call_indirect: Handler,
    call_ref: Handler,
    return_call_ref: Handler,
    // atomics
    atomic_load: Handler,
    atomic_store: Handler,
    atomic_rmw: Handler,
    atomic_cmpxchg: Handler,
    atomic_fence: Handler,
    atomic_notify: Handler,
    atomic_wait32: Handler,
    atomic_wait64: Handler,
    // tables
    table_get: Handler,
    table_set: Handler,
    table_size: Handler,
    table_grow: Handler,
    table_fill: Handler,
    table_copy: Handler,
    table_init: Handler,
    elem_drop: Handler,
    // GC structs
    struct_new: Handler,
    struct_new_default: Handler,
    struct_get: Handler,
    struct_get_s: Handler,
    struct_get_u: Handler,
    struct_set: Handler,
    // GC arrays
    array_new: Handler,
    array_new_default: Handler,
    array_new_fixed: Handler,
    array_new_data: Handler,
    array_new_elem: Handler,
    array_get: Handler,
    array_get_s: Handler,
    array_get_u: Handler,
    array_set: Handler,
    array_len: Handler,
    array_fill: Handler,
    array_copy: Handler,
    array_init_data: Handler,
    array_init_elem: Handler,
    // GC i31
    ref_i31: Handler,
    i31_get_s: Handler,
    i31_get_u: Handler,
    // GC ref test/cast
    ref_test: Handler,
    ref_cast: Handler,
    ref_as_non_null: Handler,
    br_on_null: Handler,
    br_on_non_null: Handler,
    br_on_cast: Handler,
    br_on_cast_fail: Handler,
    // GC calls
    // any/extern conversion
    any_convert_extern: Handler,
    extern_convert_any: Handler,
    // EH
    throw: Handler,
    throw_ref: Handler,
    try_table_enter: Handler,
    try_table_leave: Handler,
    // Fused: binop-imm (Candidate C)
    i32_add_imm: Handler,
    i32_sub_imm: Handler,
    i32_mul_imm: Handler,
    i32_and_imm: Handler,
    i32_or_imm: Handler,
    i32_xor_imm: Handler,
    i32_shl_imm: Handler,
    i32_shr_s_imm: Handler,
    i32_shr_u_imm: Handler,
    i32_eq_imm: Handler,
    i32_ne_imm: Handler,
    i32_lt_s_imm: Handler,
    i32_lt_u_imm: Handler,
    i32_gt_s_imm: Handler,
    i32_gt_u_imm: Handler,
    i32_le_s_imm: Handler,
    i32_le_u_imm: Handler,
    i32_ge_s_imm: Handler,
    i32_ge_u_imm: Handler,
    // Fused: i64 binop-imm (Candidate C, i64)
    i64_add_imm: Handler,
    i64_sub_imm: Handler,
    i64_mul_imm: Handler,
    i64_and_imm: Handler,
    i64_or_imm: Handler,
    i64_xor_imm: Handler,
    i64_shl_imm: Handler,
    i64_shr_s_imm: Handler,
    i64_shr_u_imm: Handler,
    i64_eq_imm: Handler,
    i64_ne_imm: Handler,
    i64_lt_s_imm: Handler,
    i64_lt_u_imm: Handler,
    i64_gt_s_imm: Handler,
    i64_gt_u_imm: Handler,
    i64_le_s_imm: Handler,
    i64_le_u_imm: Handler,
    i64_ge_s_imm: Handler,
    i64_ge_u_imm: Handler,
    // r0 variants: i32 binop-imm-r
    i32_add_imm_r: Handler,
    i32_sub_imm_r: Handler,
    i32_mul_imm_r: Handler,
    i32_and_imm_r: Handler,
    i32_or_imm_r: Handler,
    i32_xor_imm_r: Handler,
    i32_shl_imm_r: Handler,
    i32_shr_s_imm_r: Handler,
    i32_shr_u_imm_r: Handler,
    // r0 variants: i64 binop-imm-r
    i64_add_imm_r: Handler,
    i64_sub_imm_r: Handler,
    i64_mul_imm_r: Handler,
    i64_and_imm_r: Handler,
    i64_or_imm_r: Handler,
    i64_xor_imm_r: Handler,
    i64_shl_imm_r: Handler,
    i64_shr_s_imm_r: Handler,
    i64_shr_u_imm_r: Handler,
    // Fused: compare-jump (Candidate F)
    i32_eq_jump_if_false: Handler,
    i32_ne_jump_if_false: Handler,
    i32_lt_s_jump_if_false: Handler,
    i32_lt_u_jump_if_false: Handler,
    i32_gt_s_jump_if_false: Handler,
    i32_gt_u_jump_if_false: Handler,
    i32_le_s_jump_if_false: Handler,
    i32_le_u_jump_if_false: Handler,
    i32_ge_s_jump_if_false: Handler,
    i32_ge_u_jump_if_false: Handler,
    i32_eqz_jump_if_false: Handler,
    // Fused: i64 compare-jump (Candidate F, i64)
    i64_eq_jump_if_false: Handler,
    i64_ne_jump_if_false: Handler,
    i64_lt_s_jump_if_false: Handler,
    i64_lt_u_jump_if_false: Handler,
    i64_gt_s_jump_if_false: Handler,
    i64_gt_u_jump_if_false: Handler,
    i64_le_s_jump_if_false: Handler,
    i64_le_u_jump_if_false: Handler,
    i64_ge_s_jump_if_false: Handler,
    i64_ge_u_jump_if_false: Handler,
    i64_eqz_jump_if_false: Handler,
    // Fused compare-jump-if-true (Peephole J)
    i32_eq_jump_if_true: Handler,
    i32_ne_jump_if_true: Handler,
    i32_lt_s_jump_if_true: Handler,
    i32_lt_u_jump_if_true: Handler,
    i32_gt_s_jump_if_true: Handler,
    i32_gt_u_jump_if_true: Handler,
    i32_le_s_jump_if_true: Handler,
    i32_le_u_jump_if_true: Handler,
    i32_ge_s_jump_if_true: Handler,
    i32_ge_u_jump_if_true: Handler,
    i32_eqz_jump_if_true: Handler,
    i64_eq_jump_if_true: Handler,
    i64_ne_jump_if_true: Handler,
    i64_lt_s_jump_if_true: Handler,
    i64_lt_u_jump_if_true: Handler,
    i64_gt_s_jump_if_true: Handler,
    i64_gt_u_jump_if_true: Handler,
    i64_le_s_jump_if_true: Handler,
    i64_le_u_jump_if_true: Handler,
    i64_ge_s_jump_if_true: Handler,
    i64_ge_u_jump_if_true: Handler,
    i64_eqz_jump_if_true: Handler,
    // Fused: binop-to-local (Candidate D)
    i32_add_to_local: Handler,
    i32_sub_to_local: Handler,
    i32_mul_to_local: Handler,
    i32_and_to_local: Handler,
    i32_or_to_local: Handler,
    i32_xor_to_local: Handler,
    i32_shl_to_local: Handler,
    i32_shr_s_to_local: Handler,
    i32_shr_u_to_local: Handler,
    // Fused: i64 binop-to-local (Candidate D, i64)
    i64_add_to_local: Handler,
    i64_sub_to_local: Handler,
    i64_mul_to_local: Handler,
    i64_and_to_local: Handler,
    i64_or_to_local: Handler,
    i64_xor_to_local: Handler,
    i64_shl_to_local: Handler,
    i64_shr_s_to_local: Handler,
    i64_shr_u_to_local: Handler,
    // Fused: binop + local_tee
    i32_add_tee_local: Handler,
    i32_sub_tee_local: Handler,
    i32_mul_tee_local: Handler,
    i32_and_tee_local: Handler,
    i32_or_tee_local: Handler,
    i32_xor_tee_local: Handler,
    i32_shl_tee_local: Handler,
    i32_shr_s_tee_local: Handler,
    i32_shr_u_tee_local: Handler,
    i64_add_tee_local: Handler,
    i64_sub_tee_local: Handler,
    i64_mul_tee_local: Handler,
    i64_and_tee_local: Handler,
    i64_or_tee_local: Handler,
    i64_xor_tee_local: Handler,
    i64_shl_tee_local: Handler,
    i64_shr_s_tee_local: Handler,
    i64_shr_u_tee_local: Handler,
    // Fused: comparison + local_set (cmp_to_local)
    i32_eq_to_local: Handler,
    i32_ne_to_local: Handler,
    i32_lt_s_to_local: Handler,
    i32_lt_u_to_local: Handler,
    i32_gt_s_to_local: Handler,
    i32_gt_u_to_local: Handler,
    i32_le_s_to_local: Handler,
    i32_le_u_to_local: Handler,
    i32_ge_s_to_local: Handler,
    i32_ge_u_to_local: Handler,
    i64_eq_to_local: Handler,
    i64_ne_to_local: Handler,
    i64_lt_s_to_local: Handler,
    i64_lt_u_to_local: Handler,
    i64_gt_s_to_local: Handler,
    i64_gt_u_to_local: Handler,
    i64_le_s_to_local: Handler,
    i64_le_u_to_local: Handler,
    i64_ge_s_to_local: Handler,
    i64_ge_u_to_local: Handler,
    // fused binop-imm-to-local (Candidate E)
    i32_add_imm_to_local: Handler,
    i32_sub_imm_to_local: Handler,
    i32_mul_imm_to_local: Handler,
    i32_and_imm_to_local: Handler,
    i32_or_imm_to_local: Handler,
    i32_xor_imm_to_local: Handler,
    i32_shl_imm_to_local: Handler,
    i32_shr_s_imm_to_local: Handler,
    i32_shr_u_imm_to_local: Handler,
    i64_add_imm_to_local: Handler,
    i64_sub_imm_to_local: Handler,
    i64_mul_imm_to_local: Handler,
    i64_and_imm_to_local: Handler,
    i64_or_imm_to_local: Handler,
    i64_xor_imm_to_local: Handler,
    i64_shl_imm_to_local: Handler,
    i64_shr_s_imm_to_local: Handler,
    i64_shr_u_imm_to_local: Handler,
    // fused local-inplace (Candidate H)
    i32_add_local_inplace: Handler,
    i32_sub_local_inplace: Handler,
    i32_mul_local_inplace: Handler,
    i32_and_local_inplace: Handler,
    i32_or_local_inplace: Handler,
    i32_xor_local_inplace: Handler,
    i32_shl_local_inplace: Handler,
    i32_shr_s_local_inplace: Handler,
    i32_shr_u_local_inplace: Handler,
    i64_add_local_inplace: Handler,
    i64_sub_local_inplace: Handler,
    i64_mul_local_inplace: Handler,
    i64_and_local_inplace: Handler,
    i64_or_local_inplace: Handler,
    i64_xor_local_inplace: Handler,
    i64_shl_local_inplace: Handler,
    i64_shr_s_local_inplace: Handler,
    i64_shr_u_local_inplace: Handler,
    // fused const-to-local
    i32_const_to_local: Handler,
    i64_const_to_local: Handler,
    // superinstruction: imm + local_set → imm_to_local
    i32_imm_to_local: Handler,
    i64_imm_to_local: Handler,
    // fused global_get-to-local
    global_get_to_local: Handler,
    // fused load-to-local
    i32_load_to_local: Handler,
    i64_load_to_local: Handler,
    // fused compare-imm-jump (Candidate G)
    i32_eq_imm_jump_if_false: Handler,
    i32_ne_imm_jump_if_false: Handler,
    i32_lt_s_imm_jump_if_false: Handler,
    i32_lt_u_imm_jump_if_false: Handler,
    i32_gt_s_imm_jump_if_false: Handler,
    i32_gt_u_imm_jump_if_false: Handler,
    i32_le_s_imm_jump_if_false: Handler,
    i32_le_u_imm_jump_if_false: Handler,
    i32_ge_s_imm_jump_if_false: Handler,
    i32_ge_u_imm_jump_if_false: Handler,
    i64_eq_imm_jump_if_false: Handler,
    i64_ne_imm_jump_if_false: Handler,
    i64_lt_s_imm_jump_if_false: Handler,
    i64_lt_u_imm_jump_if_false: Handler,
    i64_gt_s_imm_jump_if_false: Handler,
    i64_gt_u_imm_jump_if_false: Handler,
    i64_le_s_imm_jump_if_false: Handler,
    i64_le_u_imm_jump_if_false: Handler,
    i64_ge_s_imm_jump_if_false: Handler,
    i64_ge_u_imm_jump_if_false: Handler,
    // fused compare-imm-jump, true-branch (J-imm)
    i32_eq_imm_jump_if_true: Handler,
    i32_ne_imm_jump_if_true: Handler,
    i32_lt_s_imm_jump_if_true: Handler,
    i32_lt_u_imm_jump_if_true: Handler,
    i32_gt_s_imm_jump_if_true: Handler,
    i32_gt_u_imm_jump_if_true: Handler,
    i32_le_s_imm_jump_if_true: Handler,
    i32_le_u_imm_jump_if_true: Handler,
    i32_ge_s_imm_jump_if_true: Handler,
    i32_ge_u_imm_jump_if_true: Handler,
    i64_eq_imm_jump_if_true: Handler,
    i64_ne_imm_jump_if_true: Handler,
    i64_lt_s_imm_jump_if_true: Handler,
    i64_lt_u_imm_jump_if_true: Handler,
    i64_gt_s_imm_jump_if_true: Handler,
    i64_gt_u_imm_jump_if_true: Handler,
    i64_le_s_imm_jump_if_true: Handler,
    i64_le_u_imm_jump_if_true: Handler,
    i64_ge_s_imm_jump_if_true: Handler,
    i64_ge_u_imm_jump_if_true: Handler,
    // SIMD
    simd_unary: Handler,
    simd_binary: Handler,
    simd_ternary: Handler,
    simd_compare: Handler,
    simd_shift_scalar: Handler,
    simd_extract_lane: Handler,
    simd_replace_lane: Handler,
    simd_shuffle: Handler,
    simd_load: Handler,
    simd_store: Handler,
};

// ── Encode ────────────────────────────────────────────────────────────────────

/// Write inline arg slots (Slot[]) immediately after an ops struct in the code buffer.
/// `ops_ptr` points to the start of the operands (after the handler pointer).
/// `comptime OpsT` is the fixed-size operand struct type.
/// `call_args` is the full call_args pool from the CompiledFunction.
/// `args_start` is the starting index into call_args.
/// `args_len` is the number of arg slots to write.
fn writeInlineArgs(ops_ptr: [*]u8, comptime OpsT: type, call_args: []const Slot, args_start: u32, args_len: u32) void {
    const base: [*]align(1) Slot = @ptrCast(ops_ptr + @sizeOf(OpsT));
    for (0..args_len) |j| {
        base[j] = call_args[args_start + j];
    }
}

/// Write an ops struct to an unaligned byte pointer (compact encoding).
inline fn writeOps(comptime T: type, ptr: [*]u8, value: T) void {
    @setEvalBranchQuota(4000);
    std.mem.bytesAsValue(T, ptr[0..@sizeOf(T)]).* = value;
}

/// Encode a `CompiledFunction` into an `EncodedFunction`.
///
/// `handlers` must be a pointer to a fully-populated `HandlerTable`.
/// The returned `EncodedFunction` is allocated with `allocator`; caller owns it
/// and must call `.deinit(allocator)` when done.
///
/// After this call succeeds, the caller may free the `CompiledFunction`'s
/// `ops` ArrayList; the auxiliary tables are consumed (moved) into the result.
pub fn encode(
    allocator: Allocator,
    cf: *CompiledFunction,
    handlers: *const HandlerTable,
) Allocator.Error!EncodedFunction {
    const ops = cf.ops.items;
    const n_ops = ops.len;

    // ── Pass 1: compute byte offset for each op ────────────────────────────
    // op_offset[i] = byte offset of op i in the final code[] buffer.
    const op_offset = try allocator.alloc(u32, n_ops + 1);
    defer allocator.free(op_offset);

    {
        var off: u32 = 0;
        for (ops, 0..) |op, i| {
            op_offset[i] = off;
            off += @intCast(instrSize(op));
        }
        op_offset[n_ops] = off; // sentinel: "one past the end"
    }

    const code_len = op_offset[n_ops];

    // ── Allocate code buffer ───────────────────────────────────────────────
    const code = try allocator.alignedAlloc(u8, .@"8", code_len);
    errdefer allocator.free(code);

    // ── Pass 2: write instructions ─────────────────────────────────────────
    for (ops, 0..) |op, i| {
        const base = op_offset[i];
        const ptr = code.ptr + base;

        // Write handler pointer (always 8 bytes at the start).
        const h: Handler = handlerFor(op, handlers);
        std.mem.bytesAsValue(Handler, ptr[0..@sizeOf(Handler)]).* = h;

        const ops_ptr = ptr + HANDLER_SIZE;

        // Write operands; patch op-index jump targets to byte offsets.
        switch (op) {
            .unreachable_ => {},
            .const_i32 => |inst| {
                writeOps(OpsConstI32, ops_ptr, .{
                    .dst = inst.dst,
                    .value = inst.value,
                });
            },
            .const_i64 => |inst| {
                writeOps(OpsConstI64, ops_ptr, .{
                    .dst = inst.dst,
                    .value = inst.value,
                });
            },
            .const_f32 => |inst| {
                writeOps(OpsConstF32, ops_ptr, .{
                    .dst = inst.dst,
                    .value = inst.value,
                });
            },
            .const_f64 => |inst| {
                writeOps(OpsConstF64, ops_ptr, .{
                    .dst = inst.dst,
                    .value = inst.value,
                });
            },
            .const_v128 => |inst| {
                writeOps(OpsConstV128, ops_ptr, .{
                    .dst = inst.dst,
                    .value = @bitCast(inst.value),
                });
            },
            .const_ref_null => |inst| {
                writeOps(OpsDst, ops_ptr, .{ .dst = inst.dst });
            },
            .ref_is_null => |inst| {
                writeOps(OpsDstSrc, ops_ptr, .{ .dst = inst.dst, .src = inst.src });
            },
            .ref_func => |inst| {
                writeOps(OpsRefFunc, ops_ptr, .{ .dst = inst.dst, .func_idx = inst.func_idx });
            },
            .ref_eq => |inst| {
                writeOps(OpsDstLhsRhs, ops_ptr, .{ .dst = inst.dst, .lhs = inst.lhs, .rhs = inst.rhs });
            },
            .local_get => |inst| {
                writeOps(OpsLocalGet, ops_ptr, .{ .dst = inst.dst, .local = inst.local });
            },
            .local_set => |inst| {
                writeOps(OpsLocalSet, ops_ptr, .{ .local = inst.local, .src = inst.src });
            },
            .global_get => |inst| {
                writeOps(OpsGlobalGet, ops_ptr, .{ .dst = inst.dst, .global_idx = inst.global_idx });
            },
            .global_set => |inst| {
                writeOps(OpsGlobalSet, ops_ptr, .{ .src = inst.src, .global_idx = inst.global_idx });
            },
            .copy => |inst| {
                writeOps(OpsCopy, ops_ptr, .{ .dst = inst.dst, .src = inst.src });
            },
            .copy_jump_if_nz => |inst| {
                writeOps(OpsCopyJumpIfNz, ops_ptr, .{
                    .dst = inst.dst,
                    .src = inst.src,
                    .cond = inst.cond,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .jump => |inst| {
                writeOps(OpsJump, ops_ptr, .{
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .jump_if_z => |inst| {
                writeOps(OpsJumpIfZ, ops_ptr, .{
                    .cond = inst.cond,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .jump_if_nz => |inst| {
                writeOps(OpsJumpIfZ, ops_ptr, .{
                    .cond = inst.cond,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .jump_table => |inst| {
                writeOps(OpsJumpTable, ops_ptr, .{
                    .index = inst.index,
                    .targets_start = inst.targets_start,
                    .targets_len = inst.targets_len,
                });
            },
            .select => |inst| {
                writeOps(OpsSelect, ops_ptr, .{
                    .dst = inst.dst,
                    .val1 = inst.val1,
                    .val2 = inst.val2,
                    .cond = inst.cond,
                });
            },
            .ret => |inst| {
                writeOps(OpsRet, ops_ptr, .{
                    .has_value = if (inst.value != null) 1 else 0,
                    .value = inst.value orelse 0,
                });
            },
            // ── Fused binop+ret (Peephole I) ───────────────────────────────
            inline .i32_add_ret, .i32_sub_ret, .i64_add_ret, .i64_sub_ret => |inst| {
                writeOps(OpsLhsRhs, ops_ptr, .{ .lhs = inst.lhs, .rhs = inst.rhs });
            },

            // ── All binary ops sharing dst/lhs/rhs layout ──────────────────
            inline .i32_add,
            .i32_sub,
            .i32_mul,
            .i32_div_s,
            .i32_div_u,
            .i32_rem_s,
            .i32_rem_u,
            .i32_and,
            .i32_or,
            .i32_xor,
            .i32_shl,
            .i32_shr_s,
            .i32_shr_u,
            .i32_rotl,
            .i32_rotr,
            .i64_add,
            .i64_sub,
            .i64_mul,
            .i64_div_s,
            .i64_div_u,
            .i64_rem_s,
            .i64_rem_u,
            .i64_and,
            .i64_or,
            .i64_xor,
            .i64_shl,
            .i64_shr_s,
            .i64_shr_u,
            .i64_rotl,
            .i64_rotr,
            .f32_add,
            .f32_sub,
            .f32_mul,
            .f32_div,
            .f32_min,
            .f32_max,
            .f32_copysign,
            .f64_add,
            .f64_sub,
            .f64_mul,
            .f64_div,
            .f64_min,
            .f64_max,
            .f64_copysign,
            .i32_eq,
            .i32_ne,
            .i32_lt_s,
            .i32_lt_u,
            .i32_gt_s,
            .i32_gt_u,
            .i32_le_s,
            .i32_le_u,
            .i32_ge_s,
            .i32_ge_u,
            .i64_eq,
            .i64_ne,
            .i64_lt_s,
            .i64_lt_u,
            .i64_gt_s,
            .i64_gt_u,
            .i64_le_s,
            .i64_le_u,
            .i64_ge_s,
            .i64_ge_u,
            .f32_eq,
            .f32_ne,
            .f32_lt,
            .f32_gt,
            .f32_le,
            .f32_ge,
            .f64_eq,
            .f64_ne,
            .f64_lt,
            .f64_gt,
            .f64_le,
            .f64_ge,
            => |inst| {
                writeOps(OpsDstLhsRhs, ops_ptr, .{
                    .dst = inst.dst,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },

            // ── All unary / conversion ops sharing dst/src layout ──────────
            inline .i32_clz,
            .i32_ctz,
            .i32_popcnt,
            .i32_eqz,
            .i64_clz,
            .i64_ctz,
            .i64_popcnt,
            .i64_eqz,
            .f32_abs,
            .f32_neg,
            .f32_ceil,
            .f32_floor,
            .f32_trunc,
            .f32_nearest,
            .f32_sqrt,
            .f64_abs,
            .f64_neg,
            .f64_ceil,
            .f64_floor,
            .f64_trunc,
            .f64_nearest,
            .f64_sqrt,
            .i32_wrap_i64,
            .i32_trunc_f32_s,
            .i32_trunc_f32_u,
            .i32_trunc_f64_s,
            .i32_trunc_f64_u,
            .i64_extend_i32_s,
            .i64_extend_i32_u,
            .i64_trunc_f32_s,
            .i64_trunc_f32_u,
            .i64_trunc_f64_s,
            .i64_trunc_f64_u,
            .i32_trunc_sat_f32_s,
            .i32_trunc_sat_f32_u,
            .i32_trunc_sat_f64_s,
            .i32_trunc_sat_f64_u,
            .i64_trunc_sat_f32_s,
            .i64_trunc_sat_f32_u,
            .i64_trunc_sat_f64_s,
            .i64_trunc_sat_f64_u,
            .f32_convert_i32_s,
            .f32_convert_i32_u,
            .f32_convert_i64_s,
            .f32_convert_i64_u,
            .f32_demote_f64,
            .f64_promote_f32,
            .f64_convert_i32_s,
            .f64_convert_i32_u,
            .f64_convert_i64_s,
            .f64_convert_i64_u,
            .i32_reinterpret_f32,
            .i64_reinterpret_f64,
            .f32_reinterpret_i32,
            .f64_reinterpret_i64,
            .i32_extend8_s,
            .i32_extend16_s,
            .i64_extend8_s,
            .i64_extend16_s,
            .i64_extend32_s,
            => |inst| {
                writeOps(OpsDstSrc, ops_ptr, .{
                    .dst = inst.dst,
                    .src = inst.src,
                });
            },

            // ── Memory loads ──────────────────────────────────────────────
            inline .i32_load,
            .i32_load8_s,
            .i32_load8_u,
            .i32_load16_s,
            .i32_load16_u,
            .i64_load,
            .i64_load8_s,
            .i64_load8_u,
            .i64_load16_s,
            .i64_load16_u,
            .i64_load32_s,
            .i64_load32_u,
            .f32_load,
            .f64_load,
            => |inst| {
                writeOps(OpsLoad, ops_ptr, .{
                    .dst = inst.dst,
                    .addr = inst.addr,
                    .offset = inst.offset,
                });
            },

            // ── Memory stores ─────────────────────────────────────────────
            inline .i32_store,
            .i32_store8,
            .i32_store16,
            .i64_store,
            .i64_store8,
            .i64_store16,
            .i64_store32,
            .f32_store,
            .f64_store,
            => |inst| {
                writeOps(OpsStore, ops_ptr, .{
                    .addr = inst.addr,
                    .src = inst.src,
                    .offset = inst.offset,
                });
            },

            .memory_size => |inst| {
                writeOps(OpsMemorySize, ops_ptr, .{ .dst = inst.dst });
            },
            .memory_grow => |inst| {
                writeOps(OpsMemoryGrow, ops_ptr, .{ .dst = inst.dst, .delta = inst.delta });
            },
            .memory_init => |inst| {
                writeOps(OpsMemoryInit, ops_ptr, .{
                    .segment_idx = inst.segment_idx,
                    .dst_addr = inst.dst_addr,
                    .src_offset = inst.src_offset,
                    .len = inst.len,
                });
            },
            .data_drop => |inst| {
                writeOps(OpsDataDrop, ops_ptr, .{ .segment_idx = inst.segment_idx });
            },
            .memory_copy => |inst| {
                writeOps(OpsMemoryCopy, ops_ptr, .{
                    .dst_addr = inst.dst_addr,
                    .src_addr = inst.src_addr,
                    .len = inst.len,
                });
            },
            .memory_fill => |inst| {
                writeOps(OpsMemoryFill, ops_ptr, .{
                    .dst_addr = inst.dst_addr,
                    .value = inst.value,
                    .len = inst.len,
                });
            },

            .call => |inst| {
                writeOps(OpsCall, ops_ptr, .{
                    .dst_valid = if (inst.dst != null) 1 else 0,
                    .dst = inst.dst orelse 0,
                    .func_idx = inst.func_idx,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, OpsCall, cf.call_args.items, inst.args_start, inst.args_len);
            },
            .call_indirect => |inst| {
                writeOps(OpsCallIndirect, ops_ptr, .{
                    .dst_valid = if (inst.dst != null) 1 else 0,
                    .dst = inst.dst orelse 0,
                    .index = inst.index,
                    .type_index = inst.type_index,
                    .table_index = inst.table_index,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, OpsCallIndirect, cf.call_args.items, inst.args_start, inst.args_len);
            },
            .return_call => |inst| {
                writeOps(OpsReturnCall, ops_ptr, .{
                    .func_idx = inst.func_idx,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, OpsReturnCall, cf.call_args.items, inst.args_start, inst.args_len);
            },
            .return_call_indirect => |inst| {
                writeOps(OpsReturnCallIndirect, ops_ptr, .{
                    .index = inst.index,
                    .type_index = inst.type_index,
                    .table_index = inst.table_index,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, OpsReturnCallIndirect, cf.call_args.items, inst.args_start, inst.args_len);
            },
            .call_ref => |inst| {
                writeOps(OpsCallRef, ops_ptr, .{
                    .dst_valid = if (inst.dst != null) 1 else 0,
                    .dst = inst.dst orelse 0,
                    .ref = inst.ref,
                    .type_idx = inst.type_idx,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, OpsCallRef, cf.call_args.items, inst.args_start, inst.args_len);
            },
            .return_call_ref => |inst| {
                writeOps(OpsReturnCallRef, ops_ptr, .{
                    .ref = inst.ref,
                    .type_idx = inst.type_idx,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, OpsReturnCallRef, cf.call_args.items, inst.args_start, inst.args_len);
            },

            // ── Atomics ───────────────────────────────────────────────────
            .atomic_load => |inst| {
                writeOps(OpsAtomicLoad, ops_ptr, .{
                    .dst = inst.dst,
                    .addr = inst.addr,
                    .offset = inst.offset,
                    .width = @intFromEnum(inst.width),
                    .ty = @intFromEnum(inst.ty),
                });
            },
            .atomic_store => |inst| {
                writeOps(OpsAtomicStore, ops_ptr, .{
                    .addr = inst.addr,
                    .src = inst.src,
                    .offset = inst.offset,
                    .width = @intFromEnum(inst.width),
                    .ty = @intFromEnum(inst.ty),
                });
            },
            .atomic_rmw => |inst| {
                writeOps(OpsAtomicRmw, ops_ptr, .{
                    .dst = inst.dst,
                    .addr = inst.addr,
                    .src = inst.src,
                    .offset = inst.offset,
                    .op = @intFromEnum(inst.op),
                    .width = @intFromEnum(inst.width),
                    .ty = @intFromEnum(inst.ty),
                });
            },
            .atomic_cmpxchg => |inst| {
                writeOps(OpsAtomicCmpxchg, ops_ptr, .{
                    .dst = inst.dst,
                    .addr = inst.addr,
                    .expected = inst.expected,
                    .replacement = inst.replacement,
                    .offset = inst.offset,
                    .width = @intFromEnum(inst.width),
                    .ty = @intFromEnum(inst.ty),
                });
            },
            .atomic_fence => {},
            .atomic_notify => |inst| {
                writeOps(OpsAtomicNotify, ops_ptr, .{
                    .dst = inst.dst,
                    .addr = inst.addr,
                    .count = inst.count,
                    .offset = inst.offset,
                });
            },
            .atomic_wait32 => |inst| {
                writeOps(OpsAtomicWait32, ops_ptr, .{
                    .dst = inst.dst,
                    .addr = inst.addr,
                    .expected = inst.expected,
                    .timeout = inst.timeout,
                    .offset = inst.offset,
                });
            },
            .atomic_wait64 => |inst| {
                writeOps(OpsAtomicWait64, ops_ptr, .{
                    .dst = inst.dst,
                    .addr = inst.addr,
                    .expected = inst.expected,
                    .timeout = inst.timeout,
                    .offset = inst.offset,
                });
            },

            // ── Tables ────────────────────────────────────────────────────
            .table_get => |inst| {
                writeOps(OpsTableGet, ops_ptr, .{
                    .dst = inst.dst,
                    .table_index = inst.table_index,
                    .index = inst.index,
                });
            },
            .table_set => |inst| {
                writeOps(OpsTableSet, ops_ptr, .{
                    .table_index = inst.table_index,
                    .index = inst.index,
                    .value = inst.value,
                });
            },
            .table_size => |inst| {
                writeOps(OpsTableSize, ops_ptr, .{
                    .dst = inst.dst,
                    .table_index = inst.table_index,
                });
            },
            .table_grow => |inst| {
                writeOps(OpsTableGrow, ops_ptr, .{
                    .dst = inst.dst,
                    .table_index = inst.table_index,
                    .init = inst.init,
                    .delta = inst.delta,
                });
            },
            .table_fill => |inst| {
                writeOps(OpsTableFill, ops_ptr, .{
                    .table_index = inst.table_index,
                    .dst_idx = inst.dst_idx,
                    .value = inst.value,
                    .len = inst.len,
                });
            },
            .table_copy => |inst| {
                writeOps(OpsTableCopy, ops_ptr, .{
                    .dst_table = inst.dst_table,
                    .src_table = inst.src_table,
                    .dst_idx = inst.dst_idx,
                    .src_idx = inst.src_idx,
                    .len = inst.len,
                });
            },
            .table_init => |inst| {
                writeOps(OpsTableInit, ops_ptr, .{
                    .table_index = inst.table_index,
                    .segment_idx = inst.segment_idx,
                    .dst_idx = inst.dst_idx,
                    .src_offset = inst.src_offset,
                    .len = inst.len,
                });
            },
            .elem_drop => |inst| {
                writeOps(OpsElemDrop, ops_ptr, .{ .segment_idx = inst.segment_idx });
            },

            // ── GC structs ─────────────────────────────────────────────────
            .struct_new => |inst| {
                writeOps(OpsStructNew, ops_ptr, .{
                    .dst = inst.dst,
                    .type_idx = inst.type_idx,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, OpsStructNew, cf.call_args.items, inst.args_start, inst.args_len);
            },
            .struct_new_default => |inst| {
                writeOps(OpsStructNewDefault, ops_ptr, .{
                    .dst = inst.dst,
                    .type_idx = inst.type_idx,
                });
            },
            inline .struct_get, .struct_get_s, .struct_get_u => |inst| {
                writeOps(OpsStructGet, ops_ptr, .{
                    .dst = inst.dst,
                    .ref = inst.ref,
                    .type_idx = inst.type_idx,
                    .field_idx = inst.field_idx,
                });
            },
            .struct_set => |inst| {
                writeOps(OpsStructSet, ops_ptr, .{
                    .ref = inst.ref,
                    .value = inst.value,
                    .type_idx = inst.type_idx,
                    .field_idx = inst.field_idx,
                });
            },

            // ── GC arrays ──────────────────────────────────────────────────
            .array_new => |inst| {
                writeOps(OpsArrayNew, ops_ptr, .{
                    .dst = inst.dst,
                    .init = inst.init,
                    .len = inst.len,
                    .type_idx = inst.type_idx,
                });
            },
            .array_new_default => |inst| {
                writeOps(OpsArrayNewDefault, ops_ptr, .{
                    .dst = inst.dst,
                    .len = inst.len,
                    .type_idx = inst.type_idx,
                });
            },
            .array_new_fixed => |inst| {
                writeOps(OpsArrayNewFixed, ops_ptr, .{
                    .dst = inst.dst,
                    .type_idx = inst.type_idx,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, OpsArrayNewFixed, cf.call_args.items, inst.args_start, inst.args_len);
            },
            .array_new_data => |inst| {
                writeOps(OpsArrayNewData, ops_ptr, .{
                    .dst = inst.dst,
                    .offset = inst.offset,
                    .len = inst.len,
                    .type_idx = inst.type_idx,
                    .data_idx = inst.data_idx,
                });
            },
            .array_new_elem => |inst| {
                writeOps(OpsArrayNewElem, ops_ptr, .{
                    .dst = inst.dst,
                    .offset = inst.offset,
                    .len = inst.len,
                    .type_idx = inst.type_idx,
                    .elem_idx = inst.elem_idx,
                });
            },
            inline .array_get, .array_get_s, .array_get_u => |inst| {
                writeOps(OpsArrayGet, ops_ptr, .{
                    .dst = inst.dst,
                    .ref = inst.ref,
                    .index = inst.index,
                    .type_idx = inst.type_idx,
                });
            },
            .array_set => |inst| {
                writeOps(OpsArraySet, ops_ptr, .{
                    .ref = inst.ref,
                    .index = inst.index,
                    .value = inst.value,
                    .type_idx = inst.type_idx,
                });
            },
            .array_len => |inst| {
                writeOps(OpsArrayLen, ops_ptr, .{
                    .dst = inst.dst,
                    .ref = inst.ref,
                });
            },
            .array_fill => |inst| {
                writeOps(OpsArrayFill, ops_ptr, .{
                    .ref = inst.ref,
                    .offset = inst.offset,
                    .value = inst.value,
                    .n = inst.n,
                    .type_idx = inst.type_idx,
                });
            },
            .array_copy => |inst| {
                writeOps(OpsArrayCopy, ops_ptr, .{
                    .dst_ref = inst.dst_ref,
                    .dst_offset = inst.dst_offset,
                    .src_ref = inst.src_ref,
                    .src_offset = inst.src_offset,
                    .n = inst.n,
                    .dst_type_idx = inst.dst_type_idx,
                    .src_type_idx = inst.src_type_idx,
                });
            },
            .array_init_data => |inst| {
                writeOps(OpsArrayInitData, ops_ptr, .{
                    .ref = inst.ref,
                    .d = inst.d,
                    .s = inst.s,
                    .n = inst.n,
                    .type_idx = inst.type_idx,
                    .data_idx = inst.data_idx,
                });
            },
            .array_init_elem => |inst| {
                writeOps(OpsArrayInitElem, ops_ptr, .{
                    .ref = inst.ref,
                    .d = inst.d,
                    .s = inst.s,
                    .n = inst.n,
                    .type_idx = inst.type_idx,
                    .elem_idx = inst.elem_idx,
                });
            },

            // ── GC i31 ─────────────────────────────────────────────────────
            .ref_i31 => |inst| {
                writeOps(OpsRefI31, ops_ptr, .{ .dst = inst.dst, .value = inst.value });
            },
            inline .i31_get_s, .i31_get_u => |inst| {
                writeOps(OpsI31Get, ops_ptr, .{ .dst = inst.dst, .ref = inst.ref });
            },

            // ── GC ref test/cast ────────────────────────────────────────────
            inline .ref_test, .ref_cast => |inst| {
                writeOps(OpsRefTest, ops_ptr, .{
                    .dst = inst.dst,
                    .ref = inst.ref,
                    .type_idx = inst.type_idx,
                    .nullable = if (inst.nullable) 1 else 0,
                });
            },
            .ref_as_non_null => |inst| {
                writeOps(OpsRefAsNonNull, ops_ptr, .{ .dst = inst.dst, .ref = inst.ref });
            },
            inline .br_on_null, .br_on_non_null => |inst| {
                writeOps(OpsBrOnNull, ops_ptr, .{
                    .ref = inst.ref,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            inline .br_on_cast, .br_on_cast_fail => |inst| {
                writeOps(OpsBrOnCast, ops_ptr, .{
                    .ref = inst.ref,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                    .from_type_idx = inst.from_type_idx,
                    .to_type_idx = inst.to_type_idx,
                    .to_nullable = if (inst.to_nullable) 1 else 0,
                });
            },

            // ── GC extern/any ───────────────────────────────────────────────
            inline .any_convert_extern, .extern_convert_any => |inst| {
                writeOps(OpsConvertRef, ops_ptr, .{ .dst = inst.dst, .ref = inst.ref });
            },

            // ── EH ─────────────────────────────────────────────────────────
            .throw => |inst| {
                writeOps(OpsThrow, ops_ptr, .{
                    .tag_index = inst.tag_index,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, OpsThrow, cf.call_args.items, inst.args_start, inst.args_len);
            },
            .throw_ref => |inst| {
                writeOps(OpsThrowRef, ops_ptr, .{ .ref = inst.ref });
            },
            .try_table_enter => |inst| {
                writeOps(OpsTryTableEnter, ops_ptr, .{
                    .handlers_start = inst.handlers_start,
                    .handlers_len = inst.handlers_len,
                    .end_target = op_offset[inst.end_target],
                });
            },
            .try_table_leave => |inst| {
                writeOps(OpsTryTableLeave, ops_ptr, .{
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },

            // ── Fused: binop-imm (Candidate C) ────────────────────────────
            .i32_add_imm,
            .i32_sub_imm,
            .i32_mul_imm,
            .i32_and_imm,
            .i32_or_imm,
            .i32_xor_imm,
            .i32_shl_imm,
            .i32_shr_s_imm,
            .i32_shr_u_imm,
            .i32_eq_imm,
            .i32_ne_imm,
            .i32_lt_s_imm,
            .i32_lt_u_imm,
            .i32_gt_s_imm,
            .i32_gt_u_imm,
            .i32_le_s_imm,
            .i32_le_u_imm,
            .i32_ge_s_imm,
            .i32_ge_u_imm,
            => |inst| {
                writeOps(OpsBinopImm, ops_ptr, .{
                    .dst = inst.dst,
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                });
            },

            // ── Fused: i64 binop-imm (Candidate C, i64) ───────────────────
            .i64_add_imm,
            .i64_sub_imm,
            .i64_mul_imm,
            .i64_and_imm,
            .i64_or_imm,
            .i64_xor_imm,
            .i64_shl_imm,
            .i64_shr_s_imm,
            .i64_shr_u_imm,
            .i64_eq_imm,
            .i64_ne_imm,
            .i64_lt_s_imm,
            .i64_lt_u_imm,
            .i64_gt_s_imm,
            .i64_gt_u_imm,
            .i64_le_s_imm,
            .i64_le_u_imm,
            .i64_ge_s_imm,
            .i64_ge_u_imm,
            => |inst| {
                writeOps(OpsBinopImm64, ops_ptr, .{
                    .dst = inst.dst,
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                });
            },

            // ── r0 variants: i32 binop-imm-r ──────────────────────────────
            .i32_add_imm_r,
            .i32_sub_imm_r,
            .i32_mul_imm_r,
            .i32_and_imm_r,
            .i32_or_imm_r,
            .i32_xor_imm_r,
            .i32_shl_imm_r,
            .i32_shr_s_imm_r,
            .i32_shr_u_imm_r,
            => |inst| {
                writeOps(OpsBinopImmR0, ops_ptr, .{
                    .dst = inst.dst,
                    .imm = inst.imm,
                });
            },

            // ── r0 variants: i64 binop-imm-r ──────────────────────────────
            .i64_add_imm_r,
            .i64_sub_imm_r,
            .i64_mul_imm_r,
            .i64_and_imm_r,
            .i64_or_imm_r,
            .i64_xor_imm_r,
            .i64_shl_imm_r,
            .i64_shr_s_imm_r,
            .i64_shr_u_imm_r,
            => |inst| {
                writeOps(OpsBinopImmR064, ops_ptr, .{
                    .dst = inst.dst,
                    .imm = inst.imm,
                });
            },

            // ── Fused: compare-jump (Candidate F) ─────────────────────────
            .i32_eq_jump_if_false,
            .i32_ne_jump_if_false,
            .i32_lt_s_jump_if_false,
            .i32_lt_u_jump_if_false,
            .i32_gt_s_jump_if_false,
            .i32_gt_u_jump_if_false,
            .i32_le_s_jump_if_false,
            .i32_le_u_jump_if_false,
            .i32_ge_s_jump_if_false,
            .i32_ge_u_jump_if_false,
            => |inst| {
                writeOps(OpsCompareJump, ops_ptr, .{
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .i32_eqz_jump_if_false => |inst| {
                writeOps(OpsEqzJump, ops_ptr, .{
                    .src = inst.src,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },

            // ── Fused: i64 compare-jump (Candidate F, i64) ────────────────
            .i64_eq_jump_if_false,
            .i64_ne_jump_if_false,
            .i64_lt_s_jump_if_false,
            .i64_lt_u_jump_if_false,
            .i64_gt_s_jump_if_false,
            .i64_gt_u_jump_if_false,
            .i64_le_s_jump_if_false,
            .i64_le_u_jump_if_false,
            .i64_ge_s_jump_if_false,
            .i64_ge_u_jump_if_false,
            => |inst| {
                writeOps(OpsCompareJump, ops_ptr, .{
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .i64_eqz_jump_if_false => |inst| {
                writeOps(OpsEqzJump, ops_ptr, .{
                    .src = inst.src,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },

            // ── Fused: compare-jump-if-true (Peephole J) ──────────────────
            .i32_eq_jump_if_true,
            .i32_ne_jump_if_true,
            .i32_lt_s_jump_if_true,
            .i32_lt_u_jump_if_true,
            .i32_gt_s_jump_if_true,
            .i32_gt_u_jump_if_true,
            .i32_le_s_jump_if_true,
            .i32_le_u_jump_if_true,
            .i32_ge_s_jump_if_true,
            .i32_ge_u_jump_if_true,
            => |inst| {
                writeOps(OpsCompareJump, ops_ptr, .{
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .i32_eqz_jump_if_true => |inst| {
                writeOps(OpsEqzJump, ops_ptr, .{
                    .src = inst.src,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .i64_eq_jump_if_true,
            .i64_ne_jump_if_true,
            .i64_lt_s_jump_if_true,
            .i64_lt_u_jump_if_true,
            .i64_gt_s_jump_if_true,
            .i64_gt_u_jump_if_true,
            .i64_le_s_jump_if_true,
            .i64_le_u_jump_if_true,
            .i64_ge_s_jump_if_true,
            .i64_ge_u_jump_if_true,
            => |inst| {
                writeOps(OpsCompareJump, ops_ptr, .{
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .i64_eqz_jump_if_true => |inst| {
                writeOps(OpsEqzJump, ops_ptr, .{
                    .src = inst.src,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },

            // ── Fused: binop-to-local (Candidate D) ───────────────────────
            .i32_add_to_local,
            .i32_sub_to_local,
            .i32_mul_to_local,
            .i32_and_to_local,
            .i32_or_to_local,
            .i32_xor_to_local,
            .i32_shl_to_local,
            .i32_shr_s_to_local,
            .i32_shr_u_to_local,
            => |inst| {
                writeOps(OpsBinopToLocal, ops_ptr, .{
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },

            // ── Fused: i64 binop-to-local (Candidate D, i64) ──────────────
            .i64_add_to_local,
            .i64_sub_to_local,
            .i64_mul_to_local,
            .i64_and_to_local,
            .i64_or_to_local,
            .i64_xor_to_local,
            .i64_shl_to_local,
            .i64_shr_s_to_local,
            .i64_shr_u_to_local,
            => |inst| {
                writeOps(OpsBinopToLocal, ops_ptr, .{
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },

            // ── Fused: binop + local_tee (i32) ───────────────────────
            .i32_add_tee_local,
            .i32_sub_tee_local,
            .i32_mul_tee_local,
            .i32_and_tee_local,
            .i32_or_tee_local,
            .i32_xor_tee_local,
            .i32_shl_tee_local,
            .i32_shr_s_tee_local,
            .i32_shr_u_tee_local,
            => |inst| {
                writeOps(OpsBinopTeeLocal, ops_ptr, .{
                    .dst = inst.dst,
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },

            // ── Fused: binop + local_tee (i64) ───────────────────────
            .i64_add_tee_local,
            .i64_sub_tee_local,
            .i64_mul_tee_local,
            .i64_and_tee_local,
            .i64_or_tee_local,
            .i64_xor_tee_local,
            .i64_shl_tee_local,
            .i64_shr_s_tee_local,
            .i64_shr_u_tee_local,
            => |inst| {
                writeOps(OpsBinopTeeLocal, ops_ptr, .{
                    .dst = inst.dst,
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },

            // ── Fused: comparison + local_set (cmp_to_local) ──────────────
            .i32_eq_to_local,
            .i32_ne_to_local,
            .i32_lt_s_to_local,
            .i32_lt_u_to_local,
            .i32_gt_s_to_local,
            .i32_gt_u_to_local,
            .i32_le_s_to_local,
            .i32_le_u_to_local,
            .i32_ge_s_to_local,
            .i32_ge_u_to_local,
            => |inst| {
                writeOps(OpsCmpToLocal, ops_ptr, .{
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },

            .i64_eq_to_local,
            .i64_ne_to_local,
            .i64_lt_s_to_local,
            .i64_lt_u_to_local,
            .i64_gt_s_to_local,
            .i64_gt_u_to_local,
            .i64_le_s_to_local,
            .i64_le_u_to_local,
            .i64_ge_s_to_local,
            .i64_ge_u_to_local,
            => |inst| {
                writeOps(OpsCmpToLocal, ops_ptr, .{
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },

            // ── Fused: binop-imm-to-local (Candidate E, i32) ──────────────
            .i32_add_imm_to_local,
            .i32_sub_imm_to_local,
            .i32_mul_imm_to_local,
            .i32_and_imm_to_local,
            .i32_or_imm_to_local,
            .i32_xor_imm_to_local,
            .i32_shl_imm_to_local,
            .i32_shr_s_imm_to_local,
            .i32_shr_u_imm_to_local,
            => |inst| {
                writeOps(OpsBinopImmToLocal, ops_ptr, .{
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                });
            },

            // ── Fused: binop-imm-to-local (Candidate E, i64) ──────────────
            .i64_add_imm_to_local,
            .i64_sub_imm_to_local,
            .i64_mul_imm_to_local,
            .i64_and_imm_to_local,
            .i64_or_imm_to_local,
            .i64_xor_imm_to_local,
            .i64_shl_imm_to_local,
            .i64_shr_s_imm_to_local,
            .i64_shr_u_imm_to_local,
            => |inst| {
                writeOps(OpsBinopImmToLocal64, ops_ptr, .{
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                });
            },

            // ── Fused: local-inplace (Candidate H, i32) ────────────────────
            .i32_add_local_inplace,
            .i32_sub_local_inplace,
            .i32_mul_local_inplace,
            .i32_and_local_inplace,
            .i32_or_local_inplace,
            .i32_xor_local_inplace,
            .i32_shl_local_inplace,
            .i32_shr_s_local_inplace,
            .i32_shr_u_local_inplace,
            => |inst| {
                writeOps(OpsLocalInplace, ops_ptr, .{
                    .local = inst.local,
                    .imm = inst.imm,
                });
            },

            // ── Fused: local-inplace (Candidate H, i64) ────────────────────
            .i64_add_local_inplace,
            .i64_sub_local_inplace,
            .i64_mul_local_inplace,
            .i64_and_local_inplace,
            .i64_or_local_inplace,
            .i64_xor_local_inplace,
            .i64_shl_local_inplace,
            .i64_shr_s_local_inplace,
            .i64_shr_u_local_inplace,
            => |inst| {
                writeOps(OpsLocalInplace64, ops_ptr, .{
                    .local = inst.local,
                    .imm = inst.imm,
                });
            },

            // ── Fused: const-to-local ───────────────────────────────────────
            .i32_const_to_local,
            => |inst| {
                writeOps(OpsConstToLocal32, ops_ptr, .{
                    .local = inst.local,
                    .value = inst.value,
                });
            },

            .i64_const_to_local,
            => |inst| {
                writeOps(OpsConstToLocal64, ops_ptr, .{
                    .local = inst.local,
                    .value = inst.value,
                });
            },

            // ── Superinstruction: imm + local_set → imm_to_local ───────────────
            .i32_imm_to_local,
            => |inst| {
                writeOps(OpsImm32ToLocal, ops_ptr, .{
                    .local = inst.local,
                    .src = inst.src,
                    .imm = inst.imm,
                });
            },

            .i64_imm_to_local,
            => |inst| {
                writeOps(OpsImm64ToLocal, ops_ptr, .{
                    .local = inst.local,
                    .src = inst.src,
                    .imm = inst.imm,
                });
            },

            // ── Fused: global_get-to-local ────────────────────────────────────
            .global_get_to_local,
            => |inst| {
                writeOps(OpsGlobalGetToLocal, ops_ptr, .{
                    .local = inst.local,
                    .global_idx = inst.global_idx,
                });
            },

            // ── Fused: load-to-local ─────────────────────────────────────────
            .i32_load_to_local,
            => |inst| {
                writeOps(OpsLoadToLocal, ops_ptr, .{
                    .local = inst.local,
                    .addr = inst.addr,
                    .offset = inst.offset,
                });
            },

            .i64_load_to_local,
            => |inst| {
                writeOps(OpsLoadToLocal, ops_ptr, .{
                    .local = inst.local,
                    .addr = inst.addr,
                    .offset = inst.offset,
                });
            },

            // ── Fused: compare-imm-jump (Candidate G, i32) ─────────────────
            .i32_eq_imm_jump_if_false,
            .i32_ne_imm_jump_if_false,
            .i32_lt_s_imm_jump_if_false,
            .i32_lt_u_imm_jump_if_false,
            .i32_gt_s_imm_jump_if_false,
            .i32_gt_u_imm_jump_if_false,
            .i32_le_s_imm_jump_if_false,
            .i32_le_u_imm_jump_if_false,
            .i32_ge_s_imm_jump_if_false,
            .i32_ge_u_imm_jump_if_false,
            => |inst| {
                writeOps(OpsCompareImmJump, ops_ptr, .{
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },

            // ── Fused: compare-imm-jump (Candidate G, i64) ─────────────────
            .i64_eq_imm_jump_if_false,
            .i64_ne_imm_jump_if_false,
            .i64_lt_s_imm_jump_if_false,
            .i64_lt_u_imm_jump_if_false,
            .i64_gt_s_imm_jump_if_false,
            .i64_gt_u_imm_jump_if_false,
            .i64_le_s_imm_jump_if_false,
            .i64_le_u_imm_jump_if_false,
            .i64_ge_s_imm_jump_if_false,
            .i64_ge_u_imm_jump_if_false,
            => |inst| {
                writeOps(OpsCompareImmJump64, ops_ptr, .{
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },

            // ── Fused: compare-imm-jump, true-branch (J-imm, i32) ──────────
            .i32_eq_imm_jump_if_true,
            .i32_ne_imm_jump_if_true,
            .i32_lt_s_imm_jump_if_true,
            .i32_lt_u_imm_jump_if_true,
            .i32_gt_s_imm_jump_if_true,
            .i32_gt_u_imm_jump_if_true,
            .i32_le_s_imm_jump_if_true,
            .i32_le_u_imm_jump_if_true,
            .i32_ge_s_imm_jump_if_true,
            .i32_ge_u_imm_jump_if_true,
            => |inst| {
                writeOps(OpsCompareImmJump, ops_ptr, .{
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },

            // ── Fused: compare-imm-jump, true-branch (J-imm, i64) ──────────
            .i64_eq_imm_jump_if_true,
            .i64_ne_imm_jump_if_true,
            .i64_lt_s_imm_jump_if_true,
            .i64_lt_u_imm_jump_if_true,
            .i64_gt_s_imm_jump_if_true,
            .i64_gt_u_imm_jump_if_true,
            .i64_le_s_imm_jump_if_true,
            .i64_le_u_imm_jump_if_true,
            .i64_ge_s_imm_jump_if_true,
            .i64_ge_u_imm_jump_if_true,
            => |inst| {
                writeOps(OpsCompareImmJump64, ops_ptr, .{
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },

            // ── SIMD ───────────────────────────────────────────────────────
            .simd_unary => |inst| {
                writeOps(OpsSimdUnary, ops_ptr, .{
                    .dst = inst.dst,
                    .opcode = @intFromEnum(inst.opcode),
                    .src = inst.src,
                });
            },
            .simd_binary => |inst| {
                writeOps(OpsSimdBinary, ops_ptr, .{
                    .dst = inst.dst,
                    .opcode = @intFromEnum(inst.opcode),
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },
            .simd_ternary => |inst| {
                writeOps(OpsSimdTernary, ops_ptr, .{
                    .dst = inst.dst,
                    .opcode = @intFromEnum(inst.opcode),
                    .first = inst.first,
                    .second = inst.second,
                    .third = inst.third,
                });
            },
            .simd_compare => |inst| {
                writeOps(OpsSimdUnary, ops_ptr, .{
                    .dst = inst.dst,
                    .opcode = @intFromEnum(inst.opcode),
                    .src = inst.lhs,
                });
            },
            .simd_shift_scalar => |inst| {
                writeOps(OpsSimdBinary, ops_ptr, .{
                    .dst = inst.dst,
                    .opcode = @intFromEnum(inst.opcode),
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },
            .simd_extract_lane => |inst| {
                writeOps(OpsSimdExtractLane, ops_ptr, .{
                    .dst = inst.dst,
                    .opcode = @intFromEnum(inst.opcode),
                    .src = inst.src,
                    .lane = inst.lane,
                });
            },
            .simd_replace_lane => |inst| {
                writeOps(OpsSimdReplaceLane, ops_ptr, .{
                    .dst = inst.dst,
                    .opcode = @intFromEnum(inst.opcode),
                    .src_vec = inst.src_vec,
                    .src_lane = inst.src_lane,
                    .lane = inst.lane,
                });
            },
            .simd_shuffle => |inst| {
                writeOps(OpsSimdShuffle, ops_ptr, .{
                    .dst = inst.dst,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                    .lanes = inst.lanes,
                });
            },
            .simd_load => |inst| {
                writeOps(OpsSimdLoad, ops_ptr, .{
                    .dst = inst.dst,
                    .opcode = @intFromEnum(inst.opcode),
                    .addr = inst.addr,
                    .offset = inst.offset,
                    .lane_valid = if (inst.lane != null) 1 else 0,
                    .lane = inst.lane orelse 0,
                    .src_vec_valid = if (inst.src_vec != null) 1 else 0,
                    .src_vec = inst.src_vec orelse 0,
                });
            },
            .simd_store => |inst| {
                writeOps(OpsSimdStore, ops_ptr, .{
                    .opcode = @intFromEnum(inst.opcode),
                    .addr = inst.addr,
                    .src = inst.src,
                    .offset = inst.offset,
                    .lane_valid = if (inst.lane != null) 1 else 0,
                    .lane = inst.lane orelse 0,
                });
            },
        }
    }

    // ── Migrate auxiliary tables ───────────────────────────────────────────
    // call_args are now inlined into the bytecode stream for call/throw/struct_new/array_new_fixed.
    // The only remaining use of call_args is CatchHandlerEntry.dst_slots_start/dst_slots_len
    // for exception handler payload destinations. We migrate those into a separate eh_dst_slots table.

    // catch_handler_tables: copy entries, patch .target field, and migrate dst_slots to eh_dst_slots
    const cht_src = cf.catch_handler_tables.items;
    const catch_handler_tables = try allocator.dupe(CatchHandlerEntry, cht_src);
    errdefer allocator.free(catch_handler_tables);

    // Compute total eh_dst_slots needed
    var eh_dst_total: u32 = 0;
    for (cht_src) |e| {
        eh_dst_total += e.dst_slots_len;
    }

    const eh_dst_slots = try allocator.alloc(Slot, eh_dst_total);
    errdefer allocator.free(eh_dst_slots);

    // Copy dst_slots from call_args into eh_dst_slots and update indices
    {
        var eh_off: u32 = 0;
        for (catch_handler_tables) |*e| {
            e.target = op_offset[e.target];
            if (e.dst_slots_len > 0) {
                const src_slots = cf.call_args.items[e.dst_slots_start .. e.dst_slots_start + e.dst_slots_len];
                @memcpy(eh_dst_slots[eh_off .. eh_off + e.dst_slots_len], src_slots);
                e.dst_slots_start = eh_off;
                eh_off += e.dst_slots_len;
            }
        }
    }

    // br_table_targets: convert op-index entries to byte offsets
    const br_targets_src = cf.br_table_targets.items;
    const br_table_targets = try allocator.alloc(u32, br_targets_src.len);
    errdefer allocator.free(br_table_targets);
    for (br_targets_src, 0..) |t, j| {
        br_table_targets[j] = op_offset[t];
    }

    return EncodedFunction{
        .code = code,
        .slots_len = cf.slots_len,
        .locals_count = cf.locals_count,
        .eh_dst_slots = eh_dst_slots,
        .br_table_targets = br_table_targets,
        .catch_handler_tables = catch_handler_tables,
    };
}

// ── Helper: map Op tag → Handler pointer ─────────────────────────────────────

fn handlerFor(op: Op, t: *const HandlerTable) Handler {
    return switch (op) {
        .unreachable_ => t.unreachable_,
        .const_i32 => t.const_i32,
        .const_i64 => t.const_i64,
        .const_f32 => t.const_f32,
        .const_f64 => t.const_f64,
        .const_v128 => t.const_v128,
        .const_ref_null => t.const_ref_null,
        .ref_is_null => t.ref_is_null,
        .ref_func => t.ref_func,
        .ref_eq => t.ref_eq,
        .local_get => t.local_get,
        .local_set => t.local_set,
        .global_get => t.global_get,
        .global_set => t.global_set,
        .copy => t.copy,
        .copy_jump_if_nz => t.copy_jump_if_nz,
        .jump => t.jump,
        .jump_if_z => t.jump_if_z,
        .jump_if_nz => t.jump_if_nz,
        .jump_table => t.jump_table,
        .select => t.select,
        .ret => t.ret,
        .i32_add_ret => t.i32_add_ret,
        .i32_sub_ret => t.i32_sub_ret,
        .i64_add_ret => t.i64_add_ret,
        .i64_sub_ret => t.i64_sub_ret,
        .i32_add => t.i32_add,
        .i32_sub => t.i32_sub,
        .i32_mul => t.i32_mul,
        .i32_div_s => t.i32_div_s,
        .i32_div_u => t.i32_div_u,
        .i32_rem_s => t.i32_rem_s,
        .i32_rem_u => t.i32_rem_u,
        .i32_and => t.i32_and,
        .i32_or => t.i32_or,
        .i32_xor => t.i32_xor,
        .i32_shl => t.i32_shl,
        .i32_shr_s => t.i32_shr_s,
        .i32_shr_u => t.i32_shr_u,
        .i32_rotl => t.i32_rotl,
        .i32_rotr => t.i32_rotr,
        .i64_add => t.i64_add,
        .i64_sub => t.i64_sub,
        .i64_mul => t.i64_mul,
        .i64_div_s => t.i64_div_s,
        .i64_div_u => t.i64_div_u,
        .i64_rem_s => t.i64_rem_s,
        .i64_rem_u => t.i64_rem_u,
        .i64_and => t.i64_and,
        .i64_or => t.i64_or,
        .i64_xor => t.i64_xor,
        .i64_shl => t.i64_shl,
        .i64_shr_s => t.i64_shr_s,
        .i64_shr_u => t.i64_shr_u,
        .i64_rotl => t.i64_rotl,
        .i64_rotr => t.i64_rotr,
        .f32_add => t.f32_add,
        .f32_sub => t.f32_sub,
        .f32_mul => t.f32_mul,
        .f32_div => t.f32_div,
        .f32_min => t.f32_min,
        .f32_max => t.f32_max,
        .f32_copysign => t.f32_copysign,
        .f64_add => t.f64_add,
        .f64_sub => t.f64_sub,
        .f64_mul => t.f64_mul,
        .f64_div => t.f64_div,
        .f64_min => t.f64_min,
        .f64_max => t.f64_max,
        .f64_copysign => t.f64_copysign,
        .i32_clz => t.i32_clz,
        .i32_ctz => t.i32_ctz,
        .i32_popcnt => t.i32_popcnt,
        .i32_eqz => t.i32_eqz,
        .i64_clz => t.i64_clz,
        .i64_ctz => t.i64_ctz,
        .i64_popcnt => t.i64_popcnt,
        .i64_eqz => t.i64_eqz,
        .f32_abs => t.f32_abs,
        .f32_neg => t.f32_neg,
        .f32_ceil => t.f32_ceil,
        .f32_floor => t.f32_floor,
        .f32_trunc => t.f32_trunc,
        .f32_nearest => t.f32_nearest,
        .f32_sqrt => t.f32_sqrt,
        .f64_abs => t.f64_abs,
        .f64_neg => t.f64_neg,
        .f64_ceil => t.f64_ceil,
        .f64_floor => t.f64_floor,
        .f64_trunc => t.f64_trunc,
        .f64_nearest => t.f64_nearest,
        .f64_sqrt => t.f64_sqrt,
        .i32_eq => t.i32_eq,
        .i32_ne => t.i32_ne,
        .i32_lt_s => t.i32_lt_s,
        .i32_lt_u => t.i32_lt_u,
        .i32_gt_s => t.i32_gt_s,
        .i32_gt_u => t.i32_gt_u,
        .i32_le_s => t.i32_le_s,
        .i32_le_u => t.i32_le_u,
        .i32_ge_s => t.i32_ge_s,
        .i32_ge_u => t.i32_ge_u,
        .i64_eq => t.i64_eq,
        .i64_ne => t.i64_ne,
        .i64_lt_s => t.i64_lt_s,
        .i64_lt_u => t.i64_lt_u,
        .i64_gt_s => t.i64_gt_s,
        .i64_gt_u => t.i64_gt_u,
        .i64_le_s => t.i64_le_s,
        .i64_le_u => t.i64_le_u,
        .i64_ge_s => t.i64_ge_s,
        .i64_ge_u => t.i64_ge_u,
        .f32_eq => t.f32_eq,
        .f32_ne => t.f32_ne,
        .f32_lt => t.f32_lt,
        .f32_gt => t.f32_gt,
        .f32_le => t.f32_le,
        .f32_ge => t.f32_ge,
        .f64_eq => t.f64_eq,
        .f64_ne => t.f64_ne,
        .f64_lt => t.f64_lt,
        .f64_gt => t.f64_gt,
        .f64_le => t.f64_le,
        .f64_ge => t.f64_ge,
        .i32_wrap_i64 => t.i32_wrap_i64,
        .i32_trunc_f32_s => t.i32_trunc_f32_s,
        .i32_trunc_f32_u => t.i32_trunc_f32_u,
        .i32_trunc_f64_s => t.i32_trunc_f64_s,
        .i32_trunc_f64_u => t.i32_trunc_f64_u,
        .i64_extend_i32_s => t.i64_extend_i32_s,
        .i64_extend_i32_u => t.i64_extend_i32_u,
        .i64_trunc_f32_s => t.i64_trunc_f32_s,
        .i64_trunc_f32_u => t.i64_trunc_f32_u,
        .i64_trunc_f64_s => t.i64_trunc_f64_s,
        .i64_trunc_f64_u => t.i64_trunc_f64_u,
        .i32_trunc_sat_f32_s => t.i32_trunc_sat_f32_s,
        .i32_trunc_sat_f32_u => t.i32_trunc_sat_f32_u,
        .i32_trunc_sat_f64_s => t.i32_trunc_sat_f64_s,
        .i32_trunc_sat_f64_u => t.i32_trunc_sat_f64_u,
        .i64_trunc_sat_f32_s => t.i64_trunc_sat_f32_s,
        .i64_trunc_sat_f32_u => t.i64_trunc_sat_f32_u,
        .i64_trunc_sat_f64_s => t.i64_trunc_sat_f64_s,
        .i64_trunc_sat_f64_u => t.i64_trunc_sat_f64_u,
        .f32_convert_i32_s => t.f32_convert_i32_s,
        .f32_convert_i32_u => t.f32_convert_i32_u,
        .f32_convert_i64_s => t.f32_convert_i64_s,
        .f32_convert_i64_u => t.f32_convert_i64_u,
        .f32_demote_f64 => t.f32_demote_f64,
        .f64_promote_f32 => t.f64_promote_f32,
        .f64_convert_i32_s => t.f64_convert_i32_s,
        .f64_convert_i32_u => t.f64_convert_i32_u,
        .f64_convert_i64_s => t.f64_convert_i64_s,
        .f64_convert_i64_u => t.f64_convert_i64_u,
        .i32_reinterpret_f32 => t.i32_reinterpret_f32,
        .i64_reinterpret_f64 => t.i64_reinterpret_f64,
        .f32_reinterpret_i32 => t.f32_reinterpret_i32,
        .f64_reinterpret_i64 => t.f64_reinterpret_i64,
        .i32_extend8_s => t.i32_extend8_s,
        .i32_extend16_s => t.i32_extend16_s,
        .i64_extend8_s => t.i64_extend8_s,
        .i64_extend16_s => t.i64_extend16_s,
        .i64_extend32_s => t.i64_extend32_s,
        .i32_load => t.i32_load,
        .i32_load8_s => t.i32_load8_s,
        .i32_load8_u => t.i32_load8_u,
        .i32_load16_s => t.i32_load16_s,
        .i32_load16_u => t.i32_load16_u,
        .i64_load => t.i64_load,
        .i64_load8_s => t.i64_load8_s,
        .i64_load8_u => t.i64_load8_u,
        .i64_load16_s => t.i64_load16_s,
        .i64_load16_u => t.i64_load16_u,
        .i64_load32_s => t.i64_load32_s,
        .i64_load32_u => t.i64_load32_u,
        .f32_load => t.f32_load,
        .f64_load => t.f64_load,
        .i32_store => t.i32_store,
        .i32_store8 => t.i32_store8,
        .i32_store16 => t.i32_store16,
        .i64_store => t.i64_store,
        .i64_store8 => t.i64_store8,
        .i64_store16 => t.i64_store16,
        .i64_store32 => t.i64_store32,
        .f32_store => t.f32_store,
        .f64_store => t.f64_store,
        .memory_size => t.memory_size,
        .memory_grow => t.memory_grow,
        .memory_init => t.memory_init,
        .data_drop => t.data_drop,
        .memory_copy => t.memory_copy,
        .memory_fill => t.memory_fill,
        .call => t.call,
        .call_indirect => t.call_indirect,
        .return_call => t.return_call,
        .return_call_indirect => t.return_call_indirect,
        .call_ref => t.call_ref,
        .return_call_ref => t.return_call_ref,
        .atomic_load => t.atomic_load,
        .atomic_store => t.atomic_store,
        .atomic_rmw => t.atomic_rmw,
        .atomic_cmpxchg => t.atomic_cmpxchg,
        .atomic_fence => t.atomic_fence,
        .atomic_notify => t.atomic_notify,
        .atomic_wait32 => t.atomic_wait32,
        .atomic_wait64 => t.atomic_wait64,
        .table_get => t.table_get,
        .table_set => t.table_set,
        .table_size => t.table_size,
        .table_grow => t.table_grow,
        .table_fill => t.table_fill,
        .table_copy => t.table_copy,
        .table_init => t.table_init,
        .elem_drop => t.elem_drop,
        .struct_new => t.struct_new,
        .struct_new_default => t.struct_new_default,
        .struct_get => t.struct_get,
        .struct_get_s => t.struct_get_s,
        .struct_get_u => t.struct_get_u,
        .struct_set => t.struct_set,
        .array_new => t.array_new,
        .array_new_default => t.array_new_default,
        .array_new_fixed => t.array_new_fixed,
        .array_new_data => t.array_new_data,
        .array_new_elem => t.array_new_elem,
        .array_get => t.array_get,
        .array_get_s => t.array_get_s,
        .array_get_u => t.array_get_u,
        .array_set => t.array_set,
        .array_len => t.array_len,
        .array_fill => t.array_fill,
        .array_copy => t.array_copy,
        .array_init_data => t.array_init_data,
        .array_init_elem => t.array_init_elem,
        .ref_i31 => t.ref_i31,
        .i31_get_s => t.i31_get_s,
        .i31_get_u => t.i31_get_u,
        .ref_test => t.ref_test,
        .ref_cast => t.ref_cast,
        .ref_as_non_null => t.ref_as_non_null,
        .br_on_null => t.br_on_null,
        .br_on_non_null => t.br_on_non_null,
        .br_on_cast => t.br_on_cast,
        .br_on_cast_fail => t.br_on_cast_fail,
        .any_convert_extern => t.any_convert_extern,
        .extern_convert_any => t.extern_convert_any,
        .throw => t.throw,
        .throw_ref => t.throw_ref,
        .try_table_enter => t.try_table_enter,
        .try_table_leave => t.try_table_leave,
        .simd_unary => t.simd_unary,
        .simd_binary => t.simd_binary,
        .simd_ternary => t.simd_ternary,
        .simd_compare => t.simd_compare,
        .simd_shift_scalar => t.simd_shift_scalar,
        .simd_extract_lane => t.simd_extract_lane,
        .simd_replace_lane => t.simd_replace_lane,
        .simd_shuffle => t.simd_shuffle,
        .simd_load => t.simd_load,
        .simd_store => t.simd_store,
        // fused binop-imm (C)
        .i32_add_imm => t.i32_add_imm,
        .i32_sub_imm => t.i32_sub_imm,
        .i32_mul_imm => t.i32_mul_imm,
        .i32_and_imm => t.i32_and_imm,
        .i32_or_imm => t.i32_or_imm,
        .i32_xor_imm => t.i32_xor_imm,
        .i32_shl_imm => t.i32_shl_imm,
        .i32_shr_s_imm => t.i32_shr_s_imm,
        .i32_shr_u_imm => t.i32_shr_u_imm,
        .i32_eq_imm => t.i32_eq_imm,
        .i32_ne_imm => t.i32_ne_imm,
        .i32_lt_s_imm => t.i32_lt_s_imm,
        .i32_lt_u_imm => t.i32_lt_u_imm,
        .i32_gt_s_imm => t.i32_gt_s_imm,
        .i32_gt_u_imm => t.i32_gt_u_imm,
        .i32_le_s_imm => t.i32_le_s_imm,
        .i32_le_u_imm => t.i32_le_u_imm,
        .i32_ge_s_imm => t.i32_ge_s_imm,
        .i32_ge_u_imm => t.i32_ge_u_imm,
        // fused i64 binop-imm (C, i64)
        .i64_add_imm => t.i64_add_imm,
        .i64_sub_imm => t.i64_sub_imm,
        .i64_mul_imm => t.i64_mul_imm,
        .i64_and_imm => t.i64_and_imm,
        .i64_or_imm => t.i64_or_imm,
        .i64_xor_imm => t.i64_xor_imm,
        .i64_shl_imm => t.i64_shl_imm,
        .i64_shr_s_imm => t.i64_shr_s_imm,
        .i64_shr_u_imm => t.i64_shr_u_imm,
        .i64_eq_imm => t.i64_eq_imm,
        .i64_ne_imm => t.i64_ne_imm,
        .i64_lt_s_imm => t.i64_lt_s_imm,
        .i64_lt_u_imm => t.i64_lt_u_imm,
        .i64_gt_s_imm => t.i64_gt_s_imm,
        .i64_gt_u_imm => t.i64_gt_u_imm,
        .i64_le_s_imm => t.i64_le_s_imm,
        .i64_le_u_imm => t.i64_le_u_imm,
        .i64_ge_s_imm => t.i64_ge_s_imm,
        .i64_ge_u_imm => t.i64_ge_u_imm,
        // r0 variants: i32 binop-imm-r
        .i32_add_imm_r => t.i32_add_imm_r,
        .i32_sub_imm_r => t.i32_sub_imm_r,
        .i32_mul_imm_r => t.i32_mul_imm_r,
        .i32_and_imm_r => t.i32_and_imm_r,
        .i32_or_imm_r => t.i32_or_imm_r,
        .i32_xor_imm_r => t.i32_xor_imm_r,
        .i32_shl_imm_r => t.i32_shl_imm_r,
        .i32_shr_s_imm_r => t.i32_shr_s_imm_r,
        .i32_shr_u_imm_r => t.i32_shr_u_imm_r,
        // r0 variants: i64 binop-imm-r
        .i64_add_imm_r => t.i64_add_imm_r,
        .i64_sub_imm_r => t.i64_sub_imm_r,
        .i64_mul_imm_r => t.i64_mul_imm_r,
        .i64_and_imm_r => t.i64_and_imm_r,
        .i64_or_imm_r => t.i64_or_imm_r,
        .i64_xor_imm_r => t.i64_xor_imm_r,
        .i64_shl_imm_r => t.i64_shl_imm_r,
        .i64_shr_s_imm_r => t.i64_shr_s_imm_r,
        .i64_shr_u_imm_r => t.i64_shr_u_imm_r,
        // fused compare-jump (F)
        .i32_eq_jump_if_false => t.i32_eq_jump_if_false,
        .i32_ne_jump_if_false => t.i32_ne_jump_if_false,
        .i32_lt_s_jump_if_false => t.i32_lt_s_jump_if_false,
        .i32_lt_u_jump_if_false => t.i32_lt_u_jump_if_false,
        .i32_gt_s_jump_if_false => t.i32_gt_s_jump_if_false,
        .i32_gt_u_jump_if_false => t.i32_gt_u_jump_if_false,
        .i32_le_s_jump_if_false => t.i32_le_s_jump_if_false,
        .i32_le_u_jump_if_false => t.i32_le_u_jump_if_false,
        .i32_ge_s_jump_if_false => t.i32_ge_s_jump_if_false,
        .i32_ge_u_jump_if_false => t.i32_ge_u_jump_if_false,
        .i32_eqz_jump_if_false => t.i32_eqz_jump_if_false,
        // fused i64 compare-jump (F, i64)
        .i64_eq_jump_if_false => t.i64_eq_jump_if_false,
        .i64_ne_jump_if_false => t.i64_ne_jump_if_false,
        .i64_lt_s_jump_if_false => t.i64_lt_s_jump_if_false,
        .i64_lt_u_jump_if_false => t.i64_lt_u_jump_if_false,
        .i64_gt_s_jump_if_false => t.i64_gt_s_jump_if_false,
        .i64_gt_u_jump_if_false => t.i64_gt_u_jump_if_false,
        .i64_le_s_jump_if_false => t.i64_le_s_jump_if_false,
        .i64_le_u_jump_if_false => t.i64_le_u_jump_if_false,
        .i64_ge_s_jump_if_false => t.i64_ge_s_jump_if_false,
        .i64_ge_u_jump_if_false => t.i64_ge_u_jump_if_false,
        .i64_eqz_jump_if_false => t.i64_eqz_jump_if_false,
        // fused compare-jump-if-true (Peephole J)
        .i32_eq_jump_if_true => t.i32_eq_jump_if_true,
        .i32_ne_jump_if_true => t.i32_ne_jump_if_true,
        .i32_lt_s_jump_if_true => t.i32_lt_s_jump_if_true,
        .i32_lt_u_jump_if_true => t.i32_lt_u_jump_if_true,
        .i32_gt_s_jump_if_true => t.i32_gt_s_jump_if_true,
        .i32_gt_u_jump_if_true => t.i32_gt_u_jump_if_true,
        .i32_le_s_jump_if_true => t.i32_le_s_jump_if_true,
        .i32_le_u_jump_if_true => t.i32_le_u_jump_if_true,
        .i32_ge_s_jump_if_true => t.i32_ge_s_jump_if_true,
        .i32_ge_u_jump_if_true => t.i32_ge_u_jump_if_true,
        .i32_eqz_jump_if_true => t.i32_eqz_jump_if_true,
        .i64_eq_jump_if_true => t.i64_eq_jump_if_true,
        .i64_ne_jump_if_true => t.i64_ne_jump_if_true,
        .i64_lt_s_jump_if_true => t.i64_lt_s_jump_if_true,
        .i64_lt_u_jump_if_true => t.i64_lt_u_jump_if_true,
        .i64_gt_s_jump_if_true => t.i64_gt_s_jump_if_true,
        .i64_gt_u_jump_if_true => t.i64_gt_u_jump_if_true,
        .i64_le_s_jump_if_true => t.i64_le_s_jump_if_true,
        .i64_le_u_jump_if_true => t.i64_le_u_jump_if_true,
        .i64_ge_s_jump_if_true => t.i64_ge_s_jump_if_true,
        .i64_ge_u_jump_if_true => t.i64_ge_u_jump_if_true,
        .i64_eqz_jump_if_true => t.i64_eqz_jump_if_true,
        // fused binop-to-local (D)
        .i32_add_to_local => t.i32_add_to_local,
        .i32_sub_to_local => t.i32_sub_to_local,
        .i32_mul_to_local => t.i32_mul_to_local,
        .i32_and_to_local => t.i32_and_to_local,
        .i32_or_to_local => t.i32_or_to_local,
        .i32_xor_to_local => t.i32_xor_to_local,
        .i32_shl_to_local => t.i32_shl_to_local,
        .i32_shr_s_to_local => t.i32_shr_s_to_local,
        .i32_shr_u_to_local => t.i32_shr_u_to_local,
        // fused i64 binop-to-local (D, i64)
        .i64_add_to_local => t.i64_add_to_local,
        .i64_sub_to_local => t.i64_sub_to_local,
        .i64_mul_to_local => t.i64_mul_to_local,
        .i64_and_to_local => t.i64_and_to_local,
        .i64_or_to_local => t.i64_or_to_local,
        .i64_xor_to_local => t.i64_xor_to_local,
        .i64_shl_to_local => t.i64_shl_to_local,
        .i64_shr_s_to_local => t.i64_shr_s_to_local,
        .i64_shr_u_to_local => t.i64_shr_u_to_local,
        // fused binop + local_tee
        .i32_add_tee_local => t.i32_add_tee_local,
        .i32_sub_tee_local => t.i32_sub_tee_local,
        .i32_mul_tee_local => t.i32_mul_tee_local,
        .i32_and_tee_local => t.i32_and_tee_local,
        .i32_or_tee_local => t.i32_or_tee_local,
        .i32_xor_tee_local => t.i32_xor_tee_local,
        .i32_shl_tee_local => t.i32_shl_tee_local,
        .i32_shr_s_tee_local => t.i32_shr_s_tee_local,
        .i32_shr_u_tee_local => t.i32_shr_u_tee_local,
        .i64_add_tee_local => t.i64_add_tee_local,
        .i64_sub_tee_local => t.i64_sub_tee_local,
        .i64_mul_tee_local => t.i64_mul_tee_local,
        .i64_and_tee_local => t.i64_and_tee_local,
        .i64_or_tee_local => t.i64_or_tee_local,
        .i64_xor_tee_local => t.i64_xor_tee_local,
        .i64_shl_tee_local => t.i64_shl_tee_local,
        .i64_shr_s_tee_local => t.i64_shr_s_tee_local,
        .i64_shr_u_tee_local => t.i64_shr_u_tee_local,
        // fused cmp-to-local
        .i32_eq_to_local => t.i32_eq_to_local,
        .i32_ne_to_local => t.i32_ne_to_local,
        .i32_lt_s_to_local => t.i32_lt_s_to_local,
        .i32_lt_u_to_local => t.i32_lt_u_to_local,
        .i32_gt_s_to_local => t.i32_gt_s_to_local,
        .i32_gt_u_to_local => t.i32_gt_u_to_local,
        .i32_le_s_to_local => t.i32_le_s_to_local,
        .i32_le_u_to_local => t.i32_le_u_to_local,
        .i32_ge_s_to_local => t.i32_ge_s_to_local,
        .i32_ge_u_to_local => t.i32_ge_u_to_local,
        .i64_eq_to_local => t.i64_eq_to_local,
        .i64_ne_to_local => t.i64_ne_to_local,
        .i64_lt_s_to_local => t.i64_lt_s_to_local,
        .i64_lt_u_to_local => t.i64_lt_u_to_local,
        .i64_gt_s_to_local => t.i64_gt_s_to_local,
        .i64_gt_u_to_local => t.i64_gt_u_to_local,
        .i64_le_s_to_local => t.i64_le_s_to_local,
        .i64_le_u_to_local => t.i64_le_u_to_local,
        .i64_ge_s_to_local => t.i64_ge_s_to_local,
        .i64_ge_u_to_local => t.i64_ge_u_to_local,
        // fused binop-imm-to-local (E)
        .i32_add_imm_to_local => t.i32_add_imm_to_local,
        .i32_sub_imm_to_local => t.i32_sub_imm_to_local,
        .i32_mul_imm_to_local => t.i32_mul_imm_to_local,
        .i32_and_imm_to_local => t.i32_and_imm_to_local,
        .i32_or_imm_to_local => t.i32_or_imm_to_local,
        .i32_xor_imm_to_local => t.i32_xor_imm_to_local,
        .i32_shl_imm_to_local => t.i32_shl_imm_to_local,
        .i32_shr_s_imm_to_local => t.i32_shr_s_imm_to_local,
        .i32_shr_u_imm_to_local => t.i32_shr_u_imm_to_local,
        .i64_add_imm_to_local => t.i64_add_imm_to_local,
        .i64_sub_imm_to_local => t.i64_sub_imm_to_local,
        .i64_mul_imm_to_local => t.i64_mul_imm_to_local,
        .i64_and_imm_to_local => t.i64_and_imm_to_local,
        .i64_or_imm_to_local => t.i64_or_imm_to_local,
        .i64_xor_imm_to_local => t.i64_xor_imm_to_local,
        .i64_shl_imm_to_local => t.i64_shl_imm_to_local,
        .i64_shr_s_imm_to_local => t.i64_shr_s_imm_to_local,
        .i64_shr_u_imm_to_local => t.i64_shr_u_imm_to_local,
        // fused local-inplace (H)
        .i32_add_local_inplace => t.i32_add_local_inplace,
        .i32_sub_local_inplace => t.i32_sub_local_inplace,
        .i32_mul_local_inplace => t.i32_mul_local_inplace,
        .i32_and_local_inplace => t.i32_and_local_inplace,
        .i32_or_local_inplace => t.i32_or_local_inplace,
        .i32_xor_local_inplace => t.i32_xor_local_inplace,
        .i32_shl_local_inplace => t.i32_shl_local_inplace,
        .i32_shr_s_local_inplace => t.i32_shr_s_local_inplace,
        .i32_shr_u_local_inplace => t.i32_shr_u_local_inplace,
        .i64_add_local_inplace => t.i64_add_local_inplace,
        .i64_sub_local_inplace => t.i64_sub_local_inplace,
        .i64_mul_local_inplace => t.i64_mul_local_inplace,
        .i64_and_local_inplace => t.i64_and_local_inplace,
        .i64_or_local_inplace => t.i64_or_local_inplace,
        .i64_xor_local_inplace => t.i64_xor_local_inplace,
        .i64_shl_local_inplace => t.i64_shl_local_inplace,
        .i64_shr_s_local_inplace => t.i64_shr_s_local_inplace,
        .i64_shr_u_local_inplace => t.i64_shr_u_local_inplace,
        // fused const-to-local
        .i32_const_to_local => t.i32_const_to_local,
        .i64_const_to_local => t.i64_const_to_local,
        // superinstruction: imm + local_set → imm_to_local
        .i32_imm_to_local => t.i32_imm_to_local,
        .i64_imm_to_local => t.i64_imm_to_local,
        // fused global_get-to-local
        .global_get_to_local => t.global_get_to_local,
        // fused load-to-local
        .i32_load_to_local => t.i32_load_to_local,
        .i64_load_to_local => t.i64_load_to_local,
        // fused compare-imm-jump (G)
        .i32_eq_imm_jump_if_false => t.i32_eq_imm_jump_if_false,
        .i32_ne_imm_jump_if_false => t.i32_ne_imm_jump_if_false,
        .i32_lt_s_imm_jump_if_false => t.i32_lt_s_imm_jump_if_false,
        .i32_lt_u_imm_jump_if_false => t.i32_lt_u_imm_jump_if_false,
        .i32_gt_s_imm_jump_if_false => t.i32_gt_s_imm_jump_if_false,
        .i32_gt_u_imm_jump_if_false => t.i32_gt_u_imm_jump_if_false,
        .i32_le_s_imm_jump_if_false => t.i32_le_s_imm_jump_if_false,
        .i32_le_u_imm_jump_if_false => t.i32_le_u_imm_jump_if_false,
        .i32_ge_s_imm_jump_if_false => t.i32_ge_s_imm_jump_if_false,
        .i32_ge_u_imm_jump_if_false => t.i32_ge_u_imm_jump_if_false,
        .i64_eq_imm_jump_if_false => t.i64_eq_imm_jump_if_false,
        .i64_ne_imm_jump_if_false => t.i64_ne_imm_jump_if_false,
        .i64_lt_s_imm_jump_if_false => t.i64_lt_s_imm_jump_if_false,
        .i64_lt_u_imm_jump_if_false => t.i64_lt_u_imm_jump_if_false,
        .i64_gt_s_imm_jump_if_false => t.i64_gt_s_imm_jump_if_false,
        .i64_gt_u_imm_jump_if_false => t.i64_gt_u_imm_jump_if_false,
        .i64_le_s_imm_jump_if_false => t.i64_le_s_imm_jump_if_false,
        .i64_le_u_imm_jump_if_false => t.i64_le_u_imm_jump_if_false,
        .i64_ge_s_imm_jump_if_false => t.i64_ge_s_imm_jump_if_false,
        .i64_ge_u_imm_jump_if_false => t.i64_ge_u_imm_jump_if_false,
        // fused compare-imm-jump, true-branch (J-imm)
        .i32_eq_imm_jump_if_true => t.i32_eq_imm_jump_if_true,
        .i32_ne_imm_jump_if_true => t.i32_ne_imm_jump_if_true,
        .i32_lt_s_imm_jump_if_true => t.i32_lt_s_imm_jump_if_true,
        .i32_lt_u_imm_jump_if_true => t.i32_lt_u_imm_jump_if_true,
        .i32_gt_s_imm_jump_if_true => t.i32_gt_s_imm_jump_if_true,
        .i32_gt_u_imm_jump_if_true => t.i32_gt_u_imm_jump_if_true,
        .i32_le_s_imm_jump_if_true => t.i32_le_s_imm_jump_if_true,
        .i32_le_u_imm_jump_if_true => t.i32_le_u_imm_jump_if_true,
        .i32_ge_s_imm_jump_if_true => t.i32_ge_s_imm_jump_if_true,
        .i32_ge_u_imm_jump_if_true => t.i32_ge_u_imm_jump_if_true,
        .i64_eq_imm_jump_if_true => t.i64_eq_imm_jump_if_true,
        .i64_ne_imm_jump_if_true => t.i64_ne_imm_jump_if_true,
        .i64_lt_s_imm_jump_if_true => t.i64_lt_s_imm_jump_if_true,
        .i64_lt_u_imm_jump_if_true => t.i64_lt_u_imm_jump_if_true,
        .i64_gt_s_imm_jump_if_true => t.i64_gt_s_imm_jump_if_true,
        .i64_gt_u_imm_jump_if_true => t.i64_gt_u_imm_jump_if_true,
        .i64_le_s_imm_jump_if_true => t.i64_le_s_imm_jump_if_true,
        .i64_le_u_imm_jump_if_true => t.i64_le_u_imm_jump_if_true,
        .i64_ge_s_imm_jump_if_true => t.i64_ge_s_imm_jump_if_true,
        .i64_ge_u_imm_jump_if_true => t.i64_ge_u_imm_jump_if_true,
    };
}

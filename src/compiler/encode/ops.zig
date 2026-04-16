const ir = @import("../ir.zig");
const Slot = ir.Slot;

pub const OpsNone = extern struct {};
pub const OpsDst = extern struct { dst: Slot };
pub const OpsDstSrc = extern struct { dst: Slot, src: Slot };
pub const OpsDstLhsRhs = extern struct { dst: Slot, lhs: Slot, rhs: Slot };

pub const OpsConstI32 = extern struct { dst: Slot, _pad: u16 = 0, value: i32 };
pub const OpsConstI64 = extern struct { dst: Slot, _pad: [6]u8 = [_]u8{0} ** 6, value: i64 };
pub const OpsConstF32 = extern struct { dst: Slot, _pad: u16 = 0, value: f32 };
pub const OpsConstF64 = extern struct { dst: Slot, _pad: [6]u8 = [_]u8{0} ** 6, value: f64 };
pub const OpsConstV128 = extern struct { dst: Slot, _pad: [14]u8 = [_]u8{0} ** 14, value: [16]u8 };

pub const OpsLocalGet = extern struct { dst: Slot, local: Slot };
pub const OpsLocalSet = extern struct { local: Slot, src: Slot };
pub const OpsGlobalGet = extern struct { dst: Slot, _pad: u16 = 0, global_idx: u32 };
pub const OpsGlobalSet = extern struct { src: Slot, _pad: u16 = 0, global_idx: u32 };
pub const OpsCopy = extern struct { dst: Slot, src: Slot };
pub const OpsCopyJumpIfNz = extern struct { dst: Slot, src: Slot, cond: Slot, _pad: u16 = 0, rel_target: i32 };
pub const OpsJump = extern struct { rel_target: i32 };
pub const OpsJumpIfZ = extern struct { cond: Slot, _pad: u16 = 0, rel_target: i32 };

pub const OpsBinopImm = extern struct { dst: Slot, lhs: Slot, imm: i32 };
pub const OpsBinopImm64 = extern struct { dst: Slot, lhs: Slot, _pad: u32 = 0, imm: i64 };
pub const OpsBinopImmR0 = extern struct { dst: Slot, _pad: u16 = 0, imm: i32 };
pub const OpsBinopImmR064 = extern struct { dst: Slot, _pad: [6]u8 = [_]u8{0} ** 6, imm: i64 };

pub const OpsCompareJump = extern struct { lhs: Slot, rhs: Slot, rel_target: i32 };
pub const OpsEqzJump = extern struct { src: Slot, _pad: u16 = 0, rel_target: i32 };
pub const OpsBinopToLocal = extern struct { local: Slot, lhs: Slot, rhs: Slot };
pub const OpsBinopTeeLocal = extern struct { dst: Slot, local: Slot, lhs: Slot, rhs: Slot };
pub const OpsCmpToLocal = extern struct { local: Slot, lhs: Slot, rhs: Slot };
pub const OpsBinopImmToLocal = extern struct { local: Slot, lhs: Slot, imm: i32 };
pub const OpsBinopImmToLocal64 = extern struct { local: Slot, lhs: Slot, _pad: u32 = 0, imm: i64 };
pub const OpsLocalInplace = extern struct { local: Slot, _pad: u16 = 0, imm: i32 };
pub const OpsLocalInplace64 = extern struct { local: Slot, _pad: [6]u8 = [_]u8{0} ** 6, imm: i64 };
pub const OpsConstToLocal32 = extern struct { local: Slot, _pad: u16 = 0, value: i32 };
pub const OpsConstToLocal64 = extern struct { local: Slot, _pad: [6]u8 = [_]u8{0} ** 6, value: i64 };
pub const OpsImm32ToLocal = extern struct { local: Slot, src: Slot, imm: i32 };
pub const OpsImm64ToLocal = extern struct { local: Slot, src: Slot, _pad: [6]u8 = [_]u8{0} ** 6, imm: i64 };
pub const OpsGlobalGetToLocal = extern struct { local: Slot, _pad: u16 = 0, global_idx: u32 };
pub const OpsLoadToLocal = extern struct { local: Slot, addr: Slot, offset: u32 };
pub const OpsCompareImmJump = extern struct { lhs: Slot, _pad: u16 = 0, imm: i32, rel_target: i32 };
pub const OpsCompareImmJump64 = extern struct { lhs: Slot, _pad: [6]u8 = [_]u8{0} ** 6, imm: i64, rel_target: i32, _pad2: u32 = 0 };

pub const OpsJumpTable = extern struct { index: Slot, _pad: u16 = 0, targets_start: u32, targets_len: u32 };
pub const OpsSelect = extern struct { dst: Slot, val1: Slot, val2: Slot, cond: Slot };
pub const OpsRet = extern struct {
    has_value: u16,
    value: Slot,
};
pub const OpsLhsRhs = extern struct { lhs: Slot, rhs: Slot };
pub const OpsRefFunc = extern struct { dst: Slot, _pad: u16 = 0, func_idx: u32 };
pub const OpsRefTest = extern struct { dst: Slot, ref: Slot, type_idx: u32, nullable: u32 };
pub const OpsRefAsNonNull = extern struct { dst: Slot, ref: Slot };
pub const OpsBrOnNull = extern struct { ref: Slot, _pad: u16 = 0, rel_target: i32 };
pub const OpsBrOnCast = extern struct { ref: Slot, _pad: u16 = 0, rel_target: i32, from_type_idx: u32, to_type_idx: u32, to_nullable: u32 };
pub const OpsRefI31 = extern struct { dst: Slot, value: Slot };
pub const OpsI31Get = extern struct { dst: Slot, ref: Slot };

pub const OpsLoad = extern struct { dst: Slot, addr: Slot, offset: u32 };
pub const OpsStore = extern struct { addr: Slot, src: Slot, offset: u32 };
pub const OpsMemorySize = extern struct { dst: Slot };
pub const OpsMemoryGrow = extern struct { dst: Slot, delta: Slot };
pub const OpsMemoryInit = extern struct { dst_addr: Slot, src_offset: Slot, len: Slot, _pad: u16 = 0, segment_idx: u32 };
pub const OpsDataDrop = extern struct { segment_idx: u32 };
pub const OpsMemoryCopy = extern struct { dst_addr: Slot, src_addr: Slot, len: Slot };
pub const OpsMemoryFill = extern struct { dst_addr: Slot, value: Slot, len: Slot };

pub const OpsCall = extern struct { dst: Slot, dst_valid: u16, func_idx: u32, args_len: u32 };
pub const OpsCallToLocal = extern struct { local: Slot, func_idx: u32, args_len: u32 };
pub const OpsCallLeaf = extern struct { func_idx: u32, args_len: u32 };
pub const OpsCallIndirect = extern struct { dst: Slot, index: Slot, dst_valid: u16, _pad: u16 = 0, type_index: u32, table_index: u32, args_len: u32 };
pub const OpsReturnCall = extern struct { func_idx: u32, args_len: u32 };
pub const OpsReturnCallIndirect = extern struct { index: Slot, _pad: u16 = 0, type_index: u32, table_index: u32, args_len: u32 };
pub const OpsCallRef = extern struct { dst: Slot, ref: Slot, dst_valid: u16, _pad: u16 = 0, type_idx: u32, args_len: u32 };
pub const OpsReturnCallRef = extern struct { ref: Slot, _pad: u16 = 0, type_idx: u32, args_len: u32 };

pub const OpsAtomicLoad = extern struct { dst: Slot, addr: Slot, offset: u32, width: u8, ty: u8, _pad: u16 = 0 };
pub const OpsAtomicStore = extern struct { addr: Slot, src: Slot, offset: u32, width: u8, ty: u8, _pad: u16 = 0 };
pub const OpsAtomicRmw = extern struct { dst: Slot, addr: Slot, src: Slot, _pad: u16 = 0, offset: u32, op: u8, width: u8, ty: u8, _pad2: u8 = 0 };
pub const OpsAtomicCmpxchg = extern struct { dst: Slot, addr: Slot, expected: Slot, replacement: Slot, offset: u32, width: u8, ty: u8, _pad: u16 = 0 };
pub const OpsAtomicNotify = extern struct { dst: Slot, addr: Slot, count: Slot, _pad: u16 = 0, offset: u32 };
pub const OpsAtomicWait32 = extern struct { dst: Slot, addr: Slot, expected: Slot, timeout: Slot, offset: u32 };
pub const OpsAtomicWait64 = extern struct { dst: Slot, addr: Slot, expected: Slot, timeout: Slot, offset: u32 };

pub const OpsTableGet = extern struct { dst: Slot, index: Slot, table_index: u32 };
pub const OpsTableSet = extern struct { index: Slot, value: Slot, table_index: u32 };
pub const OpsTableSize = extern struct { dst: Slot, _pad: u16 = 0, table_index: u32 };
pub const OpsTableGrow = extern struct { dst: Slot, init: Slot, delta: Slot, _pad: u16 = 0, table_index: u32 };
pub const OpsTableFill = extern struct { dst_idx: Slot, value: Slot, len: Slot, _pad: u16 = 0, table_index: u32 };
pub const OpsTableCopy = extern struct { dst_idx: Slot, src_idx: Slot, len: Slot, _pad: u16 = 0, dst_table: u32, src_table: u32 };
pub const OpsTableInit = extern struct { dst_idx: Slot, src_offset: Slot, len: Slot, _pad: u16 = 0, table_index: u32, segment_idx: u32 };
pub const OpsElemDrop = extern struct { segment_idx: u32 };

pub const OpsStructNew = extern struct { dst: Slot, _pad: u16 = 0, type_idx: u32, args_len: u32 };
pub const OpsStructNewDefault = extern struct { dst: Slot, _pad: u16 = 0, type_idx: u32 };
pub const OpsStructGet = extern struct { dst: Slot, ref: Slot, type_idx: u32, field_idx: u32 };
pub const OpsStructSet = extern struct { ref: Slot, value: Slot, type_idx: u32, field_idx: u32 };

pub const OpsArrayNew = extern struct { dst: Slot, init: Slot, len: Slot, _pad: u16 = 0, type_idx: u32 };
pub const OpsArrayNewDefault = extern struct { dst: Slot, len: Slot, type_idx: u32 };
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

pub const OpsConvertRef = extern struct { dst: Slot, ref: Slot };

pub const OpsThrow = extern struct { tag_index: u32, args_len: u32 };
pub const OpsThrowRef = extern struct { ref: Slot };
pub const OpsTryTableEnter = extern struct { handlers_start: u32, handlers_len: u32, end_target: u32 };
pub const OpsTryTableLeave = extern struct { rel_target: i32 };

pub const OpsSimdUnary = extern struct { dst: Slot, src: Slot, opcode: u32 };
pub const OpsSimdBinary = extern struct { dst: Slot, lhs: Slot, rhs: Slot, _pad: u16 = 0, opcode: u32 };
pub const OpsSimdTernary = extern struct { dst: Slot, first: Slot, second: Slot, third: Slot, opcode: u32 };
pub const OpsSimdExtractLane = extern struct { dst: Slot, src: Slot, opcode: u32, lane: u8, _pad2: [3]u8 = [_]u8{0} ** 3 };
pub const OpsSimdReplaceLane = extern struct { dst: Slot, src_vec: Slot, src_lane: Slot, _pad: u16 = 0, opcode: u32, lane: u8, _pad2: [3]u8 = [_]u8{0} ** 3 };
pub const OpsSimdShuffle = extern struct { dst: Slot, lhs: Slot, rhs: Slot, _pad: u16 = 0, lanes: [16]u8 };
pub const OpsSimdLoad = extern struct { dst: Slot, addr: Slot, src_vec: Slot, _pad: u16 = 0, opcode: u32, offset: u32, lane_valid: u8, lane: u8, src_vec_valid: u8, _pad2: u8 = 0 };
pub const OpsSimdStore = extern struct { addr: Slot, src: Slot, opcode: u32, offset: u32, lane_valid: u8, lane: u8, _pad: [2]u8 = [_]u8{0} ** 2 };

// ── f32/f64 fused operations ───────────────────────────────────────────────────

pub const OpsBinopImmF32 = extern struct { dst: Slot, lhs: Slot, _pad: u16 = 0, imm: f32 };
pub const OpsBinopImmF64 = extern struct { dst: Slot, lhs: Slot, _pad: [6]u8 = [_]u8{0} ** 6, imm: f64 };

pub const OpsCompareImmJumpF32 = extern struct { lhs: Slot, _pad: u16 = 0, imm: f32, rel_target: i32 };
pub const OpsCompareImmJumpF64 = extern struct { lhs: Slot, _pad: [6]u8 = [_]u8{0} ** 6, imm: f64, rel_target: i32, _pad2: u32 = 0 };

pub const OpsBinopImmToLocalF32 = extern struct { local: Slot, lhs: Slot, _pad: u16 = 0, imm: f32 };
pub const OpsBinopImmToLocalF64 = extern struct { local: Slot, lhs: Slot, _pad: [6]u8 = [_]u8{0} ** 6, imm: f64 };

pub const OpsLocalInplaceF32 = extern struct { local: Slot, _pad: u16 = 0, imm: f32 };
pub const OpsLocalInplaceF64 = extern struct { local: Slot, _pad: [6]u8 = [_]u8{0} ** 6, imm: f64 };

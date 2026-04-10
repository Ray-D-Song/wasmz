/// translate.zig - parser to compiler/core bridge for type translation
///
/// Responsible for translating Wasm type representations from the parser/payload layer
/// into types used by the compiler and runtime.
/// This module serves as a bridge between the parser layer and the compiler/core layer.
const std = @import("std");
const payload_mod = @import("payload");
const lower_mod = @import("./lower.zig");
const core = @import("core");

const OperatorInformation = payload_mod.OperatorInformation;
const OperatorCode = payload_mod.OperatorCode;
const Type = payload_mod.Type;
const TypeKind = payload_mod.TypeKind;
const TypeEntry = payload_mod.TypeEntry;
const PayloadHeapType = payload_mod.HeapType;
const WasmOp = lower_mod.WasmOp;
const BlockType = lower_mod.BlockType;
const ValType = core.ValType;
const HeapType = core.HeapType;
const RefType = core.RefType;
const StorageType = core.StorageType;
const FieldType = core.FieldType;
const CompositeType = core.CompositeType;
const simd = core.simd;
const V128 = simd.V128;

pub const TranslateError = error{
    UnsupportedFunctionType,
    UnsupportedBlockType,
    UnsupportedOperator,
    InvalidI32Literal,
    InvalidI64Literal,
    UnsupportedConstExpr,
    UnsupportedStorageType,
    OutOfMemory,
    TooManyFunctionParams,
    TooManyFunctionResults,
    InvalidTypeIndex,
};

/// Translates a Wasm type (payload Type) into a runtime value type (ValType).
/// Supports i32/i64/f32/f64/v128 and all GC reference types.
pub fn wasmValTypeFromType(typ: Type) TranslateError!ValType {
    return switch (typ) {
        .kind => |kind| switch (kind) {
            .i32 => .I32,
            .i64 => .I64,
            .f32 => .F32,
            .f64 => .F64,
            .v128 => .V128,
            .funcref => ValType.funcref(),
            .null_funcref => ValType.nullfuncref(),
            .externref => ValType.externref(),
            .null_externref => ValType.nullexternref(),
            .anyref => ValType.anyref(),
            .null_ref => ValType.nullref(),
            .eqref => ValType.eqref(),
            .i31ref => ValType.i31ref(),
            .structref => ValType.structref(),
            .arrayref => ValType.arrayref(),
            else => error.UnsupportedFunctionType,
        },
        .ref_type => |ref_type| blk: {
            const heap_type = switch (ref_type.ref_index) {
                .kind => |kind| switch (kind) {
                    .funcref => HeapType.Func,
                    .null_funcref => HeapType.NoFunc,
                    .externref => HeapType.Extern,
                    .null_externref => HeapType.NoExtern,
                    .anyref => HeapType.Any,
                    .null_ref => HeapType.None,
                    .eqref => HeapType.Eq,
                    .i31ref => HeapType.I31,
                    .structref => HeapType.Struct,
                    .arrayref => HeapType.Array,
                    else => return error.UnsupportedFunctionType,
                },
                .index => |idx| HeapType.fromConcreteType(idx),
            };
            const ref_ty = RefType.init(ref_type.nullable, heap_type);
            break :blk .{ .Ref = ref_ty };
        },
        else => error.UnsupportedFunctionType,
    };
}

/// Translates a Wasm block type (optional Type) into a BlockType used by Lower.
/// empty_block_type (0x40) corresponds to null (void block).
/// All single-value types are delegated to wasmValTypeFromType.
/// TODO: support multi-value block types (positive type index referencing the Type Section).
pub fn wasmBlockTypeFromType(block_type: ?Type) TranslateError!?BlockType {
    const typ = block_type orelse return error.UnsupportedBlockType;
    return switch (typ) {
        .kind => |kind| switch (kind) {
            .empty_block_type => null,
            else => try wasmValTypeFromType(typ),
        },
        else => error.UnsupportedBlockType,
    };
}

/// Extracts a concrete type index from a HeapType.
/// Returns InvalidTypeIndex error if the HeapType is null or represents an abstract type.
fn typeIndexFromHeapType(heap_type: ?PayloadHeapType) TranslateError!u32 {
    const ht = heap_type orelse return error.InvalidTypeIndex;
    return switch (ht) {
        .index => |idx| idx,
        .kind => return error.InvalidTypeIndex, // Abstract heap types not supported here
    };
}

/// Translates OperatorInformation produced by the parser into a WasmOp recognized by Lower.
/// Unsupported opcodes return the UnsupportedOperator error.
pub fn operatorToWasmOp(info: OperatorInformation) TranslateError!WasmOp {
    // ── Comptime-generated simple operation mappings ─────────────────────────
    // These operations have a 1:1 mapping from OperatorCode to WasmOp (no payload)

    const simple_binary_ops = [_]OperatorCode{
        .i32_add,   .i32_sub,      .i32_mul, .i32_div_s, .i32_div_u, .i32_rem_s, .i32_rem_u,
        .i32_and,   .i32_or,       .i32_xor, .i32_shl,   .i32_shr_s, .i32_shr_u, .i32_rotl,
        .i32_rotr,  .i64_add,      .i64_sub, .i64_mul,   .i64_div_s, .i64_div_u, .i64_rem_s,
        .i64_rem_u, .i64_and,      .i64_or,  .i64_xor,   .i64_shl,   .i64_shr_s, .i64_shr_u,
        .i64_rotl,  .i64_rotr,     .f32_add, .f32_sub,   .f32_mul,   .f32_div,   .f32_min,
        .f32_max,   .f32_copysign, .f64_add, .f64_sub,   .f64_mul,   .f64_div,   .f64_min,
        .f64_max,   .f64_copysign,
    };

    const simple_unary_ops = [_]OperatorCode{
        .i32_clz,     .i32_ctz,   .i32_popcnt,
        .i64_clz,     .i64_ctz,   .i64_popcnt,
        .f32_abs,     .f32_neg,   .f32_ceil,
        .f32_floor,   .f32_trunc, .f32_nearest,
        .f32_sqrt,    .f64_abs,   .f64_neg,
        .f64_ceil,    .f64_floor, .f64_trunc,
        .f64_nearest, .f64_sqrt,
    };

    const simple_compare_ops = [_]OperatorCode{
        .i32_eqz,
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
        .i64_eqz,
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
    };

    const simple_convert_ops = [_]OperatorCode{
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
        .f64_convert_i32_s,
        .f64_convert_i32_u,
        .f64_convert_i64_s,
        .f64_convert_i64_u,
        .f64_promote_f32,
        .i32_reinterpret_f32,
        .i64_reinterpret_f64,
        .f32_reinterpret_i32,
        .f64_reinterpret_i64,
        .i32_extend8_s,
        .i32_extend16_s,
        .i64_extend8_s,
        .i64_extend16_s,
        .i64_extend32_s,
    };

    // Auto-generate mappings for binary operations
    inline for (simple_binary_ops) |op| {
        if (info.code == op) {
            return @field(WasmOp, @tagName(op));
        }
    }

    // Auto-generate mappings for unary operations
    inline for (simple_unary_ops) |op| {
        if (info.code == op) {
            return @field(WasmOp, @tagName(op));
        }
    }

    // Auto-generate mappings for comparison operations
    inline for (simple_compare_ops) |op| {
        if (info.code == op) {
            return @field(WasmOp, @tagName(op));
        }
    }

    // Auto-generate mappings for conversion and sign-extension operations
    inline for (simple_convert_ops) |op| {
        if (info.code == op) {
            return @field(WasmOp, @tagName(op));
        }
    }

    if (simd.isSimdOpcode(info.code)) {
        return try simdWasmOpFromOperatorInfo(info);
    }

    // ── Manual mapping for operations with special payloads ───────────────────

    return switch (info.code) {
        .unreachable_ => WasmOp.unreachable_,
        .nop => WasmOp.nop,
        .drop => WasmOp.drop,
        .block => WasmOp{ .block = try wasmBlockTypeFromType(info.block_type) },
        .loop => WasmOp{ .loop = try wasmBlockTypeFromType(info.block_type) },
        .if_ => WasmOp{ .if_ = try wasmBlockTypeFromType(info.block_type) },
        .else_ => WasmOp.else_,
        .end => WasmOp.end,
        .br => WasmOp{ .br = info.br_depth orelse return error.UnsupportedOperator },
        .br_if => WasmOp{ .br_if = info.br_depth orelse return error.UnsupportedOperator },
        .br_table => WasmOp{ .br_table = .{ .targets = info.br_table } },
        .local_get => WasmOp{ .local_get = info.local_index orelse return error.UnsupportedOperator },
        .local_set => WasmOp{ .local_set = info.local_index orelse return error.UnsupportedOperator },
        .local_tee => WasmOp{ .local_tee = info.local_index orelse return error.UnsupportedOperator },
        .global_get => WasmOp{ .global_get = info.global_index orelse return error.UnsupportedOperator },
        .global_set => WasmOp{ .global_set = info.global_index orelse return error.UnsupportedOperator },

        // ── Constants ───────────────────────────────────────────────────────
        .i32_const => WasmOp{ .i32_const = try literalAsI32(info) },
        .i64_const => WasmOp{ .i64_const = try literalAsI64(info) },
        .f32_const => WasmOp{ .f32_const = try literalAsF32(info) },
        .f64_const => WasmOp{ .f64_const = try literalAsF64(info) },

        // ── Memory load instructions ─────────────────────────────────────────
        .i32_load => WasmOp{ .i32_load = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .i32_load8_s => WasmOp{ .i32_load8_s = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .i32_load8_u => WasmOp{ .i32_load8_u = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .i32_load16_s => WasmOp{ .i32_load16_s = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .i32_load16_u => WasmOp{ .i32_load16_u = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .i64_load => WasmOp{ .i64_load = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .i64_load8_s => WasmOp{ .i64_load8_s = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .i64_load8_u => WasmOp{ .i64_load8_u = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .i64_load16_s => WasmOp{ .i64_load16_s = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .i64_load16_u => WasmOp{ .i64_load16_u = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .i64_load32_s => WasmOp{ .i64_load32_s = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .i64_load32_u => WasmOp{ .i64_load32_u = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .f32_load => WasmOp{ .f32_load = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .f64_load => WasmOp{ .f64_load = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },

        // ── Memory store instructions ───────────────────────────────────────
        .i32_store => WasmOp{ .i32_store = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .i32_store8 => WasmOp{ .i32_store8 = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .i32_store16 => WasmOp{ .i32_store16 = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .i64_store => WasmOp{ .i64_store = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .i64_store8 => WasmOp{ .i64_store8 = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .i64_store16 => WasmOp{ .i64_store16 = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .i64_store32 => WasmOp{ .i64_store32 = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .f32_store => WasmOp{ .f32_store = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .f64_store => WasmOp{ .f64_store = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },

        // ── Bulk memory instructions ────────────────────────────────────────
        .memory_init => WasmOp{ .memory_init = info.segment_index orelse return error.UnsupportedOperator },
        .data_drop => WasmOp{ .data_drop = info.segment_index orelse return error.UnsupportedOperator },
        .memory_copy => WasmOp.memory_copy,
        .memory_fill => WasmOp.memory_fill,

        .return_ => WasmOp.ret,
        .select => WasmOp.select,
        .select_with_type => WasmOp.select_with_type,

        // ── Reference type instructions ─────────────────────────────────────────
        .ref_null => WasmOp.ref_null,
        .ref_is_null => WasmOp.ref_is_null,
        .ref_func => WasmOp{ .ref_func = info.func_index orelse return error.UnsupportedOperator },
        .ref_eq => WasmOp.ref_eq,

        // ── Table instructions ──────────────────────────────────────────────────
        .table_get => WasmOp{ .table_get = info.table_index orelse return error.UnsupportedOperator },
        .table_set => WasmOp{ .table_set = info.table_index orelse return error.UnsupportedOperator },
        .table_size => WasmOp{ .table_size = info.table_index orelse return error.UnsupportedOperator },
        .table_grow => WasmOp{ .table_grow = info.table_index orelse return error.UnsupportedOperator },
        .table_fill => WasmOp{ .table_fill = info.table_index orelse return error.UnsupportedOperator },
        .table_copy => WasmOp{ .table_copy = .{
            .dst_table = info.table_index orelse return error.UnsupportedOperator,
            .src_table = info.destination_index orelse return error.UnsupportedOperator,
        } },
        .table_init => WasmOp{ .table_init = .{
            .table_index = info.table_index orelse return error.UnsupportedOperator,
            .segment_idx = info.segment_index orelse return error.UnsupportedOperator,
        } },
        .elem_drop => WasmOp{ .elem_drop = info.segment_index orelse return error.UnsupportedOperator },

        // ── GC Struct instructions ─────────────────────────────────────────────────
        // Note: n_fields will be filled by module.zig after looking up the type definition
        .struct_new => WasmOp{
            .struct_new = .{
                .type_idx = try typeIndexFromHeapType(info.type_index),
                .n_fields = info.len orelse 0, // placeholder, filled by module.zig
            },
        },
        .struct_new_default => WasmOp{ .struct_new_default = try typeIndexFromHeapType(info.type_index) },
        .struct_get => WasmOp{ .struct_get = .{
            .type_idx = try typeIndexFromHeapType(info.type_index),
            .field_idx = info.field_index orelse return error.UnsupportedOperator,
        } },
        .struct_get_s => WasmOp{ .struct_get_s = .{
            .type_idx = try typeIndexFromHeapType(info.type_index),
            .field_idx = info.field_index orelse return error.UnsupportedOperator,
        } },
        .struct_get_u => WasmOp{ .struct_get_u = .{
            .type_idx = try typeIndexFromHeapType(info.type_index),
            .field_idx = info.field_index orelse return error.UnsupportedOperator,
        } },
        .struct_set => WasmOp{ .struct_set = .{
            .type_idx = try typeIndexFromHeapType(info.type_index),
            .field_idx = info.field_index orelse return error.UnsupportedOperator,
        } },

        // ── GC Array instructions ──────────────────────────────────────────────────
        .array_new => WasmOp{ .array_new = try typeIndexFromHeapType(info.type_index) },
        .array_new_default => WasmOp{ .array_new_default = try typeIndexFromHeapType(info.type_index) },
        .array_new_fixed => WasmOp{ .array_new_fixed = .{
            .type_idx = try typeIndexFromHeapType(info.type_index),
            .n = info.len orelse return error.UnsupportedOperator,
        } },
        .array_new_data => WasmOp{ .array_new_data = .{
            .type_idx = try typeIndexFromHeapType(info.type_index),
            .data_idx = info.segment_index orelse return error.UnsupportedOperator,
        } },
        .array_new_elem => WasmOp{ .array_new_elem = .{
            .type_idx = try typeIndexFromHeapType(info.type_index),
            .elem_idx = info.segment_index orelse return error.UnsupportedOperator,
        } },
        .array_get => WasmOp{ .array_get = try typeIndexFromHeapType(info.type_index) },
        .array_get_s => WasmOp{ .array_get_s = try typeIndexFromHeapType(info.type_index) },
        .array_get_u => WasmOp{ .array_get_u = try typeIndexFromHeapType(info.type_index) },
        .array_set => WasmOp{ .array_set = try typeIndexFromHeapType(info.type_index) },
        .array_len => WasmOp.array_len,
        .array_fill => WasmOp{ .array_fill = try typeIndexFromHeapType(info.type_index) },
        .array_copy => WasmOp{ .array_copy = .{
            .dst_type_idx = try typeIndexFromHeapType(info.type_index),
            .src_type_idx = try typeIndexFromHeapType(info.src_type),
        } },
        .array_init_data => WasmOp{ .array_init_data = .{
            .type_idx = try typeIndexFromHeapType(info.type_index),
            .data_idx = info.segment_index orelse return error.UnsupportedOperator,
        } },
        .array_init_elem => WasmOp{ .array_init_elem = .{
            .type_idx = try typeIndexFromHeapType(info.type_index),
            .elem_idx = info.segment_index orelse return error.UnsupportedOperator,
        } },

        // ── GC i31 instructions ────────────────────────────────────────────────────
        .ref_i31 => WasmOp.ref_i31,
        .i31_get_s => WasmOp.i31_get_s,
        .i31_get_u => WasmOp.i31_get_u,

        // ── GC Type Test/Cast instructions ─────────────────────────────────────────
        .ref_test, .ref_test_null => WasmOp{ .ref_test = try typeIndexFromHeapType(info.type_index) },
        .ref_cast, .ref_cast_null => WasmOp{ .ref_cast = try typeIndexFromHeapType(info.type_index) },
        .ref_as_non_null => WasmOp.ref_as_non_null,

        // ── GC Control Flow instructions ───────────────────────────────────────────
        .br_on_null => WasmOp{ .br_on_null = info.br_depth orelse return error.UnsupportedOperator },
        .br_on_non_null => WasmOp{ .br_on_non_null = info.br_depth orelse return error.UnsupportedOperator },
        .br_on_cast => WasmOp{ .br_on_cast = .{
            .br_depth = info.br_depth orelse return error.UnsupportedOperator,
            .from_type_idx = try typeIndexFromHeapType(info.src_type),
            .to_type_idx = try typeIndexFromHeapType(info.type_index),
        } },
        .br_on_cast_fail => WasmOp{ .br_on_cast_fail = .{
            .br_depth = info.br_depth orelse return error.UnsupportedOperator,
            .from_type_idx = try typeIndexFromHeapType(info.src_type),
            .to_type_idx = try typeIndexFromHeapType(info.type_index),
        } },

        // ── GC Call instructions ───────────────────────────────────────────────────
        // Note: n_params and has_result will be filled by the caller (module.zig)
        .call_ref => WasmOp{
            .call_ref = .{
                .type_idx = try typeIndexFromHeapType(info.type_index),
                .n_params = 0, // placeholder, filled by caller
                .has_result = false, // placeholder, filled by caller
            },
        },
        .return_call_ref => WasmOp{
            .return_call_ref = .{
                .type_idx = try typeIndexFromHeapType(info.type_index),
                .n_params = 0, // placeholder, filled by caller
            },
        },

        // ── GC Extern/Any conversion instructions ──────────────────────────────────
        .any_convert_extern => WasmOp.any_convert_extern,
        .extern_convert_any => WasmOp.extern_convert_any,

        else => |op| {
            std.debug.print("UnsupportedOperator: {s}\n", .{@tagName(op)});
            return error.UnsupportedOperator;
        },
    };
}

fn simdWasmOpFromOperatorInfo(info: OperatorInformation) TranslateError!WasmOp {
    const class = simd.classifyOpcode(info.code) orelse return error.UnsupportedOperator;
    return switch (class) {
        .const_ => WasmOp{ .v128_const = try literalAsV128(info) },
        .shuffle => WasmOp{ .simd_shuffle = try literalAsShuffleLanes(info) },
        .extract_lane => WasmOp{ .simd_extract_lane = .{
            .opcode = info.code,
            .lane = try laneIndexAsU8(info),
        } },
        .replace_lane => WasmOp{ .simd_replace_lane = .{
            .opcode = info.code,
            .lane = try laneIndexAsU8(info),
        } },
        .load => WasmOp{ .simd_load = .{
            .opcode = info.code,
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
            .lane = if (simd.isLaneLoadOpcode(info.code)) try laneIndexAsU8(info) else null,
        } },
        .store => WasmOp{ .simd_store = .{
            .opcode = info.code,
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
            .lane = if (simd.isLaneStoreOpcode(info.code)) try laneIndexAsU8(info) else null,
        } },
        .unary => WasmOp{ .simd_unary = info.code },
        .binary => WasmOp{ .simd_binary = info.code },
        .ternary => WasmOp{ .simd_ternary = info.code },
        .compare => WasmOp{ .simd_compare = info.code },
        .shift => WasmOp{ .simd_shift_scalar = info.code },
    };
}

/// Extracts an i32 literal from OperatorInformation.
/// Returns InvalidI32Literal if the literal field is missing or the type does not match.
pub fn literalAsI32(info: OperatorInformation) TranslateError!i32 {
    const literal = info.literal orelse return error.InvalidI32Literal;
    return switch (literal) {
        .number => |value| std.math.cast(i32, value) orelse error.InvalidI32Literal,
        else => error.InvalidI32Literal,
    };
}

/// Extracts an i64 literal from OperatorInformation.
pub fn literalAsI64(info: OperatorInformation) TranslateError!i64 {
    const literal = info.literal orelse return error.InvalidI64Literal;
    return switch (literal) {
        .int64 => |value| value,
        .number => |value| value,
        else => error.InvalidI64Literal,
    };
}

/// Extracts an f32 literal from OperatorInformation.
/// f32 is stored in 4-byte little-endian format in literal.bytes and restored to f32 via bitcast.
pub fn literalAsF32(info: OperatorInformation) TranslateError!f32 {
    const literal = info.literal orelse return error.UnsupportedConstExpr;
    return switch (literal) {
        .bytes => |bytes| {
            if (bytes.len != 4) return error.UnsupportedConstExpr;
            const bits = std.mem.readInt(u32, bytes[0..4], .little);
            return @as(f32, @bitCast(bits));
        },
        else => error.UnsupportedConstExpr,
    };
}

/// Extracts an f64 literal from OperatorInformation.
/// f64 is stored in 8-byte little-endian format in literal.bytes and restored to f64 via bitcast.
pub fn literalAsF64(info: OperatorInformation) TranslateError!f64 {
    const literal = info.literal orelse return error.UnsupportedConstExpr;
    return switch (literal) {
        .bytes => |bytes| {
            if (bytes.len != 8) return error.UnsupportedConstExpr;
            const bits = std.mem.readInt(u64, bytes[0..8], .little);
            return @as(f64, @bitCast(bits));
        },
        else => error.UnsupportedConstExpr,
    };
}

pub fn literalAsV128(info: OperatorInformation) TranslateError!V128 {
    const literal = info.literal orelse return error.UnsupportedConstExpr;
    return switch (literal) {
        .bytes => |bytes| {
            if (bytes.len != 16) return error.UnsupportedConstExpr;
            var out: [16]u8 = undefined;
            @memcpy(out[0..], bytes[0..16]);
            return simd.v128FromBytes(out);
        },
        else => error.UnsupportedConstExpr,
    };
}

fn literalAsShuffleLanes(info: OperatorInformation) TranslateError![16]u8 {
    const bytes = info.lines orelse return error.UnsupportedOperator;
    if (bytes.len != 16) return error.UnsupportedOperator;
    var out: [16]u8 = undefined;
    @memcpy(out[0..], bytes[0..16]);
    return out;
}

fn laneIndexAsU8(info: OperatorInformation) TranslateError!u8 {
    return @as(u8, @intCast(info.line_index orelse return error.UnsupportedOperator));
}

/// Translates a Wasm type (payload Type) into a runtime storage type (StorageType).
/// Supports value types (i32/i64/f32/f64/v128/ref) and packed types (i8/i16).
pub fn wasmStorageTypeFromType(typ: Type) TranslateError!StorageType {
    return switch (typ) {
        .kind => |kind| switch (kind) {
            .i32 => StorageType{ .valtype = .I32 },
            .i64 => StorageType{ .valtype = .I64 },
            .f32 => StorageType{ .valtype = .F32 },
            .f64 => StorageType{ .valtype = .F64 },
            .v128 => StorageType{ .valtype = .V128 },
            .i8 => StorageType{ .packed_type = .I8 },
            .i16 => StorageType{ .packed_type = .I16 },
            .funcref, .null_funcref => StorageType{ .valtype = ValType.funcref() },
            .externref, .null_externref => StorageType{ .valtype = ValType.externref() },
            .anyref, .null_ref => StorageType{ .valtype = ValType.anyref() },
            .eqref => StorageType{ .valtype = ValType.eqref() },
            .i31ref => StorageType{ .valtype = ValType.i31ref() },
            .structref => StorageType{ .valtype = ValType.structref() },
            .arrayref => StorageType{ .valtype = ValType.arrayref() },
            else => error.UnsupportedStorageType,
        },
        .ref_type => |ref_type| blk: {
            const heap_type = switch (ref_type.ref_index) {
                .kind => |kind| switch (kind) {
                    .funcref, .null_funcref => core.HeapType.Func,
                    .externref, .null_externref => core.HeapType.Extern,
                    .anyref, .null_ref => core.HeapType.Any,
                    .eqref => core.HeapType.Eq,
                    .i31ref => core.HeapType.I31,
                    .structref => core.HeapType.Struct,
                    .arrayref => core.HeapType.Array,
                    else => return error.UnsupportedStorageType,
                },
                .index => |idx| core.HeapType.fromConcreteType(idx),
            };
            const ref_ty = core.RefType.init(ref_type.nullable, heap_type);
            break :blk StorageType{ .valtype = .{ .Ref = ref_ty } };
        },
        else => error.UnsupportedStorageType,
    };
}

/// Compiles a GC composite type into a CompositeType.
/// Function types are handled separately from GC runtime metadata.
pub fn wasmCompositeTypeFromTypeEntry(
    allocator: std.mem.Allocator,
    entry: TypeEntry,
) (TranslateError || std.mem.Allocator.Error)!CompositeType {
    return switch (entry.type) {
        .struct_type => blk: {
            const fields = try allocator.alloc(FieldType, entry.fields.len);
            for (entry.fields, entry.mutabilities, 0..) |field_type, mutable, i| {
                fields[i] = .{
                    .storage_type = try wasmStorageTypeFromType(field_type),
                    .mutable = mutable,
                };
            }
            break :blk CompositeType{ .struct_type = .{ .fields = fields } };
        },
        .array_type => blk: {
            const element_type = entry.element_type orelse return error.UnsupportedStorageType;
            const mutable = entry.mutability orelse false;
            break :blk CompositeType{ .array_type = .{
                .field = .{
                    .storage_type = try wasmStorageTypeFromType(element_type),
                    .mutable = mutable,
                },
            } };
        },
        else => error.UnsupportedFunctionType,
    };
}

test "wasmValTypeFromType handles GC reference types" {
    const testing = std.testing;
    const payload = @import("payload");

    // Test abstract heap types
    const anyref_type = Type{ .kind = .anyref };
    try testing.expectEqual(ValType.anyref(), try wasmValTypeFromType(anyref_type));

    const eqref_type = Type{ .kind = .eqref };
    try testing.expectEqual(ValType.eqref(), try wasmValTypeFromType(eqref_type));

    const i31ref_type = Type{ .kind = .i31ref };
    try testing.expectEqual(ValType.i31ref(), try wasmValTypeFromType(i31ref_type));

    const structref_type = Type{ .kind = .structref };
    try testing.expectEqual(ValType.structref(), try wasmValTypeFromType(structref_type));

    const arrayref_type = Type{ .kind = .arrayref };
    try testing.expectEqual(ValType.arrayref(), try wasmValTypeFromType(arrayref_type));

    // Test nullable ref types
    const null_funcref = Type{ .kind = .null_funcref };
    try testing.expectEqual(ValType.nullfuncref(), try wasmValTypeFromType(null_funcref));

    const null_externref = Type{ .kind = .null_externref };
    try testing.expectEqual(ValType.nullexternref(), try wasmValTypeFromType(null_externref));

    const null_ref = Type{ .kind = .null_ref };
    try testing.expectEqual(ValType.nullref(), try wasmValTypeFromType(null_ref));

    // Test ref.type with heap type index
    const ref_type_payload = payload.RefType{
        .nullable = true,
        .ref_index = .{ .index = 5 },
    };
    const concrete_ref_type = Type{ .ref_type = ref_type_payload };
    const result = try wasmValTypeFromType(concrete_ref_type);
    try testing.expect(result == .Ref);
    try testing.expect(result.Ref.nullable);
    try testing.expect(result.Ref.heap_type.isConcrete());
    try testing.expectEqual(@as(u32, 5), result.Ref.heap_type.concreteType().?);
}

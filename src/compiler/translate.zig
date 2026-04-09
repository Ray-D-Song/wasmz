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
const WasmOp = lower_mod.WasmOp;
const BlockType = lower_mod.BlockType;
const ValType = core.ValType;
const simd = core.simd;
const V128 = simd.V128;

pub const TranslateError = error{
    UnsupportedFunctionType,
    UnsupportedBlockType,
    UnsupportedOperator,
    InvalidI32Literal,
    InvalidI64Literal,
    UnsupportedConstExpr,
};

/// Translates a Wasm type (payload Type) into a runtime value type (ValType).
/// Only supports i32/i64/f32/f64/v128/funcref/externref; other types return UnsupportedFunctionType.
pub fn wasmValTypeFromType(typ: Type) TranslateError!ValType {
    return switch (typ) {
        .kind => |kind| switch (kind) {
            .i32 => .I32,
            .i64 => .I64,
            .f32 => .F32,
            .f64 => .F64,
            .v128 => .V128,
            .funcref, .null_funcref => ValType.funcref(),
            .externref, .null_externref => ValType.externref(),
            else => error.UnsupportedFunctionType,
        },
        .ref_type => |ref_type| switch (ref_type.ref_index) {
            .kind => |kind| switch (kind) {
                .funcref, .null_funcref => ValType.funcref(),
                .externref, .null_externref => ValType.externref(),
                else => error.UnsupportedFunctionType,
            },
            else => error.UnsupportedFunctionType,
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

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
const Type = payload_mod.Type;
const WasmOp = lower_mod.WasmOp;
const BlockType = lower_mod.BlockType;
const ValType = core.ValType;

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
            .funcref, .null_funcref => .FuncRef,
            .externref, .null_externref => .ExternRef,
            else => error.UnsupportedFunctionType,
        },
        .ref_type => |ref_type| switch (ref_type.ref_index) {
            .kind => |kind| switch (kind) {
                .funcref, .null_funcref => .FuncRef,
                .externref, .null_externref => .ExternRef,
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
    return switch (info.code) {
        .unreachable_ => WasmOp.unreachable_,
        .drop => WasmOp.drop,
        .block => WasmOp{ .block = try wasmBlockTypeFromType(info.block_type) },
        .loop => WasmOp{ .loop = try wasmBlockTypeFromType(info.block_type) },
        .if_ => WasmOp{ .if_ = try wasmBlockTypeFromType(info.block_type) },
        .else_ => WasmOp.else_,
        .end => WasmOp.end,
        .br => WasmOp{ .br = info.br_depth orelse return error.UnsupportedOperator },
        .br_if => WasmOp{ .br_if = info.br_depth orelse return error.UnsupportedOperator },
        .local_get => WasmOp{ .local_get = info.local_index orelse return error.UnsupportedOperator },
        .local_set => WasmOp{ .local_set = info.local_index orelse return error.UnsupportedOperator },
        .local_tee => WasmOp{ .local_tee = info.local_index orelse return error.UnsupportedOperator },
        .global_get => WasmOp{ .global_get = info.global_index orelse return error.UnsupportedOperator },
        .global_set => WasmOp{ .global_set = info.global_index orelse return error.UnsupportedOperator },
        .i32_const => WasmOp{ .i32_const = try literalAsI32(info) },

        // ── Memory instructions ───────────────────────────────────────────────
        // All memory instructions require memory_address field (with offset), align field is ignored for now (not validated at runtime).
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
        .i32_store => WasmOp{ .i32_store = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .i32_store8 => WasmOp{ .i32_store8 = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },
        .i32_store16 => WasmOp{ .i32_store16 = .{
            .offset = (info.memory_address orelse return error.UnsupportedOperator).offset,
        } },

        .i32_add => WasmOp.i32_add,
        .i32_sub => WasmOp.i32_sub,
        .i32_mul => WasmOp.i32_mul,
        .i32_div_s => WasmOp.i32_div_s,
        .i32_div_u => WasmOp.i32_div_u,
        .i32_rem_s => WasmOp.i32_rem_s,
        .i32_rem_u => WasmOp.i32_rem_u,
        .i32_and => WasmOp.i32_and,
        .i32_or => WasmOp.i32_or,
        .i32_xor => WasmOp.i32_xor,
        .i32_shl => WasmOp.i32_shl,
        .i32_shr_s => WasmOp.i32_shr_s,
        .i32_shr_u => WasmOp.i32_shr_u,
        .i32_rotl => WasmOp.i32_rotl,
        .i32_rotr => WasmOp.i32_rotr,
        .i32_clz => WasmOp.i32_clz,
        .i32_ctz => WasmOp.i32_ctz,
        .i32_popcnt => WasmOp.i32_popcnt,
        .i32_eqz => WasmOp.i32_eqz,
        .i32_eq => WasmOp.i32_eq,
        .i32_ne => WasmOp.i32_ne,
        .i32_lt_s => WasmOp.i32_lt_s,
        .i32_lt_u => WasmOp.i32_lt_u,
        .i32_gt_s => WasmOp.i32_gt_s,
        .i32_gt_u => WasmOp.i32_gt_u,
        .i32_le_s => WasmOp.i32_le_s,
        .i32_le_u => WasmOp.i32_le_u,
        .i32_ge_s => WasmOp.i32_ge_s,
        .i32_ge_u => WasmOp.i32_ge_u,
        .return_ => WasmOp.ret,
        else => |op| {
            // print unsupported operator, then return error
            std.debug.print("UnsupportedOperator: {s}\n", .{@tagName(op)});
            return error.UnsupportedOperator;
        },
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

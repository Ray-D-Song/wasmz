/// utils/parse.zig — shared helpers for evaluating WebAssembly constant expressions.
///
/// Both the compile-time evaluator (module.zig) and the runtime evaluator
/// (instance.zig) need to decode the same set of primitive const opcodes into
/// RawVal.  This module provides that shared logic so neither file duplicates it.
const std = @import("std");
const payload_mod = @import("payload");
const core = @import("core");

const OperatorInformation = payload_mod.OperatorInformation;
const RawVal = core.RawVal;

pub const ParseConstError = error{
    /// The opcode is not a primitive const instruction handled here.
    UnsupportedConstOpcode,
    /// A required literal field was absent or had an unexpected variant.
    InvalidLiteral,
};

/// Decode a single primitive const opcode into a `RawVal`.
///
/// Handles:
///   - `i32.const`  → `RawVal.from(i32)`
///   - `i64.const`  → `RawVal.from(i64)`
///   - `f32.const`  → `RawVal.from(f32)`
///   - `f64.const`  → `RawVal.from(f64)`
///   - `ref.null`   → `RawVal.fromBits64(0)`
///   - `ref.func`   → `RawVal.fromBits64(func_idx + 1)`
///
/// Any other opcode returns `error.UnsupportedConstOpcode`.
pub fn parseConstLiteral(info: OperatorInformation) ParseConstError!RawVal {
    return switch (info.code) {
        .i32_const => {
            const lit = info.literal orelse return error.InvalidLiteral;
            const val: i32 = switch (lit) {
                .number => |n| std.math.cast(i32, n) orelse return error.InvalidLiteral,
                else => return error.InvalidLiteral,
            };
            return RawVal.from(val);
        },
        .i64_const => {
            const lit = info.literal orelse return error.InvalidLiteral;
            const val: i64 = switch (lit) {
                .int64 => |n| n,
                .number => |n| n,
                else => return error.InvalidLiteral,
            };
            return RawVal.from(val);
        },
        .f32_const => {
            const lit = info.literal orelse return error.InvalidLiteral;
            const val: f32 = switch (lit) {
                .bytes => |b| blk: {
                    if (b.len != 4) return error.InvalidLiteral;
                    break :blk @bitCast(std.mem.readInt(u32, b[0..4], .little));
                },
                else => return error.InvalidLiteral,
            };
            return RawVal.from(val);
        },
        .f64_const => {
            const lit = info.literal orelse return error.InvalidLiteral;
            const val: f64 = switch (lit) {
                .bytes => |b| blk: {
                    if (b.len != 8) return error.InvalidLiteral;
                    break :blk @bitCast(std.mem.readInt(u64, b[0..8], .little));
                },
                else => return error.InvalidLiteral,
            };
            return RawVal.from(val);
        },
        .ref_null => RawVal.fromBits64(0),
        .ref_func => {
            const func_idx = info.func_index orelse return error.InvalidLiteral;
            // funcref encoding: func_idx + 1 so that func_idx=0 is not confused with null.
            return RawVal.fromBits64(func_idx + 1);
        },
        else => error.UnsupportedConstOpcode,
    };
}

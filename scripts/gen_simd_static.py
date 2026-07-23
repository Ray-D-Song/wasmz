#!/usr/bin/env python3
"""Expand generic SIMD ops templates into named static functions."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SIMD_DIR = ROOT / "src/core/simd"
OPS_PATH = SIMD_DIR / "ops.zig"
OPS_STATIC_PATH = SIMD_DIR / "ops_static.zig"
EXEC_PATH = SIMD_DIR / "exec.zig"
MEMORY_PATH = SIMD_DIR / "memory.zig"
EXEC_TEST_PATH = SIMD_DIR / "tests/exec_test.zig"

VECTOR_ALIASES = """
pub const I8x16 = @Vector(16, i8);
pub const U8x16 = @Vector(16, u8);
pub const I16x8 = @Vector(8, i16);
pub const U16x8 = @Vector(8, u16);
pub const I32x4 = @Vector(4, i32);
pub const U32x4 = @Vector(4, u32);
pub const I64x2 = @Vector(2, i64);
pub const U64x2 = @Vector(2, u64);
pub const F32x4 = @Vector(4, f32);
pub const F64x2 = @Vector(2, f64);
"""

TYPE_TO_VEC_ALIAS = {
    ("i8", 16): "I8x16",
    ("u8", 16): "U8x16",
    ("i16", 8): "I16x8",
    ("u16", 8): "U16x8",
    ("i32", 4): "I32x4",
    ("u32", 4): "U32x4",
    ("i64", 2): "I64x2",
    ("u64", 2): "U64x2",
    ("f32", 4): "F32x4",
    ("f64", 2): "F64x2",
}

GENERIC_FUNCS_TO_REMOVE = [
    "splatGeneric",
    "unaryInt",
    "unaryFloat",
    "binaryInt",
    "binaryFloat",
    "compareInt",
    "compareFloat",
    "shiftInt",
    "extaddPairwise",
    "extendHalf",
    "narrow",
    "extmul",
    "truncSatF32x4ToI32x4",
    "truncSatF64x2ToI32x4Zero",
    "convertI32x4ToF32x4",
    "convertLowI32x4ToF64x2",
    "floatMulAddVec",
    "allTrue",
    "bitmask",
]

SPLAT_SCALAR_TYPE = {
    "i8x16": "i8",
    "i16x8": "i16",
    "i32x4": "i32",
    "i64x2": "i64",
    "f32x4": "f32",
    "f64x2": "f64",
}

LOAD_SPLAT_CASES = {
    "v8x16_load_splat": ("u8", "i8", "i8x16Splat"),
    "v16x8_load_splat": ("u16", "i16", "i16x8Splat"),
    "v32x4_load_splat": ("u32", "i32", "i32x4Splat"),
    "v64x2_load_splat": ("u64", "i64", "i64x2Splat"),
}


def opcode_to_fn_name(opcode: str) -> str:
    parts = opcode.split("_")
    return parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:])


def vec_alias(lane_type: str, count: int) -> str:
    return TYPE_TO_VEC_ALIAS[(lane_type, count)]


GENERIC_CALL_RE = re.compile(
    r"ops\.(unaryInt|unaryFloat|binaryInt|binaryFloat|compareInt|compareFloat|"
    r"shiftInt|allTrue|bitmask|extaddPairwise|extendHalf|narrow|extmul|"
    r"truncSatF32x4ToI32x4|truncSatF64x2ToI32x4Zero|convertI32x4ToF32x4|"
    r"convertLowI32x4ToF64x2|floatMulAddVec|splatGeneric)\("
)

SHAPE_LANE = {
    "i8x16": ("i8", 16),
    "i16x8": ("i16", 8),
    "i32x4": ("i32", 4),
    "i64x2": ("i64", 2),
    "f32x4": ("f32", 4),
    "f64x2": ("f64", 2),
}


def opcode_shape(opcode: str) -> tuple[str, int]:
    for prefix, shape in SHAPE_LANE.items():
        if opcode.startswith(prefix + "_") or opcode == prefix:
            return shape
    raise ValueError(f"unknown opcode shape: {opcode}")


def unsigned_lane(lane: str) -> str:
    return {"i8": "u8", "i16": "u16", "i32": "u32", "i64": "u64"}.get(lane, lane)


def spec_from_opcode(opcode: str, generic_fn: str) -> tuple | None:
    lane, count = opcode_shape(opcode)
    if generic_fn == "unaryInt":
        kind = opcode.rsplit("_", 1)[1]
        return ("unaryInt", lane, count, kind)
    if generic_fn == "unaryFloat":
        kind = opcode.rsplit("_", 1)[1]
        return ("unaryFloat", lane, count, kind)
    if generic_fn == "binaryInt":
        if opcode.endswith("_avgr_u"):
            return ("binaryInt", unsigned_lane(lane), count, "avgr_u")
        if "_sat_u" in opcode:
            kind = opcode.split("_sat_")[0].rsplit("_", 1)[1] + "_sat"
            return ("binaryInt", unsigned_lane(lane), count, kind)
        if "_sat_s" in opcode:
            base = opcode.split("_sat_s")[0]
            kind = base.rsplit("_", 1)[1] + "_sat"
            return ("binaryInt", lane, count, kind)
        if opcode.endswith("_u"):
            kind = opcode.rsplit("_", 2)[1]
            return ("binaryInt", unsigned_lane(lane), count, kind)
        if opcode.endswith("_s"):
            kind = opcode.rsplit("_", 2)[1]
            return ("binaryInt", lane, count, kind)
        kind = opcode.rsplit("_", 1)[1]
        return ("binaryInt", lane, count, kind)
    if generic_fn == "binaryFloat":
        if opcode.endswith("_pmin"):
            return ("binaryFloat", lane, count, "pmin")
        if opcode.endswith("_pmax"):
            return ("binaryFloat", lane, count, "pmax")
        if "relaxed_min" in opcode or opcode.endswith("_min"):
            return ("binaryFloat", lane, count, "min")
        if "relaxed_max" in opcode or opcode.endswith("_max"):
            return ("binaryFloat", lane, count, "max")
        kind = opcode.rsplit("_", 1)[1]
        return ("binaryFloat", lane, count, kind)
    if generic_fn == "compareInt":
        if opcode.endswith("_u") or opcode.endswith("_s"):
            cmp_kind = opcode.rsplit("_", 2)[1]
            use_lane = unsigned_lane(lane) if opcode.endswith("_u") else lane
            return ("compareInt", use_lane, count, cmp_kind)
        kind = opcode.rsplit("_", 1)[1]
        return ("compareInt", lane, count, kind)
    if generic_fn == "compareFloat":
        kind = opcode.rsplit("_", 1)[1]
        return ("compareFloat", lane, count, kind)
    if generic_fn == "shiftInt":
        if opcode.endswith("_shr_u"):
            return ("shiftInt", unsigned_lane(lane), count, "shr_u")
        if opcode.endswith("_shr_s"):
            return ("shiftInt", lane, count, "shr_s")
        return ("shiftInt", lane, count, "shl")
    if generic_fn == "allTrue":
        return ("allTrue", lane, count)
    if generic_fn == "bitmask":
        return ("bitmask", lane, count)
    if generic_fn == "extaddPairwise":
        rest = opcode.split("_extadd_pairwise_")[1]
        src_shape, signedness = rest.rsplit("_", 1)
        src_lane = {"i8x16": "i8", "u8x16": "u8", "i16x8": "i16", "u16x8": "u16"}[src_shape]
        return ("extaddPairwise", src_lane, lane, count)
    if generic_fn == "extendHalf":
        rest = opcode.split("_extend_")[1]
        which, rest2 = rest.split("_", 1)
        src_shape = rest2.rsplit("_", 1)[0]
        src_lane = {"i8x16": "i8", "u8x16": "u8", "i16x8": "i16", "u16x8": "u16", "i32x4": "i32", "u32x4": "u32"}[src_shape]
        return ("extendHalf", src_lane, lane, which)
    if generic_fn == "narrow":
        rest = opcode.split("_narrow_")[1]
        src_shape = rest.rsplit("_", 1)[0]
        src_lane = {"i16x8": "i16", "u16x8": "u16", "i32x4": "i32", "u32x4": "u32"}[src_shape]
        half_n = int(src_shape.split("x")[1])
        return ("narrow", src_lane, lane, half_n)
    if generic_fn == "extmul":
        rest = opcode.split("_extmul_")[1]
        which, rest2 = rest.split("_", 1)
        src_shape = rest2.rsplit("_", 1)[0]
        src_lane = {"i8x16": "i8", "u8x16": "u8", "i16x8": "i16", "u16x8": "u16", "i32x4": "i32", "u32x4": "u32"}[src_shape]
        return ("extmul", src_lane, lane, which)
    if generic_fn == "truncSatF32x4ToI32x4":
        return ("truncSatF32x4ToI32x4", opcode.endswith("_s") or opcode.endswith("_s_zero"))
    if generic_fn == "truncSatF64x2ToI32x4Zero":
        return ("truncSatF64x2ToI32x4Zero", "_s_" in opcode or opcode.endswith("_s_zero"))
    if generic_fn == "convertI32x4ToF32x4":
        return ("convertI32x4ToF32x4", opcode.endswith("_s"))
    if generic_fn == "convertLowI32x4ToF64x2":
        return ("convertLowI32x4ToF64x2", opcode.endswith("_s"))
    if generic_fn == "floatMulAddVec":
        return ("floatMulAddVec", lane, count, "nmadd" in opcode)
    return None


def extract_generic_call(line: str) -> tuple[str, str] | None:
    m = GENERIC_CALL_RE.search(line)
    if not m:
        return None
    generic_fn = m.group(1)
    start = m.start()
    depth = 0
    i = line.index("(", start)
    for j in range(i, len(line)):
        if line[j] == "(":
            depth += 1
        elif line[j] == ")":
            depth -= 1
            if depth == 0:
                return generic_fn, line[start : j + 1]
    return None


def parse_exec_calls(text: str) -> list[tuple[str, str, str]]:
    """Return (opcode, generic_fn, full_call) tuples from exec.zig."""
    results: list[tuple[str, str, str]] = []
    arm_re = re.compile(r"^\s*\.([\w,\s.]+)\s*=>")
    skip = {
        "mapBytesUnary", "anyTrue", "unaryI8Popcnt", "demoteF64x2Zero",
        "promoteLowF32x4", "q15mulr", "dotI16x8ToI32x4", "relaxedDotI8x16ToI16x8",
        "relaxedDotAddI8x16ToI32x4", "bitselect", "bytesBinary", "swizzle",
    }
    for line in text.splitlines():
        arm = arm_re.match(line)
        if not arm:
            continue
        opcodes = [o.strip().lstrip(".") for o in arm.group(1).split(",")]
        extracted = extract_generic_call(line)
        if extracted is None:
            continue
        generic_fn, full_call = extracted
        if generic_fn in skip:
            continue
        for opcode in opcodes:
            results.append((opcode, generic_fn, full_call))
    return results


@dataclass(frozen=True)
class StaticFn:
    name: str
    body: str


def gen_unary_int(name: str, lane: str, count: int, kind: str) -> StaticFn:
    vec = vec_alias(lane, count)
    if kind == "abs":
        body = f"""pub fn {name}(value: V128) V128 {{
    const lanes = vecFromV128({lane}, {count}, value);
    const zero: {vec} = @splat(0);
    const results: {vec} = @select({lane}, lanes < zero, zero -% lanes, lanes);
    return v128FromVec({lane}, {count}, results);
}}"""
    else:
        body = f"""pub fn {name}(value: V128) V128 {{
    const lanes = vecFromV128({lane}, {count}, value);
    const zero: {vec} = @splat(0);
    return v128FromVec({lane}, {count}, zero -% lanes);
}}"""
    return StaticFn(name, body)


def gen_unary_float(name: str, lane: str, count: int, kind: str) -> StaticFn:
    vec = vec_alias(lane, count)
    if kind == "nearest":
        body = f"""pub fn {name}(value: V128) V128 {{
    var out = std.mem.zeroes([16]u8);
    inline for (0..{count}) |i| {{
        const lane = readLane({lane}, value.bytes, @intCast(i));
        writeLane({lane}, &out, @intCast(i), helper.nearest(lane));
    }}
    return v128FromBytes(out);
}}"""
    else:
        op_map = {
            "abs": "@abs(lanes)",
            "neg": "-lanes",
            "sqrt": "@sqrt(lanes)",
            "ceil": "@ceil(lanes)",
            "floor": "@floor(lanes)",
            "trunc": "@trunc(lanes)",
        }
        expr = op_map[kind]
        body = f"""pub fn {name}(value: V128) V128 {{
    const lanes = vecFromV128({lane}, {count}, value);
    return v128FromVec({lane}, {count}, {expr});
}}"""
    return StaticFn(name, body)


def gen_binary_int(name: str, lane: str, count: int, kind: str) -> StaticFn:
    vec = vec_alias(lane, count)
    bodies = {
        "add": "a +% b",
        "sub": "a -% b",
        "mul": "a *% b",
        "min": "@select({lane}, a < b, a, b)",
        "max": "@select({lane}, a > b, a, b)",
        "add_sat": "a +| b",
        "sub_sat": "a -| b",
    }
    if kind == "avgr_u":
        body = f"""pub fn {name}(lhs: V128, rhs: V128) V128 {{
    const a = vecFromV128({lane}, {count}, lhs);
    const b = vecFromV128({lane}, {count}, rhs);
    const ShiftT = std.math.Log2Int({lane});
    const shifts: @Vector({count}, ShiftT) = @splat(1);
    return v128FromVec({lane}, {count}, (a | b) - ((a ^ b) >> shifts));
}}"""
    else:
        expr = bodies[kind].format(lane=lane)
        body = f"""pub fn {name}(lhs: V128, rhs: V128) V128 {{
    const a = vecFromV128({lane}, {count}, lhs);
    const b = vecFromV128({lane}, {count}, rhs);
    return v128FromVec({lane}, {count}, {expr});
}}"""
    return StaticFn(name, body)


def gen_binary_float(name: str, lane: str, count: int, kind: str) -> StaticFn:
    if kind in ("min", "max"):
        helper_fn = "helper.min" if kind == "min" else "helper.max"
        body = f"""pub fn {name}(lhs: V128, rhs: V128) V128 {{
    var out = std.mem.zeroes([16]u8);
    inline for (0..{count}) |i| {{
        const lane_a = readLane({lane}, lhs.bytes, @intCast(i));
        const lane_b = readLane({lane}, rhs.bytes, @intCast(i));
        const result: {lane} = {helper_fn}(lane_a, lane_b);
        writeLane({lane}, &out, @intCast(i), result);
    }}
    return v128FromBytes(out);
}}"""
    elif kind == "pmin":
        body = f"""pub fn {name}(lhs: V128, rhs: V128) V128 {{
    const a = vecFromV128({lane}, {count}, lhs);
    const b = vecFromV128({lane}, {count}, rhs);
    return v128FromVec({lane}, {count}, @select({lane}, b < a, b, a));
}}"""
    elif kind == "pmax":
        body = f"""pub fn {name}(lhs: V128, rhs: V128) V128 {{
    const a = vecFromV128({lane}, {count}, lhs);
    const b = vecFromV128({lane}, {count}, rhs);
    return v128FromVec({lane}, {count}, @select({lane}, a < b, b, a));
}}"""
    else:
        op_map = {"add": "a + b", "sub": "a - b", "mul": "a * b", "div": "a / b"}
        body = f"""pub fn {name}(lhs: V128, rhs: V128) V128 {{
    const a = vecFromV128({lane}, {count}, lhs);
    const b = vecFromV128({lane}, {count}, rhs);
    return v128FromVec({lane}, {count}, {op_map[kind]});
}}"""
    return StaticFn(name, body)


def gen_compare_int(name: str, lane: str, count: int, kind: str) -> StaticFn:
    cmp_map = {"eq": "==", "ne": "!=", "lt": "<", "gt": ">", "le": "<=", "ge": ">="}
    body = f"""pub fn {name}(lhs: V128, rhs: V128) V128 {{
    const a = vecFromV128({lane}, {count}, lhs);
    const b = vecFromV128({lane}, {count}, rhs);
    const mask = a {cmp_map[kind]} b;
    return vectorMaskToV128({lane}, {count}, mask);
}}"""
    return StaticFn(name, body)


def gen_compare_float(name: str, lane: str, count: int, kind: str) -> StaticFn:
    return gen_compare_int(name, lane, count, kind)


def gen_shift(name: str, lane: str, count: int, kind: str, unsigned_lane: str | None = None) -> StaticFn:
    read_lane = unsigned_lane or lane
    if kind == "shl":
        body = f"""pub fn {name}(value: V128, amount: u32) V128 {{
    const ShiftT = std.math.Log2Int({lane});
    const shift: ShiftT = @intCast(amount % @bitSizeOf({lane}));
    const lanes = vecFromV128({lane}, {count}, value);
    const shifts: @Vector({count}, ShiftT) = @splat(shift);
    return v128FromVec({lane}, {count}, lanes << shifts);
}}"""
    elif kind == "shr_s":
        body = f"""pub fn {name}(value: V128, amount: u32) V128 {{
    const ShiftT = std.math.Log2Int({lane});
    const shift: ShiftT = @intCast(amount % @bitSizeOf({lane}));
    const lanes = vecFromV128({lane}, {count}, value);
    const shifts: @Vector({count}, ShiftT) = @splat(shift);
    return v128FromVec({lane}, {count}, lanes >> shifts);
}}"""
    else:
        body = f"""pub fn {name}(value: V128, amount: u32) V128 {{
    const ShiftT = std.math.Log2Int({read_lane});
    const shift: ShiftT = @intCast(amount % @bitSizeOf({read_lane}));
    const lanes = vecFromV128({read_lane}, {count}, value);
    const shifts: @Vector({count}, ShiftT) = @splat(shift);
    return v128FromVec({read_lane}, {count}, lanes >> shifts);
}}"""
    return StaticFn(name, body)


def gen_splat(name: str, lane: str, count: int) -> StaticFn:
    vec = vec_alias(lane, count)
    body = f"""pub fn {name}(value: {lane}) V128 {{
    return v128FromVec({lane}, {count}, @as({vec}, @splat(value)));
}}"""
    return StaticFn(name, body)


def gen_all_true(name: str, lane: str, count: int) -> StaticFn:
    vec = vec_alias(lane, count)
    body = f"""pub fn {name}(value: V128) bool {{
    const lanes = vecFromV128({lane}, {count}, value);
    const zero: {vec} = @splat(0);
    return @reduce(.And, lanes != zero);
}}"""
    return StaticFn(name, body)


def gen_bitmask(name: str, lane: str, count: int) -> StaticFn:
    vec = vec_alias(lane, count)
    body = f"""pub fn {name}(value: V128) i32 {{
    const lanes = vecFromV128({lane}, {count}, value);
    const zero: {vec} = @splat(0);
    const sign_bits: @Vector({count}, u1) = @bitCast(lanes < zero);
    const MaskInt = std.meta.Int(.unsigned, {count});
    const mask_uint: MaskInt = @bitCast(sign_bits);
    return @as(i32, @intCast(mask_uint));
}}"""
    return StaticFn(name, body)


def gen_extadd_pairwise(name: str, src: str, dst: str, count: int) -> StaticFn:
    signed = src.startswith("i")
    dst_bits = {"i16": 16, "u16": 16, "i32": 32, "u32": 32}[dst]
    pair_t = f"{'i' if signed else 'u'}{dst_bits}"
    body = f"""pub fn {name}(value: V128) V128 {{
    const PairT = {pair_t};
    const PairVec = @Vector({count}, PairT);
    const pairs = vecFromV128(PairT, {count}, value);
    const bits = @bitSizeOf({src});
    const shift_amt: @Vector({count}, std.math.Log2Int(PairT)) = @splat(bits);
    if ({str(signed).lower()}) {{
        const low: PairVec = (pairs << shift_amt) >> shift_amt;
        const high: PairVec = pairs >> shift_amt;
        return v128FromVec(PairT, {count}, low + high);
    }} else {{
        const mask_val: PairT = (@as(PairT, 1) << @intCast(bits)) - 1;
        const mask: PairVec = @splat(mask_val);
        const low: PairVec = pairs & mask;
        const high: PairVec = pairs >> shift_amt;
        return v128FromVec(PairT, {count}, low + high);
    }}
}}"""
    return StaticFn(name, body)


def gen_extend_half(name: str, src: str, dst: str, which: str) -> StaticFn:
    signed = src.startswith("i")
    src_size = int(re.search(r"\d+", src).group())
    dst_size = int(re.search(r"\d+", dst).group())
    src_lanes = 16 // (src_size // 8)
    dst_lanes = 16 // (dst_size // 8)
    start = 0 if which == "low" else src_lanes // 2
    body = f"""pub fn {name}(value: V128) V128 {{
    var out = std.mem.zeroes([16]u8);
    inline for (0..{dst_lanes}) |i| {{
        const lane = readLane({src}, value.bytes, @intCast({start} + i));
        const result: {dst} = if ({str(signed).lower()}) @as({dst}, lane) else @as({dst}, @intCast(lane));
        writeLane({dst}, &out, @intCast(i), result);
    }}
    return v128FromBytes(out);
}}"""
    return StaticFn(name, body)


def gen_narrow(name: str, src: str, dst: str, half_n: int) -> StaticFn:
    signed = src.startswith("i")
    body = f"""pub fn {name}(lhs: V128, rhs: V128) V128 {{
    var out = std.mem.zeroes([16]u8);
    inline for (0..{half_n}) |i| {{
        writeLane({dst}, &out, @intCast(i), narrowLane({src}, {dst}, readLane({src}, lhs.bytes, @intCast(i)), {str(signed).lower()}));
        writeLane({dst}, &out, @intCast({half_n} + i), narrowLane({src}, {dst}, readLane({src}, rhs.bytes, @intCast(i)), {str(signed).lower()}));
    }}
    return v128FromBytes(out);
}}"""
    return StaticFn(name, body)


def gen_extmul(name: str, src: str, dst: str, which: str) -> StaticFn:
    signed = src.startswith("i")
    src_size = int(re.search(r"\d+", src).group())
    dst_size = int(re.search(r"\d+", dst).group())
    src_lanes = 16 // (src_size // 8)
    dst_lanes = 16 // (dst_size // 8)
    start = 0 if which == "low" else src_lanes // 2
    if signed:
        mul_expr = f"@as({dst}, a) * @as({dst}, b)"
    else:
        mul_expr = f"@as({dst}, @intCast(a)) * @as({dst}, @intCast(b))"
    body = f"""pub fn {name}(lhs: V128, rhs: V128) V128 {{
    var out = std.mem.zeroes([16]u8);
    inline for (0..{dst_lanes}) |i| {{
        const a = readLane({src}, lhs.bytes, @intCast({start} + i));
        const b = readLane({src}, rhs.bytes, @intCast({start} + i));
        const result: {dst} = {mul_expr};
        writeLane({dst}, &out, @intCast(i), result);
    }}
    return v128FromBytes(out);
}}"""
    return StaticFn(name, body)


def gen_trunc_sat_f32x4(name: str, signed: bool) -> StaticFn:
    if signed:
        lane_write = "writeLane(i32, &out, @intCast(i), helper.truncateSaturateInto(i32, lane));"
    else:
        lane_write = """const bits = helper.truncateSaturateInto(u32, lane);
            writeLane(i32, &out, @intCast(i), @bitCast(bits));"""
    body = f"""pub fn {name}(value: V128) V128 {{
    var out = std.mem.zeroes([16]u8);
    inline for (0..4) |i| {{
        const lane = readLane(f32, value.bytes, @intCast(i));
        {lane_write}
    }}
    return v128FromBytes(out);
}}"""
    return StaticFn(name, body)


def gen_trunc_sat_f64x2(name: str, signed: bool) -> StaticFn:
    if signed:
        lane_write = "writeLane(i32, &out, @intCast(i), helper.truncateSaturateInto(i32, lane));"
    else:
        lane_write = """const bits = helper.truncateSaturateInto(u32, lane);
            writeLane(i32, &out, @intCast(i), @bitCast(bits));"""
    body = f"""pub fn {name}(value: V128) V128 {{
    var out = std.mem.zeroes([16]u8);
    inline for (0..2) |i| {{
        const lane = readLane(f64, value.bytes, @intCast(i));
        {lane_write}
    }}
    return v128FromBytes(out);
}}"""
    return StaticFn(name, body)


def gen_convert_i32x4_f32x4(name: str, signed: bool) -> StaticFn:
    if signed:
        lane_write = "writeLane(f32, &out, @intCast(i), @floatFromInt(readLane(i32, value.bytes, @intCast(i))));"
    else:
        lane_write = "writeLane(f32, &out, @intCast(i), @floatFromInt(readLane(u32, value.bytes, @intCast(i))));"
    body = f"""pub fn {name}(value: V128) V128 {{
    var out = std.mem.zeroes([16]u8);
    inline for (0..4) |i| {{
        {lane_write}
    }}
    return v128FromBytes(out);
}}"""
    return StaticFn(name, body)


def gen_convert_low_i32x4_f64x2(name: str, signed: bool) -> StaticFn:
    if signed:
        lane_write = "writeLane(f64, &out, @intCast(i), @floatFromInt(readLane(i32, value.bytes, @intCast(i))));"
    else:
        lane_write = "writeLane(f64, &out, @intCast(i), @floatFromInt(readLane(u32, value.bytes, @intCast(i))));"
    body = f"""pub fn {name}(value: V128) V128 {{
    var out = std.mem.zeroes([16]u8);
    inline for (0..2) |i| {{
        {lane_write}
    }}
    return v128FromBytes(out);
}}"""
    return StaticFn(name, body)


def gen_float_mul_add(name: str, lane: str, count: int, negate_first: bool) -> StaticFn:
    vec = vec_alias(lane, count)
    if negate_first:
        body = f"""pub fn {name}(first: V128, second: V128, third: V128) V128 {{
    var a = vecFromV128({lane}, {count}, first);
    const b = vecFromV128({lane}, {count}, second);
    const c = vecFromV128({lane}, {count}, third);
    a = -a;
    return v128FromVec({lane}, {count}, @mulAdd({vec}, a, b, c));
}}"""
    else:
        body = f"""pub fn {name}(first: V128, second: V128, third: V128) V128 {{
    const a = vecFromV128({lane}, {count}, first);
    const b = vecFromV128({lane}, {count}, second);
    const c = vecFromV128({lane}, {count}, third);
    return v128FromVec({lane}, {count}, @mulAdd({vec}, a, b, c));
}}"""
    return StaticFn(name, body)


def build_static_fn(name: str, parsed: tuple) -> StaticFn:
    kind = parsed[0]
    if kind == "unaryInt":
        return gen_unary_int(name, parsed[1], parsed[2], parsed[3])
    if kind == "unaryFloat":
        return gen_unary_float(name, parsed[1], parsed[2], parsed[3])
    if kind == "binaryInt":
        return gen_binary_int(name, parsed[1], parsed[2], parsed[3])
    if kind == "binaryFloat":
        return gen_binary_float(name, parsed[1], parsed[2], parsed[3])
    if kind == "compareInt":
        return gen_compare_int(name, parsed[1], parsed[2], parsed[3])
    if kind == "compareFloat":
        return gen_compare_float(name, parsed[1], parsed[2], parsed[3])
    if kind == "shiftInt":
        lane, count, sk = parsed[1], parsed[2], parsed[3]
        unsigned = lane if sk == "shr_u" else None
        return gen_shift(name, lane, count, sk, unsigned)
    if kind == "allTrue":
        return gen_all_true(name, parsed[1], parsed[2])
    if kind == "bitmask":
        return gen_bitmask(name, parsed[1], parsed[2])
    if kind == "extaddPairwise":
        return gen_extadd_pairwise(name, parsed[1], parsed[2], parsed[3])
    if kind == "extendHalf":
        return gen_extend_half(name, parsed[1], parsed[2], parsed[3])
    if kind == "narrow":
        return gen_narrow(name, parsed[1], parsed[2], parsed[3])
    if kind == "extmul":
        return gen_extmul(name, parsed[1], parsed[2], parsed[3])
    if kind == "truncSatF32x4ToI32x4":
        return gen_trunc_sat_f32x4(name, parsed[1])
    if kind == "truncSatF64x2ToI32x4Zero":
        return gen_trunc_sat_f64x2(name, parsed[1])
    if kind == "convertI32x4ToF32x4":
        return gen_convert_i32x4_f32x4(name, parsed[1])
    if kind == "convertLowI32x4ToF64x2":
        return gen_convert_low_i32x4_f64x2(name, parsed[1])
    if kind == "floatMulAddVec":
        return gen_float_mul_add(name, parsed[1], parsed[2], parsed[3])
    if kind == "splatGeneric":
        return gen_splat(name, parsed[1], parsed[2])
    raise ValueError(f"unknown parsed kind {kind}")


def collect_static_functions(exec_text: str) -> tuple[dict[str, StaticFn], dict[str, str]]:
    """Return fn_name->StaticFn and full_call->replacement_call."""
    functions: dict[str, StaticFn] = {}
    replacements: dict[str, str] = {}

    for opcode, generic_fn, full_call in parse_exec_calls(exec_text):
        parsed = spec_from_opcode(opcode, generic_fn)
        if parsed is None:
            continue
        fn_name = opcode_to_fn_name(opcode)
        if fn_name not in functions:
            functions[fn_name] = build_static_fn(fn_name, parsed)
        # build replacement call
        if generic_fn in ("unaryInt", "unaryFloat", "allTrue", "bitmask",
                          "extaddPairwise", "extendHalf",
                          "truncSatF32x4ToI32x4", "truncSatF64x2ToI32x4Zero",
                          "convertI32x4ToF32x4", "convertLowI32x4ToF64x2"):
            new_call = f"ops.{fn_name}(sv2v(src))"
        elif generic_fn == "shiftInt":
            new_call = f"ops.{fn_name}(sv2v(lhs), amount)"
        elif generic_fn == "floatMulAddVec":
            new_call = f"ops.{fn_name}(sv2v(first), sv2v(second), sv2v(third))"
        else:
            new_call = f"ops.{fn_name}(sv2v(lhs), sv2v(rhs))"
        replacements[full_call] = new_call

    # splatScalar in exec.zig
    for shape, lane in SPLAT_SCALAR_TYPE.items():
        fn_name = f"{shape}Splat"
        if fn_name not in functions:
            count = {"i8x16": 16, "i16x8": 8, "i32x4": 4, "i64x2": 2, "f32x4": 4, "f64x2": 2}[shape]
            functions[fn_name] = gen_splat(fn_name, lane, count)
        old = f"ops.splatGeneric({lane}, {count}, scalar.readAs({lane}))"
        new = f"ops.{fn_name}(scalar.readAs({lane}))"
        replacements[old] = new

    return functions, replacements


def gen_ops_static(functions: dict[str, StaticFn], *, for_inline: bool) -> str:
    lines: list[str] = []
    if not for_inline:
        lines.extend([
            "// Auto-generated by scripts/gen_simd_static.py — do not edit.",
            "const std = @import(\"std\");",
            "const helper = @import(\"../value/helper.zig\");",
            "const base = @import(\"ops.zig\");",
            "",
            "const V128 = base.V128;",
            "const vecFromV128 = base.vecFromV128;",
            "const v128FromVec = base.v128FromVec;",
            "const vectorMaskToV128 = base.vectorMaskToV128;",
            "const v128FromBytes = base.v128FromBytes;",
            "const readLane = base.readLane;",
            "const writeLane = base.writeLane;",
            "const narrowLane = base.narrowLane;",
            "",
        ])
    else:
        lines.extend([
            "",
            "// --- Static SIMD ops (generated by scripts/gen_simd_static.py) ---",
            "",
        ])
    for name in sorted(functions.keys()):
        lines.append(functions[name].body)
        lines.append("")
    return "\n".join(lines)


def patch_ops_zig(text: str, static_inline: str) -> str:
    # Add vector aliases after V128
    if "pub const I8x16" not in text:
        text = text.replace(
            "pub const V128 = vec.V128;\n",
            "pub const V128 = vec.V128;\n" + VECTOR_ALIASES + "\n",
        )

    # Remove generic template functions
    for fn_name in GENERIC_FUNCS_TO_REMOVE:
        pattern = rf"///[^\n]*\n(?:///[^\n]*\n)*pub fn {fn_name}\([^\{{]*\{{[\s\S]*?\n\}}\n\n"
        text = re.sub(pattern, "", text)
        pattern2 = rf"pub fn {fn_name}\([^\{{]*\{{[\s\S]*?\n\}}\n\n"
        text = re.sub(pattern2, "", text, count=1)

    # Make narrowLane visible to generated narrow helpers.
    text = text.replace("fn narrowLane(", "pub fn narrowLane(")

    # Remove prior generated block / usingnamespace if re-running.
    text = re.sub(r"\n// --- Static SIMD ops \(generated[^\n]*\n[\s\S]*$", "\n", text)
    text = re.sub(r"\n\npub usingnamespace @import\(\"ops_static\.zig\"\);\n?", "\n", text)

    text = text.rstrip() + static_inline
    return text + "\n"


def apply_replacements(text: str, replacements: dict[str, str]) -> str:
    for old, new in sorted(replacements.items(), key=lambda x: -len(x[0])):
        text = text.replace(old, new)
    return text


def patch_memory_zig(text: str) -> str:
    # Replace loadSplat generic helper with static splat calls
    old_load_splat = """/// Splat load: loads a single scalar from memory and broadcasts it to all lanes.
fn loadSplat(comptime SrcT: type, comptime DstT: type, comptime N: usize, slice: []const u8) V128 {
    var tmp = std.mem.zeroes([16]u8);
    @memcpy(tmp[0..slice.len], slice);
    const lane = ops.readLane(SrcT, tmp, 0);
    return ops.splatGeneric(DstT, N, @as(DstT, @bitCast(lane)));
}"""

    new_helpers = []
    for opcode, (src_t, dst_t, fn_name) in LOAD_SPLAT_CASES.items():
        shape = fn_name.replace("Splat", "")
        helper_name = f"loadSplat{shape[0].upper()}{shape[1:]}"
        new_helpers.append(f"""fn {helper_name}(slice: []const u8) V128 {{
    var tmp = std.mem.zeroes([16]u8);
    @memcpy(tmp[0..slice.len], slice);
    const lane = ops.readLane({src_t}, tmp, 0);
    return ops.{fn_name}(@as({dst_t}, @bitCast(lane)));
}}""")

    text = text.replace(old_load_splat, "/// Splat load: loads a single scalar from memory and broadcasts it to all lanes.\n" + "\n\n".join(new_helpers))

    for opcode, (_, _, fn_name) in LOAD_SPLAT_CASES.items():
        shape = fn_name.replace("Splat", "")
        helper_name = f"loadSplat{shape[0].upper()}{shape[1:]}"
        text = re.sub(
            rf"\.{opcode} => loadSplat\(\w+,\s*\w+,\s*\d+,\s*",
            f".{opcode} => {helper_name}(",
            text,
        )
    return text


def patch_exec_test(text: str) -> str:
    text = text.replace("ops.splatGeneric(i32, 4, 3)", "ops.i32x4Splat(3)")
    text = text.replace("ops.splatGeneric(i32, 4, 4)", "ops.i32x4Splat(4)")
    text = text.replace("ops.splatGeneric(i16, 8, 0)", "ops.i16x8Splat(0)")
    return text


def main() -> None:
    exec_text = EXEC_PATH.read_text()
    functions, replacements = collect_static_functions(exec_text)

    static_inline = gen_ops_static(functions, for_inline=True)
    OPS_STATIC_PATH.write_text(gen_ops_static(functions, for_inline=False))
    OPS_PATH.write_text(patch_ops_zig(OPS_PATH.read_text(), static_inline))
    EXEC_PATH.write_text(apply_replacements(exec_text, replacements))
    MEMORY_PATH.write_text(patch_memory_zig(MEMORY_PATH.read_text()))
    EXEC_TEST_PATH.write_text(patch_exec_test(EXEC_TEST_PATH.read_text()))

    print(f"Generated {len(functions)} static functions in {OPS_STATIC_PATH.name}")
    print(f"Patched: {OPS_PATH.name}, {EXEC_PATH.name}, {MEMORY_PATH.name}, {EXEC_TEST_PATH.name}")


if __name__ == "__main__":
    main()

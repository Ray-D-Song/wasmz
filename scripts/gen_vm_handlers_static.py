#!/usr/bin/env python3
"""Expand comptime VM handler templates into static implementations."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ROOT_ZIG = ROOT / "src/vm/handlers/root.zig"

I32_INT_CMP = [
    ("eq", "==", "i32", "i32"),
    ("ne", "!=", "i32", "i32"),
    ("lt_s", "<", "i32", "i32"),
    ("lt_u", "<", "u32", "u32"),
    ("gt_s", ">", "i32", "i32"),
    ("gt_u", ">", "u32", "u32"),
    ("le_s", "<=", "i32", "i32"),
    ("le_u", "<=", "u32", "u32"),
    ("ge_s", ">=", "i32", "i32"),
    ("ge_u", ">=", "u32", "u32"),
]

I64_INT_CMP = [
    ("eq", "==", "i64", "i64"),
    ("ne", "!=", "i64", "i64"),
    ("lt_s", "<", "i64", "i64"),
    ("lt_u", "<", "u64", "u64"),
    ("gt_s", ">", "i64", "i64"),
    ("gt_u", ">", "u64", "u64"),
    ("le_s", "<=", "i64", "i64"),
    ("le_u", "<=", "u64", "u64"),
    ("ge_s", ">=", "i64", "i64"),
    ("ge_u", ">=", "u64", "u64"),
]

F32_CMP = [("eq", "=="), ("ne", "!="), ("lt", "<"), ("gt", ">"), ("le", "<="), ("ge", ">=")]
F64_CMP = F32_CMP


def cmp_result(lt: str, rt: str, op: str) -> str:
    return f"@as(i32, if (slots[ops.lhs].readAs({lt}) {op} slots[ops.rhs].readAs({rt})) 1 else 0)"


def cmp_imm_result(prefix: str, suffix: str, lt: str, op: str) -> str:
    if suffix.endswith("_u") and prefix in ("i32", "i64"):
        ut = "u32" if prefix == "i32" else "u64"
        imm = f"@as({ut}, @bitCast(ops.imm))"
        return f"slots[ops.lhs].readAs({lt}) {op} {imm}"
    return f"slots[ops.lhs].readAs({lt}) {op} ops.imm"


def gen_i32_binop(name: str, expr: str) -> str:
    return f"""pub fn handle_i32_{name}(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {{
    dispatch.countOp("misc");
    _ = r0;
    const ops = readOps(encode.ops.OpsDstLhsRhs, ip);
    const result = {expr};
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstLhsRhs), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}}
"""


def gen_cmp(prefix: str, suffix: str, lt: str, rt: str, op: str) -> str:
    return f"""pub fn handle_{prefix}_{suffix}(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {{
    dispatch.countOp("cmp");
    const ops = readOps(encode.ops.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from({cmp_result(lt, rt, op)});
    dispatch.next(ip, stride(encode.ops.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}}
"""


def gen_cmp_to_local(prefix: str, suffix: str, lt: str, rt: str, op: str) -> str:
    return f"""pub fn handle_{prefix}_{suffix}_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {{
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.ops.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from({cmp_result(lt, rt, op)});
    dispatch.next(ip, stride(encode.ops.OpsCmpToLocal), slots, frame, env, r0, fp0);
}}
"""


def gen_cmp_jump(prefix: str, suffix: str, lt: str, rt: str, op: str, taken_when: str, count: str = "jump") -> str:
    branch = "if_false" if taken_when == "false" else "if_true"
    taken_expr = cmp_result(lt, rt, op).replace("@as(i32, if (", "if (").replace(") 1 else 0)", ")")
    if taken_when == "false":
        cond = f"!({taken_expr.replace('@as(i32, ', '').replace(') 1 else 0', '')})"
        # simpler: use taken variable
        taken = f"slots[ops.lhs].readAs({lt}) {op} slots[ops.rhs].readAs({rt})"
        cond = f"!({taken})"
    else:
        taken = f"slots[ops.lhs].readAs({lt}) {op} slots[ops.rhs].readAs({rt})"
        cond = taken
    return f"""pub fn handle_{prefix}_{suffix}_jump_{branch}(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {{
    dispatch.countOp("{count}");
    const ops = readOps(encode.ops.OpsCompareJump, ip);
    const taken = {taken};
    if ({'!' if taken_when == 'false' else ''}taken) {{
        const target_ip: [*]u8 = @ptrFromInt(@intFromPtr(ip) +% @as(usize, @bitCast(@as(isize, ops.rel_target))));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    }} else {{
        dispatch.next(ip, stride(encode.ops.OpsCompareJump), slots, frame, env, r0, fp0);
    }}
}}
"""


def gen_cmp_imm_jump(prefix: str, suffix: str, lt: str, op: str, taken_when: str, ops_type: str) -> str:
    branch = "if_false" if taken_when == "false" else "if_true"
    taken = cmp_imm_result(prefix, suffix, lt, op)
    return f"""pub fn handle_{prefix}_{suffix}_imm_jump_{branch}(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {{
    dispatch.countOp("jump");
    const ops = readOps(encode.ops.{ops_type}, ip);
    const taken = {taken};
    if ({'!' if taken_when == 'false' else ''}taken) {{
        const target_ip: [*]u8 = @ptrFromInt(@intFromPtr(ip) +% @as(usize, @bitCast(@as(isize, ops.rel_target))));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    }} else {{
        dispatch.next(ip, stride(encode.ops.{ops_type}), slots, frame, env, r0, fp0);
    }}
}}
"""


def gen_float_cmp(prefix: str, suffix: str, op: str) -> str:
    t = "f32" if prefix == "f32" else "f64"
    return gen_cmp(prefix, suffix, t, t, op)


def gen_float_cmp_to_local(prefix: str, suffix: str, op: str) -> str:
    t = "f32" if prefix == "f32" else "f64"
    return gen_cmp_to_local(prefix, suffix, t, t, op)


def gen_float_cmp_jump(prefix: str, suffix: str, op: str, taken_when: str) -> str:
    t = "f32" if prefix == "f32" else "f64"
    return gen_cmp_jump(prefix, suffix, t, t, op, taken_when)


TEMPLATE_PATTERNS = [
    r"fn binOpI32\([\s\S]*?\n\}\n\n",
    r"fn cmpI32\([\s\S]*?\n\}\n\n",
    r"fn cmpI64\([\s\S]*?\n\}\n\n",
    r"fn cmpI32ToLocal\([\s\S]*?\n\}\n\n",
    r"fn cmpI64ToLocal\([\s\S]*?\n\}\n\n",
    r"inline fn cmpF32ToLocal\([\s\S]*?\n\}\n\n",
    r"inline fn cmpF64ToLocal\([\s\S]*?\n\}\n\n",
    r"fn cmpF32\([\s\S]*?\n\}\n\n",
    r"fn cmpF64\([\s\S]*?\n\}\n\n",
    r"inline fn cmpJumpI32\([\s\S]*?\n\}\n\n",
    r"inline fn cmpJumpI32True\([\s\S]*?\n\}\n\n",
    r"inline fn cmpJumpI64\([\s\S]*?\n\}\n\n",
    r"inline fn cmpJumpI64True\([\s\S]*?\n\}\n\n",
    r"inline fn cmpJumpF32False\([\s\S]*?\n\}\n\n",
    r"inline fn cmpJumpF64False\([\s\S]*?\n\}\n\n",
    r"inline fn cmpJumpF32True\([\s\S]*?\n\}\n\n",
    r"inline fn cmpJumpF64True\([\s\S]*?\n\}\n\n",
    r"inline fn cmpImmJumpI32\([\s\S]*?\n\}\n\n",
    r"inline fn cmpImmJumpI64\([\s\S]*?\n\}\n\n",
    r"inline fn cmpImmJumpI32True\([\s\S]*?\n\}\n\n",
    r"inline fn cmpImmJumpI64True\([\s\S]*?\n\}\n\n",
    r"inline fn cmpImmJumpF32False\([\s\S]*?\n\}\n\n",
    r"inline fn cmpImmJumpF64False\([\s\S]*?\n\}\n\n",
    r"inline fn cmpImmJumpF32True\([\s\S]*?\n\}\n\n",
    r"inline fn cmpImmJumpF64True\([\s\S]*?\n\}\n\n",
]


def replace_handler_block(text: str, name: str, body: str) -> str:
    pattern = rf"pub fn {re.escape(name)}\([^\)]*\) callconv\(\.c\) void \{{[\s\S]*?\n\}}\n"
    return re.sub(pattern, body + "\n", text, count=1)


def main() -> None:
    text = ROOT_ZIG.read_text()

    # i32 add/sub/mul
    for name, expr in (
        ("add", "slots[ops.lhs].readAs(i32) +% slots[ops.rhs].readAs(i32)"),
        ("sub", "slots[ops.lhs].readAs(i32) -% slots[ops.rhs].readAs(i32)"),
        ("mul", "slots[ops.lhs].readAs(i32) *% slots[ops.rhs].readAs(i32)"),
    ):
        text = replace_handler_block(text, f"handle_i32_{name}", gen_i32_binop(name, expr))

    for suffix, op, lt, rt in I32_INT_CMP:
        text = replace_handler_block(text, f"handle_i32_{suffix}", gen_cmp("i32", suffix, lt, rt, op))
        text = replace_handler_block(text, f"handle_i32_{suffix}_to_local", gen_cmp_to_local("i32", suffix, lt, rt, op))
        text = replace_handler_block(text, f"handle_i32_{suffix}_jump_if_false", gen_cmp_jump("i32", suffix, lt, rt, op, "false"))
        text = replace_handler_block(text, f"handle_i32_{suffix}_jump_if_true", gen_cmp_jump("i32", suffix, lt, rt, op, "true"))

    for suffix, op, lt, rt in I64_INT_CMP:
        text = replace_handler_block(text, f"handle_i64_{suffix}", gen_cmp("i64", suffix, lt, rt, op))
        text = replace_handler_block(text, f"handle_i64_{suffix}_to_local", gen_cmp_to_local("i64", suffix, lt, rt, op))
        text = replace_handler_block(text, f"handle_i64_{suffix}_jump_if_false", gen_cmp_jump("i64", suffix, lt, rt, op, "false"))
        text = replace_handler_block(text, f"handle_i64_{suffix}_jump_if_true", gen_cmp_jump("i64", suffix, lt, rt, op, "true"))

    for suffix, op in F32_CMP:
        text = replace_handler_block(text, f"handle_f32_{suffix}", gen_float_cmp("f32", suffix, op))
        text = replace_handler_block(text, f"handle_f32_{suffix}_to_local", gen_float_cmp_to_local("f32", suffix, op))
        text = replace_handler_block(text, f"handle_f32_{suffix}_jump_if_false", gen_float_cmp_jump("f32", suffix, op, "false"))
        text = replace_handler_block(text, f"handle_f32_{suffix}_jump_if_true", gen_float_cmp_jump("f32", suffix, op, "true"))

    for suffix, op in F64_CMP:
        text = replace_handler_block(text, f"handle_f64_{suffix}", gen_float_cmp("f64", suffix, op))
        text = replace_handler_block(text, f"handle_f64_{suffix}_to_local", gen_float_cmp_to_local("f64", suffix, op))
        text = replace_handler_block(text, f"handle_f64_{suffix}_jump_if_false", gen_float_cmp_jump("f64", suffix, op, "false"))
        text = replace_handler_block(text, f"handle_f64_{suffix}_jump_if_true", gen_float_cmp_jump("f64", suffix, op, "true"))

    ops_type_i32 = "OpsCompareImmJump"
    ops_type_i64 = "OpsCompareImmJump64"
    ops_type_f32 = "OpsCompareImmJumpF32"
    ops_type_f64 = "OpsCompareImmJumpF64"
    for suffix, op, lt, _ in I32_INT_CMP:
        text = replace_handler_block(text, f"handle_i32_{suffix}_imm_jump_if_false", gen_cmp_imm_jump("i32", suffix, lt, op, "false", ops_type_i32))
        text = replace_handler_block(text, f"handle_i32_{suffix}_imm_jump_if_true", gen_cmp_imm_jump("i32", suffix, lt, op, "true", ops_type_i32))
    for suffix, op, lt, _ in I64_INT_CMP:
        text = replace_handler_block(text, f"handle_i64_{suffix}_imm_jump_if_false", gen_cmp_imm_jump("i64", suffix, lt, op, "false", ops_type_i64))
        text = replace_handler_block(text, f"handle_i64_{suffix}_imm_jump_if_true", gen_cmp_imm_jump("i64", suffix, lt, op, "true", ops_type_i64))
    for suffix, op in F32_CMP:
        text = replace_handler_block(text, f"handle_f32_{suffix}_imm_jump_if_false", gen_cmp_imm_jump("f32", suffix, "f32", op, "false", ops_type_f32))
        text = replace_handler_block(text, f"handle_f32_{suffix}_imm_jump_if_true", gen_cmp_imm_jump("f32", suffix, "f32", op, "true", ops_type_f32))
    for suffix, op in F64_CMP:
        text = replace_handler_block(text, f"handle_f64_{suffix}_imm_jump_if_false", gen_cmp_imm_jump("f64", suffix, "f64", op, "false", ops_type_f64))
        text = replace_handler_block(text, f"handle_f64_{suffix}_imm_jump_if_true", gen_cmp_imm_jump("f64", suffix, "f64", op, "true", ops_type_f64))

    for pat in TEMPLATE_PATTERNS:
        text = re.sub(pat, "", text, count=1)

    text = re.sub(
        r"/// Read the operand struct for an instruction\.[\s\S]*?inline fn stride\(comptime OpsT: type\) usize \{[\s\S]*?\n\}\n",
        "const readOps = common.readOps;\nconst stride = common.stride;\n",
        text,
        count=1,
    )

    ROOT_ZIG.write_text(text)
    print(f"Patched {ROOT_ZIG}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""One-shot generator for comptime static expansion. Output is committed source."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# IR fields with _imm suffix (from ir.zig)
IMM_OPS = {
    "i32_add", "i32_sub", "i32_mul", "i32_and", "i32_or", "i32_xor",
    "i32_shl", "i32_shr_s", "i32_shr_u",
    "i32_eq", "i32_ne", "i32_lt_s", "i32_lt_u", "i32_gt_s", "i32_gt_u", "i32_le_s", "i32_le_u", "i32_ge_s", "i32_ge_u",
    "i64_add", "i64_sub", "i64_mul", "i64_and", "i64_or", "i64_xor",
    "i64_shl", "i64_shr_s", "i64_shr_u",
    "i64_eq", "i64_ne", "i64_lt_s", "i64_lt_u", "i64_gt_s", "i64_gt_u", "i64_le_s", "i64_le_u", "i64_ge_s", "i64_ge_u",
    "f32_add", "f32_sub", "f32_mul", "f32_div",
    "f64_add", "f64_sub", "f64_mul", "f64_div",
}

IMM_R_OPS = {
    "i32_add", "i32_sub", "i32_mul", "i32_and", "i32_or", "i32_xor",
    "i32_shl", "i32_shr_s", "i32_shr_u",
    "i64_add", "i64_sub", "i64_mul", "i64_and", "i64_or", "i64_xor",
    "i64_shl", "i64_shr_s", "i64_shr_u",
}

R_OPS = IMM_R_OPS | {"f32_add", "f32_sub", "f32_mul", "f32_div", "f64_add", "f64_sub", "f64_mul", "f64_div"}


def snake_to_camel(name: str) -> str:
    parts = name.split("_")
    return parts[0] + "".join(p.capitalize() for p in parts[1:])


def zig_type(op: str) -> str:
    if op.startswith("i32_"):
        return "i32"
    if op.startswith("i64_"):
        return "i64"
    if op.startswith("f32_"):
        return "f32"
    if op.startswith("f64_"):
        return "f64"
    raise ValueError(op)


def acc_kind(op: str) -> str:
    t = zig_type(op)
    if t in ("f32", "f64"):
        return "fp0"
    return "r0"


def const_tag(t: str) -> str:
    return f"const_{t}"


def unsigned_type(t: str) -> str:
    return {"i32": "u32", "i64": "u64", "f32": "u32", "f64": "u64"}[t]


def fold_binary_body(op: str, t: str) -> str:
    l = "lhs_val"
    r = "rhs_val"
    ut = unsigned_type(t)
    lu, ru = f"@as({ut}, @bitCast({l}))", f"@as({ut}, @bitCast({r}))"

    def br(expr: str) -> str:
        return f"break :blk {expr};"

    cases = {
        "add": br(f"{l} +% {r}"),
        "sub": br(f"{l} -% {r}"),
        "mul": br(f"{l} *% {r}"),
        "and": br(f"@bitCast({lu} & {ru})"),
        "or": br(f"@bitCast({lu} | {ru})"),
        "xor": br(f"@bitCast({lu} ^ {ru})"),
    }
    suffix = op.split("_", 1)[1]
    if suffix in cases:
        return cases[suffix]

    if t in ("i32", "i64"):
        mask = "31" if t == "i32" else "63"
        if suffix == "shl":
            return br(f"@bitCast({lu} << @intCast({ru} & {mask}))")
        if suffix == "shr_u":
            return br(f"@bitCast({lu} >> @intCast({ru} & {mask}))")
        if suffix == "shr_s":
            return br(f"{l} >> @intCast({ru} & {mask})")
        if suffix == "rotl":
            ut = "u32" if t == "i32" else "u64"
            return br(f"@bitCast(std.math.rotl({ut}, {lu}, {ru} & {mask}))")
        if suffix == "rotr":
            ut = "u32" if t == "i32" else "u64"
            return br(f"@bitCast(std.math.rotr({ut}, {lu}, {ru} & {mask}))")
        if suffix == "div_s":
            min_int = "std.math.minInt(i32)" if t == "i32" else "std.math.minInt(i64)"
            cast = "@intCast(@divTrunc(lhs_val, rhs_val))"
            return f"""if (rhs_val == 0 or (lhs_val == {min_int} and rhs_val == -1)) break :blk null;
        break :blk {cast};"""
        if suffix == "div_u":
            return f"""if ({ru} == 0) break :blk null;
        break :blk @bitCast({lu} / {ru});"""
        if suffix == "rem_s":
            return f"""if (rhs_val == 0) break :blk null;
        if (lhs_val == {'std.math.minInt(i32)' if t == 'i32' else 'std.math.minInt(i64)'} and rhs_val == -1) break :blk 0;
        break :blk @intCast(@rem(lhs_val, rhs_val));"""
        if suffix == "rem_u":
            return f"""if ({ru} == 0) break :blk null;
        break :blk @bitCast({lu} % {ru});"""

    return "break :blk null;"


def identity_annihilator_i32(op: str) -> tuple[str, str]:
    suffix = op.split("_", 1)[1]
    identity = """if (imm == 0) {
            self.recycle_slot(dst);
            try self.stack.push(self.allocator, lhs);
            return true;
        }"""
    if suffix in ("add", "sub", "or", "xor", "shl", "shr_s", "shr_u", "rotl", "rotr"):
        return identity, ""
    if suffix == "mul":
        return """if (imm == 1) {
            self.recycle_slot(dst);
            try self.stack.push(self.allocator, lhs);
            return true;
        }""", """if (imm == 0) {
            _ = self.compiled.ops.pop();
            try self.emit(.{ .const_i32 = .{ .dst = dst, .value = 0 } });
            try self.stack.push(self.allocator, dst);
            return true;
        }"""
    if suffix == "and":
        return """if (imm == -1) {
            self.recycle_slot(dst);
            try self.stack.push(self.allocator, lhs);
            return true;
        }""", """if (imm == 0) {
            _ = self.compiled.ops.pop();
            try self.emit(.{ .const_i32 = .{ .dst = dst, .value = 0 } });
            try self.stack.push(self.allocator, dst);
            return true;
        }"""
    if suffix in ("div_s", "div_u"):
        return """if (imm == 1) {
            self.recycle_slot(dst);
            try self.stack.push(self.allocator, lhs);
            return true;
        }""", ""
    return "", ""


def identity_annihilator_i64(op: str) -> tuple[str, str]:
    ident, annih = identity_annihilator_i32(op)
    return ident.replace("const_i32", "const_i64"), annih.replace("const_i32", "const_i64")


def gen_try_fold_binary(op: str) -> str:
    t = zig_type(op)
    fn = f"try_fold_{op}_const"
    body = fold_binary_body(op, t)
    ct = const_tag(t)
    return f"""    fn {fn}(self: *Lower, lhs: Slot, rhs: Slot, dst: Slot) !bool {{
        const ops = self.compiled.ops.items;
        if (ops.len < 2) return false;
        const rhs_op = ops[ops.len - 1];
        const lhs_op = ops[ops.len - 2];
        const rhs_val: {t} = switch (rhs_op) {{
            .{ct} => |c| if (c.dst == rhs) c.value else return false,
            else => return false,
        }};
        const lhs_val: {t} = switch (lhs_op) {{
            .{ct} => |c| if (c.dst == lhs) c.value else return false,
            else => return false,
        }};
        const result: ?{t} = blk: {{
            {body}
        }};
        if (result) |val| {{
            _ = self.compiled.ops.pop();
            _ = self.compiled.ops.pop();
            try self.emit(.{{ .{ct} = .{{ .dst = dst, .value = val }} }});
            return true;
        }}
        return false;
    }}
"""


def gen_try_simplify_imm(op: str) -> str | None:
    t = zig_type(op)
    if t not in ("i32", "i64"):
        return None
    fn = f"try_simplify_{op}_imm"
    ident, annih = identity_annihilator_i32(op) if t == "i32" else identity_annihilator_i64(op)
    strength = ""
    suffix = op.split("_", 1)[1]
    ct = const_tag(t)
    imm_u = "@bitCast(imm)"
    if suffix == "mul":
        strength = f"""
        if (imm_u != 0 and (imm_u & (imm_u -{'% 1' if t == 'i32' else '% 1'})) == 0) {{
            const shift: {t} = @intCast(@ctz(imm_u));
            _ = self.compiled.ops.pop();
            try self.emit(.{{ .{op}_imm = .{{ .dst = dst, .lhs = lhs, .imm = shift }} }});
            try self.stack.push(self.allocator, dst);
            return true;
        }}"""
    if suffix == "div_u":
        strength = f"""
        if (imm_u != 0 and (imm_u & (imm_u -{'% 1' if t == 'i32' else '% 1'})) == 0) {{
            const shift: {t} = @intCast(@ctz(imm_u));
            _ = self.compiled.ops.pop();
            try self.emit(.{{ .{op.replace('div_u', 'shr_u')}_imm = .{{ .dst = dst, .lhs = lhs, .imm = shift }} }});
            try self.stack.push(self.allocator, dst);
            return true;
        }}"""

    parts = []
    if ident:
        parts.append(ident)
    if annih:
        parts.append(annih)
    if not parts and not strength:
        return None

    simplify_body = "\n        ".join(parts)
    ut = unsigned_type(t)
    imm_u_decl = f"const imm_u: {ut} = @bitCast(imm);\n        " if strength else ""
    return f"""    fn {fn}(self: *Lower, lhs: Slot, imm: {t}, dst: Slot) !bool {{
        {imm_u_decl}{simplify_body}
        {strength}
        return false;
    }}
"""


def gen_lower_binary(op: str) -> str:
    fn = snake_to_camel(f"lower_{op}")
    t = zig_type(op)
    acc = acc_kind(op)
    prev_acc = "prev_fp0" if acc == "fp0" else "prev_r0"
    other_prev = "prev_r0" if acc == "fp0" else "prev_fp0"
    has_imm = op in IMM_OPS
    has_r = op in R_OPS
    can_fold = t in ("i32", "i64")
    fold_call = f"if (try self.try_fold_{op}_const(lhs, rhs, dst)) {{\n            try self.stack.push(self.allocator, dst);\n            return;\n        }}\n        " if can_fold else ""

    imm_block = ""
    if has_imm:
        ct = const_tag(t)
        imm_r_block = ""
        if op in IMM_R_OPS:
            imm_r_block = f"""
                        if ({prev_acc}) |acc| {{
                            if (acc == lhs) {{
                                try self.emit(.{{ .{op}_imm_r = .{{ .dst = dst, .imm = c.value }} }});
                                self.{acc}_slot = dst;
                                try self.stack.push(self.allocator, dst);
                                return;
                            }}
                        }}"""
        simplify_call = ""
        if can_fold and gen_try_simplify_imm(op):
            simplify_call = f"""
                        if (try self.try_simplify_{op}_imm(lhs, c.value, dst)) {{
                            self.r0_slot = null;
                            return;
                        }}"""
        imm_block = f"""
        const ops_buf = self.compiled.ops.items;
        if (ops_buf.len > 0) {{
            switch (ops_buf[ops_buf.len - 1]) {{
                .{ct} => |c| if (c.dst == rhs) {{{simplify_call}
                        _ = self.compiled.ops.pop();{imm_r_block}
                        try self.emit(.{{ .{op}_imm = .{{ .dst = dst, .lhs = lhs, .imm = c.value }} }});
                        self.{acc}_slot = dst;
                        try self.stack.push(self.allocator, dst);
                        return;
                    }},
                else => {{}},
            }}
        }}"""

    r_block = ""
    if has_r:
        r_block = f"""
        if ({prev_acc}) |acc| {{
            if (acc == lhs) {{
                try self.emit(.{{ .{op}_r = .{{ .dst = dst, .rhs = rhs }} }});
                self.{acc}_slot = dst;
                try self.stack.push(self.allocator, dst);
                return;
            }}
        }}"""

    fold_fn = f"try_fold_{op}_const"
    discard = []
    if not has_r or acc == "fp0":
        discard.append("_ = prev_r0;")
    if not has_r or acc == "r0":
        discard.append("_ = prev_fp0;")
    discard_lines = "\n        ".join(discard)
    return f"""    pub fn {fn}(self: *Lower, prev_r0: ?Slot, prev_fp0: ?Slot) !void {{
        {discard_lines}
        self.r0_slot = null;
        self.fp0_slot = null;
        const rhs = try self.pop_slot();
        const lhs = try self.pop_slot();
        const dst = self.alloc_slot();
        {fold_call}{imm_block}{r_block}
        self.{acc}_slot = dst;
        try self.emit(.{{ .{op} = .{{ .dst = dst, .lhs = lhs, .rhs = rhs }} }});
        try self.stack.push(self.allocator, dst);
    }}
"""


def cmp_fold_body(op: str) -> str:
    t = zig_type(op)
    suffix = op.split("_", 1)[1]
    l, r = "lhs_val", "rhs_val"
    if t in ("i32", "i64"):
        ut = unsigned_type(t)
        lu, ru = f"@as({ut}, @bitCast({l}))", f"@as({ut}, @bitCast({r}))"
        mapping = {
            "eq": f"break :blk {l} == {r};",
            "ne": f"break :blk {l} != {r};",
            "lt_s": f"break :blk {l} < {r};",
            "lt_u": f"break :blk {lu} < {ru};",
            "gt_s": f"break :blk {l} > {r};",
            "gt_u": f"break :blk {lu} > {ru};",
            "le_s": f"break :blk {l} <= {r};",
            "le_u": f"break :blk {lu} <= {ru};",
            "ge_s": f"break :blk {l} >= {r};",
            "ge_u": f"break :blk {lu} >= {ru};",
        }
    else:
        mapping = {
            "eq": f"break :blk {l} == {r};",
            "ne": f"break :blk {l} != {r};",
            "lt": f"break :blk {l} < {r};",
            "gt": f"break :blk {l} > {r};",
            "le": f"break :blk {l} <= {r};",
            "ge": f"break :blk {l} >= {r};",
        }
    return mapping[suffix]


def gen_try_fold_compare(op: str) -> str:
    t = zig_type(op)
    ct = const_tag(t)
    fn = f"try_fold_{op}_const"
    body = cmp_fold_body(op)
    return f"""    fn {fn}(self: *Lower, lhs: Slot, rhs: Slot, dst: Slot) !bool {{
        const ops = self.compiled.ops.items;
        if (ops.len < 2) return false;
        const rhs_op = ops[ops.len - 1];
        const lhs_op = ops[ops.len - 2];
        const rhs_val: {t} = switch (rhs_op) {{
            .{ct} => |c| if (c.dst == rhs) c.value else return false,
            else => return false,
        }};
        const lhs_val: {t} = switch (lhs_op) {{
            .{ct} => |c| if (c.dst == lhs) c.value else return false,
            else => return false,
        }};
        const result = blk: {{
            {body}
        }};
        _ = self.compiled.ops.pop();
        _ = self.compiled.ops.pop();
        try self.emit(.{{ .const_i32 = .{{ .dst = dst, .value = if (result) 1 else 0 }} }});
        return true;
    }}
"""


def gen_lower_compare(op: str) -> str:
    fn = snake_to_camel(f"lower_{op}")
    t = zig_type(op)
    ct = const_tag(t)
    imm_block = ""
    if op in IMM_OPS:
        imm_block = f"""
        const ops_buf = self.compiled.ops.items;
        if (ops_buf.len > 0) {{
            switch (ops_buf[ops_buf.len - 1]) {{
                .{ct} => |c| if (c.dst == rhs) {{
                        _ = self.compiled.ops.pop();
                        try self.emit(.{{ .{op}_imm = .{{ .dst = dst, .lhs = lhs, .imm = c.value }} }});
                        try self.stack.push(self.allocator, dst);
                        return;
                    }},
                else => {{}},
            }}
        }}"""
    return f"""    pub fn {fn}(self: *Lower) !void {{
        const rhs = try self.pop_slot();
        const lhs = try self.pop_slot();
        const dst = self.alloc_slot();
        if (try self.try_fold_{op}_const(lhs, rhs, dst)) {{
            try self.stack.push(self.allocator, dst);
            return;
        }}
{imm_block}
        try self.emit(.{{ .{op} = .{{ .dst = dst, .lhs = lhs, .rhs = rhs }} }});
        self.r0_slot = dst;
        try self.stack.push(self.allocator, dst);
    }}
"""


def unary_fold_body(op: str) -> str:
    t = zig_type(op)
    suffix = op.split("_", 1)[1]
    if suffix == "eqz":
        return "break :blk @as(i32, if (val == 0) 1 else 0);"
    if suffix == "clz":
        ut = "u32" if t == "i32" else "u64"
        rt = "i32" if t == "i32" else "i64"
        return f"break :blk @intCast(@clz(@as({ut}, @bitCast(val))));"
    if suffix == "ctz":
        ut = "u32" if t == "i32" else "u64"
        return f"break :blk @intCast(@ctz(@as({ut}, @bitCast(val))));"
    if suffix == "popcnt":
        ut = "u32" if t == "i32" else "u64"
        return f"break :blk @intCast(@popCount(@as({ut}, @bitCast(val))));"
    if t in ("f32", "f64"):
        mapping = {
            "abs": "break :blk @abs(val);",
            "neg": "break :blk -val;",
            "ceil": "break :blk @ceil(val);",
            "floor": "break :blk @floor(val);",
            "trunc": "break :blk @trunc(val);",
            "nearest": "break :blk @round(val);",
            "sqrt": "break :blk @sqrt(val);",
        }
        return mapping.get(suffix, "break :blk null;")
    return "break :blk null;"


def gen_lower_unary(op: str) -> str:
    fn = snake_to_camel(f"lower_{op}")
    t = zig_type(op)
    ct = const_tag(t)
    suffix = op.split("_", 1)[1]
    result_t = "i32" if suffix == "eqz" else t
    emit_ct = "const_i32" if suffix == "eqz" else ct
    track_r0 = suffix == "eqz" or t in ("i32", "i64")
    track = "self.r0_slot = dst;" if track_r0 else "self.r0_slot = null;"
    can_fold = t in ("i32", "i64")
    fold_block = ""
    if can_fold:
        fold_block = f"""
        const ops = self.compiled.ops.items;
        if (ops.len > 0) {{
            switch (ops[ops.len - 1]) {{
                .{ct} => |c| if (c.dst == src) {{
                        const val = c.value;
                        const result: ?{result_t} = blk: {{
                            {unary_fold_body(op)}
                        }};
                        if (result) |r| {{
                            _ = self.compiled.ops.pop();
                            try self.emit(.{{ .{emit_ct} = .{{ .dst = dst, .value = r }} }});
                            try self.stack.push(self.allocator, dst);
                            return;
                        }}
                    }},
                else => {{}},
            }}
        }}"""
    return f"""    pub fn {fn}(self: *Lower) !void {{
        const src = try self.pop_slot();
        const dst = self.alloc_slot();{fold_block}
        try self.emit(.{{ .{op} = .{{ .dst = dst, .src = src }} }});
        {track}
        try self.stack.push(self.allocator, dst);
    }}
"""


def gen_lower_convert(op: str) -> str:
    fn = snake_to_camel(f"lower_{op}")
    track = "self.r0_slot = dst;" if op.startswith(("i32_", "i64_")) else "self.r0_slot = null;"
    return f"""    pub fn {fn}(self: *Lower) !void {{
        const src = try self.pop_slot();
        const dst = self.alloc_slot();
        try self.emit(.{{ .{op} = .{{ .dst = dst, .src = src }} }});
        {track}
        try self.stack.push(self.allocator, dst);
    }}
"""


BINARY_OPS = []
for prefix in ("i32", "i64"):
    for s in ("add", "sub", "mul", "div_s", "div_u", "rem_s", "rem_u", "and", "or", "xor", "shl", "shr_s", "shr_u", "rotl", "rotr"):
        BINARY_OPS.append(f"{prefix}_{s}")
for prefix, suffixes in (("f32", ("add", "sub", "mul", "div", "min", "max", "copysign")), ("f64", ("add", "sub", "mul", "div", "min", "max", "copysign"))):
    for s in suffixes:
        BINARY_OPS.append(f"{prefix}_{s}")

COMPARE_OPS = []
for prefix in ("i32", "i64"):
    for s in ("eq", "ne", "lt_s", "lt_u", "gt_s", "gt_u", "le_s", "le_u", "ge_s", "ge_u"):
        COMPARE_OPS.append(f"{prefix}_{s}")
for prefix in ("f32", "f64"):
    for s in ("eq", "ne", "lt", "gt", "le", "ge"):
        COMPARE_OPS.append(f"{prefix}_{s}")

UNARY_OPS = []
for prefix in ("i32", "i64"):
    for s in ("clz", "ctz", "popcnt", "eqz"):
        UNARY_OPS.append(f"{prefix}_{s}")
for prefix in ("f32", "f64"):
    for s in ("abs", "neg", "ceil", "floor", "trunc", "nearest", "sqrt"):
        UNARY_OPS.append(f"{prefix}_{s}")

CONVERT_OPS = [
    "i32_wrap_i64", "i64_extend_i32_s", "i64_extend_i32_u",
    "i32_extend8_s", "i32_extend16_s", "i64_extend8_s", "i64_extend16_s", "i64_extend32_s",
    "i32_trunc_f32_s", "i32_trunc_f32_u", "i32_trunc_f64_s", "i32_trunc_f64_u",
    "i64_trunc_f32_s", "i64_trunc_f32_u", "i64_trunc_f64_s", "i64_trunc_f64_u",
    "i32_trunc_sat_f32_s", "i32_trunc_sat_f32_u", "i32_trunc_sat_f64_s", "i32_trunc_sat_f64_u",
    "i64_trunc_sat_f32_s", "i64_trunc_sat_f32_u", "i64_trunc_sat_f64_s", "i64_trunc_sat_f64_u",
    "f32_convert_i32_s", "f32_convert_i32_u", "f32_convert_i64_s", "f32_convert_i64_u", "f32_demote_f64",
    "f64_convert_i32_s", "f64_convert_i32_u", "f64_convert_i64_s", "f64_convert_i64_u", "f64_promote_f32",
    "i32_reinterpret_f32", "i64_reinterpret_f64", "f32_reinterpret_i32", "f64_reinterpret_i64",
]


def gen_lower_static_block() -> str:
    lines = ["    // --- Static numeric lowering (generated) ---"]
    for op in BINARY_OPS:
        if zig_type(op) in ("i32", "i64"):
            lines.append(gen_try_fold_binary(op))
        simp = gen_try_simplify_imm(op)
        if simp:
            lines.append(simp)
        lines.append(gen_lower_binary(op))
    for op in COMPARE_OPS:
        lines.append(gen_try_fold_compare(op))
        lines.append(gen_lower_compare(op))
    for op in UNARY_OPS:
        lines.append(gen_lower_unary(op))
    for op in CONVERT_OPS:
        lines.append(gen_lower_convert(op))
    return "\n".join(lines)


def patch_lower_dispatch(text: str) -> str:
    for op in BINARY_OPS:
        fn = snake_to_camel(f"lower_{op}")
        text = text.replace(f'lower_binary_op("{op}", saved_r0, saved_fp0)', f"{fn}(saved_r0, saved_fp0)")
    for op in COMPARE_OPS:
        fn = snake_to_camel(f"lower_{op}")
        text = text.replace(f'lower_compare_op("{op}")', f"{fn}()")
    for op in UNARY_OPS:
        fn = snake_to_camel(f"lower_{op}")
        text = text.replace(f'lower_unary_op("{op}")', f"{fn}()")
    for op in CONVERT_OPS:
        fn = snake_to_camel(f"lower_{op}")
        text = text.replace(f'lower_convert_op("{op}")', f"{fn}()")
    return text


def patch_module_dispatch(text: str) -> str:
    for op in BINARY_OPS:
        fn = snake_to_camel(f"lower_{op}")
        text = text.replace(f'lower.lower_binary_op("{op}", saved_r0, saved_fp0)', f"lower.{fn}(saved_r0, saved_fp0)")
    for op in COMPARE_OPS:
        fn = snake_to_camel(f"lower_{op}")
        text = text.replace(f'lower.lower_compare_op("{op}")', f"lower.{fn}()")
    for op in UNARY_OPS:
        fn = snake_to_camel(f"lower_{op}")
        text = text.replace(f'lower.lower_unary_op("{op}")', f"lower.{fn}()")
    for op in CONVERT_OPS:
        fn = snake_to_camel(f"lower_{op}")
        text = text.replace(f'lower.lower_convert_op("{op}")', f"lower.{fn}()")
    return text


# --- VM handler generation ---

I32_CMP = [
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

I64_CMP = [(n, op, "i64", "u64" if "u" in n else "i64") for n, op, lt, rt in [
    ("eq", "==", "i64", "i64"), ("ne", "!=", "i64", "i64"),
    ("lt_s", "<", "i64", "i64"), ("lt_u", "<", "u64", "u64"),
    ("gt_s", ">", "i64", "i64"), ("gt_u", ">", "u64", "u64"),
    ("le_s", "<=", "i64", "i64"), ("le_u", "<=", "u64", "u64"),
    ("ge_s", ">=", "i64", "i64"), ("ge_u", ">=", "u64", "u64"),
]]

F32_CMP = [("eq", "=="), ("ne", "!="), ("lt", "<"), ("gt", ">"), ("le", "<="), ("ge", ">=")]
F64_CMP = F32_CMP


def cmp_expr(lhs: str, rhs: str, op: str, lt: str, rt: str) -> str:
    return f"if (slots[ops.lhs].readAs({lt}) {op} slots[ops.rhs].readAs({rt})) @as(i32, 1) else 0"


def gen_handle_i32_binop(name: str, expr: str) -> str:
    return f"""pub fn handle_i32_{name}(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {{
    dispatch.countOp("misc");
    _ = r0;
    const ops = readOps(encode.ops.OpsDstLhsRhs, ip);
    const result = {expr};
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsDstLhsRhs), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}}
"""


def gen_handle_cmp(prefix: str, suffix: str, lt: str, rt: str, op: str, ops_type: str, stride_type: str, count: str) -> str:
    expr = cmp_expr("ops.lhs", "ops.rhs", op, lt, rt)
    return f"""pub fn handle_{prefix}_{suffix}(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {{
    dispatch.countOp("{count}");
    const ops = readOps(encode.ops.{ops_type}, ip);
    slots[ops.dst] = RawVal.from({expr});
    dispatch.next(ip, stride(encode.ops.{ops_type}), slots, frame, env, r0, fp0);
}}
"""


def gen_handle_cmp_to_local(prefix: str, suffix: str, lt: str, rt: str, op: str) -> str:
    expr = cmp_expr("ops.lhs", "ops.rhs", op, lt, rt)
    return f"""pub fn handle_{prefix}_{suffix}_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {{
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.ops.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from({expr});
    dispatch.next(ip, stride(encode.ops.OpsCmpToLocal), slots, frame, env, r0, fp0);
}}
"""


def main() -> None:
    lower_path = ROOT / "src/compiler/lower.zig"
    text = lower_path.read_text()

    start_marker = "    /// Try to fold a binary op where both operands are compile-time constants."
    keep_start_marker = "    fn trackNumericResult(self: *Lower, val_type: ValType, dst: Slot) void {"
    template_start_marker = "    pub fn lower_binary_op("
    end_marker = "    fn lower_simd_unary(self: *Lower, opcode: SimdOpcode) !void {"

    start = text.index(start_marker)
    keep_start = text.index(keep_start_marker)
    template_start = text.index(template_start_marker)
    end = text.index(end_marker)

    kept_helpers = text[keep_start:template_start]
    static_block = gen_lower_static_block() + "\n\n    "
    text = text[:start] + static_block + kept_helpers + text[end:]

    text = patch_lower_dispatch(text)
    lower_path.write_text(text)

    module_path = ROOT / "src/wasmz/module.zig"
    module_path.write_text(patch_module_dispatch(module_path.read_text()))

    print(f"Patched {lower_path} and {module_path}")


if __name__ == "__main__":
    main()

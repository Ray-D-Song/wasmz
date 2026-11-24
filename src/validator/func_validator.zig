/// func_validator.zig — WebAssembly function body operand-stack & control-flow validator.
///
/// Implements the standard Wasm specification polymorphic operand-stack and
/// structured control-flow validation algorithm (Appendix A.3), extended with:
///   - Reference Types & GC (subtyping, defaultability, local init tracking,
///     struct/array operations, ref.test/cast, br_on_null/non_null/cast/cast_fail)
///   - Multi-value blocks & Tail Calls (return_call, return_call_indirect, return_call_ref)
///   - Exception Handling (new try_table/throw/throw_ref and legacy try/catch/rethrow/delegate)
///   - SIMD & Relaxed SIMD (lane bounds, alignment, operand/result shapes)
///   - Threads / Atomics (natural alignment, memory existence)
///   - Memory64 (i64 linear memory address & size types)
const std = @import("std");
const core = @import("core");
const parser_mod = @import("parser");
const payload_mod = @import("payload");
const engine_config_mod = @import("../engine/config.zig");
const subtyping = @import("subtyping.zig");

const Allocator = std.mem.Allocator;
const ValType = core.ValType;
const HeapType = core.HeapType;
const RefType = core.RefType;
const FuncType = core.FuncType;
const StorageType = core.StorageType;
const simd = core.simd;
const OperatorCode = payload_mod.OperatorCode;
const OperatorInformation = payload_mod.OperatorInformation;
const FunctionInformation = payload_mod.FunctionInformation;
const FunctionBodyParser = parser_mod.FunctionBodyParser;
const EngineConfig = engine_config_mod.Config;
const TypeContext = subtyping.TypeContext;
const ValidationError = subtyping.ValidationError;

pub const GlobalTypeInfo = struct {
    val_type: ValType,
    mutable: bool,
};

pub const ValidatorEHMode = enum {
    none,
    new,
    legacy,
};

pub const FuncValidationContext = struct {
    type_ctx: *const TypeContext,
    func_type_indices: []const u32,
    table_types: []const ValType,
    global_types: []const GlobalTypeInfo,
    tags: []const u32,
    memory_count: u32,
    memory64: bool,
    data_segments_count: u32,
    has_data_count: bool,
    elem_segment_types: []const ValType,
    declared_funcs: *const std.AutoHashMapUnmanaged(u32, void),
    eh_mode: ValidatorEHMode,
    config: EngineConfig,
};

pub const StackValType = union(enum) {
    val: ValType,
    /// Polymorphic type after `unreachable` / unconditional branch.
    unknown,
    /// Polymorphic reference type (e.g. `ref.as_non_null` / `br_on_null` on `.unknown`).
    unknown_ref,
};

pub const BlockSig = union(enum) {
    empty,
    val: ValType,
    func_type: *const FuncType,

    fn params(self: BlockSig) []const ValType {
        return switch (self) {
            .empty, .val => &.{},
            .func_type => |ft| ft.params(),
        };
    }

    fn results(self: BlockSig, scratch_one: *[1]ValType) []const ValType {
        return switch (self) {
            .empty => &.{},
            .val => |v| blk: {
                scratch_one[0] = v;
                break :blk scratch_one[0..1];
            },
            .func_type => |ft| ft.results(),
        };
    }
};

pub const ControlKind = enum {
    func,
    block,
    loop,
    if_,
    else_,
    try_table,
    try_,
    catch_,
    catch_all,
};

pub const ControlFrame = struct {
    kind: ControlKind,
    sig: BlockSig,
    height: usize,
    unreachable_flag: bool,
    local_init_mark: usize,
};

pub const ValidateFuncError = ValidationError || Allocator.Error || parser_mod.CodeReadError || error{
    DisabledSimd,
    DisabledRelaxedSimd,
    UnsupportedOperator,
};

/// Reusable validator state across all function bodies in a module.
pub const FuncValidator = struct {
    allocator: Allocator,
    val_stack: std.ArrayListUnmanaged(StackValType) = .empty,
    ctrl_stack: std.ArrayListUnmanaged(ControlFrame) = .empty,
    local_types: std.ArrayListUnmanaged(ValType) = .empty,
    local_init_bits: std.DynamicBitSetUnmanaged = .{},
    local_init_undo: std.ArrayListUnmanaged(u32) = .empty,
    scratch_vals: std.ArrayListUnmanaged(StackValType) = .empty,

    pub fn init(allocator: Allocator) FuncValidator {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FuncValidator) void {
        self.val_stack.deinit(self.allocator);
        self.ctrl_stack.deinit(self.allocator);
        self.local_types.deinit(self.allocator);
        self.local_init_bits.deinit(self.allocator);
        self.local_init_undo.deinit(self.allocator);
        self.scratch_vals.deinit(self.allocator);
    }

    fn reset(self: *FuncValidator) void {
        self.val_stack.clearRetainingCapacity();
        self.ctrl_stack.clearRetainingCapacity();
        self.local_types.clearRetainingCapacity();
        self.local_init_undo.clearRetainingCapacity();
        self.scratch_vals.clearRetainingCapacity();
    }

    pub fn validateFunction(
        self: *FuncValidator,
        ctx: *const FuncValidationContext,
        func_type: *const FuncType,
        info: FunctionInformation,
        scratch: Allocator,
    ) ValidateFuncError!void {
        self.reset();

        const type_ctx = ctx.type_ctx;
        const params = func_type.params();

        var total_locals: usize = params.len;
        for (info.locals) |group| {
            const sum, const ov = @addWithOverflow(total_locals, @as(usize, group.count));
            if (ov != 0 or sum > std.math.maxInt(u32)) return error.InvalidArity;
            total_locals = sum;
        }

        try self.local_types.ensureTotalCapacity(self.allocator, total_locals);
        try self.local_init_bits.resize(self.allocator, total_locals, false);

        for (params, 0..) |p, idx| {
            self.local_types.appendAssumeCapacity(p);
            self.local_init_bits.setValue(idx, true);
        }

        var local_idx: usize = params.len;
        for (info.locals) |group| {
            const vt = try subtyping.payloadTypeToValType(group.typ, type_ctx);
            const is_def = subtyping.isValTypeDefaultable(vt);
            for (0..group.count) |_| {
                self.local_types.appendAssumeCapacity(vt);
                self.local_init_bits.setValue(local_idx, is_def);
                local_idx += 1;
            }
        }

        try self.ctrl_stack.append(self.allocator, .{
            .kind = .func,
            .sig = .{ .func_type = func_type },
            .height = 0,
            .unreachable_flag = false,
            .local_init_mark = 0,
        });

        var fbp = FunctionBodyParser.init(scratch, info.body);
        while (!fbp.done()) {
            const op_info = try fbp.next();

            if (simd.isSimdOpcode(op_info.code)) {
                if (!ctx.config.simd) return error.DisabledSimd;
                if (simd.isRelaxedSimdOpcode(op_info.code) and !ctx.config.relaxed_simd) {
                    return error.DisabledRelaxedSimd;
                }
            }

            try self.validateOp(ctx, func_type, op_info);
            if (self.ctrl_stack.items.len == 0) {
                // Only valid if we just consumed the trailing `end` at EOF.
                if (!fbp.done()) return error.MismatchedControlFlow;
            }
        }

        if (self.ctrl_stack.items.len != 0) return error.MismatchedControlFlow;
    }

    inline fn topFrame(self: *FuncValidator) ValidateFuncError!*ControlFrame {
        if (self.ctrl_stack.items.len == 0) return error.MismatchedControlFlow;
        return &self.ctrl_stack.items[self.ctrl_stack.items.len - 1];
    }

    fn pushStack(self: *FuncValidator, sv: StackValType) Allocator.Error!void {
        try self.val_stack.append(self.allocator, sv);
    }

    fn pushVal(self: *FuncValidator, vt: ValType) Allocator.Error!void {
        try self.val_stack.append(self.allocator, .{ .val = vt });
    }

    fn pushVals(self: *FuncValidator, vts: []const ValType) Allocator.Error!void {
        for (vts) |vt| {
            try self.pushVal(vt);
        }
    }

    fn popVal(self: *FuncValidator) ValidateFuncError!StackValType {
        const frame = try self.topFrame();
        if (self.val_stack.items.len == frame.height) {
            if (frame.unreachable_flag) return .unknown;
            return error.TypeMismatch;
        }
        return self.val_stack.pop().?;
    }

    fn popExpect(self: *FuncValidator, expected: ValType, type_ctx: *const TypeContext) ValidateFuncError!StackValType {
        const actual = try self.popVal();
        switch (actual) {
            .unknown => return .{ .val = expected },
            .unknown_ref => {
                if (expected != .Ref) return error.TypeMismatch;
                return .{ .val = expected };
            },
            .val => |vt| {
                if (!subtyping.valTypeMatches(vt, expected, type_ctx)) return error.TypeMismatch;
                return actual;
            },
        }
    }

    fn popExpectVals(self: *FuncValidator, expected: []const ValType, type_ctx: *const TypeContext) ValidateFuncError!void {
        var i: usize = expected.len;
        while (i > 0) {
            i -= 1;
            _ = try self.popExpect(expected[i], type_ctx);
        }
    }

    /// Pops any reference type; returns `null` when the operand was polymorphic (`.unknown` / `.unknown_ref`).
    fn popRef(self: *FuncValidator) ValidateFuncError!?RefType {
        const actual = try self.popVal();
        return switch (actual) {
            .unknown, .unknown_ref => null,
            .val => |vt| switch (vt) {
                .Ref => |rt| rt,
                else => error.TypeMismatch,
            },
        };
    }

    fn markUnreachable(self: *FuncValidator) ValidateFuncError!void {
        const frame = try self.topFrame();
        self.val_stack.shrinkRetainingCapacity(frame.height);
        frame.unreachable_flag = true;
    }

    fn rollbackLocalInit(self: *FuncValidator, mark: usize) void {
        while (self.local_init_undo.items.len > mark) {
            const idx = self.local_init_undo.pop().?;
            self.local_init_bits.unset(idx);
        }
    }

    fn pushControlFrame(
        self: *FuncValidator,
        kind: ControlKind,
        sig: BlockSig,
        type_ctx: *const TypeContext,
    ) ValidateFuncError!void {
        try self.popExpectVals(sig.params(), type_ctx);
        const height = self.val_stack.items.len;
        const mark = self.local_init_undo.items.len;
        try self.ctrl_stack.append(self.allocator, .{
            .kind = kind,
            .sig = sig,
            .height = height,
            .unreachable_flag = false,
            .local_init_mark = mark,
        });
        try self.pushVals(sig.params());
    }

    fn popControlFrame(self: *FuncValidator, type_ctx: *const TypeContext) ValidateFuncError!ControlFrame {
        const frame = try self.topFrame();
        var scratch_one: [1]ValType = undefined;
        const end_types = frame.sig.results(&scratch_one);
        try self.popExpectVals(end_types, type_ctx);
        if (self.val_stack.items.len != frame.height) return error.TypeMismatch;
        const popped = self.ctrl_stack.pop().?;
        self.rollbackLocalInit(popped.local_init_mark);
        return popped;
    }

    fn frameLabelTypes(frame: *const ControlFrame, scratch_one: *[1]ValType) []const ValType {
        return switch (frame.kind) {
            .loop => frame.sig.params(),
            else => frame.sig.results(scratch_one),
        };
    }

    fn resolveBlockSig(block_type_opt: ?payload_mod.Type, type_ctx: *const TypeContext) ValidateFuncError!BlockSig {
        const bt = block_type_opt orelse return error.InvalidBlockType;
        return switch (bt) {
            .kind => |k| if (k == .empty_block_type)
                .empty
            else
                .{ .val = try subtyping.payloadTypeToValType(bt, type_ctx) },
            .ref_type => .{ .val = try subtyping.payloadTypeToValType(bt, type_ctx) },
            .index => |idx| blk: {
                if (idx >= type_ctx.composite_types.len) return error.UnknownType;
                switch (type_ctx.composite_types[idx]) {
                    .func_type => |*ft| break :blk .{ .func_type = ft },
                    else => return error.InvalidCompositeTypeIndex,
                }
            },
        };
    }

    fn checkStackMatchesValTypes(actuals: []const StackValType, expected: []const ValType, type_ctx: *const TypeContext) bool {
        if (actuals.len != expected.len) return false;
        for (actuals, expected) |act, exp| {
            switch (act) {
                .unknown => {},
                .unknown_ref => if (exp != .Ref) return false,
                .val => |vt| if (!subtyping.valTypeMatches(vt, exp, type_ctx)) return false,
            }
        }
        return true;
    }

    fn getFuncTypeAt(ctx: *const FuncValidationContext, func_idx: u32) ValidateFuncError!*const FuncType {
        if (func_idx >= ctx.func_type_indices.len) return error.UnknownFunction;
        const type_idx = ctx.func_type_indices[func_idx];
        if (type_idx >= ctx.type_ctx.composite_types.len) return error.UnknownType;
        return switch (ctx.type_ctx.composite_types[type_idx]) {
            .func_type => |*ft| ft,
            else => error.InvalidCompositeTypeIndex,
        };
    }

    fn getFuncTypeByIndex(type_ctx: *const TypeContext, type_idx: u32) ValidateFuncError!*const FuncType {
        if (type_idx >= type_ctx.composite_types.len) return error.UnknownType;
        return switch (type_ctx.composite_types[type_idx]) {
            .func_type => |*ft| ft,
            else => error.InvalidCompositeTypeIndex,
        };
    }

    fn validateOp(
        self: *FuncValidator,
        ctx: *const FuncValidationContext,
        func_type: *const FuncType,
        op_info: OperatorInformation,
    ) ValidateFuncError!void {
        const type_ctx = ctx.type_ctx;
        const addr_type: ValType = if (ctx.memory64) .I64 else .I32;

        if (simd.isSimdOpcode(op_info.code)) {
            return self.validateSimdOp(ctx, op_info, addr_type);
        }

        switch (op_info.code) {
            .unreachable_ => try self.markUnreachable(),
            .nop => {},

            .block => {
                const sig = try resolveBlockSig(op_info.block_type, type_ctx);
                try self.pushControlFrame(.block, sig, type_ctx);
            },
            .loop => {
                const sig = try resolveBlockSig(op_info.block_type, type_ctx);
                try self.pushControlFrame(.loop, sig, type_ctx);
            },
            .if_ => {
                _ = try self.popExpect(.I32, type_ctx);
                const sig = try resolveBlockSig(op_info.block_type, type_ctx);
                try self.pushControlFrame(.if_, sig, type_ctx);
            },
            .else_ => {
                const popped = try self.popControlFrame(type_ctx);
                if (popped.kind != .if_) return error.MismatchedControlFlow;
                try self.ctrl_stack.append(self.allocator, .{
                    .kind = .else_,
                    .sig = popped.sig,
                    .height = popped.height,
                    .unreachable_flag = false,
                    .local_init_mark = popped.local_init_mark,
                });
                try self.pushVals(popped.sig.params());
            },
            .end => {
                const frame = try self.topFrame();
                if (frame.kind == .if_) {
                    // An `if` without `else` implicitly passes params directly to results.
                    var scratch_one: [1]ValType = undefined;
                    const p_types = frame.sig.params();
                    const r_types = frame.sig.results(&scratch_one);
                    if (p_types.len != r_types.len) return error.TypeMismatch;
                    for (p_types, r_types) |pt, rt| {
                        if (!subtyping.valTypeMatches(pt, rt, type_ctx)) return error.TypeMismatch;
                    }
                }
                const popped = try self.popControlFrame(type_ctx);
                var scratch_one: [1]ValType = undefined;
                try self.pushVals(popped.sig.results(&scratch_one));
            },

            .br => {
                const depth = op_info.br_depth orelse return error.UnknownLabel;
                if (depth >= self.ctrl_stack.items.len) return error.UnknownLabel;
                const target = &self.ctrl_stack.items[self.ctrl_stack.items.len - 1 - depth];
                var scratch_one: [1]ValType = undefined;
                try self.popExpectVals(frameLabelTypes(target, &scratch_one), type_ctx);
                try self.markUnreachable();
            },
            .br_if => {
                _ = try self.popExpect(.I32, type_ctx);
                const depth = op_info.br_depth orelse return error.UnknownLabel;
                if (depth >= self.ctrl_stack.items.len) return error.UnknownLabel;
                const target = &self.ctrl_stack.items[self.ctrl_stack.items.len - 1 - depth];
                var scratch_one: [1]ValType = undefined;
                const label_types = frameLabelTypes(target, &scratch_one);
                try self.popExpectVals(label_types, type_ctx);
                try self.pushVals(label_types);
            },
            .br_table => {
                _ = try self.popExpect(.I32, type_ctx);
                const targets = op_info.br_table;
                if (targets.len == 0) return error.UnknownLabel;
                const default_depth = targets[targets.len - 1];
                if (default_depth >= self.ctrl_stack.items.len) return error.UnknownLabel;
                const default_frame = &self.ctrl_stack.items[self.ctrl_stack.items.len - 1 - default_depth];
                var scratch_def: [1]ValType = undefined;
                const arity = frameLabelTypes(default_frame, &scratch_def).len;

                for (targets) |d| {
                    if (d >= self.ctrl_stack.items.len) return error.UnknownLabel;
                    const t_frame = &self.ctrl_stack.items[self.ctrl_stack.items.len - 1 - d];
                    var scratch_t: [1]ValType = undefined;
                    if (frameLabelTypes(t_frame, &scratch_t).len != arity) return error.InvalidArity;
                }

                self.scratch_vals.clearRetainingCapacity();
                try self.scratch_vals.resize(self.allocator, arity);
                var k: usize = arity;
                while (k > 0) {
                    k -= 1;
                    self.scratch_vals.items[k] = try self.popVal();
                }

                for (targets) |d| {
                    const t_frame = &self.ctrl_stack.items[self.ctrl_stack.items.len - 1 - d];
                    var scratch_t: [1]ValType = undefined;
                    const t_types = frameLabelTypes(t_frame, &scratch_t);
                    if (!checkStackMatchesValTypes(self.scratch_vals.items, t_types, type_ctx)) {
                        return error.TypeMismatch;
                    }
                }
                try self.markUnreachable();
            },
            .return_ => {
                try self.popExpectVals(func_type.results(), type_ctx);
                try self.markUnreachable();
            },

            // Calls
            .call => {
                const func_idx = op_info.func_index orelse return error.UnknownFunction;
                const callee_ft = try getFuncTypeAt(ctx, func_idx);
                try self.popExpectVals(callee_ft.params(), type_ctx);
                try self.pushVals(callee_ft.results());
            },
            .return_call => {
                const func_idx = op_info.func_index orelse return error.UnknownFunction;
                const callee_ft = try getFuncTypeAt(ctx, func_idx);
                try self.popExpectVals(callee_ft.params(), type_ctx);
                try checkReturnCallResults(callee_ft.results(), func_type.results(), type_ctx);
                try self.markUnreachable();
            },
            .call_indirect, .return_call_indirect => {
                const table_idx = op_info.table_index orelse 0;
                if (table_idx >= ctx.table_types.len) return error.UnknownTable;
                if (!subtyping.valTypeMatches(ctx.table_types[table_idx], ValType.funcref(), type_ctx)) {
                    return error.TypeMismatch;
                }
                const ht = op_info.type_index orelse return error.UnknownType;
                const type_idx = switch (ht) {
                    .index => |idx| idx,
                    .kind => return error.UnknownType,
                };
                const callee_ft = try getFuncTypeByIndex(type_ctx, type_idx);
                _ = try self.popExpect(.I32, type_ctx);
                try self.popExpectVals(callee_ft.params(), type_ctx);
                if (op_info.code == .return_call_indirect) {
                    try checkReturnCallResults(callee_ft.results(), func_type.results(), type_ctx);
                    try self.markUnreachable();
                } else {
                    try self.pushVals(callee_ft.results());
                }
            },
            .call_ref, .return_call_ref => {
                const ht = op_info.type_index orelse return error.UnknownType;
                const type_idx = switch (ht) {
                    .index => |idx| idx,
                    .kind => return error.UnknownType,
                };
                const callee_ft = try getFuncTypeByIndex(type_ctx, type_idx);
                _ = try self.popExpect(.{ .Ref = RefType.init(true, HeapType.fromConcreteType(type_idx)) }, type_ctx);
                try self.popExpectVals(callee_ft.params(), type_ctx);
                if (op_info.code == .return_call_ref) {
                    try checkReturnCallResults(callee_ft.results(), func_type.results(), type_ctx);
                    try self.markUnreachable();
                } else {
                    try self.pushVals(callee_ft.results());
                }
            },

            // Parametric
            .drop => _ = try self.popVal(),
            .select => {
                _ = try self.popExpect(.I32, type_ctx);
                const t2 = try self.popVal();
                const t1 = try self.popVal();
                switch (t1) {
                    .val => |v1| {
                        if (v1 == .Ref) return error.TypeMismatch;
                        switch (t2) {
                            .val => |v2| {
                                if (v2 == .Ref or !v1.eql(v2)) return error.TypeMismatch;
                                try self.pushVal(v1);
                            },
                            .unknown => try self.pushVal(v1),
                            .unknown_ref => return error.TypeMismatch,
                        }
                    },
                    .unknown => switch (t2) {
                        .val => |v2| {
                            if (v2 == .Ref) return error.TypeMismatch;
                            try self.pushVal(v2);
                        },
                        .unknown => try self.pushStack(.unknown),
                        .unknown_ref => return error.TypeMismatch,
                    },
                    .unknown_ref => return error.TypeMismatch,
                }
            },
            .select_with_type => {
                if ((op_info.len orelse 0) != 1) return error.InvalidSelectType;
                const sel_raw = op_info.select_type orelse return error.InvalidSelectType;
                const vt = try subtyping.payloadTypeToValType(sel_raw, type_ctx);
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(vt, type_ctx);
                _ = try self.popExpect(vt, type_ctx);
                try self.pushVal(vt);
            },

            // Variables
            .local_get => {
                const idx = op_info.local_index orelse return error.UnknownLocal;
                if (idx >= self.local_types.items.len) return error.UnknownLocal;
                if (!self.local_init_bits.isSet(idx)) return error.UninitializedLocal;
                try self.pushVal(self.local_types.items[idx]);
            },
            .local_set => {
                const idx = op_info.local_index orelse return error.UnknownLocal;
                if (idx >= self.local_types.items.len) return error.UnknownLocal;
                _ = try self.popExpect(self.local_types.items[idx], type_ctx);
                if (!self.local_init_bits.isSet(idx)) {
                    self.local_init_bits.set(idx);
                    try self.local_init_undo.append(self.allocator, idx);
                }
            },
            .local_tee => {
                const idx = op_info.local_index orelse return error.UnknownLocal;
                if (idx >= self.local_types.items.len) return error.UnknownLocal;
                const vt = self.local_types.items[idx];
                _ = try self.popExpect(vt, type_ctx);
                try self.pushVal(vt);
                if (!self.local_init_bits.isSet(idx)) {
                    self.local_init_bits.set(idx);
                    try self.local_init_undo.append(self.allocator, idx);
                }
            },
            .global_get => {
                const idx = op_info.global_index orelse return error.UnknownGlobal;
                if (idx >= ctx.global_types.len) return error.UnknownGlobal;
                try self.pushVal(ctx.global_types[idx].val_type);
            },
            .global_set => {
                const idx = op_info.global_index orelse return error.UnknownGlobal;
                if (idx >= ctx.global_types.len) return error.UnknownGlobal;
                if (!ctx.global_types[idx].mutable) return error.ImmutableGlobal;
                _ = try self.popExpect(ctx.global_types[idx].val_type, type_ctx);
            },

            // Tables
            .table_get => {
                const tbl_idx = op_info.table_index orelse return error.UnknownTable;
                if (tbl_idx >= ctx.table_types.len) return error.UnknownTable;
                _ = try self.popExpect(.I32, type_ctx);
                try self.pushVal(ctx.table_types[tbl_idx]);
            },
            .table_set => {
                const tbl_idx = op_info.table_index orelse return error.UnknownTable;
                if (tbl_idx >= ctx.table_types.len) return error.UnknownTable;
                _ = try self.popExpect(ctx.table_types[tbl_idx], type_ctx);
                _ = try self.popExpect(.I32, type_ctx);
            },
            .table_size => {
                const tbl_idx = op_info.table_index orelse return error.UnknownTable;
                if (tbl_idx >= ctx.table_types.len) return error.UnknownTable;
                try self.pushVal(.I32);
            },
            .table_grow => {
                const tbl_idx = op_info.table_index orelse return error.UnknownTable;
                if (tbl_idx >= ctx.table_types.len) return error.UnknownTable;
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(ctx.table_types[tbl_idx], type_ctx);
                try self.pushVal(.I32);
            },
            .table_fill => {
                const tbl_idx = op_info.table_index orelse return error.UnknownTable;
                if (tbl_idx >= ctx.table_types.len) return error.UnknownTable;
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(ctx.table_types[tbl_idx], type_ctx);
                _ = try self.popExpect(.I32, type_ctx);
            },
            .table_copy => {
                const dst_idx = op_info.table_index orelse return error.UnknownTable;
                const src_idx = op_info.destination_index orelse return error.UnknownTable;
                if (dst_idx >= ctx.table_types.len or src_idx >= ctx.table_types.len) return error.UnknownTable;
                if (!subtyping.valTypeMatches(ctx.table_types[src_idx], ctx.table_types[dst_idx], type_ctx)) {
                    return error.TypeMismatch;
                }
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(.I32, type_ctx);
            },
            .table_init => {
                const seg_idx = op_info.segment_index orelse return error.UnknownElemSegment;
                const tbl_idx = op_info.table_index orelse return error.UnknownTable;
                if (tbl_idx >= ctx.table_types.len) return error.UnknownTable;
                if (seg_idx >= ctx.elem_segment_types.len) return error.UnknownElemSegment;
                if (!subtyping.valTypeMatches(ctx.elem_segment_types[seg_idx], ctx.table_types[tbl_idx], type_ctx)) {
                    return error.TypeMismatch;
                }
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(.I32, type_ctx);
            },
            .elem_drop => {
                const seg_idx = op_info.segment_index orelse return error.UnknownElemSegment;
                if (seg_idx >= ctx.elem_segment_types.len) return error.UnknownElemSegment;
            },

            // Memory loads & stores
            .i32_load => try self.checkLoad(ctx, op_info, addr_type, .I32, 2),
            .i64_load => try self.checkLoad(ctx, op_info, addr_type, .I64, 3),
            .f32_load => try self.checkLoad(ctx, op_info, addr_type, .F32, 2),
            .f64_load => try self.checkLoad(ctx, op_info, addr_type, .F64, 3),
            .i32_load8_s, .i32_load8_u => try self.checkLoad(ctx, op_info, addr_type, .I32, 0),
            .i32_load16_s, .i32_load16_u => try self.checkLoad(ctx, op_info, addr_type, .I32, 1),
            .i64_load8_s, .i64_load8_u => try self.checkLoad(ctx, op_info, addr_type, .I64, 0),
            .i64_load16_s, .i64_load16_u => try self.checkLoad(ctx, op_info, addr_type, .I64, 1),
            .i64_load32_s, .i64_load32_u => try self.checkLoad(ctx, op_info, addr_type, .I64, 2),
            .i32_store => try self.checkStore(ctx, op_info, addr_type, .I32, 2),
            .i64_store => try self.checkStore(ctx, op_info, addr_type, .I64, 3),
            .f32_store => try self.checkStore(ctx, op_info, addr_type, .F32, 2),
            .f64_store => try self.checkStore(ctx, op_info, addr_type, .F64, 3),
            .i32_store8 => try self.checkStore(ctx, op_info, addr_type, .I32, 0),
            .i32_store16 => try self.checkStore(ctx, op_info, addr_type, .I32, 1),
            .i64_store8 => try self.checkStore(ctx, op_info, addr_type, .I64, 0),
            .i64_store16 => try self.checkStore(ctx, op_info, addr_type, .I64, 1),
            .i64_store32 => try self.checkStore(ctx, op_info, addr_type, .I64, 2),

            .memory_size => {
                if (ctx.memory_count == 0) return error.UnknownMemory;
                if ((op_info.destination_index orelse 0) != 0) return error.InvalidMemoryIndex;
                try self.pushVal(addr_type);
            },
            .memory_grow => {
                if (ctx.memory_count == 0) return error.UnknownMemory;
                if ((op_info.destination_index orelse 0) != 0) return error.InvalidMemoryIndex;
                _ = try self.popExpect(addr_type, type_ctx);
                try self.pushVal(addr_type);
            },
            .memory_init => {
                if (ctx.memory_count == 0) return error.UnknownMemory;
                if ((op_info.destination_index orelse 0) != 0) return error.InvalidMemoryIndex;
                if (!ctx.has_data_count) return error.MissingDataCountSection;
                const seg_idx = op_info.segment_index orelse return error.UnknownDataSegment;
                if (seg_idx >= ctx.data_segments_count) return error.UnknownDataSegment;
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(addr_type, type_ctx);
            },
            .data_drop => {
                if (!ctx.has_data_count) return error.MissingDataCountSection;
                const seg_idx = op_info.segment_index orelse return error.UnknownDataSegment;
                if (seg_idx >= ctx.data_segments_count) return error.UnknownDataSegment;
            },
            .memory_copy => {
                if (ctx.memory_count == 0) return error.UnknownMemory;
                if ((op_info.destination_index orelse 0) != 0 or (op_info.table_index orelse 0) != 0) {
                    return error.InvalidMemoryIndex;
                }
                _ = try self.popExpect(addr_type, type_ctx);
                _ = try self.popExpect(addr_type, type_ctx);
                _ = try self.popExpect(addr_type, type_ctx);
            },
            .memory_fill => {
                if (ctx.memory_count == 0) return error.UnknownMemory;
                if ((op_info.destination_index orelse 0) != 0) return error.InvalidMemoryIndex;
                _ = try self.popExpect(addr_type, type_ctx);
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(addr_type, type_ctx);
            },

            // Numeric constants
            .i32_const => try self.pushVal(.I32),
            .i64_const => try self.pushVal(.I64),
            .f32_const => try self.pushVal(.F32),
            .f64_const => try self.pushVal(.F64),

            // i32 unary / compare / binary
            .i32_clz, .i32_ctz, .i32_popcnt, .i32_eqz, .i32_extend8_s, .i32_extend16_s => {
                _ = try self.popExpect(.I32, type_ctx);
                try self.pushVal(.I32);
            },
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
            => {
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(.I32, type_ctx);
                try self.pushVal(.I32);
            },

            // i64 unary / compare / binary
            .i64_clz, .i64_ctz, .i64_popcnt, .i64_extend8_s, .i64_extend16_s, .i64_extend32_s => {
                _ = try self.popExpect(.I64, type_ctx);
                try self.pushVal(.I64);
            },
            .i64_eqz => {
                _ = try self.popExpect(.I64, type_ctx);
                try self.pushVal(.I32);
            },
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
            => {
                _ = try self.popExpect(.I64, type_ctx);
                _ = try self.popExpect(.I64, type_ctx);
                try self.pushVal(.I32);
            },
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
            => {
                _ = try self.popExpect(.I64, type_ctx);
                _ = try self.popExpect(.I64, type_ctx);
                try self.pushVal(.I64);
            },

            // f32 unary / compare / binary
            .f32_abs, .f32_neg, .f32_ceil, .f32_floor, .f32_trunc, .f32_nearest, .f32_sqrt => {
                _ = try self.popExpect(.F32, type_ctx);
                try self.pushVal(.F32);
            },
            .f32_eq, .f32_ne, .f32_lt, .f32_gt, .f32_le, .f32_ge => {
                _ = try self.popExpect(.F32, type_ctx);
                _ = try self.popExpect(.F32, type_ctx);
                try self.pushVal(.I32);
            },
            .f32_add, .f32_sub, .f32_mul, .f32_div, .f32_min, .f32_max, .f32_copysign => {
                _ = try self.popExpect(.F32, type_ctx);
                _ = try self.popExpect(.F32, type_ctx);
                try self.pushVal(.F32);
            },

            // f64 unary / compare / binary
            .f64_abs, .f64_neg, .f64_ceil, .f64_floor, .f64_trunc, .f64_nearest, .f64_sqrt => {
                _ = try self.popExpect(.F64, type_ctx);
                try self.pushVal(.F64);
            },
            .f64_eq, .f64_ne, .f64_lt, .f64_gt, .f64_le, .f64_ge => {
                _ = try self.popExpect(.F64, type_ctx);
                _ = try self.popExpect(.F64, type_ctx);
                try self.pushVal(.I32);
            },
            .f64_add, .f64_sub, .f64_mul, .f64_div, .f64_min, .f64_max, .f64_copysign => {
                _ = try self.popExpect(.F64, type_ctx);
                _ = try self.popExpect(.F64, type_ctx);
                try self.pushVal(.F64);
            },

            // Conversions
            .i32_wrap_i64 => try self.checkUnary(.I64, .I32, type_ctx),
            .i32_trunc_f32_s, .i32_trunc_f32_u, .i32_reinterpret_f32, .i32_trunc_sat_f32_s, .i32_trunc_sat_f32_u => try self.checkUnary(.F32, .I32, type_ctx),
            .i32_trunc_f64_s, .i32_trunc_f64_u, .i32_trunc_sat_f64_s, .i32_trunc_sat_f64_u => try self.checkUnary(.F64, .I32, type_ctx),
            .i64_extend_i32_s, .i64_extend_i32_u => try self.checkUnary(.I32, .I64, type_ctx),
            .i64_trunc_f32_s, .i64_trunc_f32_u, .i64_trunc_sat_f32_s, .i64_trunc_sat_f32_u => try self.checkUnary(.F32, .I64, type_ctx),
            .i64_trunc_f64_s, .i64_trunc_f64_u, .i64_reinterpret_f64, .i64_trunc_sat_f64_s, .i64_trunc_sat_f64_u => try self.checkUnary(.F64, .I64, type_ctx),
            .f32_convert_i32_s, .f32_convert_i32_u, .f32_reinterpret_i32 => try self.checkUnary(.I32, .F32, type_ctx),
            .f32_convert_i64_s, .f32_convert_i64_u => try self.checkUnary(.I64, .F32, type_ctx),
            .f32_demote_f64 => try self.checkUnary(.F64, .F32, type_ctx),
            .f64_convert_i32_s, .f64_convert_i32_u => try self.checkUnary(.I32, .F64, type_ctx),
            .f64_convert_i64_s, .f64_convert_i64_u, .f64_reinterpret_i64 => try self.checkUnary(.I64, .F64, type_ctx),
            .f64_promote_f32 => try self.checkUnary(.F32, .F64, type_ctx),

            // Reference types
            .ref_null => {
                const ht = try subtyping.payloadHeapTypeToCore(op_info.ref_type orelse return error.UnknownType, type_ctx);
                try self.pushVal(.{ .Ref = RefType.init(true, ht) });
            },
            .ref_is_null => {
                _ = try self.popRef();
                try self.pushVal(.I32);
            },
            .ref_func => {
                const f_idx = op_info.func_index orelse return error.UnknownFunction;
                if (f_idx >= ctx.func_type_indices.len) return error.UnknownFunction;
                if (!ctx.declared_funcs.contains(f_idx)) return error.UndeclaredFuncRef;
                const t_idx = ctx.func_type_indices[f_idx];
                try self.pushVal(.{ .Ref = RefType.init(false, HeapType.fromConcreteType(t_idx)) });
            },
            .ref_eq => {
                _ = try self.popExpect(ValType.eqref(), type_ctx);
                _ = try self.popExpect(ValType.eqref(), type_ctx);
                try self.pushVal(.I32);
            },
            .ref_as_non_null => {
                if (try self.popRef()) |rt| {
                    try self.pushVal(.{ .Ref = RefType.init(false, rt.heap_type) });
                } else {
                    try self.pushStack(.unknown_ref);
                }
            },
            .br_on_null => {
                const depth = op_info.br_depth orelse return error.UnknownLabel;
                if (depth >= self.ctrl_stack.items.len) return error.UnknownLabel;
                const rt_opt = try self.popRef();
                const target = &self.ctrl_stack.items[self.ctrl_stack.items.len - 1 - depth];
                var scratch_one: [1]ValType = undefined;
                const label_types = frameLabelTypes(target, &scratch_one);
                try self.popExpectVals(label_types, type_ctx);
                try self.pushVals(label_types);
                if (rt_opt) |rt| {
                    try self.pushVal(.{ .Ref = RefType.init(false, rt.heap_type) });
                } else {
                    try self.pushStack(.unknown_ref);
                }
            },
            .br_on_non_null => {
                const depth = op_info.br_depth orelse return error.UnknownLabel;
                if (depth >= self.ctrl_stack.items.len) return error.UnknownLabel;
                const target = &self.ctrl_stack.items[self.ctrl_stack.items.len - 1 - depth];
                var scratch_one: [1]ValType = undefined;
                const label_types = frameLabelTypes(target, &scratch_one);
                if (label_types.len == 0) return error.TypeMismatch;
                const label_last = label_types[label_types.len - 1];
                const expected_ref = switch (label_last) {
                    .Ref => |r| r,
                    else => return error.TypeMismatch,
                };
                if (try self.popRef()) |rt| {
                    const non_null_rt = RefType.init(false, rt.heap_type);
                    if (!subtyping.refTypeMatches(non_null_rt, expected_ref, type_ctx)) return error.TypeMismatch;
                }
                const prefix = label_types[0 .. label_types.len - 1];
                try self.popExpectVals(prefix, type_ctx);
                try self.pushVals(prefix);
            },

            // GC Structs
            .struct_new, .struct_new_default => {
                const type_idx = try concreteIndexFromPayload(op_info.ref_type, type_ctx);
                const struct_ty = switch (type_ctx.composite_types[type_idx]) {
                    .struct_type => |st| st,
                    else => return error.InvalidCompositeTypeIndex,
                };
                if (op_info.code == .struct_new_default) {
                    for (struct_ty.fields) |f| {
                        if (!subtyping.isStorageTypeDefaultable(f.storage_type)) return error.NonDefaultableType;
                    }
                } else {
                    var i: usize = struct_ty.fields.len;
                    while (i > 0) {
                        i -= 1;
                        _ = try self.popExpect(subtyping.unpackStorageType(struct_ty.fields[i].storage_type), type_ctx);
                    }
                }
                try self.pushVal(.{ .Ref = RefType.init(false, HeapType.fromConcreteType(type_idx)) });
            },
            .struct_get, .struct_get_s, .struct_get_u => {
                const type_idx = try concreteIndexFromPayload(op_info.ref_type, type_ctx);
                const struct_ty = switch (type_ctx.composite_types[type_idx]) {
                    .struct_type => |st| st,
                    else => return error.InvalidCompositeTypeIndex,
                };
                const field_idx = op_info.field_index orelse return error.UnknownField;
                if (field_idx >= struct_ty.fields.len) return error.UnknownField;
                const field = struct_ty.fields[field_idx];
                const is_packed = field.storage_type == .packed_type;
                if (op_info.code == .struct_get and is_packed) return error.PackedFieldAccessMismatch;
                if ((op_info.code == .struct_get_s or op_info.code == .struct_get_u) and !is_packed) {
                    return error.PackedFieldAccessMismatch;
                }
                _ = try self.popExpect(.{ .Ref = RefType.init(true, HeapType.fromConcreteType(type_idx)) }, type_ctx);
                try self.pushVal(subtyping.unpackStorageType(field.storage_type));
            },
            .struct_set => {
                const type_idx = try concreteIndexFromPayload(op_info.ref_type, type_ctx);
                const struct_ty = switch (type_ctx.composite_types[type_idx]) {
                    .struct_type => |st| st,
                    else => return error.InvalidCompositeTypeIndex,
                };
                const field_idx = op_info.field_index orelse return error.UnknownField;
                if (field_idx >= struct_ty.fields.len) return error.UnknownField;
                const field = struct_ty.fields[field_idx];
                if (!field.mutable) return error.ImmutableField;
                _ = try self.popExpect(subtyping.unpackStorageType(field.storage_type), type_ctx);
                _ = try self.popExpect(.{ .Ref = RefType.init(true, HeapType.fromConcreteType(type_idx)) }, type_ctx);
            },

            // GC Arrays
            .array_new => {
                const type_idx = try concreteIndexFromPayload(op_info.ref_type, type_ctx);
                const array_ty = switch (type_ctx.composite_types[type_idx]) {
                    .array_type => |at| at,
                    else => return error.InvalidCompositeTypeIndex,
                };
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(subtyping.unpackStorageType(array_ty.field.storage_type), type_ctx);
                try self.pushVal(.{ .Ref = RefType.init(false, HeapType.fromConcreteType(type_idx)) });
            },
            .array_new_default => {
                const type_idx = try concreteIndexFromPayload(op_info.ref_type, type_ctx);
                const array_ty = switch (type_ctx.composite_types[type_idx]) {
                    .array_type => |at| at,
                    else => return error.InvalidCompositeTypeIndex,
                };
                if (!subtyping.isStorageTypeDefaultable(array_ty.field.storage_type)) return error.NonDefaultableType;
                _ = try self.popExpect(.I32, type_ctx);
                try self.pushVal(.{ .Ref = RefType.init(false, HeapType.fromConcreteType(type_idx)) });
            },
            .array_new_fixed => {
                const type_idx = try concreteIndexFromPayload(op_info.ref_type, type_ctx);
                const array_ty = switch (type_ctx.composite_types[type_idx]) {
                    .array_type => |at| at,
                    else => return error.InvalidCompositeTypeIndex,
                };
                const n = op_info.len orelse return error.InvalidArity;
                const elem_vt = subtyping.unpackStorageType(array_ty.field.storage_type);
                for (0..n) |_| {
                    _ = try self.popExpect(elem_vt, type_ctx);
                }
                try self.pushVal(.{ .Ref = RefType.init(false, HeapType.fromConcreteType(type_idx)) });
            },
            .array_new_data, .array_init_data => {
                const type_idx = try concreteIndexFromPayload(op_info.ref_type, type_ctx);
                const array_ty = switch (type_ctx.composite_types[type_idx]) {
                    .array_type => |at| at,
                    else => return error.InvalidCompositeTypeIndex,
                };
                if (!ctx.has_data_count) return error.MissingDataCountSection;
                const data_idx = op_info.segment_index orelse return error.UnknownDataSegment;
                if (data_idx >= ctx.data_segments_count) return error.UnknownDataSegment;
                if (array_ty.field.storage_type == .valtype and array_ty.field.storage_type.valtype == .Ref) {
                    return error.TypeMismatch;
                }
                if (op_info.code == .array_init_data) {
                    if (!array_ty.field.mutable) return error.ImmutableField;
                    _ = try self.popExpect(.I32, type_ctx);
                    _ = try self.popExpect(.I32, type_ctx);
                    _ = try self.popExpect(.I32, type_ctx);
                    _ = try self.popExpect(.{ .Ref = RefType.init(true, HeapType.fromConcreteType(type_idx)) }, type_ctx);
                } else {
                    _ = try self.popExpect(.I32, type_ctx);
                    _ = try self.popExpect(.I32, type_ctx);
                    try self.pushVal(.{ .Ref = RefType.init(false, HeapType.fromConcreteType(type_idx)) });
                }
            },
            .array_new_elem, .array_init_elem => {
                const type_idx = try concreteIndexFromPayload(op_info.ref_type, type_ctx);
                const array_ty = switch (type_ctx.composite_types[type_idx]) {
                    .array_type => |at| at,
                    else => return error.InvalidCompositeTypeIndex,
                };
                const elem_idx = op_info.segment_index orelse return error.UnknownElemSegment;
                if (elem_idx >= ctx.elem_segment_types.len) return error.UnknownElemSegment;
                if (!subtyping.storageTypeMatches(.{ .valtype = ctx.elem_segment_types[elem_idx] }, array_ty.field.storage_type, type_ctx)) {
                    return error.TypeMismatch;
                }
                if (op_info.code == .array_init_elem) {
                    if (!array_ty.field.mutable) return error.ImmutableField;
                    _ = try self.popExpect(.I32, type_ctx);
                    _ = try self.popExpect(.I32, type_ctx);
                    _ = try self.popExpect(.I32, type_ctx);
                    _ = try self.popExpect(.{ .Ref = RefType.init(true, HeapType.fromConcreteType(type_idx)) }, type_ctx);
                } else {
                    _ = try self.popExpect(.I32, type_ctx);
                    _ = try self.popExpect(.I32, type_ctx);
                    try self.pushVal(.{ .Ref = RefType.init(false, HeapType.fromConcreteType(type_idx)) });
                }
            },
            .array_get, .array_get_s, .array_get_u => {
                const type_idx = try concreteIndexFromPayload(op_info.ref_type, type_ctx);
                const array_ty = switch (type_ctx.composite_types[type_idx]) {
                    .array_type => |at| at,
                    else => return error.InvalidCompositeTypeIndex,
                };
                const is_packed = array_ty.field.storage_type == .packed_type;
                if (op_info.code == .array_get and is_packed) return error.PackedFieldAccessMismatch;
                if ((op_info.code == .array_get_s or op_info.code == .array_get_u) and !is_packed) {
                    return error.PackedFieldAccessMismatch;
                }
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(.{ .Ref = RefType.init(true, HeapType.fromConcreteType(type_idx)) }, type_ctx);
                try self.pushVal(subtyping.unpackStorageType(array_ty.field.storage_type));
            },
            .array_set => {
                const type_idx = try concreteIndexFromPayload(op_info.ref_type, type_ctx);
                const array_ty = switch (type_ctx.composite_types[type_idx]) {
                    .array_type => |at| at,
                    else => return error.InvalidCompositeTypeIndex,
                };
                if (!array_ty.field.mutable) return error.ImmutableField;
                _ = try self.popExpect(subtyping.unpackStorageType(array_ty.field.storage_type), type_ctx);
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(.{ .Ref = RefType.init(true, HeapType.fromConcreteType(type_idx)) }, type_ctx);
            },
            .array_len => {
                _ = try self.popExpect(ValType.arrayref(), type_ctx);
                try self.pushVal(.I32);
            },
            .array_fill => {
                const type_idx = try concreteIndexFromPayload(op_info.ref_type, type_ctx);
                const array_ty = switch (type_ctx.composite_types[type_idx]) {
                    .array_type => |at| at,
                    else => return error.InvalidCompositeTypeIndex,
                };
                if (!array_ty.field.mutable) return error.ImmutableField;
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(subtyping.unpackStorageType(array_ty.field.storage_type), type_ctx);
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(.{ .Ref = RefType.init(true, HeapType.fromConcreteType(type_idx)) }, type_ctx);
            },
            .array_copy => {
                const dst_idx = try concreteIndexFromPayload(op_info.ref_type, type_ctx);
                const src_idx = try concreteIndexFromPayload(op_info.src_type, type_ctx);
                const dst_arr = switch (type_ctx.composite_types[dst_idx]) {
                    .array_type => |at| at,
                    else => return error.InvalidCompositeTypeIndex,
                };
                const src_arr = switch (type_ctx.composite_types[src_idx]) {
                    .array_type => |at| at,
                    else => return error.InvalidCompositeTypeIndex,
                };
                if (!dst_arr.field.mutable) return error.ImmutableField;
                if (!subtyping.storageTypeMatches(src_arr.field.storage_type, dst_arr.field.storage_type, type_ctx)) {
                    return error.TypeMismatch;
                }
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(.{ .Ref = RefType.init(true, HeapType.fromConcreteType(src_idx)) }, type_ctx);
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(.{ .Ref = RefType.init(true, HeapType.fromConcreteType(dst_idx)) }, type_ctx);
            },

            // GC i31, casts, conversions
            .ref_i31 => {
                _ = try self.popExpect(.I32, type_ctx);
                try self.pushVal(.{ .Ref = RefType.init(false, .I31) });
            },
            .i31_get_s, .i31_get_u => {
                _ = try self.popExpect(.{ .Ref = RefType.init(true, .I31) }, type_ctx);
                try self.pushVal(.I32);
            },
            .ref_test, .ref_test_null => {
                const ht = try subtyping.payloadHeapTypeToCore(op_info.ref_type orelse return error.UnknownType, type_ctx);
                const top_ht = topHeapTypeFor(try subtyping.heapTypeTop(ht, type_ctx));
                _ = try self.popExpect(.{ .Ref = RefType.init(true, top_ht) }, type_ctx);
                try self.pushVal(.I32);
            },
            .ref_cast, .ref_cast_null => {
                const ht = try subtyping.payloadHeapTypeToCore(op_info.ref_type orelse return error.UnknownType, type_ctx);
                const top_ht = topHeapTypeFor(try subtyping.heapTypeTop(ht, type_ctx));
                _ = try self.popExpect(.{ .Ref = RefType.init(true, top_ht) }, type_ctx);
                const nullable = op_info.code == .ref_cast_null;
                try self.pushVal(.{ .Ref = RefType.init(nullable, ht) });
            },
            .br_on_cast, .br_on_cast_fail => {
                const flags_raw: i64 = if (op_info.literal) |lit| lit.number else return error.InvalidCastFlags;
                if (flags_raw < 0 or flags_raw > 3) return error.InvalidCastFlags;
                const flags: u8 = @intCast(flags_raw);
                const depth = op_info.br_depth orelse return error.UnknownLabel;
                if (depth >= self.ctrl_stack.items.len) return error.UnknownLabel;

                const ht1 = try subtyping.payloadHeapTypeToCore(op_info.src_type orelse return error.UnknownType, type_ctx);
                const ht2 = try subtyping.payloadHeapTypeToCore(op_info.ref_type orelse return error.UnknownType, type_ctx);
                const rt1 = RefType.init((flags & 0x01) != 0, ht1);
                const rt2 = RefType.init((flags & 0x02) != 0, ht2);
                if (!subtyping.refTypeMatches(rt2, rt1, type_ctx)) return error.TypeMismatch;

                const diff_rt = RefType.init(rt1.nullable and !rt2.nullable, ht1);
                const is_cast = op_info.code == .br_on_cast;
                const branch_rt = if (is_cast) rt2 else diff_rt;
                const fallthrough_rt = if (is_cast) diff_rt else rt2;

                const target = &self.ctrl_stack.items[self.ctrl_stack.items.len - 1 - depth];
                var scratch_one: [1]ValType = undefined;
                const label_types = frameLabelTypes(target, &scratch_one);
                if (label_types.len == 0) return error.TypeMismatch;
                if (!subtyping.valTypeMatches(.{ .Ref = branch_rt }, label_types[label_types.len - 1], type_ctx)) {
                    return error.TypeMismatch;
                }

                _ = try self.popExpect(.{ .Ref = rt1 }, type_ctx);
                const prefix = label_types[0 .. label_types.len - 1];
                try self.popExpectVals(prefix, type_ctx);
                try self.pushVals(prefix);
                try self.pushVal(.{ .Ref = fallthrough_rt });
            },
            .any_convert_extern => {
                const popped = try self.popExpect(ValType.externref(), type_ctx);
                const nullable = switch (popped) {
                    .val => |v| v.Ref.nullable,
                    else => false,
                };
                try self.pushVal(.{ .Ref = RefType.init(nullable, .Any) });
            },
            .extern_convert_any => {
                const popped = try self.popExpect(ValType.anyref(), type_ctx);
                const nullable = switch (popped) {
                    .val => |v| v.Ref.nullable,
                    else => false,
                };
                try self.pushVal(.{ .Ref = RefType.init(nullable, .Extern) });
            },

            // Exception handling
            .throw => {
                const tag_idx = op_info.tag_index orelse return error.UnknownTag;
                if (tag_idx >= ctx.tags.len) return error.UnknownTag;
                const tag_ft = try getFuncTypeByIndex(type_ctx, ctx.tags[tag_idx]);
                try self.popExpectVals(tag_ft.params(), type_ctx);
                try self.markUnreachable();
            },
            .throw_ref => {
                _ = try self.popExpect(ValType.exnref(), type_ctx);
                try self.markUnreachable();
            },
            .try_table => {
                if (ctx.eh_mode == .legacy and !ctx.config.legacy_exceptions) {
                    // Notice new and legacy EH proposals cannot be mixed in the same module.
                    return error.MixedExceptionProposals;
                }
                const sig = try resolveBlockSig(op_info.block_type, type_ctx);
                for (op_info.try_table) |h| {
                    if (h.depth >= self.ctrl_stack.items.len) return error.UnknownLabel;
                    const target = &self.ctrl_stack.items[self.ctrl_stack.items.len - 1 - h.depth];
                    var scratch_one: [1]ValType = undefined;
                    const label_types = frameLabelTypes(target, &scratch_one);
                    switch (h.kind) {
                        .catch_, .catch_ref => {
                            const tag_idx = h.tag_index orelse return error.UnknownTag;
                            if (tag_idx >= ctx.tags.len) return error.UnknownTag;
                            const tag_ft = try getFuncTypeByIndex(type_ctx, ctx.tags[tag_idx]);
                            const tag_params = tag_ft.params();
                            const expected_len = tag_params.len + @as(usize, if (h.kind == .catch_ref) 1 else 0);
                            if (label_types.len != expected_len) return error.TypeMismatch;
                            for (tag_params, 0..) |tp, k| {
                                if (!subtyping.valTypeMatches(tp, label_types[k], type_ctx)) return error.TypeMismatch;
                            }
                            if (h.kind == .catch_ref) {
                                const non_null_exn = ValType{ .Ref = RefType.init(false, .Exn) };
                                if (!subtyping.valTypeMatches(non_null_exn, label_types[tag_params.len], type_ctx)) {
                                    return error.TypeMismatch;
                                }
                            }
                        },
                        .catch_all => {
                            if (label_types.len != 0) return error.TypeMismatch;
                        },
                        .catch_all_ref => {
                            if (label_types.len != 1) return error.TypeMismatch;
                            const non_null_exn = ValType{ .Ref = RefType.init(false, .Exn) };
                            if (!subtyping.valTypeMatches(non_null_exn, label_types[0], type_ctx)) {
                                return error.TypeMismatch;
                            }
                        },
                    }
                }
                try self.pushControlFrame(.try_table, sig, type_ctx);
            },

            // Legacy exception handling
            .try_ => {
                if (ctx.eh_mode != .legacy and !ctx.config.legacy_exceptions) return error.UnsupportedOperator;
                const sig = try resolveBlockSig(op_info.block_type, type_ctx);
                try self.pushControlFrame(.try_, sig, type_ctx);
            },
            .catch_ => {
                if (ctx.eh_mode != .legacy and !ctx.config.legacy_exceptions) return error.UnsupportedOperator;
                const popped = try self.popControlFrame(type_ctx);
                if (popped.kind != .try_ and popped.kind != .catch_) return error.MismatchedControlFlow;
                const tag_idx = op_info.tag_index orelse return error.UnknownTag;
                if (tag_idx >= ctx.tags.len) return error.UnknownTag;
                const tag_ft = try getFuncTypeByIndex(type_ctx, ctx.tags[tag_idx]);
                try self.ctrl_stack.append(self.allocator, .{
                    .kind = .catch_,
                    .sig = popped.sig,
                    .height = popped.height,
                    .unreachable_flag = false,
                    .local_init_mark = popped.local_init_mark,
                });
                try self.pushVals(tag_ft.params());
            },
            .catch_all => {
                if (ctx.eh_mode != .legacy and !ctx.config.legacy_exceptions) return error.UnsupportedOperator;
                const popped = try self.popControlFrame(type_ctx);
                if (popped.kind != .try_ and popped.kind != .catch_) return error.MismatchedControlFlow;
                try self.ctrl_stack.append(self.allocator, .{
                    .kind = .catch_all,
                    .sig = popped.sig,
                    .height = popped.height,
                    .unreachable_flag = false,
                    .local_init_mark = popped.local_init_mark,
                });
            },
            .rethrow => {
                if (ctx.eh_mode != .legacy and !ctx.config.legacy_exceptions) return error.UnsupportedOperator;
                const depth = op_info.relative_depth orelse return error.UnknownLabel;
                if (depth >= self.ctrl_stack.items.len) return error.UnknownLabel;
                const target = &self.ctrl_stack.items[self.ctrl_stack.items.len - 1 - depth];
                if (target.kind != .catch_ and target.kind != .catch_all) return error.MismatchedControlFlow;
                try self.markUnreachable();
            },
            .delegate => {
                if (ctx.eh_mode != .legacy and !ctx.config.legacy_exceptions) return error.UnsupportedOperator;
                const popped = try self.popControlFrame(type_ctx);
                if (popped.kind != .try_) return error.MismatchedControlFlow;
                const depth = op_info.relative_depth orelse return error.UnknownLabel;
                if (depth >= self.ctrl_stack.items.len) return error.UnknownLabel;
                var scratch_one: [1]ValType = undefined;
                try self.pushVals(popped.sig.results(&scratch_one));
            },

            // Threads / Atomics
            .atomic_fence => {},
            .memory_atomic_notify => {
                try self.checkAtomicMem(ctx, op_info, 2);
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(addr_type, type_ctx);
                try self.pushVal(.I32);
            },
            .memory_atomic_wait32 => {
                try self.checkAtomicMem(ctx, op_info, 2);
                _ = try self.popExpect(.I64, type_ctx);
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(addr_type, type_ctx);
                try self.pushVal(.I32);
            },
            .memory_atomic_wait64 => {
                try self.checkAtomicMem(ctx, op_info, 3);
                _ = try self.popExpect(.I64, type_ctx);
                _ = try self.popExpect(.I64, type_ctx);
                _ = try self.popExpect(addr_type, type_ctx);
                try self.pushVal(.I32);
            },
            .i32_atomic_load => try self.checkAtomicLoad(ctx, op_info, addr_type, .I32, 2),
            .i32_atomic_load8_u => try self.checkAtomicLoad(ctx, op_info, addr_type, .I32, 0),
            .i32_atomic_load16_u => try self.checkAtomicLoad(ctx, op_info, addr_type, .I32, 1),
            .i64_atomic_load => try self.checkAtomicLoad(ctx, op_info, addr_type, .I64, 3),
            .i64_atomic_load8_u => try self.checkAtomicLoad(ctx, op_info, addr_type, .I64, 0),
            .i64_atomic_load16_u => try self.checkAtomicLoad(ctx, op_info, addr_type, .I64, 1),
            .i64_atomic_load32_u => try self.checkAtomicLoad(ctx, op_info, addr_type, .I64, 2),
            .i32_atomic_store => try self.checkAtomicStore(ctx, op_info, addr_type, .I32, 2),
            .i32_atomic_store8 => try self.checkAtomicStore(ctx, op_info, addr_type, .I32, 0),
            .i32_atomic_store16 => try self.checkAtomicStore(ctx, op_info, addr_type, .I32, 1),
            .i64_atomic_store => try self.checkAtomicStore(ctx, op_info, addr_type, .I64, 3),
            .i64_atomic_store8 => try self.checkAtomicStore(ctx, op_info, addr_type, .I64, 0),
            .i64_atomic_store16 => try self.checkAtomicStore(ctx, op_info, addr_type, .I64, 1),
            .i64_atomic_store32 => try self.checkAtomicStore(ctx, op_info, addr_type, .I64, 2),
            .i32_atomic_rmw_add, .i32_atomic_rmw_sub, .i32_atomic_rmw_and, .i32_atomic_rmw_or, .i32_atomic_rmw_xor, .i32_atomic_rmw_xchg => try self.checkAtomicRmw(ctx, op_info, addr_type, .I32, 2),
            .i32_atomic_rmw8_add_u, .i32_atomic_rmw8_sub_u, .i32_atomic_rmw8_and_u, .i32_atomic_rmw8_or_u, .i32_atomic_rmw8_xor_u, .i32_atomic_rmw8_xchg_u => try self.checkAtomicRmw(ctx, op_info, addr_type, .I32, 0),
            .i32_atomic_rmw16_add_u, .i32_atomic_rmw16_sub_u, .i32_atomic_rmw16_and_u, .i32_atomic_rmw16_or_u, .i32_atomic_rmw16_xor_u, .i32_atomic_rmw16_xchg_u => try self.checkAtomicRmw(ctx, op_info, addr_type, .I32, 1),
            .i64_atomic_rmw_add, .i64_atomic_rmw_sub, .i64_atomic_rmw_and, .i64_atomic_rmw_or, .i64_atomic_rmw_xor, .i64_atomic_rmw_xchg => try self.checkAtomicRmw(ctx, op_info, addr_type, .I64, 3),
            .i64_atomic_rmw8_add_u, .i64_atomic_rmw8_sub_u, .i64_atomic_rmw8_and_u, .i64_atomic_rmw8_or_u, .i64_atomic_rmw8_xor_u, .i64_atomic_rmw8_xchg_u => try self.checkAtomicRmw(ctx, op_info, addr_type, .I64, 0),
            .i64_atomic_rmw16_add_u, .i64_atomic_rmw16_sub_u, .i64_atomic_rmw16_and_u, .i64_atomic_rmw16_or_u, .i64_atomic_rmw16_xor_u, .i64_atomic_rmw16_xchg_u => try self.checkAtomicRmw(ctx, op_info, addr_type, .I64, 1),
            .i64_atomic_rmw32_add_u, .i64_atomic_rmw32_sub_u, .i64_atomic_rmw32_and_u, .i64_atomic_rmw32_or_u, .i64_atomic_rmw32_xor_u, .i64_atomic_rmw32_xchg_u => try self.checkAtomicRmw(ctx, op_info, addr_type, .I64, 2),
            .i32_atomic_rmw_cmpxchg => try self.checkAtomicCmpxchg(ctx, op_info, addr_type, .I32, 2),
            .i32_atomic_rmw8_cmpxchg_u => try self.checkAtomicCmpxchg(ctx, op_info, addr_type, .I32, 0),
            .i32_atomic_rmw16_cmpxchg_u => try self.checkAtomicCmpxchg(ctx, op_info, addr_type, .I32, 1),
            .i64_atomic_rmw_cmpxchg => try self.checkAtomicCmpxchg(ctx, op_info, addr_type, .I64, 3),
            .i64_atomic_rmw8_cmpxchg_u => try self.checkAtomicCmpxchg(ctx, op_info, addr_type, .I64, 0),
            .i64_atomic_rmw16_cmpxchg_u => try self.checkAtomicCmpxchg(ctx, op_info, addr_type, .I64, 1),
            .i64_atomic_rmw32_cmpxchg_u => try self.checkAtomicCmpxchg(ctx, op_info, addr_type, .I64, 2),

            else => return error.UnsupportedOperator,
        }
    }

    fn checkUnary(self: *FuncValidator, in_vt: ValType, out_vt: ValType, type_ctx: *const TypeContext) ValidateFuncError!void {
        _ = try self.popExpect(in_vt, type_ctx);
        try self.pushVal(out_vt);
    }

    fn checkLoad(
        self: *FuncValidator,
        ctx: *const FuncValidationContext,
        op_info: OperatorInformation,
        addr_type: ValType,
        res_vt: ValType,
        max_align: u32,
    ) ValidateFuncError!void {
        if (ctx.memory_count == 0) return error.UnknownMemory;
        const ma = op_info.memory_address orelse return error.InvalidAlignment;
        if (ma.flags > max_align) return error.InvalidAlignment;
        _ = try self.popExpect(addr_type, ctx.type_ctx);
        try self.pushVal(res_vt);
    }

    fn checkStore(
        self: *FuncValidator,
        ctx: *const FuncValidationContext,
        op_info: OperatorInformation,
        addr_type: ValType,
        val_vt: ValType,
        max_align: u32,
    ) ValidateFuncError!void {
        if (ctx.memory_count == 0) return error.UnknownMemory;
        const ma = op_info.memory_address orelse return error.InvalidAlignment;
        if (ma.flags > max_align) return error.InvalidAlignment;
        _ = try self.popExpect(val_vt, ctx.type_ctx);
        _ = try self.popExpect(addr_type, ctx.type_ctx);
    }

    fn checkAtomicMem(
        self: *FuncValidator,
        ctx: *const FuncValidationContext,
        op_info: OperatorInformation,
        exact_align: u32,
    ) ValidateFuncError!void {
        _ = self;
        if (ctx.memory_count == 0) return error.UnknownMemory;
        const ma = op_info.memory_address orelse return error.InvalidAlignment;
        if (ma.flags != exact_align) return error.InvalidAlignment;
    }

    fn checkAtomicLoad(
        self: *FuncValidator,
        ctx: *const FuncValidationContext,
        op_info: OperatorInformation,
        addr_type: ValType,
        res_vt: ValType,
        exact_align: u32,
    ) ValidateFuncError!void {
        try self.checkAtomicMem(ctx, op_info, exact_align);
        _ = try self.popExpect(addr_type, ctx.type_ctx);
        try self.pushVal(res_vt);
    }

    fn checkAtomicStore(
        self: *FuncValidator,
        ctx: *const FuncValidationContext,
        op_info: OperatorInformation,
        addr_type: ValType,
        val_vt: ValType,
        exact_align: u32,
    ) ValidateFuncError!void {
        try self.checkAtomicMem(ctx, op_info, exact_align);
        _ = try self.popExpect(val_vt, ctx.type_ctx);
        _ = try self.popExpect(addr_type, ctx.type_ctx);
    }

    fn checkAtomicRmw(
        self: *FuncValidator,
        ctx: *const FuncValidationContext,
        op_info: OperatorInformation,
        addr_type: ValType,
        vt: ValType,
        exact_align: u32,
    ) ValidateFuncError!void {
        try self.checkAtomicMem(ctx, op_info, exact_align);
        _ = try self.popExpect(vt, ctx.type_ctx);
        _ = try self.popExpect(addr_type, ctx.type_ctx);
        try self.pushVal(vt);
    }

    fn checkAtomicCmpxchg(
        self: *FuncValidator,
        ctx: *const FuncValidationContext,
        op_info: OperatorInformation,
        addr_type: ValType,
        vt: ValType,
        exact_align: u32,
    ) ValidateFuncError!void {
        try self.checkAtomicMem(ctx, op_info, exact_align);
        _ = try self.popExpect(vt, ctx.type_ctx);
        _ = try self.popExpect(vt, ctx.type_ctx);
        _ = try self.popExpect(addr_type, ctx.type_ctx);
        try self.pushVal(vt);
    }

    fn validateSimdOp(
        self: *FuncValidator,
        ctx: *const FuncValidationContext,
        op_info: OperatorInformation,
        addr_type: ValType,
    ) ValidateFuncError!void {
        const type_ctx = ctx.type_ctx;
        const class = simd.classifyOpcode(op_info.code) orelse return error.UnsupportedOperator;

        switch (class) {
            .const_ => try self.pushVal(.V128),
            .shuffle => {
                const lanes = op_info.lines orelse return error.InvalidLaneIndex;
                if (lanes.len != 16) return error.InvalidLaneIndex;
                for (lanes) |l| {
                    if (l >= 32) return error.InvalidLaneIndex;
                }
                _ = try self.popExpect(.V128, type_ctx);
                _ = try self.popExpect(.V128, type_ctx);
                try self.pushVal(.V128);
            },
            .extract_lane => {
                const shape = simd.shapeOf(op_info.code) orelse return error.UnsupportedOperator;
                const lane = op_info.line_index orelse return error.InvalidLaneIndex;
                if (lane >= simd.laneCount(shape)) return error.InvalidLaneIndex;
                _ = try self.popExpect(.V128, type_ctx);
                try self.pushVal(scalarValTypeForShape(shape));
            },
            .replace_lane => {
                const shape = simd.shapeOf(op_info.code) orelse return error.UnsupportedOperator;
                const lane = op_info.line_index orelse return error.InvalidLaneIndex;
                if (lane >= simd.laneCount(shape)) return error.InvalidLaneIndex;
                _ = try self.popExpect(scalarValTypeForShape(shape), type_ctx);
                _ = try self.popExpect(.V128, type_ctx);
                try self.pushVal(.V128);
            },
            .load => {
                if (ctx.memory_count == 0) return error.UnknownMemory;
                const ma = op_info.memory_address orelse return error.InvalidAlignment;
                const max_align = simdLoadMaxAlign(op_info.code);
                if (ma.flags > max_align) return error.InvalidAlignment;
                if (simd.isLaneLoadOpcode(op_info.code)) {
                    const lane = op_info.line_index orelse return error.InvalidLaneIndex;
                    const limit = 16 / simd.laneImmediateFromOpcode(op_info.code);
                    if (lane >= limit) return error.InvalidLaneIndex;
                    _ = try self.popExpect(.V128, type_ctx);
                }
                _ = try self.popExpect(addr_type, type_ctx);
                try self.pushVal(.V128);
            },
            .store => {
                if (ctx.memory_count == 0) return error.UnknownMemory;
                const ma = op_info.memory_address orelse return error.InvalidAlignment;
                const max_align = simdStoreMaxAlign(op_info.code);
                if (ma.flags > max_align) return error.InvalidAlignment;
                if (simd.isLaneStoreOpcode(op_info.code)) {
                    const lane = op_info.line_index orelse return error.InvalidLaneIndex;
                    const limit = 16 / simd.laneImmediateFromOpcode(op_info.code);
                    if (lane >= limit) return error.InvalidLaneIndex;
                }
                _ = try self.popExpect(.V128, type_ctx);
                _ = try self.popExpect(addr_type, type_ctx);
            },
            .shift => {
                _ = try self.popExpect(.I32, type_ctx);
                _ = try self.popExpect(.V128, type_ctx);
                try self.pushVal(.V128);
            },
            .compare, .binary => {
                _ = try self.popExpect(.V128, type_ctx);
                _ = try self.popExpect(.V128, type_ctx);
                try self.pushVal(.V128);
            },
            .ternary => {
                _ = try self.popExpect(.V128, type_ctx);
                _ = try self.popExpect(.V128, type_ctx);
                _ = try self.popExpect(.V128, type_ctx);
                try self.pushVal(.V128);
            },
            .unary => {
                if (simd.isSplatOpcode(op_info.code)) {
                    const shape = simd.shapeOf(op_info.code) orelse return error.UnsupportedOperator;
                    _ = try self.popExpect(scalarValTypeForShape(shape), type_ctx);
                    try self.pushVal(.V128);
                } else if (!simd.isVectorResultOpcode(op_info.code)) {
                    _ = try self.popExpect(.V128, type_ctx);
                    try self.pushVal(.I32);
                } else {
                    _ = try self.popExpect(.V128, type_ctx);
                    try self.pushVal(.V128);
                }
            },
        }
    }
};

fn checkReturnCallResults(
    callee_results: []const ValType,
    func_results: []const ValType,
    type_ctx: *const TypeContext,
) ValidationError!void {
    if (callee_results.len != func_results.len) return error.TypeMismatch;
    for (callee_results, func_results) |cr, fr| {
        if (!subtyping.valTypeMatches(cr, fr, type_ctx)) return error.TypeMismatch;
    }
}

fn concreteIndexFromPayload(ht_opt: ?payload_mod.HeapType, type_ctx: *const TypeContext) ValidationError!u32 {
    const ht = ht_opt orelse return error.UnknownType;
    return switch (ht) {
        .index => |idx| blk: {
            if (idx >= type_ctx.composite_types.len) return error.UnknownType;
            break :blk idx;
        },
        .kind => error.UnknownType,
    };
}

fn topHeapTypeFor(top: subtyping.HeapTop) HeapType {
    return switch (top) {
        .any => .Any,
        .func => .Func,
        .extern_ => .Extern,
        .exn => .Exn,
    };
}

fn scalarValTypeForShape(shape: simd.SimdShape) ValType {
    return switch (shape) {
        .i8x16, .i16x8, .i32x4 => .I32,
        .i64x2 => .I64,
        .f32x4 => .F32,
        .f64x2 => .F64,
    };
}

fn simdLoadMaxAlign(code: OperatorCode) u32 {
    return switch (code) {
        .v128_load => 4,
        .v8x16_load_splat, .v128_load8_lane => 0,
        .v16x8_load_splat, .v128_load16_lane => 1,
        .v32x4_load_splat, .v128_load32_zero, .v128_load32_lane => 2,
        else => 3, // load8x8, load16x4, load32x2, load64_splat, load64_zero, load64_lane
    };
}

fn simdStoreMaxAlign(code: OperatorCode) u32 {
    return switch (code) {
        .v128_store => 4,
        .v128_store8_lane => 0,
        .v128_store16_lane => 1,
        .v128_store32_lane => 2,
        .v128_store64_lane => 3,
        else => unreachable,
    };
}

/// module_validator.zig — WebAssembly module-level & constant-expression validator.
const std = @import("std");
const core = @import("core");
const parser_mod = @import("parser");
const payload_mod = @import("payload");
const engine_config_mod = @import("../engine/config.zig");
const subtyping = @import("subtyping.zig");
const func_validator = @import("func_validator.zig");

const Allocator = std.mem.Allocator;
const ValType = core.ValType;
const HeapType = core.HeapType;
const RefType = core.RefType;
const FuncType = core.FuncType;
const ExternalKind = payload_mod.ExternalKind;
const ElementMode = payload_mod.ElementMode;
const DataMode = payload_mod.DataMode;
const FunctionInformation = payload_mod.FunctionInformation;
const EngineConfig = engine_config_mod.Config;
const TypeContext = subtyping.TypeContext;
const ValidationError = subtyping.ValidationError;
const GlobalTypeInfo = func_validator.GlobalTypeInfo;
const ValidatorEHMode = func_validator.ValidatorEHMode;
const FuncValidator = func_validator.FuncValidator;
const FuncValidationContext = func_validator.FuncValidationContext;
const ValidateFuncError = func_validator.ValidateFuncError;

pub const TableDefInfo = struct {
    val_type: ValType,
    min: u64,
    max: ?u64,
};

pub const MemoryDefInfo = struct {
    min_pages: u64,
    max_pages: ?u64,
    shared: bool,
    memory64: bool,
};

pub const LocalGlobalInfo = struct {
    val_type: ValType,
    mutable: bool,
    init_expr: []const u8,
};

pub const ExportCheckInfo = struct {
    kind: ExternalKind,
    index: u32,
};

pub const ElemSegmentInfo = struct {
    mode: ElementMode,
    table_index: u32,
    elem_type: ValType,
    elemkind: u8,
    is_externval: bool,
    func_indices: []const u32,
    elem_exprs: []const []const u8,
    offset_expr: []const u8,
};

pub const DataSegmentInfo = struct {
    mode: DataMode,
    memory_index: u32,
    offset_expr: []const u8,
};

pub const ModuleValidationInput = struct {
    allocator: Allocator,
    type_ctx: TypeContext,
    super_type_counts: []const usize,
    func_type_indices: []const u32,
    table_defs: []const TableDefInfo,
    memories: []const MemoryDefInfo,
    imported_globals: []const GlobalTypeInfo,
    local_globals: []const LocalGlobalInfo,
    tags: []const u32,
    exports: []const ExportCheckInfo,
    start_function: ?u32,
    elem_segments: []const ElemSegmentInfo,
    data_segments: []const DataSegmentInfo,
    data_count: ?u32,
    local_funcs: []const FunctionInformation,
    local_func_type_indices: []const u32,
    eh_mode: ValidatorEHMode,
    config: EngineConfig,
};

pub const ValidateModuleError = ValidateFuncError || parser_mod.CodeReadError;

pub fn validateModule(input: *const ModuleValidationInput) ValidateModuleError!void {
    const allocator = input.allocator;
    const type_ctx = &input.type_ctx;
    const n_types = type_ctx.composite_types.len;

    // 1. Validate Type Section (subtyping, finality, depth <= 63, rec-group forward refs).
    try subtyping.validateTypeSection(type_ctx, input.super_type_counts);

    // 2. Validate function type indices (imports + locals).
    for (input.func_type_indices) |t_idx| {
        if (t_idx >= n_types) return error.UnknownType;
        if (type_ctx.composite_types[t_idx] != .func_type) return error.InvalidCompositeTypeIndex;
    }

    // 3. Validate tag signatures (must point to func_type with empty results).
    for (input.tags) |t_idx| {
        if (t_idx >= n_types) return error.UnknownType;
        const ft = switch (type_ctx.composite_types[t_idx]) {
            .func_type => |ft| ft,
            else => return error.InvalidCompositeTypeIndex,
        };
        if (ft.results().len != 0) return error.InvalidTagType;
    }

    // 4. Validate tables (ref elem type, valid concrete refs, limits, defaultability).
    for (input.table_defs) |tbl| {
        if (tbl.val_type != .Ref) return error.TypeMismatch;
        try subtyping.validateValType(tbl.val_type, type_ctx);
        if (!subtyping.isValTypeDefaultable(tbl.val_type)) return error.NonDefaultableType;
        if (tbl.min > std.math.maxInt(u32)) return error.InvalidTableLimits;
        if (tbl.max) |mx| {
            if (mx > std.math.maxInt(u32) or tbl.min > mx) return error.InvalidTableLimits;
        }
    }

    // 5. Validate memories (at most 1 memory, page limits, shared requires max).
    if (input.memories.len > 1) return error.InvalidMemoryLimits;
    for (input.memories) |mem| {
        const cap: u64 = if (mem.memory64) (@as(u64, 1) << 48) else 65536;
        if (mem.min_pages > cap) return error.InvalidMemoryLimits;
        if (mem.max_pages) |mx| {
            if (mx > cap or mem.min_pages > mx) return error.InvalidMemoryLimits;
        } else if (mem.shared) {
            return error.InvalidMemoryLimits;
        }
    }

    // Scratch arena for temporary validation slices and constant expression decoding.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    // Assemble combined global type table (imported + local) and table type list.
    const total_globals = input.imported_globals.len + input.local_globals.len;
    const all_globals = try scratch.alloc(GlobalTypeInfo, total_globals);
    for (input.imported_globals, 0..) |ig, i| {
        try subtyping.validateValType(ig.val_type, type_ctx);
        all_globals[i] = ig;
    }
    for (input.local_globals, 0..) |lg, i| {
        try subtyping.validateValType(lg.val_type, type_ctx);
        all_globals[input.imported_globals.len + i] = .{
            .val_type = lg.val_type,
            .mutable = lg.mutable,
        };
    }

    const table_types = try scratch.alloc(ValType, input.table_defs.len);
    for (input.table_defs, 0..) |tbl, i| {
        table_types[i] = tbl.val_type;
    }

    // Track declared functions (`C.refs`): globals, element segments, and exports.
    var declared_funcs: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer declared_funcs.deinit(allocator);

    // 6. Validate local globals and their initializer constant expressions.
    for (input.local_globals, 0..) |lg, i| {
        const visible_globals = input.imported_globals.len + i;
        try validateConstExpr(
            scratch,
            lg.init_expr,
            lg.val_type,
            type_ctx,
            input.func_type_indices,
            all_globals[0..visible_globals],
            &declared_funcs,
            allocator,
            input.config,
        );
    }

    // 7. Validate exports and collect exported function indices into C.refs.
    for (input.exports) |exp| {
        switch (exp.kind) {
            .function => {
                if (exp.index >= input.func_type_indices.len) return error.UnknownFunction;
                try declared_funcs.put(allocator, exp.index, {});
            },
            .table => if (exp.index >= input.table_defs.len) return error.UnknownTable,
            .memory => if (exp.index >= input.memories.len) return error.UnknownMemory,
            .global => if (exp.index >= total_globals) return error.UnknownGlobal,
            .tag => if (exp.index >= input.tags.len) return error.UnknownTag,
        }
    }

    // 8. Validate start function signature.
    if (input.start_function) |start_idx| {
        if (start_idx >= input.func_type_indices.len) return error.UnknownFunction;
        const start_ft = type_ctx.composite_types[input.func_type_indices[start_idx]].func_type;
        if (start_ft.params().len != 0 or start_ft.results().len != 0) {
            return error.InvalidStartFunction;
        }
    }

    // 9. Validate element segments and populate C.refs + elem_segment_types.
    const elem_segment_types = try scratch.alloc(ValType, input.elem_segments.len);
    for (input.elem_segments, 0..) |seg, i| {
        try subtyping.validateValType(seg.elem_type, type_ctx);
        elem_segment_types[i] = seg.elem_type;

        if (seg.mode == .active) {
            if (seg.table_index >= input.table_defs.len) return error.UnknownTable;
            if (!subtyping.valTypeMatches(seg.elem_type, input.table_defs[seg.table_index].val_type, type_ctx)) {
                return error.TypeMismatch;
            }
            try validateConstExpr(
                scratch,
                seg.offset_expr,
                .I32,
                type_ctx,
                input.func_type_indices,
                all_globals,
                &declared_funcs,
                allocator,
                input.config,
            );
        }

        if (seg.is_externval) {
            if (seg.elemkind != 0x00) return error.InvalidElemKind;
            for (seg.func_indices) |f_idx| {
                if (f_idx >= input.func_type_indices.len) return error.UnknownFunction;
                try declared_funcs.put(allocator, f_idx, {});
                const f_ref = ValType{
                    .Ref = RefType.init(false, HeapType.fromConcreteType(input.func_type_indices[f_idx])),
                };
                if (!subtyping.valTypeMatches(f_ref, seg.elem_type, type_ctx)) {
                    return error.TypeMismatch;
                }
            }
        } else {
            for (seg.elem_exprs) |expr| {
                try validateConstExpr(
                    scratch,
                    expr,
                    seg.elem_type,
                    type_ctx,
                    input.func_type_indices,
                    all_globals,
                    &declared_funcs,
                    allocator,
                    input.config,
                );
            }
        }
    }

    // 10. Validate DataCount section and Data segments.
    if (input.data_count) |dc| {
        if (dc != input.data_segments.len) return error.DataCountMismatch;
    }
    for (input.data_segments) |seg| {
        if (seg.mode == .active) {
            if (input.memories.len == 0) return error.UnknownMemory;
            if (seg.memory_index != 0) return error.InvalidMemoryIndex;
            const offset_ty: ValType = if (input.memories[0].memory64) .I64 else .I32;
            try validateConstExpr(
                scratch,
                seg.offset_expr,
                offset_ty,
                type_ctx,
                input.func_type_indices,
                all_globals,
                &declared_funcs,
                allocator,
                input.config,
            );
        }
    }

    // 11. Validate every local function body using a single reusable FuncValidator.
    const memory64 = if (input.memories.len > 0) input.memories[0].memory64 else false;
    const f_ctx = FuncValidationContext{
        .type_ctx = type_ctx,
        .func_type_indices = input.func_type_indices,
        .table_types = table_types,
        .global_types = all_globals,
        .tags = input.tags,
        .memory_count = @intCast(input.memories.len),
        .memory64 = memory64,
        .data_segments_count = @intCast(input.data_segments.len),
        .has_data_count = input.data_count != null,
        .elem_segment_types = elem_segment_types,
        .declared_funcs = &declared_funcs,
        .eh_mode = input.eh_mode,
        .config = input.config,
    };

    var fv = FuncValidator.init(allocator);
    defer fv.deinit();

    var func_scratch = std.heap.ArenaAllocator.init(allocator);
    defer func_scratch.deinit();

    for (input.local_funcs, input.local_func_type_indices) |info, t_idx| {
        _ = func_scratch.reset(.retain_capacity);
        const ft = &type_ctx.composite_types[t_idx].func_type;
        try fv.validateFunction(&f_ctx, ft, info, func_scratch.allocator());
    }
}

/// Validates a constant expression (global init, active data/elem offset, elem item).
fn validateConstExpr(
    scratch: Allocator,
    expr: []const u8,
    expected_type: ValType,
    type_ctx: *const TypeContext,
    func_type_indices: []const u32,
    visible_globals: []const GlobalTypeInfo,
    declared_funcs: *std.AutoHashMapUnmanaged(u32, void),
    decl_allocator: Allocator,
    config: EngineConfig,
) ValidateModuleError!void {
    var stack: std.ArrayListUnmanaged(ValType) = .empty;
    var fbp = parser_mod.FunctionBodyParser.init(scratch, expr);
    var saw_end = false;

    while (!fbp.done()) {
        const op_info = try fbp.next();
        switch (op_info.code) {
            .end => {
                if (!fbp.done()) return error.InvalidConstExpr;
                saw_end = true;
                break;
            },
            .i32_const => try stack.append(scratch, .I32),
            .i64_const => try stack.append(scratch, .I64),
            .f32_const => try stack.append(scratch, .F32),
            .f64_const => try stack.append(scratch, .F64),
            .v128_const => {
                if (!config.simd) return error.DisabledSimd;
                try stack.append(scratch, .V128);
            },
            .ref_null => {
                const ht = try subtyping.payloadHeapTypeToCore(op_info.ref_type orelse return error.UnknownType, type_ctx);
                try stack.append(scratch, .{ .Ref = RefType.init(true, ht) });
            },
            .ref_func => {
                const f_idx = op_info.func_index orelse return error.UnknownFunction;
                if (f_idx >= func_type_indices.len) return error.UnknownFunction;
                try declared_funcs.put(decl_allocator, f_idx, {});
                const t_idx = func_type_indices[f_idx];
                try stack.append(scratch, .{ .Ref = RefType.init(false, HeapType.fromConcreteType(t_idx)) });
            },
            .global_get => {
                const g_idx = op_info.global_index orelse return error.UnknownGlobal;
                if (g_idx >= visible_globals.len) return error.UnknownGlobal;
                if (visible_globals[g_idx].mutable) return error.InvalidConstExpr;
                try stack.append(scratch, visible_globals[g_idx].val_type);
            },
            .i32_add, .i32_sub, .i32_mul => {
                try popConstExpect(&stack, .I32, type_ctx);
                try popConstExpect(&stack, .I32, type_ctx);
                try stack.append(scratch, .I32);
            },
            .i64_add, .i64_sub, .i64_mul => {
                try popConstExpect(&stack, .I64, type_ctx);
                try popConstExpect(&stack, .I64, type_ctx);
                try stack.append(scratch, .I64);
            },
            .struct_new, .struct_new_default => {
                const ht = op_info.ref_type orelse return error.UnknownType;
                const type_idx = switch (ht) {
                    .index => |idx| idx,
                    .kind => return error.UnknownType,
                };
                if (type_idx >= type_ctx.composite_types.len) return error.UnknownType;
                const st = switch (type_ctx.composite_types[type_idx]) {
                    .struct_type => |s| s,
                    else => return error.InvalidCompositeTypeIndex,
                };
                if (op_info.code == .struct_new_default) {
                    for (st.fields) |f| {
                        if (!subtyping.isStorageTypeDefaultable(f.storage_type)) return error.NonDefaultableType;
                    }
                } else {
                    var i: usize = st.fields.len;
                    while (i > 0) {
                        i -= 1;
                        try popConstExpect(&stack, subtyping.unpackStorageType(st.fields[i].storage_type), type_ctx);
                    }
                }
                try stack.append(scratch, .{ .Ref = RefType.init(false, HeapType.fromConcreteType(type_idx)) });
            },
            .array_new, .array_new_default, .array_new_fixed => {
                const ht = op_info.ref_type orelse return error.UnknownType;
                const type_idx = switch (ht) {
                    .index => |idx| idx,
                    .kind => return error.UnknownType,
                };
                if (type_idx >= type_ctx.composite_types.len) return error.UnknownType;
                const at = switch (type_ctx.composite_types[type_idx]) {
                    .array_type => |a| a,
                    else => return error.InvalidCompositeTypeIndex,
                };
                switch (op_info.code) {
                    .array_new => {
                        try popConstExpect(&stack, .I32, type_ctx);
                        try popConstExpect(&stack, subtyping.unpackStorageType(at.field.storage_type), type_ctx);
                    },
                    .array_new_default => {
                        if (!subtyping.isStorageTypeDefaultable(at.field.storage_type)) return error.NonDefaultableType;
                        try popConstExpect(&stack, .I32, type_ctx);
                    },
                    .array_new_fixed => {
                        const n = op_info.len orelse return error.InvalidArity;
                        const elem_vt = subtyping.unpackStorageType(at.field.storage_type);
                        for (0..n) |_| {
                            try popConstExpect(&stack, elem_vt, type_ctx);
                        }
                    },
                    else => unreachable,
                }
                try stack.append(scratch, .{ .Ref = RefType.init(false, HeapType.fromConcreteType(type_idx)) });
            },
            .ref_i31 => {
                try popConstExpect(&stack, .I32, type_ctx);
                try stack.append(scratch, .{ .Ref = RefType.init(false, .I31) });
            },
            .any_convert_extern => {
                if (stack.items.len == 0) return error.TypeMismatch;
                const top = stack.pop().?;
                if (!subtyping.valTypeMatches(top, ValType.externref(), type_ctx)) return error.TypeMismatch;
                try stack.append(scratch, .{ .Ref = RefType.init(top.Ref.nullable, .Any) });
            },
            .extern_convert_any => {
                if (stack.items.len == 0) return error.TypeMismatch;
                const top = stack.pop().?;
                if (!subtyping.valTypeMatches(top, ValType.anyref(), type_ctx)) return error.TypeMismatch;
                try stack.append(scratch, .{ .Ref = RefType.init(top.Ref.nullable, .Extern) });
            },
            else => return error.InvalidConstExpr,
        }
    }

    if (!saw_end or stack.items.len != 1) return error.TypeMismatch;
    if (!subtyping.valTypeMatches(stack.items[0], expected_type, type_ctx)) return error.TypeMismatch;
}

fn popConstExpect(stack: *std.ArrayListUnmanaged(ValType), expected: ValType, type_ctx: *const TypeContext) ValidationError!void {
    const actual = stack.pop() orelse return error.TypeMismatch;
    if (!subtyping.valTypeMatches(actual, expected, type_ctx)) return error.TypeMismatch;
}

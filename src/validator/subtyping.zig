/// subtyping.zig — WebAssembly 2.0 + GC type validation and subtyping rules.
const std = @import("std");
const core = @import("core");
const payload_mod = @import("payload");

const ValType = core.ValType;
const HeapType = core.HeapType;
const RefType = core.RefType;
const StorageType = core.StorageType;
const FieldType = core.FieldType;
const StructType = core.StructType;
const ArrayType = core.ArrayType;
const FuncType = core.FuncType;
const CompositeType = core.CompositeType;

/// Maximum subtyping inheritance chain depth allowed by the Wasm GC specification.
pub const MAX_SUBTYPE_DEPTH: u32 = 63;

pub const ValidationError = error{
    InvalidSubtype,
    SubtypeDepthExceeded,
    ExtendFinalType,
    ForwardTypeReference,
    TypeMismatch,
    InvalidArity,
    NonDefaultableType,
    ImmutableField,
    ImmutableGlobal,
    UninitializedLocal,
    UndeclaredFuncRef,
    InvalidAlignment,
    InvalidLaneIndex,
    InvalidMemoryLimits,
    InvalidTableLimits,
    InvalidStartFunction,
    InvalidConstExpr,
    InvalidTagType,
    InvalidSelectType,
    InvalidBlockType,
    InvalidElemKind,
    InvalidMemoryIndex,
    InvalidCastFlags,
    InvalidCompositeTypeIndex,
    UnknownType,
    UnknownFunction,
    UnknownMemory,
    UnknownTable,
    UnknownGlobal,
    UnknownLocal,
    UnknownLabel,
    UnknownTag,
    UnknownField,
    UnknownDataSegment,
    UnknownElemSegment,
    DataCountMismatch,
    MissingDataCountSection,
    PackedFieldAccessMismatch,
    MismatchedControlFlow,
    MixedExceptionProposals,
};

/// Half-open range `[start, end)` of type indices belonging to one `rec` group.
pub const RecGroupRange = struct {
    start: u32,
    end: u32,
};

/// Type-section metadata needed for static validation and subtyping checks.
pub const TypeContext = struct {
    composite_types: []const CompositeType,
    direct_parents: []const ?u32,
    type_final: []const bool,
    type_canonical: []const u32,
    rec_ranges: []const RecGroupRange,
};

/// Top-level disjoint reference hierarchies in Wasm GC + EH.
pub const HeapTop = enum {
    any,
    func,
    extern_,
    exn,
};

/// Returns true if `vt` has a default value (numbers, v128, and nullable refs).
pub fn isValTypeDefaultable(vt: ValType) bool {
    return switch (vt) {
        .I32, .I64, .F32, .F64, .V128 => true,
        .Ref => |rt| rt.nullable,
    };
}

/// Returns true if `st` has a default value (packed i8/i16 or defaultable valtype).
pub fn isStorageTypeDefaultable(st: StorageType) bool {
    return switch (st) {
        .packed_type => true,
        .valtype => |vt| isValTypeDefaultable(vt),
    };
}

/// Unpacks a StorageType into its runtime operand ValType (`i8`/`i16` -> `i32`).
pub fn unpackStorageType(st: StorageType) ValType {
    return switch (st) {
        .packed_type => .I32,
        .valtype => |vt| vt,
    };
}

/// Returns the top type hierarchy for a HeapType, validating concrete indices.
pub fn heapTypeTop(ht: HeapType, ctx: *const TypeContext) ValidationError!HeapTop {
    return switch (ht) {
        .Any, .Eq, .I31, .Struct, .Array, .None => .any,
        .Func, .NoFunc => .func,
        .Extern, .NoExtern => .extern_,
        .Exn, .NoExn => .exn,
        else => blk: {
            const idx = ht.concreteType() orelse return error.UnknownType;
            if (idx >= ctx.composite_types.len) return error.UnknownType;
            break :blk switch (ctx.composite_types[idx]) {
                .func_type => .func,
                .struct_type, .array_type => .any,
            };
        },
    };
}

/// Returns the bottom heap type matching a given HeapTop.
pub fn bottomHeapTypeForTop(top: HeapTop) HeapType {
    return switch (top) {
        .any => .None,
        .func => .NoFunc,
        .extern_ => .NoExtern,
        .exn => .NoExn,
    };
}

/// Validates that any concrete type index referenced inside `ht` is in bounds.
pub fn validateHeapType(ht: HeapType, ctx: *const TypeContext) ValidationError!void {
    if (ht.concreteType()) |idx| {
        if (idx >= ctx.composite_types.len) return error.UnknownType;
    }
}

/// Validates that any concrete type index referenced inside `vt` is in bounds.
pub fn validateValType(vt: ValType, ctx: *const TypeContext) ValidationError!void {
    switch (vt) {
        .Ref => |rt| try validateHeapType(rt.heap_type, ctx),
        else => {},
    }
}

/// Converts a parser HeapType into a core HeapType and checks concrete type index bounds.
pub fn payloadHeapTypeToCore(ht: payload_mod.HeapType, ctx: *const TypeContext) ValidationError!HeapType {
    return switch (ht) {
        .index => |idx| blk: {
            if (idx >= ctx.composite_types.len) return error.UnknownType;
            break :blk HeapType.fromConcreteType(idx);
        },
        .kind => |kind| switch (kind) {
            .funcref => .Func,
            .null_funcref => .NoFunc,
            .externref => .Extern,
            .null_externref => .NoExtern,
            .anyref => .Any,
            .null_ref => .None,
            .eqref => .Eq,
            .i31ref => .I31,
            .structref => .Struct,
            .arrayref => .Array,
            .exnref => .Exn,
            .null_exnref => .NoExn,
            else => error.UnknownType,
        },
    };
}

/// Converts a parser Type into a core ValType and checks concrete type index bounds.
pub fn payloadTypeToValType(typ: payload_mod.Type, ctx: *const TypeContext) ValidationError!ValType {
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
            .exnref => ValType.exnref(),
            .null_exnref => ValType.nullexnref(),
            else => error.UnknownType,
        },
        .ref_type => |rt| .{ .Ref = RefType.init(rt.nullable, try payloadHeapTypeToCore(rt.ref_index, ctx)) },
        .index => error.UnknownType,
    };
}

/// Checks `sub <: sup` for HeapTypes under the module's TypeContext.
pub fn heapTypeMatches(sub: HeapType, sup: HeapType, ctx: *const TypeContext) bool {
    if (sub == sup) return true;

    const sub_concrete = sub.concreteType();
    const sup_concrete = sup.concreteType();

    if (sub_concrete != null and sup_concrete != null) {
        const sub_idx = sub_concrete.?;
        const sup_idx = sup_concrete.?;
        if (sub_idx >= ctx.composite_types.len or sup_idx >= ctx.composite_types.len) return false;
        if (ctx.type_canonical[sub_idx] == ctx.type_canonical[sup_idx]) return true;

        var cur_opt = ctx.direct_parents[sub_idx];
        var steps: u32 = 0;
        while (cur_opt) |cur| : (steps += 1) {
            if (steps > MAX_SUBTYPE_DEPTH) break;
            if (cur == sup_idx) return true;
            if (ctx.type_canonical[cur] == ctx.type_canonical[sup_idx]) return true;
            cur_opt = ctx.direct_parents[cur];
        }
        return false;
    }

    if (sub_concrete) |sub_idx| {
        if (sub_idx >= ctx.composite_types.len) return false;
        return switch (ctx.composite_types[sub_idx]) {
            .func_type => sup == .Func,
            .struct_type => sup == .Struct or sup == .Eq or sup == .Any,
            .array_type => sup == .Array or sup == .Eq or sup == .Any,
        };
    }

    if (sup_concrete) |sup_idx| {
        if (sup_idx >= ctx.composite_types.len) return false;
        return switch (ctx.composite_types[sup_idx]) {
            .func_type => sub == .NoFunc,
            .struct_type, .array_type => sub == .None,
        };
    }

    return switch (sub) {
        .None => sup == .Any or sup == .Eq or sup == .I31 or sup == .Struct or sup == .Array or sup == .None,
        .I31 => sup == .I31 or sup == .Eq or sup == .Any,
        .Struct => sup == .Struct or sup == .Eq or sup == .Any,
        .Array => sup == .Array or sup == .Eq or sup == .Any,
        .Eq => sup == .Eq or sup == .Any,
        .Any => sup == .Any,
        .NoFunc => sup == .NoFunc or sup == .Func,
        .Func => sup == .Func,
        .NoExtern => sup == .NoExtern or sup == .Extern,
        .Extern => sup == .Extern,
        .NoExn => sup == .NoExn or sup == .Exn,
        .Exn => sup == .Exn,
        else => false,
    };
}

/// Checks `sub <: sup` for RefTypes.
pub fn refTypeMatches(sub: RefType, sup: RefType, ctx: *const TypeContext) bool {
    if (sub.nullable and !sup.nullable) return false;
    return heapTypeMatches(sub.heap_type, sup.heap_type, ctx);
}

/// Checks `sub <: sup` for ValTypes.
pub fn valTypeMatches(sub: ValType, sup: ValType, ctx: *const TypeContext) bool {
    if (sub == .Ref and sup == .Ref) {
        return refTypeMatches(sub.Ref, sup.Ref, ctx);
    }
    return std.meta.eql(sub, sup);
}

/// Checks `sub <: sup` for StorageTypes.
pub fn storageTypeMatches(sub: StorageType, sup: StorageType, ctx: *const TypeContext) bool {
    return switch (sub) {
        .packed_type => |pa| switch (sup) {
            .packed_type => |pb| pa == pb,
            .valtype => false,
        },
        .valtype => |va| switch (sup) {
            .valtype => |vb| valTypeMatches(va, vb, ctx),
            .packed_type => false,
        },
    };
}

/// Checks `sub <: sup` for FieldTypes (mutable fields are invariant, immutable fields are covariant).
pub fn fieldTypeMatches(sub: FieldType, sup: FieldType, ctx: *const TypeContext) bool {
    if (sub.mutable != sup.mutable) return false;
    if (sup.mutable) {
        return storageTypeMatches(sub.storage_type, sup.storage_type, ctx) and
            storageTypeMatches(sup.storage_type, sub.storage_type, ctx);
    }
    return storageTypeMatches(sub.storage_type, sup.storage_type, ctx);
}

/// Checks `sub <: sup` for CompositeTypes (struct width+depth, array field, func contravariant params + covariant results).
pub fn compositeTypeMatches(sub: CompositeType, sup: CompositeType, ctx: *const TypeContext) bool {
    if (std.meta.activeTag(sub) != std.meta.activeTag(sup)) return false;
    return switch (sub) {
        .struct_type => |s_sub| blk: {
            const s_sup = sup.struct_type;
            if (s_sub.fields.len < s_sup.fields.len) break :blk false;
            for (0..s_sup.fields.len) |k| {
                if (!fieldTypeMatches(s_sub.fields[k], s_sup.fields[k], ctx)) break :blk false;
            }
            break :blk true;
        },
        .array_type => |a_sub| fieldTypeMatches(a_sub.field, sup.array_type.field, ctx),
        .func_type => |f_sub| blk: {
            const f_sup = sup.func_type;
            const sub_params = f_sub.params();
            const sup_params = f_sup.params();
            const sub_results = f_sub.results();
            const sup_results = f_sup.results();
            if (sub_params.len != sup_params.len or sub_results.len != sup_results.len) break :blk false;
            for (sub_params, sup_params) |psub, psup| {
                if (!valTypeMatches(psup, psub, ctx)) break :blk false;
            }
            for (sub_results, sup_results) |rsub, rsup| {
                if (!valTypeMatches(rsub, rsup, ctx)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn validateValTypeInRecGroup(vt: ValType, max_visible: u32, total_types: usize) ValidationError!void {
    switch (vt) {
        .Ref => |rt| {
            if (rt.heap_type.concreteType()) |idx| {
                if (idx >= total_types) return error.UnknownType;
                if (idx >= max_visible) return error.ForwardTypeReference;
            }
        },
        else => {},
    }
}

fn validateStorageTypeInRecGroup(st: StorageType, max_visible: u32, total_types: usize) ValidationError!void {
    switch (st) {
        .packed_type => {},
        .valtype => |vt| try validateValTypeInRecGroup(vt, max_visible, total_types),
    }
}

/// Validates all type definitions in the Type Section:
///   - At most 1 declared supertype per type definition
///   - Supertype index strictly precedes subtype index (`p < i`)
///   - Supertype is not marked `final`
///   - Subtype inheritance chain depth <= 63
///   - All referenced type indices are within the enclosing `rec` group's end bound
///   - Structural subtyping rules hold against declared supertype
pub fn validateTypeSection(
    ctx: *const TypeContext,
    super_type_counts: []const usize,
) ValidationError!void {
    const n = ctx.composite_types.len;
    for (0..n) |i| {
        if (super_type_counts[i] > 1) return error.InvalidSubtype;

        const max_visible = ctx.rec_ranges[i].end;
        switch (ctx.composite_types[i]) {
            .func_type => |ft| {
                for (ft.params()) |p| try validateValTypeInRecGroup(p, max_visible, n);
                for (ft.results()) |r| try validateValTypeInRecGroup(r, max_visible, n);
            },
            .struct_type => |st| {
                for (st.fields) |f| try validateStorageTypeInRecGroup(f.storage_type, max_visible, n);
            },
            .array_type => |at| {
                try validateStorageTypeInRecGroup(at.field.storage_type, max_visible, n);
            },
        }

        if (ctx.direct_parents[i]) |parent_idx| {
            if (parent_idx >= n) return error.UnknownType;
            if (parent_idx >= i) return error.ForwardTypeReference;
            if (ctx.type_final[parent_idx]) return error.ExtendFinalType;

            var depth: u32 = 1;
            var cur_opt = ctx.direct_parents[parent_idx];
            while (cur_opt) |cur| {
                depth += 1;
                if (depth > MAX_SUBTYPE_DEPTH) return error.SubtypeDepthExceeded;
                if (cur >= i) return error.ForwardTypeReference;
                cur_opt = ctx.direct_parents[cur];
            }

            if (!compositeTypeMatches(ctx.composite_types[i], ctx.composite_types[parent_idx], ctx)) {
                return error.InvalidSubtype;
            }
        }
    }
}

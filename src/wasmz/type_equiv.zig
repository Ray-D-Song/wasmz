const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;
const CompositeType = core.CompositeType;
const StorageType = core.StorageType;
const ValType = core.ValType;
const HeapType = core.HeapType;
const RefType = core.RefType;
const FuncType = core.FuncType;

/// For each composite type index, the canonical representative of its structural
/// equivalence class (iso-recursive tie). Indices not in a GC struct/array class
/// are their own canonical id.
pub fn computeTypeCanonical(
    allocator: Allocator,
    composite_types: []const CompositeType,
    direct_parents: []const ?u32,
    type_final: []const bool,
) ![]u32 {
    const n = composite_types.len;
    var canonical = try allocator.alloc(u32, n);
    for (0..n) |i| canonical[i] = @intCast(i);

    var changed = true;
    while (changed) {
        changed = false;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var j: u32 = i + 1;
            while (j < n) : (j += 1) {
                if (!gcTypesComparable(composite_types[i], composite_types[j])) continue;
                if (!gcTypesStructurallyEqual(
                    i,
                    j,
                    composite_types,
                    direct_parents,
                    type_final,
                    canonical,
                )) continue;

                const min_c = @min(canonical[i], canonical[j]);
                if (canonical[i] != min_c) {
                    canonical[i] = min_c;
                    changed = true;
                }
                if (canonical[j] != min_c) {
                    canonical[j] = min_c;
                    changed = true;
                }
            }
        }
    }

    for (0..n) |idx| {
        var c = canonical[idx];
        while (c != canonical[c]) c = canonical[c];
        canonical[idx] = c;
    }
    return canonical;
}

/// Returns true when a heap object's concrete type index matches a ref.test/cast
/// target, including nominal subtyping and structural equivalence.
pub fn concreteTypeMatches(
    obj_idx: u32,
    target_idx: u32,
    type_canonical: []const u32,
    type_ancestors: []const []const u32,
) bool {
    if (obj_idx == target_idx) return true;
    if (obj_idx < type_canonical.len and target_idx < type_canonical.len and
        type_canonical[obj_idx] == type_canonical[target_idx])
    {
        return true;
    }
    if (obj_idx < type_ancestors.len) {
        for (type_ancestors[obj_idx]) |anc| {
            if (anc == target_idx) return true;
            if (anc < type_canonical.len and target_idx < type_canonical.len and
                type_canonical[anc] == type_canonical[target_idx])
            {
                return true;
            }
        }
    }
    return false;
}

/// Returns true when `actual_type_idx` matches `target_type_idx` for funcref subtyping
/// (nominal equality or structural equivalence of function types).
pub fn funcTypeMatches(actual_type_idx: u32, target_type_idx: u32, type_canonical: []const u32) bool {
    if (actual_type_idx == target_type_idx) return true;
    if (actual_type_idx < type_canonical.len and target_type_idx < type_canonical.len and
        type_canonical[actual_type_idx] == type_canonical[target_type_idx])
    {
        return true;
    }
    return false;
}

/// True when the ref.test/cast/br_on_cast target heap type denotes a funcref.
pub fn isFuncrefTargetHeapType(heap: HeapType, composite_types: []const CompositeType) bool {
    return switch (heap) {
        .Func, .NoFunc => true,
        else => blk: {
            const idx = heap.concreteType() orelse break :blk false;
            if (idx >= composite_types.len) break :blk false;
            break :blk composite_types[idx] == .func_type;
        },
    };
}

/// Match a funcref slot value (func_idx+1, or 0 for null) against a funcref heap target.
pub fn funcrefMatchesTarget(
    ref_bits: u64,
    target_heap: HeapType,
    nullable: bool,
    func_type_indices: []const u32,
    type_canonical: []const u32,
    composite_types: []const CompositeType,
) bool {
    if (ref_bits == 0) return nullable;
    return switch (target_heap) {
        .Func => true,
        .NoFunc => false,
        else => blk: {
            const target_type_idx = target_heap.concreteType() orelse break :blk false;
            if (target_type_idx >= composite_types.len) break :blk false;
            if (composite_types[target_type_idx] != .func_type) break :blk false;
            const func_idx: u32 = @intCast(ref_bits - 1);
            if (func_idx >= func_type_indices.len) break :blk false;
            break :blk funcTypeMatches(func_type_indices[func_idx], target_type_idx, type_canonical);
        },
    };
}

fn gcTypesComparable(a: CompositeType, b: CompositeType) bool {
    return std.meta.activeTag(a) == std.meta.activeTag(b);
}

fn gcTypesStructurallyEqual(
    i: u32,
    j: u32,
    composite_types: []const CompositeType,
    direct_parents: []const ?u32,
    type_final: []const bool,
    canonical: []const u32,
) bool {
    return switch (composite_types[i]) {
        .func_type => |fi| funcTypesEqual(fi, composite_types[j].func_type, canonical),
        .struct_type, .array_type => blk: {
            if (type_final[i] != type_final[j]) break :blk false;
            if (!parentsEquivalent(direct_parents[i], direct_parents[j], canonical)) break :blk false;
            break :blk switch (composite_types[i]) {
                .struct_type => |si| blk2: {
                    const sj = composite_types[j].struct_type;
                    if (si.fields.len != sj.fields.len) return false;
                    for (si.fields, sj.fields) |fi, fj| {
                        if (fi.mutable != fj.mutable) return false;
                        if (!storageTypesEqual(fi.storage_type, fj.storage_type, canonical)) return false;
                    }
                    break :blk2 true;
                },
                .array_type => |ai| blk2: {
                    const aj = composite_types[j].array_type;
                    if (ai.field.mutable != aj.field.mutable) return false;
                    break :blk2 storageTypesEqual(ai.field.storage_type, aj.field.storage_type, canonical);
                },
                .func_type => unreachable,
            };
        },
    };
}

fn funcTypesEqual(a: FuncType, b: FuncType, canonical: []const u32) bool {
    if (a.params().len != b.params().len) return false;
    if (a.results().len != b.results().len) return false;
    for (a.params(), b.params()) |pa, pb| {
        if (!valTypesEqual(pa, pb, canonical)) return false;
    }
    for (a.results(), b.results()) |ra, rb| {
        if (!valTypesEqual(ra, rb, canonical)) return false;
    }
    return true;
}

fn parentsEquivalent(a: ?u32, b: ?u32, canonical: []const u32) bool {
    if (a == null and b == null) return true;
    const pa = a orelse return false;
    const pb = b orelse return false;
    return canonical[pa] == canonical[pb];
}

fn storageTypesEqual(a: StorageType, b: StorageType, canonical: []const u32) bool {
    return switch (a) {
        .valtype => |va| switch (b) {
            .valtype => |vb| valTypesEqual(va, vb, canonical),
            else => false,
        },
        .packed_type => |pa| switch (b) {
            .packed_type => |pb| pa == pb,
            else => false,
        },
    };
}

fn valTypesEqual(a: ValType, b: ValType, canonical: []const u32) bool {
    if (a == .Ref and b == .Ref) {
        return refTypesEqual(a.Ref, b.Ref, canonical);
    }
    return std.meta.eql(a, b);
}

fn refTypesEqual(a: RefType, b: RefType, canonical: []const u32) bool {
    if (a.nullable != b.nullable) return false;
    return heapTypesEqual(a.heap_type, b.heap_type, canonical);
}

fn heapTypesEqual(a: HeapType, b: HeapType, canonical: []const u32) bool {
    const a_concrete = a.concreteType();
    const b_concrete = b.concreteType();
    if (a_concrete == null and b_concrete == null) return a == b;
    if (a_concrete == null or b_concrete == null) return false;
    return canonical[a_concrete.?] == canonical[b_concrete.?];
}

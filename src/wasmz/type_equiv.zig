const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;
const CompositeType = core.CompositeType;
const StorageType = core.StorageType;
const ValType = core.ValType;
const HeapType = core.HeapType;
const RefType = core.RefType;

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

fn gcTypesComparable(a: CompositeType, b: CompositeType) bool {
    return std.meta.activeTag(a) == std.meta.activeTag(b) and switch (a) {
        .func_type => false,
        else => true,
    };
}

fn gcTypesStructurallyEqual(
    i: u32,
    j: u32,
    composite_types: []const CompositeType,
    direct_parents: []const ?u32,
    type_final: []const bool,
    canonical: []const u32,
) bool {
    if (type_final[i] != type_final[j]) return false;
    if (!parentsEquivalent(direct_parents[i], direct_parents[j], canonical)) return false;

    return switch (composite_types[i]) {
        .struct_type => |si| blk: {
            const sj = composite_types[j].struct_type;
            if (si.fields.len != sj.fields.len) return false;
            for (si.fields, sj.fields) |fi, fj| {
                if (fi.mutable != fj.mutable) return false;
                if (!storageTypesEqual(fi.storage_type, fj.storage_type, canonical)) return false;
            }
            break :blk true;
        },
        .array_type => |ai| blk: {
            const aj = composite_types[j].array_type;
            if (ai.field.mutable != aj.field.mutable) return false;
            break :blk storageTypesEqual(ai.field.storage_type, aj.field.storage_type, canonical);
        },
        .func_type => unreachable,
    };
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

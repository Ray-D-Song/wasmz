const std = @import("std");
const trap = @import("../trap.zig");
const table_type = @import("../table/type.zig");
const heap_type = @import("../heap_type.zig");
const ref_type = @import("../ref_type.zig");

pub const ValType = union(enum) {
    I32,
    I64,
    F32,
    F64,
    V128,
    Ref: ref_type.RefType,

    pub fn funcref() ValType {
        return .{ .Ref = ref_type.RefType.funcref() };
    }

    pub fn externref() ValType {
        return .{ .Ref = ref_type.RefType.externref() };
    }

    pub fn anyref() ValType {
        return .{ .Ref = ref_type.RefType.anyref() };
    }

    pub fn eqref() ValType {
        return .{ .Ref = ref_type.RefType.eqref() };
    }

    pub fn i31ref() ValType {
        return .{ .Ref = ref_type.RefType.i31ref() };
    }

    pub fn structref() ValType {
        return .{ .Ref = ref_type.RefType.structref() };
    }

    pub fn arrayref() ValType {
        return .{ .Ref = ref_type.RefType.arrayref() };
    }

    pub fn nullref() ValType {
        return .{ .Ref = ref_type.RefType.nullref() };
    }

    pub fn nullfuncref() ValType {
        return .{ .Ref = ref_type.RefType.nullfuncref() };
    }

    pub fn nullexternref() ValType {
        return .{ .Ref = ref_type.RefType.nullexternref() };
    }

    pub fn isNum(self: ValType) bool {
        return switch (self) {
            .I32, .I64, .F32, .F64 => true,
            else => false,
        };
    }

    pub fn isRef(self: ValType) bool {
        return switch (self) {
            .Ref => true,
            else => false,
        };
    }

    pub fn isGcRef(self: ValType) bool {
        return switch (self) {
            .Ref => |r| switch (r.heap_type) {
                .Any, .Eq, .I31, .Struct, .Array, .None, .NoFunc, .NoExtern, _ => r.heap_type.isConcrete(),
                else => false,
            },
            else => false,
        };
    }

    pub fn asRefType(self: ValType) ?table_type.RefType {
        return switch (self) {
            .Ref => |r| switch (r.heap_type) {
                .Func => table_type.RefType.Func,
                .Extern => table_type.RefType.Extern,
                else => null,
            },
            else => null,
        };
    }

    pub fn fromRefType(refType: table_type.RefType) ValType {
        return switch (refType) {
            .Func => funcref(),
            .Extern => externref(),
        };
    }

    pub fn asHeapType(self: ValType) ?heap_type.HeapType {
        return switch (self) {
            .Ref => |r| r.heap_type,
            else => null,
        };
    }

    pub fn isSubtypeOf(self: ValType, other: ValType) bool {
        const self_heap = self.asHeapType();
        const other_heap = other.asHeapType();

        if (self_heap == null or other_heap == null) {
            return self.eql(other);
        }

        switch (self) {
            .Ref => |self_ref| {
                switch (other) {
                    .Ref => |other_ref| {
                        return self_ref.isSubtypeOf(other_ref);
                    },
                    else => return false,
                }
            },
            else => return self.eql(other),
        }
    }

    pub fn eql(self: ValType, other: ValType) bool {
        return std.meta.eql(self, other);
    }

    pub fn eqlSlice(a: []const ValType, b: []const ValType) bool {
        if (a.len != b.len) return false;
        for (a, b) |a_val, b_val| {
            if (!a_val.eql(b_val)) return false;
        }
        return true;
    }
};

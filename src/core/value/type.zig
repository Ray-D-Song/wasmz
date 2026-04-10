const std = @import("std");
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

const std = @import("std");
const trap = @import("../trap.zig");
const table_type = @import("../table/type.zig");

pub const ValType = enum {
    I32,
    I64,
    F32,
    F64,
    V128,
    // A nullable function reference.
    FuncRef,
    // A nullable external reference.
    // external ref is a reference to an opaque object owned by the host environment.
    ExternRef,

    pub fn isNum(self: ValType) bool {
        return switch (self) {
            .I32, .I64, .F32, .F64 => true,
            else => false,
        };
    }

    pub fn isRef(self: ValType) bool {
        return switch (self) {
            .FuncRef, .ExternRef => true,
            else => false,
        };
    }

    // Transforms the Ref Value Type into RefType
    // If the ValType is not a reference type, returns null
    pub fn asRefType(self: ValType) ?table_type.RefType {
        return switch (self) {
            .FuncRef => table_type.RefType.Func,
            .ExternRef => table_type.RefType.Extern,
            else => null,
        };
    }

    pub fn fromRefType(refType: table_type.RefType) ValType {
        return switch (refType) {
            .Func => .FuncRef,
            .Extern => .ExternRef,
        };
    }
};

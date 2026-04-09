const std = @import("std");
const trap = @import("../trap.zig");
const table_type = @import("../table/type.zig");
const heap_type = @import("../heap_type.zig");

pub const ValType = enum {
    I32,
    I64,
    F32,
    F64,
    V128,
    FuncRef,
    ExternRef,
    // GC reference types
    AnyRef,
    EqRef,
    I31Ref,
    StructRef,
    ArrayRef,
    NullRef,
    NullFuncRef,
    NullExternRef,

    pub fn isNum(self: ValType) bool {
        return switch (self) {
            .I32, .I64, .F32, .F64 => true,
            else => false,
        };
    }

    pub fn isRef(self: ValType) bool {
        return switch (self) {
            .FuncRef, .ExternRef, .AnyRef, .EqRef, .I31Ref, .StructRef, .ArrayRef, .NullRef, .NullFuncRef, .NullExternRef => true,
            else => false,
        };
    }

    pub fn isGcRef(self: ValType) bool {
        return switch (self) {
            .AnyRef, .EqRef, .I31Ref, .StructRef, .ArrayRef, .NullRef, .NullFuncRef, .NullExternRef => true,
            else => false,
        };
    }

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

    // Converts GC reference types to their corresponding HeapType, returning null for non-GC reference types.
    pub fn asHeapType(self: ValType) ?heap_type.HeapType {
        return switch (self) {
            .FuncRef => .Func,
            .ExternRef => .Extern,
            .AnyRef => .Any,
            .EqRef => .Eq,
            .I31Ref => .I31,
            .StructRef => .Struct,
            .ArrayRef => .Array,
            .NullRef => .None,
            .NullFuncRef => .NoFunc,
            .NullExternRef => .NoExtern,
            else => null,
        };
    }
};

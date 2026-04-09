const std = @import("std");
const raw_mod = @import("./raw.zig");
const value_type = @import("./value/type.zig");
const vec = @import("./value/vec.zig");
const float = @import("./float.zig");

const RawVal = raw_mod.RawVal;
const ValType = value_type.ValType;

pub fn wasmTypeOf(comptime T: type) ValType {
    if (T == bool or T == i8 or T == u8 or T == i16 or T == u16 or T == i32 or T == u32) {
        return .I32;
    }
    if (T == i64 or T == u64) {
        return .I64;
    }
    if (T == f32) {
        return .F32;
    }
    if (T == f64) {
        return .F64;
    }
    if (T == vec.V128) {
        return .V128;
    }
    if (T == f32 or T == float.F32) {
        return .F32;
    }
    if (T == f64 or T == float.F64) {
        return .F64;
    }
    @compileError("unsupported wasm typed value");
}

pub const TypedRawVal = struct {
    ty: ValType,
    value: RawVal,

    pub fn init(ty: ValType, value: RawVal) TypedRawVal {
        return .{
            .ty = ty,
            .value = value,
        };
    }

    pub fn from(value: anytype) TypedRawVal {
        const T = @TypeOf(value);
        return .{
            .ty = wasmTypeOf(T),
            .value = RawVal.from(value),
        };
    }

    pub fn raw(self: TypedRawVal) RawVal {
        return self.value;
    }

    pub fn valType(self: TypedRawVal) ValType {
        return self.ty;
    }

    pub fn into(self: TypedRawVal, comptime T: type) T {
        std.debug.assert(self.ty.eql(wasmTypeOf(T)));
        return self.value.readAs(T);
    }
};

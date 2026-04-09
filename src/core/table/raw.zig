// Wasm table store references types like funcref and externref
// This file defines the raw representation of table elements, which is used for encoding and decoding
// It's similar to ./value/
const RawVal = @import("../raw.zig").RawVal;
const RefType = @import("./type.zig").RefType;
const TypedRawVal = @import("../typed.zig").TypedRawVal;
const ValType = @import("../value/type.zig").ValType;

pub const RawRef = struct {
    // The raw bits of the reference value.
    // For funcref, this is the function index.
    // For externref, this is a pointer to the external object.
    bits: u32,

    pub fn initNull() RawRef {
        return .{ .bits = 0 };
    }

    pub fn isNull(self: RawRef) bool {
        return self.bits == 0;
    }

    pub fn fromU32(bits: u32) RawRef {
        return .{ .bits = bits };
    }

    pub fn fromRawVal(rawVal: RawVal) RawRef {
        return .{ .bits = rawVal.readAs(u32) };
    }

    pub fn toBits(self: RawRef) u32 {
        return self.bits;
    }

    pub fn toRawVal(self: RawRef) RawVal {
        return RawVal.fromBits64(@as(u64, self.bits));
    }

    pub fn readFromRawVal(rawVal: RawVal) RawRef {
        return RawRef.fromRawVal(rawVal);
    }

    pub fn writeFromRawVal(self: *RawRef, rawVal: RawVal) void {
        self.bits = @as(u32, rawVal.low64);
    }

    pub fn toTypedRawVal(self: TypedRawRef) TypedRawVal {
        const val = RawVal.from(self.raw.toBits());
        const ty = switch (self.ty) {
            .Func => ValType.funcref(),
            .Extern => ValType.externref(),
        };
        return TypedRawVal.init(ty, val);
    }
};

pub const TypedRawRef = struct {
    raw: RawRef,
    ty: RefType,

    pub fn init(raw: RawRef, ty: RefType) TypedRawRef {
        return .{
            .raw = raw,
            .ty = ty,
        };
    }

    pub fn initNull(ty: RefType) TypedRawRef {
        return .{
            .raw = RawRef.initNull(),
            .ty = ty,
        };
    }
};

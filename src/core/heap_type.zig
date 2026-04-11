const std = @import("std");

pub const HeapType = enum(u32) {
    Func = 0,
    NoFunc = 1,
    Extern = 2,
    NoExtern = 3,
    Any = 4,
    Eq = 5,
    I31 = 6,
    Struct = 7,
    Array = 8,
    None = 9,
    Exn = 10,
    NoExn = 11,
    _,

    // Check if it is a user-defined concrete type
    pub fn isConcrete(self: HeapType) bool {
        return @intFromEnum(self) >= 0x80000000;
    }

    // For concrete types, return the type index (subtracting the offset).
    pub fn concreteType(self: HeapType) ?u32 {
        return if (self.isConcrete()) @intFromEnum(self) -% 0x80000000 else null;
    }

    // Create a HeapType for a user-defined concrete type given its type index.
    pub fn fromConcreteType(type_index: u32) HeapType {
        return @enumFromInt(type_index +% 0x80000000);
    }
};

pub const GcRefKind = packed struct {
    bits: u6,

    pub const Any: u6 = 0b100000;
    pub const Eq: u6 = 0b101000;
    pub const I31: u6 = 0b111000;
    pub const Struct: u6 = 0b101100;
    pub const Array: u6 = 0b101010;
    pub const None: u6 = 0b100001;
    pub const Func: u6 = 0b010000;
    pub const NoFunc: u6 = 0b010001;
    pub const Extern: u6 = 0b001000;
    pub const NoExtern: u6 = 0b001001;

    pub fn init(bits: u6) GcRefKind {
        return .{ .bits = bits };
    }

    pub fn isSubtypeOf(a: GcRefKind, b: GcRefKind) bool {
        return (a.bits & b.bits) == b.bits;
    }
};

pub fn gcRefKindFromHeapType(heap_type: HeapType) ?GcRefKind {
    return switch (heap_type) {
        .Any => GcRefKind.init(GcRefKind.Any),
        .Eq => GcRefKind.init(GcRefKind.Eq),
        .I31 => GcRefKind.init(GcRefKind.I31),
        .Struct => GcRefKind.init(GcRefKind.Struct),
        .Array => GcRefKind.init(GcRefKind.Array),
        .None => GcRefKind.init(GcRefKind.None),
        .Func => GcRefKind.init(GcRefKind.Func),
        .NoFunc => GcRefKind.init(GcRefKind.NoFunc),
        .Extern => GcRefKind.init(GcRefKind.Extern),
        .NoExtern => GcRefKind.init(GcRefKind.NoExtern),
        else => null,
    };
}

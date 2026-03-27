const std = @import("std");
const IndexType = @import("../index_type.zig").IndexType;
const TableError = @import("./error.zig").TableError;

// Wasm reference type.
pub const RefType = enum {
    Func,
    Extern,
};

pub const TableType = struct {
    element: RefType,
    min: u64,
    max: ?u64,
    index_type: IndexType,

    pub fn init(element: RefType, min: u32, max: ?u32) TableType {
        return initImpl(element, .I32, min, if (max) |m| @as(u64, m) else null);
    }

    pub fn init64(element: RefType, min: u64, max: ?u64) TableType {
        return initImpl(element, .I64, min, max);
    }

    pub fn initImpl(element: RefType, index_type: IndexType, min: u64, max: ?u64) TableType {
        const absolute_max = index_type.maxSize();
        std.debug.assert(@as(u128, min) <= absolute_max);

        if (max) |maximum| {
            std.debug.assert(min <= maximum and @as(u128, maximum) <= absolute_max);
        }

        return .{
            .element = element,
            .min = min,
            .max = max,
            .index_type = index_type,
        };
    }

    pub fn is64(self: TableType) bool {
        return self.index_type.is64();
    }

    pub fn ensureElementTypeMatches(self: TableType, refTy: RefType) TableError!void {
        if (self.element != refTy) {
            return TableError.ElementTypeMismatch;
        }
    }

    // Returns `true` if the [`TableType`] is a subtype of the `other` [`TableType`].
    //
    // # Note
    //
    // This implements the [subtyping rules] according to the WebAssembly spec.
    //
    // [import subtyping]:
    // https://webassembly.github.io/spec/core/valid/types.html#import-subtyping
    pub fn isSubTypeOf(self: TableType, other: TableType) bool {
        if (self.is64() != other.is64()) {
            return false;
        }
        if (self.element != other.element) return false;
        if (self.min < other.min) return false;
        if (other.max) |otherMax| {
            if (self.max == null or self.max > otherMax) return false;
        }
        return true;
    }
};

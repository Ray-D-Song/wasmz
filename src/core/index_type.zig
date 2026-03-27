const ValType = @import("val_type.zig").ValType;

// The index type used for addressing memories and tables.
pub const IndexType = enum {
    I32,
    I64,

    pub fn getType(self: IndexType) ValType {
        return switch (self) {
            .I32 => .I32,
            .I64 => .I64,
        };
    }

    pub fn is64(self: IndexType) bool {
        return self == .I64;
    }

    // Returns the maximum size for Wasm memories and tables for the IndexType
    pub fn maxSize(self: IndexType) u128 {
        return switch (self) {
            .I32 => @as(u128, 1) << 32,
            .I64 => @as(u128, 1) << 64,
        };
    }

    // Return the narrower of the two index types
    pub fn min(self: IndexType, other: IndexType) IndexType {
        return if (self == .I64 and other == .I64) .I64 else .I32;
    }
};

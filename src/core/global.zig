const ValType = @import("value/type.zig").ValType;
const RawVal = @import("raw.zig").RawVal;
const TypedRawVal = @import("typed.zig").TypedRawVal;

pub const GlobalError = error{
    /// Occurs when trying to write to an immutable global variable.
    ImmutableWrite,
    /// Occurs when trying writing a value with mismatching type to a global variable.
    TypeMismatch,
};

pub fn globalErrorMsg(err: GlobalError) []const u8 {
    return switch (err) {
        GlobalError.ImmutableWrite => "cannot write to an immutable global variable",
        GlobalError.TypeMismatch => "type mismatch when writing to a global variable",
    };
}

pub const Mutability = enum {
    /// The value of the global variable is a constant.
    Const,
    /// The value of the global variable is mutable.
    Var,

    pub fn isConst(self: Mutability) bool {
        return self == .Const;
    }

    pub fn isVar(self: Mutability) bool {
        return self == .Var;
    }
};

// Shape of a global variable
pub const GlobalType = struct {
    mutability: Mutability,
    valueType: ValType,

    pub fn init(mutability: Mutability, valueType: ValType) GlobalType {
        return .{
            .mutability = mutability,
            .valueType = valueType,
        };
    }
};

pub const Global = struct {
    ty: GlobalType,
    value: RawVal,

    pub fn init(ty: GlobalType, value: RawVal) Global {
        return .{
            .ty = ty,
            .value = value,
        };
    }

    // Set a new value
    pub fn setValue(self: *Global, value: TypedRawVal) GlobalError!void {
        // Checks the mutability and type of the global variable before setting the value.
        if (self.ty.mutability.isConst()) {
            return error.ImmutableWrite;
        }
        if (self.ty.valueType != value.valType()) {
            return error.TypeMismatch;
        }
        self.value = value.raw();
    }

    pub fn getValue(self: Global) TypedRawVal {
        return .{
            .ty = self.ty.valueType,
            .value = self.value,
        };
    }

    pub fn getRawValue(self: Global) RawVal {
        return self.value;
    }
};

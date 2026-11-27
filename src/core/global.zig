const std = @import("std");
const ValType = @import("value/type.zig").ValType;
const RawVal = @import("raw.zig").RawVal;
const TypedRawVal = @import("typed.zig").TypedRawVal;
const Allocator = std.mem.Allocator;

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

pub const SharedGlobalInner = struct {
    global: Global,
    hi64: u64 = 0,
    allocator: Allocator,
    refs: std.atomic.Value(usize),
};

/// Reference-counted, shareable runtime WebAssembly Global.
/// Keeping `global: Global` as the first field lets VM hot-path handlers read/write
/// `*Global` directly via `SharedGlobal.asGlobal()`.
pub const SharedGlobal = struct {
    inner: *SharedGlobalInner,

    pub fn init(allocator: Allocator, ty: GlobalType, value: RawVal, hi64: u64) Allocator.Error!SharedGlobal {
        const inner = try allocator.create(SharedGlobalInner);
        inner.* = .{
            .global = Global.init(ty, value),
            .hi64 = hi64,
            .allocator = allocator,
            .refs = std.atomic.Value(usize).init(1),
        };
        return .{ .inner = inner };
    }

    pub fn clone(self: SharedGlobal) SharedGlobal {
        _ = self.inner.refs.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn deinit(self: *SharedGlobal) void {
        const prev = self.inner.refs.fetchSub(1, .acq_rel);
        if (prev == 1) {
            const allocator = self.inner.allocator;
            allocator.destroy(self.inner);
        }
        self.* = undefined;
    }

    pub inline fn asGlobal(self: SharedGlobal) *Global {
        return &self.inner.global;
    }

    pub inline fn mutability(self: SharedGlobal) Mutability {
        return self.inner.global.ty.mutability;
    }

    pub inline fn valueType(self: SharedGlobal) ValType {
        return self.inner.global.ty.valueType;
    }

    pub inline fn getRaw(self: SharedGlobal) RawVal {
        return self.inner.global.value;
    }

    pub inline fn setRaw(self: SharedGlobal, value: RawVal) GlobalError!void {
        if (self.inner.global.ty.mutability.isConst()) {
            return error.ImmutableWrite;
        }
        self.inner.global.value = value;
    }
};

const std = @import("std");
const vec = @import("./value/vec.zig");
const GcRef = @import("./gc_ref.zig").GcRef;

/// A single 64-bit value slot used for all non-SIMD Wasm value types:
/// i32, i64, f32, f64, funcref/externref (GcRef).
///
/// Size: 8 bytes.  The value stack (`val_stack`) is an array of `RawVal`.
/// V128 values use two consecutive `RawVal` slots — access them via `SimdVal`.
pub const RawVal = struct {
    // The 64-bits used to encode and decode all types that fit into
    // 64-bits such as `i32`, `i64`, `f32` and `f64`.
    low64: u64,

    // Reads native types like `i32`, `f64` from the raw value.
    pub fn readAs(self: RawVal, comptime T: type) T {
        if (T == RawVal) return self;
        if (T == i8) return @as(i8, @bitCast(@as(u8, @truncate(self.low64))));
        if (T == i16) return @as(i16, @bitCast(@as(u16, @truncate(self.low64))));
        if (T == i32) return @as(i32, @bitCast(@as(u32, @truncate(self.low64))));
        if (T == i64) return @as(i64, @bitCast(self.low64));

        if (T == u8) return @as(u8, @truncate(self.low64));
        if (T == u16) return @as(u16, @truncate(self.low64));
        if (T == u32) return @as(u32, @truncate(self.low64));
        if (T == u64) return self.low64;

        if (T == f32) {
            const bits: u32 = @truncate(self.low64);
            return @as(f32, @bitCast(bits));
        }
        if (T == f64) return @as(f64, @bitCast(self.low64));

        if (T == vec.V128) @compileError("V128 cannot be stored in RawVal; use SimdVal instead");

        if (T == bool) return self.low64 != 0;

        if (T == GcRef) {
            return GcRef.encode(@as(u32, @truncate(self.low64)));
        }

        @compileError("unsupported readAs type");
    }

    // Cast a primitive value that fits into 64-bits into a `RawVal`.
    pub fn fromBits64(low64: u64) RawVal {
        return .{ .low64 = low64 };
    }

    pub fn from(value: anytype) RawVal {
        var raw = RawVal{ .low64 = 0 };
        raw.writeAs(value);
        return raw;
    }

    fn readLow64(self: RawVal) u64 {
        return self.low64;
    }

    fn writeLow64(self: *RawVal, bits: u64) void {
        self.low64 = bits;
    }

    pub fn writeAs(self: *RawVal, value: anytype) void {
        const T = @TypeOf(value);

        if (T == RawVal) {
            self.* = value;
            return;
        }

        if (T == bool) {
            self.writeLow64(if (value) 1 else 0);
            return;
        }

        if (T == u8 or T == u16 or T == u32 or T == u64) {
            self.writeLow64(@as(u64, value));
            return;
        }

        if (T == i8) {
            self.writeLow64(@as(u64, @as(u8, @bitCast(value))));
            return;
        }
        if (T == i16) {
            self.writeLow64(@as(u64, @as(u16, @bitCast(value))));
            return;
        }
        if (T == i32) {
            self.writeLow64(@as(u64, @as(u32, @bitCast(value))));
            return;
        }
        if (T == i64) {
            self.writeLow64(@as(u64, @bitCast(value)));
            return;
        }

        if (T == f32) {
            self.writeLow64(@as(u64, @as(u32, @bitCast(value))));
            return;
        }
        if (T == f64) {
            self.writeLow64(@as(u64, @bitCast(value)));
            return;
        }

        if (T == vec.V128) {
            @compileError("V128 cannot be stored in RawVal; use SimdVal instead");
        }

        if (T == GcRef) {
            self.writeLow64(@as(u64, value.decode()));
            return;
        }

        @compileError("unsupported writeAs type");
    }

    pub fn toBits64(self: RawVal) u64 {
        return self.low64;
    }

    pub fn fromGcRef(ref: GcRef) RawVal {
        return fromBits64(ref.decode());
    }

    pub fn readAsGcRef(self: RawVal) GcRef {
        return GcRef.encode(@as(u32, @truncate(self.low64)));
    }
};

/// A 128-bit SIMD value slot for Wasm V128.
///
/// Size: 16 bytes, align: 8.
/// In the value stack a V128 occupies two consecutive `RawVal` slots.
/// SIMD handlers obtain a `*SimdVal` by pointer-casting the first slot:
///   `@as(*SimdVal, @ptrCast(@alignCast(&slots[ops.dst])))`
///
/// `@sizeOf(SimdVal) == 2 * @sizeOf(RawVal)` is asserted at compile time.
pub const SimdVal = extern struct {
    bytes: [16]u8,

    comptime {
        // Must exactly cover two consecutive RawVal slots.
        if (@sizeOf(SimdVal) != 2 * @sizeOf(RawVal)) @compileError("SimdVal size mismatch");
        if (@alignOf(SimdVal) > @alignOf(RawVal)) @compileError("SimdVal alignment exceeds RawVal alignment");
    }

    pub fn fromV128(v: vec.V128) SimdVal {
        return .{ .bytes = v.bytes };
    }

    pub fn toV128(self: SimdVal) vec.V128 {
        return .{ .bytes = self.bytes };
    }

    pub fn fromU128(value: u128) SimdVal {
        return fromV128(vec.V128.fromU128(value));
    }

    pub fn asU128(self: SimdVal) u128 {
        return self.toV128().asU128();
    }

    /// Read from a pair of consecutive RawVal slots (slot[0] and slot[1]).
    pub fn fromSlots(lo: RawVal, hi: RawVal) SimdVal {
        var s: SimdVal = undefined;
        @memcpy(s.bytes[0..8], @as(*const [8]u8, @ptrCast(&lo.low64)));
        @memcpy(s.bytes[8..16], @as(*const [8]u8, @ptrCast(&hi.low64)));
        return s;
    }

    /// Write this SimdVal into a pair of consecutive RawVal slots.
    pub fn toSlots(self: SimdVal, lo: *RawVal, hi: *RawVal) void {
        lo.low64 = @as(u64, @bitCast(self.bytes[0..8].*));
        hi.low64 = @as(u64, @bitCast(self.bytes[8..16].*));
    }

    /// Wrap a scalar RawVal as a SimdVal (high 8 bytes zeroed).
    /// Used for splat sources and bitmask/any_true scalar results.
    pub fn fromScalar(r: RawVal) SimdVal {
        var s: SimdVal = std.mem.zeroes(SimdVal);
        @memcpy(s.bytes[0..8], @as(*const [8]u8, @ptrCast(&r.low64)));
        return s;
    }

    /// Extract the low 8 bytes as a scalar RawVal.
    pub fn toScalar(self: SimdVal) RawVal {
        return .{ .low64 = @as(u64, @bitCast(self.bytes[0..8].*)) };
    }
};

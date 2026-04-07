const vec = @import("./value/vec.zig");
const float = @import("./float.zig");

pub const RawVal = struct {
    // The low 64-bits of an [`RawVal`].
    //
    // The low 64-bits are used to encode and decode all types that
    // are convertible from and to an [`RawVal`] that fit into
    // 64-bits such as `i32`, `i64`, `f32` and `f64`.
    low64: u64,
    // The high 64-bits of an [`RawVal`].
    //
    // This is only used to encode or decode types which do not fit
    // into the lower 64-bits part such as Wasm's `V128` or `i128`.
    high64: u64,

    // Reads native types like `i32`, `f64` or `V128` from the raw value.
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

        // Support reading float.F32 and float.F64 wrapper type
        if (T == float.F32) {
            const bits: u32 = @truncate(self.low64);
            return float.F32.fromBits(bits);
        }
        if (T == float.F64) {
            return float.F64.fromBits(self.low64);
        }

        if (T == vec.V128) {
            const bits = (@as(u128, self.high64) << 64) | @as(u128, self.low64);
            return vec.V128.fromU128(bits);
        }

        if (T == bool) return self.low64 != 0;

        @compileError("unsupported readAs type");
    }

    // Cast a primitive value that fits into 64-bits into a `RawVal`.
    pub fn fromBits64(low64: u64) RawVal {
        return .{
            .low64 = low64,
            .high64 = 0,
        };
    }

    pub fn from(value: anytype) RawVal {
        var raw = RawVal{ .low64 = 0, .high64 = 0 };
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

        if (T == float.F32) {
            self.writeLow64(@as(u64, value.toBits()));
            return;
        }
        if (T == float.F64) {
            self.writeLow64(value.toBits());
            return;
        }

        if (T == vec.V128) {
            const bits = value.asU128();
            self.low64 = @as(u64, @truncate(bits));
            self.high64 = @as(u64, @truncate(bits >> 64));
            return;
        }

        @compileError("unsupported writeAs type");
    }

    pub fn toBits64(self: RawVal) u64 {
        return self.low64;
    }
};

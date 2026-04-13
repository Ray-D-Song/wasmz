const vec = @import("./value/vec.zig");
const GcRef = @import("./gc_ref.zig").GcRef;

pub const RawVal = struct {
    // no-simd branch: single 64-bit slot; V128 is not supported.
    low64: u64,

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

        if (T == vec.V128) @panic("V128 not supported in no-simd build");

        if (T == bool) return self.low64 != 0;

        if (T == GcRef) {
            return GcRef.encode(@as(u32, @truncate(self.low64)));
        }

        @compileError("unsupported readAs type");
    }

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
            @panic("V128 not supported in no-simd build");
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

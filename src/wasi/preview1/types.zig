const core = @import("core");

pub const RawVal = core.RawVal;

pub const module_name = "wasi_snapshot_preview1";

pub const Errno = enum(u16) {
    success = 0,
    badf = 8,
    fault = 21,
    inval = 28,
    io = 29,
    nosys = 52,
    spi = 58,
};

pub inline fn writeErrno(results: []RawVal, errno: Errno) void {
    results[0] = RawVal.from(@as(i32, @intCast(@intFromEnum(errno))));
}

pub const ClockId = enum(u32) {
    realtime = 0,
    monotonic = 1,
    process_cputime_id = 2,
    thread_cputime_id = 3,
};

pub const Ciovec = extern struct {
    buf: u32,
    buf_len: u32,
};

pub const Iovec = extern struct {
    buf: u32,
    buf_len: u32,
};

pub const Whence = enum(u32) {
    set = 0,
    cur = 1,
    end = 2,
};

pub const Size = u32;
pub const Filesize = u64;

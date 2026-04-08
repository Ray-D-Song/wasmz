const core = @import("core");

pub const RawVal = core.RawVal;

pub const module_name = "wasi_snapshot_preview1";

pub const Errno = enum(u16) {
    success = 0,
    badf = 8,
    exist = 20,
    fault = 21,
    inout = 22,
    inval = 28,
    io = 29,
    noent = 44,
    nosys = 52,
    notdir = 54,
    overflow = 61,
    spi = 58,
    isdir = 31,
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

pub const Filetype = enum(u8) {
    unknown = 0,
    block_device = 1,
    character_device = 2,
    directory = 3,
    regular_file = 4,
    socket_dgram = 5,
    socket_stream = 6,
    symbolic_link = 7,
};

pub const Filestat = extern struct {
    dev: u64,
    ino: u64,
    filetype: Filetype,
    nlink: u64,
    size: u64,
    atim: u64,
    mtim: u64,
    ctim: u64,
};

pub const Size = u32;
pub const Filesize = u64;
pub const Fd = u32;

pub const LookupFlags = packed struct(u32) {
    symlink_follow: bool = false,
    _padding: u31 = 0,
};

pub const OFlags = packed struct(u32) {
    creat: bool = false,
    directory: bool = false,
    excl: bool = false,
    trunc: bool = false,
    _padding: u28 = 0,
};

pub const FdFlags = packed struct(u32) {
    append: bool = false,
    dsync: bool = false,
    nonblock: bool = false,
    rsync: bool = false,
    sync: bool = false,
    _padding: u27 = 0,
};

pub const Rights = packed struct(u64) {
    fd_datasync: bool = false,
    fd_read: bool = false,
    fd_seek: bool = false,
    fd_fdstat_set_flags: bool = false,
    fd_write: bool = false,
    fd_advise: bool = false,
    fd_allocate: bool = false,
    path_create_directory: bool = false,
    path_create_file: bool = false,
    path_link_source: bool = false,
    path_rename_source: bool = false,
    path_symlink: bool = false,
    path_unlink_file: bool = false,
    path_remove_directory: bool = false,
    path_filestat_get: bool = false,
    path_filestat_set_size: bool = false,
    path_filestat_set_times: bool = false,
    fd_filestat_get: bool = false,
    fd_filestat_set_size: bool = false,
    fd_filestat_set_times: bool = false,
    path_symlink_to: bool = false,
    path_rename_target: bool = false,
    path_link_target: bool = false,
    _padding: u41 = 0,
};

pub const FdStat = extern struct {
    fs_filetype: Filetype,
    fs_flags: FdFlags,
    fs_rights_base: Rights,
    fs_rights_inheriting: Rights,
};

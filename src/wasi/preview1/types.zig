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

pub const Advice = enum(u8) {
    normal = 0,
    sequential = 1,
    random = 2,
    willneed = 3,
    dontneed = 4,
    noreuse = 5,
};

pub const Dirent = extern struct {
    d_next: u64,
    d_ino: u64,
    d_namlen: u32,
    d_type: Filetype,
};

pub const Signal = enum(u8) {
    none = 0,
    hup = 1,
    int = 2,
    quit = 3,
    ill = 4,
    trap = 5,
    abrt = 6,
    bus = 7,
    fpe = 8,
    kill = 9,
    usr1 = 10,
    segv = 11,
    usr2 = 12,
    pipe = 13,
    alrm = 14,
    term = 15,
    chld = 16,
    cont = 17,
    stop = 18,
    tstp = 19,
    ttin = 20,
    ttou = 21,
    urg = 22,
    xcpu = 23,
    xfsz = 24,
    vtalrm = 25,
    prof = 26,
    winch = 27,
    poll = 28,
    pwr = 29,
    sys = 30,
};

pub const Timestamp = u64;

pub const EventType = enum(u8) {
    clock = 0,
    fd_read = 1,
    fd_write = 2,
};

pub const SubclockFlags = packed struct(u16) {
    subscription_clock_abstime: bool = false,
    _padding: u15 = 0,
};

pub const SubscriptionClock = extern struct {
    id: u32,
    timeout: Timestamp,
    precision: Timestamp,
    flags: SubclockFlags,
};

pub const SubscriptionFdReadwrite = extern struct {
    file_descriptor: Fd,
};

pub const SubscriptionU = extern union {
    clock: SubscriptionClock,
    fd_read: SubscriptionFdReadwrite,
    fd_write: SubscriptionFdReadwrite,
};

pub const Subscription = extern struct {
    userdata: u64,
    u: extern struct {
        tag: EventType,
        _padding: [3]u8 = [_]u8{0} ** 3,
        u: SubscriptionU,
    },
};

pub const EventFdReadwrite = extern struct {
    nbytes: u64,
    flags: u16,
};

pub const Event = extern struct {
    userdata: u64,
    error_val: u16,
    type: EventType,
    fd_readwrite: EventFdReadwrite,
};

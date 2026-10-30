const std = @import("std");
const core = @import("core");
const wasmz = @import("wasmz");
const types = @import("./types.zig");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const RawVal = core.RawVal;
const HostContext = wasmz.HostContext;

// ── POSIX stat — platform-dependent ─────────────────────────────────────────
// On macOS/BSD Zig's Stat is well-defined.  On Linux cross-compilation
// from macOS, Stat and std.c.fstat/fstatat are `void`, so we provide
// our own extern declarations and Stat layout matching glibc x86_64.
const isBsd = builtin.target.os.tag == .macos or
    builtin.target.os.tag == .freebsd or
    builtin.target.os.tag == .openbsd or
    builtin.target.os.tag == .dragonfly or
    builtin.target.os.tag == .netbsd;

const timespec = extern struct { tv_sec: i64, tv_nsec: i64 };

const Stat = if (isBsd) std.c.Stat else extern struct {
    st_dev: u64,
    st_ino: u64,
    st_nlink: u64,
    st_mode: u32,
    st_uid: u32,
    st_gid: u32,
    __pad0: u32,
    st_rdev: u64,
    st_size: i64,
    st_blksize: i64,
    st_blocks: i64,
    st_atim: timespec,
    st_mtim: timespec,
    st_ctim: timespec,
    __unused: [3]i64,
};

extern "c" fn fstat(fd: c_int, buf: *Stat) c_int;
extern "c" fn fstatat(dir_fd: c_int, path: [*:0]const u8, buf: *Stat, flags: c_int) c_int;
extern "c" fn ftruncate(fd: c_int, length: i64) c_int;

/// AT_SYMLINK_NOFOLLOW — POSIX constant, 0x100 on Linux, 0x20 on macOS.
/// We define our own so we don't depend on std.c.AT which may be void
/// during cross-compilation.
const AT_SYMLINK_NOFOLLOW: c_int = if (isBsd) 0x20 else 0x100;

/// POSIX S_IFMT constants to extract file type from `Stat.mode`.
const S_IFMT = 0xF000;
const S_IFREG = 0x8000;
const S_IFDIR = 0x4000;
const S_IFLNK = 0xA000;
const S_IFCHR = 0x2000;
const S_IFBLK = 0x6000;
const S_IFIFO = 0x1000;
const S_IFSOCK = 0xC000;

/// POSIX dirent d_type constants.
const DT_UNKNOWN: u8 = 0;
const DT_FIFO: u8 = 1;
const DT_CHR: u8 = 2;
const DT_DIR: u8 = 4;
const DT_BLK: u8 = 6;
const DT_REG: u8 = 8;
const DT_LNK: u8 = 10;
const DT_SOCK: u8 = 12;
const DT_WHT: u8 = 14;

fn modeToFiletype(mode: u16) types.Filetype {
    return switch (mode & S_IFMT) {
        S_IFREG => .regular_file,
        S_IFDIR => .directory,
        S_IFLNK => .symbolic_link,
        S_IFCHR => .character_device,
        S_IFBLK => .block_device,
        S_IFIFO => .socket_stream,
        S_IFSOCK => .socket_dgram,
        else => .unknown,
    };
}

fn direntTypeToFiletype(dt: u8) types.Filetype {
    return switch (dt) {
        DT_REG => .regular_file,
        DT_DIR => .directory,
        DT_LNK => .symbolic_link,
        DT_CHR => .character_device,
        DT_BLK => .block_device,
        DT_FIFO => .socket_stream,
        DT_SOCK => .socket_dgram,
        else => .unknown,
    };
}

/// Convert a platform `Stat` to WASI `types.Filestat`.
fn statToFilestat(stat: Stat) types.Filestat {
    if (isBsd) {
        return .{
            .dev = @intCast(stat.dev),
            .ino = @intCast(stat.ino),
            .filetype = modeToFiletype(@as(u16, @intCast(stat.mode))),
            .nlink = @intCast(stat.nlink),
            .size = @intCast(stat.size),
            .atim = @intCast(stat.atimespec.sec * std.time.ns_per_s + stat.atimespec.nsec),
            .mtim = @intCast(stat.mtimespec.sec * std.time.ns_per_s + stat.mtimespec.nsec),
            .ctim = @intCast(stat.ctimespec.sec * std.time.ns_per_s + stat.ctimespec.nsec),
        };
    } else {
        return .{
            .dev = @intCast(stat.st_dev),
            .ino = @intCast(stat.st_ino),
            .filetype = modeToFiletype(@as(u16, @intCast(stat.st_mode))),
            .nlink = @intCast(stat.st_nlink),
            .size = @intCast(stat.st_size),
            .atim = @intCast(stat.st_atim.tv_sec * std.time.ns_per_s + stat.st_atim.tv_nsec),
            .mtim = @intCast(stat.st_mtim.tv_sec * std.time.ns_per_s + stat.st_mtim.tv_nsec),
            .ctim = @intCast(stat.st_ctim.tv_sec * std.time.ns_per_s + stat.st_ctim.tv_nsec),
        };
    }
}

/// Write all bytes to a file descriptor, retrying on partial writes.
fn writeAllFd(fd: std.c.fd_t, bytes: []const u8) bool {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = std.c.write(fd, remaining.ptr, remaining.len);
        if (n < 0) return false;
        remaining = remaining[@intCast(n)..];
    }
    return true;
}

pub const WriteError = error{Io};

pub const Output = struct {
    ctx: ?*anyopaque,
    write_fn: *const fn (?*anyopaque, bytes: []const u8) WriteError!void,

    pub fn stdout() Output {
        return .{ .ctx = null, .write_fn = write_stdout };
    }

    pub fn stderr() Output {
        return .{ .ctx = null, .write_fn = write_stderr };
    }

    pub fn writeAll(self: Output, bytes: []const u8) WriteError!void {
        return self.write_fn(self.ctx, bytes);
    }

    fn write_stdout(_: ?*anyopaque, bytes: []const u8) WriteError!void {
        if (!writeAllFd(1, bytes)) return error.Io;
    }

    fn write_stderr(_: ?*anyopaque, bytes: []const u8) WriteError!void {
        if (!writeAllFd(2, bytes)) return error.Io;
    }
};

const FileEntry = struct {
    kind: enum { file, directory },
    fd: std.c.fd_t,
    offset: u64,
    rights: types.Rights,
};

const Preopen = struct {
    path: []const u8,
    fd: std.c.fd_t,
};

fn errnoToWasi(rc: c_int) types.Errno {
    const err = std.c.errno(rc);
    return switch (err) {
        .SUCCESS => .success,
        .BADF => .badf,
        .NOENT => .noent,
        .EXIST => .exist,
        .FAULT => .fault,
        .INVAL => .inval,
        .IO => .io,
        .NOSYS => .nosys,
        .NOTDIR => .notdir,
        .ISDIR => .isdir,
        .ACCES => .noent,
        .FBIG => .overflow,
        .OVERFLOW => .overflow,
        .SPIPE => .spi,
        .DQUOT, .NAMETOOLONG, .ROFS, .MLINK => .noent,
        .INTR, .AGAIN => .io,
        else => .io,
    };
}

pub const FdIO = struct {
    const Self = @This();

    stdout: Output,
    stderr: Output,
    allocator: Allocator,
    files: std.AutoHashMap(types.Fd, FileEntry),
    preopens: std.AutoHashMap(types.Fd, Preopen),
    next_fd: types.Fd,

    pub fn init(allocator: Allocator) FdIO {
        return .{
            .stdout = Output.stdout(),
            .stderr = Output.stderr(),
            .allocator = allocator,
            .files = std.AutoHashMap(types.Fd, FileEntry).init(allocator),
            .preopens = std.AutoHashMap(types.Fd, Preopen).init(allocator),
            .next_fd = 3,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            _ = std.c.close(entry.value_ptr.fd);
        }
        self.files.deinit();

        var preopen_iter = self.preopens.iterator();
        while (preopen_iter.next()) |entry| {
            _ = std.c.close(entry.value_ptr.fd);
            self.allocator.free(entry.value_ptr.path);
        }
        self.preopens.deinit();
    }

    pub fn setStdout(self: *Self, output: Output) void {
        self.stdout = output;
    }

    pub fn setStderr(self: *Self, output: Output) void {
        self.stderr = output;
    }

    pub fn addPreopen(self: *Self, path: []const u8) !types.Fd {
        const path_z = try self.allocator.dupeSentinel(u8, path, 0);
        defer self.allocator.free(path_z);

        const dirfd = std.c.openat(
            std.c.AT.FDCWD,
            path_z,
            @as(std.c.O, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }),
        );
        if (dirfd < 0) {
            return error.PathNotFound;
        }

        const fd = self.next_fd;
        self.next_fd +%= 1;

        const path_dup = try self.allocator.dupe(u8, path);
        try self.preopens.put(fd, .{
            .path = path_dup,
            .fd = dirfd,
        });

        return fd;
    }

    pub fn pathOpen(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const _dirflags: types.LookupFlags = @bitCast(params[1].readAs(u32));
        const path_ptr = params[2].readAs(u32);
        const path_len = params[3].readAs(u32);
        const oflags: types.OFlags = @bitCast(params[4].readAs(u32));
        const fs_rights_base: types.Rights = @bitCast(params[5].readAs(u64));
        const fs_rights_inheriting: types.Rights = @bitCast(params[6].readAs(u64));
        const fdflags: types.FdFlags = @bitCast(params[7].readAs(u32));
        const fd_ptr = params[8].readAs(u32);

        _ = _dirflags;
        _ = fs_rights_inheriting;
        _ = fdflags;

        const preopen = self.preopens.get(fd) orelse {
            types.writeErrno(results, .badf);
            return;
        };

        const path_bytes = try ctx.readBytes(path_ptr, path_len);
        const path = std.mem.sliceTo(path_bytes, 0);
        const path_z = try self.allocator.dupeSentinel(u8, path, 0);
        defer self.allocator.free(path_z);

        if (oflags.directory) {
            const new_fd = std.c.openat(
                preopen.fd,
                path_z,
                @as(std.c.O, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }),
            );
            if (new_fd < 0) {
                types.writeErrno(results, errnoToWasi(new_fd));
                return;
            }
            const new_fd_num = self.next_fd;
            self.next_fd +%= 1;
            try self.files.put(new_fd_num, .{
                .kind = .directory,
                .fd = new_fd,
                .offset = 0,
                .rights = fs_rights_base,
            });
            try ctx.writeValue(fd_ptr, new_fd_num);
            types.writeErrno(results, .success);
            return;
        }

        // File open
        var open_flags: std.c.O = .{ .ACCMODE = .RDWR, .CLOEXEC = true };
        if (oflags.creat) {
            open_flags.CREAT = true;
            open_flags.TRUNC = oflags.trunc;
            open_flags.EXCL = oflags.excl;
        }
        const new_fd = std.c.openat(
            preopen.fd,
            path_z,
            open_flags,
            @as(c_uint, 0o644),
        );
        if (new_fd < 0) {
            types.writeErrno(results, errnoToWasi(new_fd));
            return;
        }

        const new_fd_num = self.next_fd;
        self.next_fd +%= 1;
        try self.files.put(new_fd_num, .{
            .kind = .file,
            .fd = new_fd,
            .offset = 0,
            .rights = fs_rights_base,
        });
        try ctx.writeValue(fd_ptr, new_fd_num);
        types.writeErrno(results, .success);
    }

    pub fn fdClose(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        _ = ctx;
        const fd = params[0].readAs(u32);

        switch (fd) {
            0, 1, 2 => {
                types.writeErrno(results, .badf);
            },
            else => {
                if (self.files.fetchRemove(fd)) |removed| {
                    _ = std.c.close(removed.value.fd);
                    types.writeErrno(results, .success);
                } else if (self.preopens.fetchRemove(fd)) |removed| {
                    _ = std.c.close(removed.value.fd);
                    self.allocator.free(removed.value.path);
                    types.writeErrno(results, .success);
                } else {
                    types.writeErrno(results, .badf);
                }
            },
        }
    }

    pub fn fdWrite(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const iovs_ptr = params[1].readAs(u32);
        const iovs_len = params[2].readAs(u32);
        const nwritten_ptr = params[3].readAs(u32);

        switch (fd) {
            1 => {
                const iovs = try ctx.readSlice(iovs_ptr, iovs_len, types.Ciovec);
                var total_written: u32 = 0;
                for (iovs) |iov| {
                    const bytes = try ctx.readBytes(iov.buf, iov.buf_len);
                    if (!writeAllFd(1, bytes)) {
                        types.writeErrno(results, .io);
                        return;
                    }
                    total_written +%= iov.buf_len;
                }
                try ctx.writeValue(nwritten_ptr, total_written);
                types.writeErrno(results, .success);
            },
            2 => {
                const iovs = try ctx.readSlice(iovs_ptr, iovs_len, types.Ciovec);
                var total_written: u32 = 0;
                for (iovs) |iov| {
                    const bytes = try ctx.readBytes(iov.buf, iov.buf_len);
                    if (!writeAllFd(2, bytes)) {
                        types.writeErrno(results, .io);
                        return;
                    }
                    total_written +%= iov.buf_len;
                }
                try ctx.writeValue(nwritten_ptr, total_written);
                types.writeErrno(results, .success);
            },
            else => {
                const entry = self.files.getPtr(fd) orelse {
                    types.writeErrno(results, .badf);
                    return;
                };

                const iovs = try ctx.readSlice(iovs_ptr, iovs_len, types.Ciovec);
                var total_written: u32 = 0;

                if (std.c.lseek(entry.fd, @intCast(entry.offset), @as(c_int, 0)) < 0) {
                    types.writeErrno(results, .io);
                    return;
                }

                for (iovs) |iov| {
                    const bytes = try ctx.readBytes(iov.buf, iov.buf_len);
                    const n = std.c.write(entry.fd, bytes.ptr, bytes.len);
                    if (n < 0) {
                        types.writeErrno(results, .io);
                        return;
                    }
                    total_written +%= @intCast(n);
                    entry.offset += @intCast(n);
                }

                try ctx.writeValue(nwritten_ptr, total_written);
                types.writeErrno(results, .success);
            },
        }
    }

    pub fn fdRead(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const iovs_ptr = params[1].readAs(u32);
        const iovs_len = params[2].readAs(u32);
        const nread_ptr = params[3].readAs(u32);

        switch (fd) {
            0 => {
                const iovs = try ctx.readSlice(iovs_ptr, iovs_len, types.Iovec);
                var total_read: u32 = 0;

                for (iovs) |iov| {
                    const buf = iov.buf;
                    const buf_len = iov.buf_len;
                    const guest_mem = ctx.memory() orelse {
                        types.writeErrno(results, .fault);
                        return;
                    };

                    if (buf >= guest_mem.len) {
                        types.writeErrno(results, .fault);
                        return;
                    }

                    const bytes_to_read = @min(buf_len, @as(u32, @intCast(guest_mem.len - buf)));
                    const read_buf = guest_mem[buf .. buf + bytes_to_read];

                    const bytes_read = std.c.read(0, read_buf.ptr, read_buf.len);
                    if (bytes_read < 0) {
                        types.writeErrno(results, .io);
                        return;
                    }

                    total_read +%= @intCast(bytes_read);
                    if (bytes_read == 0 or @as(u64, @intCast(bytes_read)) < buf_len) break;
                }

                try ctx.writeValue(nread_ptr, total_read);
                types.writeErrno(results, .success);
            },
            else => {
                const entry = self.files.getPtr(fd) orelse {
                    types.writeErrno(results, .badf);
                    return;
                };

                const iovs = try ctx.readSlice(iovs_ptr, iovs_len, types.Iovec);
                var total_read: u32 = 0;

                if (std.c.lseek(entry.fd, @intCast(entry.offset), @as(c_int, 0)) < 0) {
                    types.writeErrno(results, .io);
                    return;
                }

                for (iovs) |iov| {
                    const buf = iov.buf;
                    const buf_len = iov.buf_len;
                    const guest_mem = ctx.memory() orelse {
                        types.writeErrno(results, .fault);
                        return;
                    };

                    if (buf >= guest_mem.len) {
                        types.writeErrno(results, .fault);
                        return;
                    }

                    const bytes_to_read = @min(buf_len, @as(u32, @intCast(guest_mem.len - buf)));
                    const read_buf = guest_mem[buf .. buf + bytes_to_read];

                    const bytes_read = std.c.read(entry.fd, read_buf.ptr, read_buf.len);
                    if (bytes_read < 0) {
                        types.writeErrno(results, .io);
                        return;
                    }

                    total_read +%= @intCast(bytes_read);
                    entry.offset += @intCast(bytes_read);
                    if (bytes_read == 0 or @as(u64, @intCast(bytes_read)) < buf_len) break;
                }

                try ctx.writeValue(nread_ptr, total_read);
                types.writeErrno(results, .success);
            },
        }
    }

    pub fn fdSeek(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const offset = params[1].readAs(i64);
        const whence: types.Whence = @enumFromInt(params[2].readAs(u32));
        const newoffset_ptr = params[3].readAs(u32);

        switch (fd) {
            0, 1, 2 => {
                types.writeErrno(results, .spi);
                return;
            },
            else => {
                const entry = self.files.getPtr(fd) orelse {
                    types.writeErrno(results, .badf);
                    return;
                };

                const new_offset: u64 = switch (whence) {
                    .set => blk: {
                        if (offset < 0) {
                            types.writeErrno(results, .inval);
                            return;
                        }
                        break :blk @intCast(offset);
                    },
                    .cur => blk: {
                        const cur = @as(i64, @intCast(entry.offset));
                        const new = cur + offset;
                        if (new < 0) {
                            types.writeErrno(results, .inval);
                            return;
                        }
                        break :blk @intCast(new);
                    },
                    .end => blk: {
                        var stat: Stat = undefined;
                        if (fstat(entry.fd, &stat) < 0) {
                            types.writeErrno(results, .io);
                            return;
                        }
                        const end = @as(i64, @intCast(if (isBsd) stat.size else stat.st_size));
                        const new = end + offset;
                        if (new < 0) {
                            types.writeErrno(results, .inval);
                            return;
                        }
                        break :blk @intCast(new);
                    },
                };

                entry.offset = new_offset;
                try ctx.writeValue(newoffset_ptr, new_offset);
                types.writeErrno(results, .success);
            },
        }
    }

    pub fn fdFilestatGet(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const buf_ptr = params[1].readAs(u32);

        const result: types.Filestat = switch (fd) {
            0 => .{
                .dev = 0,
                .ino = 0,
                .filetype = .character_device,
                .nlink = 1,
                .size = 0,
                .atim = 0,
                .mtim = 0,
                .ctim = 0,
            },
            1, 2 => .{
                .dev = 0,
                .ino = fd,
                .filetype = .character_device,
                .nlink = 1,
                .size = 0,
                .atim = 0,
                .mtim = 0,
                .ctim = 0,
            },
            else => {
                if (self.files.get(fd)) |entry| {
                    var stat: Stat = undefined;
                    if (fstat(entry.fd, &stat) < 0) {
                        types.writeErrno(results, .io);
                        return;
                    }
                    const fs = statToFilestat(stat);
                    try ctx.writeBytes(buf_ptr, std.mem.asBytes(&fs));
                    types.writeErrno(results, .success);
                    return;
                }

                if (self.preopens.get(fd)) |preopen| {
                    var stat: Stat = undefined;
                    if (fstat(preopen.fd, &stat) < 0) {
                        types.writeErrno(results, .io);
                        return;
                    }
                    const fs = statToFilestat(stat);
                    try ctx.writeBytes(buf_ptr, std.mem.asBytes(&fs));
                    types.writeErrno(results, .success);
                    return;
                }

                types.writeErrno(results, .badf);
                return;
            },
        };

        try ctx.writeBytes(buf_ptr, std.mem.asBytes(&result));
        types.writeErrno(results, .success);
    }

    pub fn fdPwrite(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const iovs_ptr = params[1].readAs(u32);
        const iovs_len = params[2].readAs(u32);
        const offset = params[3].readAs(i64);
        const nwritten_ptr = params[4].readAs(u32);

        switch (fd) {
            0, 1, 2 => {
                types.writeErrno(results, .spi);
            },
            else => {
                if (offset < 0) {
                    types.writeErrno(results, .inval);
                    return;
                }

                const entry = self.files.getPtr(fd) orelse {
                    types.writeErrno(results, .badf);
                    return;
                };

                const iovs = try ctx.readSlice(iovs_ptr, iovs_len, types.Ciovec);
                var total_written: u32 = 0;

                if (std.c.lseek(entry.fd, @intCast(offset), @as(c_int, 0)) < 0) {
                    types.writeErrno(results, .io);
                    return;
                }

                for (iovs) |iov| {
                    const bytes = try ctx.readBytes(iov.buf, iov.buf_len);
                    const n = std.c.write(entry.fd, bytes.ptr, bytes.len);
                    if (n < 0) {
                        types.writeErrno(results, .io);
                        return;
                    }
                    total_written +%= @intCast(n);
                }

                try ctx.writeValue(nwritten_ptr, total_written);
                types.writeErrno(results, .success);
            },
        }
    }

    pub fn fdPread(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const iovs_ptr = params[1].readAs(u32);
        const iovs_len = params[2].readAs(u32);
        const offset = params[3].readAs(i64);
        const nread_ptr = params[4].readAs(u32);

        switch (fd) {
            0, 1, 2 => {
                types.writeErrno(results, .spi);
            },
            else => {
                if (offset < 0) {
                    types.writeErrno(results, .inval);
                    return;
                }

                const entry = self.files.getPtr(fd) orelse {
                    types.writeErrno(results, .badf);
                    return;
                };

                const iovs = try ctx.readSlice(iovs_ptr, iovs_len, types.Iovec);
                var total_read: u32 = 0;

                if (std.c.lseek(entry.fd, @intCast(offset), @as(c_int, 0)) < 0) {
                    types.writeErrno(results, .io);
                    return;
                }

                for (iovs) |iov| {
                    const buf = iov.buf;
                    const buf_len = iov.buf_len;
                    const guest_mem = ctx.memory() orelse {
                        types.writeErrno(results, .fault);
                        return;
                    };

                    if (buf >= guest_mem.len) {
                        types.writeErrno(results, .fault);
                        return;
                    }

                    const bytes_to_read = @min(buf_len, @as(u32, @intCast(guest_mem.len - buf)));
                    const read_buf = guest_mem[buf .. buf + bytes_to_read];

                    const bytes_read = std.c.read(entry.fd, read_buf.ptr, read_buf.len);
                    if (bytes_read < 0) {
                        types.writeErrno(results, .io);
                        return;
                    }

                    total_read +%= @intCast(bytes_read);
                    if (bytes_read == 0 or @as(u64, @intCast(bytes_read)) < buf_len) break;
                }

                try ctx.writeValue(nread_ptr, total_read);
                types.writeErrno(results, .success);
            },
        }
    }

    pub fn fdFdstatGet(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const buf_ptr = params[1].readAs(u32);

        const fdstat: types.FdStat = switch (fd) {
            0 => .{
                .fs_filetype = .character_device,
                .fs_flags = .{},
                .fs_rights_base = .{ .fd_read = true },
                .fs_rights_inheriting = .{},
            },
            1, 2 => .{
                .fs_filetype = .character_device,
                .fs_flags = .{},
                .fs_rights_base = .{ .fd_write = true },
                .fs_rights_inheriting = .{},
            },
            else => {
                if (self.files.get(fd)) |entry| {
                    var stat: Stat = undefined;
                    if (fstat(entry.fd, &stat) < 0) {
                        types.writeErrno(results, .io);
                        return;
                    }
                    const result: types.FdStat = .{
                        .fs_filetype = modeToFiletype(@as(u16, @intCast(if (isBsd) stat.mode else stat.st_mode))),
                        .fs_flags = .{},
                        .fs_rights_base = entry.rights,
                        .fs_rights_inheriting = .{},
                    };
                    try ctx.writeBytes(buf_ptr, std.mem.asBytes(&result));
                    types.writeErrno(results, .success);
                    return;
                }

                if (self.preopens.get(fd)) |_| {
                    const result: types.FdStat = .{
                        .fs_filetype = .directory,
                        .fs_flags = .{},
                        .fs_rights_base = .{
                            .fd_read = true,
                            .fd_write = true,
                            .fd_seek = true,
                            .fd_filestat_get = true,
                            .path_create_directory = true,
                            .path_create_file = true,
                            .path_filestat_get = true,
                            .path_unlink_file = true,
                            .path_remove_directory = true,
                        },
                        .fs_rights_inheriting = .{},
                    };
                    try ctx.writeBytes(buf_ptr, std.mem.asBytes(&result));
                    types.writeErrno(results, .success);
                    return;
                }

                types.writeErrno(results, .badf);
                return;
            },
        };

        try ctx.writeBytes(buf_ptr, std.mem.asBytes(&fdstat));
        types.writeErrno(results, .success);
    }

    pub fn fdPrestatGet(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const buf_ptr = params[1].readAs(u32);

        const preopen = self.preopens.get(fd) orelse {
            types.writeErrno(results, .badf);
            return;
        };

        const Prestat = extern struct {
            pr_type: packed struct(u32) { tag: u32 = 0 },
            u: extern union {
                dir: extern struct {
                    pr_len: u32,
                },
            },
        };

        const prestat: Prestat = .{
            .pr_type = .{},
            .u = .{ .dir = .{ .pr_len = @intCast(preopen.path.len) } },
        };

        try ctx.writeBytes(buf_ptr, std.mem.asBytes(&prestat));
        types.writeErrno(results, .success);
    }

    pub fn fdPrestatDirName(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const path_ptr = params[1].readAs(u32);
        const path_len = params[2].readAs(u32);

        const preopen = self.preopens.get(fd) orelse {
            types.writeErrno(results, .badf);
            return;
        };

        const copy_len = @min(path_len, @as(u32, @intCast(preopen.path.len)));
        const bytes_to_write = preopen.path[0..copy_len];
        try ctx.writeBytes(path_ptr, bytes_to_write);

        types.writeErrno(results, .success);
    }

    pub fn fdAdvise(self: *Self, _: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        _ = params[1];
        _ = params[2];
        _ = params[3];

        switch (fd) {
            0, 1, 2 => {
                types.writeErrno(results, .success);
            },
            else => {
                if (self.files.get(fd) == null) {
                    types.writeErrno(results, .badf);
                    return;
                }
                types.writeErrno(results, .success);
            },
        }
    }

    pub fn fdAllocate(self: *Self, _: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const offset = params[1].readAs(i64);
        const len = params[2].readAs(i64);

        switch (fd) {
            0, 1, 2 => {
                types.writeErrno(results, .badf);
            },
            else => {
                const entry = self.files.getPtr(fd) orelse {
                    types.writeErrno(results, .badf);
                    return;
                };
                if (entry.kind != .file) {
                    types.writeErrno(results, .badf);
                    return;
                }
                if (offset < 0 or len < 0) {
                    types.writeErrno(results, .inval);
                    return;
                }
                const new_size: u64 = @intCast(offset + len);
                var stat: Stat = undefined;
                if (fstat(entry.fd, &stat) < 0) {
                    types.writeErrno(results, .io);
                    return;
                }
                if (new_size > @as(u64, @intCast(if (isBsd) stat.size else stat.st_size))) {
                    if (ftruncate(entry.fd, @intCast(new_size)) < 0) {
                        types.writeErrno(results, .io);
                        return;
                    }
                }
                types.writeErrno(results, .success);
            },
        }
    }

    pub fn fdDatasync(self: *Self, _: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);

        switch (fd) {
            0, 1, 2 => {
                types.writeErrno(results, .success);
            },
            else => {
                const entry = self.files.getPtr(fd) orelse {
                    types.writeErrno(results, .badf);
                    return;
                };
                if (entry.kind != .file) {
                    types.writeErrno(results, .badf);
                    return;
                }
                if (std.c.fsync(entry.fd) < 0) {
                    types.writeErrno(results, .io);
                    return;
                }
                types.writeErrno(results, .success);
            },
        }
    }

    pub fn fdFdstatSetFlags(self: *Self, _: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        _ = params[1];

        switch (fd) {
            0, 1, 2 => {
                types.writeErrno(results, .success);
            },
            else => {
                if (self.files.get(fd) == null) {
                    types.writeErrno(results, .badf);
                    return;
                }
                types.writeErrno(results, .success);
            },
        }
    }

    pub fn fdFdstatSetRights(self: *Self, _: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const fs_rights_base: types.Rights = @bitCast(params[1].readAs(u64));
        _ = params[2];

        switch (fd) {
            0, 1, 2 => {
                types.writeErrno(results, .success);
            },
            else => {
                const entry = self.files.getPtr(fd) orelse {
                    types.writeErrno(results, .badf);
                    return;
                };
                entry.rights = fs_rights_base;
                types.writeErrno(results, .success);
            },
        }
    }

    pub fn fdFilestatSetSize(self: *Self, _: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const size = params[1].readAs(u64);

        switch (fd) {
            0, 1, 2 => {
                types.writeErrno(results, .badf);
            },
            else => {
                const entry = self.files.getPtr(fd) orelse {
                    types.writeErrno(results, .badf);
                    return;
                };
                if (entry.kind != .file) {
                    types.writeErrno(results, .badf);
                    return;
                }
                if (ftruncate(entry.fd, @intCast(size)) < 0) {
                    types.writeErrno(results, .io);
                    return;
                }
                types.writeErrno(results, .success);
            },
        }
    }

    pub fn fdFilestatSetTimes(self: *Self, _: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        _ = params[1];
        _ = params[2];
        _ = params[3];

        switch (fd) {
            0, 1, 2 => {
                types.writeErrno(results, .badf);
            },
            else => {
                if (self.files.get(fd) == null) {
                    types.writeErrno(results, .badf);
                    return;
                }
                types.writeErrno(results, .nosys);
            },
        }
    }

    pub fn fdReaddir(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const buf_ptr = params[1].readAs(u32);
        const buf_len = params[2].readAs(u32);
        const cookie = params[3].readAs(u64);
        const bufused_ptr = params[4].readAs(u32);

        const dir_fd: std.c.fd_t = blk: {
            if (self.files.getPtr(fd)) |entry| {
                if (entry.kind != .directory) {
                    types.writeErrno(results, .notdir);
                    return;
                }
                break :blk entry.fd;
            }
            if (self.preopens.getPtr(fd)) |preopen| {
                break :blk preopen.fd;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const guest_mem = ctx.memory() orelse {
            types.writeErrno(results, .fault);
            return;
        };

        if (buf_ptr >= guest_mem.len) {
            types.writeErrno(results, .fault);
            return;
        }

        const available = @min(buf_len, @as(u32, @intCast(guest_mem.len - buf_ptr)));

        const dir = std.c.fdopendir(dir_fd) orelse {
            types.writeErrno(results, .noent);
            return;
        };
        defer _ = std.c.closedir(dir);

        var write_offset: u32 = 0;
        var current_cookie: u64 = 0;

        // Skip entries until we reach the cookie
        while (current_cookie < cookie) {
            const entry = std.c.readdir(dir) orelse break;
            _ = entry;
            current_cookie += 1;
        }

        // Write directory entries into the buffer
        while (true) {
            const entry = std.c.readdir(dir) orelse break;

            const name_bytes = &entry.name;
            const name_len: u32 = if (@hasField(@TypeOf(entry.*), "namlen"))
                @intCast(entry.namlen)
            else
                @intCast(std.mem.indexOfScalar(u8, name_bytes, 0) orelse name_bytes.len);
            const name_slice = name_bytes[0..name_len];
            const dirent_size: u32 = @intCast(@sizeOf(types.Dirent));
            const needed = dirent_size + name_len;

            if (write_offset + needed > available) break;

            current_cookie += 1;
            const wasi_dirent = types.Dirent{
                .d_next = current_cookie,
                .d_ino = entry.ino,
                .d_namlen = name_len,
                .d_type = if (@hasField(@TypeOf(entry.*), "type"))
                    direntTypeToFiletype(entry.type)
                else
                    .unknown,
            };

            const dirent_bytes = std.mem.asBytes(&wasi_dirent);
            @memcpy(guest_mem[buf_ptr + write_offset .. buf_ptr + write_offset + dirent_size], dirent_bytes);
            write_offset += dirent_size;
            @memcpy(guest_mem[buf_ptr + write_offset .. buf_ptr + write_offset + name_len], name_slice);
            write_offset += name_len;
        }

        try ctx.writeValue(bufused_ptr, write_offset);
        types.writeErrno(results, .success);
    }

    pub fn fdRenumber(self: *Self, _: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const to = params[1].readAs(u32);

        if (fd == to) {
            types.writeErrno(results, .success);
            return;
        }

        if (self.files.fetchRemove(to)) |removed| {
            _ = std.c.close(removed.value.fd);
        } else if (self.preopens.fetchRemove(to)) |removed| {
            _ = std.c.close(removed.value.fd);
            self.allocator.free(removed.value.path);
        }

        if (self.files.fetchRemove(fd)) |removed| {
            self.files.put(to, removed.value) catch {
                types.writeErrno(results, .io);
                return;
            };
            types.writeErrno(results, .success);
        } else if (self.preopens.fetchRemove(fd)) |removed| {
            self.preopens.put(to, removed.value) catch {
                types.writeErrno(results, .io);
                return;
            };
            types.writeErrno(results, .success);
        } else {
            types.writeErrno(results, .badf);
        }
    }

    pub fn fdSync(self: *Self, _: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);

        switch (fd) {
            0, 1, 2 => {
                types.writeErrno(results, .success);
            },
            else => {
                const entry = self.files.getPtr(fd) orelse {
                    types.writeErrno(results, .badf);
                    return;
                };
                if (entry.kind != .file) {
                    types.writeErrno(results, .badf);
                    return;
                }
                if (std.c.fsync(entry.fd) < 0) {
                    types.writeErrno(results, .io);
                    return;
                }
                types.writeErrno(results, .success);
            },
        }
    }

    pub fn fdTell(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const offset_ptr = params[1].readAs(u32);

        switch (fd) {
            0, 1, 2 => {
                types.writeErrno(results, .spi);
            },
            else => {
                const entry = self.files.getPtr(fd) orelse {
                    types.writeErrno(results, .badf);
                    return;
                };
                try ctx.writeValue(offset_ptr, entry.offset);
                types.writeErrno(results, .success);
            },
        }
    }

    pub fn pathCreateDirectory(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const path_ptr = params[1].readAs(u32);
        const path_len = params[2].readAs(u32);

        const dir_fd: std.c.fd_t = blk: {
            if (self.preopens.get(fd)) |p| break :blk p.fd;
            if (self.files.get(fd)) |e| {
                if (e.kind == .directory) break :blk e.fd;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const path_bytes = try ctx.readBytes(path_ptr, path_len);
        const path = std.mem.sliceTo(path_bytes, 0);
        const path_z = try self.allocator.dupeSentinel(u8, path, 0);
        defer self.allocator.free(path_z);

        const rc = std.c.mkdirat(dir_fd, path_z, @as(c_uint, 0o755));
        if (rc < 0) {
            types.writeErrno(results, errnoToWasi(rc));
            return;
        }
        types.writeErrno(results, .success);
    }

    pub fn pathFilestatGet(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        _ = params[1]; // flags (symlink_follow)
        const path_ptr = params[2].readAs(u32);
        const path_len = params[3].readAs(u32);
        const buf_ptr = params[4].readAs(u32);

        const dir_fd: std.c.fd_t = blk: {
            if (self.preopens.get(fd)) |p| break :blk p.fd;
            if (self.files.get(fd)) |e| {
                if (e.kind == .directory) break :blk e.fd;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const path_bytes = try ctx.readBytes(path_ptr, path_len);
        const path = std.mem.sliceTo(path_bytes, 0);
        const path_z = try self.allocator.dupeSentinel(u8, path, 0);
        defer self.allocator.free(path_z);

        var stat: Stat = undefined;
        if (fstatat(dir_fd, path_z, &stat, @as(u32, AT_SYMLINK_NOFOLLOW)) < 0) {
            types.writeErrno(results, .noent);
            return;
        }

        const result = statToFilestat(stat);
        try ctx.writeBytes(buf_ptr, std.mem.asBytes(&result));
        types.writeErrno(results, .success);
    }

    pub fn pathFilestatSetTimes(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        _ = params[1]; // flags
        const path_ptr = params[2].readAs(u32);
        const path_len = params[3].readAs(u32);
        _ = params[4]; // atim
        _ = params[5]; // mtim
        _ = params[6]; // fst_flags

        const path_bytes = try ctx.readBytes(path_ptr, path_len);
        _ = std.mem.sliceTo(path_bytes, 0);

        if (self.preopens.get(fd) == null and self.files.get(fd) == null) {
            types.writeErrno(results, .badf);
            return;
        }

        types.writeErrno(results, .nosys);
    }

    pub fn pathLink(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const old_fd = params[0].readAs(u32);
        _ = params[1]; // old_flags
        const old_path_ptr = params[2].readAs(u32);
        const old_path_len = params[3].readAs(u32);
        const new_fd = params[4].readAs(u32);
        const new_path_ptr = params[5].readAs(u32);
        const new_path_len = params[6].readAs(u32);

        const old_dir_fd: std.c.fd_t = blk: {
            if (self.preopens.get(old_fd)) |p| break :blk p.fd;
            if (self.files.get(old_fd)) |e| {
                if (e.kind == .directory) break :blk e.fd;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const new_dir_fd: std.c.fd_t = blk: {
            if (self.preopens.get(new_fd)) |p| break :blk p.fd;
            if (self.files.get(new_fd)) |e| {
                if (e.kind == .directory) break :blk e.fd;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const old_path_bytes = try ctx.readBytes(old_path_ptr, old_path_len);
        const old_path = std.mem.sliceTo(old_path_bytes, 0);
        const new_path_bytes = try ctx.readBytes(new_path_ptr, new_path_len);
        const new_path = std.mem.sliceTo(new_path_bytes, 0);

        const old_path_z = try self.allocator.dupeSentinel(u8, old_path, 0);
        defer self.allocator.free(old_path_z);
        const new_path_z = try self.allocator.dupeSentinel(u8, new_path, 0);
        defer self.allocator.free(new_path_z);

        // Try hard link first; fall back to nosys if not available
        const rc = std.c.linkat(old_dir_fd, old_path_z, new_dir_fd, new_path_z, @as(c_uint, 0));
        if (rc < 0) {
            const err = std.c.errno(rc);
            if (err == .NOSYS or err == .MLINK or err == .OPNOTSUPP) {
                types.writeErrno(results, .nosys);
                return;
            }
            types.writeErrno(results, errnoToWasi(rc));
            return;
        }

        types.writeErrno(results, .success);
    }

    pub fn pathReadlink(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const path_ptr = params[1].readAs(u32);
        const path_len = params[2].readAs(u32);
        const buf_ptr = params[3].readAs(u32);
        const buf_len = params[4].readAs(u32);
        const bufused_ptr = params[5].readAs(u32);

        const dir_fd: std.c.fd_t = blk: {
            if (self.preopens.get(fd)) |p| break :blk p.fd;
            if (self.files.get(fd)) |e| {
                if (e.kind == .directory) break :blk e.fd;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const path_bytes = try ctx.readBytes(path_ptr, path_len);
        const path = std.mem.sliceTo(path_bytes, 0);
        const path_z = try self.allocator.dupeSentinel(u8, path, 0);
        defer self.allocator.free(path_z);

        const guest_mem = ctx.memory() orelse {
            types.writeErrno(results, .fault);
            return;
        };

        if (buf_ptr >= guest_mem.len) {
            types.writeErrno(results, .fault);
            return;
        }

        const available = @min(buf_len, @as(u32, @intCast(guest_mem.len - buf_ptr)));
        var link_buf: [std.c.PATH_MAX]u8 = undefined;

        const n = std.c.readlinkat(dir_fd, path_z, &link_buf, link_buf.len);
        if (n < 0) {
            types.writeErrno(results, errnoToWasi(@intCast(n)));
            return;
        }

        const link_target = link_buf[0..@intCast(n)];
        const copy_len = @min(@as(u32, @intCast(link_target.len)), available);
        @memcpy(guest_mem[buf_ptr .. buf_ptr + copy_len], link_target[0..copy_len]);
        try ctx.writeValue(bufused_ptr, copy_len);
        types.writeErrno(results, .success);
    }

    pub fn pathRemoveDirectory(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const path_ptr = params[1].readAs(u32);
        const path_len = params[2].readAs(u32);

        const dir_fd: std.c.fd_t = blk: {
            if (self.preopens.get(fd)) |p| break :blk p.fd;
            if (self.files.get(fd)) |e| {
                if (e.kind == .directory) break :blk e.fd;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const path_bytes = try ctx.readBytes(path_ptr, path_len);
        const path = std.mem.sliceTo(path_bytes, 0);
        const path_z = try self.allocator.dupeSentinel(u8, path, 0);
        defer self.allocator.free(path_z);

        const rc = std.c.unlinkat(dir_fd, path_z, @as(c_uint, std.c.AT.REMOVEDIR));
        if (rc < 0) {
            types.writeErrno(results, errnoToWasi(rc));
            return;
        }
        types.writeErrno(results, .success);
    }

    pub fn pathRename(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const old_fd = params[0].readAs(u32);
        const old_path_ptr = params[1].readAs(u32);
        const old_path_len = params[2].readAs(u32);
        const new_fd = params[3].readAs(u32);
        const new_path_ptr = params[4].readAs(u32);
        const new_path_len = params[5].readAs(u32);

        const old_dir_fd: std.c.fd_t = blk: {
            if (self.preopens.get(old_fd)) |p| break :blk p.fd;
            if (self.files.get(old_fd)) |e| {
                if (e.kind == .directory) break :blk e.fd;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const new_dir_fd: std.c.fd_t = blk: {
            if (self.preopens.get(new_fd)) |p| break :blk p.fd;
            if (self.files.get(new_fd)) |e| {
                if (e.kind == .directory) break :blk e.fd;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const old_path_bytes = try ctx.readBytes(old_path_ptr, old_path_len);
        const old_path = std.mem.sliceTo(old_path_bytes, 0);
        const new_path_bytes = try ctx.readBytes(new_path_ptr, new_path_len);
        const new_path = std.mem.sliceTo(new_path_bytes, 0);

        const old_path_z = try self.allocator.dupeSentinel(u8, old_path, 0);
        defer self.allocator.free(old_path_z);
        const new_path_z = try self.allocator.dupeSentinel(u8, new_path, 0);
        defer self.allocator.free(new_path_z);

        const rc = std.c.renameat(old_dir_fd, old_path_z, new_dir_fd, new_path_z);
        if (rc < 0) {
            types.writeErrno(results, errnoToWasi(rc));
            return;
        }
        types.writeErrno(results, .success);
    }

    pub fn pathSymlink(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const old_path_ptr = params[0].readAs(u32);
        const old_path_len = params[1].readAs(u32);
        const fd = params[2].readAs(u32);
        const new_path_ptr = params[3].readAs(u32);
        const new_path_len = params[4].readAs(u32);

        const dir_fd: std.c.fd_t = blk: {
            if (self.preopens.get(fd)) |p| break :blk p.fd;
            if (self.files.get(fd)) |e| {
                if (e.kind == .directory) break :blk e.fd;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const old_path_bytes = try ctx.readBytes(old_path_ptr, old_path_len);
        const old_path = std.mem.sliceTo(old_path_bytes, 0);
        const new_path_bytes = try ctx.readBytes(new_path_ptr, new_path_len);
        const new_path = std.mem.sliceTo(new_path_bytes, 0);

        const old_path_z = try self.allocator.dupeSentinel(u8, old_path, 0);
        defer self.allocator.free(old_path_z);
        const new_path_z = try self.allocator.dupeSentinel(u8, new_path, 0);
        defer self.allocator.free(new_path_z);

        const rc = std.c.symlinkat(old_path_z, dir_fd, new_path_z);
        if (rc < 0) {
            types.writeErrno(results, errnoToWasi(rc));
            return;
        }
        types.writeErrno(results, .success);
    }

    pub fn pathUnlinkFile(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const path_ptr = params[1].readAs(u32);
        const path_len = params[2].readAs(u32);

        const dir_fd: std.c.fd_t = blk: {
            if (self.preopens.get(fd)) |p| break :blk p.fd;
            if (self.files.get(fd)) |e| {
                if (e.kind == .directory) break :blk e.fd;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const path_bytes = try ctx.readBytes(path_ptr, path_len);
        const path = std.mem.sliceTo(path_bytes, 0);
        const path_z = try self.allocator.dupeSentinel(u8, path, 0);
        defer self.allocator.free(path_z);

        const rc = std.c.unlinkat(dir_fd, path_z, @as(c_uint, 0));
        if (rc < 0) {
            types.writeErrno(results, errnoToWasi(rc));
            return;
        }
        types.writeErrno(results, .success);
    }
};

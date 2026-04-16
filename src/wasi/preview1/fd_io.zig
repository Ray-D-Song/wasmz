const std = @import("std");
const core = @import("core");
const wasmz = @import("wasmz");
const types = @import("./types.zig");

const Allocator = std.mem.Allocator;
const RawVal = core.RawVal;
const HostContext = wasmz.HostContext;

fn wasiInode(inode: anytype) u64 {
    const T = @TypeOf(inode);
    const info = @typeInfo(T);
    if (info != .int) @compileError("inode must be an integer");

    return switch (info.int.signedness) {
        .unsigned => @as(u64, @intCast(inode)),
        .signed => blk: {
            const UnsignedT = std.meta.Int(.unsigned, @bitSizeOf(T));
            const raw: UnsignedT = @bitCast(inode);
            break :blk @as(u64, @intCast(raw));
        },
    };
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
        std.fs.File.stdout().writeAll(bytes) catch return error.Io;
    }

    fn write_stderr(_: ?*anyopaque, bytes: []const u8) WriteError!void {
        std.fs.File.stderr().writeAll(bytes) catch return error.Io;
    }
};

const FileEntry = struct {
    kind: enum { file, directory },
    handle: union {
        file: std.fs.File,
        directory: std.fs.Dir,
    },
    offset: u64,
    rights: types.Rights,
};

const Preopen = struct {
    path: []const u8,
    dir: std.fs.Dir,
};

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
            switch (entry.value_ptr.kind) {
                .file => entry.value_ptr.handle.file.close(),
                .directory => {
                    var dir = @constCast(&entry.value_ptr.handle.directory);
                    dir.close();
                },
            }
        }
        self.files.deinit();

        var preopen_iter = self.preopens.iterator();
        while (preopen_iter.next()) |entry| {
            var dir = @constCast(&entry.value_ptr.dir);
            dir.close();
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
        const dir = std.fs.cwd().openDir(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.PathNotFound,
            error.NotDir => return error.NotDirectory,
            else => return error.Io,
        };

        const fd = self.next_fd;
        self.next_fd +%= 1;

        const path_dup = try self.allocator.dupe(u8, path);
        try self.preopens.put(fd, .{
            .path = path_dup,
            .dir = dir,
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

        const entry: FileEntry = blk: {
            if (oflags.directory) {
                const subdir = preopen.dir.openDir(path, .{}) catch {
                    types.writeErrno(results, .noent);
                    return;
                };
                break :blk .{
                    .kind = .directory,
                    .handle = .{ .directory = subdir },
                    .offset = 0,
                    .rights = fs_rights_base,
                };
            }

            if (oflags.creat) {
                const file = preopen.dir.createFile(path, .{ .truncate = oflags.trunc }) catch {
                    types.writeErrno(results, .exist);
                    return;
                };
                break :blk .{
                    .kind = .file,
                    .handle = .{ .file = file },
                    .offset = 0,
                    .rights = fs_rights_base,
                };
            }

            const file = preopen.dir.openFile(path, .{ .mode = .read_write }) catch {
                types.writeErrno(results, .noent);
                return;
            };
            break :blk .{
                .kind = .file,
                .handle = .{ .file = file },
                .offset = 0,
                .rights = fs_rights_base,
            };
        };

        const new_fd = self.next_fd;
        self.next_fd +%= 1;

        try self.files.put(new_fd, entry);

        try ctx.writeValue(fd_ptr, new_fd);
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
                    switch (removed.value.kind) {
                        .file => removed.value.handle.file.close(),
                        .directory => {
                            var dir = @constCast(&removed.value.handle.directory);
                            dir.close();
                        },
                    }
                    types.writeErrno(results, .success);
                } else if (self.preopens.fetchRemove(fd)) |removed| {
                    var dir = @constCast(&removed.value.dir);
                    dir.close();
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
                    self.stdout.writeAll(bytes) catch {
                        types.writeErrno(results, .io);
                        return;
                    };
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
                    self.stderr.writeAll(bytes) catch {
                        types.writeErrno(results, .io);
                        return;
                    };
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

                entry.handle.file.seekTo(entry.offset) catch {
                    types.writeErrno(results, .io);
                    return;
                };

                for (iovs) |iov| {
                    const bytes = try ctx.readBytes(iov.buf, iov.buf_len);
                    const written = entry.handle.file.write(bytes) catch {
                        types.writeErrno(results, .io);
                        return;
                    };
                    total_written +%= @intCast(written);
                    entry.offset += written;
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

                    const bytes_read = std.fs.File.stdin().read(read_buf) catch {
                        types.writeErrno(results, .io);
                        return;
                    };

                    total_read +%= @intCast(bytes_read);
                    if (bytes_read < buf_len) break;
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

                entry.handle.file.seekTo(entry.offset) catch {
                    types.writeErrno(results, .io);
                    return;
                };

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

                    const bytes_read = entry.handle.file.read(read_buf) catch {
                        types.writeErrno(results, .io);
                        return;
                    };

                    total_read +%= @intCast(bytes_read);
                    entry.offset += bytes_read;
                    if (bytes_read < buf_len) break;
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
                        const stat = entry.handle.file.stat() catch {
                            types.writeErrno(results, .io);
                            return;
                        };
                        const end = @as(i64, @intCast(stat.size));
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

        const stat: types.Filestat = switch (fd) {
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
                    const file_stat = entry.handle.file.stat() catch {
                        types.writeErrno(results, .io);
                        return;
                    };

                    const result: types.Filestat = .{
                        .dev = 0,
                        .ino = wasiInode(file_stat.inode),
                        .filetype = switch (file_stat.kind) {
                            .file => .regular_file,
                            .directory => .directory,
                            .sym_link => .symbolic_link,
                            else => .unknown,
                        },
                        .nlink = 1,
                        .size = file_stat.size,
                        .atim = @intCast(file_stat.atime),
                        .mtim = @intCast(file_stat.mtime),
                        .ctim = @intCast(file_stat.ctime),
                    };

                    try ctx.writeBytes(buf_ptr, std.mem.asBytes(&result));
                    types.writeErrno(results, .success);
                    return;
                }

                if (self.preopens.get(fd)) |preopen| {
                    const dir_stat = preopen.dir.stat() catch {
                        types.writeErrno(results, .io);
                        return;
                    };

                    const result: types.Filestat = .{
                        .dev = 0,
                        .ino = wasiInode(dir_stat.inode),
                        .filetype = .directory,
                        .nlink = 1,
                        .size = dir_stat.size,
                        .atim = @intCast(dir_stat.atime),
                        .mtim = @intCast(dir_stat.mtime),
                        .ctim = @intCast(dir_stat.ctime),
                    };

                    try ctx.writeBytes(buf_ptr, std.mem.asBytes(&result));
                    types.writeErrno(results, .success);
                    return;
                }

                types.writeErrno(results, .badf);
                return;
            },
        };

        try ctx.writeBytes(buf_ptr, std.mem.asBytes(&stat));
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

                entry.handle.file.seekTo(@intCast(offset)) catch {
                    types.writeErrno(results, .io);
                    return;
                };

                for (iovs) |iov| {
                    const bytes = try ctx.readBytes(iov.buf, iov.buf_len);
                    const written = entry.handle.file.write(bytes) catch {
                        types.writeErrno(results, .io);
                        return;
                    };
                    total_written +%= @intCast(written);
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

                entry.handle.file.seekTo(@intCast(offset)) catch {
                    types.writeErrno(results, .io);
                    return;
                };

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

                    const bytes_read = entry.handle.file.read(read_buf) catch {
                        types.writeErrno(results, .io);
                        return;
                    };

                    total_read +%= @intCast(bytes_read);
                    if (bytes_read < buf_len) break;
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
                    const file_stat = entry.handle.file.stat() catch {
                        types.writeErrno(results, .io);
                        return;
                    };

                    const result: types.FdStat = .{
                        .fs_filetype = switch (file_stat.kind) {
                            .file => .regular_file,
                            .directory => .directory,
                            .sym_link => .symbolic_link,
                            else => .unknown,
                        },
                        .fs_flags = .{},
                        .fs_rights_base = entry.rights,
                        .fs_rights_inheriting = .{},
                    };

                    try ctx.writeBytes(buf_ptr, std.mem.asBytes(&result));
                    types.writeErrno(results, .success);
                    return;
                }

                if (self.preopens.get(fd)) |preopen| {
                    _ = preopen;
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

    /// fd_advise: Provide file access advice (hint only, no-op is acceptable)
    /// params: fd(i32), offset(i64), len(i64), advice(i32)
    pub fn fdAdvise(self: *Self, _: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        // offset and len are hints only; advice is advisory
        _ = params[1]; // offset
        _ = params[2]; // len
        _ = params[3]; // advice

        switch (fd) {
            0, 1, 2 => {
                types.writeErrno(results, .success);
            },
            else => {
                if (self.files.get(fd) == null) {
                    types.writeErrno(results, .badf);
                    return;
                }
                // No-op: posix_fadvise not available everywhere; treat as success
                types.writeErrno(results, .success);
            },
        }
    }

    /// fd_allocate: Allocate space in a file
    /// params: fd(i32), offset(i64), len(i64)
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
                const stat = entry.handle.file.stat() catch {
                    types.writeErrno(results, .io);
                    return;
                };
                if (new_size > stat.size) {
                    entry.handle.file.setEndPos(new_size) catch {
                        types.writeErrno(results, .io);
                        return;
                    };
                }
                types.writeErrno(results, .success);
            },
        }
    }

    /// fd_datasync: Synchronize the data of a file to disk
    /// params: fd(i32)
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
                entry.handle.file.sync() catch {
                    types.writeErrno(results, .io);
                    return;
                };
                types.writeErrno(results, .success);
            },
        }
    }

    /// fd_fdstat_set_flags: Update the flags associated with a file descriptor
    /// params: fd(i32), flags(i32)
    pub fn fdFdstatSetFlags(self: *Self, _: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        _ = params[1]; // flags — not enforced in this implementation

        switch (fd) {
            0, 1, 2 => {
                types.writeErrno(results, .success);
            },
            else => {
                if (self.files.get(fd) == null) {
                    types.writeErrno(results, .badf);
                    return;
                }
                // Flag changes (append/nonblock/sync) are not persisted in this impl
                types.writeErrno(results, .success);
            },
        }
    }

    /// fd_fdstat_set_rights: Update the rights of a file descriptor
    /// params: fd(i32), fs_rights_base(i64), fs_rights_inheriting(i64)
    pub fn fdFdstatSetRights(self: *Self, _: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const fs_rights_base: types.Rights = @bitCast(params[1].readAs(u64));
        _ = params[2]; // fs_rights_inheriting

        switch (fd) {
            0, 1, 2 => {
                types.writeErrno(results, .success);
            },
            else => {
                const entry = self.files.getPtr(fd) orelse {
                    types.writeErrno(results, .badf);
                    return;
                };
                // Rights can only be reduced, not increased
                entry.rights = fs_rights_base;
                types.writeErrno(results, .success);
            },
        }
    }

    /// fd_filestat_set_size: Set the size of a file
    /// params: fd(i32), size(i64)
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
                entry.handle.file.setEndPos(size) catch {
                    types.writeErrno(results, .io);
                    return;
                };
                types.writeErrno(results, .success);
            },
        }
    }

    /// fd_filestat_set_times: Set the timestamps of a file
    /// params: fd(i32), atim(i64), mtim(i64), fst_flags(i32)
    pub fn fdFilestatSetTimes(self: *Self, _: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        _ = params[1]; // atim
        _ = params[2]; // mtim
        _ = params[3]; // fst_flags

        switch (fd) {
            0, 1, 2 => {
                types.writeErrno(results, .badf);
            },
            else => {
                if (self.files.get(fd) == null) {
                    types.writeErrno(results, .badf);
                    return;
                }
                // Timestamp setting is not supported portably; return nosys
                types.writeErrno(results, .nosys);
            },
        }
    }

    /// fd_readdir: Read directory entries
    /// params: fd(i32), buf_ptr(i32), buf_len(i32), cookie(i64), bufused_ptr(i32)
    pub fn fdReaddir(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const buf_ptr = params[1].readAs(u32);
        const buf_len = params[2].readAs(u32);
        const cookie = params[3].readAs(u64);
        const bufused_ptr = params[4].readAs(u32);

        // Get the directory handle
        const dir_handle: std.fs.Dir = blk: {
            if (self.files.getPtr(fd)) |entry| {
                if (entry.kind != .directory) {
                    types.writeErrno(results, .notdir);
                    return;
                }
                break :blk entry.handle.directory;
            }
            if (self.preopens.getPtr(fd)) |preopen| {
                break :blk preopen.dir;
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
        var write_offset: u32 = 0;

        // Open an iterator — we need to re-iterate from the cookie position
        var iter = dir_handle.iterate();
        var current_cookie: u64 = 0;

        // Skip entries until we reach the cookie
        while (current_cookie < cookie) {
            const entry = iter.next() catch {
                types.writeErrno(results, .io);
                return;
            };
            if (entry == null) break;
            current_cookie += 1;
        }

        // Write directory entries into the buffer
        while (true) {
            const entry = iter.next() catch {
                types.writeErrno(results, .io);
                return;
            };
            const e = entry orelse break;

            const name_bytes = e.name;
            const name_len: u32 = @intCast(name_bytes.len);
            const dirent_size: u32 = @intCast(@sizeOf(types.Dirent));
            const needed = dirent_size + name_len;

            if (write_offset + needed > available) break;

            current_cookie += 1;
            const dirent = types.Dirent{
                .d_next = current_cookie,
                .d_ino = 0,
                .d_namlen = name_len,
                .d_type = switch (e.kind) {
                    .file => .regular_file,
                    .directory => .directory,
                    .sym_link => .symbolic_link,
                    else => .unknown,
                },
            };

            const dirent_bytes = std.mem.asBytes(&dirent);
            @memcpy(guest_mem[buf_ptr + write_offset .. buf_ptr + write_offset + dirent_size], dirent_bytes);
            write_offset += dirent_size;
            @memcpy(guest_mem[buf_ptr + write_offset .. buf_ptr + write_offset + name_len], name_bytes);
            write_offset += name_len;
        }

        try ctx.writeValue(bufused_ptr, write_offset);
        types.writeErrno(results, .success);
    }

    /// fd_renumber: Renumber a file descriptor
    /// params: fd(i32), to(i32)
    pub fn fdRenumber(self: *Self, _: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const to = params[1].readAs(u32);

        if (fd == to) {
            types.writeErrno(results, .success);
            return;
        }

        // Close the destination fd if it exists
        if (self.files.fetchRemove(to)) |removed| {
            switch (removed.value.kind) {
                .file => removed.value.handle.file.close(),
                .directory => {
                    var dir = @constCast(&removed.value.handle.directory);
                    dir.close();
                },
            }
        } else if (self.preopens.fetchRemove(to)) |removed| {
            var dir = @constCast(&removed.value.dir);
            dir.close();
            self.allocator.free(removed.value.path);
        }

        // Move source to destination
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

    /// fd_sync: Synchronize the data and metadata of a file to disk
    /// params: fd(i32)
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
                entry.handle.file.sync() catch {
                    types.writeErrno(results, .io);
                    return;
                };
                types.writeErrno(results, .success);
            },
        }
    }

    /// fd_tell: Return the current offset of a file descriptor
    /// params: fd(i32), offset_ptr(i32)
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

    /// path_create_directory: Create a directory
    /// params: fd(i32), path_ptr(i32), path_len(i32)
    pub fn pathCreateDirectory(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const path_ptr = params[1].readAs(u32);
        const path_len = params[2].readAs(u32);

        const dir_handle: std.fs.Dir = blk: {
            if (self.preopens.get(fd)) |p| break :blk p.dir;
            if (self.files.get(fd)) |e| {
                if (e.kind == .directory) break :blk e.handle.directory;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const path_bytes = try ctx.readBytes(path_ptr, path_len);
        const path = std.mem.sliceTo(path_bytes, 0);

        dir_handle.makeDir(path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                types.writeErrno(results, .exist);
                return;
            },
            error.FileNotFound => {
                types.writeErrno(results, .noent);
                return;
            },
            else => {
                types.writeErrno(results, .io);
                return;
            },
        };

        types.writeErrno(results, .success);
    }

    /// path_filestat_get: Get file status for a path
    /// params: fd(i32), flags(i32), path_ptr(i32), path_len(i32), buf_ptr(i32)
    pub fn pathFilestatGet(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        _ = params[1]; // flags (symlink_follow)
        const path_ptr = params[2].readAs(u32);
        const path_len = params[3].readAs(u32);
        const buf_ptr = params[4].readAs(u32);

        const dir_handle: std.fs.Dir = blk: {
            if (self.preopens.get(fd)) |p| break :blk p.dir;
            if (self.files.get(fd)) |e| {
                if (e.kind == .directory) break :blk e.handle.directory;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const path_bytes = try ctx.readBytes(path_ptr, path_len);
        const path = std.mem.sliceTo(path_bytes, 0);

        const stat = dir_handle.statFile(path) catch |err| switch (err) {
            error.FileNotFound => {
                types.writeErrno(results, .noent);
                return;
            },
            else => {
                types.writeErrno(results, .io);
                return;
            },
        };

        const result = types.Filestat{
            .dev = 0,
            .ino = wasiInode(stat.inode),
            .filetype = switch (stat.kind) {
                .file => .regular_file,
                .directory => .directory,
                .sym_link => .symbolic_link,
                else => .unknown,
            },
            .nlink = 1,
            .size = stat.size,
            .atim = @intCast(stat.atime),
            .mtim = @intCast(stat.mtime),
            .ctim = @intCast(stat.ctime),
        };

        try ctx.writeBytes(buf_ptr, std.mem.asBytes(&result));
        types.writeErrno(results, .success);
    }

    /// path_filestat_set_times: Set timestamps of a path
    /// params: fd(i32), flags(i32), path_ptr(i32), path_len(i32), atim(i64), mtim(i64), fst_flags(i32)
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

        // Timestamp setting is not supported portably
        types.writeErrno(results, .nosys);
    }

    /// path_link: Create a hard link
    /// params: old_fd(i32), old_flags(i32), old_path_ptr(i32), old_path_len(i32),
    ///         new_fd(i32), new_path_ptr(i32), new_path_len(i32)
    pub fn pathLink(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const old_fd = params[0].readAs(u32);
        _ = params[1]; // old_flags
        const old_path_ptr = params[2].readAs(u32);
        const old_path_len = params[3].readAs(u32);
        const new_fd = params[4].readAs(u32);
        const new_path_ptr = params[5].readAs(u32);
        const new_path_len = params[6].readAs(u32);

        const old_dir: std.fs.Dir = blk: {
            if (self.preopens.get(old_fd)) |p| break :blk p.dir;
            if (self.files.get(old_fd)) |e| {
                if (e.kind == .directory) break :blk e.handle.directory;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const new_dir: std.fs.Dir = blk: {
            if (self.preopens.get(new_fd)) |p| break :blk p.dir;
            if (self.files.get(new_fd)) |e| {
                if (e.kind == .directory) break :blk e.handle.directory;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const old_path_bytes = try ctx.readBytes(old_path_ptr, old_path_len);
        const old_path = std.mem.sliceTo(old_path_bytes, 0);
        const new_path_bytes = try ctx.readBytes(new_path_ptr, new_path_len);
        const new_path = std.mem.sliceTo(new_path_bytes, 0);

        old_dir.symLink(old_path, new_path, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {
                types.writeErrno(results, .exist);
                return;
            },
            error.FileNotFound => {
                types.writeErrno(results, .noent);
                return;
            },
            else => {
                // Hard links not portably available; fallback to nosys
                types.writeErrno(results, .nosys);
                return;
            },
        };
        _ = new_dir;

        types.writeErrno(results, .success);
    }

    /// path_readlink: Read a symbolic link
    /// params: fd(i32), path_ptr(i32), path_len(i32), buf_ptr(i32), buf_len(i32), bufused_ptr(i32)
    pub fn pathReadlink(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const path_ptr = params[1].readAs(u32);
        const path_len = params[2].readAs(u32);
        const buf_ptr = params[3].readAs(u32);
        const buf_len = params[4].readAs(u32);
        const bufused_ptr = params[5].readAs(u32);

        const dir_handle: std.fs.Dir = blk: {
            if (self.preopens.get(fd)) |p| break :blk p.dir;
            if (self.files.get(fd)) |e| {
                if (e.kind == .directory) break :blk e.handle.directory;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const path_bytes = try ctx.readBytes(path_ptr, path_len);
        const path = std.mem.sliceTo(path_bytes, 0);

        const guest_mem = ctx.memory() orelse {
            types.writeErrno(results, .fault);
            return;
        };

        if (buf_ptr >= guest_mem.len) {
            types.writeErrno(results, .fault);
            return;
        }

        const available = @min(buf_len, @as(u32, @intCast(guest_mem.len - buf_ptr)));
        var buf: [std.fs.max_path_bytes]u8 = undefined;

        const link_target = dir_handle.readLink(path, &buf) catch |err| switch (err) {
            error.FileNotFound => {
                types.writeErrno(results, .noent);
                return;
            },
            else => {
                types.writeErrno(results, .io);
                return;
            },
        };

        const copy_len = @min(@as(u32, @intCast(link_target.len)), available);
        @memcpy(guest_mem[buf_ptr .. buf_ptr + copy_len], link_target[0..copy_len]);
        try ctx.writeValue(bufused_ptr, copy_len);
        types.writeErrno(results, .success);
    }

    /// path_remove_directory: Remove a directory
    /// params: fd(i32), path_ptr(i32), path_len(i32)
    pub fn pathRemoveDirectory(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const path_ptr = params[1].readAs(u32);
        const path_len = params[2].readAs(u32);

        const dir_handle: std.fs.Dir = blk: {
            if (self.preopens.get(fd)) |p| break :blk p.dir;
            if (self.files.get(fd)) |e| {
                if (e.kind == .directory) break :blk e.handle.directory;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const path_bytes = try ctx.readBytes(path_ptr, path_len);
        const path = std.mem.sliceTo(path_bytes, 0);

        dir_handle.deleteDir(path) catch |err| switch (err) {
            error.FileNotFound => {
                types.writeErrno(results, .noent);
                return;
            },
            error.DirNotEmpty => {
                types.writeErrno(results, .inout);
                return;
            },
            else => {
                types.writeErrno(results, .io);
                return;
            },
        };

        types.writeErrno(results, .success);
    }

    /// path_rename: Rename a file or directory
    /// params: fd(i32), old_path_ptr(i32), old_path_len(i32),
    ///         new_fd(i32), new_path_ptr(i32), new_path_len(i32)
    pub fn pathRename(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const old_fd = params[0].readAs(u32);
        const old_path_ptr = params[1].readAs(u32);
        const old_path_len = params[2].readAs(u32);
        const new_fd = params[3].readAs(u32);
        const new_path_ptr = params[4].readAs(u32);
        const new_path_len = params[5].readAs(u32);

        const old_dir: std.fs.Dir = blk: {
            if (self.preopens.get(old_fd)) |p| break :blk p.dir;
            if (self.files.get(old_fd)) |e| {
                if (e.kind == .directory) break :blk e.handle.directory;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const new_dir: std.fs.Dir = blk: {
            if (self.preopens.get(new_fd)) |p| break :blk p.dir;
            if (self.files.get(new_fd)) |e| {
                if (e.kind == .directory) break :blk e.handle.directory;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const old_path_bytes = try ctx.readBytes(old_path_ptr, old_path_len);
        const old_path = std.mem.sliceTo(old_path_bytes, 0);
        const new_path_bytes = try ctx.readBytes(new_path_ptr, new_path_len);
        const new_path = std.mem.sliceTo(new_path_bytes, 0);

        std.fs.rename(old_dir, old_path, new_dir, new_path) catch |err| switch (err) {
            error.FileNotFound => {
                types.writeErrno(results, .noent);
                return;
            },
            else => {
                types.writeErrno(results, .io);
                return;
            },
        };

        types.writeErrno(results, .success);
    }

    /// path_symlink: Create a symbolic link
    /// params: old_path_ptr(i32), old_path_len(i32), fd(i32), new_path_ptr(i32), new_path_len(i32)
    pub fn pathSymlink(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const old_path_ptr = params[0].readAs(u32);
        const old_path_len = params[1].readAs(u32);
        const fd = params[2].readAs(u32);
        const new_path_ptr = params[3].readAs(u32);
        const new_path_len = params[4].readAs(u32);

        const dir_handle: std.fs.Dir = blk: {
            if (self.preopens.get(fd)) |p| break :blk p.dir;
            if (self.files.get(fd)) |e| {
                if (e.kind == .directory) break :blk e.handle.directory;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const old_path_bytes = try ctx.readBytes(old_path_ptr, old_path_len);
        const old_path = std.mem.sliceTo(old_path_bytes, 0);
        const new_path_bytes = try ctx.readBytes(new_path_ptr, new_path_len);
        const new_path = std.mem.sliceTo(new_path_bytes, 0);

        dir_handle.symLink(old_path, new_path, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {
                types.writeErrno(results, .exist);
                return;
            },
            error.FileNotFound => {
                types.writeErrno(results, .noent);
                return;
            },
            else => {
                types.writeErrno(results, .io);
                return;
            },
        };

        types.writeErrno(results, .success);
    }

    /// path_unlink_file: Remove a file
    /// params: fd(i32), path_ptr(i32), path_len(i32)
    pub fn pathUnlinkFile(self: *Self, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
        const fd = params[0].readAs(u32);
        const path_ptr = params[1].readAs(u32);
        const path_len = params[2].readAs(u32);

        const dir_handle: std.fs.Dir = blk: {
            if (self.preopens.get(fd)) |p| break :blk p.dir;
            if (self.files.get(fd)) |e| {
                if (e.kind == .directory) break :blk e.handle.directory;
            }
            types.writeErrno(results, .badf);
            return;
        };

        const path_bytes = try ctx.readBytes(path_ptr, path_len);
        const path = std.mem.sliceTo(path_bytes, 0);

        dir_handle.deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => {
                types.writeErrno(results, .noent);
                return;
            },
            error.IsDir => {
                types.writeErrno(results, .isdir);
                return;
            },
            else => {
                types.writeErrno(results, .io);
                return;
            },
        };

        types.writeErrno(results, .success);
    }
};

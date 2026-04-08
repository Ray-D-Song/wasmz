const std = @import("std");
const core = @import("core");
const wasmz = @import("wasmz");
const types = @import("./types.zig");

const Allocator = std.mem.Allocator;
const RawVal = core.RawVal;
const HostContext = wasmz.HostContext;

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
                        .ino = file_stat.inode,
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
                        .ino = dir_stat.inode,
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
};

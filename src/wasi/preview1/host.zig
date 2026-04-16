const std = @import("std");
const core = @import("core");
const wasmz = @import("wasmz");
const types = @import("./types.zig");
const fd_io = @import("./fd_io.zig");
const clock = @import("./clock.zig");
const env_args = @import("./env_args.zig");

const Allocator = std.mem.Allocator;
const RawVal = core.RawVal;
const ValType = core.ValType;
const Linker = wasmz.Linker;
const HostContext = wasmz.HostContext;
const HostFunc = wasmz.HostFunc;

pub const FdIO = fd_io.FdIO;
pub const Clock = clock.Clock;
pub const EnvArgs = env_args.EnvArgs;
pub const EnvVar = env_args.EnvVar;
pub const Output = fd_io.Output;
pub const ClockSource = clock.ClockSource;

const WasiDiagOp = enum {
    args_sizes_get,
    args_get,
    environ_sizes_get,
    environ_get,
    clock_time_get,
    fd_fdstat_get,
    fd_prestat_get,
    fd_prestat_dir_name,
    fd_read,
    fd_seek,
    fd_write,
    path_open,
    poll_oneoff,
    proc_exit,
};

const WasiDiag = struct {
    enabled: bool = false,
    args_sizes_get_count: u64 = 0,
    args_sizes_get_ns: u64 = 0,
    args_get_count: u64 = 0,
    args_get_ns: u64 = 0,
    environ_sizes_get_count: u64 = 0,
    environ_sizes_get_ns: u64 = 0,
    environ_get_count: u64 = 0,
    environ_get_ns: u64 = 0,
    clock_time_get_count: u64 = 0,
    clock_time_get_ns: u64 = 0,
    fd_fdstat_get_count: u64 = 0,
    fd_fdstat_get_ns: u64 = 0,
    fd_prestat_get_count: u64 = 0,
    fd_prestat_get_ns: u64 = 0,
    fd_prestat_dir_name_count: u64 = 0,
    fd_prestat_dir_name_ns: u64 = 0,
    fd_read_count: u64 = 0,
    fd_read_ns: u64 = 0,
    fd_seek_count: u64 = 0,
    fd_seek_ns: u64 = 0,
    fd_write_count: u64 = 0,
    fd_write_ns: u64 = 0,
    path_open_count: u64 = 0,
    path_open_ns: u64 = 0,
    poll_oneoff_count: u64 = 0,
    poll_oneoff_ns: u64 = 0,
    proc_exit_count: u64 = 0,
    proc_exit_ns: u64 = 0,

    fn record(self: *WasiDiag, op: WasiDiagOp, delta_ns: i128) void {
        if (!self.enabled) return;
        const ns: u64 = if (delta_ns <= 0) 0 else @intCast(delta_ns);
        switch (op) {
            .args_sizes_get => {
                self.args_sizes_get_count += 1;
                self.args_sizes_get_ns += ns;
            },
            .args_get => {
                self.args_get_count += 1;
                self.args_get_ns += ns;
            },
            .environ_sizes_get => {
                self.environ_sizes_get_count += 1;
                self.environ_sizes_get_ns += ns;
            },
            .environ_get => {
                self.environ_get_count += 1;
                self.environ_get_ns += ns;
            },
            .clock_time_get => {
                self.clock_time_get_count += 1;
                self.clock_time_get_ns += ns;
            },
            .fd_fdstat_get => {
                self.fd_fdstat_get_count += 1;
                self.fd_fdstat_get_ns += ns;
            },
            .fd_prestat_get => {
                self.fd_prestat_get_count += 1;
                self.fd_prestat_get_ns += ns;
            },
            .fd_prestat_dir_name => {
                self.fd_prestat_dir_name_count += 1;
                self.fd_prestat_dir_name_ns += ns;
            },
            .fd_read => {
                self.fd_read_count += 1;
                self.fd_read_ns += ns;
            },
            .fd_seek => {
                self.fd_seek_count += 1;
                self.fd_seek_ns += ns;
            },
            .fd_write => {
                self.fd_write_count += 1;
                self.fd_write_ns += ns;
            },
            .path_open => {
                self.path_open_count += 1;
                self.path_open_ns += ns;
            },
            .poll_oneoff => {
                self.poll_oneoff_count += 1;
                self.poll_oneoff_ns += ns;
            },
            .proc_exit => {
                self.proc_exit_count += 1;
                self.proc_exit_ns += ns;
            },
        }
    }

    fn print(self: *const WasiDiag) void {
        if (!self.enabled) return;
        std.debug.print(
            \\[wasi-diag] wasmz summary
            \\[wasi-diag]   args_sizes_get      count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   args_get            count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   environ_sizes_get   count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   environ_get         count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   clock_time_get      count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   fd_fdstat_get       count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   fd_prestat_get      count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   fd_prestat_dir_name count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   fd_read             count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   fd_seek             count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   fd_write            count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   path_open           count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   poll_oneoff         count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   proc_exit           count={d:>4}  total={d:8.3} ms
            \\
        , .{
            self.args_sizes_get_count, @as(f64, @floatFromInt(self.args_sizes_get_ns)) / 1_000_000.0,
            self.args_get_count, @as(f64, @floatFromInt(self.args_get_ns)) / 1_000_000.0,
            self.environ_sizes_get_count, @as(f64, @floatFromInt(self.environ_sizes_get_ns)) / 1_000_000.0,
            self.environ_get_count, @as(f64, @floatFromInt(self.environ_get_ns)) / 1_000_000.0,
            self.clock_time_get_count, @as(f64, @floatFromInt(self.clock_time_get_ns)) / 1_000_000.0,
            self.fd_fdstat_get_count, @as(f64, @floatFromInt(self.fd_fdstat_get_ns)) / 1_000_000.0,
            self.fd_prestat_get_count, @as(f64, @floatFromInt(self.fd_prestat_get_ns)) / 1_000_000.0,
            self.fd_prestat_dir_name_count, @as(f64, @floatFromInt(self.fd_prestat_dir_name_ns)) / 1_000_000.0,
            self.fd_read_count, @as(f64, @floatFromInt(self.fd_read_ns)) / 1_000_000.0,
            self.fd_seek_count, @as(f64, @floatFromInt(self.fd_seek_ns)) / 1_000_000.0,
            self.fd_write_count, @as(f64, @floatFromInt(self.fd_write_ns)) / 1_000_000.0,
            self.path_open_count, @as(f64, @floatFromInt(self.path_open_ns)) / 1_000_000.0,
            self.poll_oneoff_count, @as(f64, @floatFromInt(self.poll_oneoff_ns)) / 1_000_000.0,
            self.proc_exit_count, @as(f64, @floatFromInt(self.proc_exit_ns)) / 1_000_000.0,
        });
    }
};

fn envFlag(allocator: Allocator, name: []const u8) bool {
    const value = std.process.getEnvVarOwned(allocator, name) catch return false;
    allocator.free(value);
    return true;
}

pub const Host = struct {
    allocator: Allocator,
    /// Lazily initialized on first fd_* or path_* call.
    fd_io: ?*FdIO = null,
    /// Lazily initialized on first clock_* call.
    clock: ?*Clock = null,
    /// Lazily initialized on first args_* / environ_* call.
    env_args: ?*EnvArgs = null,
    /// Optional callback invoked just before process exit.
    /// Signature: fn(exit_code: u32, data: ?*anyopaque) void
    on_exit: ?*const fn (u32, ?*anyopaque) void = null,
    on_exit_data: ?*anyopaque = null,
    diag: WasiDiag = .{},

    pub fn init(allocator: Allocator) Host {
        return .{
            .allocator = allocator,
            .diag = .{ .enabled = envFlag(allocator, "WASMZ_WASI_DIAG") },
        };
    }

    pub fn deinit(self: *Host) void {
        self.diag.print();
        if (self.fd_io) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        if (self.env_args) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        if (self.clock) |p| {
            self.allocator.destroy(p);
        }
        self.* = undefined;
    }

    // ── Lazy accessor helpers ─────────────────────────────────────────────

    /// Returns a pointer to the FdIO subsystem, initializing it on first access.
    fn getFdIO(self: *Host) *FdIO {
        if (self.fd_io == null) {
            const p = self.allocator.create(FdIO) catch @panic("OOM");
            p.* = FdIO.init(self.allocator);
            self.fd_io = p;
        }
        return self.fd_io.?;
    }

    /// Returns a pointer to the Clock subsystem, initializing it on first access.
    fn getClock(self: *Host) *Clock {
        if (self.clock == null) {
            const p = self.allocator.create(Clock) catch @panic("OOM");
            p.* = Clock.init();
            self.clock = p;
        }
        return self.clock.?;
    }

    /// Returns a pointer to the EnvArgs subsystem, initializing it on first access.
    fn getEnvArgs(self: *Host) *EnvArgs {
        if (self.env_args == null) {
            const p = self.allocator.create(EnvArgs) catch @panic("OOM");
            p.* = EnvArgs.init(self.allocator);
            self.env_args = p;
        }
        return self.env_args.?;
    }

    // ── Public configuration API ──────────────────────────────────────────

    pub fn setArgs(self: *Host, args: []const []const u8) Allocator.Error!void {
        try self.getEnvArgs().setArgs(args);
    }

    pub fn setEnv(self: *Host, env: []const EnvVar) Allocator.Error!void {
        try self.getEnvArgs().setEnv(env);
    }

    pub fn setStdout(self: *Host, output: Output) void {
        self.getFdIO().setStdout(output);
    }

    pub fn setStderr(self: *Host, output: Output) void {
        self.getFdIO().setStderr(output);
    }

    pub fn setRealtimeClock(self: *Host, source: ClockSource) void {
        self.getClock().setRealtime(source);
    }

    pub fn setMonotonicClock(self: *Host, source: ClockSource) void {
        self.getClock().setMonotonic(source);
    }

    /// Register a callback that will be invoked (with the exit code) just
    /// before proc_exit terminates the process.  Use this to flush stats or
    /// perform other cleanup that must survive a WASI proc_exit call.
    pub fn setOnExit(self: *Host, cb: *const fn (u32, ?*anyopaque) void, data: ?*anyopaque) void {
        self.on_exit = cb;
        self.on_exit_data = data;
    }

    pub fn addPreopen(self: *Host, path: []const u8) !types.Fd {
        return self.getFdIO().addPreopen(path);
    }

    pub fn addToLinker(self: *Host, linker: *Linker, allocator: Allocator) Allocator.Error!void {
        const specs = .{
            .{ "args_sizes_get", args_sizes_get, &[_]ValType{ .I32, .I32 } },
            .{ "args_get", args_get, &[_]ValType{ .I32, .I32 } },
            .{ "environ_sizes_get", environ_sizes_get, &[_]ValType{ .I32, .I32 } },
            .{ "environ_get", environ_get, &[_]ValType{ .I32, .I32 } },
            .{ "clock_res_get", clock_res_get, &[_]ValType{ .I32, .I32 } },
            .{ "clock_time_get", clock_time_get, &[_]ValType{ .I32, .I64, .I32 } },
            .{ "fd_advise", fd_advise, &[_]ValType{ .I32, .I64, .I64, .I32 } },
            .{ "fd_allocate", fd_allocate, &[_]ValType{ .I32, .I64, .I64 } },
            .{ "fd_close", fd_close, &[_]ValType{.I32} },
            .{ "fd_datasync", fd_datasync, &[_]ValType{.I32} },
            .{ "fd_fdstat_get", fd_fdstat_get, &[_]ValType{ .I32, .I32 } },
            .{ "fd_fdstat_set_flags", fd_fdstat_set_flags, &[_]ValType{ .I32, .I32 } },
            .{ "fd_fdstat_set_rights", fd_fdstat_set_rights, &[_]ValType{ .I32, .I64, .I64 } },
            .{ "fd_filestat_get", fd_filestat_get, &[_]ValType{ .I32, .I32 } },
            .{ "fd_filestat_set_size", fd_filestat_set_size, &[_]ValType{ .I32, .I64 } },
            .{ "fd_filestat_set_times", fd_filestat_set_times, &[_]ValType{ .I32, .I64, .I64, .I32 } },
            .{ "fd_pread", fd_pread, &[_]ValType{ .I32, .I32, .I32, .I64, .I32 } },
            .{ "fd_prestat_get", fd_prestat_get, &[_]ValType{ .I32, .I32 } },
            .{ "fd_prestat_dir_name", fd_prestat_dir_name, &[_]ValType{ .I32, .I32, .I32 } },
            .{ "fd_pwrite", fd_pwrite, &[_]ValType{ .I32, .I32, .I32, .I64, .I32 } },
            .{ "fd_read", fd_read, &[_]ValType{ .I32, .I32, .I32, .I32 } },
            .{ "fd_readdir", fd_readdir, &[_]ValType{ .I32, .I32, .I32, .I64, .I32 } },
            .{ "fd_renumber", fd_renumber, &[_]ValType{ .I32, .I32 } },
            .{ "fd_seek", fd_seek, &[_]ValType{ .I32, .I64, .I32, .I32 } },
            .{ "fd_sync", fd_sync, &[_]ValType{.I32} },
            .{ "fd_tell", fd_tell, &[_]ValType{ .I32, .I32 } },
            .{ "fd_write", fd_write, &[_]ValType{ .I32, .I32, .I32, .I32 } },
            .{ "path_create_directory", path_create_directory, &[_]ValType{ .I32, .I32, .I32 } },
            .{ "path_filestat_get", path_filestat_get, &[_]ValType{ .I32, .I32, .I32, .I32, .I32 } },
            .{ "path_filestat_set_times", path_filestat_set_times, &[_]ValType{ .I32, .I32, .I32, .I32, .I64, .I64, .I32 } },
            .{ "path_link", path_link, &[_]ValType{ .I32, .I32, .I32, .I32, .I32, .I32, .I32 } },
            .{ "path_open", path_open, &[_]ValType{ .I32, .I32, .I32, .I32, .I32, .I64, .I64, .I32, .I32 } },
            .{ "path_readlink", path_readlink, &[_]ValType{ .I32, .I32, .I32, .I32, .I32, .I32 } },
            .{ "path_remove_directory", path_remove_directory, &[_]ValType{ .I32, .I32, .I32 } },
            .{ "path_rename", path_rename, &[_]ValType{ .I32, .I32, .I32, .I32, .I32, .I32 } },
            .{ "path_symlink", path_symlink, &[_]ValType{ .I32, .I32, .I32, .I32, .I32 } },
            .{ "path_unlink_file", path_unlink_file, &[_]ValType{ .I32, .I32, .I32 } },
            .{ "poll_oneoff", poll_oneoff, &[_]ValType{ .I32, .I32, .I32, .I32 } },
            .{ "proc_exit", proc_exit, &[_]ValType{.I32}, &[_]ValType{} },
            .{ "proc_raise", proc_raise, &[_]ValType{.I32} },
            .{ "random_get", random_get, &[_]ValType{ .I32, .I32 } },
            .{ "sched_yield", sched_yield, &[_]ValType{}, &[_]ValType{.I32} },
            .{ "sock_accept", sock_accept, &[_]ValType{ .I32, .I32, .I32 } },
            .{ "sock_recv", sock_recv, &[_]ValType{ .I32, .I32, .I32, .I32, .I32, .I32 } },
            .{ "sock_send", sock_send, &[_]ValType{ .I32, .I32, .I32, .I32, .I32 } },
            .{ "sock_shutdown", sock_shutdown, &[_]ValType{ .I32, .I32 } },
        };

        const default_result_types = &[_]ValType{.I32};

        inline for (specs) |spec| {
            const result_types: []const ValType = if (@typeInfo(@TypeOf(spec)).@"struct".fields.len == 4) spec[3] else default_result_types;
            try linker.define(allocator, types.module_name, spec[0], HostFunc.init(
                self,
                spec[1],
                spec[2],
                result_types,
            ));
        }
    }
};

fn args_sizes_get(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    const t0 = if (host.diag.enabled) std.time.nanoTimestamp() else 0;
    defer host.diag.record(.args_sizes_get, std.time.nanoTimestamp() - t0);
    return host.getEnvArgs().argsSizesGet(ctx, params, results);
}

fn args_get(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    const t0 = if (host.diag.enabled) std.time.nanoTimestamp() else 0;
    defer host.diag.record(.args_get, std.time.nanoTimestamp() - t0);
    return host.getEnvArgs().argsGet(ctx, params, results);
}

fn environ_sizes_get(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    const t0 = if (host.diag.enabled) std.time.nanoTimestamp() else 0;
    defer host.diag.record(.environ_sizes_get, std.time.nanoTimestamp() - t0);
    return host.getEnvArgs().environSizesGet(ctx, params, results);
}

fn environ_get(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    const t0 = if (host.diag.enabled) std.time.nanoTimestamp() else 0;
    defer host.diag.record(.environ_get, std.time.nanoTimestamp() - t0);
    return host.getEnvArgs().environGet(ctx, params, results);
}

fn clock_res_get(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getClock().clockResGet(ctx, params, results);
}

fn clock_time_get(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    const t0 = if (host.diag.enabled) std.time.nanoTimestamp() else 0;
    defer host.diag.record(.clock_time_get, std.time.nanoTimestamp() - t0);
    return host.getClock().clockTimeGet(ctx, params, results);
}

fn fd_write(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    const t0 = if (host.diag.enabled) std.time.nanoTimestamp() else 0;
    defer host.diag.record(.fd_write, std.time.nanoTimestamp() - t0);
    return host.getFdIO().fdWrite(ctx, params, results);
}

fn fd_seek(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    const t0 = if (host.diag.enabled) std.time.nanoTimestamp() else 0;
    defer host.diag.record(.fd_seek, std.time.nanoTimestamp() - t0);
    return host.getFdIO().fdSeek(ctx, params, results);
}

fn fd_filestat_get(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().fdFilestatGet(ctx, params, results);
}

fn fd_read(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    const t0 = if (host.diag.enabled) std.time.nanoTimestamp() else 0;
    defer host.diag.record(.fd_read, std.time.nanoTimestamp() - t0);
    return host.getFdIO().fdRead(ctx, params, results);
}

fn fd_pwrite(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().fdPwrite(ctx, params, results);
}

fn fd_pread(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().fdPread(ctx, params, results);
}

fn path_open(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    const t0 = if (host.diag.enabled) std.time.nanoTimestamp() else 0;
    defer host.diag.record(.path_open, std.time.nanoTimestamp() - t0);
    return host.getFdIO().pathOpen(ctx, params, results);
}

fn fd_close(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().fdClose(ctx, params, results);
}

fn fd_fdstat_get(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    const t0 = if (host.diag.enabled) std.time.nanoTimestamp() else 0;
    defer host.diag.record(.fd_fdstat_get, std.time.nanoTimestamp() - t0);
    return host.getFdIO().fdFdstatGet(ctx, params, results);
}

fn fd_prestat_get(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    const t0 = if (host.diag.enabled) std.time.nanoTimestamp() else 0;
    defer host.diag.record(.fd_prestat_get, std.time.nanoTimestamp() - t0);
    return host.getFdIO().fdPrestatGet(ctx, params, results);
}

fn fd_prestat_dir_name(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    const t0 = if (host.diag.enabled) std.time.nanoTimestamp() else 0;
    defer host.diag.record(.fd_prestat_dir_name, std.time.nanoTimestamp() - t0);
    return host.getFdIO().fdPrestatDirName(ctx, params, results);
}

fn fd_advise(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().fdAdvise(ctx, params, results);
}

fn fd_allocate(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().fdAllocate(ctx, params, results);
}

fn fd_datasync(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().fdDatasync(ctx, params, results);
}

fn fd_fdstat_set_flags(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().fdFdstatSetFlags(ctx, params, results);
}

fn fd_fdstat_set_rights(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().fdFdstatSetRights(ctx, params, results);
}

fn fd_filestat_set_size(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().fdFilestatSetSize(ctx, params, results);
}

fn fd_filestat_set_times(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().fdFilestatSetTimes(ctx, params, results);
}

fn fd_readdir(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().fdReaddir(ctx, params, results);
}

fn fd_renumber(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().fdRenumber(ctx, params, results);
}

fn fd_sync(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().fdSync(ctx, params, results);
}

fn fd_tell(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().fdTell(ctx, params, results);
}

fn path_create_directory(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().pathCreateDirectory(ctx, params, results);
}

fn path_filestat_get(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().pathFilestatGet(ctx, params, results);
}

fn path_filestat_set_times(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().pathFilestatSetTimes(ctx, params, results);
}

fn path_link(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().pathLink(ctx, params, results);
}

fn path_readlink(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().pathReadlink(ctx, params, results);
}

fn path_remove_directory(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().pathRemoveDirectory(ctx, params, results);
}

fn path_rename(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().pathRename(ctx, params, results);
}

fn path_symlink(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().pathSymlink(ctx, params, results);
}

fn path_unlink_file(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.getFdIO().pathUnlinkFile(ctx, params, results);
}

/// sock_accept: stub — sockets not supported
fn sock_accept(_: ?*anyopaque, _: *HostContext, _: []const RawVal, results: []RawVal) wasmz.HostError!void {
    types.writeErrno(results, .nosys);
}

/// sock_recv: stub — sockets not supported
fn sock_recv(_: ?*anyopaque, _: *HostContext, _: []const RawVal, results: []RawVal) wasmz.HostError!void {
    types.writeErrno(results, .nosys);
}

/// sock_send: stub — sockets not supported
fn sock_send(_: ?*anyopaque, _: *HostContext, _: []const RawVal, results: []RawVal) wasmz.HostError!void {
    types.writeErrno(results, .nosys);
}

/// sock_shutdown: stub — sockets not supported
fn sock_shutdown(_: ?*anyopaque, _: *HostContext, _: []const RawVal, results: []RawVal) wasmz.HostError!void {
    types.writeErrno(results, .nosys);
}

fn random_get(_: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const buf_ptr: u32 = @bitCast(params[0].readAs(i32));
    const buf_len: u32 = @bitCast(params[1].readAs(i32));

    const mem = ctx.memory() orelse {
        // EFAULT — no memory available
        results[0] = RawVal.from(@as(i32, 21));
        return;
    };

    if (buf_ptr + buf_len > mem.len) {
        // EFAULT — out of bounds
        results[0] = RawVal.from(@as(i32, 21));
        return;
    }

    const buf = mem[buf_ptr .. buf_ptr + buf_len];
    std.crypto.random.bytes(buf);
    results[0] = RawVal.from(@as(i32, 0)); // ESUCCESS
}

/// proc_exit: Terminate the process
/// params: rval(i32)
fn proc_exit(host_data: ?*anyopaque, _: *HostContext, params: []const RawVal, _: []RawVal) wasmz.HostError!void {
    const rval = params[0].readAs(i32);
    const code: u32 = @bitCast(rval);
    if (host_data) |data| {
        const host: *Host = @ptrCast(@alignCast(data));
        host.diag.record(.proc_exit, 0);
        host.diag.print();
        if (host.on_exit) |cb| cb(code, host.on_exit_data);
    }
    std.process.exit(@intCast(code));
}

/// proc_raise: Send a signal to the process
/// params: sig(i32)
fn proc_raise(_: ?*anyopaque, _: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    _ = params[0]; // sig — not easily portable; treat as nosys
    types.writeErrno(results, .nosys);
}

/// sched_yield: Yield the CPU
fn sched_yield(_: ?*anyopaque, _: *HostContext, _: []const RawVal, results: []RawVal) wasmz.HostError!void {
    // No-op on most platforms; return success
    types.writeErrno(results, .success);
}

/// poll_oneoff: Concurrently poll for the occurrence of a set of events
/// params: in_ptr(i32), out_ptr(i32), nsubscriptions(i32), nevents_ptr(i32)
fn poll_oneoff(_: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(ctx.host_data_ptr.?));
    const t0 = if (host.diag.enabled) std.time.nanoTimestamp() else 0;
    defer host.diag.record(.poll_oneoff, std.time.nanoTimestamp() - t0);
    const in_ptr = params[0].readAs(u32);
    const out_ptr = params[1].readAs(u32);
    const nsubscriptions = params[2].readAs(u32);
    const nevents_ptr = params[3].readAs(u32);

    if (nsubscriptions == 0) {
        types.writeErrno(results, .inval);
        return;
    }

    const subscriptions = try ctx.readSlice(in_ptr, nsubscriptions, types.Subscription);
    const guest_mem = ctx.memory() orelse {
        types.writeErrno(results, .fault);
        return;
    };

    const event_size: u32 = @intCast(@sizeOf(types.Event));
    var nevents: u32 = 0;

    for (subscriptions) |sub| {
        const event = types.Event{
            .userdata = sub.userdata,
            .error_val = 0,
            .type = sub.u.tag,
            .fd_readwrite = .{ .nbytes = 0, .flags = 0 },
        };

        const out_offset = out_ptr + nevents * event_size;
        if (out_offset + event_size > guest_mem.len) break;

        @memcpy(guest_mem[out_offset .. out_offset + event_size], std.mem.asBytes(&event));
        nevents += 1;
    }

    try ctx.writeValue(nevents_ptr, nevents);
    types.writeErrno(results, .success);
}

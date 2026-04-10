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

pub const Host = struct {
    allocator: Allocator,
    fd_io: *FdIO,
    clock: *Clock,
    env_args: *EnvArgs,

    pub fn init(allocator: Allocator) Host {
        const fd_io_ptr = allocator.create(FdIO) catch @panic("OOM");
        fd_io_ptr.* = FdIO.init(allocator);

        const clock_ptr = allocator.create(Clock) catch @panic("OOM");
        clock_ptr.* = Clock.init();

        const env_args_ptr = allocator.create(EnvArgs) catch @panic("OOM");
        env_args_ptr.* = EnvArgs.init(allocator);

        return .{
            .allocator = allocator,
            .fd_io = fd_io_ptr,
            .clock = clock_ptr,
            .env_args = env_args_ptr,
        };
    }

    pub fn deinit(self: *Host) void {
        self.fd_io.deinit();
        self.allocator.destroy(self.fd_io);

        self.env_args.deinit();
        self.allocator.destroy(self.env_args);

        self.allocator.destroy(self.clock);
        self.* = undefined;
    }

    pub fn setArgs(self: *Host, args: []const []const u8) Allocator.Error!void {
        try self.env_args.setArgs(args);
    }

    pub fn setEnv(self: *Host, env: []const EnvVar) Allocator.Error!void {
        try self.env_args.setEnv(env);
    }

    pub fn setStdout(self: *Host, output: Output) void {
        self.fd_io.setStdout(output);
    }

    pub fn setStderr(self: *Host, output: Output) void {
        self.fd_io.setStderr(output);
    }

    pub fn setRealtimeClock(self: *Host, source: ClockSource) void {
        self.clock.setRealtime(source);
    }

    pub fn setMonotonicClock(self: *Host, source: ClockSource) void {
        self.clock.setMonotonic(source);
    }

    pub fn addPreopen(self: *Host, path: []const u8) !types.Fd {
        return self.fd_io.addPreopen(path);
    }

    pub fn addToLinker(self: *Host, linker: *Linker, allocator: Allocator) Allocator.Error!void {
        const specs = .{
            .{ "args_sizes_get", args_sizes_get, &[_]ValType{ .I32, .I32 } },
            .{ "args_get", args_get, &[_]ValType{ .I32, .I32 } },
            .{ "environ_sizes_get", environ_sizes_get, &[_]ValType{ .I32, .I32 } },
            .{ "environ_get", environ_get, &[_]ValType{ .I32, .I32 } },
            .{ "clock_res_get", clock_res_get, &[_]ValType{ .I32, .I32 } },
            .{ "clock_time_get", clock_time_get, &[_]ValType{ .I32, .I64, .I32 } },
            .{ "fd_write", fd_write, &[_]ValType{ .I32, .I32, .I32, .I32 } },
            .{ "fd_seek", fd_seek, &[_]ValType{ .I32, .I64, .I32, .I32 } },
            .{ "fd_filestat_get", fd_filestat_get, &[_]ValType{ .I32, .I32 } },
            .{ "fd_read", fd_read, &[_]ValType{ .I32, .I32, .I32, .I32 } },
            .{ "fd_pwrite", fd_pwrite, &[_]ValType{ .I32, .I32, .I32, .I64, .I32 } },
            .{ "fd_pread", fd_pread, &[_]ValType{ .I32, .I32, .I32, .I64, .I32 } },
            .{ "path_open", path_open, &[_]ValType{ .I32, .I32, .I32, .I32, .I32, .I64, .I64, .I32, .I32 } },
            .{ "fd_close", fd_close, &[_]ValType{.I32} },
            .{ "fd_fdstat_get", fd_fdstat_get, &[_]ValType{ .I32, .I32 } },
            .{ "fd_prestat_get", fd_prestat_get, &[_]ValType{ .I32, .I32 } },
            .{ "fd_prestat_dir_name", fd_prestat_dir_name, &[_]ValType{ .I32, .I32, .I32 } },
        };

        const result_types = &[_]ValType{.I32};

        inline for (specs) |spec| {
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
    return host.env_args.argsSizesGet(ctx, params, results);
}

fn args_get(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.env_args.argsGet(ctx, params, results);
}

fn environ_sizes_get(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.env_args.environSizesGet(ctx, params, results);
}

fn environ_get(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.env_args.environGet(ctx, params, results);
}

fn clock_res_get(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.clock.clockResGet(ctx, params, results);
}

fn clock_time_get(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.clock.clockTimeGet(ctx, params, results);
}

fn fd_write(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.fd_io.fdWrite(ctx, params, results);
}

fn fd_seek(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.fd_io.fdSeek(ctx, params, results);
}

fn fd_filestat_get(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.fd_io.fdFilestatGet(ctx, params, results);
}

fn fd_read(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.fd_io.fdRead(ctx, params, results);
}

fn fd_pwrite(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.fd_io.fdPwrite(ctx, params, results);
}

fn fd_pread(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.fd_io.fdPread(ctx, params, results);
}

fn path_open(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.fd_io.pathOpen(ctx, params, results);
}

fn fd_close(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.fd_io.fdClose(ctx, params, results);
}

fn fd_fdstat_get(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.fd_io.fdFdstatGet(ctx, params, results);
}

fn fd_prestat_get(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.fd_io.fdPrestatGet(ctx, params, results);
}

fn fd_prestat_dir_name(host_data: ?*anyopaque, ctx: *HostContext, params: []const RawVal, results: []RawVal) wasmz.HostError!void {
    const host: *Host = @ptrCast(@alignCast(host_data.?));
    return host.fd_io.fdPrestatDirName(ctx, params, results);
}

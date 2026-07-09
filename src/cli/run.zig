const wasmz = @import("wasmz");
const args_mod = @import("args.zig");
const runtime_mod = @import("runtime.zig");

const std = @import("std");

const CliArgs = args_mod.CliArgs;
const Runtime = runtime_mod.Runtime;

pub const RunMode = union(enum) {
    list_exports,
    run_start,
    call_export: struct {
        name: []const u8,
        i32_args: []const []const u8,
    },
};

pub fn resolveRunMode(cli: *const CliArgs, module: *const wasmz.Module) RunMode {
    if (cli.func_name) |name| {
        return .{ .call_export = .{
            .name = name,
            .i32_args = cli.i32_args,
        } };
    }
    if (module.exports.get("_start") != null) return .run_start;
    return .list_exports;
}

pub fn dispatch(rt: *Runtime, stdout: *std.Io.Writer) void {
    const mode = resolveRunMode(rt.cli, rt.module());
    switch (mode) {
        .list_exports => rt.listExports(stdout),
        .run_start => rt.runStart(),
        .call_export => |call| rt.callExport(stdout, call.name, call.i32_args),
    }
}
/// wasmz CLI entry
///
/// Usage:
///   wasmz <file.wasm>                                        List exported functions
///   wasmz <file.wasm> <func_name> [i32_args]                 Call the specified function and print the return value
///   wasmz <file.wasm> --args "<wasm_arg...>"                 Run _start, forwarding args to the WASM module
///
/// Flags:
///   --help                Show this help message
///   --legacy-exceptions   Force the legacy exception-handling proposal (try/catch/rethrow/delegate)
///   --args <string>       Arguments to pass to the WASM module (space-separated, shell-quoted)
///   --func <name>         Name of the exported function to call (reactor/library mode)
///   --reactor             Initialize the module as a reactor (_initialize) before calling --func
///   --mem-stats           Print memory usage stats to stderr after execution
///   --mem-trace           Print RSS snapshots at each execution phase to stderr
///   --mem-limit <MB>      Memory limit in megabytes
///   --eager-compile       Compile all functions eagerly at module load time
const std = @import("std");
const builtin = @import("builtin");
const wasmz = @import("wasmz");

const cli = @import("cli/root.zig");

pub const panic = cli.errors.panic;

pub fn main(init: std.process.Init) !void {
    const allocator = if (builtin.os.tag == .wasi) std.heap.wasm_allocator else init.gpa;
    const io = init.io;
    defer wasmz.profiling.printReport();

    var stdout_buf: [8192]u8 = undefined;
    var stdout_bw = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_bw.interface;
    defer stdout_bw.interface.flush() catch {};

    const raw_args = try init.minimal.args.toSlice(init.arena.allocator());
    defer init.arena.allocator().free(raw_args);

    var parsed_args = cli.args.CliArgs.parse(allocator, raw_args) catch |err| switch (err) {
        error.MissingFilePath => {
            cli.args.CliArgs.command.printUsage();
            std.process.exit(1);
        },
        else => cli.errors.fatal("Failed to parse args: {s}", .{@errorName(err)}),
    };
    defer parsed_args.deinit(allocator);

    var rt: cli.runtime.Runtime = undefined;
    cli.runtime.Runtime.init(&rt, allocator, io, init.environ_map, &parsed_args);
    defer rt.deinit();

    cli.run.dispatch(&rt, stdout);
}
/// wasmz CLI entry
///
/// Usage:
///   wasmz <file.wasm>                          List exported functions
///   wasmz <file.wasm> <func_name> [i32_args]   Call the specified function and print the return value
///
/// Flags:
///   --legacy-exceptions   Force the legacy exception-handling proposal (try/catch/rethrow/delegate)
///
/// Current limitations:
///   - Function arguments only support i32 (parsed as decimal integers)
///   - Return values are printed as i32 (void functions do not output)
const std = @import("std");
const wasmz = @import("wasmz");
const wasi_preview1 = @import("wasi").preview1;

/// Custom panic handler: simply print the message to stderr and abort, without unwinding with DWARF.
/// This eliminates about 127 KB of DWARF parsing code from std.debug
fn simplePanic(msg: []const u8, _: ?usize) noreturn {
    const stderr = std.fs.File.stderr();
    stderr.writeAll("panic: ") catch {};
    stderr.writeAll(msg) catch {};
    stderr.writeAll("\n") catch {};
    std.process.abort();
}
pub const panic = std.debug.FullPanic(simplePanic);

const Engine = wasmz.Engine;
const Config = wasmz.Config;
const Module = wasmz.Module;
const Store = wasmz.Store;
const Instance = wasmz.Instance;
const RawVal = wasmz.RawVal;
const Linker = wasmz.Linker;
const HostFunc = wasmz.HostFunc;
const HostContext = wasmz.HostContext;
const ValType = wasmz.ValType;

const CliArgs = struct {
    file_path: []const u8,
    func_name: ?[]const u8,
    i32_args: []const []const u8,
    legacy_exceptions: bool,
    positional: []const []const u8,

    fn parse(allocator: std.mem.Allocator) !CliArgs {
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);

        var legacy_exceptions = false;
        var positional_buf: [16][]const u8 = undefined;
        var positional_count: usize = 0;
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--legacy-exceptions")) {
                legacy_exceptions = true;
            } else {
                if (positional_count >= positional_buf.len) {
                    std.debug.print("error: too many arguments\n", .{});
                    std.process.exit(1);
                }
                positional_buf[positional_count] = arg;
                positional_count += 1;
            }
        }
        const positional = allocator.dupe([]const u8, positional_buf[0..positional_count]) catch {
            std.debug.print("error: out of memory\n", .{});
            std.process.exit(1);
        };

        if (positional.len < 1) {
            return error.MissingFilePath;
        }

        const file_path = positional[0];
        if (!std.mem.endsWith(u8, file_path, ".wasm")) {
            std.debug.print("error: {s}: Unsupported file extension, expected .wasm\n", .{file_path});
            std.process.exit(1);
        }

        const func_name: ?[]const u8 = if (positional.len >= 2) positional[1] else null;
        const i32_args = if (positional.len >= 3) positional[2..] else &.{};

        return .{
            .file_path = file_path,
            .func_name = func_name,
            .i32_args = i32_args,
            .legacy_exceptions = legacy_exceptions,
            .positional = positional,
        };
    }

    fn deinit(self: *CliArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.positional);
    }
};

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize a buffered stdout writer (Zig 0.15 new I/O API)
    var out_buf: [8192]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&out_buf);
    const stdout = &bw.interface;

    run(allocator, stdout) catch |err| {
        std.debug.print("fatal: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    bw.interface.flush() catch {};
}

fn host_print_i32(_: ?*anyopaque, _: *HostContext, params: []const RawVal, _: []RawVal) wasmz.HostError!void {
    const val = params[0].readAs(i32);
    std.debug.print("host_print_i32: {d}\n", .{val});
    return;
}

fn run(allocator: std.mem.Allocator, stdout: anytype) !void {
    const cli_args = CliArgs.parse(allocator) catch |err| {
        switch (err) {
            error.MissingFilePath => {
                try stdout.writeAll(
                    \\Usage:
                    \\  wasmz [--legacy-exceptions] <file.wasm>                       List exported functions
                    \\  wasmz [--legacy-exceptions] <file.wasm> <func> [i32_arg...]   Call the specified function and print the return value
                    \\
                );
                std.process.exit(1);
            },
            else => return err,
        }
    };

    const file_path = cli_args.file_path;

    // ── Read file (max 64 MiB) ──────────────────────────────────────────────

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("error: Unable to open {s}: {s}\n", .{ file_path, @errorName(err) });
        std.process.exit(1);
    };
    defer file.close();

    const bytes = file.readToEndAlloc(allocator, 64 * 1024 * 1024) catch |err| {
        std.debug.print("error: Unable to read {s}: {s}\n", .{ file_path, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(bytes);

    // ── Compile module ──────────────────────────────────────────────────────────────

    var engine = Engine.init(allocator, Config{ .legacy_exceptions = cli_args.legacy_exceptions }) catch |err| {
        std.debug.print("error: Failed to initialize engine: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer engine.deinit();

    var module = Module.compile(engine, bytes) catch |err| {
        std.debug.print("error: Failed to compile {s}: {s}\n", .{ file_path, @errorName(err) });
        std.process.exit(1);
    };
    defer module.deinit();

    // ── Instantiate ───────────────────────────────────────────────────────────────

    var store = try Store.init(allocator, engine);
    defer store.deinit();

    var wasi_host = wasi_preview1.Host.init(allocator);
    defer wasi_host.deinit();
    try wasi_host.setArgs(cli_args.positional);

    var linker = Linker.empty;
    try wasi_host.addToLinker(&linker, allocator);
    try linker.define(allocator, "env", "host_print_i32", HostFunc.init(
        null,
        host_print_i32,
        &[_]ValType{.I32},
        &[_]ValType{},
    ));
    defer linker.deinit(allocator);

    var instance = Instance.init(&store, &module, linker) catch |err| {
        std.debug.print("error: Failed to instantiate module: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer instance.deinit();

    // ── No function name → List exports or run _start ─────────────────────────

    if (cli_args.func_name == null) {
        // If the module exports a "_start" function, call it automatically (WASI command pattern)
        if (module.exports.get("_start")) |_| {
            const result = instance.call("_start", &.{}) catch |err| {
                std.debug.print("error: Failed to call _start: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            switch (result) {
                .ok => {},
                .trap => |t| {
                    const msg = try t.allocPrint(allocator);
                    defer allocator.free(msg);
                    std.debug.print("error: trap: {s}\n", .{msg});
                    std.process.exit(1);
                },
            }
            return;
        }

        // No _start export → list all exported functions
        if (module.exports.count() == 0) {
            try stdout.writeAll("(module has no exported functions)\n");
            return;
        }
        try stdout.writeAll("Exported functions:\n");
        var iter = module.exports.iterator();
        while (iter.next()) |entry| {
            try stdout.print("  {s}\n", .{entry.key_ptr.*});
        }
        return;
    }

    // ── Parse i32 arguments and call function ───────────────────────────────────────────────

    const func_name = cli_args.func_name.?;

    var call_args = std.ArrayList(RawVal){};
    defer call_args.deinit(allocator);

    for (cli_args.i32_args) |arg| {
        const val = std.fmt.parseInt(i32, arg, 10) catch |err| {
            std.debug.print("error: Argument \"{s}\" is not a valid i32: {s}\n", .{ arg, @errorName(err) });
            std.process.exit(1);
        };
        try call_args.append(allocator, RawVal.from(val));
    }

    const result = instance.call(func_name, call_args.items) catch |err| {
        std.debug.print("error: Failed to call \"{s}\": {s}\n", .{ func_name, @errorName(err) });
        std.process.exit(1);
    };

    switch (result) {
        .ok => |val| {
            if (val) |v| try stdout.print("{d}\n", .{v.readAs(i32)});
        },
        .trap => |t| {
            const msg = try t.allocPrint(allocator);
            defer allocator.free(msg);
            std.debug.print("error: trap: {s}\n", .{msg});
            std.process.exit(1);
        },
    }
}

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
///   --mem-limit <MB>      Memory limit in megabytes
///   --eager-compile       Compile all functions eagerly at module load time
const std = @import("std");
const builtin = @import("builtin");
const wasmz = @import("wasmz");
const wasi_preview1 = @import("wasi").preview1;
const profiling = wasmz.profiling;
const arg_parse = @import("utils/arg-parse.zig");
const stats = @import("utils/stats.zig");

const Engine = wasmz.Engine;
const Config = wasmz.Config;
const Module = wasmz.Module;
const Store = wasmz.Store;
const Instance = wasmz.Instance;
const RawVal = wasmz.RawVal;
const Linker = wasmz.Linker;

pub fn main() void {
    // Debug builds use GeneralPurposeAllocator for leak/corruption detection.
    // Release builds use smp_allocator (lock-free, low-overhead) to avoid the
    // mmap-per-allocation cost of DebugAllocator (GPA alias in Zig 0.15).
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();
        defer wasmz.profiling.printReport();
        var out_buf: [8192]u8 = undefined;
        var bw = std.fs.File.stdout().writer(&out_buf);
        const stdout = &bw.interface;
        run(allocator, stdout) catch |err| {
            std.debug.print("fatal: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        bw.interface.flush() catch {};
    } else {
        const allocator = std.heap.smp_allocator;
        defer wasmz.profiling.printReport();
        var out_buf: [8192]u8 = undefined;
        var bw = std.fs.File.stdout().writer(&out_buf);
        const stdout = &bw.interface;
        run(allocator, stdout) catch |err| {
            std.debug.print("fatal: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        bw.interface.flush() catch {};
    }
}

fn run(allocator: std.mem.Allocator, stdout: anytype) !void {
    var cli_args = CliArgs.parse(allocator) catch |err| {
        switch (err) {
            error.MissingFilePath => {
                CliArgs.command.printUsage();
                std.process.exit(1);
            },
            else => return err,
        }
    };
    defer cli_args.deinit(allocator);

    const file_path = cli_args.file_path;

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err|
        fatal("Unable to open {s}: {s}", .{ file_path, @errorName(err) });
    defer file.close();

    const bytes = file.readToEndAlloc(allocator, 64 * 1024 * 1024) catch |err|
        fatal("Unable to read {s}: {s}", .{ file_path, @errorName(err) });
    defer allocator.free(bytes);

    var engine = Engine.init(allocator, Config{
        .legacy_exceptions = cli_args.legacy_exceptions,
        .mem_limit_bytes = if (cli_args.mem_limit_mb) |mb| mb * 1024 * 1024 else null,
        .eager_compile = cli_args.eager_compile,
    }) catch |err| fatal("Failed to initialize engine: {s}", .{@errorName(err)});
    defer engine.deinit();

    var arc_module = Module.compileArc(engine, bytes) catch |err|
        fatal("Failed to compile {s}: {s}", .{ file_path, @errorName(err) });
    defer if (arc_module.releaseUnwrap()) |m| {
        var mod = m;
        mod.deinit();
    };

    var store = try Store.init(allocator, engine);
    if (cli_args.mem_limit_mb != null) store.linkBudget();
    defer store.deinit();

    // Lazy WASI initialization (plan A): only allocate and register the WASI
    // host when the module actually imports wasi_snapshot_preview1 symbols.
    // For pure-compute modules with no WASI imports this avoids all FdIO /
    // Clock / EnvArgs heap allocations.
    var wasi_host: ?wasi_preview1.Host = null;
    defer if (wasi_host) |*h| h.deinit();

    var linker = Linker.empty;
    defer linker.deinit(allocator);

    if (moduleNeedsWasi(arc_module.value)) {
        wasi_host = wasi_preview1.Host.init(allocator);
        try wasi_host.?.setArgs(cli_args.wasi_args);
        if (profiling.enabled) wasi_host.?.setOnExit(stats.onExitProfiling, null);
        try wasi_host.?.addToLinker(&linker, allocator);
    }

    var instance = Instance.init(&store, arc_module.retain(), linker) catch |err| {
        wasmz.printInitError(arc_module, linker, err);
        std.process.exit(1);
    };
    if (cli_args.mem_stats) {
        var mem_stats_ctx = stats.MemStatsCtx{};
        mem_stats_ctx.store = &store;
        mem_stats_ctx.instance = &instance;
        if (wasi_host) |*h| h.setOnExit(stats.onExitMemStats, &mem_stats_ctx);
    }
    defer {
        if (cli_args.mem_stats) stats.printMemStats(&store, &instance);
        profiling.printReport();
        instance.deinit();
    }

    if (instance.runStartFunction() catch |err|
        fatal("Failed to run start function: {s}", .{@errorName(err)})) |result|
    {
        if (result == .trap) fatalTrap(result.trap, allocator, "start function trapped");
    }

    if (cli_args.reactor) {
        if (instance.initializeReactor() catch |err|
            fatal("Failed to call _initialize: {s}", .{@errorName(err)})) |res|
        {
            if (res == .trap) fatalTrap(res.trap, allocator, "_initialize trapped");
        }
    }

    if (cli_args.func_name == null) {
        if (arc_module.value.exports.get("_start")) |_| {
            const result = instance.call("_start", &.{}) catch |err|
                fatal("Failed to call _start: {s}", .{@errorName(err)});
            if (result == .trap) fatalTrap(result.trap, allocator, "trap");
            return;
        }

        if (arc_module.value.exports.count() == 0) {
            try stdout.writeAll("(module has no exported functions)\n");
            return;
        }
        try stdout.writeAll("Exported functions:\n");
        var iter = arc_module.value.exports.iterator();
        while (iter.next()) |entry| {
            try stdout.print("  {s}\n", .{entry.key_ptr.*});
        }
        return;
    }

    const func_name = cli_args.func_name.?;

    var call_args = std.ArrayList(RawVal){};
    defer call_args.deinit(allocator);

    for (cli_args.i32_args) |arg| {
        const val = std.fmt.parseInt(i32, arg, 10) catch
            fatal("Argument \"{s}\" is not a valid i32", .{arg});
        try call_args.append(allocator, RawVal.from(val));
    }

    const result = instance.call(func_name, call_args.items) catch |err|
        fatal("Failed to call \"{s}\": {s}", .{ func_name, @errorName(err) });

    switch (result) {
        .ok => |val| if (val) |v| try stdout.print("{d}\n", .{v.readAs(i32)}),
        .trap => |t| fatalTrap(t, allocator, "trap"),
    }
}

const CliArgs = struct {
    file_path: []const u8,
    func_name: ?[]const u8,
    i32_args: []const []const u8,
    legacy_exceptions: bool,
    wasi_args: []const []const u8,
    passthrough: bool,
    mem_stats: bool,
    mem_limit_mb: ?u64,
    reactor: bool,
    eager_compile: bool,
    _parsed: arg_parse.Parsed,
    _wasm_args_parsed: [][]const u8,
    _positional: []const []const u8,

    const flags = [_]arg_parse.Flag{
        arg_parse.Flag.boolFlag("help", "Show this help message"),
        arg_parse.Flag.boolFlag("legacy-exceptions", "Force legacy exception handling"),
        arg_parse.Flag.boolFlag("mem-stats", "Print memory usage stats after execution"),
        arg_parse.Flag.boolFlag("reactor", "Initialize as reactor before calling --func"),
        arg_parse.Flag.boolFlag("eager-compile", "Compile all functions eagerly"),
        arg_parse.Flag.stringFlag("args", "Arguments to pass to the WASM module"),
        arg_parse.Flag.stringFlag("func", "Name of exported function to call"),
        arg_parse.Flag.intFlag("mem-limit", "Memory limit in MB"),
    };

    const args = [_]arg_parse.Arg{
        .{ .name = "file", .help = "Path to .wasm file", .required = true },
        .{ .name = "func", .help = "Function name (optional)" },
        .{ .name = "args", .help = "Function arguments (i32 values)" },
    };

    const command = arg_parse.Command{
        .name = "wasmz",
        .help = "WebAssembly runtime CLI",
        .flags = &flags,
        .args = &args,
    };

    fn parse(allocator: std.mem.Allocator) !CliArgs {
        var parser = arg_parse.Parser.init(&command, allocator);
        var parsed = parser.parse() catch {
            std.process.exit(1);
        };

        if (parsed.getBool("help")) {
            command.printUsage();
            std.process.exit(0);
        }

        const positional = parsed.positional;
        if (positional.len < 1) {
            parsed.deinit();
            return error.MissingFilePath;
        }

        const file_path = positional[0];
        if (!std.mem.endsWith(u8, file_path, ".wasm")) {
            std.debug.print("error: {s}: Unsupported file extension, expected .wasm\n", .{file_path});
            std.process.exit(1);
        }

        const args_flag_value = parsed.getString("args");
        const passthrough = args_flag_value != null;
        const wasm_args_parsed: [][]const u8 = if (args_flag_value) |val|
            arg_parse.splitShellArgs(allocator, val) catch &.{}
        else
            try allocator.alloc([]const u8, 0);

        const wasi_args = try allocator.alloc([]const u8, 1 + wasm_args_parsed.len);
        wasi_args[0] = file_path;
        @memcpy(wasi_args[1..], wasm_args_parsed);

        const func_flag_value = parsed.getString("func");
        const func_name: ?[]const u8 = if (func_flag_value) |f|
            f
        else if (!passthrough and positional.len >= 2)
            positional[1]
        else
            null;

        const i32_args: []const []const u8 = if (!passthrough) blk: {
            if (func_flag_value != null) {
                break :blk if (positional.len >= 2) positional[1..] else &.{};
            } else {
                break :blk if (positional.len >= 3) positional[2..] else &.{};
            }
        } else &.{};

        const mem_limit_int = parsed.getInt("mem-limit");
        const mem_limit_mb: ?u64 = if (mem_limit_int) |m| @intCast(m) else null;

        return .{
            .file_path = file_path,
            .func_name = func_name,
            .i32_args = i32_args,
            .legacy_exceptions = parsed.getBool("legacy-exceptions"),
            .mem_stats = parsed.getBool("mem-stats"),
            .mem_limit_mb = mem_limit_mb,
            .reactor = parsed.getBool("reactor"),
            .eager_compile = parsed.getBool("eager-compile"),
            .wasi_args = wasi_args,
            .passthrough = passthrough,
            ._parsed = parsed,
            ._wasm_args_parsed = wasm_args_parsed,
            ._positional = positional,
        };
    }

    fn deinit(self: *CliArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.wasi_args);
        for (self._wasm_args_parsed) |tok| allocator.free(tok);
        allocator.free(self._wasm_args_parsed);
        allocator.free(self._positional);
        self._parsed.deinit();
    }
};

/// Release builds use a minimal panic handler to avoid pulling in DWARF stack-unwinding
/// code (~127 KB).  Debug/ReleaseSafe builds use the default handler for readable backtraces.
fn simplePanic(msg: []const u8, _: ?usize) noreturn {
    const stderr = std.fs.File.stderr();
    stderr.writeAll("panic: ") catch {};
    stderr.writeAll(msg) catch {};
    stderr.writeAll("\n") catch {};
    std.process.abort();
}

pub const panic = switch (builtin.mode) {
    .Debug, .ReleaseSafe => std.debug.FullPanic(std.debug.defaultPanic),
    .ReleaseFast, .ReleaseSmall => std.debug.FullPanic(simplePanic),
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn fatalTrap(trap: wasmz.Trap, allocator: std.mem.Allocator, comptime context: []const u8) noreturn {
    const msg = trap.allocPrint(allocator) catch "?";
    std.debug.print("error: {s}: {s}\n", .{ context, msg });
    std.process.exit(1);
}

/// Returns true when the compiled module imports at least one symbol from the
/// "wasi_snapshot_preview1" namespace, meaning it needs a live WASI host.
/// Used for lazy WASI initialization: modules with no WASI imports skip Host
/// allocation entirely.
fn moduleNeedsWasi(module: *const Module) bool {
    for (module.imported_funcs) |def| {
        if (std.mem.eql(u8, def.module_name, "wasi_snapshot_preview1")) return true;
    }
    return false;
}

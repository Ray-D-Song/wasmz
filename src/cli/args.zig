const std = @import("std");
const arg_parse = @import("../utils/arg-parse.zig");

pub const SMART_SIZE_THRESHOLD: u64 = 3 * 1024 * 1024;

pub const CliArgs = struct {
    file_path: []const u8,
    func_name: ?[]const u8,
    i32_args: []const []const u8,
    legacy_exceptions: bool,
    wasi_args: []const []const u8,
    passthrough: bool,
    mem_stats: bool,
    mem_trace: bool,
    mem_limit_mb: ?u64,
    reactor: bool,
    smart_compile: bool,
    eager_compile: bool,
    _parsed: arg_parse.Parsed,
    _wasm_args_parsed: [][]const u8,

    const flags = [_]arg_parse.Flag{
        arg_parse.Flag.boolFlag("help", "Show this help message"),
        arg_parse.Flag.boolFlag("legacy-exceptions", "Force legacy exception handling"),
        arg_parse.Flag.boolFlag("mem-stats", "Print memory usage stats after execution"),
        arg_parse.Flag.boolFlag("mem-trace", "Print RSS snapshots at each execution phase"),
        arg_parse.Flag.boolFlag("reactor", "Initialize as reactor before calling --func"),
        arg_parse.Flag.boolFlag("smart-compile", "Smart compile: eager < 3MB, lazy >= 3MB (default)"),
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

    pub const command = arg_parse.Command{
        .name = "wasmz",
        .help = "WebAssembly runtime CLI",
        .flags = &flags,
        .args = &args,
    };

    pub fn parse(allocator: std.mem.Allocator, raw_args: []const []const u8) !CliArgs {
        var parser = arg_parse.Parser.init(&command, allocator);
        var parsed = parser.parse(raw_args) catch {
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
            .mem_trace = parsed.getBool("mem-trace"),
            .mem_limit_mb = mem_limit_mb,
            .reactor = parsed.getBool("reactor"),
            .smart_compile = parsed.getBool("smart-compile"),
            .eager_compile = parsed.getBool("eager-compile"),
            .wasi_args = wasi_args,
            .passthrough = passthrough,
            ._parsed = parsed,
            ._wasm_args_parsed = wasm_args_parsed,
        };
    }

    pub fn deinit(self: *CliArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.wasi_args);
        for (self._wasm_args_parsed) |tok| allocator.free(tok);
        allocator.free(self._wasm_args_parsed);
        self._parsed.deinit();
    }

    pub fn eagerCompilePolicy(self: *const CliArgs, wasm_len: usize) bool {
        return if (self.smart_compile)
            wasm_len < SMART_SIZE_THRESHOLD
        else
            self.eager_compile;
    }
};
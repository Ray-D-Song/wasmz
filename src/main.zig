/// wasmz CLI entry
///
/// Usage:
///   wasmz <file.wasm>                                        List exported functions
///   wasmz <file.wasm> <func_name> [i32_args]                 Call the specified function and print the return value
///   wasmz <file.wasm> --args "<wasm_arg...>"                 Run _start, forwarding args to the WASM module
///
/// Flags:
///   --legacy-exceptions   Force the legacy exception-handling proposal (try/catch/rethrow/delegate)
///   --args <string>       Arguments to pass to the WASM module (space-separated, shell-quoted)
///   --func <name>         Name of the exported function to call (reactor/library mode)
///   --reactor             Initialize the module as a reactor (_initialize) before calling --func
const std = @import("std");
const builtin = @import("builtin");
const wasmz = @import("wasmz");
const wasi_preview1 = @import("wasi").preview1;

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
    /// argv passed to the WASI module: [file_path, wasm_args...]
    /// Populated from the value of --args "<wasm_arg...>" (shell-word-split).
    wasi_args: []const []const u8,
    /// When true, --args was provided and _start is the target.
    passthrough: bool,
    /// When true, print memory usage stats to stderr after execution.
    mem_stats: bool,
    /// Memory limit in MB, null means unlimited.
    mem_limit_mb: ?u64,
    /// When true, call _initialize before --func (reactor mode).
    reactor: bool,
    /// Kept alive so that string slices in the fields above remain valid.
    _args_alloc: [][:0]u8,
    _args_allocator: std.mem.Allocator,
    /// Storage for wasm args parsed from --args string (owned by allocator).
    _wasm_args_parsed: [][]const u8,
    /// The positional argument slice (owned by allocator).
    _positional: []const []const u8,

    /// Simple shell-word split: split `s` on whitespace, respecting
    /// single- and double-quoted spans.  Returns a slice owned by `allocator`.
    fn splitArgs(allocator: std.mem.Allocator, s: []const u8) ![][]const u8 {
        var result: std.ArrayList([]const u8) = .empty;
        errdefer result.deinit(allocator);

        var i: usize = 0;
        while (i < s.len) {
            // skip whitespace
            while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
            if (i >= s.len) break;

            var token: std.ArrayList(u8) = .empty;
            errdefer token.deinit(allocator);

            while (i < s.len and s[i] != ' ' and s[i] != '\t') {
                const ch = s[i];
                if (ch == '\'' or ch == '"') {
                    // consume everything until matching closing quote
                    const quote = ch;
                    i += 1;
                    while (i < s.len and s[i] != quote) : (i += 1) {
                        try token.append(allocator, s[i]);
                    }
                    if (i < s.len) i += 1; // skip closing quote
                } else {
                    try token.append(allocator, ch);
                    i += 1;
                }
            }

            try result.append(allocator, try token.toOwnedSlice(allocator));
        }

        return result.toOwnedSlice(allocator);
    }

    fn parse(allocator: std.mem.Allocator) !CliArgs {
        const args = try std.process.argsAlloc(allocator);

        var legacy_exceptions = false;
        var mem_stats = false;
        var mem_limit_mb: ?u64 = null;
        var args_flag_value: ?[]const u8 = null; // value of --args
        var func_flag_value: ?[]const u8 = null; // value of --func
        var reactor = false;

        // Collect wasmz-side positional args (everything that is not a known flag).
        var positional_buf: [16][]const u8 = undefined;
        var positional_count: usize = 0;

        var idx: usize = 1;
        while (idx < args.len) : (idx += 1) {
            const arg = args[idx];
            if (std.mem.eql(u8, arg, "--legacy-exceptions")) {
                legacy_exceptions = true;
            } else if (std.mem.eql(u8, arg, "--mem-stats")) {
                mem_stats = true;
            } else if (std.mem.eql(u8, arg, "--reactor")) {
                reactor = true;
            } else if (std.mem.eql(u8, arg, "--mem-limit")) {
                idx += 1;
                if (idx >= args.len) {
                    std.debug.print("error: --mem-limit requires a value (MB)\n", .{});
                    std.process.exit(1);
                }
                mem_limit_mb = std.fmt.parseInt(u64, args[idx], 10) catch {
                    std.debug.print("error: --mem-limit value must be a positive integer (MB)\n", .{});
                    std.process.exit(1);
                };
            } else if (std.mem.eql(u8, arg, "--args")) {
                idx += 1;
                if (idx >= args.len) {
                    std.debug.print("error: --args requires a value\n", .{});
                    std.process.exit(1);
                }
                args_flag_value = args[idx];
            } else if (std.mem.startsWith(u8, arg, "--args=")) {
                args_flag_value = arg["--args=".len..];
            } else if (std.mem.eql(u8, arg, "--func")) {
                idx += 1;
                if (idx >= args.len) {
                    std.debug.print("error: --func requires a function name\n", .{});
                    std.process.exit(1);
                }
                func_flag_value = args[idx];
            } else if (std.mem.startsWith(u8, arg, "--func=")) {
                func_flag_value = arg["--func=".len..];
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
            allocator.free(positional);
            std.process.argsFree(allocator, args);
            return error.MissingFilePath;
        }

        const file_path = positional[0];
        if (!std.mem.endsWith(u8, file_path, ".wasm")) {
            std.debug.print("error: {s}: Unsupported file extension, expected .wasm\n", .{file_path});
            std.process.exit(1);
        }

        // --args mode: forward split tokens to the WASM module.
        const passthrough = args_flag_value != null;
        const wasm_args_parsed: [][]const u8 = if (args_flag_value) |val|
            splitArgs(allocator, val) catch &.{}
        else
            try allocator.alloc([]const u8, 0);

        // wasi_args = [file_path] ++ wasm_args_parsed
        const wasi_args = try allocator.alloc([]const u8, 1 + wasm_args_parsed.len);
        wasi_args[0] = file_path;
        @memcpy(wasi_args[1..], wasm_args_parsed);

        // --func flag takes priority over positional func name
        const func_name: ?[]const u8 = if (func_flag_value) |f|
            f
        else if (!passthrough and positional.len >= 2)
            positional[1]
        else
            null;
        // i32_args: when --func is used, all remaining positionals (after file) are args.
        // When positional func name is used, positionals after the func name are args.
        const i32_args: []const []const u8 = if (!passthrough) blk: {
            if (func_flag_value != null) {
                // --func <name> used: positional[1..] are all i32 args (no func name in positionals)
                break :blk if (positional.len >= 2) positional[1..] else &.{};
            } else {
                // positional[0]=file, positional[1]=func, positional[2..]=args
                break :blk if (positional.len >= 3) positional[2..] else &.{};
            }
        } else &.{};

        return .{
            .file_path = file_path,
            .func_name = func_name,
            .i32_args = i32_args,
            .legacy_exceptions = legacy_exceptions,
            .mem_stats = mem_stats,
            .mem_limit_mb = mem_limit_mb,
            .reactor = reactor,
            .wasi_args = wasi_args,
            .passthrough = passthrough,
            ._args_alloc = args,
            ._args_allocator = allocator,
            ._wasm_args_parsed = wasm_args_parsed,
            ._positional = positional,
        };
    }

    fn deinit(self: *CliArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.wasi_args);
        for (self._wasm_args_parsed) |tok| allocator.free(tok);
        allocator.free(self._wasm_args_parsed);
        allocator.free(self._positional);
        std.process.argsFree(self._args_allocator, self._args_alloc);
    }
};

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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
}

/// Context used for the proc_exit callback when --mem-stats is active.
const MemStatsCtx = struct {
    store: ?*Store = null,
    instance: ?*Instance = null,
};

fn onExitMemStats(_: u32, data: ?*anyopaque) void {
    if (data) |d| {
        const ctx: *MemStatsCtx = @ptrCast(@alignCast(d));
        if (ctx.store != null and ctx.instance != null) {
            printMemStats(ctx.store.?, ctx.instance.?);
        }
    }
}

/// Print memory usage stats to stderr.
fn printMemStats(store: *Store, instance: *Instance) void {
    const linear_bytes = instance.memory.byteLen();
    const linear_pages = instance.memory.pageCount();
    const gc_used = store.gc_heap.usedSize();
    const gc_cap = store.gc_heap.totalSize();
    const shared_bytes = store.memory_budget.shared_bytes;
    const total = linear_bytes + gc_cap + shared_bytes;

    const linear_mb = @as(f64, @floatFromInt(linear_bytes)) / (1024.0 * 1024.0);
    const gc_cap_mb = @as(f64, @floatFromInt(gc_cap)) / (1024.0 * 1024.0);
    const gc_used_kb = @as(f64, @floatFromInt(gc_used)) / 1024.0;
    const gc_cap_kb = @as(f64, @floatFromInt(gc_cap)) / 1024.0;
    const shared_mb = @as(f64, @floatFromInt(shared_bytes)) / (1024.0 * 1024.0);
    const total_mb = @as(f64, @floatFromInt(total)) / (1024.0 * 1024.0);

    const shared_annotation: []const u8 = if (shared_bytes == 0) "(none)" else "";

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.print(
        "Memory usage:\n" ++
            "  Linear memory:  {d:.2} MB  ({d} pages)\n" ++
            "  GC heap:        {d:.2} MB  (used {d:.1} KB / capacity {d:.1} KB)\n" ++
            "  Shared memory:  {d:.2} MB  {s}\n" ++
            "  \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n" ++
            "  Total:          {d:.2} MB\n",
        .{
            linear_mb,
            linear_pages,
            gc_cap_mb,
            gc_used_kb,
            gc_cap_kb,
            shared_mb,
            shared_annotation,
            total_mb,
        },
    ) catch {};
    std.fs.File.stderr().writeAll(fbs.getWritten()) catch {};
}

fn run(allocator: std.mem.Allocator, stdout: anytype) !void {
    var cli_args = CliArgs.parse(allocator) catch |err| {
        switch (err) {
            error.MissingFilePath => {
                try stdout.writeAll(
                    \\Usage:
                    \\  wasmz [--legacy-exceptions] <file.wasm>                                List exported functions
                    \\  wasmz [--legacy-exceptions] <file.wasm> <func> [i32_arg...]            Call the specified function and print the return value
                    \\  wasmz [--legacy-exceptions] <file.wasm> --args "<wasm_arg...>"         Run _start, forwarding args to the WASM module
                    \\  wasmz [--legacy-exceptions] <file.wasm> --func <name> [i32_arg...]     Call exported function (reactor mode)
                    \\  wasmz [--legacy-exceptions] <file.wasm> --reactor --func <name> [i32_arg...]
                    \\                                                                          Run _initialize then call function
                    \\
                );
                std.process.exit(1);
            },
            else => return err,
        }
    };
    defer cli_args.deinit(allocator);

    const file_path = cli_args.file_path;

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

    var engine = Engine.init(allocator, Config{
        .legacy_exceptions = cli_args.legacy_exceptions,
        .mem_limit_bytes = if (cli_args.mem_limit_mb) |mb| mb * 1024 * 1024 else null,
    }) catch |err| {
        std.debug.print("error: Failed to initialize engine: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer engine.deinit();

    var arc_module = Module.compileArc(engine, bytes) catch |err| {
        std.debug.print("error: Failed to compile {s}: {s}\n", .{ file_path, @errorName(err) });
        std.process.exit(1);
    };
    defer if (arc_module.releaseUnwrap()) |m| {
        var mod = m;
        mod.deinit();
    };

    var store = try Store.init(allocator, engine);
    store.linkBudget();
    defer store.deinit();

    var wasi_host = wasi_preview1.Host.init(allocator);
    defer wasi_host.deinit();
    try wasi_host.setArgs(cli_args.wasi_args);

    // If --mem-stats is set, register a proc_exit callback so that stats are
    // printed even when the WASM module calls proc_exit (which bypasses defer).
    var mem_stats_ctx = MemStatsCtx{};
    mem_stats_ctx.store = &store;
    if (cli_args.mem_stats) {
        wasi_host.setOnExit(onExitMemStats, &mem_stats_ctx);
    }

    var linker = Linker.empty;
    try wasi_host.addToLinker(&linker, allocator);
    try linker.define(allocator, "env", "host_print_i32", HostFunc.init(
        null,
        host_print_i32,
        &[_]ValType{.I32},
        &[_]ValType{},
    ));
    defer linker.deinit(allocator);

    var instance = Instance.init(&store, arc_module.retain(), linker) catch |err| {
        switch (err) {
            error.ImportNotSatisfied => {
                std.debug.print("error: Failed to instantiate module: the following imports are not satisfied:\n", .{});
                for (arc_module.value.imported_funcs) |def| {
                    if (linker.get(def.module_name, def.func_name) == null) {
                        std.debug.print("  - {s}::{s}\n", .{ def.module_name, def.func_name });
                    }
                }
            },
            error.ImportSignatureMismatch => {
                std.debug.print("error: Failed to instantiate module: import signature mismatch\n", .{});
                for (arc_module.value.imported_funcs) |def| {
                    const hf = linker.get(def.module_name, def.func_name);
                    if (hf == null) continue;

                    const func_type = switch (arc_module.value.composite_types[def.type_index]) {
                        .func_type => |ft| ft,
                        else => continue,
                    };

                    if (!hf.?.matches(func_type)) {
                        std.debug.print("  - {s}::{s}\n", .{ def.module_name, def.func_name });
                        std.debug.print("    expected: {any} -> {any}\n", .{ func_type.params(), func_type.results() });
                        std.debug.print("    provided: {any} -> {any}\n", .{ hf.?.param_types, hf.?.result_types });
                    }
                }
            },
            else => std.debug.print("error: Failed to instantiate module: {s}\n", .{@errorName(err)}),
        }
        std.process.exit(1);
    };
    // Point the mem-stats callback context at the live instance.
    mem_stats_ctx.instance = &instance;
    // Defer deinit last so we can print stats before it runs.
    defer {
        if (cli_args.mem_stats) printMemStats(&store, &instance);
        instance.deinit();
    }

    if (instance.runStartFunction() catch |err| {
        std.debug.print("error: Failed to run start function: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    }) |result| {
        switch (result) {
            .ok => {},
            .trap => |t| {
                const msg = t.allocPrint(allocator) catch "?";
                std.debug.print("error: start function trapped: {s}\n", .{msg});
                std.process.exit(1);
            },
        }
    }

    // Reactor initialization: only if --reactor flag is explicitly given.
    const should_init_reactor = cli_args.reactor;
    if (should_init_reactor) {
        const init_result = instance.initializeReactor() catch |err| {
            std.debug.print("error: Failed to call _initialize: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        if (init_result) |res| {
            switch (res) {
                .ok => {},
                .trap => |t| {
                    const msg = t.allocPrint(allocator) catch "?";
                    std.debug.print("error: _initialize trapped: {s}\n", .{msg});
                    std.process.exit(1);
                },
            }
        }
    }

    if (cli_args.func_name == null) {
        if (arc_module.value.exports.get("_start")) |_| {
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

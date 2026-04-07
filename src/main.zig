/// wasmz CLI entry
///
/// Usage:
///   wasmz <file.wasm>                          List exported functions
///   wasmz <file.wasm> <func_name> [i32_args]   Call the specified function and print the return value
///
/// Current limitations:
///   - Function arguments only support i32 (parsed as decimal integers)
///   - Return values are printed as i32 (void functions do not output)
const std = @import("std");
const wasmz = @import("wasmz");

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
const Imports = wasmz.Imports;

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

fn run(allocator: std.mem.Allocator, stdout: anytype) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try stdout.writeAll(
            \\Usage:
            \\  wasmz <file.wasm>                       List exported functions
            \\  wasmz <file.wasm> <func> [i32_arg...]   Call the specified function and print the return value
            \\
        );
        std.process.exit(1);
    }

    const file_path = args[1];
    if (!std.mem.endsWith(u8, file_path, ".wasm")) {
        std.debug.print("error: {s}: Unsupported file extension, expected .wasm\n", .{file_path});
        std.process.exit(1);
    }

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

    var engine = Engine.init(allocator, Config{}) catch |err| {
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

    var store = Store.init(allocator, engine);
    defer store.deinit();

    var imports = Imports.empty;
    imports.define(allocator, "env", "host_print_i32", .{
        .ctx = null,
        .func = struct {
            fn call(
                _: ?*anyopaque,
                params: []const RawVal,
                _: std.mem.Allocator,
            ) std.mem.Allocator.Error!wasmz.ExecResult {
                // Wasm type validation guarantees exactly 1 i32 param at compile time.
                const val = params[0].readAs(i32);
                std.debug.print("host_print_i32: {d}\n", .{val});
                return .{ .ok = null };
            }
        }.call,
    }) catch |err| {
        std.debug.print("error: Failed to define host function: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer imports.deinit(allocator);

    var instance = Instance.init(&store, &module, imports) catch |err| {
        std.debug.print("error: Failed to instantiate module: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer instance.deinit();

    // ── No function name → List exports (start function automatically executed during instantiation) ──────────────

    if (args.len < 3) {
        // If there is a start function, indicate it has been automatically executed
        if (module.start_function) |idx| {
            try stdout.print("start function (index {d}) has been automatically executed during instantiation.\n", .{idx});
        }
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

    const func_name = args[2];

    var call_args = std.ArrayList(RawVal){};
    defer call_args.deinit(allocator);

    for (args[3..]) |arg| {
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

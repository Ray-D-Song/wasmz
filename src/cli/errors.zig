const std = @import("std");
const builtin = @import("builtin");
const wasmz = @import("wasmz");

const Module = wasmz.Module;

/// Release builds use a minimal panic handler to avoid pulling in DWARF stack-unwinding
/// code (~127 KB).  Debug/ReleaseSafe builds use the default handler for readable backtraces.
fn simplePanic(msg: []const u8, _: ?usize) noreturn {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, "panic: ") catch {};
    std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, msg) catch {};
    std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, "\n") catch {};
    std.process.abort();
}

pub const panic = switch (builtin.mode) {
    .Debug, .ReleaseSafe => std.debug.FullPanic(std.debug.defaultPanic),
    .ReleaseFast, .ReleaseSmall => std.debug.FullPanic(simplePanic),
};

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn fatalTrap(trap: wasmz.Trap, allocator: std.mem.Allocator, module: *const Module, comptime context: []const u8) noreturn {
    const red = "\x1b[31m";
    const reset = "\x1b[0m";
    const msg = trap.allocPrint(allocator) catch "?";
    std.debug.print("{s}{s}: {s}{s}\n", .{ red, context, msg, reset });
    if (trap.stack_trace) |frames| {
        std.debug.print("wasm backtrace:\n", .{});
        for (frames, 0..) |frame, i| {
            const func_name = blk: {
                if (frame.func_idx < module.func_names.len) {
                    if (module.func_names[frame.func_idx]) |name| break :blk name;
                }
                var iter = module.exports.iterator();
                while (iter.next()) |entry| {
                    switch (entry.value_ptr.*) {
                        .function_index => |idx| {
                            if (idx == frame.func_idx) break :blk entry.key_ptr.*;
                        },
                        else => {},
                    }
                }
                if (frame.func_idx < module.imported_funcs.len) {
                    break :blk module.imported_funcs[frame.func_idx].func_name;
                }
                break :blk null;
            };
            if (func_name) |name| {
                std.debug.print("  {d}: [func {d}] {s} +0x{x}\n", .{ i, frame.func_idx, name, frame.code_offset });
            } else {
                std.debug.print("  {d}: [func {d}] <unknown> +0x{x}\n", .{ i, frame.func_idx, frame.code_offset });
            }
        }
    }
    std.process.exit(1);
}

pub fn moduleNeedsWasi(module: *const Module) bool {
    for (module.imported_funcs) |def| {
        if (std.mem.eql(u8, def.module_name, "wasi_snapshot_preview1")) return true;
    }
    return false;
}
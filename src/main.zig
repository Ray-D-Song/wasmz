const std = @import("std");

const ArgsError = error{
    TooFewArgs,
    FileExtensionNotSupported,
    FileNotExist,
};

fn args_error_message(err: ArgsError) []const u8 {
    return switch (err) {
        error.TooFewArgs => "too few arguments, expected at least 1 \n",
        error.FileExtensionNotSupported => "file extension not supported, expected .wasm \n",
        error.FileNotExist => "file does not exist \n",
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print(args_error_message(error.TooFewArgs), .{});
        return;
    }

    const file = args[1];
    if (!std.mem.endsWith(u8, file, ".wasm")) {
        std.debug.print(args_error_message(error.FileExtensionNotSupported), .{});
        return;
    }

    std.fs.cwd().access(file, .{}) catch {
        std.debug.print(args_error_message(error.FileNotExist), .{});
        return;
    };

    std.debug.print("file = {s}\n", .{file});
}

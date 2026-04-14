const std = @import("std");

pub const FlagType = enum {
    boolean,
    string,
    int,
};

pub const Flag = struct {
    name: []const u8,
    short: ?[]const u8 = null,
    help: []const u8 = "",
    type: FlagType,
    default: union {
        boolean: bool,
        string: ?[]const u8,
        int: ?i64,
    },

    pub fn boolFlag(name: []const u8, help: []const u8) Flag {
        return .{
            .name = name,
            .help = help,
            .type = .boolean,
            .default = .{ .boolean = false },
        };
    }

    pub fn stringFlag(name: []const u8, help: []const u8) Flag {
        return .{
            .name = name,
            .help = help,
            .type = .string,
            .default = .{ .string = null },
        };
    }

    pub fn intFlag(name: []const u8, help: []const u8) Flag {
        return .{
            .name = name,
            .help = help,
            .type = .int,
            .default = .{ .int = null },
        };
    }
};

pub const Arg = struct {
    name: []const u8,
    help: []const u8 = "",
    required: bool = false,
};

pub const Command = struct {
    name: []const u8,
    help: []const u8 = "",
    flags: []const Flag = &.{},
    args: []const Arg = &.{},

    pub const UsageWriter = struct {
        context: *const Command,
        writer: std.fs.File,

        pub fn write(self: *UsageWriter) !void {
            const w = self.writer;
            try w.writeAll("Usage:\n");
            try self.writeCommandUsage(w);
            try self.writeFlags(w);
            try self.writeArgs(w);
        }

        fn writeCommandUsage(self: *UsageWriter, w: std.fs.File) !void {
            var buf: [256]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            const writer = fbs.writer();

            try writer.print("  {s}", .{self.context.name});
            if (self.context.flags.len > 0) {
                try writer.writeAll(" [options]");
            }
            for (self.context.args) |arg| {
                if (arg.required) {
                    try writer.print(" <{s}>", .{arg.name});
                } else {
                    try writer.print(" [{s}]", .{arg.name});
                }
            }
            try writer.writeAll("\n\n");
            try w.writeAll(fbs.getWritten());
        }

        fn writeFlags(self: *UsageWriter, w: std.fs.File) !void {
            if (self.context.flags.len == 0) return;

            try w.writeAll("Options:\n");
            var buf: [256]u8 = undefined;
            for (self.context.flags) |flag| {
                var fbs = std.io.fixedBufferStream(&buf);
                const writer = fbs.writer();

                if (flag.short) |short| {
                    try writer.print("  -{s}, --{s}", .{ short, flag.name });
                } else {
                    try writer.print("  --{s}", .{flag.name});
                }
                switch (flag.type) {
                    .string => try writer.writeAll(" <string>"),
                    .int => try writer.writeAll(" <int>"),
                    .boolean => {},
                }
                if (flag.help.len > 0) {
                    try writer.print("  {s}", .{flag.help});
                }
                try writer.writeAll("\n");
                try w.writeAll(fbs.getWritten());
            }
            try w.writeAll("\n");
        }

        fn writeArgs(self: *UsageWriter, w: std.fs.File) !void {
            if (self.context.args.len == 0) return;

            try w.writeAll("Arguments:\n");
            var buf: [128]u8 = undefined;
            for (self.context.args) |arg| {
                var fbs = std.io.fixedBufferStream(&buf);
                const writer = fbs.writer();
                try writer.print("  {s}", .{arg.name});
                if (arg.help.len > 0) {
                    try writer.print("  {s}", .{arg.help});
                }
                try writer.writeAll("\n");
                try w.writeAll(fbs.getWritten());
            }
        }
    };

    pub fn printUsage(self: *const Command) void {
        var writer = UsageWriter{
            .context = self,
            .writer = std.fs.File.stderr(),
        };
        writer.write() catch {};
    }
};

pub const Parsed = struct {
    flags: std.StringHashMap(FlagValue),
    positional: []const []const u8,
    _args_alloc: [][:0]u8,
    _allocator: std.mem.Allocator,
    _string_values: std.ArrayList([]const u8),

    pub const FlagValue = union(enum) {
        boolean: bool,
        string: ?[]const u8,
        int: ?i64,
    };

    pub fn getBool(self: *const Parsed, name: []const u8) bool {
        if (self.flags.get(name)) |val| {
            return switch (val) {
                .boolean => |b| b,
                else => false,
            };
        }
        return false;
    }

    pub fn getString(self: *const Parsed, name: []const u8) ?[]const u8 {
        if (self.flags.get(name)) |val| {
            return switch (val) {
                .string => |s| s,
                else => null,
            };
        }
        return null;
    }

    pub fn getInt(self: *const Parsed, name: []const u8) ?i64 {
        if (self.flags.get(name)) |val| {
            return switch (val) {
                .int => |i| i,
                else => null,
            };
        }
        return null;
    }

    pub fn deinit(self: *Parsed) void {
        self.flags.deinit();
        for (self._string_values.items) |s| {
            self._allocator.free(s);
        }
        self._string_values.deinit(self._allocator);
        std.process.argsFree(self._allocator, self._args_alloc);
    }
};

pub const ParseError = error{
    MissingRequiredArg,
    UnknownFlag,
    InvalidFlagValue,
    OutOfMemory,
};

pub const Parser = struct {
    command: *const Command,
    allocator: std.mem.Allocator,

    pub fn init(command: *const Command, allocator: std.mem.Allocator) Parser {
        return .{
            .command = command,
            .allocator = allocator,
        };
    }

    pub fn parse(self: *Parser) ParseError!Parsed {
        const args = std.process.argsAlloc(self.allocator) catch
            return error.OutOfMemory;
        errdefer std.process.argsFree(self.allocator, args);

        var flags = std.StringHashMap(Parsed.FlagValue).init(self.allocator);
        errdefer flags.deinit();

        var string_values: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (string_values.items) |s| self.allocator.free(s);
            string_values.deinit(self.allocator);
        }

        for (self.command.flags) |flag| {
            const default_val: Parsed.FlagValue = switch (flag.type) {
                .boolean => .{ .boolean = flag.default.boolean },
                .string => .{ .string = flag.default.string },
                .int => .{ .int = flag.default.int },
            };
            flags.put(flag.name, default_val) catch
                return error.OutOfMemory;
        }

        var positional: std.ArrayList([]const u8) = .empty;
        defer positional.deinit(self.allocator);

        var idx: usize = 1;
        while (idx < args.len) : (idx += 1) {
            const arg = args[idx];

            if (std.mem.startsWith(u8, arg, "--")) {
                if (std.mem.indexOf(u8, arg, "=")) |eq_pos| {
                    const flag_name = arg[2..eq_pos];
                    const flag_value = arg[eq_pos + 1 ..];
                    try self.setFlag(&flags, &string_values, flag_name, flag_value);
                } else {
                    const flag_name = arg[2..];
                    if (self.findFlag(flag_name)) |flag| {
                        switch (flag.type) {
                            .boolean => {
                                flags.put(flag_name, .{ .boolean = true }) catch
                                    return error.OutOfMemory;
                            },
                            .string, .int => {
                                idx += 1;
                                if (idx >= args.len) {
                                    std.debug.print("error: --{s} requires a value\n", .{flag_name});
                                    self.command.printUsage();
                                    return error.InvalidFlagValue;
                                }
                                try self.setFlag(&flags, &string_values, flag_name, args[idx]);
                            },
                        }
                    } else {
                        std.debug.print("error: unknown flag: --{s}\n", .{flag_name});
                        self.command.printUsage();
                        return error.UnknownFlag;
                    }
                }
            } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
                const short_name = arg[1..];
                if (self.findFlagByShort(short_name)) |flag| {
                    switch (flag.type) {
                        .boolean => {
                            flags.put(flag.name, .{ .boolean = true }) catch
                                return error.OutOfMemory;
                        },
                        .string, .int => {
                            idx += 1;
                            if (idx >= args.len) {
                                std.debug.print("error: -{s} requires a value\n", .{short_name});
                                self.command.printUsage();
                                return error.InvalidFlagValue;
                            }
                            try self.setFlag(&flags, &string_values, flag.name, args[idx]);
                        },
                    }
                } else {
                    std.debug.print("error: unknown flag: -{s}\n", .{short_name});
                    self.command.printUsage();
                    return error.UnknownFlag;
                }
            } else {
                positional.append(self.allocator, arg) catch
                    return error.OutOfMemory;
            }
        }

        for (self.command.args, 0..) |arg_spec, i| {
            if (arg_spec.required and i >= positional.items.len) {
                if (flags.get("help")) |val| {
                    if (val == .boolean and val.boolean) {
                        return .{
                            .flags = flags,
                            .positional = positional.toOwnedSlice(self.allocator) catch
                                return error.OutOfMemory,
                            ._args_alloc = args,
                            ._allocator = self.allocator,
                            ._string_values = string_values,
                        };
                    }
                }
                std.debug.print("error: missing required argument: {s}\n", .{arg_spec.name});
                self.command.printUsage();
                return error.MissingRequiredArg;
            }
        }

        return .{
            .flags = flags,
            .positional = positional.toOwnedSlice(self.allocator) catch
                return error.OutOfMemory,
            ._args_alloc = args,
            ._allocator = self.allocator,
            ._string_values = string_values,
        };
    }

    fn findFlag(self: *Parser, name: []const u8) ?*const Flag {
        for (self.command.flags) |*flag| {
            if (std.mem.eql(u8, flag.name, name)) {
                return flag;
            }
        }
        return null;
    }

    fn findFlagByShort(self: *Parser, short: []const u8) ?*const Flag {
        for (self.command.flags) |*flag| {
            if (flag.short) |s| {
                if (std.mem.eql(u8, s, short)) {
                    return flag;
                }
            }
        }
        return null;
    }

    fn setFlag(
        self: *Parser,
        flags: *std.StringHashMap(Parsed.FlagValue),
        string_values: *std.ArrayList([]const u8),
        name: []const u8,
        value: []const u8,
    ) ParseError!void {
        if (self.findFlag(name)) |flag| {
            switch (flag.type) {
                .boolean => {
                    const bool_val = std.mem.eql(u8, value, "true") or
                        std.mem.eql(u8, value, "1");
                    flags.put(name, .{ .boolean = bool_val }) catch
                        return error.OutOfMemory;
                },
                .string => {
                    const duped = self.allocator.dupe(u8, value) catch
                        return error.OutOfMemory;
                    string_values.append(self.allocator, duped) catch {
                        self.allocator.free(duped);
                        return error.OutOfMemory;
                    };
                    flags.put(name, .{ .string = duped }) catch
                        return error.OutOfMemory;
                },
                .int => {
                    const int_val = std.fmt.parseInt(i64, value, 10) catch {
                        std.debug.print("error: --{s} value must be an integer\n", .{name});
                        return error.InvalidFlagValue;
                    };
                    flags.put(name, .{ .int = int_val }) catch
                        return error.OutOfMemory;
                },
            }
        } else {
            std.debug.print("error: unknown flag: --{s}\n", .{name});
            self.command.printUsage();
            return error.UnknownFlag;
        }
    }
};

pub fn splitShellArgs(allocator: std.mem.Allocator, s: []const u8) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
        if (i >= s.len) break;

        var token: std.ArrayList(u8) = .empty;
        errdefer token.deinit(allocator);

        while (i < s.len and s[i] != ' ' and s[i] != '\t') {
            const ch = s[i];
            if (ch == '\'' or ch == '"') {
                const quote = ch;
                i += 1;
                while (i < s.len and s[i] != quote) : (i += 1) {
                    try token.append(allocator, s[i]);
                }
                if (i < s.len) i += 1;
            } else {
                try token.append(allocator, ch);
                i += 1;
            }
        }

        try result.append(allocator, try token.toOwnedSlice(allocator));
    }

    return result.toOwnedSlice(allocator);
}

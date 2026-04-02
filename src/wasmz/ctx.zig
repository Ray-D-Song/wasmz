const std = @import("std");

pub const Context = struct {
    allocator: std.mem.Allocator,
    file: []const u8,

    pub fn init(allocator: std.mem.Allocator, file: []const u8) Context {
        return .{
            .allocator = allocator,
            .file = file,
        };
    }
};

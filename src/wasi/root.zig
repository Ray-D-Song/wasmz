const std = @import("std");

pub const WasiContext = struct {
    allocator: std.mem.Allocator,
};

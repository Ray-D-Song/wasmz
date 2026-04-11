const std = @import("std");
const ValType = @import("./value/type.zig").ValType;

pub const FuncTypeError = error{
    TooManyFunctionParams,
    TooManyFunctionResults,
};

pub fn funcTypeErrorMsg(err: FuncTypeError) []const u8 {
    return switch (err) {
        FuncTypeError.TooManyFunctionParams => "too many function parameters (max 255)",
        FuncTypeError.TooManyFunctionResults => "too many function results (max 1)",
    };
}

/// Maximum total number of params+results stored inline (no heap allocation).
/// Covers the vast majority of real-world Wasm function signatures.
const INLINE_CAP: usize = 4;

/// Heap-allocated, reference-counted buffer used when params+results > INLINE_CAP.
/// Stores params immediately followed by results in a single contiguous allocation.
const SharedBuf = struct {
    refcount: usize,
    /// Contiguous slice: data[0..params_len] = params, data[params_len..] = results.
    data: []ValType,
    allocator: std.mem.Allocator,

    fn create(allocator: std.mem.Allocator, params: []const ValType, results: []const ValType) std.mem.Allocator.Error!*SharedBuf {
        const total = params.len + results.len;
        const buf = try allocator.create(SharedBuf);
        errdefer allocator.destroy(buf);
        const data = try allocator.alloc(ValType, total);
        @memcpy(data[0..params.len], params);
        @memcpy(data[params.len..], results);
        buf.* = .{ .refcount = 1, .data = data, .allocator = allocator };
        return buf;
    }

    fn retain(self: *SharedBuf) void {
        self.refcount += 1;
    }

    /// Decrement refcount and free if it reaches zero. Returns true if freed.
    fn release(self: *SharedBuf) void {
        self.refcount -= 1;
        if (self.refcount == 0) {
            const allocator = self.allocator;
            allocator.free(self.data);
            allocator.destroy(self);
        }
    }
};

/// Internal representation: either inline (small) or ref-counted heap (large).
const Repr = union(enum) {
    /// params+results fit within INLINE_CAP — stored without any heap allocation.
    small: [INLINE_CAP]ValType,
    /// params+results exceed INLINE_CAP — stored in a reference-counted shared buffer.
    large: *SharedBuf,
};

// A function type representing a function's parameter and result types.
pub const FuncType = struct {
    repr: Repr,
    params_len: u16,
    results_len: u16,

    pub const max_len_params: usize = 1000;
    pub const max_len_results: usize = 1000;

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        param_types: []const ValType,
        result_types: []const ValType,
    ) (FuncTypeError || std.mem.Allocator.Error)!Self {
        if (param_types.len > max_len_params) {
            return error.TooManyFunctionParams;
        }
        if (result_types.len > max_len_results) {
            return error.TooManyFunctionResults;
        }

        const total = param_types.len + result_types.len;
        const params_len: u16 = @intCast(param_types.len);
        const results_len: u16 = @intCast(result_types.len);

        if (total <= INLINE_CAP) {
            // Small path: store inline, no allocation needed.
            var data: [INLINE_CAP]ValType = undefined;
            @memcpy(data[0..param_types.len], param_types);
            @memcpy(data[param_types.len .. param_types.len + result_types.len], result_types);
            return .{ .repr = .{ .small = data }, .params_len = params_len, .results_len = results_len };
        } else {
            // Large path: allocate a shared ref-counted buffer.
            const buf = try SharedBuf.create(allocator, param_types, result_types);
            return .{ .repr = .{ .large = buf }, .params_len = params_len, .results_len = results_len };
        }
    }

    /// Returns a new FuncType that shares the same underlying buffer (no allocation).
    /// The caller is responsible for calling deinit on the returned FuncType.
    pub fn retain(self: Self) Self {
        switch (self.repr) {
            .small => {
                // Inline data is copied by value; no refcount to update.
                return self;
            },
            .large => |buf| {
                buf.retain();
                return self;
            },
        }
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        _ = allocator; // not needed; allocator is stored in SharedBuf for large case
        switch (self.repr) {
            .small => {
                // Inline data — nothing to free.
            },
            .large => |buf| {
                buf.release();
            },
        }
    }

    pub fn params(self: *const Self) []const ValType {
        return switch (self.repr) {
            .small => |*data| data[0..self.params_len],
            .large => |buf| buf.data[0..self.params_len],
        };
    }

    pub fn results(self: *const Self) []const ValType {
        const offset = self.params_len;
        return switch (self.repr) {
            .small => |*data| data[offset .. offset + self.results_len],
            .large => |buf| buf.data[offset .. offset + self.results_len],
        };
    }

    pub fn lenParams(self: Self) u16 {
        return self.params_len;
    }

    pub fn lenResults(self: Self) u16 {
        return self.results_len;
    }

    // A helper method to get both params and results together
    pub fn getParamsResults(self: *const Self) struct {
        params: []const ValType,
        results: []const ValType,
    } {
        return .{
            .params = self.params(),
            .results = self.results(),
        };
    }

    // For debug print like: std.debug.print("{}\n", .{func_type});
    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.writeAll("FuncType{ params=[");
        for (self.params(), 0..) |ty, i| {
            if (i != 0) try writer.writeAll(", ");
            try writer.print("{}", .{ty});
        }
        try writer.writeAll("], results=[");

        for (self.results(), 0..) |ty, i| {
            if (i != 0) try writer.writeAll(", ");
            try writer.print("{}", .{ty});
        }
        try writer.writeAll("] }");
    }
};

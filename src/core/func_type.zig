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

// A function type representing a function's parameter and result types.
// TODO: Supports inline allocation into arrays of structs when the total number of parameter types and return types is relatively small
// TODO: Reference count decrease copy
pub const FuncType = struct {
    params_buf: []ValType,
    results_buf: []ValType,

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

        const params_buf = try allocator.dupe(ValType, param_types);
        errdefer allocator.free(params_buf);

        const results_buf = try allocator.dupe(ValType, result_types);
        errdefer allocator.free(results_buf);

        return .{
            .params_buf = params_buf,
            .results_buf = results_buf,
        };
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.params_buf);
        allocator.free(self.results_buf);
    }

    pub fn params(self: Self) []const ValType {
        return self.params_buf;
    }

    pub fn results(self: Self) []const ValType {
        return self.results_buf;
    }

    pub fn lenParams(self: Self) u16 {
        return @as(u16, @intCast(self.params_buf.len));
    }

    pub fn lenResults(self: Self) u16 {
        return @as(u16, @intCast(self.results_buf.len));
    }

    // A helper method to get both params and results together
    pub fn getParamsResults(self: Self) struct {
        params: []const ValType,
        results: []const ValType,
    } {
        return .{
            .params = self.params_buf,
            .results = self.results_buf,
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
        for (self.params_buf, 0..) |ty, i| {
            if (i != 0) try writer.writeAll(", ");
            try writer.print("{}", .{ty});
        }
        try writer.writeAll("], results=[");

        for (self.results_buf, 0..) |ty, i| {
            if (i != 0) try writer.writeAll(", ");
            try writer.print("{}", .{ty});
        }
        try writer.writeAll("] }");
    }
};

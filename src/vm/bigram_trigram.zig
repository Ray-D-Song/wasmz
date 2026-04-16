/// bigram_trigram.zig —统计 opcode bigram/trigram 频率
///
/// 用法: 编译时加 `-Dprofiling=true`，运行后查看 stderr 的 bigram/trigram 统计。
const std = @import("std");
const build_options = @import("build_options");

pub const bigram_enabled = build_options.profiling;
pub const trigram_enabled = build_options.profiling;

pub const OpName = enum(u8) {
    copy,
    local_get,
    local_set,
    copy_jump_if_nz,
    jump,
    call_ret,
    global,
    constant,
    imm,
    imm_r,
    unary,
    conv,
    cmp,
    binop,
    ref_select,
    mem_table,
    simd,
    atomic,
    trap_unreachable,
    i32_to_local,
    i64_to_local,
    i32_imm_to_local,
    i64_imm_to_local,
    i32_local_inplace,
    i64_local_inplace,
    const_to_local,
    load_to_local,
    global_to_local,
    tee_local,
    cmp_to_local,
    misc,
    dispatch_next,
    dispatch_dispatch,
    unknown,
};

pub fn strToOpName(s: []const u8) OpName {
    return std.meta.stringToEnum(OpName, s) orelse .unknown;
}

pub const BigramCounts = if (bigram_enabled) struct {
    map: std.AutoArrayHashMap(u16, u64),

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{ .map = std.AutoArrayHashMap(u16, u64).init(allocator) };
    }

    pub fn deinit(self: *@This()) void {
        self.map.deinit();
    }

    pub fn record(self: *@This(), prev: OpName, curr: OpName) void {
        const a = @as(u8, @intFromEnum(prev));
        const b = @as(u8, @intFromEnum(curr));
        const key: u16 = (@as(u16, a) << 8) | @as(u16, b);
        const entry = self.map.getOrPut(key) catch return;
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }
} else struct {
    pub fn init(_: std.mem.Allocator) @This() {
        return .{};
    }
    pub fn deinit(_: *@This()) void {}
    pub fn record(_: OpName, _: OpName) void {}
};

pub const TrigramCounts = if (trigram_enabled) struct {
    map: std.AutoArrayHashMap(u32, u64),

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{ .map = std.AutoArrayHashMap(u32, u64).init(allocator) };
    }

    pub fn deinit(self: *@This()) void {
        self.map.deinit();
    }

    pub fn record(self: *@This(), prev2: OpName, prev1: OpName, curr: OpName) void {
        const a = @as(u8, @intFromEnum(prev2));
        const b = @as(u8, @intFromEnum(prev1));
        const c = @as(u8, @intFromEnum(curr));
        const key: u32 = (@as(u32, a) << 16) | (@as(u32, b) << 8) | @as(u32, c);
        const entry = self.map.getOrPut(key) catch return;
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }
} else struct {
    pub fn init(_: std.mem.Allocator) @This() {
        return .{};
    }
    pub fn deinit(_: *@This()) void {}
    pub fn record(_: OpName, _: OpName, _: OpName) void {}
};

pub var bigram_counts: BigramCounts = if (bigram_enabled) .{ .map = undefined } else .{};
pub var trigram_counts: TrigramCounts = if (trigram_enabled) .{ .map = undefined } else .{};

pub fn initNgramCounts(allocator: std.mem.Allocator) void {
    if (bigram_enabled) {
        bigram_counts.map = std.AutoArrayHashMap(u16, u64).init(allocator);
    }
    if (trigram_enabled) {
        trigram_counts.map = std.AutoArrayHashMap(u32, u64).init(allocator);
    }
}

pub fn deinitNgramCounts() void {
    if (bigram_enabled) bigram_counts.deinit();
    if (trigram_enabled) trigram_counts.deinit();
}

pub fn printNgramStats(n: usize) void {
    const stderr_file = std.fs.File.stderr();
    _ = n;

    stderr_file.writeAll("\n=== Top 30 Bigrams ===\n") catch return;
    var iter = bigram_counts.map.iterator();

    var items: [256]struct { key: u16, value: u64 } = undefined;
    var count: usize = 0;
    while (iter.next()) |entry| {
        if (count < 256) {
            items[count] = .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* };
            count += 1;
        }
    }

    for (0..count) |i| {
        var min_idx = i;
        for (i + 1..count) |j| {
            if (items[j].value > items[min_idx].value) min_idx = j;
        }
        if (min_idx != i) {
            const tmp = items[i];
            items[i] = items[min_idx];
            items[min_idx] = tmp;
        }
    }

    for (0..@min(30, count)) |i| {
        const key = items[i].key;
        const prev = @as(OpName, @enumFromInt(key >> 8));
        const curr = @as(OpName, @enumFromInt(key & 0xFF));
        printOpName(stderr_file, prev) catch return;
        stderr_file.writeAll(" -> ") catch return;
        printOpName(stderr_file, curr) catch return;
        stderr_file.writeAll(": ") catch return;
        printU64(stderr_file, items[i].value) catch return;
        stderr_file.writeAll("\n") catch return;
    }

    stderr_file.writeAll("\n=== Top 30 Trigrams ===\n") catch return;
    var iter2 = trigram_counts.map.iterator();

    var items2: [256]struct { key: u32, value: u64 } = undefined;
    var count2: usize = 0;
    while (iter2.next()) |entry| {
        if (count2 < 256) {
            items2[count2] = .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* };
            count2 += 1;
        }
    }

    for (0..count2) |i| {
        var min_idx = i;
        for (i + 1..count2) |j| {
            if (items2[j].value > items2[min_idx].value) min_idx = j;
        }
        if (min_idx != i) {
            const tmp = items2[i];
            items2[i] = items2[min_idx];
            items2[min_idx] = tmp;
        }
    }

    for (0..@min(30, count2)) |i| {
        const key = items2[i].key;
        const op1 = @as(OpName, @enumFromInt((key >> 16) & 0xFF));
        const op2 = @as(OpName, @enumFromInt((key >> 8) & 0xFF));
        const op3 = @as(OpName, @enumFromInt(key & 0xFF));
        printOpName(stderr_file, op1) catch return;
        stderr_file.writeAll(" -> ") catch return;
        printOpName(stderr_file, op2) catch return;
        stderr_file.writeAll(" -> ") catch return;
        printOpName(stderr_file, op3) catch return;
        stderr_file.writeAll(": ") catch return;
        printU64(stderr_file, items2[i].value) catch return;
        stderr_file.writeAll("\n") catch return;
    }
}

fn printOpName(f: std.fs.File, op: OpName) !void {
    const s = switch (op) {
        .copy => "copy",
        .local_get => "local_get",
        .local_set => "local_set",
        .copy_jump_if_nz => "copy_jump_if_nz",
        .jump => "jump",
        .call_ret => "call_ret",
        .global => "global",
        .constant => "constant",
        .imm => "imm",
        .imm_r => "imm_r",
        .unary => "unary",
        .conv => "conv",
        .cmp => "cmp",
        .binop => "binop",
        .ref_select => "ref_select",
        .mem_table => "mem_table",
        .simd => "simd",
        .atomic => "atomic",
        .trap_unreachable => "trap_unreachable",
        .i32_to_local => "i32_to_local",
        .i64_to_local => "i64_to_local",
        .i32_imm_to_local => "i32_imm_to_local",
        .i64_imm_to_local => "i64_imm_to_local",
        .i32_local_inplace => "i32_local_inplace",
        .i64_local_inplace => "i64_local_inplace",
        .const_to_local => "const_to_local",
        .load_to_local => "load_to_local",
        .global_to_local => "global_to_local",
        .tee_local => "tee_local",
        .cmp_to_local => "cmp_to_local",
        .misc => "misc",
        .dispatch_next => "dispatch_next",
        .dispatch_dispatch => "dispatch_dispatch",
        .unknown => "(start)",
    };
    try f.writeAll(s);
}

fn printU64(f: std.fs.File, x: u64) !void {
    var buf: [24]u8 = undefined;
    try f.writeAll(std.fmt.bufPrint(&buf, "{d}", .{x}) catch "0");
}

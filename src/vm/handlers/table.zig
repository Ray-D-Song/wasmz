/// handlers_table.zig — M3 threaded-dispatch table instruction handlers
///
/// table_get, table_set, table_size, table_grow, table_fill, table_copy, table_init, elem_drop
const std = @import("std");
const ir = @import("../../compiler/ir.zig");
const encode = @import("../../compiler/encode.zig");
const dispatch = @import("../dispatch.zig");
const core = @import("core");

const RawVal = dispatch.RawVal;
const Trap = dispatch.Trap;
const Handler = dispatch.Handler;
const DispatchState = dispatch.DispatchState;
const ExecEnv = dispatch.ExecEnv;

const HANDLER_SIZE = dispatch.HANDLER_SIZE;

// ── Helpers ──────────────────────────────────────────────────────────────────

inline fn readOps(comptime T: type, ip: [*]u8) T {
    if (@sizeOf(T) == 0) return .{};
    const bytes = ip[HANDLER_SIZE..][0..@sizeOf(T)];
    return std.mem.bytesAsValue(T, bytes).*;
}

inline fn stride(comptime OpsT: type) usize {
    return HANDLER_SIZE + @sizeOf(OpsT);
}

inline fn trapReturn(frame: *DispatchState, code: core.TrapCode) void {
    var trap = Trap.fromTrapCode(code);
    if (frame.captureStackTrace()) |trace| {
        trap.allocator = frame.allocator;
        trap.stack_trace = trace;
    }
    frame.result = .{ .trap = trap };
}

// ── table_get ────────────────────────────────────────────────────────────────

pub fn handle_table_get(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsTableGet, ip);
    if (ops.table_index >= env.tables.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    const table = env.tables[ops.table_index];
    const idx = slots[ops.index].readAs(u32);
    if (idx >= table.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    const func_idx = table[idx];
    // Convert u32 table entry to funcref slot value.
    // Table null sentinel (maxInt(u32)) -> slot null (0).
    // Non-null: func_idx -> func_idx+1.
    const ref: u64 = if (func_idx == std.math.maxInt(u32)) 0 else @as(u64, func_idx) + 1;
    slots[ops.dst] = RawVal.fromBits64(ref);
    dispatch.next(ip, stride(encode.OpsTableGet), slots, frame, env, r0, fp0);
}

// ── table_set ────────────────────────────────────────────────────────────────

pub fn handle_table_set(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsTableSet, ip);
    if (ops.table_index >= env.tables.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    const table = env.tables[ops.table_index];
    const idx = slots[ops.index].readAs(u32);
    if (idx >= table.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    const ref = slots[ops.value].readAs(u64);
    // Convert funcref slot value to u32 table entry.
    // Slot null (0) -> table null sentinel (maxInt(u32)).
    // Non-null: slot value is func_idx+1 -> table stores func_idx.
    env.tables[ops.table_index][idx] = if (ref == 0) std.math.maxInt(u32) else @as(u32, @intCast(ref - 1));
    dispatch.next(ip, stride(encode.OpsTableSet), slots, frame, env, r0, fp0);
}

// ── table_size ───────────────────────────────────────────────────────────────

pub fn handle_table_size(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsTableSize, ip);
    if (ops.table_index >= env.tables.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    const size: i32 = @intCast(env.tables[ops.table_index].len);
    slots[ops.dst] = RawVal.from(size);
    dispatch.next(ip, stride(encode.OpsTableSize), slots, frame, env, r0, fp0);
}

// ── table_grow ───────────────────────────────────────────────────────────────

pub fn handle_table_grow(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsTableGrow, ip);

    const result: i32 = blk: {
        if (ops.table_index >= env.tables.len) break :blk -1;
        const old_len = env.tables[ops.table_index].len;
        const delta = slots[ops.delta].readAs(u32);
        const new_len = std.math.add(usize, old_len, @as(usize, delta)) catch break :blk -1;
        const init_ref = slots[ops.init].readAs(u64);
        const init_val: u32 = if (init_ref == 0) std.math.maxInt(u32) else @as(u32, @intCast(init_ref - 1));
        const new_slice = frame.allocator.realloc(env.tables[ops.table_index], new_len) catch break :blk -1;
        env.tables[ops.table_index] = new_slice;
        @memset(env.tables[ops.table_index][old_len..], init_val);
        break :blk @intCast(old_len);
    };
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsTableGrow), slots, frame, env, r0, fp0);
}

// ── table_fill ───────────────────────────────────────────────────────────────

pub fn handle_table_fill(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsTableFill, ip);
    if (ops.table_index >= env.tables.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    const table = env.tables[ops.table_index];
    const dst_idx = slots[ops.dst_idx].readAs(u32);
    const len = slots[ops.len].readAs(u32);
    const end = dst_idx +% len;
    if (end > table.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    const ref = slots[ops.value].readAs(u64);
    const val: u32 = if (ref == 0) std.math.maxInt(u32) else @as(u32, @intCast(ref - 1));
    @memset(env.tables[ops.table_index][dst_idx..][0..len], val);
    dispatch.next(ip, stride(encode.OpsTableFill), slots, frame, env, r0, fp0);
}

// ── table_copy ───────────────────────────────────────────────────────────────

pub fn handle_table_copy(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsTableCopy, ip);
    if (ops.dst_table >= env.tables.len or ops.src_table >= env.tables.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    const dst_tbl = env.tables[ops.dst_table];
    const src_tbl = env.tables[ops.src_table];
    const dst_idx = slots[ops.dst_idx].readAs(u32);
    const src_idx = slots[ops.src_idx].readAs(u32);
    const len = slots[ops.len].readAs(u32);
    const src_end = src_idx +% len;
    const dst_end = dst_idx +% len;
    if (src_end > src_tbl.len or dst_end > dst_tbl.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    if (len > 0) {
        if (ops.dst_table == ops.src_table) {
            if (dst_idx < src_idx) {
                @memcpy(env.tables[ops.dst_table][dst_idx..][0..len], env.tables[ops.src_table][src_idx..][0..len]);
            } else if (dst_idx > src_idx) {
                var i: usize = len;
                while (i > 0) {
                    i -= 1;
                    env.tables[ops.dst_table][dst_idx + i] = env.tables[ops.src_table][src_idx + i];
                }
            }
        } else {
            @memcpy(env.tables[ops.dst_table][dst_idx..][0..len], env.tables[ops.src_table][src_idx..][0..len]);
        }
    }
    dispatch.next(ip, stride(encode.OpsTableCopy), slots, frame, env, r0, fp0);
}

// ── table_init ───────────────────────────────────────────────────────────────

pub fn handle_table_init(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsTableInit, ip);
    if (ops.table_index >= env.tables.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    if (ops.segment_idx >= env.elem_segments.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    if (env.elem_segments_dropped[ops.segment_idx]) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    const seg = env.elem_segments[ops.segment_idx];
    const dst_idx = slots[ops.dst_idx].readAs(u32);
    const src_offset = slots[ops.src_offset].readAs(u32);
    const len = slots[ops.len].readAs(u32);
    const src_end = src_offset +% len;
    const dst_end = dst_idx +% len;
    if (src_end > seg.func_indices.len or dst_end > env.tables[ops.table_index].len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    for (0..len) |i| {
        env.tables[ops.table_index][dst_idx + i] = seg.func_indices[src_offset + i];
    }
    dispatch.next(ip, stride(encode.OpsTableInit), slots, frame, env, r0, fp0);
}

// ── elem_drop ────────────────────────────────────────────────────────────────

pub fn handle_elem_drop(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsElemDrop, ip);
    if (ops.segment_idx >= env.elem_segments.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    env.elem_segments_dropped[ops.segment_idx] = true;
    dispatch.next(ip, stride(encode.OpsElemDrop), slots, frame, env, r0, fp0);
}

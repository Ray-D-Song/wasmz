/// handlers_table.zig — M3 threaded-dispatch table instruction handlers
///
/// table_get, table_set, table_size, table_grow, table_fill, table_copy, table_init, elem_drop
const std = @import("std");
const ir = @import("../../compiler/ir.zig");
const encode = @import("../../compiler/encode/encode.zig");
const dispatch = @import("../dispatch.zig");
const core = @import("core");

const RawVal = dispatch.RawVal;
const Trap = dispatch.Trap;
const DispatchState = dispatch.DispatchState;
const ExecEnv = dispatch.ExecEnv;
const TableEntry = core.TableEntry;

const HANDLER_SIZE = dispatch.HANDLER_SIZE;

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

inline fn entryFromRefSlot(tbl: core.SharedTable, ref: u64, env: *const ExecEnv) TableEntry {
    if (ref == 0) return TableEntry.null_entry;
    if (tbl.elemType().eql(core.ValType.funcref())) {
        const fi = @as(u32, @intCast(ref - 1));
        const foreign = if (fi < env.foreign_funcs.len) &env.foreign_funcs[fi] else null;
        return TableEntry.fromFuncWithForeign(fi, env.instance_id, foreign);
    }
    return TableEntry.fromExternRef(ref);
}

// table_get

pub fn handle_table_get(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsTableGet, ip);
    if (ops.table_index >= env.tables.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    const tbl = env.tables[ops.table_index];
    const idx = slots[ops.index].readAs(u32);
    const entry = tbl.get(idx) orelse {
        trapReturn(frame, .TableOutOfBounds);
        return;
    };
    slots[ops.dst] = RawVal.fromBits64(entry.raw);
    dispatch.next(ip, stride(encode.ops.OpsTableGet), slots, frame, env, r0, fp0);
}

// table_set

pub fn handle_table_set(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsTableSet, ip);
    if (ops.table_index >= env.tables.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    const tbl = env.tables[ops.table_index];
    const idx = slots[ops.index].readAs(u32);
    const ref = slots[ops.value].readAs(u64);
    const entry = entryFromRefSlot(tbl, ref, env);
    if (!tbl.set(idx, entry)) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    dispatch.next(ip, stride(encode.ops.OpsTableSet), slots, frame, env, r0, fp0);
}

// table_size

pub fn handle_table_size(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsTableSize, ip);
    if (ops.table_index >= env.tables.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    const size: i32 = @intCast(env.tables[ops.table_index].len());
    slots[ops.dst] = RawVal.from(size);
    dispatch.next(ip, stride(encode.ops.OpsTableSize), slots, frame, env, r0, fp0);
}

// table_grow

pub fn handle_table_grow(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsTableGrow, ip);

    const result: i32 = blk: {
        if (ops.table_index >= env.tables.len) break :blk -1;
        const tbl = env.tables[ops.table_index];
        const delta = slots[ops.delta].readAs(u32);
        const init_ref = slots[ops.init].readAs(u64);
        const init_entry = entryFromRefSlot(tbl, init_ref, env);
        const old_len = tbl.grow(delta, init_entry) orelse break :blk -1;
        break :blk @intCast(old_len);
    };
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.ops.OpsTableGrow), slots, frame, env, r0, fp0);
}

// table_fill

pub fn handle_table_fill(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsTableFill, ip);
    if (ops.table_index >= env.tables.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    const tbl = env.tables[ops.table_index];
    const entries = tbl.inner.entries;
    const dst_idx = slots[ops.dst_idx].readAs(u32);
    const len = slots[ops.len].readAs(u32);
    const end = dst_idx +% len;
    if (end < dst_idx or end > entries.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    const ref = slots[ops.value].readAs(u64);
    const val = entryFromRefSlot(tbl, ref, env);
    @memset(entries[dst_idx..][0..len], val);
    tbl.inner.version +%= 1;
    dispatch.next(ip, stride(encode.ops.OpsTableFill), slots, frame, env, r0, fp0);
}

// table_copy

pub fn handle_table_copy(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsTableCopy, ip);
    if (ops.dst_table >= env.tables.len or ops.src_table >= env.tables.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    const dst_entries = env.tables[ops.dst_table].inner.entries;
    const src_entries = env.tables[ops.src_table].inner.entries;
    const dst_idx = slots[ops.dst_idx].readAs(u32);
    const src_idx = slots[ops.src_idx].readAs(u32);
    const len = slots[ops.len].readAs(u32);
    const src_end = src_idx +% len;
    const dst_end = dst_idx +% len;
    if (src_end < src_idx or dst_end < dst_idx or src_end > src_entries.len or dst_end > dst_entries.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    if (len > 0) {
        if (ops.dst_table == ops.src_table) {
            if (dst_idx < src_idx) {
                @memcpy(dst_entries[dst_idx..][0..len], src_entries[src_idx..][0..len]);
            } else if (dst_idx > src_idx) {
                var i: usize = len;
                while (i > 0) {
                    i -= 1;
                    dst_entries[dst_idx + i] = src_entries[src_idx + i];
                }
            }
        } else {
            @memcpy(dst_entries[dst_idx..][0..len], src_entries[src_idx..][0..len]);
        }
    }
    env.tables[ops.dst_table].inner.version +%= 1;
    dispatch.next(ip, stride(encode.ops.OpsTableCopy), slots, frame, env, r0, fp0);
}

// table_init

pub fn handle_table_init(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsTableInit, ip);
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
    const entries = env.tables[ops.table_index].inner.entries;
    const dst_idx = slots[ops.dst_idx].readAs(u32);
    const src_offset = slots[ops.src_offset].readAs(u32);
    const len = slots[ops.len].readAs(u32);
    const src_end = src_offset +% len;
    const dst_end = dst_idx +% len;
    if (src_end < src_offset or dst_end < dst_idx or src_end > seg.func_indices.len or dst_end > entries.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    for (0..len) |i| {
        const fi = seg.func_indices[src_offset + i];
        entries[dst_idx + i] = if (fi == std.math.maxInt(u32))
            TableEntry.null_entry
        else
            TableEntry.fromFuncWithForeign(fi, env.instance_id, if (fi < env.foreign_funcs.len) &env.foreign_funcs[fi] else null);
    }
    env.tables[ops.table_index].inner.version +%= 1;
    dispatch.next(ip, stride(encode.ops.OpsTableInit), slots, frame, env, r0, fp0);
}

// elem_drop

pub fn handle_elem_drop(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsElemDrop, ip);
    if (ops.segment_idx >= env.elem_segments.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    env.elem_segments_dropped[ops.segment_idx] = true;
    dispatch.next(ip, stride(encode.ops.OpsElemDrop), slots, frame, env, r0, fp0);
}

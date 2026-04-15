/// handlers_atomic.zig — M3 threaded-dispatch atomic instruction handlers
///
/// atomic_fence, atomic_load, atomic_store, atomic_rmw, atomic_cmpxchg,
/// atomic_notify, atomic_wait32, atomic_wait64
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

// ── atomic_fence ─────────────────────────────────────────────────────────────

pub fn handle_atomic_fence(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const Fence = struct {
        threadlocal var dummy: u8 = 0;
    };
    _ = @atomicRmw(u8, &Fence.dummy, .Or, 0, .seq_cst);
    dispatch.next(ip, stride(encode.OpsNone), slots, frame, env, r0, fp0);
}

// ── atomic_load ──────────────────────────────────────────────────────────────

pub fn handle_atomic_load(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsAtomicLoad, ip);
    const mem = env.memory.bytes();
    const width: ir.AtomicWidth = @enumFromInt(ops.width);
    const ty: ir.AtomicType = @enumFromInt(ops.ty);
    const access_size = width.byteSize();
    const base = slots[ops.addr].readAs(u32);
    const ea = base +% ops.offset;

    if (ea % access_size != 0) {
        trapReturn(frame, .UnalignedAtomicAccess);
        return;
    }
    if (@as(usize, ea) + access_size > mem.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }

    const raw_ptr: [*]u8 = mem.ptr + ea;
    const val: u64 = switch (width) {
        .@"8" => @atomicLoad(u8, @as(*u8, @ptrCast(raw_ptr)), .seq_cst),
        .@"16" => @atomicLoad(u16, @as(*u16, @ptrCast(@alignCast(raw_ptr))), .seq_cst),
        .@"32" => @atomicLoad(u32, @as(*u32, @ptrCast(@alignCast(raw_ptr))), .seq_cst),
        .@"64" => @atomicLoad(u64, @as(*u64, @ptrCast(@alignCast(raw_ptr))), .seq_cst),
    };
    slots[ops.dst] = switch (ty) {
        .i32 => RawVal.from(@as(i32, @bitCast(@as(u32, @truncate(val))))),
        .i64 => RawVal.from(@as(i64, @bitCast(val))),
    };
    dispatch.next(ip, stride(encode.OpsAtomicLoad), slots, frame, env, r0, fp0);
}

// ── atomic_store ─────────────────────────────────────────────────────────────

pub fn handle_atomic_store(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsAtomicStore, ip);
    const mem = env.memory.bytes();
    const width: ir.AtomicWidth = @enumFromInt(ops.width);
    const ty: ir.AtomicType = @enumFromInt(ops.ty);
    const access_size = width.byteSize();
    const base = slots[ops.addr].readAs(u32);
    const ea = base +% ops.offset;

    if (ea % access_size != 0) {
        trapReturn(frame, .UnalignedAtomicAccess);
        return;
    }
    if (@as(usize, ea) + access_size > mem.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }

    const raw_ptr: [*]u8 = mem.ptr + ea;
    const src_val: u64 = switch (ty) {
        .i32 => @as(u64, @as(u32, @bitCast(slots[ops.src].readAs(i32)))),
        .i64 => @as(u64, @bitCast(slots[ops.src].readAs(i64))),
    };
    switch (width) {
        .@"8" => @atomicStore(u8, @as(*u8, @ptrCast(raw_ptr)), @truncate(src_val), .seq_cst),
        .@"16" => @atomicStore(u16, @as(*u16, @ptrCast(@alignCast(raw_ptr))), @truncate(src_val), .seq_cst),
        .@"32" => @atomicStore(u32, @as(*u32, @ptrCast(@alignCast(raw_ptr))), @truncate(src_val), .seq_cst),
        .@"64" => @atomicStore(u64, @as(*u64, @ptrCast(@alignCast(raw_ptr))), src_val, .seq_cst),
    }
    dispatch.next(ip, stride(encode.OpsAtomicStore), slots, frame, env, r0, fp0);
}

// ── atomic_rmw ───────────────────────────────────────────────────────────────

pub fn handle_atomic_rmw(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsAtomicRmw, ip);
    const mem = env.memory.bytes();
    const width: ir.AtomicWidth = @enumFromInt(ops.width);
    const ty: ir.AtomicType = @enumFromInt(ops.ty);
    const rmw_op: ir.AtomicRmwOp = @enumFromInt(ops.op);
    const access_size = width.byteSize();
    const base = slots[ops.addr].readAs(u32);
    const ea = base +% ops.offset;

    if (ea % access_size != 0) {
        trapReturn(frame, .UnalignedAtomicAccess);
        return;
    }
    if (@as(usize, ea) + access_size > mem.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }

    const raw_ptr: [*]u8 = mem.ptr + ea;
    const src_val: u64 = switch (ty) {
        .i32 => @as(u64, @as(u32, @bitCast(slots[ops.src].readAs(i32)))),
        .i64 => @as(u64, @bitCast(slots[ops.src].readAs(i64))),
    };

    const old: u64 = switch (width) {
        .@"8" => blk: {
            const p = @as(*u8, @ptrCast(raw_ptr));
            const v: u8 = @truncate(src_val);
            break :blk switch (rmw_op) {
                .add => @atomicRmw(u8, p, .Add, v, .seq_cst),
                .sub => @atomicRmw(u8, p, .Sub, v, .seq_cst),
                .@"and" => @atomicRmw(u8, p, .And, v, .seq_cst),
                .@"or" => @atomicRmw(u8, p, .Or, v, .seq_cst),
                .xor => @atomicRmw(u8, p, .Xor, v, .seq_cst),
                .xchg => @atomicRmw(u8, p, .Xchg, v, .seq_cst),
            };
        },
        .@"16" => blk: {
            const p = @as(*u16, @ptrCast(@alignCast(raw_ptr)));
            const v: u16 = @truncate(src_val);
            break :blk switch (rmw_op) {
                .add => @atomicRmw(u16, p, .Add, v, .seq_cst),
                .sub => @atomicRmw(u16, p, .Sub, v, .seq_cst),
                .@"and" => @atomicRmw(u16, p, .And, v, .seq_cst),
                .@"or" => @atomicRmw(u16, p, .Or, v, .seq_cst),
                .xor => @atomicRmw(u16, p, .Xor, v, .seq_cst),
                .xchg => @atomicRmw(u16, p, .Xchg, v, .seq_cst),
            };
        },
        .@"32" => blk: {
            const p = @as(*u32, @ptrCast(@alignCast(raw_ptr)));
            const v: u32 = @truncate(src_val);
            break :blk switch (rmw_op) {
                .add => @atomicRmw(u32, p, .Add, v, .seq_cst),
                .sub => @atomicRmw(u32, p, .Sub, v, .seq_cst),
                .@"and" => @atomicRmw(u32, p, .And, v, .seq_cst),
                .@"or" => @atomicRmw(u32, p, .Or, v, .seq_cst),
                .xor => @atomicRmw(u32, p, .Xor, v, .seq_cst),
                .xchg => @atomicRmw(u32, p, .Xchg, v, .seq_cst),
            };
        },
        .@"64" => blk: {
            const p = @as(*u64, @ptrCast(@alignCast(raw_ptr)));
            break :blk switch (rmw_op) {
                .add => @atomicRmw(u64, p, .Add, src_val, .seq_cst),
                .sub => @atomicRmw(u64, p, .Sub, src_val, .seq_cst),
                .@"and" => @atomicRmw(u64, p, .And, src_val, .seq_cst),
                .@"or" => @atomicRmw(u64, p, .Or, src_val, .seq_cst),
                .xor => @atomicRmw(u64, p, .Xor, src_val, .seq_cst),
                .xchg => @atomicRmw(u64, p, .Xchg, src_val, .seq_cst),
            };
        },
    };
    slots[ops.dst] = switch (ty) {
        .i32 => RawVal.from(@as(i32, @bitCast(@as(u32, @truncate(old))))),
        .i64 => RawVal.from(@as(i64, @bitCast(old))),
    };
    dispatch.next(ip, stride(encode.OpsAtomicRmw), slots, frame, env, r0, fp0);
}

// ── atomic_cmpxchg ───────────────────────────────────────────────────────────

pub fn handle_atomic_cmpxchg(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsAtomicCmpxchg, ip);
    const mem = env.memory.bytes();
    const width: ir.AtomicWidth = @enumFromInt(ops.width);
    const ty: ir.AtomicType = @enumFromInt(ops.ty);
    const access_size = width.byteSize();
    const base = slots[ops.addr].readAs(u32);
    const ea = base +% ops.offset;

    if (ea % access_size != 0) {
        trapReturn(frame, .UnalignedAtomicAccess);
        return;
    }
    if (@as(usize, ea) + access_size > mem.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }

    const raw_ptr: [*]u8 = mem.ptr + ea;
    const exp_val: u64 = switch (ty) {
        .i32 => @as(u64, @as(u32, @bitCast(slots[ops.expected].readAs(i32)))),
        .i64 => @as(u64, @bitCast(slots[ops.expected].readAs(i64))),
    };
    const rep_val: u64 = switch (ty) {
        .i32 => @as(u64, @as(u32, @bitCast(slots[ops.replacement].readAs(i32)))),
        .i64 => @as(u64, @bitCast(slots[ops.replacement].readAs(i64))),
    };

    const old: u64 = switch (width) {
        .@"8" => blk: {
            const p = @as(*u8, @ptrCast(raw_ptr));
            const e: u8 = @truncate(exp_val);
            const r: u8 = @truncate(rep_val);
            const result = @cmpxchgStrong(u8, p, e, r, .seq_cst, .seq_cst);
            break :blk result orelse e;
        },
        .@"16" => blk: {
            const p = @as(*u16, @ptrCast(@alignCast(raw_ptr)));
            const e: u16 = @truncate(exp_val);
            const r: u16 = @truncate(rep_val);
            const result = @cmpxchgStrong(u16, p, e, r, .seq_cst, .seq_cst);
            break :blk result orelse e;
        },
        .@"32" => blk: {
            const p = @as(*u32, @ptrCast(@alignCast(raw_ptr)));
            const e: u32 = @truncate(exp_val);
            const r: u32 = @truncate(rep_val);
            const result = @cmpxchgStrong(u32, p, e, r, .seq_cst, .seq_cst);
            break :blk result orelse e;
        },
        .@"64" => blk: {
            const p = @as(*u64, @ptrCast(@alignCast(raw_ptr)));
            const result = @cmpxchgStrong(u64, p, exp_val, rep_val, .seq_cst, .seq_cst);
            break :blk result orelse exp_val;
        },
    };
    slots[ops.dst] = switch (ty) {
        .i32 => RawVal.from(@as(i32, @bitCast(@as(u32, @truncate(old))))),
        .i64 => RawVal.from(@as(i64, @bitCast(old))),
    };
    dispatch.next(ip, stride(encode.OpsAtomicCmpxchg), slots, frame, env, r0, fp0);
}

// ── atomic_notify ────────────────────────────────────────────────────────────

pub fn handle_atomic_notify(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsAtomicNotify, ip);
    const mem = env.memory.bytes();
    const base = slots[ops.addr].readAs(u32);
    const ea = base +% ops.offset;

    if (ea % 4 != 0) {
        trapReturn(frame, .UnalignedAtomicAccess);
        return;
    }
    if (@as(usize, ea) + 4 > mem.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }

    const count = @as(u32, @bitCast(slots[ops.count].readAs(i32)));
    const woken = env.memory.notify(ea, count);
    slots[ops.dst] = RawVal.from(@as(i32, @bitCast(woken)));
    dispatch.next(ip, stride(encode.OpsAtomicNotify), slots, frame, env, r0, fp0);
}

// ── atomic_wait32 ────────────────────────────────────────────────────────────

pub fn handle_atomic_wait32(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsAtomicWait32, ip);

    if (!env.memory.isShared()) {
        trapReturn(frame, .UnsharedMemoryWait);
        return;
    }

    const mem = env.memory.bytes();
    const base = slots[ops.addr].readAs(u32);
    const ea = base +% ops.offset;

    if (ea % 4 != 0) {
        trapReturn(frame, .UnalignedAtomicAccess);
        return;
    }
    if (@as(usize, ea) + 4 > mem.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }

    const expected = @as(u32, @bitCast(slots[ops.expected].readAs(i32)));
    const timeout_ns = slots[ops.timeout].readAs(i64);
    const result = env.memory.wait32(ea, expected, timeout_ns);
    slots[ops.dst] = RawVal.from(@as(i32, @intFromEnum(result)));
    dispatch.next(ip, stride(encode.OpsAtomicWait32), slots, frame, env, r0, fp0);
}

// ── atomic_wait64 ────────────────────────────────────────────────────────────

pub fn handle_atomic_wait64(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsAtomicWait64, ip);

    if (!env.memory.isShared()) {
        trapReturn(frame, .UnsharedMemoryWait);
        return;
    }

    const mem = env.memory.bytes();
    const base = slots[ops.addr].readAs(u32);
    const ea = base +% ops.offset;

    if (ea % 8 != 0) {
        trapReturn(frame, .UnalignedAtomicAccess);
        return;
    }
    if (@as(usize, ea) + 8 > mem.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }

    const expected = @as(u64, @bitCast(slots[ops.expected].readAs(i64)));
    const timeout_ns = slots[ops.timeout].readAs(i64);
    const result = env.memory.wait64(ea, expected, timeout_ns);
    slots[ops.dst] = RawVal.from(@as(i32, @intFromEnum(result)));
    dispatch.next(ip, stride(encode.OpsAtomicWait64), slots, frame, env, r0, fp0);
}

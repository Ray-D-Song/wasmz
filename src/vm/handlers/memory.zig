/// memory.zig — memory and bulk-memory instruction handlers
const std = @import("std");
const builtin = @import("builtin");
const encode = @import("../../compiler/encode/encode.zig");
const dispatch = @import("../dispatch.zig");
const core = @import("core");
const common = @import("common.zig");
const profiling = @import("../../utils/profiling.zig");

const RawVal = dispatch.RawVal;
const Trap = dispatch.Trap;
const DispatchState = dispatch.DispatchState;
const ExecEnv = dispatch.ExecEnv;

const readOps = common.readOps;
const stride = common.stride;
const trapReturn = common.trapReturn;
const effectiveAddr = common.effectiveAddr;
const currentRssBytes = profiling.currentRssBytes;


inline fn nextAfterI32Load(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, fp0: f64, val: i32) void {
    dispatch.next(ip, stride(encode.ops.OpsLoad), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(val)))), fp0);
}

inline fn nextAfterI64Load(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, fp0: f64, val: i64) void {
    dispatch.next(ip, stride(encode.ops.OpsLoad), slots, frame, env, @as(u64, @bitCast(val)), fp0);
}

inline fn nextAfterF32Load(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, val: f32) void {
    dispatch.next(ip, stride(encode.ops.OpsLoad), slots, frame, env, r0, @as(f64, @floatCast(val)));
}

inline fn nextAfterF64Load(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, val: f64) void {
    dispatch.next(ip, stride(encode.ops.OpsLoad), slots, frame, env, r0, val);
}

// Memory Loads

pub fn handle_i32_load(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
        _ = r0;
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const val = std.mem.readInt(i32, memory[ea..][0..4], .little);
    slots[ops.dst] = RawVal.from(val);
    nextAfterI32Load(ip, slots, frame, env, fp0, val);
}

pub fn handle_i32_load8_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
        _ = r0;
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 1, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const val = @as(i32, @as(i8, @bitCast(memory[ea])));
    slots[ops.dst] = RawVal.from(val);
    nextAfterI32Load(ip, slots, frame, env, fp0, val);
}

pub fn handle_i32_load8_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
        _ = r0;
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 1, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const val = @as(i32, memory[ea]);
    slots[ops.dst] = RawVal.from(val);
    nextAfterI32Load(ip, slots, frame, env, fp0, val);
}

pub fn handle_i32_load16_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
        _ = r0;
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 2, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const half: i16 = @bitCast(std.mem.readInt(u16, memory[ea..][0..2], .little));
    const val = @as(i32, half);
    slots[ops.dst] = RawVal.from(val);
    nextAfterI32Load(ip, slots, frame, env, fp0, val);
}

pub fn handle_i32_load16_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
        _ = r0;
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 2, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const val = @as(i32, std.mem.readInt(u16, memory[ea..][0..2], .little));
    slots[ops.dst] = RawVal.from(val);
    nextAfterI32Load(ip, slots, frame, env, fp0, val);
}

pub fn handle_i64_load(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
        _ = r0;
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 8, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const val = std.mem.readInt(i64, memory[ea..][0..8], .little);
    slots[ops.dst] = RawVal.from(val);
    nextAfterI64Load(ip, slots, frame, env, fp0, val);
}

pub fn handle_i64_load8_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
        _ = r0;
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 1, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const val = @as(i64, @as(i8, @bitCast(memory[ea])));
    slots[ops.dst] = RawVal.from(val);
    nextAfterI64Load(ip, slots, frame, env, fp0, val);
}

pub fn handle_i64_load8_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
        _ = r0;
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 1, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const val = @as(i64, memory[ea]);
    slots[ops.dst] = RawVal.from(val);
    nextAfterI64Load(ip, slots, frame, env, fp0, val);
}

pub fn handle_i64_load16_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
        _ = r0;
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 2, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const half: i16 = @bitCast(std.mem.readInt(u16, memory[ea..][0..2], .little));
    const val = @as(i64, half);
    slots[ops.dst] = RawVal.from(val);
    nextAfterI64Load(ip, slots, frame, env, fp0, val);
}

pub fn handle_i64_load16_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
        _ = r0;
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 2, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const val = @as(i64, std.mem.readInt(u16, memory[ea..][0..2], .little));
    slots[ops.dst] = RawVal.from(val);
    nextAfterI64Load(ip, slots, frame, env, fp0, val);
}

pub fn handle_i64_load32_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
        _ = r0;
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const word: i32 = @bitCast(std.mem.readInt(u32, memory[ea..][0..4], .little));
    const val = @as(i64, word);
    slots[ops.dst] = RawVal.from(val);
    nextAfterI64Load(ip, slots, frame, env, fp0, val);
}

pub fn handle_i64_load32_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
        _ = r0;
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const val = @as(i64, std.mem.readInt(u32, memory[ea..][0..4], .little));
    slots[ops.dst] = RawVal.from(val);
    nextAfterI64Load(ip, slots, frame, env, fp0, val);
}

pub fn handle_f32_load(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
        _ = fp0;
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const bits = std.mem.readInt(u32, memory[ea..][0..4], .little);
    const val: f32 = @bitCast(bits);
    slots[ops.dst] = RawVal.from(val);
    nextAfterF32Load(ip, slots, frame, env, r0, val);
}

pub fn handle_f64_load(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
        _ = fp0;
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 8, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const bits = std.mem.readInt(u64, memory[ea..][0..8], .little);
    const val: f64 = @bitCast(bits);
    slots[ops.dst] = RawVal.from(val);
    nextAfterF64Load(ip, slots, frame, env, r0, val);
}

// Memory Stores

pub fn handle_i32_store(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsStore, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(i32, memory[ea..][0..4], slots[ops.src].readAs(i32), .little);
    dispatch.next(ip, stride(encode.ops.OpsStore), slots, frame, env, r0, fp0);
}

pub fn handle_i32_store8(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsStore, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 1, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    memory[ea] = @truncate(@as(u32, @bitCast(slots[ops.src].readAs(i32))));
    dispatch.next(ip, stride(encode.ops.OpsStore), slots, frame, env, r0, fp0);
}

pub fn handle_i32_store16(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsStore, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 2, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(u16, memory[ea..][0..2], @truncate(@as(u32, @bitCast(slots[ops.src].readAs(i32)))), .little);
    dispatch.next(ip, stride(encode.ops.OpsStore), slots, frame, env, r0, fp0);
}

pub fn handle_i64_store(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsStore, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 8, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(i64, memory[ea..][0..8], slots[ops.src].readAs(i64), .little);
    dispatch.next(ip, stride(encode.ops.OpsStore), slots, frame, env, r0, fp0);
}

pub fn handle_i64_store8(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsStore, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 1, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    memory[ea] = @truncate(@as(u64, @bitCast(slots[ops.src].readAs(i64))));
    dispatch.next(ip, stride(encode.ops.OpsStore), slots, frame, env, r0, fp0);
}

pub fn handle_i64_store16(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsStore, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 2, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(u16, memory[ea..][0..2], @truncate(@as(u64, @bitCast(slots[ops.src].readAs(i64)))), .little);
    dispatch.next(ip, stride(encode.ops.OpsStore), slots, frame, env, r0, fp0);
}

pub fn handle_i64_store32(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsStore, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(u32, memory[ea..][0..4], @truncate(@as(u64, @bitCast(slots[ops.src].readAs(i64)))), .little);
    dispatch.next(ip, stride(encode.ops.OpsStore), slots, frame, env, r0, fp0);
}

pub fn handle_f32_store(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsStore, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(u32, memory[ea..][0..4], @as(u32, @bitCast(slots[ops.src].readAs(f32))), .little);
    dispatch.next(ip, stride(encode.ops.OpsStore), slots, frame, env, r0, fp0);
}

pub fn handle_f64_store(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsStore, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 8, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(u64, memory[ea..][0..8], @as(u64, @bitCast(slots[ops.src].readAs(f64))), .little);
    dispatch.next(ip, stride(encode.ops.OpsStore), slots, frame, env, r0, fp0);
}

// Bulk Memory

pub fn handle_memory_size(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsMemorySize, ip);
    const page_count = env.memory.pageCount();
    if (frame.memory64) {
        slots[ops.dst] = RawVal.from(@as(i64, @intCast(page_count)));
    } else {
        slots[ops.dst] = RawVal.from(@as(i32, @intCast(page_count)));
    }
    dispatch.next(ip, stride(encode.ops.OpsMemorySize), slots, frame, env, r0, fp0);
}

pub fn handle_memory_grow(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsMemoryGrow, ip);
    const delta: u64 = if (frame.memory64)
        @bitCast(slots[ops.delta].readAs(i64))
    else
        @intCast(@as(u32, @bitCast(slots[ops.delta].readAs(i32))));
    if (delta > 0) {
        if (env.memory_budget) |b| {
            const additional_bytes = delta * core.WASM_PAGE_SIZE;
            if (!b.canGrow(additional_bytes)) {
                if (frame.memory64) {
                    slots[ops.dst] = RawVal.from(@as(i64, -1));
                } else {
                    slots[ops.dst] = RawVal.from(@as(i32, -1));
                }
                dispatch.next(ip, stride(encode.ops.OpsMemoryGrow), slots, frame, env, r0, fp0);
                return;
            }
        }
    }
    const old_byte_len = env.memory.byteLen();
    const rss_before = if (env.mem_trace and delta > 0) currentRssBytes() else 0;
    const old = env.memory.grow(delta);
    if (frame.memory64) {
        const result: i64 = if (old == std.math.maxInt(u64)) -1 else @intCast(old);
        slots[ops.dst] = RawVal.from(result);
    } else {
        const result: i32 = if (old == std.math.maxInt(u64)) -1 else @intCast(@as(u32, @truncate(old)));
        slots[ops.dst] = RawVal.from(result);
    }
    if (old != std.math.maxInt(u64)) {
        // Refresh cached mem_base/mem_len after successful grow.
        frame.refreshMemCache(env.memory);
        if (env.memory_budget) |b| {
            b.recordLinearGrow(env.memory.byteLen());
        }
        // mem-trace probe: log every successful memory.grow
        if (env.mem_trace and delta > 0) {
            if (!builtin.single_threaded) {
                const new_byte_len = env.memory.byteLen();
                const rss_after = currentRssBytes();
                const mb = struct {
                    fn f(b: usize) f64 {
                        return @as(f64, @floatFromInt(b)) / (1024.0 * 1024.0);
                    }
                }.f;
                std.debug.print(
                    "[mem-trace] memory.grow +{d} pages  linear {d:.1} -> {d:.1} MB  RSS {d:.1} -> {d:.1} MB (realloc {s}{d:.1} MB)\n",
                    .{
                        delta,
                        mb(old_byte_len),
                        mb(new_byte_len),
                        mb(rss_before),
                        mb(rss_after),
                        if (rss_after >= rss_before) "+" else "-",
                        if (rss_after >= rss_before) mb(rss_after - rss_before) else mb(rss_before - rss_after),
                    },
                );
            }
        }
    }
    dispatch.next(ip, stride(encode.ops.OpsMemoryGrow), slots, frame, env, r0, fp0);
}

pub fn handle_memory_init(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsMemoryInit, ip);
    const memory = frame.memSlice();
    const len = slots[ops.len].readAs(u32);
    const dst_ea = effectiveAddr(slots, ops.dst_addr, 0, len, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const src_offset: u64 = if (frame.memory64)
        @bitCast(slots[ops.src_offset].readAs(i64))
    else
        slots[ops.src_offset].readAs(u32);

    if (ops.segment_idx >= env.data_segments.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }
    if (env.data_segments_dropped[ops.segment_idx]) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }

    const segment = env.data_segments[ops.segment_idx];
    const src_end = std.math.add(u64, src_offset, @as(u64, len)) catch {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    if (src_end > segment.data.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }
    @memcpy(memory[dst_ea..][0..len], segment.data[@intCast(src_offset)..][0..len]);
    dispatch.next(ip, stride(encode.ops.OpsMemoryInit), slots, frame, env, r0, fp0);
}

pub fn handle_data_drop(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsDataDrop, ip);
    if (ops.segment_idx >= env.data_segments.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }
    env.data_segments_dropped[ops.segment_idx] = true;
    dispatch.next(ip, stride(encode.ops.OpsDataDrop), slots, frame, env, r0, fp0);
}

pub fn handle_memory_copy(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsMemoryCopy, ip);
    const memory = frame.memSlice();
    const len = slots[ops.len].readAs(u32);
    const dst_ea = effectiveAddr(slots, ops.dst_addr, 0, len, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const src_ea = effectiveAddr(slots, ops.src_addr, 0, len, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    if (len > 0) {
        // memory.copy allows overlapping src/dst ranges, so this must be a
        // memmove, not a memcpy. `@memmove` lowers to the target's optimized
        // memmove (SIMD/ERMS on x86, etc.); the old copyForwards/copyBackwards
        // manual byte loops were an order of magnitude slower for this
        // benchmark's overlapping-copy pattern.
        @memmove(memory[dst_ea .. dst_ea + len], memory[src_ea .. src_ea + len]);
    }
    dispatch.next(ip, stride(encode.ops.OpsMemoryCopy), slots, frame, env, r0, fp0);
}

pub fn handle_memory_fill(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(dispatch.HandlerCallConv) void {
    const ops = readOps(encode.ops.OpsMemoryFill, ip);
    const memory = frame.memSlice();
    const value = slots[ops.value].readAs(u32);
    const len = slots[ops.len].readAs(u32);
    const dst_ea = effectiveAddr(slots, ops.dst_addr, 0, len, memory, frame.memory64) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    @memset(memory[dst_ea .. dst_ea + len], @truncate(value));
    dispatch.next(ip, stride(encode.ops.OpsMemoryFill), slots, frame, env, r0, fp0);
}

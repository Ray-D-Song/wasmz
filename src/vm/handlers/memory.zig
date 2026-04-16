/// memory.zig — memory and bulk-memory instruction handlers
const std = @import("std");
const encode = @import("../../compiler/encode/encode.zig");
const dispatch = @import("../dispatch.zig");
const core = @import("core");
const common = @import("common.zig");

const RawVal = dispatch.RawVal;
const Trap = dispatch.Trap;
const DispatchState = dispatch.DispatchState;
const ExecEnv = dispatch.ExecEnv;

const readOps = common.readOps;
const stride = common.stride;
const trapReturn = common.trapReturn;
const effectiveAddr = common.effectiveAddr;
const currentRssBytes = common.currentRssBytes;

// ── Memory Loads ────────────────────────────────────────────────────────────

pub fn handle_i32_load(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.dst] = RawVal.from(std.mem.readInt(i32, memory[ea..][0..4], .little));
    dispatch.next(ip, stride(encode.ops.OpsLoad), slots, frame, env, r0, fp0);
}

pub fn handle_i32_load8_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 1, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i32, @as(i8, @bitCast(memory[ea]))));
    dispatch.next(ip, stride(encode.ops.OpsLoad), slots, frame, env, r0, fp0);
}

pub fn handle_i32_load8_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 1, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i32, memory[ea]));
    dispatch.next(ip, stride(encode.ops.OpsLoad), slots, frame, env, r0, fp0);
}

pub fn handle_i32_load16_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 2, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const half: i16 = @bitCast(std.mem.readInt(u16, memory[ea..][0..2], .little));
    slots[ops.dst] = RawVal.from(@as(i32, half));
    dispatch.next(ip, stride(encode.ops.OpsLoad), slots, frame, env, r0, fp0);
}

pub fn handle_i32_load16_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 2, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i32, std.mem.readInt(u16, memory[ea..][0..2], .little)));
    dispatch.next(ip, stride(encode.ops.OpsLoad), slots, frame, env, r0, fp0);
}

pub fn handle_i64_load(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 8, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.dst] = RawVal.from(std.mem.readInt(i64, memory[ea..][0..8], .little));
    dispatch.next(ip, stride(encode.ops.OpsLoad), slots, frame, env, r0, fp0);
}

pub fn handle_i64_load8_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 1, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i64, @as(i8, @bitCast(memory[ea]))));
    dispatch.next(ip, stride(encode.ops.OpsLoad), slots, frame, env, r0, fp0);
}

pub fn handle_i64_load8_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 1, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i64, memory[ea]));
    dispatch.next(ip, stride(encode.ops.OpsLoad), slots, frame, env, r0, fp0);
}

pub fn handle_i64_load16_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 2, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const half: i16 = @bitCast(std.mem.readInt(u16, memory[ea..][0..2], .little));
    slots[ops.dst] = RawVal.from(@as(i64, half));
    dispatch.next(ip, stride(encode.ops.OpsLoad), slots, frame, env, r0, fp0);
}

pub fn handle_i64_load16_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 2, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i64, std.mem.readInt(u16, memory[ea..][0..2], .little)));
    dispatch.next(ip, stride(encode.ops.OpsLoad), slots, frame, env, r0, fp0);
}

pub fn handle_i64_load32_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const word: i32 = @bitCast(std.mem.readInt(u32, memory[ea..][0..4], .little));
    slots[ops.dst] = RawVal.from(@as(i64, word));
    dispatch.next(ip, stride(encode.ops.OpsLoad), slots, frame, env, r0, fp0);
}

pub fn handle_i64_load32_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i64, std.mem.readInt(u32, memory[ea..][0..4], .little)));
    dispatch.next(ip, stride(encode.ops.OpsLoad), slots, frame, env, r0, fp0);
}

pub fn handle_f32_load(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const bits = std.mem.readInt(u32, memory[ea..][0..4], .little);
    slots[ops.dst] = RawVal.from(@as(f32, @bitCast(bits)));
    dispatch.next(ip, stride(encode.ops.OpsLoad), slots, frame, env, r0, fp0);
}

pub fn handle_f64_load(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsLoad, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 8, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const bits = std.mem.readInt(u64, memory[ea..][0..8], .little);
    slots[ops.dst] = RawVal.from(@as(f64, @bitCast(bits)));
    dispatch.next(ip, stride(encode.ops.OpsLoad), slots, frame, env, r0, fp0);
}

// ── Memory Stores ───────────────────────────────────────────────────────────

pub fn handle_i32_store(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsStore, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(i32, memory[ea..][0..4], slots[ops.src].readAs(i32), .little);
    dispatch.next(ip, stride(encode.ops.OpsStore), slots, frame, env, r0, fp0);
}

pub fn handle_i32_store8(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsStore, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 1, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    memory[ea] = @truncate(@as(u32, @bitCast(slots[ops.src].readAs(i32))));
    dispatch.next(ip, stride(encode.ops.OpsStore), slots, frame, env, r0, fp0);
}

pub fn handle_i32_store16(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsStore, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 2, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(u16, memory[ea..][0..2], @truncate(@as(u32, @bitCast(slots[ops.src].readAs(i32)))), .little);
    dispatch.next(ip, stride(encode.ops.OpsStore), slots, frame, env, r0, fp0);
}

pub fn handle_i64_store(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsStore, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 8, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(i64, memory[ea..][0..8], slots[ops.src].readAs(i64), .little);
    dispatch.next(ip, stride(encode.ops.OpsStore), slots, frame, env, r0, fp0);
}

pub fn handle_i64_store8(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsStore, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 1, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    memory[ea] = @truncate(@as(u64, @bitCast(slots[ops.src].readAs(i64))));
    dispatch.next(ip, stride(encode.ops.OpsStore), slots, frame, env, r0, fp0);
}

pub fn handle_i64_store16(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsStore, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 2, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(u16, memory[ea..][0..2], @truncate(@as(u64, @bitCast(slots[ops.src].readAs(i64)))), .little);
    dispatch.next(ip, stride(encode.ops.OpsStore), slots, frame, env, r0, fp0);
}

pub fn handle_i64_store32(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsStore, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(u32, memory[ea..][0..4], @truncate(@as(u64, @bitCast(slots[ops.src].readAs(i64)))), .little);
    dispatch.next(ip, stride(encode.ops.OpsStore), slots, frame, env, r0, fp0);
}

pub fn handle_f32_store(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsStore, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(u32, memory[ea..][0..4], @as(u32, @bitCast(slots[ops.src].readAs(f32))), .little);
    dispatch.next(ip, stride(encode.ops.OpsStore), slots, frame, env, r0, fp0);
}

pub fn handle_f64_store(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsStore, ip);
    const memory = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 8, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(u64, memory[ea..][0..8], @as(u64, @bitCast(slots[ops.src].readAs(f64))), .little);
    dispatch.next(ip, stride(encode.ops.OpsStore), slots, frame, env, r0, fp0);
}

// ── Bulk Memory ─────────────────────────────────────────────────────────────

pub fn handle_memory_size(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsMemorySize, ip);
    const page_count: i32 = @intCast(env.memory.pageCount());
    slots[ops.dst] = RawVal.from(page_count);
    dispatch.next(ip, stride(encode.ops.OpsMemorySize), slots, frame, env, r0, fp0);
}

pub fn handle_memory_grow(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsMemoryGrow, ip);
    const delta = @as(u32, @bitCast(slots[ops.delta].readAs(i32)));
    if (delta > 0) {
        if (env.memory_budget) |b| {
            const additional_bytes = @as(u64, delta) * core.WASM_PAGE_SIZE;
            if (!b.canGrow(additional_bytes)) {
                slots[ops.dst] = RawVal.from(@as(i32, -1));
                dispatch.next(ip, stride(encode.ops.OpsMemoryGrow), slots, frame, env, r0, fp0);
                return;
            }
        }
    }
    const old_byte_len = env.memory.byteLen();
    const rss_before = if (env.mem_trace and delta > 0) currentRssBytes() else 0;
    const old = env.memory.grow(delta);
    const result: i32 = if (old == std.math.maxInt(u32)) -1 else @intCast(old);
    slots[ops.dst] = RawVal.from(result);
    if (result != -1) {
        // Refresh cached mem_base/mem_len after successful grow.
        frame.refreshMemCache(env.memory);
        if (env.memory_budget) |b| {
            b.recordLinearGrow(env.memory.byteLen());
        }
        // ── mem-trace probe: log every successful memory.grow ─────────────
        if (env.mem_trace and delta > 0) {
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
    dispatch.next(ip, stride(encode.ops.OpsMemoryGrow), slots, frame, env, r0, fp0);
}

pub fn handle_memory_init(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsMemoryInit, ip);
    const memory = frame.memSlice();
    const dst_addr = slots[ops.dst_addr].readAs(u32);
    const src_offset = slots[ops.src_offset].readAs(u32);
    const len = slots[ops.len].readAs(u32);

    if (ops.segment_idx >= env.data_segments.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }
    if (env.data_segments_dropped[ops.segment_idx]) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }

    const segment = env.data_segments[ops.segment_idx];
    const src_end = src_offset +% len;
    const dst_end = dst_addr +% len;
    if (src_end > segment.data.len or dst_end > memory.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }
    @memcpy(memory[dst_addr..][0..len], segment.data[src_offset..][0..len]);
    dispatch.next(ip, stride(encode.ops.OpsMemoryInit), slots, frame, env, r0, fp0);
}

pub fn handle_data_drop(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsDataDrop, ip);
    if (ops.segment_idx >= env.data_segments.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }
    env.data_segments_dropped[ops.segment_idx] = true;
    dispatch.next(ip, stride(encode.ops.OpsDataDrop), slots, frame, env, r0, fp0);
}

pub fn handle_memory_copy(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsMemoryCopy, ip);
    const memory = frame.memSlice();
    const dst_addr = slots[ops.dst_addr].readAs(u32);
    const src_addr = slots[ops.src_addr].readAs(u32);
    const len = slots[ops.len].readAs(u32);

    const src_end = src_addr +% len;
    const dst_end = dst_addr +% len;
    if (src_end > memory.len or dst_end > memory.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }
    if (len > 0) {
        if (dst_addr <= src_addr) {
            std.mem.copyForwards(u8, memory[dst_addr .. dst_addr + len], memory[src_addr .. src_addr + len]);
        } else {
            std.mem.copyBackwards(u8, memory[dst_addr .. dst_addr + len], memory[src_addr .. src_addr + len]);
        }
    }
    dispatch.next(ip, stride(encode.ops.OpsMemoryCopy), slots, frame, env, r0, fp0);
}

pub fn handle_memory_fill(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.ops.OpsMemoryFill, ip);
    const memory = frame.memSlice();
    const dst_addr = slots[ops.dst_addr].readAs(u32);
    const value = slots[ops.value].readAs(u32);
    const len = slots[ops.len].readAs(u32);

    const dst_end = dst_addr +% len;
    if (dst_end > memory.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }
    @memset(memory[dst_addr .. dst_addr + len], @truncate(value));
    dispatch.next(ip, stride(encode.ops.OpsMemoryFill), slots, frame, env, r0, fp0);
}

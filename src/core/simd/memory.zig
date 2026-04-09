// SIMD memory load/store operations.
//
// Handles plain v128.load/store, widening loads, splat loads, zero-extending
// loads, and lane loads/stores.  All helpers operate on V128 (no RawVal
// dependency -- the exec layer does the RawVal <-> V128 conversion).
const std = @import("std");
const ops = @import("ops.zig");
const classify = @import("classify.zig");

const V128 = ops.V128;
const SimdOpcode = classify.SimdOpcode;

/// Loads a V128 value from linear memory. Handles plain v128.load, widening loads
/// (e.g. i16x8.load8x8_s), splat loads, zero-extending loads, and lane loads.
/// `ea` = addr +% offset (wrapping add per wasm spec).
/// `src_vec` is passed as ?V128 (the exec layer converts from RawVal).
pub fn load(opcode: SimdOpcode, memory: []const u8, addr: u32, offset: u32, lane: ?u8, src_vec: ?V128) V128 {
    const ea = addr +% offset;
    return switch (opcode) {
        .v128_load => blk: {
            var out: [16]u8 = undefined;
            @memcpy(out[0..], memory[ea .. ea + 16]);
            break :blk ops.v128FromBytes(out);
        },
        .i16x8_load8x8_s => wideningLoad(i8, i16, 8, memory[ea .. ea + 8], true),
        .i16x8_load8x8_u => wideningLoad(u8, i16, 8, memory[ea .. ea + 8], false),
        .i32x4_load16x4_s => wideningLoad(i16, i32, 4, memory[ea .. ea + 8], true),
        .i32x4_load16x4_u => wideningLoad(u16, i32, 4, memory[ea .. ea + 8], false),
        .i64x2_load32x2_s => wideningLoad(i32, i64, 2, memory[ea .. ea + 8], true),
        .i64x2_load32x2_u => wideningLoad(u32, i64, 2, memory[ea .. ea + 8], false),
        .v8x16_load_splat => loadSplat(u8, i8, 16, memory[ea .. ea + 1]),
        .v16x8_load_splat => loadSplat(u16, i16, 8, memory[ea .. ea + 2]),
        .v32x4_load_splat => loadSplat(u32, i32, 4, memory[ea .. ea + 4]),
        .v64x2_load_splat => loadSplat(u64, i64, 2, memory[ea .. ea + 8]),
        // Fix 8: removed unused T and width parameters from loadZeroExtended
        .v128_load32_zero => loadZeroExtended(memory[ea .. ea + 4]),
        .v128_load64_zero => loadZeroExtended(memory[ea .. ea + 8]),
        .v128_load8_lane, .v128_load16_lane, .v128_load32_lane, .v128_load64_lane => loadLane(opcode, src_vec.?, memory[ea .. ea + classify.laneImmediateFromOpcode(opcode)], lane.?),
        else => unreachable,
    };
}

/// Stores a V128 value (or a single lane) to linear memory.
/// `src` is passed as V128 (the exec layer converts from RawVal).
pub fn store(opcode: SimdOpcode, memory: []u8, addr: u32, offset: u32, lane: ?u8, src: V128) void {
    const ea = addr +% offset;
    switch (opcode) {
        .v128_store => {
            const bytes = src.bytes;
            @memcpy(memory[ea .. ea + 16], bytes[0..]);
        },
        .v128_store8_lane, .v128_store16_lane, .v128_store32_lane, .v128_store64_lane => {
            const bytes = laneBytes(src, lane.?, classify.laneImmediateFromOpcode(opcode));
            @memcpy(memory[ea .. ea + bytes.len], bytes[0..]);
        },
        else => unreachable,
    }
}

/// Widening load: reads N narrow values from memory and widens each into a
/// wider lane type (e.g. load 8 i8 values -> i16x8).
fn wideningLoad(comptime SrcT: type, comptime DstT: type, comptime N: usize, slice: []const u8, comptime signed: bool) V128 {
    var out = std.mem.zeroes([16]u8);
    var tmp = std.mem.zeroes([16]u8);
    @memcpy(tmp[0..slice.len], slice);
    inline for (0..N) |i| {
        const lane = ops.readLane(SrcT, tmp, @intCast(i));
        const widened: DstT = if (signed) @as(DstT, lane) else @as(DstT, @intCast(lane));
        ops.writeLane(DstT, &out, @intCast(i), widened);
    }
    return ops.v128FromBytes(out);
}

/// Splat load: loads a single scalar from memory and broadcasts it to all lanes.
fn loadSplat(comptime SrcT: type, comptime DstT: type, comptime N: usize, slice: []const u8) V128 {
    var tmp = std.mem.zeroes([16]u8);
    @memcpy(tmp[0..slice.len], slice);
    const lane = ops.readLane(SrcT, tmp, 0);
    return ops.splatGeneric(DstT, N, @as(DstT, @bitCast(lane)));
}

/// Zero-extending load: loads bytes into the low portion of V128,
/// zero-filling the remaining bytes.
/// Fix 8: removed unused T and width parameters.
fn loadZeroExtended(slice: []const u8) V128 {
    var out = std.mem.zeroes([16]u8);
    @memcpy(out[0..slice.len], slice);
    return ops.v128FromBytes(out);
}

/// Lane load: replaces a specific lane in the existing vector with data from memory.
fn loadLane(opcode: SimdOpcode, value: V128, slice: []const u8, lane: u8) V128 {
    var out = value;
    const width = classify.laneImmediateFromOpcode(opcode);
    const start = @as(usize, lane) * width;
    @memcpy(out.bytes[start .. start + width], slice[0..width]);
    return out;
}

/// Extracts the bytes of a single lane for store operations.
fn laneBytes(value: V128, lane: u8, width: usize) [8]u8 {
    var out = std.mem.zeroes([8]u8);
    const start = @as(usize, lane) * width;
    @memcpy(out[0..width], value.bytes[start .. start + width]);
    return out;
}

const std = @import("std");
const testing = std.testing;

const core = @import("core");
const classify = @import("../classify.zig");
const ops = @import("../ops.zig");
const exec_mod = @import("../exec.zig");

const RawVal = core.RawVal;
const V128 = ops.V128;
const SimdOpcode = classify.SimdOpcode;

test "execute simple integer simd pipeline" {
    const lanes = ops.splatGeneric(i32, 4, 3);
    const added = exec_mod.executeBinary(.i32x4_add, RawVal.from(lanes), RawVal.from(ops.splatGeneric(i32, 4, 4)));
    const replaced = exec_mod.replaceLane(.i32x4_replace_lane, added, RawVal.from(@as(i32, 99)), 2);
    try testing.expectEqual(@as(i32, 7), exec_mod.extractLane(.i32x4_extract_lane, added, 0).readAs(i32));
    try testing.expectEqual(@as(i32, 99), exec_mod.extractLane(.i32x4_extract_lane, replaced, 2).readAs(i32));
}

test "load/store lane roundtrip" {
    var memory = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0xaa, 0xbb, 0xcc, 0xdd };
    const base = ops.splatGeneric(i16, 8, 0);
    const loaded = exec_mod.load(.v128_load16_lane, memory[0..], 0, 0, 1, RawVal.from(base));
    try testing.expectEqual(@as(i32, 0x2211), exec_mod.extractLane(.i16x8_extract_lane_u, RawVal.from(loaded), 1).readAs(i32));

    var out = [_]u8{0} ** 8;
    exec_mod.store(.v128_store16_lane, out[0..], 0, 0, 1, RawVal.from(loaded));
    try testing.expectEqualSlices(u8, memory[0..2], out[0..2]);
}

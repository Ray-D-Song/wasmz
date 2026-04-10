const std = @import("std");
const testing = std.testing;

const classify_mod = @import("../classify.zig");

const SimdClass = classify_mod.SimdClass;

test "classify representative simd opcodes" {
    try testing.expectEqual(SimdClass.const_, classify_mod.classifyOpcode(.v128_const).?);
    try testing.expectEqual(SimdClass.load, classify_mod.classifyOpcode(.v128_load).?);
    try testing.expectEqual(SimdClass.shift, classify_mod.classifyOpcode(.i16x8_shr_u).?);
    try testing.expectEqual(SimdClass.compare, classify_mod.classifyOpcode(.f32x4_ge).?);
    try testing.expectEqual(SimdClass.ternary, classify_mod.classifyOpcode(.v128_bitselect).?);
}

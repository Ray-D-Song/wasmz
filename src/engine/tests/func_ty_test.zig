const std = @import("std");
const testing = std.testing;

const core = @import("core");
const func_ty_mod = @import("../func_ty.zig");

const ValType = core.ValType;
const FuncType = core.func_type.FuncType;
const FuncTypeRegistry = func_ty_mod.FuncTypeRegistry;
const EngineId = @import("../root.zig").EngineId;

test "FuncTypeRegistry deduplicates identical function types" {
    var registry = FuncTypeRegistry.init(testing.allocator, EngineId.init());
    defer registry.deinit();

    const func_a = try FuncType.init(testing.allocator, &.{ ValType.I32, ValType.I64 }, &.{ValType.I32});
    defer func_a.deinit(testing.allocator);

    const func_b = try FuncType.init(testing.allocator, &.{ ValType.I32, ValType.I64 }, &.{ValType.I32});
    defer func_b.deinit(testing.allocator);

    const dedup_a = try registry.allocFuncType(func_a);
    const dedup_b = try registry.allocFuncType(func_b);

    try testing.expectEqual(dedup_a.owned.engine_id.id, dedup_b.owned.engine_id.id);
    try testing.expectEqual(dedup_a.owned.value, dedup_b.owned.value);

    const resolved = registry.resolveFuncType(&dedup_a);
    try testing.expectEqual(@as(usize, 2), resolved.params().len);
    try testing.expectEqual(@as(usize, 1), resolved.results().len);
}

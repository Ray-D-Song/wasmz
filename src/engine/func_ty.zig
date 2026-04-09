const std = @import("std");

const Allocator = std.mem.Allocator;
const core = @import("core");
const FuncType = core.func_type.FuncType;
const DedupArenaWithContext = @import("../utils/arena/dedup.zig").DedupArenaWithContext;
const EngineId = @import("./root.zig").EngineId;
const EngineOwned = @import("./root.zig").EngineOwned;

pub const DedupFuncType = struct {
    owned: EngineOwned(u32),
};

const FuncTypeContext = struct {
    pub fn hash(_: @This(), func_type: FuncType) u64 {
        var hasher = std.hash.Wyhash.init(0);

        std.hash.autoHash(&hasher, func_type.params().len);
        hasher.update(std.mem.sliceAsBytes(func_type.params()));

        std.hash.autoHash(&hasher, func_type.results().len);
        hasher.update(std.mem.sliceAsBytes(func_type.results()));

        return hasher.final();
    }

    pub fn eql(_: @This(), lhs: FuncType, rhs: FuncType) bool {
        return std.mem.eql(std.meta.Child(@TypeOf(lhs.params())), lhs.params(), rhs.params()) and
            std.mem.eql(std.meta.Child(@TypeOf(lhs.results())), lhs.results(), rhs.results());
    }
};

pub const FuncTypeRegistry = struct {
    allocator: Allocator,
    engine_id: EngineId,
    func_types: DedupArenaWithContext(u32, FuncType, FuncTypeContext),

    const Self = @This();

    pub fn init(allocator: Allocator, engine_id: EngineId) Self {
        return .{
            .allocator = allocator,
            .engine_id = engine_id,
            .func_types = DedupArenaWithContext(u32, FuncType, FuncTypeContext).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.func_types.values()) |func_type| {
            func_type.deinit(self.allocator);
        }
        self.func_types.deinit();
        self.* = undefined;
    }

    fn cloneFuncType(self: *const Self, func_type: FuncType) Allocator.Error!FuncType {
        return FuncType.init(self.allocator, func_type.params(), func_type.results()) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => unreachable,
        };
    }

    fn unwrapOrPanic(self: *const Self, owned: EngineOwned(u32)) u32 {
        return self.engine_id.unwrap(u32, owned) orelse {
            std.debug.panic(
                "encountered foreign entity in func type registry: {any}",
                .{self.engine_id},
            );
        };
    }

    pub fn allocFuncType(self: *Self, func_type: FuncType) Allocator.Error!DedupFuncType {
        if (self.func_types.getKey(func_type)) |key| {
            return .{ .owned = self.engine_id.wrap(u32, key) };
        }

        const owned_func_type = try self.cloneFuncType(func_type);
        const key = self.func_types.alloc(owned_func_type) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotEnoughKeys => {
                owned_func_type.deinit(self.allocator);
                std.debug.panic("failed to alloc func type: exhausted key space", .{});
            },
            error.KeyOutOfBounds => unreachable,
        };
        return .{ .owned = self.engine_id.wrap(u32, key) };
    }

    pub fn resolveFuncType(self: *const Self, key: *const DedupFuncType) *const FuncType {
        const raw_key = self.unwrapOrPanic(key.owned);
        return self.func_types.get(raw_key) catch |err| switch (err) {
            error.KeyOutOfBounds => std.debug.panic(
                "failed to resolve function type at {}: key out of bounds",
                .{raw_key},
            ),
            else => unreachable,
        };
    }
};

test "FuncTypeRegistry deduplicates identical function types" {
    const ValType = core.ValType;

    var registry = FuncTypeRegistry.init(std.testing.allocator, EngineId.init());
    defer registry.deinit();

    const func_a = try FuncType.init(std.testing.allocator, &.{ ValType.I32, ValType.I64 }, &.{ValType.I32});
    defer func_a.deinit(std.testing.allocator);

    const func_b = try FuncType.init(std.testing.allocator, &.{ ValType.I32, ValType.I64 }, &.{ValType.I32});
    defer func_b.deinit(std.testing.allocator);

    const dedup_a = try registry.allocFuncType(func_a);
    const dedup_b = try registry.allocFuncType(func_b);

    try std.testing.expectEqual(dedup_a.owned.engine_id.id, dedup_b.owned.engine_id.id);
    try std.testing.expectEqual(dedup_a.owned.value, dedup_b.owned.value);

    const resolved = registry.resolveFuncType(&dedup_a);
    try std.testing.expectEqual(@as(usize, 2), resolved.params().len);
    try std.testing.expectEqual(@as(usize, 1), resolved.results().len);
}

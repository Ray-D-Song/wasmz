const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn DedupArenaWithContext(comptime Key: type, comptime T: type, comptime Context: type) type {
    return struct {
        allocator: Allocator,
        item_to_key: std.HashMapUnmanaged(T, Key, Context, std.hash_map.default_max_load_percentage) = .empty,
        items: std.ArrayListUnmanaged(T) = .empty,

        const Self = @This();

        pub const Error = Allocator.Error || error{
            NotEnoughKeys,
            KeyOutOfBounds,
        };

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.item_to_key.deinit(self.allocator);
            self.items.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn len(self: Self) usize {
            return self.items.items.len;
        }

        pub fn isEmpty(self: Self) bool {
            return self.len() == 0;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.item_to_key.clearRetainingCapacity();
            self.items.clearRetainingCapacity();
        }

        pub fn clearAndFree(self: *Self) void {
            self.item_to_key.clearAndFree(self.allocator);
            self.items.clearAndFree(self.allocator);
        }

        /// Allocates `item` if it does not already exist and returns its key.
        pub fn alloc(self: *Self, item: T) Error!Key {
            if (self.item_to_key.get(item)) |key| {
                return key;
            }

            const key = try keyFromIndex(self.items.items.len);
            try self.items.append(self.allocator, item);
            errdefer _ = self.items.pop();

            try self.item_to_key.put(self.allocator, item, key);
            return key;
        }

        pub fn contains(self: Self, item: T) bool {
            return self.item_to_key.contains(item);
        }

        pub fn getKey(self: Self, item: T) ?Key {
            return self.item_to_key.get(item);
        }

        pub fn get(self: *const Self, key: Key) Error!*const T {
            const index = indexFromKey(key);
            if (index >= self.items.items.len) {
                return error.KeyOutOfBounds;
            }
            return &self.items.items[index];
        }

        /// Mutating a stored item can invalidate the `item -> key` dedup index.
        pub fn getMut(self: *Self, key: Key) Error!*T {
            const index = indexFromKey(key);
            if (index >= self.items.items.len) {
                return error.KeyOutOfBounds;
            }
            return &self.items.items[index];
        }

        pub fn values(self: *const Self) []const T {
            return self.items.items;
        }

        /// Mutating stored items can invalidate the `item -> key` dedup index.
        pub fn valuesMut(self: *Self) []T {
            return self.items.items;
        }

        fn keyFromIndex(index: usize) error{NotEnoughKeys}!Key {
            if (comptime isIntegerKey(Key)) {
                return std.math.cast(Key, index) orelse error.NotEnoughKeys;
            }
            if (@hasDecl(Key, "fromIndex")) {
                const result = Key.fromIndex(index);
                return unwrapKeyConstructionResult(result);
            }
            if (@hasDecl(Key, "fromInt")) {
                const result = Key.fromInt(index);
                return unwrapKeyConstructionResult(result);
            }
            @compileError("DedupArena key type must be an integer type or provide fromIndex/fromInt");
        }

        fn indexFromKey(key: Key) usize {
            if (comptime isIntegerKey(Key)) {
                return @intCast(key);
            }
            if (@hasDecl(Key, "intoIndex")) {
                return key.intoIndex();
            }
            if (@hasDecl(Key, "intoInt")) {
                return key.intoInt();
            }
            @compileError("DedupArena key type must be an integer type or provide intoIndex/intoInt");
        }

        fn unwrapKeyConstructionResult(result: anytype) error{NotEnoughKeys}!Key {
            const Result = @TypeOf(result);
            return switch (@typeInfo(Result)) {
                .optional => result orelse error.NotEnoughKeys,
                .error_union => result catch error.NotEnoughKeys,
                else => result,
            };
        }

        fn isIntegerKey(comptime K: type) bool {
            return switch (@typeInfo(K)) {
                .int, .comptime_int => true,
                else => false,
            };
        }
    };
}

/// A deduplicating arena backed by a hash map and a dense item array.
///
/// The hash map provides `T -> Key` lookup for deduplication, while the array
/// provides `Key -> T` lookup for stable handle access.
///
/// This container does not deallocate single items. Clearing or deinitializing
/// it only releases the backing storage of the map and array.
pub fn DedupArena(comptime Key: type, comptime T: type) type {
    return DedupArenaWithContext(Key, T, std.hash_map.AutoContext(T));
}

test "DedupArena deduplicates integer keys" {
    var arena = DedupArena(u32, u32).init(std.testing.allocator);
    defer arena.deinit();

    const a = try arena.alloc(7);
    const b = try arena.alloc(7);
    const c = try arena.alloc(9);

    try std.testing.expectEqual(@as(u32, 0), a);
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(u32, 1), c);
    try std.testing.expectEqual(@as(usize, 2), arena.len());
    try std.testing.expectEqual(@as(u32, 7), (try arena.get(a)).*);
    try std.testing.expectEqual(@as(u32, 9), (try arena.get(c)).*);
}

test "DedupArena supports custom handle keys" {
    const Handle = struct {
        raw: u32,

        pub fn fromIndex(index: usize) ?@This() {
            const raw = std.math.cast(u32, index) orelse return null;
            return .{ .raw = raw };
        }

        pub fn intoIndex(self: @This()) usize {
            return self.raw;
        }
    };

    var arena = DedupArena(Handle, u64).init(std.testing.allocator);
    defer arena.deinit();

    const first = try arena.alloc(11);
    const second = try arena.alloc(11);
    const third = try arena.alloc(12);

    try std.testing.expectEqual(@as(u32, 0), first.raw);
    try std.testing.expectEqual(first.raw, second.raw);
    try std.testing.expectEqual(@as(u32, 1), third.raw);
    try std.testing.expectEqual(@as(u64, 12), (try arena.get(third)).*);
}

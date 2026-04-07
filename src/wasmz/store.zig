/// store.zig - WebAssembly Store
///
/// Store is the runtime context that owns all the mutable state during execution, such as instances and their associated resources
/// (memory/table, etc.). Its responsibilities are lighter: it holds references to the allocator and engine.
const std = @import("std");
const engine_mod = @import("../engine/mod.zig");

const Allocator = std.mem.Allocator;
const Engine = engine_mod.Engine;

pub const Store = struct {
    allocator: Allocator,
    /// Arc reference, ensures the engine is not released during the store's lifetime.
    engine: Engine,

    pub fn init(allocator: Allocator, engine: Engine) Store {
        return .{
            .allocator = allocator,
            // clone increments the Arc reference count, ensuring the Store holds an independent reference.
            .engine = engine.clone(),
        };
    }

    pub fn deinit(self: *Store) void {
        self.engine.deinit();
        self.* = undefined;
    }
};

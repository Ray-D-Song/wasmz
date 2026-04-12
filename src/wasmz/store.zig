/// store.zig - WebAssembly Store
///
/// Store is the runtime context that owns all the mutable state during execution, such as instances and their associated resources
/// (memory/table, etc.). Its responsibilities are lighter: it holds references to the allocator and engine.
///
/// For WASM GC: Store owns the GC heap, which is shared across all instances created from this store.
const std = @import("std");
const engine_mod = @import("../engine/root.zig");
const gc_mod = @import("../vm/gc/root.zig");
const core = @import("core");

const Allocator = std.mem.Allocator;
const Engine = engine_mod.Engine;
const GcHeap = gc_mod.GcHeap;
pub const MemoryBudget = core.MemoryBudget;

pub const Store = struct {
    allocator: Allocator,
    /// Arc reference, ensures the engine is not released during the store's lifetime.
    engine: Engine,
    /// GC heap for WASM GC objects (structs, arrays, i31).
    /// Shared across all instances created from this store.
    gc_heap: GcHeap,
    user_data: ?*anyopaque = null,
    runtime_instance_count: usize = 0,
    /// Memory budget: tracks and optionally limits total memory use.
    /// The GC heap and ExecEnv hold pointers into this field, so Store must not
    /// be moved after init (always access Store through a pointer).
    memory_budget: MemoryBudget,

    pub fn init(allocator: Allocator, engine: Engine) std.mem.Allocator.Error!Store {
        const limit: ?u64 = engine.config().*.mem_limit_bytes;
        var store = Store{
            .allocator = allocator,
            // clone increments the Arc reference count, ensuring the Store holds an independent reference.
            .engine = engine.clone(),
            // Initialize GC heap with default size (4KB, grows on demand).
            // Budget pointer is set to null here and patched to &self.memory_budget
            // by the caller via Store.linkBudget() after the store reaches its final location.
            .gc_heap = try GcHeap.initDefault(allocator, null),
            .memory_budget = .{
                .limit_bytes = limit,
                .linear_bytes = 0,
                .gc_capacity_bytes = 0,
                .shared_bytes = 0,
            },
        };
        // Record the initial GC heap capacity in the budget.
        store.memory_budget.gc_capacity_bytes = store.gc_heap.totalSize();
        return store;
    }

    /// Must be called once, after the Store has been placed at its permanent
    /// address (i.e., the `var store` declaration in the caller).
    /// This patches the GC heap's budget pointer so it refers to the store's
    /// own MemoryBudget field rather than a now-invalid stack temporary.
    pub fn linkBudget(self: *Store) void {
        if (self.memory_budget.limit_bytes != null) {
            self.gc_heap.budget = &self.memory_budget;
        }
    }

    pub fn setUserData(self: *Store, user_data: ?*anyopaque) void {
        self.user_data = user_data;
    }

    pub fn getUserData(self: *Store, comptime T: type) ?*T {
        const ptr = self.user_data orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn registerInstance(self: *Store) void {
        self.runtime_instance_count += 1;
    }

    pub fn unregisterInstance(self: *Store) void {
        std.debug.assert(self.runtime_instance_count > 0);
        self.runtime_instance_count -= 1;
    }

    pub fn deinit(self: *Store) void {
        self.gc_heap.deinit();
        self.engine.deinit();
        self.* = undefined;
    }
};

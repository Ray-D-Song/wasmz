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
    /// Lazily initialized on first need (when a module with GC types is instantiated).
    gc_heap: ?GcHeap = null,
    user_data: ?*anyopaque = null,
    runtime_instance_count: usize = 0,
    /// Memory budget: tracks and optionally limits total memory use.
    /// The GC heap and ExecEnv hold pointers into this field, so Store must not
    /// be moved after init (always access Store through a pointer).
    memory_budget: MemoryBudget,
    /// Total number of allocations performed by this store's runtime.
    alloc_count: usize = 0,

    pub fn init(allocator: Allocator, engine: Engine) std.mem.Allocator.Error!Store {
        const limit: ?u64 = engine.config().*.mem_limit_bytes;
        return .{
            .allocator = allocator,
            .engine = engine.clone(),
            .gc_heap = null,
            .memory_budget = .{
                .limit_bytes = limit,
                .linear_bytes = 0,
                .gc_capacity_bytes = 0,
                .shared_bytes = 0,
            },
        };
    }

    /// Initializes the GC heap on first use. Safe to call multiple times.
    /// Returns the gc_heap pointer for convenience.
    pub fn ensureGcHeap(self: *Store) std.mem.Allocator.Error!*GcHeap {
        if (self.gc_heap == null) {
            self.gc_heap = try GcHeap.initDefault(self.allocator, null);
            if (self.memory_budget.limit_bytes != null) {
                self.gc_heap.?.budget = &self.memory_budget;
            }
            self.memory_budget.gc_capacity_bytes = self.gc_heap.?.totalSize();
        }
        return &self.gc_heap.?;
    }

    /// Must be called once, after the Store has been placed at its permanent
    /// address (i.e., the `var store` declaration in the caller).
    /// This patches the GC heap's budget pointer so it refers to the store's
    /// own MemoryBudget field rather than a now-invalid stack temporary.
    pub fn linkBudget(self: *Store) void {
        if (self.gc_heap) |*gc_heap| {
            if (self.memory_budget.limit_bytes != null) {
                gc_heap.budget = &self.memory_budget;
            }
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
        if (self.gc_heap) |*gc_heap| {
            gc_heap.deinit();
        }
        self.engine.deinit();
        self.* = undefined;
    }
};

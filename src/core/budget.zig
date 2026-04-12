/// budget.zig - Memory budget tracking
///
/// MemoryBudget tracks total memory consumption across linear memory, GC heap,
/// and shared memory, and optionally enforces a hard limit.
///
/// Placed in core so that vm/gc/heap.zig (which lives inside the `vm` module)
/// can import it without crossing module boundaries.
/// Tracks and enforces memory consumption across linear memory, GC heap, and shared memory.
///
/// All byte counts are maintained as running totals so that limit checks are O(1).
/// Pointers to MemoryBudget are stored in GcHeap and ExecEnv so they can record
/// each allocation and enforce the limit without passing additional parameters.
pub const MemoryBudget = struct {
    /// null = unlimited
    limit_bytes: ?u64,
    /// Current linear memory size in bytes (owned memory only; excludes shared).
    linear_bytes: u64,
    /// Current GC heap capacity in bytes.
    gc_capacity_bytes: u64,
    /// Current shared memory capacity in bytes (sum across all shared instances).
    shared_bytes: u64,

    /// Total tracked bytes across all memory kinds.
    pub fn totalUsed(self: MemoryBudget) u64 {
        return self.linear_bytes + self.gc_capacity_bytes + self.shared_bytes;
    }

    /// Returns true if `additional` bytes can be allocated without exceeding the limit.
    pub fn canGrow(self: MemoryBudget, additional: u64) bool {
        const limit = self.limit_bytes orelse return true;
        const used = self.totalUsed();
        return used + additional <= limit;
    }

    /// Update the linear memory counter to `new_total` bytes.
    pub fn recordLinearGrow(self: *MemoryBudget, new_total: u64) void {
        self.linear_bytes = new_total;
    }

    /// Update the GC heap capacity counter to `new_capacity` bytes.
    pub fn recordGcGrow(self: *MemoryBudget, new_capacity: u64) void {
        self.gc_capacity_bytes = new_capacity;
    }

    /// Update the shared memory counter by adding `additional` bytes.
    pub fn recordSharedGrow(self: *MemoryBudget, additional: u64) void {
        self.shared_bytes += additional;
    }
};

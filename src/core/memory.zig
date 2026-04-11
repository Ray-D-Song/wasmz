/// memory.zig - WebAssembly Linear Memory abstraction
///
/// Provides a unified interface over two kinds of WebAssembly linear memories:
///
///   - Owned memory: a plain heap-allocated byte slice exclusively owned by one Instance.
///     This is the common case for non-threaded modules.
///
///   - Shared memory: a reference-counted, atomically-accessible byte region that can be
///     imported by multiple Instances (potentially on different OS threads).
///     Corresponds to the `(memory ... shared)` declaration in the Wasm Threads proposal.
///
/// All read/write helpers delegate to the underlying byte slice.  Atomic operations on the
/// raw bytes are performed by the VM layer directly through `Memory.bytes()`.
///
/// Wait / Notify (memory.atomic.wait32 / wait64 / notify)
/// -------------------------------------------------------
/// Implemented using a fixed-size "futex bucket table" inside `SharedMemoryInner`.
/// The effective address is hashed to one of `FUTEX_BUCKETS` buckets; each bucket owns
/// a `Mutex` and a `Condition`.  Waiters park on the condition; notify broadcasts on the
/// matching bucket.
///
/// Trade-offs:
///   - Fixed bucket count avoids dynamic allocation inside the hot path.
///   - Hash collisions can cause multiple waiters to share a bucket/condition,
///     but a `notify_seq` generation counter inside each bucket lets waiters
///     distinguish real notifications from spurious OS-level wake-ups.
///   - Each waiter re-checks `notify_seq` in a loop after waking.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const WASM_PAGE_SIZE: usize = 65536;

// ── Futex bucket table ────────────────────────────────────────────────────────

/// Number of futex buckets in the wait/notify table.  Must be a power of two.
const FUTEX_BUCKETS: usize = 64;

/// One entry in the futex bucket table.
const FutexBucket = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    /// Number of threads currently waiting on this bucket.
    waiters: u32 = 0,
    /// Generation counter: incremented by every notify call so waiters can
    /// distinguish a real wake-up from a spurious one.
    notify_seq: u32 = 0,
};

/// Wait result codes returned by `SharedMemoryInner.wait32` / `wait64`.
pub const WaitResult = enum(i32) {
    /// The waiting thread was woken by a `notify` call.
    ok = 0,
    /// The value at the address did not equal the expected value when checked.
    not_equal = 1,
    /// The timeout expired before a notification arrived.
    timed_out = 2,
};

// ── SharedMemoryInner ─────────────────────────────────────────────────────────

/// Inner shared-memory object, heap-allocated and reference-counted via `SharedMemory`.
///
/// Layout:
///   bytes        – the linear memory contents, aligned to 8 bytes for atomic access.
///   current_size – current live byte count; grows atomically when memory.grow executes.
///   max_size     – upper bound in bytes; must be set for shared memories (Wasm spec).
///
/// Ref-counting: `SharedMemory` holds an `Arc`-style refcount.  When the last reference
/// is dropped, the bytes are freed with the stored allocator.
const SharedMemoryInner = struct {
    allocator: Allocator,
    /// Entire reserved region (capacity == max_size).
    bytes: []align(8) u8,
    /// Atomically-readable current size in bytes.
    current_size: std.atomic.Value(usize),
    /// Futex bucket table for wait/notify.
    futex: [FUTEX_BUCKETS]FutexBucket,

    fn init(allocator: Allocator, min_bytes: usize, max_bytes: usize) Allocator.Error!*SharedMemoryInner {
        const ptr = try allocator.create(SharedMemoryInner);
        errdefer allocator.destroy(ptr);
        // Reserve the full maximum region so the base address never moves.
        // align(8) is required for Zig's @atomicLoad/@atomicStore on 64-bit values.
        const bytes = try allocator.alignedAlloc(u8, @enumFromInt(3), max_bytes); // 2^3 = 8
        @memset(bytes, 0);
        ptr.* = .{
            .allocator = allocator,
            .bytes = bytes,
            .current_size = std.atomic.Value(usize).init(min_bytes),
            .futex = [_]FutexBucket{.{}} ** FUTEX_BUCKETS,
        };
        return ptr;
    }

    fn deinit(self: *SharedMemoryInner) void {
        self.allocator.free(self.bytes);
        self.allocator.destroy(self);
    }

    /// Return the bucket index for an effective address (uses lower address bits).
    inline fn bucketIndex(ea: u32) usize {
        // Shift right by 2 (i.e., index by word, not byte) before masking to
        // reduce collisions for adjacent 32-bit accesses.
        return (@as(usize, ea) >> 2) & (FUTEX_BUCKETS - 1);
    }

    /// memory.atomic.notify: wake up to `count` threads waiting on `ea`.
    /// Returns the number of threads actually woken.
    pub fn notify(self: *SharedMemoryInner, ea: u32, count: u32) u32 {
        const idx = bucketIndex(ea);
        const bucket = &self.futex[idx];
        bucket.mutex.lock();
        defer bucket.mutex.unlock();
        const waiting = bucket.waiters;
        if (waiting == 0 or count == 0) return 0;
        const to_wake = @min(count, waiting);
        // Advance the generation counter so waiters can detect a real wake-up.
        bucket.notify_seq +%= 1;
        if (to_wake >= waiting) {
            // Wake all — broadcast is cheaper than N signals.
            bucket.cond.broadcast();
        } else {
            // Signal `to_wake` times.
            var i: u32 = 0;
            while (i < to_wake) : (i += 1) {
                bucket.cond.signal();
            }
        }
        return to_wake;
    }

    /// memory.atomic.wait32: block until mem[ea] != expected or timeout expires.
    /// `timeout_ns`: negative means no timeout (wait forever).
    pub fn wait32(
        self: *SharedMemoryInner,
        ea: u32,
        expected: u32,
        timeout_ns: i64,
    ) WaitResult {
        if (timeout_ns == 0) return .timed_out;

        const idx = bucketIndex(ea);
        const bucket = &self.futex[idx];

        bucket.mutex.lock();
        defer bucket.mutex.unlock();

        // Check value under the lock to avoid a TOCTOU race with notify.
        const cur = @atomicLoad(u32, @as(*u32, @ptrCast(@alignCast(self.bytes.ptr + ea))), .seq_cst);
        if (cur != expected) return .not_equal;

        bucket.waiters += 1;
        defer bucket.waiters -= 1;

        // Record the generation counter before parking.  A real notify increments
        // it; a spurious wake-up leaves it unchanged, so we loop back to sleep.
        const initial_seq = bucket.notify_seq;

        if (timeout_ns < 0) {
            // Wait indefinitely — loop to guard against spurious wake-ups.
            while (bucket.notify_seq == initial_seq) {
                bucket.cond.wait(&bucket.mutex);
            }
            return .ok;
        } else {
            // Timed wait — compute absolute deadline and loop until notified or
            // the deadline has passed.
            const start_ns = std.time.nanoTimestamp();
            const deadline_ns = start_ns + timeout_ns;
            while (bucket.notify_seq == initial_seq) {
                const now_ns = std.time.nanoTimestamp();
                if (now_ns >= deadline_ns) return .timed_out;
                const left: u64 = @intCast(deadline_ns - now_ns);
                bucket.cond.timedWait(&bucket.mutex, left) catch {
                    return .timed_out;
                };
            }
            return .ok;
        }
    }

    /// memory.atomic.wait64: same as wait32 but operates on a u64 value.
    pub fn wait64(
        self: *SharedMemoryInner,
        ea: u32,
        expected: u64,
        timeout_ns: i64,
    ) WaitResult {
        if (timeout_ns == 0) return .timed_out;

        const idx = bucketIndex(ea);
        const bucket = &self.futex[idx];

        bucket.mutex.lock();
        defer bucket.mutex.unlock();

        const cur = @atomicLoad(u64, @as(*u64, @ptrCast(@alignCast(self.bytes.ptr + ea))), .seq_cst);
        if (cur != expected) return .not_equal;

        bucket.waiters += 1;
        defer bucket.waiters -= 1;

        const initial_seq = bucket.notify_seq;

        if (timeout_ns < 0) {
            while (bucket.notify_seq == initial_seq) {
                bucket.cond.wait(&bucket.mutex);
            }
            return .ok;
        } else {
            const start_ns = std.time.nanoTimestamp();
            const deadline_ns = start_ns + timeout_ns;
            while (bucket.notify_seq == initial_seq) {
                const now_ns = std.time.nanoTimestamp();
                if (now_ns >= deadline_ns) return .timed_out;
                const left: u64 = @intCast(deadline_ns - now_ns);
                bucket.cond.timedWait(&bucket.mutex, left) catch {
                    return .timed_out;
                };
            }
            return .ok;
        }
    }
};

/// A reference-counted handle to a `SharedMemoryInner`.
///
/// Cloning increments the refcount; `deinit` decrements it and frees when it reaches zero.
pub const SharedMemory = struct {
    inner: *SharedMemoryInner,
    refcount: *std.atomic.Value(usize),

    /// Create a new shared memory region with `min_pages` initially committed and `max_pages`
    /// reserved.  The max must be provided for shared memories (Wasm spec requirement).
    pub fn init(allocator: Allocator, min_pages: u32, max_pages: u32) Allocator.Error!SharedMemory {
        const refcount = try allocator.create(std.atomic.Value(usize));
        errdefer allocator.destroy(refcount);
        refcount.* = std.atomic.Value(usize).init(1);

        const inner = try SharedMemoryInner.init(
            allocator,
            @as(usize, min_pages) * WASM_PAGE_SIZE,
            @as(usize, max_pages) * WASM_PAGE_SIZE,
        );
        return .{ .inner = inner, .refcount = refcount };
    }

    /// Increment the reference count and return a second handle to the same region.
    pub fn clone(self: SharedMemory) SharedMemory {
        _ = self.refcount.fetchAdd(1, .monotonic);
        return self;
    }

    /// Decrement the reference count.  Frees the inner region when the count reaches zero.
    pub fn deinit(self: *SharedMemory) void {
        const prev = self.refcount.fetchSub(1, .acq_rel);
        if (prev == 1) {
            // We were the last holder.
            const allocator = self.inner.allocator;
            self.inner.deinit();
            allocator.destroy(self.refcount);
        }
        self.* = undefined;
    }

    /// Current live byte slice (size may grow atomically; always use `bytes()` to read it).
    pub fn bytes(self: *const SharedMemory) []align(8) u8 {
        const size = self.inner.current_size.load(.acquire);
        return self.inner.bytes[0..size];
    }

    /// Total reserved capacity in bytes (== max_pages * WASM_PAGE_SIZE).
    pub fn capacity(self: *const SharedMemory) usize {
        return self.inner.bytes.len;
    }

    /// Forward memory.atomic.notify to the inner futex table.
    pub fn notify(self: *SharedMemory, ea: u32, count: u32) u32 {
        return self.inner.notify(ea, count);
    }

    /// Forward memory.atomic.wait32 to the inner futex table.
    pub fn wait32(self: *SharedMemory, ea: u32, expected: u32, timeout_ns: i64) WaitResult {
        return self.inner.wait32(ea, expected, timeout_ns);
    }

    /// Forward memory.atomic.wait64 to the inner futex table.
    pub fn wait64(self: *SharedMemory, ea: u32, expected: u64, timeout_ns: i64) WaitResult {
        return self.inner.wait64(ea, expected, timeout_ns);
    }

    /// memory.grow: atomically grow the shared memory by `delta` pages.
    ///
    /// Because `SharedMemoryInner` pre-reserves the full `max_pages` region at
    /// init time, grow only needs to advance the `current_size` counter.
    ///
    /// Returns the old page count on success, `maxInt(u32)` on failure.
    pub fn grow(self: *SharedMemory, delta: u32) u32 {
        const FAIL = std.math.maxInt(u32);
        if (delta == 0) {
            const old_bytes = self.inner.current_size.load(.acquire);
            return @intCast(old_bytes / WASM_PAGE_SIZE);
        }
        const max_bytes = self.inner.bytes.len;
        const max_pages: u32 = @intCast(max_bytes / WASM_PAGE_SIZE);

        // CAS loop: atomically bump current_size if room remains.
        while (true) {
            const old_bytes = self.inner.current_size.load(.acquire);
            const old_pages: u32 = @intCast(old_bytes / WASM_PAGE_SIZE);
            const new_pages = std.math.add(u32, old_pages, delta) catch return FAIL;
            if (new_pages > max_pages) return FAIL;
            const new_bytes = @as(usize, new_pages) * WASM_PAGE_SIZE;
            // Try to atomically replace old_bytes with new_bytes.
            if (self.inner.current_size.cmpxchgWeak(old_bytes, new_bytes, .acq_rel, .acquire) == null) {
                // Success: memory zero-fill is already done at init time (bytes are pre-zeroed).
                return old_pages;
            }
            // Spurious failure — retry.
        }
    }
};

/// The backing store tag: either exclusively-owned, shared, or borrowed (no-alloc view).
pub const MemoryKind = enum { owned, shared, borrowed };

/// WebAssembly linear memory.
///
/// This value is stored inside `Instance` (for owned memories) or shared across Instances
/// (for shared memories).  The VM always accesses memory through `Memory.bytes()`.
pub const Memory = struct {
    kind: union(MemoryKind) {
        owned: struct {
            allocator: Allocator,
            bytes: []u8,
        },
        shared: SharedMemory,
        /// A non-owning view into an externally-managed byte slice.
        /// Used in tests that hand-construct HostInstance / ExecEnv without an allocator.
        /// `deinit` is a no-op for borrowed memories.
        borrowed: []u8,
    },

    // ── constructors ─────────────────────────────────────────────────────────────

    /// Create an exclusively-owned memory.  The caller supplies the allocator used for
    /// the initial allocation; `deinit` will use the same allocator to free the bytes.
    pub fn initOwned(allocator: Allocator, min_pages: u32) Allocator.Error!Memory {
        const byte_count = @as(usize, min_pages) * WASM_PAGE_SIZE;
        const buf = try allocator.alloc(u8, byte_count);
        @memset(buf, 0);
        return .{ .kind = .{ .owned = .{ .allocator = allocator, .bytes = buf } } };
    }

    /// Create an empty (zero-page) owned memory placeholder used when a module declares
    /// no memory section.
    pub fn initEmpty() Memory {
        // Use a dummy slice so that `bytes()` returns an empty slice without allocating.
        return .{ .kind = .{ .owned = .{ .allocator = std.heap.page_allocator, .bytes = &[0]u8{} } } };
    }

    /// Wrap an existing `SharedMemory` handle (clones the refcount).
    pub fn initShared(shared: SharedMemory) Memory {
        return .{ .kind = .{ .shared = shared.clone() } };
    }

    /// Create a non-owning view over an externally-managed byte slice.
    ///
    /// `deinit` is a no-op for borrowed memories.  Use this in tests or FFI contexts
    /// where the backing storage is managed by the caller.
    pub fn initBorrowed(slice: []u8) Memory {
        return .{ .kind = .{ .borrowed = slice } };
    }

    // ── cleanup ───────────────────────────────────────────────────────────────────

    pub fn deinit(self: *Memory) void {
        switch (self.kind) {
            .owned => |o| {
                if (o.bytes.len > 0) o.allocator.free(o.bytes);
            },
            .shared => |*s| {
                var shared = s.*;
                shared.deinit();
            },
            .borrowed => {}, // no-op: caller owns the storage
        }
        self.* = undefined;
    }

    // ── accessors ─────────────────────────────────────────────────────────────────

    /// Return the currently-live byte slice.
    ///
    /// For shared memories, this performs an acquire load of the current size so the
    /// caller always sees the most recently committed pages.
    pub fn bytes(self: *const Memory) []u8 {
        return switch (self.kind) {
            .owned => |o| o.bytes,
            .shared => |*s| s.bytes(),
            .borrowed => |b| b,
        };
    }

    /// Return `true` if this memory was declared `shared`.
    pub fn isShared(self: *const Memory) bool {
        return self.kind == .shared;
    }

    /// Current size in bytes.
    pub fn byteLen(self: *const Memory) usize {
        return self.bytes().len;
    }

    /// Current size in pages (each page is 64 KiB).
    pub fn pageCount(self: *const Memory) u32 {
        return @intCast(self.byteLen() / WASM_PAGE_SIZE);
    }

    // ── Wait / Notify public API ───────────────────────────────────────────────
    //
    // For owned/borrowed memories, wait/notify are no-ops with the "safe" return
    // values defined by the Wasm spec for non-shared memories:
    //   notify  → 0   (no waiters to wake)
    //   wait32/64 → not_equal (caller must not block; value semantics undefined
    //               for non-shared memories per spec)

    /// memory.atomic.notify: wake up to `count` threads waiting on `ea`.
    /// Returns the number of threads actually woken (0 for non-shared memories).
    pub fn notify(self: *Memory, ea: u32, count: u32) u32 {
        return switch (self.kind) {
            .shared => |*s| s.notify(ea, count),
            .owned, .borrowed => 0,
        };
    }

    /// memory.atomic.wait32: block until mem[ea] != expected or timeout expires.
    /// For non-shared memories returns `.not_equal` immediately (per Wasm spec).
    pub fn wait32(self: *Memory, ea: u32, expected: u32, timeout_ns: i64) WaitResult {
        return switch (self.kind) {
            .shared => |*s| s.wait32(ea, expected, timeout_ns),
            .owned, .borrowed => .not_equal,
        };
    }

    /// memory.atomic.wait64: same as wait32 but for a u64 value.
    pub fn wait64(self: *Memory, ea: u32, expected: u64, timeout_ns: i64) WaitResult {
        return switch (self.kind) {
            .shared => |*s| s.wait64(ea, expected, timeout_ns),
            .owned, .borrowed => .not_equal,
        };
    }

    // ── memory.grow ───────────────────────────────────────────────────────────
    //
    // Attempts to grow the memory by `delta` pages.
    // Returns the previous page count on success, or std.math.maxInt(u32) on
    // failure (the VM interprets maxInt(u32) as the Wasm -1 result sentinel).

    /// Attempt to grow by `delta` pages.
    /// Returns the old page count on success, `maxInt(u32)` on failure.
    pub fn grow(self: *Memory, delta: u32) u32 {
        const FAIL = std.math.maxInt(u32);
        return switch (self.kind) {
            .owned => |*o| blk: {
                const old_bytes = o.bytes.len;
                const old_pages: u32 = @intCast(old_bytes / WASM_PAGE_SIZE);
                if (delta == 0) break :blk old_pages;
                const new_pages = std.math.add(u32, old_pages, delta) catch break :blk FAIL;
                const new_bytes = @as(usize, new_pages) * WASM_PAGE_SIZE;
                const new_buf = o.allocator.realloc(o.bytes, new_bytes) catch break :blk FAIL;
                @memset(new_buf[old_bytes..], 0);
                o.bytes = new_buf;
                break :blk old_pages;
            },
            .shared => |*s| s.grow(delta),
            .borrowed => FAIL, // borrowed memories cannot grow
        };
    }
};

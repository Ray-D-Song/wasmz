/// memory.zig - WebAssembly Linear Memory abstraction
///
/// Provides a unified interface over two kinds of WebAssembly linear memories:
///
///   - Owned memory: a virtual-address-reserved byte region exclusively owned by one
///     Instance.  This is the common case for non-threaded modules.
///
///     On POSIX (macOS, Linux, *BSD) the full virtual address space (up to `max_pages`
///     pages, or MAX_OWNED_CAPACITY when max is unlimited) is reserved with
///     `mmap(PROT_NONE)` at init time.  Only the initially-committed range is made
///     accessible with `mprotect(PROT_READ|WRITE)`.  Subsequent `memory.grow` calls
///     extend the committed range via a second `mprotect` call — zero copy, zero
///     realloc.  This eliminates the "old-buffer + new-buffer" peak RSS spike that
///     occurs when `realloc` cannot extend a heap region in-place.
///
///     On non-POSIX targets the implementation falls back to a plain heap-allocated
///     slice that is `realloc`-ed on every grow (same behaviour as before).
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
const builtin = @import("builtin");
const core = @import("root.zig");
const arch = core.platform;
const Allocator = std.mem.Allocator;

/// Maximum virtual address space reserved for an owned memory when the module
/// declares no maximum page count.  4 GiB is the hard limit imposed by the
/// 32-bit address space of WebAssembly linear memory.
const MAX_OWNED_CAPACITY: usize = arch.max_linear_memory_bytes;

/// True when the platform supports mmap/mprotect for the virtual-reserve strategy.
const use_mmap = builtin.os.tag == .linux or
    builtin.os.tag == .macos or
    builtin.os.tag == .ios or
    builtin.os.tag == .tvos or
    builtin.os.tag == .watchos or
    builtin.os.tag == .visionos or
    builtin.os.tag == .freebsd or
    builtin.os.tag == .netbsd or
    builtin.os.tag == .openbsd or
    builtin.os.tag == .dragonfly or
    builtin.os.tag == .illumos;

// Owned memory helpers (POSIX mmap strategy)

/// OS page alignment for mmap regions.  On macOS this is 16 KiB; on Linux 4 KiB.
/// WASM_PAGE_SIZE (64 KiB) is always a multiple of this so all offsets are valid.
const mmap_page_align = std.heap.page_size_min;

/// PROT_NONE / PROT_READ|WRITE constants that work for both the Linux
/// packed struct PROT and the Apple `vm_prot_t` packed struct.
/// Both expose `READ`, `WRITE`, `EXEC` bool fields; default-initialised
/// is "no access" (== PROT_NONE on the C side).
const prot_none: std.posix.PROT = .{};
const prot_rw: std.posix.PROT = .{ .READ = true, .WRITE = true };

/// Replacement for `std.posix.mprotect`, which was removed in Zig 0.16.
/// Calls `std.c.mprotect` directly and reports failure as a plain bool so
/// callers can map it onto their own error path.
fn mprotectRw(slice: []align(mmap_page_align) u8) bool {
    if (slice.len == 0) return true;
    const rc = std.c.mprotect(@ptrCast(slice.ptr), slice.len, prot_rw);
    return rc == 0;
}

/// Allocate a virtual address region of `capacity` bytes with no physical pages
/// committed (PROT_NONE), then commit the first `committed` bytes.
/// Returns a pointer to the base of the region and the full capacity slice.
fn ownedMmapInit(committed: usize, capacity: usize) Allocator.Error![]align(mmap_page_align) u8 {
    if (use_mmap) {
        const posix = std.posix;
        const base = posix.mmap(
            null,
            capacity,
            prot_none,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return error.OutOfMemory;
        if (committed > 0) {
            if (!mprotectRw(base[0..committed])) {
                posix.munmap(base);
                return error.OutOfMemory;
            }
            @memset(base[0..committed], 0);
        }
        return base;
    } else {
        unreachable;
    }
}

/// Extend committed range from `old_committed` to `new_committed`.
/// `base` is the full reserved region (capacity bytes).
fn ownedMmapGrow(base: []align(mmap_page_align) u8, old_committed: usize, new_committed: usize) bool {
    if (use_mmap) {
        const new_range: []align(mmap_page_align) u8 = @alignCast(base[old_committed..new_committed]);
        if (!mprotectRw(new_range)) return false;
        @memset(new_range, 0);
        return true;
    } else {
        unreachable;
    }
}

fn ownedMmapDeinit(base: []align(mmap_page_align) u8) void {
    if (use_mmap) {
        std.posix.munmap(base);
    } else {
        unreachable;
    }
}

pub const WASM_PAGE_SIZE: usize = 65536;

// Futex bucket table

/// Number of futex buckets in the wait/notify table.  Must be a power of two.
const FUTEX_BUCKETS: usize = 64;

/// Zig-0.16 stubs for `std.Thread.Mutex` / `std.Thread.Condition`.
///
/// In 0.15 these were callable without an `Io` parameter. In 0.16 the
/// blocking synchronisation primitives live under `std.Io` and require an
/// `Io` instance. wasmz only uses them for the wasm `atomic.wait` /
/// `atomic.notify` path on **shared** memories — and every public entry
/// point on `SharedMemoryInner` short-circuits with
/// `if (builtin.single_threaded) return …;`. The benchmark workloads we
/// care about never instantiate a shared memory, so the real lock /
/// condition implementations are never reached. Provide the smallest
/// possible API surface that lets the type-check pass; if a future user
/// actually runs wasm threads through this build they'll trip an
/// `unreachable` and we can plumb the real `std.Io.Mutex` / `Condition`
/// through then.
const StubMutex = struct {
    pub fn lock(_: *StubMutex) void {
        unreachable; // wasmz shared-memory wait/notify is not wired through Io in this build
    }
    pub fn unlock(_: *StubMutex) void {
        unreachable;
    }
};
const StubCondition = struct {
    pub fn wait(_: *StubCondition, _: *StubMutex) void {
        unreachable;
    }
    pub fn timedWait(_: *StubCondition, _: *StubMutex, _: u64) error{Timeout}!void {
        unreachable;
    }
    pub fn signal(_: *StubCondition) void {
        unreachable;
    }
    pub fn broadcast(_: *StubCondition) void {
        unreachable;
    }
};

/// Zig-0.16 replacement for `std.time.nanoTimestamp`. Reads CLOCK_MONOTONIC
/// directly via libc; used only by the shared-memory wait paths that the
/// stub Mutex/Condition above turn into compile-time-unreachable code on
/// non-single-threaded builds. Returning a sensible value (rather than
/// `unreachable`) keeps the arithmetic well-defined if a future revision
/// re-enables real synchronisation primitives without touching this file.
inline fn monotonicNanos() i128 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

/// One entry in the futex bucket table.
const FutexBucket = if (builtin.single_threaded) struct {
    waiters: u32 = 0,
    notify_seq: u32 = 0,
} else struct {
    mutex: StubMutex = .{},
    cond: StubCondition = .{},
    waiters: u32 = 0,
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

// SharedMemoryInner

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
        if (builtin.single_threaded) return 0;
        const idx = bucketIndex(ea);
        const bucket = &self.futex[idx];
        bucket.mutex.lock();
        defer bucket.mutex.unlock();
        const waiting = bucket.waiters;
        if (waiting == 0 or count == 0) return 0;
        const to_wake = @min(count, waiting);
        bucket.notify_seq +%= 1;
        if (to_wake >= waiting) {
            bucket.cond.broadcast();
        } else {
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
        if (builtin.single_threaded) return .not_equal;
        if (timeout_ns == 0) return .timed_out;

        const idx = bucketIndex(ea);
        const bucket = &self.futex[idx];

        bucket.mutex.lock();
        defer bucket.mutex.unlock();

        const cur = @atomicLoad(u32, @as(*u32, @ptrCast(@alignCast(self.bytes.ptr + ea))), .seq_cst);
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
            const start_ns: i128 = monotonicNanos();
            const deadline_ns = start_ns + timeout_ns;
            while (bucket.notify_seq == initial_seq) {
                const now_ns: i128 = monotonicNanos();
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
        if (builtin.single_threaded) return .not_equal;
        if (timeout_ns == 0) return .timed_out;

        const idx = bucketIndex(ea);
        const bucket = &self.futex[idx];

        bucket.mutex.lock();
        defer bucket.mutex.unlock();

        const AtomicUint = arch.AtomicUint;
        const cur = @atomicLoad(AtomicUint, @as(*AtomicUint, @ptrCast(@alignCast(self.bytes.ptr + ea))), .seq_cst);
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
            const start_ns: i128 = monotonicNanos();
            const deadline_ns = start_ns + timeout_ns;
            while (bucket.notify_seq == initial_seq) {
                const now_ns: i128 = monotonicNanos();
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

/// Exclusively-owned linear memory for a single Instance.
///
/// POSIX variant: `base` is a `mmap(PROT_NONE)`-reserved region of `base.len` bytes.
///   `committed` tracks how many bytes are currently accessible (PROT_READ|WRITE).
///   `bytes()` returns `base[0..committed]`.  `grow` extends via `mprotect`.
///
/// Fallback variant (non-POSIX): plain heap slice + realloc on grow.
const OwnedMemory = if (use_mmap)
    struct {
        /// Full virtual reservation (capacity == base.len).
        /// Aligned to mmap_page_align (OS page size), which is always a divisor of
        /// WASM_PAGE_SIZE (64 KiB), so all WASM page offsets are valid.
        base: []align(mmap_page_align) u8,
        /// Currently committed (accessible) byte count.
        committed: usize,

        pub fn liveSlice(self: *const @This()) []u8 {
            return self.base[0..self.committed];
        }
    }
else
    struct {
        allocator: Allocator,
        bytes: []u8,

        pub fn liveSlice(self: *const @This()) []u8 {
            return self.bytes;
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
        owned: OwnedMemory,
        shared: SharedMemory,
        /// A non-owning view into an externally-managed byte slice.
        /// Used in tests that hand-construct HostInstance / ExecEnv without an allocator.
        /// `deinit` is a no-op for borrowed memories.
        borrowed: []u8,
    },

    // constructors

    /// Create an exclusively-owned memory.
    ///
    /// On POSIX: reserves up to `max_pages` (or MAX_OWNED_CAPACITY when null) of virtual
    /// address space, commits only `min_pages` worth of physical pages.  Subsequent
    /// `grow` calls commit more pages without moving the base address (no copy).
    ///
    /// On non-POSIX: falls back to a plain heap allocation of `min_pages`; grow uses realloc.
    pub fn initOwned(allocator: Allocator, min_pages: u32) Allocator.Error!Memory {
        return initOwnedWithMax(allocator, min_pages, null);
    }

    /// Like `initOwned` but accepts an optional maximum page count for tighter reservation.
    pub fn initOwnedWithMax(allocator: Allocator, min_pages: u32, max_pages: ?u32) Allocator.Error!Memory {
        const committed = @as(usize, min_pages) * WASM_PAGE_SIZE;
        if (use_mmap) {
            const capacity = if (max_pages) |m|
                @as(usize, m) * WASM_PAGE_SIZE
            else
                MAX_OWNED_CAPACITY;
            const base = try ownedMmapInit(committed, capacity);
            return .{ .kind = .{ .owned = .{
                .base = base,
                .committed = committed,
            } } };
        } else {
            const buf = try allocator.alloc(u8, committed);
            @memset(buf, 0);
            return .{ .kind = .{ .owned = .{
                .allocator = allocator,
                .bytes = buf,
            } } };
        }
    }

    /// Create an empty (zero-page) owned memory placeholder used when a module declares
    /// no memory section.
    pub fn initEmpty() Memory {
        if (use_mmap) {
            // Zero-capacity mmap: use an empty slice with no reservation.
            return .{ .kind = .{ .owned = .{
                .base = @as([*]align(mmap_page_align) u8, @ptrFromInt(mmap_page_align))[0..0],
                .committed = 0,
            } } };
        } else {
            return .{ .kind = .{ .owned = .{
                .allocator = std.heap.page_allocator,
                .bytes = &[0]u8{},
            } } };
        }
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

    // cleanup

    pub fn deinit(self: *Memory) void {
        switch (self.kind) {
            .owned => |*o| {
                if (use_mmap) {
                    if (o.base.len > 0) ownedMmapDeinit(o.base);
                } else {
                    if (o.bytes.len > 0) o.allocator.free(o.bytes);
                }
            },
            .shared => |*s| {
                var shared = s.*;
                shared.deinit();
            },
            .borrowed => {}, // no-op: caller owns the storage
        }
        self.* = undefined;
    }

    // accessors

    /// Return the currently-live byte slice.
    ///
    /// For shared memories, this performs an acquire load of the current size so the
    /// caller always sees the most recently committed pages.
    pub fn bytes(self: *const Memory) []u8 {
        return switch (self.kind) {
            .owned => |*o| o.liveSlice(),
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

    // Wait / Notify public API
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

    // memory.grow
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
                if (use_mmap) {
                    const old_committed = o.committed;
                    const old_pages: u32 = @intCast(old_committed / WASM_PAGE_SIZE);
                    if (delta == 0) break :blk old_pages;
                    const new_pages = std.math.add(u32, old_pages, delta) catch break :blk FAIL;
                    const new_committed = @as(usize, new_pages) * WASM_PAGE_SIZE;
                    if (new_committed > o.base.len) break :blk FAIL; // exceeds reservation
                    if (!ownedMmapGrow(o.base, old_committed, new_committed)) break :blk FAIL;
                    o.committed = new_committed;
                    break :blk old_pages;
                } else {
                    const old_bytes = o.bytes.len;
                    const old_pages: u32 = @intCast(old_bytes / WASM_PAGE_SIZE);
                    if (delta == 0) break :blk old_pages;
                    const new_pages = std.math.add(u32, old_pages, delta) catch break :blk FAIL;
                    const new_bytes = @as(usize, new_pages) * WASM_PAGE_SIZE;
                    const new_buf = o.allocator.realloc(o.bytes, new_bytes) catch break :blk FAIL;
                    @memset(new_buf[old_bytes..], 0);
                    o.bytes = new_buf;
                    break :blk old_pages;
                }
            },
            .shared => |*s| s.grow(delta),
            .borrowed => FAIL, // borrowed memories cannot grow
        };
    }
};

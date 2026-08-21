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
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Default reservation for wasm32 memories without an explicit maximum.
const MAX_WASM32_CAPACITY: usize = std.math.cast(usize, arch.max_wasm32_linear_memory_bytes) orelse std.math.maxInt(usize);
/// Default reservation for memory64 memories without an explicit maximum.
const MAX_MEMORY64_CAPACITY: usize = arch.max_linear_memory_bytes;

inline fn pagesToBytes(pages: u64) ?usize {
    const bytes = std.math.mul(u64, pages, WASM_PAGE_SIZE) catch return null;
    return std.math.cast(usize, bytes);
}

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
/// Allocate a virtual address region of `capacity` bytes with no physical pages
/// committed (PROT_NONE), then commit the first `committed` bytes.
/// Returns a pointer to the base of the region and the full capacity slice.
fn ownedMmapInit(committed: usize, capacity: usize) Allocator.Error![]align(mmap_page_align) u8 {
    if (use_mmap) {
        const posix = std.posix;
        const prot_none: posix.PROT = .{};
        const base = posix.mmap(
            null,
            capacity,
            prot_none,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return error.OutOfMemory;
        if (committed > 0) {
            std.process.protectMemory(base[0..committed], .{ .read = true, .write = true }) catch {
                posix.munmap(base);
                return error.OutOfMemory;
            };
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
        std.process.protectMemory(new_range, .{ .read = true, .write = true }) catch return false;
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

/// One entry in the futex bucket table.
const FutexBucket = if (builtin.single_threaded) struct {
    waiters: u32 = 0,
    notify_seq: u32 = 0,
} else struct {
    slock: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    waiters: u32 = 0,
    notify_seq: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn acquire(bucket: *@This()) void {
        while (bucket.slock.swap(1, .acquire) != 0) {
            std.atomic.spinLoopHint();
        }
    }
    fn release(bucket: *@This()) void {
        bucket.slock.store(0, .release);
    }
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
    io: Io,
    /// Entire reserved region (capacity == max_size).
    bytes: []align(8) u8,
    /// Atomically-readable current size in bytes.
    current_size: std.atomic.Value(usize),
    /// Futex bucket table for wait/notify.
    futex: [FUTEX_BUCKETS]FutexBucket,

    fn init(allocator: Allocator, io: Io, min_bytes: usize, max_bytes: usize) Allocator.Error!*SharedMemoryInner {
        const ptr = try allocator.create(SharedMemoryInner);
        errdefer allocator.destroy(ptr);
        const bytes = try allocator.alignedAlloc(u8, @enumFromInt(3), max_bytes);
        @memset(bytes, 0);
        ptr.* = .{
            .allocator = allocator,
            .io = io,
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
    inline fn bucketIndex(ea: usize) usize {
        // Shift right by 2 (i.e., index by word, not byte) before masking to
        // reduce collisions for adjacent 32-bit accesses.
        return (ea >> 2) & (FUTEX_BUCKETS - 1);
    }

    /// memory.atomic.notify: wake up to `count` threads waiting on `ea`.
    /// Returns the number of threads actually woken.
    pub fn notify(self: *SharedMemoryInner, ea: usize, count: u32) u32 {
        if (builtin.single_threaded) return 0;
        if (ea >= self.bytes.len) return 0;
        const idx = bucketIndex(ea);
        const bucket = &self.futex[idx];
        bucket.acquire();
        defer bucket.release();
        const waiting = bucket.waiters;
        if (waiting == 0 or count == 0) return 0;
        _ = bucket.notify_seq.fetchAdd(1, .release);
        return waiting;
    }

    /// memory.atomic.wait32: block until mem[ea] != expected or timeout expires.
    /// `timeout_ns`: negative means no timeout (wait forever).
    pub fn wait32(
        self: *SharedMemoryInner,
        ea: usize,
        expected: u32,
        timeout_ns: i64,
    ) WaitResult {
        if (builtin.single_threaded) return .not_equal;
        if (timeout_ns == 0) return .timed_out;
        if (ea + @sizeOf(u32) > self.bytes.len) return .not_equal;

        const idx = bucketIndex(ea);
        const bucket = &self.futex[idx];

        bucket.acquire();
        defer bucket.release();

        const cur = @atomicLoad(u32, @as(*u32, @ptrCast(@alignCast(self.bytes.ptr + ea))), .seq_cst);
        if (cur != expected) return .not_equal;

        bucket.waiters += 1;
        defer bucket.waiters -= 1;

        const initial_seq = bucket.notify_seq.load(.acquire);

        if (timeout_ns < 0) {
            bucket.release();
            while (bucket.notify_seq.load(.acquire) == initial_seq) {
                std.atomic.spinLoopHint();
            }
            bucket.acquire();
            return .ok;
        } else {
            bucket.release();
            const start_ts = Io.Timestamp.now(self.io, .awake);
            const deadline_ns = start_ts.nanoseconds + timeout_ns;
            while (true) {
                if (bucket.notify_seq.load(.acquire) != initial_seq) {
                    bucket.acquire();
                    return .ok;
                }
                const now_ts = Io.Timestamp.now(self.io, .awake);
                if (now_ts.nanoseconds >= deadline_ns) {
                    bucket.acquire();
                    return .timed_out;
                }
                std.atomic.spinLoopHint();
            }
        }
    }

    /// memory.atomic.wait64: same as wait32 but operates on a u64 value.
    pub fn wait64(
        self: *SharedMemoryInner,
        ea: usize,
        expected: u64,
        timeout_ns: i64,
    ) WaitResult {
        if (builtin.single_threaded) return .not_equal;
        if (timeout_ns == 0) return .timed_out;
        const AtomicUint = arch.AtomicUint;
        if (ea + @sizeOf(AtomicUint) > self.bytes.len) return .not_equal;

        const idx = bucketIndex(ea);
        const bucket = &self.futex[idx];

        bucket.acquire();
        defer bucket.release();

        const cur = @atomicLoad(AtomicUint, @as(*AtomicUint, @ptrCast(@alignCast(self.bytes.ptr + ea))), .seq_cst);
        if (cur != expected) return .not_equal;

        bucket.waiters += 1;
        defer bucket.waiters -= 1;

        const initial_seq = bucket.notify_seq.load(.acquire);

        if (timeout_ns < 0) {
            bucket.release();
            while (bucket.notify_seq.load(.acquire) == initial_seq) {
                std.atomic.spinLoopHint();
            }
            bucket.acquire();
            return .ok;
        } else {
            bucket.release();
            const start_ts = Io.Timestamp.now(self.io, .awake);
            const deadline_ns = start_ts.nanoseconds + timeout_ns;
            while (true) {
                if (bucket.notify_seq.load(.acquire) != initial_seq) {
                    bucket.acquire();
                    return .ok;
                }
                const now_ts = Io.Timestamp.now(self.io, .awake);
                if (now_ts.nanoseconds >= deadline_ns) {
                    bucket.acquire();
                    return .timed_out;
                }
                std.atomic.spinLoopHint();
            }
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
    pub fn init(allocator: Allocator, io: Io, min_pages: u64, max_pages: u64) Allocator.Error!SharedMemory {
        const min_bytes = pagesToBytes(min_pages) orelse return error.OutOfMemory;
        const max_bytes = pagesToBytes(max_pages) orelse return error.OutOfMemory;
        const refcount = try allocator.create(std.atomic.Value(usize));
        errdefer allocator.destroy(refcount);
        refcount.* = std.atomic.Value(usize).init(1);

        const inner = try SharedMemoryInner.init(
            allocator,
            io,
            min_bytes,
            max_bytes,
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
    pub fn notify(self: *SharedMemory, ea: usize, count: u32) u32 {
        return self.inner.notify(ea, count);
    }

    /// Forward memory.atomic.wait32 to the inner futex table.
    pub fn wait32(self: *SharedMemory, ea: usize, expected: u32, timeout_ns: i64) WaitResult {
        return self.inner.wait32(ea, expected, timeout_ns);
    }

    /// Forward memory.atomic.wait64 to the inner futex table.
    pub fn wait64(self: *SharedMemory, ea: usize, expected: u64, timeout_ns: i64) WaitResult {
        return self.inner.wait64(ea, expected, timeout_ns);
    }

    /// memory.grow: atomically grow the shared memory by `delta` pages.
    ///
    /// Returns the old page count on success, `maxInt(u64)` on failure.
    pub fn grow(self: *SharedMemory, delta: u64) u64 {
        const FAIL = std.math.maxInt(u64);
        if (delta == 0) {
            const old_bytes = self.inner.current_size.load(.acquire);
            return old_bytes / WASM_PAGE_SIZE;
        }
        const max_bytes = self.inner.bytes.len;
        const max_pages = max_bytes / WASM_PAGE_SIZE;

        while (true) {
            const old_bytes = self.inner.current_size.load(.acquire);
            const old_pages = old_bytes / WASM_PAGE_SIZE;
            const new_pages = std.math.add(u64, old_pages, delta) catch return FAIL;
            if (new_pages > max_pages) return FAIL;
            const new_bytes = new_pages * WASM_PAGE_SIZE;
            const new_bytes_usize = std.math.cast(usize, new_bytes) orelse return FAIL;
            if (self.inner.current_size.cmpxchgWeak(old_bytes, new_bytes_usize, .acq_rel, .acquire) == null) {
                return old_pages;
            }
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

/// Reference-counted backing for a non-shared Wasm memory.
///
/// A linker can provide a normal (non-Threads) memory to more than one instance.
/// It therefore needs ownership semantics distinct from Wasm's `shared` memory:
/// clones share the allocation, but `isShared()` remains false.
const OwnedMemoryInner = struct {
    allocator: Allocator,
    ref_count: std.atomic.Value(usize),
    backing: OwnedMemory,

    fn retain(self: *OwnedMemoryInner) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    fn release(self: *OwnedMemoryInner) void {
        if (self.ref_count.fetchSub(1, .acq_rel) != 1) return;
        if (comptime use_mmap) {
            if (self.backing.base.len > 0) ownedMmapDeinit(self.backing.base);
        }
        self.allocator.destroy(self);
    }
};

const OwnedHeapMemoryInner = struct {
    allocator: Allocator,
    ref_count: std.atomic.Value(usize),
    max_pages: ?u64,
    bytes: []u8,

    fn retain(self: *OwnedHeapMemoryInner) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    fn release(self: *OwnedHeapMemoryInner) void {
        if (self.ref_count.fetchSub(1, .acq_rel) != 1) return;
        if (self.bytes.len > 0) self.allocator.free(self.bytes);
        self.allocator.destroy(self);
    }
};

/// The backing store tag: either owned, Wasm-shared, or borrowed (no-alloc view).
pub const MemoryKind = enum { owned, owned_heap, shared, borrowed };

/// WebAssembly linear memory.
///
/// This value is stored inside `Instance` (for owned memories) or shared across Instances
/// (for shared memories).  The VM always accesses memory through `Memory.bytes()`.
pub const Memory = struct {
    kind: union(MemoryKind) {
        owned: *OwnedMemoryInner,
        owned_heap: *OwnedHeapMemoryInner,
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
    pub fn initOwned(allocator: Allocator, min_pages: u64) Allocator.Error!Memory {
        return initOwnedWithMax(allocator, min_pages, null, false);
    }

    /// Like `initOwned` but accepts an optional maximum page count for tighter reservation.
    pub fn initOwnedWithMax(allocator: Allocator, min_pages: u64, max_pages: ?u64, memory64: bool) Allocator.Error!Memory {
        const committed = pagesToBytes(min_pages) orelse return error.OutOfMemory;
        const use_heap_owned = memory64 and max_pages == null;
        if (use_mmap and !use_heap_owned) {
            const inner = try allocator.create(OwnedMemoryInner);
            errdefer allocator.destroy(inner);
            const capacity = if (max_pages) |m|
                pagesToBytes(m) orelse return error.OutOfMemory
            else
                MAX_WASM32_CAPACITY;
            const base = try ownedMmapInit(committed, capacity);
            inner.* = .{
                .allocator = allocator,
                .ref_count = std.atomic.Value(usize).init(1),
                .backing = .{ .base = base, .committed = committed },
            };
            return .{ .kind = .{ .owned = inner } };
        } else {
            const inner = try allocator.create(OwnedHeapMemoryInner);
            errdefer allocator.destroy(inner);
            const buf = try allocator.alloc(u8, committed);
            errdefer allocator.free(buf);
            @memset(buf, 0);
            inner.* = .{
                .allocator = allocator,
                .ref_count = std.atomic.Value(usize).init(1),
                .max_pages = max_pages,
                .bytes = buf,
            };
            return .{ .kind = .{ .owned_heap = inner } };
        }
    }

    /// Create an empty (zero-page) owned memory placeholder used when a module declares
    /// no memory section.
    pub fn initEmpty() Memory {
        return .{ .kind = .{ .borrowed = &.{} } };
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
            .owned => |o| o.release(),
            .owned_heap => |o| o.release(),
            .shared => |*s| {
                var shared = s.*;
                shared.deinit();
            },
            .borrowed => {},
        }
        self.* = undefined;
    }

    pub fn bytes(self: *const Memory) []u8 {
        return switch (self.kind) {
            .owned => |o| o.backing.liveSlice(),
            .owned_heap => |o| o.bytes,
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
    pub fn pageCount(self: *const Memory) u64 {
        return @divTrunc(@as(u64, self.byteLen()), WASM_PAGE_SIZE);
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
    pub fn notify(self: *Memory, ea: usize, count: u32) u32 {
        return switch (self.kind) {
            .shared => |*s| s.notify(ea, count),
            .owned, .owned_heap, .borrowed => 0,
        };
    }

    pub fn wait32(self: *Memory, ea: usize, expected: u32, timeout_ns: i64) WaitResult {
        return switch (self.kind) {
            .shared => |*s| s.wait32(ea, expected, timeout_ns),
            .owned, .owned_heap, .borrowed => .not_equal,
        };
    }

    pub fn wait64(self: *Memory, ea: usize, expected: u64, timeout_ns: i64) WaitResult {
        return switch (self.kind) {
            .shared => |*s| s.wait64(ea, expected, timeout_ns),
            .owned, .owned_heap, .borrowed => .not_equal,
        };
    }

    pub fn grow(self: *Memory, delta: u64) u64 {
        const FAIL = std.math.maxInt(u64);
        return switch (self.kind) {
            .owned => |o| blk: {
                if (comptime use_mmap) {
                    const old_committed = o.backing.committed;
                    const old_pages = old_committed / WASM_PAGE_SIZE;
                    if (delta == 0) break :blk old_pages;
                    const new_pages = std.math.add(u64, old_pages, delta) catch break :blk FAIL;
                    const new_committed = pagesToBytes(new_pages) orelse break :blk FAIL;
                    if (new_committed > o.backing.base.len) break :blk FAIL;
                    if (!ownedMmapGrow(o.backing.base, old_committed, new_committed)) break :blk FAIL;
                    o.backing.committed = new_committed;
                    break :blk old_pages;
                } else {
                    unreachable;
                }
            },
            .owned_heap => |o| blk: {
                const old_bytes = o.bytes.len;
                const old_pages = @divTrunc(@as(u64, old_bytes), WASM_PAGE_SIZE);
                if (delta == 0) break :blk old_pages;
                const new_pages = std.math.add(u64, old_pages, delta) catch break :blk FAIL;
                if (o.max_pages) |max_pages| if (new_pages > max_pages) break :blk FAIL;
                const new_bytes = pagesToBytes(new_pages) orelse break :blk FAIL;
                const new_buf = o.allocator.realloc(o.bytes, new_bytes) catch break :blk FAIL;
                @memset(new_buf[old_bytes..], 0);
                o.bytes = new_buf;
                break :blk old_pages;
            },
            .shared => |*s| s.grow(delta),
            .borrowed => FAIL,
        };
    }

    pub fn clone(self: Memory) Memory {
        return switch (self.kind) {
            .owned => |o| blk: {
                o.retain();
                break :blk .{ .kind = .{ .owned = o } };
            },
            .owned_heap => |o| blk: {
                o.retain();
                break :blk .{ .kind = .{ .owned_heap = o } };
            },
            .shared => |s| .{ .kind = .{ .shared = s.clone() } },
            .borrowed => self,
        };
    }
};

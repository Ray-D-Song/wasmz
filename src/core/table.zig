const std = @import("std");
const ValType = @import("value/type.zig").ValType;

const Allocator = std.mem.Allocator;

/// An entry in a runtime WebAssembly Table.
///
/// Supports both `funcref` and `externref`:
///   - Null reference: `raw == 0`, `func_idx == maxInt(u32)`, `owner == null`.
///   - Local `funcref`: `raw == func_idx + 1`, `func_idx == local_func_idx`, `owner == instance_id`.
///   - Foreign `funcref` (from another instance or host): `foreign != null`, `raw != 0`.
///   - `externref`: `raw == host_id` (non-zero), `func_idx == maxInt(u32)`.
pub const ForeignFunc = struct {
    /// Pinned opaque pointer to the callee context (e.g. *CInstance or host callable).
    ctx: *anyopaque,
    /// Exported/internal function index when backed by another wasmz Instance, or 0 for pure host funcs.
    func_idx: u32,
    param_types: []const ValType,
    result_types: []const ValType,
    /// Callback invoked for cross-instance `call_indirect` or `table.set` invocation.
    /// Returns true on normal completion, false on trap (caller fills trap if trap_msg set or generic trap).
    trampoline: *const fn (
        ctx: *anyopaque,
        func_idx: u32,
        args: []const u64,
        results: []u64,
        trap_out: *?[*:0]const u8,
    ) bool,
};

pub const TableEntry = struct {
    raw: u64 = 0,
    func_idx: u32 = std.math.maxInt(u32),
    owner_id: u64 = 0,
    foreign: ?*const ForeignFunc = null,

    pub const null_entry: TableEntry = .{};

    pub fn fromFunc(func_idx: u32, owner_id: u64) TableEntry {
        return .{
            .raw = @as(u64, func_idx) + 1,
            .func_idx = func_idx,
            .owner_id = owner_id,
            .foreign = null,
        };
    }

    pub fn fromFuncWithForeign(func_idx: u32, owner_id: u64, foreign: ?*const ForeignFunc) TableEntry {
        return .{
            .raw = @as(u64, func_idx) + 1,
            .func_idx = func_idx,
            .owner_id = owner_id,
            .foreign = foreign,
        };
    }

    pub fn fromForeign(tag: u64, foreign: *const ForeignFunc) TableEntry {
        return .{
            .raw = if (tag == 0) 1 else tag,
            .func_idx = std.math.maxInt(u32),
            .owner_id = 0,
            .foreign = foreign,
        };
    }

    pub fn fromExternRef(raw: u64) TableEntry {
        return .{
            .raw = raw,
            .func_idx = std.math.maxInt(u32),
            .owner_id = 0,
            .foreign = null,
        };
    }

    pub fn isNull(self: TableEntry) bool {
        return self.raw == 0 and self.foreign == null;
    }
};

pub const SharedTableInner = struct {
    allocator: Allocator,
    elem_type: ValType,
    min: u32,
    max: ?u32,
    entries: []TableEntry,
    version: u64 = 0,
    refs: std.atomic.Value(usize),
};

/// Reference-counted, shareable runtime WebAssembly Table (`funcref` or `externref`).
pub const SharedTable = struct {
    inner: *SharedTableInner,

    pub fn init(
        allocator: Allocator,
        elem_type: ValType,
        min_len: u32,
        max_len: ?u32,
        init_entry: TableEntry,
    ) Allocator.Error!SharedTable {
        const entries = try allocator.alloc(TableEntry, min_len);
        errdefer allocator.free(entries);
        @memset(entries, init_entry);

        const inner = try allocator.create(SharedTableInner);
        inner.* = .{
            .allocator = allocator,
            .elem_type = elem_type,
            .min = min_len,
            .max = max_len,
            .entries = entries,
            .refs = std.atomic.Value(usize).init(1),
        };
        return .{ .inner = inner };
    }

    pub fn clone(self: SharedTable) SharedTable {
        _ = self.inner.refs.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn deinit(self: *SharedTable) void {
        const prev = self.inner.refs.fetchSub(1, .acq_rel);
        if (prev == 1) {
            const allocator = self.inner.allocator;
            if (self.inner.entries.len > 0) {
                allocator.free(self.inner.entries);
            }
            allocator.destroy(self.inner);
        }
        self.* = undefined;
    }

    pub inline fn len(self: SharedTable) usize {
        return self.inner.entries.len;
    }

    pub inline fn max(self: SharedTable) ?u32 {
        return self.inner.max;
    }

    pub inline fn elemType(self: SharedTable) ValType {
        return self.inner.elem_type;
    }

    pub inline fn get(self: SharedTable, idx: usize) ?TableEntry {
        if (idx >= self.inner.entries.len) return null;
        return self.inner.entries[idx];
    }

    pub inline fn set(self: SharedTable, idx: usize, entry: TableEntry) bool {
        if (idx >= self.inner.entries.len) return false;
        self.inner.entries[idx] = entry;
        self.inner.version +%= 1;
        return true;
    }

    pub fn grow(self: SharedTable, delta: u32, init_entry: TableEntry) ?u32 {
        const old_len = self.inner.entries.len;
        const new_len_u64 = @as(u64, old_len) + @as(u64, delta);
        if (new_len_u64 > std.math.maxInt(u32)) return null;
        if (self.inner.max) |m| {
            if (new_len_u64 > m) return null;
        }
        if (delta == 0) return @intCast(old_len);

        const new_len: usize = @intCast(new_len_u64);
        const new_slice = self.inner.allocator.realloc(self.inner.entries, new_len) catch return null;
        self.inner.entries = new_slice;
        @memset(self.inner.entries[old_len..], init_entry);
        self.inner.version +%= 1;
        return @intCast(old_len);
    }
};

/// capi.zig — wasmz C API implementation
///
/// This file implements the functions declared in include/wasmz.h.
/// It is compiled as a shared library (libwasmz) or static library.
///
/// Design decisions:
///   - All allocations use Zig's process-wide allocator. The C API never
///     transfers ownership of its allocations to callers: every handle and
///     error is released with its matching `wasmz_*_delete` function. This
///     keeps a static library compatible with Rust's MSVC CRT selection.
///   - Opaque handle types are thin C-ABI structs that hold a single pointer
///     to a heap-allocated Zig struct.  This avoids "extern struct cannot
///     contain non-extern type" errors.
///   - wasmz_error_t is a heap-allocated struct holding a NUL-terminated message.
const std = @import("std");
const wasmz = @import("wasmz");

const Engine = wasmz.Engine;
const Config = wasmz.Config;
const Module = wasmz.Module;
const Store = wasmz.Store;
const Instance = wasmz.Instance;
const ArcModule = wasmz.ArcModule;
const RawVal = wasmz.RawVal;
const Linker = wasmz.Linker;
const HostContext = wasmz.HostContext;
const HostFunc = wasmz.HostFunc;
const HostError = wasmz.HostError;
const ValType = wasmz.ValType;
const Trap = wasmz.Trap;
const Allocator = std.mem.Allocator;

// This allocation domain crosses the Rust/MSVC boundary only through opaque
// handles that are released by the matching C API delete functions.  Use the
// OS page allocator instead of a process-global slab allocator so teardown is
// independent of the host executable's CRT and thread-local allocator state.
const alloc = std.heap.page_allocator;

/// Panicking across the C ABI cannot be recovered from, so there is nothing to
/// gain from Zig's stack-trace machinery here. Skipping it also keeps
/// `std.debug.SelfInfo` out of the archive, which on windows-msvc would
/// otherwise need `LdrRegisterDllNotification` — a symbol the Windows SDK's
/// ntdll import library does not provide.
pub const panic = std.debug.FullPanic(struct {
    fn call(msg: []const u8, _: ?usize) noreturn {
        std.debug.print("wasmz: panic: {s}\n", .{msg});
        std.process.abort();
    }
}.call);

// Error type

/// Opaque error handle exposed to C.
/// The struct is extern so that its pointer is ABI-stable; the message field
/// is a plain C string pointer.
pub const wasmz_error_t = extern struct {
    /// NUL-terminated message, owned by this struct.
    message: [*:0]u8,
};

fn makeError(comptime fmt: []const u8, args: anytype) *wasmz_error_t {
    const msg = std.fmt.allocPrintSentinel(alloc, fmt, args, 0) catch
        return makeStaticError("(out of memory formatting error)");
    const err = alloc.create(wasmz_error_t) catch {
        alloc.free(msg);
        return makeStaticError("(out of memory allocating error)");
    };
    err.* = .{ .message = msg.ptr };
    return err;
}

fn makeStaticError(comptime msg: [:0]const u8) *wasmz_error_t {
    // Use a comptime-constant duped copy so we can always call free on it.
    const static = struct {
        var buf: wasmz_error_t = .{ .message = @constCast(msg.ptr) };
    };
    return &static.buf;
}

export fn wasmz_error_delete(err: ?*wasmz_error_t) void {
    const e = err orelse return;
    const msg = std.mem.span(e.message);
    // Don't free static sentinel messages
    const is_static_oom1 = std.mem.eql(u8, msg, "(out of memory formatting error)");
    const is_static_oom2 = std.mem.eql(u8, msg, "(out of memory allocating error)");
    if (!is_static_oom1 and !is_static_oom2) {
        // The slice was allocated with allocPrintSentinel; free the sentinel slice.
        const sentinel_slice: [:0]u8 = @ptrCast(msg);
        alloc.free(sentinel_slice);
        alloc.destroy(e);
    }
}

export fn wasmz_error_message(err: ?*const wasmz_error_t) [*:0]const u8 {
    const e = err orelse return "(null)";
    return e.message;
}

// Value type

/// Must stay in sync with the C enum wasmz_val_kind_t in include/wasmz.h
const ValKind = enum(c_int) {
    I32 = 0,
    I64 = 1,
    F32 = 2,
    F64 = 3,
    V128 = 4,
    REF_NULL = 5,
    REF_FUNC = 6,
    EXTERN_REF = 7,
    _,

    /// The core `ValType` a C value kind maps onto, or null when the kind is
    /// not (yet) transferable across the C boundary.
    fn toValType(self: ValKind) ?ValType {
        return switch (self) {
            .I32 => ValType.I32,
            .I64 => ValType.I64,
            .F32 => ValType.F32,
            .F64 => ValType.F64,
            else => null,
        };
    }
};

/// Must stay in sync with wasmz_val_t in include/wasmz.h
pub const wasmz_val_t = extern struct {
    kind: ValKind,
    _pad: [4]u8 = .{ 0, 0, 0, 0 },
    of: extern union {
        i32: i32,
        i64: i64,
        f32: f32,
        f64: f64,
        v128: [16]u8,
        func_ref: u32,
        extern_ref: ?*anyopaque,
    },

    comptime {
        // The C header is the published ABI contract; a mismatch here silently
        // corrupts every multi-value host call. Size and field offsets are
        // fixed by the header regardless of target, so they're asserted
        // exactly. Alignment is intentionally *not* pinned to a literal: the
        // i386 System V ABI only aligns 8-byte members (double/int64_t) to 4
        // bytes, so a real C compiler targeting x86-linux computes
        // `alignof(wasmz_val_t) == 4` there, vs. 8 on every 64-bit target.
        // Comparing against the union field's own alignment tracks whatever
        // the target's C ABI actually requires instead of hardcoding one.
        std.debug.assert(@sizeOf(wasmz_val_t) == 24);
        std.debug.assert(@alignOf(wasmz_val_t) == @alignOf(@FieldType(wasmz_val_t, "of")));
        std.debug.assert(@offsetOf(wasmz_val_t, "kind") == 0);
        std.debug.assert(@offsetOf(wasmz_val_t, "of") == 8);
    }
};

fn cvalToRaw(v: wasmz_val_t) ?RawVal {
    return switch (v.kind) {
        .I32 => RawVal.from(v.of.i32),
        .I64 => RawVal.from(v.of.i64),
        .F32 => RawVal.from(v.of.f32),
        .F64 => RawVal.from(v.of.f64),
        else => null,
    };
}

fn rawToCval(raw: RawVal, kind: ValKind) ?wasmz_val_t {
    return switch (kind) {
        .I32 => .{ .kind = kind, .of = .{ .i32 = raw.readAs(i32) } },
        .I64 => .{ .kind = kind, .of = .{ .i64 = raw.readAs(i64) } },
        .F32 => .{ .kind = kind, .of = .{ .f32 = raw.readAs(f32) } },
        .F64 => .{ .kind = kind, .of = .{ .f64 = raw.readAs(f64) } },
        else => null,
    };
}

fn kindName(kind: ValKind) []const u8 {
    return switch (kind) {
        .I32 => "i32",
        .I64 => "i64",
        .F32 => "f32",
        .F64 => "f64",
        .V128 => "v128",
        .REF_NULL => "ref.null",
        .REF_FUNC => "funcref",
        .EXTERN_REF => "externref",
        else => "<unknown>",
    };
}

// Engine

/// Opaque handle; the C header forward-declares this as `struct wasmz_engine`.
pub const wasmz_engine_t = extern struct {
    /// Pointer to a heap-allocated Engine.  Declared as *anyopaque so the
    /// struct itself is extern-compatible.
    ptr: *anyopaque,
};

export fn wasmz_engine_new() ?*wasmz_engine_t {
    return wasmz_engine_new_with_limit(0);
}

export fn wasmz_engine_new_with_limit(mem_limit_bytes: u64) ?*wasmz_engine_t {
    const eng_ptr = alloc.create(Engine) catch return null;
    const limit: ?u64 = if (mem_limit_bytes == 0) null else mem_limit_bytes;
    eng_ptr.* = Engine.init(alloc, Config{ .mem_limit_bytes = limit }) catch {
        alloc.destroy(eng_ptr);
        return null;
    };
    const handle = alloc.create(wasmz_engine_t) catch {
        eng_ptr.deinit();
        alloc.destroy(eng_ptr);
        return null;
    };
    handle.* = .{ .ptr = eng_ptr };
    return handle;
}

export fn wasmz_engine_delete(handle: ?*wasmz_engine_t) void {
    const h = handle orelse return;
    const eng: *Engine = @ptrCast(@alignCast(h.ptr));
    eng.deinit();
    alloc.destroy(eng);
    alloc.destroy(h);
}

// Store

pub const wasmz_store_t = extern struct {
    ptr: *anyopaque,
};

/// Backing object for a `wasmz_store_t` handle.
///
/// An `Instance` holds a `*Store` and still dereferences it from `deinit`, so
/// destroying the store first would corrupt the heap.  Rather than making the
/// embedder responsible for the teardown order, the store is reference counted:
/// the handle owns one reference and every live instance owns another.
const CStore = struct {
    store: Store,
    refs: usize,

    fn retain(self: *CStore) void {
        self.refs += 1;
    }

    fn release(self: *CStore) void {
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs == 0) {
            self.store.deinit();
            alloc.destroy(self);
        }
    }
};

export fn wasmz_store_new(engine_handle: ?*wasmz_engine_t) ?*wasmz_store_t {
    const eh = engine_handle orelse return null;
    const eng: *Engine = @ptrCast(@alignCast(eh.ptr));

    const cstore = alloc.create(CStore) catch return null;
    cstore.* = .{
        .store = Store.init(alloc, eng.*, std.Io.Threaded.global_single_threaded.io()) catch {
            alloc.destroy(cstore);
            return null;
        },
        .refs = 1,
    };
    cstore.store.linkBudget();

    const handle = alloc.create(wasmz_store_t) catch {
        cstore.store.deinit();
        alloc.destroy(cstore);
        return null;
    };
    handle.* = .{ .ptr = cstore };
    return handle;
}

export fn wasmz_store_delete(handle: ?*wasmz_store_t) void {
    const h = handle orelse return;
    const cstore: *CStore = @ptrCast(@alignCast(h.ptr));
    cstore.release();
    alloc.destroy(h);
}

// Module

pub const wasmz_module_t = extern struct {
    ptr: *anyopaque,
};

export fn wasmz_module_new(
    engine_handle: ?*wasmz_engine_t,
    bytes: ?[*]const u8,
    len: usize,
    out_module: ?*?*wasmz_module_t,
) ?*wasmz_error_t {
    const eh = engine_handle orelse return makeError("engine is null", .{});
    const b = bytes orelse return makeError("bytes is null", .{});
    const out = out_module orelse return makeError("out_module is null", .{});
    const eng: *Engine = @ptrCast(@alignCast(eh.ptr));

    const arc_ptr = alloc.create(ArcModule) catch
        return makeError("out of memory", .{});

    arc_ptr.* = Module.compileArc(eng.*, b[0..len]) catch |err| {
        alloc.destroy(arc_ptr);
        return makeError("module compilation failed: {s}", .{@errorName(err)});
    };

    const handle = alloc.create(wasmz_module_t) catch {
        if (arc_ptr.releaseUnwrap()) |m| {
            var mm = m;
            mm.deinit();
        }
        alloc.destroy(arc_ptr);
        return makeError("out of memory", .{});
    };
    handle.* = .{ .ptr = arc_ptr };
    out.* = handle;
    return null;
}

export fn wasmz_module_delete(handle: ?*wasmz_module_t) void {
    const h = handle orelse return;
    const arc: *ArcModule = @ptrCast(@alignCast(h.ptr));
    if (arc.releaseUnwrap()) |m| {
        var mm = m;
        mm.deinit();
    }
    alloc.destroy(arc);
    alloc.destroy(h);
}

// Instance

pub const wasmz_instance_t = extern struct {
    ptr: *anyopaque,
};

/// Backing object for a `wasmz_instance_t` handle.
///
/// `handle.ptr` points at the `instance` field so every accessor can keep
/// casting it to a plain `*Instance`; `wasmz_instance_delete` recovers the
/// owning `CInstance` with `@fieldParentPtr`.
const CInstance = struct {
    instance: Instance,
    /// Reference held on the store so it outlives this instance.
    store: *CStore,
};

/// Shared tail of `wasmz_instance_new` and `wasmz_instance_new_with_linker`.
fn instantiate(
    sh: *wasmz_store_t,
    mh: *wasmz_module_t,
    out: *?*wasmz_instance_t,
    imports: Linker,
) ?*wasmz_error_t {
    const cstore: *CStore = @ptrCast(@alignCast(sh.ptr));
    const arc: *ArcModule = @ptrCast(@alignCast(mh.ptr));

    const cinst = alloc.create(CInstance) catch
        return makeError("out of memory", .{});

    cinst.* = .{
        .instance = Instance.init(&cstore.store, arc.retain(), imports) catch |err| {
            alloc.destroy(cinst);
            return makeError("instantiation failed: {s}", .{@errorName(err)});
        },
        .store = cstore,
    };

    const handle = alloc.create(wasmz_instance_t) catch {
        cinst.instance.deinit();
        alloc.destroy(cinst);
        return makeError("out of memory", .{});
    };
    // The instance keeps the store alive regardless of deletion order.
    cstore.retain();
    handle.* = .{ .ptr = &cinst.instance };
    out.* = handle;
    return null;
}

export fn wasmz_instance_new(
    store_handle: ?*wasmz_store_t,
    module_handle: ?*wasmz_module_t,
    out_instance: ?*?*wasmz_instance_t,
) ?*wasmz_error_t {
    const sh = store_handle orelse return makeError("store is null", .{});
    const mh = module_handle orelse return makeError("module is null", .{});
    const out = out_instance orelse return makeError("out_instance is null", .{});
    return instantiate(sh, mh, out, Linker.empty);
}

export fn wasmz_instance_delete(handle: ?*wasmz_instance_t) void {
    const h = handle orelse return;
    const inst: *Instance = @ptrCast(@alignCast(h.ptr));
    const cinst: *CInstance = @fieldParentPtr("instance", inst);
    const cstore = cinst.store;
    inst.deinit();
    alloc.destroy(cinst);
    cstore.release();
    alloc.destroy(h);
}

export fn wasmz_instance_call_start(handle: ?*wasmz_instance_t) ?*wasmz_error_t {
    const h = handle orelse return makeError("instance is null", .{});
    const inst: *Instance = @ptrCast(@alignCast(h.ptr));

    // Run Wasm spec start section function first.
    if (inst.runStartFunction() catch |err|
        return makeError("start section error: {s}", .{@errorName(err)})) |res|
    {
        switch (res) {
            .ok => {},
            .trap => |t| {
                const msg = t.allocPrint(alloc) catch "trap";
                defer alloc.free(msg);
                return makeError("start section trapped: {s}", .{msg});
            },
        }
    }

    // Then call _start export if present.
    const m = inst.module.value;
    if (m.exports.get("_start") == null) return null;

    const result = inst.call("_start", &.{}) catch |err|
        return makeError("_start call failed: {s}", .{@errorName(err)});

    switch (result) {
        .ok => return null,
        .trap => |t| {
            const msg = t.allocPrint(alloc) catch "trap";
            defer alloc.free(msg);
            return makeError("_start trapped: {s}", .{msg});
        },
    }
}

export fn wasmz_instance_initialize(handle: ?*wasmz_instance_t) ?*wasmz_error_t {
    const h = handle orelse return makeError("instance is null", .{});
    const inst: *Instance = @ptrCast(@alignCast(h.ptr));

    const result = inst.initializeReactor() catch |err|
        return makeError("_initialize call failed: {s}", .{@errorName(err)});

    if (result) |res| {
        switch (res) {
            .ok => {},
            .trap => |t| {
                const msg = t.allocPrint(alloc) catch "trap";
                defer alloc.free(msg);
                return makeError("_initialize trapped: {s}", .{msg});
            },
        }
    }
    return null;
}

export fn wasmz_instance_call(
    handle: ?*wasmz_instance_t,
    func_name_ptr: ?[*:0]const u8,
    args_ptr: ?[*]const wasmz_val_t,
    args_len: usize,
    results_ptr: ?[*]wasmz_val_t,
    results_len: usize,
) ?*wasmz_error_t {
    const h = handle orelse return makeError("instance is null", .{});
    const name = func_name_ptr orelse return makeError("func_name is null", .{});
    const inst: *Instance = @ptrCast(@alignCast(h.ptr));
    const func_name = std.mem.span(name);

    // The core `Instance.call` returns at most one value, so multi-value
    // results would leave results[1..] uninitialized.  Reject them instead.
    if (results_len > 1) {
        return makeError(
            "multi-value results are not supported by the C API (results_len = {d})",
            .{results_len},
        );
    }

    // Convert C vals → RawVal
    const raw_args = alloc.alloc(RawVal, args_len) catch
        return makeError("out of memory", .{});
    defer alloc.free(raw_args);

    if (args_len > 0) {
        const args = args_ptr orelse return makeError("args is null but args_len > 0", .{});
        for (0..args_len) |i| {
            raw_args[i] = cvalToRaw(args[i]) orelse return makeError(
                "unsupported value kind for argument {d}: {s}",
                .{ i, kindName(args[i].kind) },
            );
        }
    }

    const result = inst.call(func_name, raw_args) catch |err|
        return makeError("call failed: {s}", .{@errorName(err)});

    switch (result) {
        .ok => |maybe_val| {
            if (results_len > 0) {
                const results = results_ptr orelse
                    return makeError("results is null but results_len > 0", .{});
                if (maybe_val) |val| {
                    results[0] = rawToCval(val, results[0].kind) orelse return makeError(
                        "unsupported value kind for result 0: {s}",
                        .{kindName(results[0].kind)},
                    );
                }
            }
            return null;
        },
        .trap => |t| {
            const msg = t.allocPrint(alloc) catch "trap";
            defer alloc.free(msg);
            return makeError("trap: {s}", .{msg});
        },
    }
}

export fn wasmz_instance_is_command(handle: ?*const wasmz_instance_t) c_int {
    const h = handle orelse return 0;
    const inst: *const Instance = @ptrCast(@alignCast(h.ptr));
    return if (inst.isCommand()) 1 else 0;
}

export fn wasmz_instance_is_reactor(handle: ?*const wasmz_instance_t) c_int {
    const h = handle orelse return 0;
    const inst: *const Instance = @ptrCast(@alignCast(h.ptr));
    return if (inst.isReactor()) 1 else 0;
}

// Memory

export fn wasmz_instance_memory(handle: ?*wasmz_instance_t) ?[*]u8 {
    const h = handle orelse return null;
    const inst: *Instance = @ptrCast(@alignCast(h.ptr));
    const bytes = inst.memory.bytes();
    return if (bytes.len == 0) null else bytes.ptr;
}

export fn wasmz_instance_memory_size(handle: ?*const wasmz_instance_t) usize {
    const h = handle orelse return 0;
    const inst: *const Instance = @ptrCast(@alignCast(h.ptr));
    return inst.memory.bytes().len;
}

export fn wasmz_instance_memory_grow(handle: ?*wasmz_instance_t, pages: u64) c_int {
    const h = handle orelse return -1;
    const inst: *Instance = @ptrCast(@alignCast(h.ptr));
    const prev_pages = inst.memory.grow(pages);
    if (prev_pages == std.math.maxInt(u64)) return -1;
    return 0;
}

export fn wasmz_instance_memory64(handle: ?*const wasmz_instance_t) c_int {
    const h = handle orelse return 0;
    const inst: *const Instance = @ptrCast(@alignCast(h.ptr));
    return if (inst.memory64) 1 else 0;
}

// Linker

pub const wasmz_linker_t = extern struct {
    ptr: *anyopaque,
};

pub const wasmz_func_t = *const fn (
    host_data: ?*anyopaque,
    ctx: ?*anyopaque,
    params: [*]const wasmz_val_t,
    param_count: usize,
    results: [*]wasmz_val_t,
    result_count: usize,
) callconv(.c) c_int;

/// Trampoline state for one C host function, kept alive by its `CLinker`.
const HostFuncWrapper = struct {
    func: wasmz_func_t,
    host_data: ?*anyopaque,
    /// Owned copies of the declared signature; the trampoline needs the kinds
    /// to tag the `wasmz_val_t`s it hands to the C callback.
    param_kinds: []ValKind,
    result_kinds: []ValKind,
};

/// Backing object for a `wasmz_linker_t` handle.
///
/// `Linker` borrows every string and signature slice it is given (see
/// `Linker.define` in src/wasmz/host.zig), and an `Instance` keeps the resolved
/// `HostFunc` values, so the C API must own that memory until the linker is
/// deleted.
const CLinker = struct {
    linker: Linker,
    owned: std.ArrayListUnmanaged(Owned) = .empty,

    const Owned = union(enum) {
        bytes: []u8,
        val_types: []ValType,
        kinds: []ValKind,
        wrapper: *HostFuncWrapper,
    };

    fn track(self: *CLinker, item: Owned) Allocator.Error!void {
        try self.owned.append(alloc, item);
    }

    fn dupeString(self: *CLinker, text: []const u8) Allocator.Error![]u8 {
        const copy = try alloc.dupe(u8, text);
        errdefer alloc.free(copy);
        try self.track(.{ .bytes = copy });
        return copy;
    }

    fn deinit(self: *CLinker) void {
        self.linker.deinit(alloc);
        for (self.owned.items) |item| {
            switch (item) {
                .bytes => |b| alloc.free(b),
                .val_types => |v| alloc.free(v),
                .kinds => |k| alloc.free(k),
                .wrapper => |w| alloc.destroy(w),
            }
        }
        self.owned.deinit(alloc);
    }
};

export fn wasmz_linker_new() ?*wasmz_linker_t {
    const linker_ptr = alloc.create(CLinker) catch return null;
    linker_ptr.* = .{ .linker = Linker.empty };
    const handle = alloc.create(wasmz_linker_t) catch {
        alloc.destroy(linker_ptr);
        return null;
    };
    handle.* = .{ .ptr = linker_ptr };
    return handle;
}

export fn wasmz_linker_delete(handle: ?*wasmz_linker_t) void {
    const h = handle orelse return;
    const linker: *CLinker = @ptrCast(@alignCast(h.ptr));
    linker.deinit();
    alloc.destroy(linker);
    alloc.destroy(h);
}

export fn wasmz_linker_define_func(
    handle: ?*wasmz_linker_t,
    module_name_ptr: ?[*:0]const u8,
    func_name_ptr: ?[*:0]const u8,
    param_kinds: ?[*]const ValKind,
    param_count: usize,
    result_kinds: ?[*]const ValKind,
    result_count: usize,
    func: ?wasmz_func_t,
    host_data: ?*anyopaque,
) ?*wasmz_error_t {
    const h = handle orelse return makeError("linker is null", .{});
    const mod_name_input = module_name_ptr orelse return makeError("module_name is null", .{});
    const func_name_input = func_name_ptr orelse return makeError("func_name is null", .{});
    const callback = func orelse return makeError("func is null", .{});
    if (param_count > 0 and param_kinds == null)
        return makeError("param_kinds is null but param_count > 0", .{});
    if (result_count > 0 and result_kinds == null)
        return makeError("result_kinds is null but result_count > 0", .{});

    const clinker: *CLinker = @ptrCast(@alignCast(h.ptr));

    const mod_name = clinker.dupeString(std.mem.span(mod_name_input)) catch
        return makeError("out of memory", .{});
    const func_name = clinker.dupeString(std.mem.span(func_name_input)) catch
        return makeError("out of memory", .{});

    const owned_param_kinds = copyKinds(clinker, param_kinds, param_count) catch
        return makeError("out of memory", .{});
    const owned_result_kinds = copyKinds(clinker, result_kinds, result_count) catch
        return makeError("out of memory", .{});

    const param_types = toValTypes(clinker, owned_param_kinds) catch |err| switch (err) {
        error.OutOfMemory => return makeError("out of memory", .{}),
        error.UnsupportedValKind => return makeError(
            "unsupported parameter kind in '{s}::{s}'",
            .{ mod_name, func_name },
        ),
    };
    const result_types = toValTypes(clinker, owned_result_kinds) catch |err| switch (err) {
        error.OutOfMemory => return makeError("out of memory", .{}),
        error.UnsupportedValKind => return makeError(
            "unsupported result kind in '{s}::{s}'",
            .{ mod_name, func_name },
        ),
    };

    const wrapper = alloc.create(HostFuncWrapper) catch
        return makeError("out of memory", .{});
    wrapper.* = .{
        .func = callback,
        .host_data = host_data,
        .param_kinds = owned_param_kinds,
        .result_kinds = owned_result_kinds,
    };
    clinker.track(.{ .wrapper = wrapper }) catch {
        alloc.destroy(wrapper);
        return makeError("out of memory", .{});
    };

    const host_func = HostFunc.init(wrapper, callHostTrampoline, param_types, result_types);
    clinker.linker.define(alloc, mod_name, func_name, host_func) catch |err|
        return makeError("linker define func failed: {s}", .{@errorName(err)});

    return null;
}

fn copyKinds(
    clinker: *CLinker,
    kinds: ?[*]const ValKind,
    count: usize,
) Allocator.Error![]ValKind {
    const copy = try alloc.alloc(ValKind, count);
    errdefer alloc.free(copy);
    if (count > 0) @memcpy(copy, kinds.?[0..count]);
    try clinker.track(.{ .kinds = copy });
    return copy;
}

fn toValTypes(
    clinker: *CLinker,
    kinds: []const ValKind,
) (Allocator.Error || error{UnsupportedValKind})![]ValType {
    const types = try alloc.alloc(ValType, kinds.len);
    errdefer alloc.free(types);
    for (kinds, 0..) |kind, i| {
        types[i] = kind.toValType() orelse return error.UnsupportedValKind;
    }
    try clinker.track(.{ .val_types = types });
    return types;
}

/// Host-call arity below which the trampoline uses stack buffers.
///
/// Host functions run on the hot path of the startup and CoreMark benchmarks,
/// so the common case must not allocate.  The largest signature in practice is
/// WASI's `path_open` with 9 parameters.
const max_stack_arity = 16;

fn callHostTrampoline(
    host_data: ?*anyopaque,
    ctx: *HostContext,
    params: []const RawVal,
    results: []RawVal,
) HostError!void {
    const wrapper: *HostFuncWrapper = @ptrCast(@alignCast(host_data));
    const param_count = wrapper.param_kinds.len;
    const result_count = wrapper.result_kinds.len;

    var param_buf: [max_stack_arity]wasmz_val_t = undefined;
    var result_buf: [max_stack_arity]wasmz_val_t = undefined;

    const c_params: []wasmz_val_t = if (param_count <= max_stack_arity)
        param_buf[0..param_count]
    else
        try alloc.alloc(wasmz_val_t, param_count);
    defer if (param_count > max_stack_arity) alloc.free(c_params);

    const c_results: []wasmz_val_t = if (result_count <= max_stack_arity)
        result_buf[0..result_count]
    else
        try alloc.alloc(wasmz_val_t, result_count);
    defer if (result_count > max_stack_arity) alloc.free(c_results);

    for (c_params, wrapper.param_kinds, params[0..param_count]) |*dst, kind, raw| {
        dst.* = rawToCval(raw, kind) orelse
            return ctx.raiseTrap(Trap.hostMessage("unsupported host function parameter kind"));
    }
    for (c_results, wrapper.result_kinds) |*dst, kind| {
        dst.* = rawToCval(RawVal.fromBits64(0), kind) orelse
            return ctx.raiseTrap(Trap.hostMessage("unsupported host function result kind"));
    }

    const ret = wrapper.func(
        wrapper.host_data,
        ctx,
        c_params.ptr,
        param_count,
        c_results.ptr,
        result_count,
    );
    if (ret != 0) {
        // The callback may have supplied a message via wasmz_context_trap.
        if (ctx.pending_trap == null) {
            ctx.pending_trap = Trap.hostMessage("host function returned a non-zero status");
        }
        return error.HostTrap;
    }

    for (results[0..result_count], c_results) |*dst, cr| {
        dst.* = cvalToRaw(cr) orelse
            return ctx.raiseTrap(Trap.hostMessage("unsupported host function result kind"));
    }
}

export fn wasmz_linker_define_global(
    handle: ?*wasmz_linker_t,
    module_name_ptr: ?[*:0]const u8,
    global_name_ptr: ?[*:0]const u8,
    value: wasmz_val_t,
) ?*wasmz_error_t {
    const h = handle orelse return makeError("linker is null", .{});
    const mod_name_input = module_name_ptr orelse return makeError("module_name is null", .{});
    const global_name_input = global_name_ptr orelse return makeError("global_name is null", .{});
    const clinker: *CLinker = @ptrCast(@alignCast(h.ptr));

    const raw = cvalToRaw(value) orelse return makeError(
        "unsupported value kind for global '{s}::{s}': {s}",
        .{ std.mem.span(mod_name_input), std.mem.span(global_name_input), kindName(value.kind) },
    );

    // `Linker.defineGlobal` borrows the key strings, so keep owned copies.
    const mod_slice = clinker.dupeString(std.mem.span(mod_name_input)) catch
        return makeError("out of memory", .{});
    const global_slice = clinker.dupeString(std.mem.span(global_name_input)) catch
        return makeError("out of memory", .{});

    clinker.linker.defineGlobal(alloc, mod_slice, global_slice, raw) catch |err|
        return makeError("linker define global failed: {s}", .{@errorName(err)});

    return null;
}

export fn wasmz_instance_new_with_linker(
    store_handle: ?*wasmz_store_t,
    module_handle: ?*wasmz_module_t,
    linker_handle: ?*wasmz_linker_t,
    out_instance: ?*?*wasmz_instance_t,
) ?*wasmz_error_t {
    const sh = store_handle orelse return makeError("store is null", .{});
    const mh = module_handle orelse return makeError("module is null", .{});
    const out = out_instance orelse return makeError("out_instance is null", .{});

    var linker: Linker = Linker.empty;
    if (linker_handle) |lh| {
        const clinker: *CLinker = @ptrCast(@alignCast(lh.ptr));
        linker = clinker.linker;
    }

    return instantiate(sh, mh, out, linker);
}

// Host Context

export fn wasmz_context_memory(ctx: ?*anyopaque) ?[*]u8 {
    const c: *HostContext = @ptrCast(@alignCast(ctx));
    const bytes = c.memory() orelse return null;
    return bytes.ptr;
}

export fn wasmz_context_memory_size(ctx: ?*anyopaque) usize {
    const c: *HostContext = @ptrCast(@alignCast(ctx));
    const mem = c.memory() orelse return 0;
    return mem.len;
}

export fn wasmz_context_read_memory(ctx: ?*anyopaque, addr: u32, len: usize, out: [*]u8) c_int {
    const c: *HostContext = @ptrCast(@alignCast(ctx));
    const bytes = c.readBytes(addr, len) catch return -1;
    @memcpy(out, bytes.ptr[0..len]);
    return 0;
}

export fn wasmz_context_write_memory(ctx: ?*anyopaque, addr: u32, data: ?[*]const u8, len: usize) c_int {
    const c: *HostContext = @ptrCast(@alignCast(ctx));
    const d = data orelse return -1;
    c.writeBytes(addr, d[0..len]) catch return -1;
    return 0;
}

export fn wasmz_context_read_memory64(ctx: ?*anyopaque, addr: u64, len: usize, out: [*]u8) c_int {
    const c: *HostContext = @ptrCast(@alignCast(ctx));
    const bytes = c.readBytes(addr, len) catch return -1;
    @memcpy(out, bytes.ptr[0..len]);
    return 0;
}

export fn wasmz_context_write_memory64(ctx: ?*anyopaque, addr: u64, data: ?[*]const u8, len: usize) c_int {
    const c: *HostContext = @ptrCast(@alignCast(ctx));
    const d = data orelse return -1;
    c.writeBytes(addr, d[0..len]) catch return -1;
    return 0;
}

export fn wasmz_context_read_value(ctx: ?*anyopaque, addr: u32, out: ?*anyopaque, size: usize) c_int {
    const c: *HostContext = @ptrCast(@alignCast(ctx));
    const o = out orelse return -1;
    const bytes = c.readBytes(addr, size) catch return -1;
    const out_slice = @as([*]u8, @ptrCast(o));
    @memcpy(out_slice[0..size], bytes);
    return 0;
}

export fn wasmz_context_write_value(ctx: ?*anyopaque, addr: u32, value: ?*const anyopaque, size: usize) c_int {
    const c: *HostContext = @ptrCast(@alignCast(ctx));
    const v = value orelse return -1;
    const v_slice = @as([*]const u8, @ptrCast(v));
    c.writeBytes(addr, v_slice[0..size]) catch return -1;
    return 0;
}

export fn wasmz_context_trap(ctx: ?*anyopaque, msg_ptr: ?[*:0]const u8) void {
    const c: *HostContext = @ptrCast(@alignCast(ctx));
    const m = msg_ptr orelse return;
    const msg = std.mem.span(m);
    const trap = Trap.hostMessage(msg);
    c.pending_trap = trap;
}

// Module introspection

export fn wasmz_module_has_memory(handle: ?*const wasmz_module_t) c_int {
    const h = handle orelse return 0;
    const arc: *const ArcModule = @ptrCast(@alignCast(h.ptr));
    const m = arc.value;
    return if (m.memory != null or m.imported_memory != null) 1 else 0;
}

export fn wasmz_module_memory_min(handle: ?*const wasmz_module_t) u32 {
    const h = handle orelse return 0;
    const arc: *const ArcModule = @ptrCast(@alignCast(h.ptr));
    const pages = if (arc.value.memory) |mem| mem.min_pages else if (arc.value.imported_memory) |mem| mem.min_pages else 0;
    return @truncate(pages);
}

export fn wasmz_module_memory_min64(handle: ?*const wasmz_module_t) u64 {
    const h = handle orelse return 0;
    const arc: *const ArcModule = @ptrCast(@alignCast(h.ptr));
    if (arc.value.memory) |mem| return mem.min_pages;
    if (arc.value.imported_memory) |mem| return mem.min_pages;
    return 0;
}

export fn wasmz_module_memory_max(handle: ?*const wasmz_module_t) u32 {
    const h = handle orelse return std.math.maxInt(u32);
    const arc: *const ArcModule = @ptrCast(@alignCast(h.ptr));
    const max = if (arc.value.memory) |mem|
        mem.max_pages
    else if (arc.value.imported_memory) |mem|
        mem.max_pages
    else
        null;
    return @truncate(max orelse std.math.maxInt(u64));
}

export fn wasmz_module_memory_max64(handle: ?*const wasmz_module_t) u64 {
    const h = handle orelse return std.math.maxInt(u64);
    const arc: *const ArcModule = @ptrCast(@alignCast(h.ptr));
    const max = if (arc.value.memory) |mem|
        mem.max_pages
    else if (arc.value.imported_memory) |mem|
        mem.max_pages
    else
        null;
    return max orelse std.math.maxInt(u64);
}

export fn wasmz_module_export_count(handle: ?*const wasmz_module_t) usize {
    const h = handle orelse return 0;
    const arc: *const ArcModule = @ptrCast(@alignCast(h.ptr));
    return arc.value.exports.count();
}

export fn wasmz_module_export_name(handle: ?*const wasmz_module_t, index: usize) ?[*]const u8 {
    const h = handle orelse return null;
    const arc: *const ArcModule = @ptrCast(@alignCast(h.ptr));
    var i: usize = 0;
    var iter = arc.value.exports.iterator();
    while (iter.next()) |entry| {
        if (i == index) {
            return entry.key_ptr.*.ptr;
        }
        i += 1;
    }
    return null;
}

// Store user data

export fn wasmz_store_set_user_data(handle: ?*wasmz_store_t, user_data: ?*anyopaque) void {
    const h = handle orelse return;
    const cstore: *CStore = @ptrCast(@alignCast(h.ptr));
    const store = &cstore.store;
    store.setUserData(user_data);
}

export fn wasmz_store_get_user_data(handle: ?*wasmz_store_t) ?*anyopaque {
    const h = handle orelse return null;
    const cstore: *CStore = @ptrCast(@alignCast(h.ptr));
    const store = &cstore.store;
    return store.user_data;
}

// VM stats

pub const wasmz_vm_stats_t = extern struct {
    val_stack_bytes: usize,
    val_stack_slots: usize,
    call_stack_bytes: usize,
    call_stack_frames: usize,
    vm_alloc_count: usize,
};

export fn wasmz_instance_vm_stats(handle: ?*const wasmz_instance_t, out_stats: ?*wasmz_vm_stats_t) void {
    const h = handle orelse return;
    const out = out_stats orelse return;
    const inst: *const Instance = @ptrCast(@alignCast(h.ptr));
    const stats = inst.vmMemStats();
    out.* = .{
        .val_stack_bytes = stats.val_stack_bytes,
        .val_stack_slots = stats.val_stack_slots,
        .call_stack_bytes = stats.call_stack_bytes,
        .call_stack_frames = stats.call_stack_frames,
        .vm_alloc_count = stats.vm_alloc_count,
    };
}

/// capi.zig — wasmz C API implementation
///
/// This file implements the functions declared in include/wasmz.h.
/// It is compiled as a shared library (libwasmz) or static library.
///
/// Design decisions:
///   - All allocations use the libc allocator (std.heap.c_allocator) so that
///     callers using C's malloc/free are ABI-compatible.
///   - Opaque handle types are thin C-ABI structs that hold a single pointer
///     to a heap-allocated Zig struct.  This avoids "extern struct cannot
///     contain non-extern type" errors.
///   - wasmz_error_t is a heap-allocated struct holding a NUL-terminated message.
const std = @import("std");
const wasmz = @import("wasmz");
const wasi = @import("wasi");

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
const GlobalType = wasmz.GlobalType;
const Memory = wasmz.Memory;
const SharedMemory = wasmz.SharedMemory;
const SharedGlobal = wasmz.SharedGlobal;
const SharedTable = wasmz.SharedTable;
const TableEntry = wasmz.TableEntry;
const ForeignFunc = wasmz.ForeignFunc;
const Trap = wasmz.Trap;
const Allocator = std.mem.Allocator;

const alloc = std.heap.c_allocator;

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

const ERR_UNKNOWN: c_int = 0;
const ERR_COMPILE: c_int = 1;
const ERR_LINK: c_int = 2;
const ERR_RUNTIME: c_int = 3;
const ERR_HOST_TRAP: c_int = 4;

/// Opaque error handle exposed to C.
/// The struct is extern so that its pointer is ABI-stable; the message field
/// is a plain C string pointer.
pub const wasmz_error_t = extern struct {
    /// NUL-terminated message, owned by this struct.
    message: [*:0]u8,
    kind: c_int = ERR_UNKNOWN,
};

fn makeErrorKind(kind: c_int, comptime fmt: []const u8, args: anytype) *wasmz_error_t {
    const msg = alloc.printSentinel(fmt, args, 0) catch
        return makeStaticError("(out of memory formatting error)");
    const err = alloc.create(wasmz_error_t) catch {
        alloc.free(msg);
        return makeStaticError("(out of memory allocating error)");
    };
    err.* = .{ .message = msg.ptr, .kind = kind };
    return err;
}

fn makeError(comptime fmt: []const u8, args: anytype) *wasmz_error_t {
    return makeErrorKind(ERR_UNKNOWN, fmt, args);
}

fn makeTrapError(prefix: []const u8, t: Trap) *wasmz_error_t {
    var tt = t;
    defer tt.deinit();
    const kind: c_int = switch (tt.reason) {
        .host_message => ERR_HOST_TRAP,
        else => ERR_RUNTIME,
    };
    const msg = tt.allocPrint(alloc) catch "trap";
    defer if (!std.mem.eql(u8, msg, "trap")) alloc.free(msg);
    if (prefix.len == 0) {
        return makeErrorKind(kind, "{s}", .{msg});
    }
    return makeErrorKind(kind, "{s}: {s}", .{ prefix, msg });
}

fn makeStaticError(comptime msg: [:0]const u8) *wasmz_error_t {
    // Use a comptime-constant duped copy so we can always call free on it.
    const static = struct {
        var buf: wasmz_error_t = .{ .message = @constCast(msg.ptr), .kind = ERR_UNKNOWN };
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
        // The slice was allocated with printSentinel; free the sentinel slice.
        const sentinel_slice: [:0]u8 = @ptrCast(msg);
        alloc.free(sentinel_slice);
        alloc.destroy(e);
    }
}

export fn wasmz_error_message(err: ?*const wasmz_error_t) [*:0]const u8 {
    const e = err orelse return "(null)";
    return e.message;
}

export fn wasmz_error_kind(err: ?*const wasmz_error_t) c_int {
    const e = err orelse return ERR_UNKNOWN;
    return e.kind;
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
            .REF_FUNC => ValType.funcref(),
            .EXTERN_REF => ValType.externref(),
            else => null,
        };
    }

    fn fromValType(vt: ValType) ?ValKind {
        return switch (vt) {
            .I32 => .I32,
            .I64 => .I64,
            .F32 => .F32,
            .F64 => .F64,
            .V128 => .V128,
            .Ref => |rt| switch (rt.heap_type) {
                .Func, .NoFunc => .REF_FUNC,
                .Extern, .NoExtern => .EXTERN_REF,
                else => .EXTERN_REF,
            },
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
        .REF_NULL => RawVal.fromBits64(0),
        .REF_FUNC => RawVal.fromBits64(if (v.of.func_ref == std.math.maxInt(u32)) 0 else @as(u64, v.of.func_ref) + 1),
        .EXTERN_REF => RawVal.fromBits64(if (v.of.extern_ref) |p| @as(u64, @intFromPtr(p)) else 0),
        else => null,
    };
}

fn rawToCval(raw: RawVal, kind: ValKind) ?wasmz_val_t {
    return switch (kind) {
        .I32 => .{ .kind = kind, .of = .{ .i32 = raw.readAs(i32) } },
        .I64 => .{ .kind = kind, .of = .{ .i64 = raw.readAs(i64) } },
        .F32 => .{ .kind = kind, .of = .{ .f32 = raw.readAs(f32) } },
        .F64 => .{ .kind = kind, .of = .{ .f64 = raw.readAs(f64) } },
        .REF_NULL => .{ .kind = kind, .of = .{ .extern_ref = null } },
        .REF_FUNC => .{
            .kind = kind,
            .of = .{ .func_ref = if (raw.low64 == 0) std.math.maxInt(u32) else @intCast(raw.low64 - 1) },
        },
        .EXTERN_REF => .{
            .kind = kind,
            .of = .{ .extern_ref = if (raw.low64 == 0) null else @ptrFromInt(@as(usize, @truncate(raw.low64))) },
        },
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
        return makeErrorKind(ERR_COMPILE, "module compilation failed: {s}", .{@errorName(err)});
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

export fn wasmz_validate_with_engine(
    engine_handle: ?*wasmz_engine_t,
    bytes: ?[*]const u8,
    len: usize,
) ?*wasmz_error_t {
    const eh = engine_handle orelse return makeError("engine is null", .{});
    const b = bytes orelse return makeErrorKind(ERR_COMPILE, "bytes is null", .{});
    const eng: *Engine = @ptrCast(@alignCast(eh.ptr));
    var m = Module.compile(eng.*, b[0..len]) catch |err| {
        return makeErrorKind(ERR_COMPILE, "validation failed: {s}", .{@errorName(err)});
    };
    m.deinit();
    return null;
}

export fn wasmz_validate(bytes: ?[*]const u8, len: usize) ?*wasmz_error_t {
    const b = bytes orelse return makeErrorKind(ERR_COMPILE, "bytes is null", .{});
    var eng = Engine.init(alloc, Config{}) catch return makeError("out of memory", .{});
    defer eng.deinit();
    var m = Module.compile(eng, b[0..len]) catch |err| {
        return makeErrorKind(ERR_COMPILE, "validation failed: {s}", .{@errorName(err)});
    };
    m.deinit();
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
            const err_kind: c_int = switch (err) {
                error.ImportNotSatisfied,
                error.ImportSignatureMismatch,
                error.ImportMemoryMismatch,
                error.ImportGlobalMismatch,
                error.ImportTableMismatch,
                error.SharedMemoryMissingMax,
                error.ModuleMemoryNotShared,
                error.SharedMemoryTooSmall,
                => ERR_LINK,
                else => ERR_RUNTIME,
            };
            return makeErrorKind(err_kind, "instantiation failed: {s}", .{@errorName(err)});
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

    if (inst.runStartFunction() catch |err|
        return makeErrorKind(ERR_RUNTIME, "start section error: {s}", .{@errorName(err)})) |res|
    {
        switch (res) {
            .ok => {},
            .trap => |t| return makeTrapError("start section trapped", t),
        }
    }

    // Then call _start export if present.
    const m = inst.module.value;
    if (m.exports.get("_start") == null) return null;

    const result = inst.call("_start", &.{}) catch |err|
        return makeErrorKind(ERR_RUNTIME, "_start call failed: {s}", .{@errorName(err)});

    switch (result) {
        .ok => return null,
        .trap => |t| return makeTrapError("_start trapped", t),
    }
}

export fn wasmz_instance_initialize(handle: ?*wasmz_instance_t) ?*wasmz_error_t {
    const h = handle orelse return makeError("instance is null", .{});
    const inst: *Instance = @ptrCast(@alignCast(h.ptr));

    const result = inst.initializeReactor() catch |err|
        return makeErrorKind(ERR_RUNTIME, "_initialize call failed: {s}", .{@errorName(err)});

    if (result) |res| {
        switch (res) {
            .ok => {},
            .trap => |t| return makeTrapError("_initialize trapped", t),
        }
    }
    return null;
}

export fn wasmz_instance_run_start(handle: ?*wasmz_instance_t) ?*wasmz_error_t {
    const h = handle orelse return makeError("instance is null", .{});
    const inst: *Instance = @ptrCast(@alignCast(h.ptr));
    if (inst.runStartFunction() catch |err|
        return makeErrorKind(ERR_RUNTIME, "start section error: {s}", .{@errorName(err)})) |res|
    {
        switch (res) {
            .ok => {},
            .trap => |t| return makeTrapError("start section trapped", t),
        }
    }
    return null;
}

fn fillCallResults(
    inst: *const Instance,
    maybe_val: ?RawVal,
    results_ptr: ?[*]wasmz_val_t,
    results_len: usize,
) ?*wasmz_error_t {
    if (results_len == 0) return null;
    const results = results_ptr orelse return makeError("results is null but results_len > 0", .{});
    const last = inst.lastResults();
    if (last.len > 0) {
        const count = @min(results_len, last.len);
        for (0..count) |i| {
            results[i] = rawToCval(last[i], results[i].kind) orelse return makeError(
                "unsupported value kind for result {d}: {s}",
                .{ i, kindName(results[i].kind) },
            );
        }
    } else if (maybe_val) |val| {
        results[0] = rawToCval(val, results[0].kind) orelse return makeError(
            "unsupported value kind for result 0: {s}",
            .{kindName(results[0].kind)},
        );
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

    const export_entry = inst.module.value.exports.get(func_name) orelse
        return makeErrorKind(ERR_RUNTIME, "call failed: ExportNotFound", .{});
    const func_index = switch (export_entry) {
        .function_index => |idx| idx,
        else => return makeErrorKind(ERR_RUNTIME, "call failed: ExportNotCallable", .{}),
    };
    const m = inst.module.value;
    const expected_results = m.composite_types[m.func_type_indices[func_index]].func_type.results().len;
    if (results_len != expected_results) {
        return makeErrorKind(
            ERR_RUNTIME,
            "result count mismatch for '{s}': expected {d}, got {d}",
            .{ func_name, expected_results, results_len },
        );
    }

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

    const result = inst.callByIndex(func_index, raw_args) catch |err|
        return makeErrorKind(ERR_RUNTIME, "call failed: {s}", .{@errorName(err)});

    switch (result) {
        .ok => |maybe_val| return fillCallResults(inst, maybe_val, results_ptr, results_len),
        .trap => |t| return makeTrapError("trap", t),
    }
}

export fn wasmz_instance_call_index(
    handle: ?*wasmz_instance_t,
    func_index: u32,
    args_ptr: ?[*]const wasmz_val_t,
    args_len: usize,
    results_ptr: ?[*]wasmz_val_t,
    results_len: usize,
) ?*wasmz_error_t {
    const h = handle orelse return makeError("instance is null", .{});
    const inst: *Instance = @ptrCast(@alignCast(h.ptr));
    const m = inst.module.value;
    if (func_index >= m.func_type_indices.len) {
        return makeErrorKind(ERR_RUNTIME, "call failed: ExportNotFound", .{});
    }
    const expected_results = m.composite_types[m.func_type_indices[func_index]].func_type.results().len;
    if (results_len != expected_results) {
        return makeErrorKind(
            ERR_RUNTIME,
            "result count mismatch: expected {d}, got {d}",
            .{ expected_results, results_len },
        );
    }

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

    const result = inst.callByIndex(func_index, raw_args) catch |err|
        return makeErrorKind(ERR_RUNTIME, "call failed: {s}", .{@errorName(err)});

    switch (result) {
        .ok => |maybe_val| return fillCallResults(inst, maybe_val, results_ptr, results_len),
        .trap => |t| return makeTrapError("trap", t),
    }
}

export fn wasmz_instance_id(handle: ?*const wasmz_instance_t) u64 {
    const h = handle orelse return 0;
    const inst: *const Instance = @ptrCast(@alignCast(h.ptr));
    return inst.instance_id;
}

export fn wasmz_instance_export_func_info(
    handle: ?*const wasmz_instance_t,
    func_name_ptr: ?[*:0]const u8,
    out_func_index: ?*u32,
    out_param_count: ?*usize,
    out_result_count: ?*usize,
) c_int {
    const h = handle orelse return -1;
    const name_z = func_name_ptr orelse return -1;
    const inst: *const Instance = @ptrCast(@alignCast(h.ptr));
    const entry = inst.module.value.exports.get(std.mem.span(name_z)) orelse return -1;
    const func_idx = switch (entry) {
        .function_index => |idx| idx,
        else => return -1,
    };
    const m = inst.module.value;
    if (func_idx >= m.func_type_indices.len) return -1;
    const ft = &m.composite_types[m.func_type_indices[func_idx]].func_type;
    if (out_func_index) |p| p.* = func_idx;
    if (out_param_count) |p| p.* = ft.params().len;
    if (out_result_count) |p| p.* = ft.results().len;
    return 0;
}

export fn wasmz_instance_func_sig(
    handle: ?*const wasmz_instance_t,
    func_index: u32,
    out_params: ?[*]ValKind,
    param_cap: usize,
    out_param_count: ?*usize,
    out_results: ?[*]ValKind,
    result_cap: usize,
    out_result_count: ?*usize,
) c_int {
    const h = handle orelse return -1;
    const inst: *const Instance = @ptrCast(@alignCast(h.ptr));
    const m = inst.module.value;
    if (func_index >= m.func_type_indices.len) return -1;
    const ft = &m.composite_types[m.func_type_indices[func_index]].func_type;
    const params = ft.params();
    const results = ft.results();
    if (out_param_count) |p| p.* = params.len;
    if (out_result_count) |p| p.* = results.len;
    if (out_params) |dst| {
        const n = @min(param_cap, params.len);
        for (0..n) |i| {
            dst[i] = ValKind.fromValType(params[i]) orelse return -1;
        }
    }
    if (out_results) |dst| {
        const n = @min(result_cap, results.len);
        for (0..n) |i| {
            dst[i] = ValKind.fromValType(results[i]) orelse return -1;
        }
    }
    return 0;
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
    const trap = Trap.hostMessageOwned(alloc, msg) catch Trap.hostMessage("trap");
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

// Shared Memory / Global / Table handles

pub const wasmz_memory_t = extern struct {
    ptr: *anyopaque,
};

pub const wasmz_global_t = extern struct {
    ptr: *anyopaque,
};

pub const wasmz_table_t = extern struct {
    ptr: *anyopaque,
};

pub const wasmz_table_host_func_t = extern struct {
    ptr: *anyopaque,
};

pub const wasmz_wasi_host_t = extern struct {
    ptr: *anyopaque,
};

export fn wasmz_memory_new(
    initial: u64,
    max_pages: u64,
    has_max: c_int,
    is_shared: c_int,
    is_64: c_int,
    out_mem: ?*?*wasmz_memory_t,
) ?*wasmz_error_t {
    const out = out_mem orelse return makeError("out_mem is null", .{});
    const max_opt: ?u64 = if (has_max != 0) max_pages else null;

    var mem: Memory = if (is_shared != 0) blk: {
        const m = max_opt orelse return makeErrorKind(ERR_RUNTIME, "shared memory requires maximum", .{});
        const shared = SharedMemory.init(alloc, std.Io.Threaded.global_single_threaded.io(), initial, m) catch |err|
            return makeErrorKind(ERR_RUNTIME, "shared memory init failed: {s}", .{@errorName(err)});
        break :blk Memory.initShared(shared);
    } else blk: {
        break :blk Memory.initRc(alloc, initial, max_opt, is_64 != 0) catch |err|
            return makeErrorKind(ERR_RUNTIME, "memory init failed: {s}", .{@errorName(err)});
    };
    errdefer mem.deinit();

    const slot = alloc.create(Memory) catch return makeError("out of memory", .{});
    errdefer alloc.destroy(slot);
    slot.* = mem;

    const handle = alloc.create(wasmz_memory_t) catch return makeError("out of memory", .{});
    handle.* = .{ .ptr = slot };
    out.* = handle;
    return null;
}

export fn wasmz_memory_clone(handle: ?*const wasmz_memory_t) ?*wasmz_memory_t {
    const h = handle orelse return null;
    const mem: *const Memory = @ptrCast(@alignCast(h.ptr));
    const cloned = mem.clone();
    const slot = alloc.create(Memory) catch {
        var c = cloned;
        c.deinit();
        return null;
    };
    slot.* = cloned;
    const out_h = alloc.create(wasmz_memory_t) catch {
        slot.deinit();
        alloc.destroy(slot);
        return null;
    };
    out_h.* = .{ .ptr = slot };
    return out_h;
}

export fn wasmz_memory_delete(handle: ?*wasmz_memory_t) void {
    const h = handle orelse return;
    const mem: *Memory = @ptrCast(@alignCast(h.ptr));
    mem.deinit();
    alloc.destroy(mem);
    alloc.destroy(h);
}

export fn wasmz_instance_export_memory(handle: ?*const wasmz_instance_t, name_ptr: ?[*:0]const u8) ?*wasmz_memory_t {
    const h = handle orelse return null;
    const n = name_ptr orelse return null;
    const inst: *const Instance = @ptrCast(@alignCast(h.ptr));
    const mem = inst.exportMemory(std.mem.span(n)) orelse return null;
    const cloned = mem.clone();
    const slot = alloc.create(Memory) catch {
        var c = cloned;
        c.deinit();
        return null;
    };
    slot.* = cloned;
    const out_h = alloc.create(wasmz_memory_t) catch {
        slot.deinit();
        alloc.destroy(slot);
        return null;
    };
    out_h.* = .{ .ptr = slot };
    return out_h;
}

export fn wasmz_memory_data(handle: ?*wasmz_memory_t) ?[*]u8 {
    const h = handle orelse return null;
    const mem: *Memory = @ptrCast(@alignCast(h.ptr));
    const b = mem.bytes();
    return if (b.len == 0) null else b.ptr;
}

export fn wasmz_memory_data_len(handle: ?*const wasmz_memory_t) usize {
    const h = handle orelse return 0;
    const mem: *const Memory = @ptrCast(@alignCast(h.ptr));
    return mem.byteLen();
}

export fn wasmz_memory_pages(handle: ?*const wasmz_memory_t) u64 {
    const h = handle orelse return 0;
    const mem: *const Memory = @ptrCast(@alignCast(h.ptr));
    return mem.pageCount();
}

export fn wasmz_memory_min(handle: ?*const wasmz_memory_t) u64 {
    const h = handle orelse return 0;
    const mem: *const Memory = @ptrCast(@alignCast(h.ptr));
    return switch (mem.kind) {
        .rc => |rc| rc.min_pages,
        else => mem.pageCount(),
    };
}

export fn wasmz_memory_max(handle: ?*const wasmz_memory_t, out_has_max: ?*c_int) u64 {
    const h = handle orelse {
        if (out_has_max) |p| p.* = 0;
        return std.math.maxInt(u64);
    };
    const mem: *const Memory = @ptrCast(@alignCast(h.ptr));
    if (mem.maxPages()) |m| {
        if (out_has_max) |p| p.* = 1;
        return m;
    }
    if (out_has_max) |p| p.* = 0;
    return std.math.maxInt(u64);
}

export fn wasmz_memory_is_shared(handle: ?*const wasmz_memory_t) c_int {
    const h = handle orelse return 0;
    const mem: *const Memory = @ptrCast(@alignCast(h.ptr));
    return if (mem.isShared()) 1 else 0;
}

export fn wasmz_memory_is_64(handle: ?*const wasmz_memory_t) c_int {
    const h = handle orelse return 0;
    const mem: *const Memory = @ptrCast(@alignCast(h.ptr));
    return switch (mem.kind) {
        .rc => |rc| if (rc.memory64) 1 else 0,
        else => 0,
    };
}

export fn wasmz_memory_grow_seq(handle: ?*const wasmz_memory_t) u64 {
    const h = handle orelse return 0;
    const mem: *const Memory = @ptrCast(@alignCast(h.ptr));
    return mem.growSeq();
}

export fn wasmz_memory_identity(handle: ?*const wasmz_memory_t) u64 {
    const h = handle orelse return 0;
    const mem: *const Memory = @ptrCast(@alignCast(h.ptr));
    return switch (mem.kind) {
        .rc => |rc| @intFromPtr(rc),
        .shared => |s| @intFromPtr(s.inner),
        else => @intFromPtr(mem),
    };
}

export fn wasmz_memory_grow(handle: ?*wasmz_memory_t, delta: u64, out_prev_pages: ?*u64) c_int {
    const h = handle orelse return -1;
    const mem: *Memory = @ptrCast(@alignCast(h.ptr));
    const prev = mem.grow(delta);
    if (prev == std.math.maxInt(u64)) return -1;
    if (out_prev_pages) |p| p.* = prev;
    return 0;
}

export fn wasmz_linker_define_memory(
    handle: ?*wasmz_linker_t,
    module_name_ptr: ?[*:0]const u8,
    field_name_ptr: ?[*:0]const u8,
    mem_handle: ?*wasmz_memory_t,
) ?*wasmz_error_t {
    const h = handle orelse return makeError("linker is null", .{});
    const mod_in = module_name_ptr orelse return makeError("module_name is null", .{});
    const field_in = field_name_ptr orelse return makeError("field_name is null", .{});
    const mh = mem_handle orelse return makeError("memory is null", .{});
    const clinker: *CLinker = @ptrCast(@alignCast(h.ptr));
    const mem: *const Memory = @ptrCast(@alignCast(mh.ptr));

    const mod_slice = clinker.dupeString(std.mem.span(mod_in)) catch return makeError("out of memory", .{});
    const field_slice = clinker.dupeString(std.mem.span(field_in)) catch return makeError("out of memory", .{});
    clinker.linker.defineMemory(alloc, mod_slice, field_slice, mem.*) catch |err|
        return makeError("linker define memory failed: {s}", .{@errorName(err)});
    return null;
}

// Global handle

export fn wasmz_global_new(
    kind: ValKind,
    is_mutable: c_int,
    initial: wasmz_val_t,
    out_global: ?*?*wasmz_global_t,
) ?*wasmz_error_t {
    const out = out_global orelse return makeError("out_global is null", .{});
    const vt = kind.toValType() orelse return makeErrorKind(ERR_RUNTIME, "unsupported global value kind", .{});
    const raw = cvalToRaw(initial) orelse return makeErrorKind(ERR_RUNTIME, "unsupported initial global value", .{});
    const gt = GlobalType.init(if (is_mutable != 0) .Var else .Const, vt);
    var sg = SharedGlobal.init(alloc, gt, raw, 0) catch return makeError("out of memory", .{});
    errdefer sg.deinit();

    const slot = alloc.create(SharedGlobal) catch return makeError("out of memory", .{});
    errdefer alloc.destroy(slot);
    slot.* = sg;

    const handle = alloc.create(wasmz_global_t) catch return makeError("out of memory", .{});
    handle.* = .{ .ptr = slot };
    out.* = handle;
    return null;
}

export fn wasmz_global_clone(handle: ?*const wasmz_global_t) ?*wasmz_global_t {
    const h = handle orelse return null;
    const g: *const SharedGlobal = @ptrCast(@alignCast(h.ptr));
    const cloned = g.clone();
    const slot = alloc.create(SharedGlobal) catch {
        var c = cloned;
        c.deinit();
        return null;
    };
    slot.* = cloned;
    const out_h = alloc.create(wasmz_global_t) catch {
        slot.deinit();
        alloc.destroy(slot);
        return null;
    };
    out_h.* = .{ .ptr = slot };
    return out_h;
}

export fn wasmz_global_delete(handle: ?*wasmz_global_t) void {
    const h = handle orelse return;
    const g: *SharedGlobal = @ptrCast(@alignCast(h.ptr));
    g.deinit();
    alloc.destroy(g);
    alloc.destroy(h);
}

export fn wasmz_instance_export_global(handle: ?*const wasmz_instance_t, name_ptr: ?[*:0]const u8) ?*wasmz_global_t {
    const h = handle orelse return null;
    const n = name_ptr orelse return null;
    const inst: *const Instance = @ptrCast(@alignCast(h.ptr));
    const g = inst.exportGlobal(std.mem.span(n)) orelse return null;
    const cloned = g.clone();
    const slot = alloc.create(SharedGlobal) catch {
        var c = cloned;
        c.deinit();
        return null;
    };
    slot.* = cloned;
    const out_h = alloc.create(wasmz_global_t) catch {
        slot.deinit();
        alloc.destroy(slot);
        return null;
    };
    out_h.* = .{ .ptr = slot };
    return out_h;
}

export fn wasmz_global_kind(handle: ?*const wasmz_global_t) ValKind {
    const h = handle orelse return .I32;
    const g: *const SharedGlobal = @ptrCast(@alignCast(h.ptr));
    return ValKind.fromValType(g.valueType()) orelse .I32;
}

export fn wasmz_global_is_mutable(handle: ?*const wasmz_global_t) c_int {
    const h = handle orelse return 0;
    const g: *const SharedGlobal = @ptrCast(@alignCast(h.ptr));
    return if (g.mutability() == .Var) 1 else 0;
}

export fn wasmz_global_get(handle: ?*const wasmz_global_t) wasmz_val_t {
    const h = handle orelse return .{ .kind = .I32, .of = .{ .i32 = 0 } };
    const g: *const SharedGlobal = @ptrCast(@alignCast(h.ptr));
    const kind = ValKind.fromValType(g.valueType()) orelse return .{ .kind = .I32, .of = .{ .i32 = 0 } };
    return rawToCval(g.getRaw(), kind) orelse .{ .kind = kind, .of = .{ .i32 = 0 } };
}

export fn wasmz_global_identity(handle: ?*const wasmz_global_t) u64 {
    const h = handle orelse return 0;
    const g: *const SharedGlobal = @ptrCast(@alignCast(h.ptr));
    return @intFromPtr(g.inner);
}

export fn wasmz_global_set(handle: ?*wasmz_global_t, value: wasmz_val_t) ?*wasmz_error_t {
    const h = handle orelse return makeError("global is null", .{});
    const g: *SharedGlobal = @ptrCast(@alignCast(h.ptr));
    if (g.mutability() != .Var) {
        return makeErrorKind(ERR_RUNTIME, "cannot set immutable global", .{});
    }
    const expected_kind = ValKind.fromValType(g.valueType()) orelse
        return makeErrorKind(ERR_RUNTIME, "unsupported global value type", .{});
    if (value.kind != expected_kind) {
        return makeErrorKind(ERR_RUNTIME, "global value kind mismatch", .{});
    }
    const raw = cvalToRaw(value) orelse
        return makeErrorKind(ERR_RUNTIME, "unsupported global value", .{});
    g.setRaw(raw) catch |err|
        return makeErrorKind(ERR_RUNTIME, "global set failed: {s}", .{@errorName(err)});
    return null;
}

export fn wasmz_linker_define_global_handle(
    handle: ?*wasmz_linker_t,
    module_name_ptr: ?[*:0]const u8,
    global_name_ptr: ?[*:0]const u8,
    global_handle: ?*wasmz_global_t,
) ?*wasmz_error_t {
    const h = handle orelse return makeError("linker is null", .{});
    const mod_in = module_name_ptr orelse return makeError("module_name is null", .{});
    const glob_in = global_name_ptr orelse return makeError("global_name is null", .{});
    const gh = global_handle orelse return makeError("global is null", .{});
    const clinker: *CLinker = @ptrCast(@alignCast(h.ptr));
    const g: *const SharedGlobal = @ptrCast(@alignCast(gh.ptr));

    const mod_slice = clinker.dupeString(std.mem.span(mod_in)) catch return makeError("out of memory", .{});
    const glob_slice = clinker.dupeString(std.mem.span(glob_in)) catch return makeError("out of memory", .{});
    clinker.linker.defineGlobalHandle(alloc, mod_slice, glob_slice, g.*) catch |err|
        return makeError("linker define global failed: {s}", .{@errorName(err)});
    return null;
}

// Table handle & host table function wrapper

const CTableHostFunc = struct {
    func: wasmz_func_t,
    host_data: ?*anyopaque,
    param_kinds: []ValKind,
    result_kinds: []ValKind,
    param_types: []ValType,
    result_types: []ValType,
    foreign: ForeignFunc,
    tag: u64,
};

fn tableHostTrampoline(
    raw_ctx: *anyopaque,
    _: u32,
    args: []const u64,
    results: []u64,
    trap_out: *?[*:0]const u8,
) bool {
    const thf: *CTableHostFunc = @ptrCast(@alignCast(raw_ctx));
    const pcount = thf.param_kinds.len;
    const rcount = thf.result_kinds.len;

    const c_params = alloc.alloc(wasmz_val_t, pcount) catch {
        trap_out.* = "out of memory";
        return false;
    };
    defer alloc.free(c_params);
    const c_results = alloc.alloc(wasmz_val_t, rcount) catch {
        trap_out.* = "out of memory";
        return false;
    };
    defer alloc.free(c_results);

    for (0..pcount) |i| {
        const bits = if (i < args.len) args[i] else 0;
        c_params[i] = rawToCval(RawVal.fromBits64(bits), thf.param_kinds[i]) orelse {
            trap_out.* = "unsupported param kind";
            return false;
        };
    }
    for (0..rcount) |i| {
        c_results[i] = rawToCval(RawVal.fromBits64(0), thf.result_kinds[i]) orelse {
            trap_out.* = "unsupported result kind";
            return false;
        };
    }

    const ret = thf.func(thf.host_data, null, c_params.ptr, pcount, c_results.ptr, rcount);
    if (ret != 0) {
        trap_out.* = "host function trapped";
        return false;
    }

    for (0..@min(results.len, rcount)) |i| {
        const raw = cvalToRaw(c_results[i]) orelse {
            trap_out.* = "unsupported result value";
            return false;
        };
        results[i] = raw.low64;
    }
    return true;
}

export fn wasmz_table_host_func_new(
    param_kinds_ptr: ?[*]const ValKind,
    param_count: usize,
    result_kinds_ptr: ?[*]const ValKind,
    result_count: usize,
    func: ?wasmz_func_t,
    host_data: ?*anyopaque,
    tag: u64,
    out_func: ?*?*wasmz_table_host_func_t,
) ?*wasmz_error_t {
    const out = out_func orelse return makeError("out_func is null", .{});
    const cb = func orelse return makeError("func is null", .{});
    if (param_count > 0 and param_kinds_ptr == null) return makeError("param_kinds is null", .{});
    if (result_count > 0 and result_kinds_ptr == null) return makeError("result_kinds is null", .{});

    const p_kinds = alloc.alloc(ValKind, param_count) catch return makeError("out of memory", .{});
    errdefer alloc.free(p_kinds);
    if (param_count > 0) @memcpy(p_kinds, param_kinds_ptr.?[0..param_count]);

    const r_kinds = alloc.alloc(ValKind, result_count) catch return makeError("out of memory", .{});
    errdefer alloc.free(r_kinds);
    if (result_count > 0) @memcpy(r_kinds, result_kinds_ptr.?[0..result_count]);

    const p_types = alloc.alloc(ValType, param_count) catch return makeError("out of memory", .{});
    errdefer alloc.free(p_types);
    for (p_kinds, 0..) |k, i| p_types[i] = k.toValType() orelse return makeError("unsupported param kind", .{});

    const r_types = alloc.alloc(ValType, result_count) catch return makeError("out of memory", .{});
    errdefer alloc.free(r_types);
    for (r_kinds, 0..) |k, i| r_types[i] = k.toValType() orelse return makeError("unsupported result kind", .{});

    const thf = alloc.create(CTableHostFunc) catch return makeError("out of memory", .{});
    thf.* = .{
        .func = cb,
        .host_data = host_data,
        .param_kinds = p_kinds,
        .result_kinds = r_kinds,
        .param_types = p_types,
        .result_types = r_types,
        .tag = if (tag == 0) 1 else tag,
        .foreign = .{
            .ctx = thf,
            .func_idx = 0,
            .param_types = p_types,
            .result_types = r_types,
            .trampoline = &tableHostTrampoline,
        },
    };

    const h = alloc.create(wasmz_table_host_func_t) catch {
        alloc.destroy(thf);
        return makeError("out of memory", .{});
    };
    h.* = .{ .ptr = thf };
    out.* = h;
    return null;
}

export fn wasmz_table_host_func_delete(handle: ?*wasmz_table_host_func_t) void {
    const h = handle orelse return;
    const thf: *CTableHostFunc = @ptrCast(@alignCast(h.ptr));
    alloc.free(thf.param_kinds);
    alloc.free(thf.result_kinds);
    alloc.free(thf.param_types);
    alloc.free(thf.result_types);
    alloc.destroy(thf);
    alloc.destroy(h);
}

fn entryFromInstanceOrRaw(
    elem_kind: ValKind,
    init_raw: u64,
    init_func_owner: ?*const wasmz_instance_t,
    init_func_idx: u32,
) TableEntry {
    if (elem_kind == .REF_FUNC) {
        if (init_func_owner) |oh| {
            const inst: *const Instance = @ptrCast(@alignCast(oh.ptr));
            return TableEntry.fromFuncWithForeign(init_func_idx, inst.instance_id, inst.foreignFuncAt(init_func_idx));
        }
        return TableEntry.null_entry;
    }
    return TableEntry.fromExternRef(init_raw);
}

export fn wasmz_table_new(
    elem_kind: ValKind,
    initial: u32,
    max_len: u32,
    has_max: c_int,
    init_raw: u64,
    init_func_owner: ?*const wasmz_instance_t,
    init_func_idx: u32,
    out_table: ?*?*wasmz_table_t,
) ?*wasmz_error_t {
    const out = out_table orelse return makeError("out_table is null", .{});
    const et = switch (elem_kind) {
        .REF_FUNC => ValType.funcref(),
        .EXTERN_REF => ValType.externref(),
        else => return makeErrorKind(ERR_RUNTIME, "table element kind must be funcref or externref", .{}),
    };
    const max_opt: ?u32 = if (has_max != 0) max_len else null;
    if (max_opt) |m| {
        if (initial > m) return makeErrorKind(ERR_RUNTIME, "table initial exceeds maximum", .{});
    }
    const init_entry = entryFromInstanceOrRaw(elem_kind, init_raw, init_func_owner, init_func_idx);
    var tbl = SharedTable.init(alloc, et, initial, max_opt, init_entry) catch
        return makeError("out of memory", .{});
    errdefer tbl.deinit();

    const slot = alloc.create(SharedTable) catch return makeError("out of memory", .{});
    errdefer alloc.destroy(slot);
    slot.* = tbl;

    const handle = alloc.create(wasmz_table_t) catch return makeError("out of memory", .{});
    handle.* = .{ .ptr = slot };
    out.* = handle;
    return null;
}

export fn wasmz_table_clone(handle: ?*const wasmz_table_t) ?*wasmz_table_t {
    const h = handle orelse return null;
    const tbl: *const SharedTable = @ptrCast(@alignCast(h.ptr));
    const cloned = tbl.clone();
    const slot = alloc.create(SharedTable) catch {
        var c = cloned;
        c.deinit();
        return null;
    };
    slot.* = cloned;
    const out_h = alloc.create(wasmz_table_t) catch {
        slot.deinit();
        alloc.destroy(slot);
        return null;
    };
    out_h.* = .{ .ptr = slot };
    return out_h;
}

export fn wasmz_table_delete(handle: ?*wasmz_table_t) void {
    const h = handle orelse return;
    const tbl: *SharedTable = @ptrCast(@alignCast(h.ptr));
    tbl.deinit();
    alloc.destroy(tbl);
    alloc.destroy(h);
}

export fn wasmz_instance_export_table(handle: ?*const wasmz_instance_t, name_ptr: ?[*:0]const u8) ?*wasmz_table_t {
    const h = handle orelse return null;
    const n = name_ptr orelse return null;
    const inst: *const Instance = @ptrCast(@alignCast(h.ptr));
    const tbl = inst.exportTable(std.mem.span(n)) orelse return null;
    const cloned = tbl.clone();
    const slot = alloc.create(SharedTable) catch {
        var c = cloned;
        c.deinit();
        return null;
    };
    slot.* = cloned;
    const out_h = alloc.create(wasmz_table_t) catch {
        slot.deinit();
        alloc.destroy(slot);
        return null;
    };
    out_h.* = .{ .ptr = slot };
    return out_h;
}

export fn wasmz_table_len(handle: ?*const wasmz_table_t) u32 {
    const h = handle orelse return 0;
    const tbl: *const SharedTable = @ptrCast(@alignCast(h.ptr));
    return @intCast(tbl.len());
}

export fn wasmz_table_max(handle: ?*const wasmz_table_t, out_has_max: ?*c_int) u32 {
    const h = handle orelse {
        if (out_has_max) |p| p.* = 0;
        return std.math.maxInt(u32);
    };
    const tbl: *const SharedTable = @ptrCast(@alignCast(h.ptr));
    if (tbl.max()) |m| {
        if (out_has_max) |p| p.* = 1;
        return m;
    }
    if (out_has_max) |p| p.* = 0;
    return std.math.maxInt(u32);
}

export fn wasmz_table_elem_kind(handle: ?*const wasmz_table_t) ValKind {
    const h = handle orelse return .REF_FUNC;
    const tbl: *const SharedTable = @ptrCast(@alignCast(h.ptr));
    return ValKind.fromValType(tbl.elemType()) orelse .REF_FUNC;
}

export fn wasmz_table_identity(handle: ?*const wasmz_table_t) u64 {
    const h = handle orelse return 0;
    const tbl: *const SharedTable = @ptrCast(@alignCast(h.ptr));
    return @intFromPtr(tbl.inner);
}

export fn wasmz_table_get_entry(
    handle: ?*const wasmz_table_t,
    index: u32,
    out_is_null: ?*c_int,
    out_owner_id: ?*u64,
    out_func_idx: ?*u32,
    out_raw: ?*u64,
) c_int {
    const h = handle orelse return -1;
    const tbl: *const SharedTable = @ptrCast(@alignCast(h.ptr));
    const entry = tbl.get(index) orelse return -1;
    if (out_is_null) |p| p.* = if (entry.isNull()) 1 else 0;
    if (out_owner_id) |p| p.* = entry.owner_id;
    if (out_func_idx) |p| p.* = entry.func_idx;
    if (out_raw) |p| p.* = entry.raw;
    return 0;
}

export fn wasmz_table_set_null(handle: ?*wasmz_table_t, index: u32) c_int {
    const h = handle orelse return -1;
    const tbl: *SharedTable = @ptrCast(@alignCast(h.ptr));
    return if (tbl.set(index, TableEntry.null_entry)) 0 else -1;
}

export fn wasmz_table_set_externref(handle: ?*wasmz_table_t, index: u32, raw_ref: u64) c_int {
    const h = handle orelse return -1;
    const tbl: *SharedTable = @ptrCast(@alignCast(h.ptr));
    return if (tbl.set(index, TableEntry.fromExternRef(raw_ref))) 0 else -1;
}

export fn wasmz_table_set_instance_func(
    handle: ?*wasmz_table_t,
    index: u32,
    owner_inst: ?*const wasmz_instance_t,
    func_idx: u32,
) c_int {
    const h = handle orelse return -1;
    const oh = owner_inst orelse return wasmz_table_set_null(handle, index);
    const tbl: *SharedTable = @ptrCast(@alignCast(h.ptr));
    const inst: *const Instance = @ptrCast(@alignCast(oh.ptr));
    const entry = TableEntry.fromFuncWithForeign(func_idx, inst.instance_id, inst.foreignFuncAt(func_idx));
    return if (tbl.set(index, entry)) 0 else -1;
}

export fn wasmz_table_grow(
    handle: ?*wasmz_table_t,
    delta: u32,
    init_raw: u64,
    out_prev_len: ?*u32,
) c_int {
    const h = handle orelse return -1;
    const tbl: *SharedTable = @ptrCast(@alignCast(h.ptr));
    const entry = if (tbl.elemType().eql(ValType.funcref()))
        TableEntry.null_entry
    else
        TableEntry.fromExternRef(init_raw);
    const prev = tbl.grow(delta, entry) orelse return -1;
    if (out_prev_len) |p| p.* = prev;
    return 0;
}

export fn wasmz_table_grow_instance_func(
    handle: ?*wasmz_table_t,
    delta: u32,
    owner_inst: ?*const wasmz_instance_t,
    func_idx: u32,
    out_prev_len: ?*u32,
) c_int {
    const h = handle orelse return -1;
    const tbl: *SharedTable = @ptrCast(@alignCast(h.ptr));
    const entry = if (owner_inst) |oh| blk: {
        const inst: *const Instance = @ptrCast(@alignCast(oh.ptr));
        break :blk TableEntry.fromFuncWithForeign(func_idx, inst.instance_id, inst.foreignFuncAt(func_idx));
    } else TableEntry.null_entry;
    const prev = tbl.grow(delta, entry) orelse return -1;
    if (out_prev_len) |p| p.* = prev;
    return 0;
}

export fn wasmz_table_set_host_func(
    handle: ?*wasmz_table_t,
    index: u32,
    func_handle: ?*const wasmz_table_host_func_t,
) c_int {
    const h = handle orelse return -1;
    const fh = func_handle orelse return wasmz_table_set_null(handle, index);
    const tbl: *SharedTable = @ptrCast(@alignCast(h.ptr));
    const thf: *const CTableHostFunc = @ptrCast(@alignCast(fh.ptr));
    return if (tbl.set(index, TableEntry.fromForeign(thf.tag, &thf.foreign))) 0 else -1;
}

export fn wasmz_table_grow_host_func(
    handle: ?*wasmz_table_t,
    delta: u32,
    func_handle: ?*const wasmz_table_host_func_t,
    out_prev_len: ?*u32,
) c_int {
    const h = handle orelse return -1;
    const tbl: *SharedTable = @ptrCast(@alignCast(h.ptr));
    const entry = if (func_handle) |fh| blk: {
        const thf: *const CTableHostFunc = @ptrCast(@alignCast(fh.ptr));
        break :blk TableEntry.fromForeign(thf.tag, &thf.foreign);
    } else TableEntry.null_entry;
    const prev = tbl.grow(delta, entry) orelse return -1;
    if (out_prev_len) |p| p.* = prev;
    return 0;
}

export fn wasmz_linker_define_table(
    handle: ?*wasmz_linker_t,
    module_name_ptr: ?[*:0]const u8,
    field_name_ptr: ?[*:0]const u8,
    table_handle: ?*wasmz_table_t,
) ?*wasmz_error_t {
    const h = handle orelse return makeError("linker is null", .{});
    const mod_in = module_name_ptr orelse return makeError("module_name is null", .{});
    const field_in = field_name_ptr orelse return makeError("field_name is null", .{});
    const th = table_handle orelse return makeError("table is null", .{});
    const clinker: *CLinker = @ptrCast(@alignCast(h.ptr));
    const tbl: *const SharedTable = @ptrCast(@alignCast(th.ptr));

    const mod_slice = clinker.dupeString(std.mem.span(mod_in)) catch return makeError("out of memory", .{});
    const field_slice = clinker.dupeString(std.mem.span(field_in)) catch return makeError("out of memory", .{});
    clinker.linker.defineTable(alloc, mod_slice, field_slice, tbl.*) catch |err|
        return makeError("linker define table failed: {s}", .{@errorName(err)});
    return null;
}

// WASI Preview 1 host

const CWasiHost = struct {
    host: wasi.preview1.Host,
};

export fn wasmz_wasi_host_new() ?*wasmz_wasi_host_t {
    const wh = alloc.create(CWasiHost) catch return null;
    wh.* = .{
        .host = wasi.preview1.Host.init(alloc, std.Io.Threaded.global_single_threaded.io()),
    };
    const handle = alloc.create(wasmz_wasi_host_t) catch {
        wh.host.deinit();
        alloc.destroy(wh);
        return null;
    };
    handle.* = .{ .ptr = wh };
    return handle;
}

export fn wasmz_wasi_host_delete(handle: ?*wasmz_wasi_host_t) void {
    const h = handle orelse return;
    const wh: *CWasiHost = @ptrCast(@alignCast(h.ptr));
    wh.host.deinit();
    alloc.destroy(wh);
    alloc.destroy(h);
}

export fn wasmz_wasi_host_set_args(
    handle: ?*wasmz_wasi_host_t,
    args_ptr: ?[*]const [*:0]const u8,
    count: usize,
) ?*wasmz_error_t {
    const h = handle orelse return makeError("wasi host is null", .{});
    const wh: *CWasiHost = @ptrCast(@alignCast(h.ptr));
    if (count > 0 and args_ptr == null) return makeError("args is null", .{});
    const slices = alloc.alloc([]const u8, count) catch return makeError("out of memory", .{});
    defer alloc.free(slices);
    for (0..count) |i| {
        slices[i] = std.mem.span(args_ptr.?[i]);
    }
    wh.host.setArgs(slices) catch return makeError("out of memory", .{});
    return null;
}

export fn wasmz_wasi_host_set_env(
    handle: ?*wasmz_wasi_host_t,
    keys_ptr: ?[*]const [*:0]const u8,
    vals_ptr: ?[*]const [*:0]const u8,
    count: usize,
) ?*wasmz_error_t {
    const h = handle orelse return makeError("wasi host is null", .{});
    const wh: *CWasiHost = @ptrCast(@alignCast(h.ptr));
    if (count > 0 and (keys_ptr == null or vals_ptr == null)) return makeError("env keys/values null", .{});
    const vars = alloc.alloc(wasi.preview1.EnvVar, count) catch return makeError("out of memory", .{});
    defer alloc.free(vars);
    for (0..count) |i| {
        vars[i] = .{
            .key = std.mem.span(keys_ptr.?[i]),
            .value = std.mem.span(vals_ptr.?[i]),
        };
    }
    wh.host.setEnv(vars) catch return makeError("out of memory", .{});
    return null;
}

export fn wasmz_wasi_host_add_preopen(
    handle: ?*wasmz_wasi_host_t,
    guest_path_ptr: ?[*:0]const u8,
    host_path_ptr: ?[*:0]const u8,
) ?*wasmz_error_t {
    const h = handle orelse return makeError("wasi host is null", .{});
    const gp = guest_path_ptr orelse return makeError("guest_path is null", .{});
    const hp = host_path_ptr orelse return makeError("host_path is null", .{});
    const wh: *CWasiHost = @ptrCast(@alignCast(h.ptr));
    _ = wh.host.addMappedPreopen(std.mem.span(gp), std.mem.span(hp)) catch |err|
        return makeErrorKind(ERR_RUNTIME, "add preopen failed: {s}", .{@errorName(err)});
    return null;
}

export fn wasmz_wasi_host_set_stdio_fds(
    handle: ?*wasmz_wasi_host_t,
    stdin_fd: i32,
    stdout_fd: i32,
    stderr_fd: i32,
) void {
    const h = handle orelse return;
    const wh: *CWasiHost = @ptrCast(@alignCast(h.ptr));
    if (stdin_fd >= 0) wh.host.setStdinFd(stdin_fd);
    if (stdout_fd >= 0) wh.host.setStdoutFd(stdout_fd);
    if (stderr_fd >= 0) wh.host.setStderrFd(stderr_fd);
}

export fn wasmz_wasi_host_set_return_on_exit(handle: ?*wasmz_wasi_host_t, return_on_exit: c_int) void {
    const h = handle orelse return;
    const wh: *CWasiHost = @ptrCast(@alignCast(h.ptr));
    wh.host.setReturnOnExit(return_on_exit != 0);
}

export fn wasmz_wasi_host_exit_code(handle: ?*const wasmz_wasi_host_t, out_code: ?*u32) c_int {
    const h = handle orelse return 0;
    const wh: *const CWasiHost = @ptrCast(@alignCast(h.ptr));
    if (wh.host.exitCode()) |c| {
        if (out_code) |p| p.* = c;
        return 1;
    }
    return 0;
}

export fn wasmz_linker_add_wasi(
    linker_handle: ?*wasmz_linker_t,
    wasi_handle: ?*wasmz_wasi_host_t,
) ?*wasmz_error_t {
    const lh = linker_handle orelse return makeError("linker is null", .{});
    const wh_ptr = wasi_handle orelse return makeError("wasi host is null", .{});
    const clinker: *CLinker = @ptrCast(@alignCast(lh.ptr));
    const wh: *CWasiHost = @ptrCast(@alignCast(wh_ptr.ptr));
    wh.host.addToLinker(&clinker.linker, alloc) catch |err|
        return makeError("add wasi to linker failed: {s}", .{@errorName(err)});
    return null;
}

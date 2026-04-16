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

const alloc = std.heap.c_allocator;

// ── Error type ────────────────────────────────────────────────────────────────

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

// ── Value type ────────────────────────────────────────────────────────────────

/// Must stay in sync with the C enum wasmz_val_kind_t in include/wasmz.h
const ValKind = enum(c_int) {
    I32 = 0,
    I64 = 1,
    F32 = 2,
    F64 = 3,
};

/// Must stay in sync with wasmz_val_t in include/wasmz.h
pub const wasmz_val_t = extern struct {
    kind: ValKind,
    _pad: [4]u8 = .{ 0, 0, 0, 0 },
    value: extern union {
        i32: i32,
        i64: i64,
        f32: f32,
        f64: f64,
    },
};

fn cvalToRaw(v: wasmz_val_t) RawVal {
    return switch (v.kind) {
        .I32 => RawVal.from(v.value.i32),
        .I64 => RawVal.from(v.value.i64),
        .F32 => RawVal.from(v.value.f32),
        .F64 => RawVal.from(v.value.f64),
    };
}

fn rawToCval(raw: RawVal, kind: ValKind) wasmz_val_t {
    var v = wasmz_val_t{ .kind = kind, .value = undefined };
    switch (kind) {
        .I32 => v.value = .{ .i32 = raw.readAs(i32) },
        .I64 => v.value = .{ .i64 = raw.readAs(i64) },
        .F32 => v.value = .{ .f32 = raw.readAs(f32) },
        .F64 => v.value = .{ .f64 = raw.readAs(f64) },
    }
    return v;
}

// ── Engine ────────────────────────────────────────────────────────────────────

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

// ── Store ─────────────────────────────────────────────────────────────────────

pub const wasmz_store_t = extern struct {
    ptr: *anyopaque,
};

export fn wasmz_store_new(engine_handle: ?*wasmz_engine_t) ?*wasmz_store_t {
    const eh = engine_handle orelse return null;
    const eng: *Engine = @ptrCast(@alignCast(eh.ptr));

    const store_ptr = alloc.create(Store) catch return null;
    store_ptr.* = Store.init(alloc, eng.*) catch {
        alloc.destroy(store_ptr);
        return null;
    };
    store_ptr.linkBudget();

    const handle = alloc.create(wasmz_store_t) catch {
        store_ptr.deinit();
        alloc.destroy(store_ptr);
        return null;
    };
    handle.* = .{ .ptr = store_ptr };
    return handle;
}

export fn wasmz_store_delete(handle: ?*wasmz_store_t) void {
    const h = handle orelse return;
    const s: *Store = @ptrCast(@alignCast(h.ptr));
    s.deinit();
    alloc.destroy(s);
    alloc.destroy(h);
}

// ── Module ────────────────────────────────────────────────────────────────────

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

// ── Instance ──────────────────────────────────────────────────────────────────

pub const wasmz_instance_t = extern struct {
    ptr: *anyopaque,
};

export fn wasmz_instance_new(
    store_handle: ?*wasmz_store_t,
    module_handle: ?*wasmz_module_t,
    out_instance: ?*?*wasmz_instance_t,
) ?*wasmz_error_t {
    const sh = store_handle orelse return makeError("store is null", .{});
    const mh = module_handle orelse return makeError("module is null", .{});
    const out = out_instance orelse return makeError("out_instance is null", .{});

    const store: *Store = @ptrCast(@alignCast(sh.ptr));
    const arc: *ArcModule = @ptrCast(@alignCast(mh.ptr));

    const inst_ptr = alloc.create(Instance) catch
        return makeError("out of memory", .{});

    inst_ptr.* = Instance.init(store, arc.retain(), Linker.empty) catch |err| {
        alloc.destroy(inst_ptr);
        return makeError("instantiation failed: {s}", .{@errorName(err)});
    };

    const handle = alloc.create(wasmz_instance_t) catch {
        inst_ptr.deinit();
        alloc.destroy(inst_ptr);
        return makeError("out of memory", .{});
    };
    handle.* = .{ .ptr = inst_ptr };
    out.* = handle;
    return null;
}

export fn wasmz_instance_delete(handle: ?*wasmz_instance_t) void {
    const h = handle orelse return;
    const inst: *Instance = @ptrCast(@alignCast(h.ptr));
    inst.deinit();
    alloc.destroy(inst);
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

    // Convert C vals → RawVal
    const raw_args = alloc.alloc(RawVal, args_len) catch
        return makeError("out of memory", .{});
    defer alloc.free(raw_args);

    if (args_len > 0) {
        const args = args_ptr orelse return makeError("args is null but args_len > 0", .{});
        for (0..args_len) |i| {
            raw_args[i] = cvalToRaw(args[i]);
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
                    if (results_len >= 1) {
                        results[0] = rawToCval(val, results[0].kind);
                    }
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

// ── Memory ───────────────────────────────────────────────────────────────────

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

export fn wasmz_instance_memory_grow(handle: ?*wasmz_instance_t, pages: u32) c_int {
    const h = handle orelse return -1;
    const inst: *Instance = @ptrCast(@alignCast(h.ptr));
    const res = inst.memory.grow(pages);
    return res catch return -1;
}

// ── Linker ─────────────────────────────────────────────────────────────────

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
) c_int;

export fn wasmz_linker_new() ?*wasmz_linker_t {
    const linker_ptr = alloc.create(Linker) catch return null;
    linker_ptr.* = Linker.empty;
    const handle = alloc.create(wasmz_linker_t) catch {
        alloc.destroy(linker_ptr);
        return null;
    };
    handle.* = .{ .ptr = linker_ptr };
    return handle;
}

export fn wasmz_linker_delete(handle: ?*wasmz_linker_t) void {
    const h = handle orelse return;
    const linker: *Linker = @ptrCast(@alignCast(h.ptr));
    linker.deinit(alloc);
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
    func: wasmz_func_t,
    host_data: ?*anyopaque,
) ?*wasmz_error_t {
    const h = handle orelse return makeError("linker is null", .{});
    const mod_name_input = module_name_ptr orelse return makeError("module_name is null", .{});
    const func_name_input = func_name_ptr orelse return makeError("func_name is null", .{});
    const linker: *Linker = @ptrCast(@alignCast(h.ptr));
    const mod_slice = std.mem.span(mod_name_input);
    const fn_slice = std.mem.span(func_name_input);

    const param_types = alloc.alloc(ValType, param_count) catch
        return makeError("out of memory", .{});
    defer alloc.free(param_types);
    for (0..param_count) |i| {
        param_types[i] = switch (param_kinds.?(i)) {
            .I32 => .I32,
            .I64 => .I64,
            .F32 => .F32,
            .F64 => .F64,
            .V128 => .V128,
            .REF_NULL => .RefNull,
            .REF_FUNC => .RefFunc,
            .EXTERN_REF => .ExternRef,
        };
    }

    const result_types = alloc.alloc(ValType, result_count) catch
        return makeError("out of memory", .{});
    defer alloc.free(result_types);
    for (0..result_count) |i| {
        result_types[i] = switch (result_kinds.?(i)) {
            .I32 => .I32,
            .I64 => .I64,
            .F32 => .F32,
            .F64 => .F64,
            .V128 => .V128,
            .REF_NULL => .RefNull,
            .REF_FUNC => .RefFunc,
            .EXTERN_REF => .ExternRef,
        };
    }

    const wrapper = alloc.create(HostFuncWrapper) catch
        return makeError("out of memory", .{});
    wrapper.* = .{
        .func = func,
        .host_data = host_data,
        .param_count = param_count,
        .result_count = result_count,
    };

    const hf = HostFunc.init(
        wrapper,
        wrapperWrapper,
        param_types,
        result_types,
    );

    linker.define(alloc, mod_slice, fn_slice, hf) catch |err|
        return makeError("linker define failed: {s}", .{@errorName(err)});

    return null;
}

const HostFuncWrapper = struct {
    func: wasmz_func_t,
    host_data: ?*anyopaque,
    param_count: usize,
    result_count: usize,
};

fn wrapperWrapper(
    host_data: ?*anyopaque,
    ctx: *HostContext,
    params: []const RawVal,
    results: []RawVal,
) HostError!void {
    const w: *HostContext = @ptrCast(@alignCast(ctx));
    const wrapper: *HostFuncWrapper = @ptrCast(@alignCast(host_data));
    const c_params = alloc.alloc(wasmz_val_t, wrapper.param_count) catch
        return error.OutOfMemory;
    defer alloc.free(c_params);
    for (params, 0..) |p, i| {
        c_params[i] = rawToCval(p, @as(ValKind, @intCast(c_params[i].kind)));
    }

    const c_results = alloc.alloc(wasmz_val_t, wrapper.result_count) catch
        return error.OutOfMemory;
    defer alloc.free(c_results);

    const ret = wrapper.func(wrapper.host_data, w, c_params, wrapper.param_count, c_results, wrapper.result_count);
    if (ret != 0) {
        return error.HostTrap;
    }
    for (c_results, 0..) |cr, i| {
        results[i] = cvalToRaw(cr);
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
    const linker: *Linker = @ptrCast(@alignCast(h.ptr));
    const mod_slice = std.mem.span(mod_name_input);
    const global_slice = std.mem.span(global_name_input);

    const raw = cvalToRaw(value);
    linker.defineGlobal(alloc, mod_slice, global_slice, raw) catch |err|
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
    const lh = linker_handle;
    const out = out_instance orelse return makeError("out_instance is null", .{});

    const store: *Store = @ptrCast(@alignCast(sh.ptr));
    const arc: *ArcModule = @ptrCast(@alignCast(mh.ptr));

    var linker: Linker = Linker.empty;
    if (lh) |lh_valid| {
        const linker_ptr: *Linker = @ptrCast(@alignCast(lh_valid.ptr));
        linker = linker_ptr.*;
    }

    const inst_ptr = alloc.create(Instance) catch
        return makeError("out of memory", .{});

    inst_ptr.* = Instance.init(store, arc.retain(), linker) catch |err| {
        alloc.destroy(inst_ptr);
        return makeError("instantiation failed: {s}", .{@errorName(err)});
    };

    const handle = alloc.create(wasmz_instance_t) catch {
        inst_ptr.deinit();
        alloc.destroy(inst_ptr);
        return makeError("out of memory", .{});
    };
    handle.* = .{ .ptr = inst_ptr };
    out.* = handle;
    return null;
}

// ── Host Context ────────────────────────────────────────────────────────────

export fn wasmz_context_memory(ctx: ?*anyopaque) ?[*]u8 {
    const c: *HostContext = @ptrCast(@alignCast(ctx));
    const bytes = c.memory() orelse return null;
    return bytes.ptr;
}

export fn wasmz_context_memory_size(ctx: ?*anyopaque) usize {
    const c: *HostContext = @ptrCast(@alignCast(ctx));
    return c.memory() orelse &.{}.len;
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

export fn wasmz_context_read_value(ctx: ?*anyopaque, addr: u32, out: ?*anyopaque, size: usize) c_int {
    const c: *HostContext = @ptrCast(@alignCast(ctx));
    const o = out orelse return -1;
    const bytes = c.readBytes(addr, size) catch return -1;
    @memcpy(o, bytes.ptr[0..size]);
    return 0;
}

export fn wasmz_context_write_value(ctx: ?*anyopaque, addr: u32, value: ?*const anyopaque, size: usize) c_int {
    const c: *HostContext = @ptrCast(@alignCast(ctx));
    const v = value orelse return -1;
    c.writeBytes(addr, @as([*]const u8, @ptrCast(v))[0..size]) catch return -1;
    return 0;
}

export fn wasmz_context_trap(ctx: ?*anyopaque, msg_ptr: ?[*:0]const u8) void {
    const c: *HostContext = @ptrCast(@alignCast(ctx));
    const m = msg_ptr orelse return;
    const msg = std.mem.span(m);
    const trap = Trap.userMessage(msg);
    c.pending_trap = trap;
}

// ── Module introspection ───────────────────────────────────────────────

export fn wasmz_module_has_memory(handle: ?*const wasmz_module_t) c_int {
    const h = handle orelse return 0;
    const arc: *const ArcModule = @ptrCast(@alignCast(h.ptr));
    return if (arc.value.memory != null) 1 else 0;
}

export fn wasmz_module_memory_min(handle: ?*const wasmz_module_t) u32 {
    const h = handle orelse return 0;
    const arc: *const ArcModule = @ptrCast(@alignCast(h.ptr));
    return arc.value.memory.?.min_pages orelse 0;
}

export fn wasmz_module_memory_max(handle: ?*const wasmz_module_t) u32 {
    const h = handle orelse return std.math.maxInt(u32);
    const arc: *const ArcModule = @ptrCast(@alignCast(h.ptr));
    return arc.value.memory.?.max_pages orelse std.math.maxInt(u32);
}

export fn wasmz_module_export_count(handle: ?*const wasmz_module_t) usize {
    const h = handle orelse return 0;
    const arc: *const ArcModule = @ptrCast(@alignCast(h.ptr));
    return arc.value.exports.size();
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

// ── Store user data ───────────────────────────────────────────────────────

export fn wasmz_store_set_user_data(handle: ?*wasmz_store_t, user_data: ?*anyopaque) void {
    const h = handle orelse return;
    const store: *Store = @ptrCast(@alignCast(h.ptr));
    store.setUserData(user_data);
}

export fn wasmz_store_get_user_data(handle: ?*wasmz_store_t) ?*anyopaque {
    const h = handle orelse return null;
    const store: *Store = @ptrCast(@alignCast(h.ptr));
    return store.user_data;
}

// ── VM stats ────────────────────────────────────────────────────────────────

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

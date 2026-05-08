/// wasmz.wasm — browser-compatible WASM runtime-in-WASM
///
/// Compiles to wasm32-freestanding.  Exports C-style functions callable from
/// JavaScript via WebAssembly.instantiate.  No filesystem, no stdio, no
/// OS-specific APIs.
///
/// Exported functions:
///   wasmz_init()           — initialise the runtime
///   wasmz_load(ptr, len)   — load a .wasm module from bytes, returns 0 on success
///   wasmz_call(nptr, nlen, args, argc) — call an exported function, returns i64 result
///   wasmz_mem_size()       — linear memory size in bytes
///   wasmz_mem_read(off, buf, len) — read linear memory into buf
///   wasmz_deinit()         — release all resources
const std = @import("std");
const wasmz = @import("wasmz");

const Allocator = std.mem.Allocator;

var ally: Allocator = .{ .ptr = undefined, .vtable = &std.heap.WasmAllocator.vtable };
var engine: wasmz.Engine = undefined;
var arc_module: wasmz.ArcModule = undefined;
var store: wasmz.Store = undefined;
var instance: ?wasmz.Instance = null;
var linker: wasmz.Linker = .empty;

export fn wasmz_init() void {
    engine = wasmz.Engine.init(ally, .{}) catch @panic("wasmz_init: engine init failed");
}

export fn wasmz_load(ptr: [*]const u8, len: usize) i32 {
    const bytes = ptr[0..len];
    arc_module = wasmz.Module.compileArc(engine, bytes) catch return -1;
    store = wasmz.Store.init(ally, engine, std.Io.Threaded.global_single_threaded.io()) catch {
        var mod = if (arc_module.releaseUnwrap()) |m| m else unreachable;
        mod.deinit();
        return -2;
    };
    instance = wasmz.Instance.init(&store, arc_module.retain(), linker) catch {
        store.deinit();
        var mod = if (arc_module.releaseUnwrap()) |m| m else unreachable;
        mod.deinit();
        return -3;
    };
    return 0;
}

export fn wasmz_call(name_ptr: [*]const u8, name_len: usize, args: [*]const i32, argc: usize) i64 {
    const name = name_ptr[0..name_len];
    if (instance == null) return -1;

    var call_args: std.ArrayList(wasmz.RawVal) = .empty;
    defer call_args.deinit(ally);
    for (0..argc) |i| {
        call_args.append(ally, wasmz.RawVal.from(args[i])) catch return -2;
    }

    const result = instance.?.call(name, call_args.items) catch return -3;
    return switch (result) {
        .ok => |val| if (val) |v| @as(i64, @bitCast(v.readAs(u64))) else 0,
        .trap => -4,
    };
}

export fn wasmz_mem_size() i32 {
    if (instance == null) return 0;
    return @intCast(instance.?.memory.byteLen());
}

export fn wasmz_mem_read(offset: i32, buf: [*]u8, buf_len: usize) void {
    if (instance == null) return;
    const off: usize = @intCast(offset);
    const mem = instance.?.memory.bytes();
    const end = @min(off + buf_len, mem.len);
    if (off < mem.len) {
        @memcpy(buf[0 .. end - off], mem[off..end]);
    }
}

export fn wasmz_deinit() void {
    if (instance) |*inst| inst.deinit();
    store.deinit();
    if (arc_module.releaseUnwrap()) |m| {
        var mod = m;
        mod.deinit();
    }
    engine.deinit();
}

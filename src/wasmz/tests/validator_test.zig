/// Comprehensive tests for WebAssembly 2.0 + GC + EH + SIMD + Threads + Memory64
/// static validation (`src/validator/`).
const std = @import("std");
const testing = std.testing;

const engine_mod = @import("../../engine/root.zig");
const config_mod = @import("../../engine/config.zig");
const module_mod = @import("../module.zig");

const Engine = engine_mod.Engine;
const Config = config_mod.Config;
const Module = module_mod.Module;

const wasm_header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

fn writeUleb(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, val_in: u32) !void {
    var v = val_in;
    while (true) {
        var byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v != 0) byte |= 0x80;
        try list.append(alloc, byte);
        if (v == 0) break;
    }
}

fn appendSection(
    module_buf: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    sec_id: u8,
    payload: []const u8,
) !void {
    try module_buf.append(alloc, sec_id);
    try writeUleb(module_buf, alloc, @intCast(payload.len));
    try module_buf.appendSlice(alloc, payload);
}

fn appendCodeSection(
    module_buf: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    bodies: []const []const u8,
) !void {
    var sec: std.ArrayListUnmanaged(u8) = .empty;
    defer sec.deinit(alloc);
    try writeUleb(&sec, alloc, @intCast(bodies.len));
    for (bodies) |body| {
        try writeUleb(&sec, alloc, @intCast(body.len));
        try sec.appendSlice(alloc, body);
    }
    try appendSection(module_buf, alloc, 10, sec.items);
}

fn appendFuncType(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, params: []const u8, results: []const u8) !void {
    try buf.append(alloc, 0x60);
    try writeUleb(buf, alloc, @intCast(params.len));
    try buf.appendSlice(alloc, params);
    try writeUleb(buf, alloc, @intCast(results.len));
    try buf.appendSlice(alloc, results);
}

fn compileModuleExpectOk(bytes: []const u8, cfg: Config) !void {
    var engine = try Engine.init(testing.allocator, cfg);
    defer engine.deinit();
    var m = try Module.compile(engine, bytes);
    defer m.deinit();
}

fn compileModuleExpectError(bytes: []const u8, expected: anyerror) !void {
    var engine = try Engine.init(testing.allocator, Config{});
    defer engine.deinit();
    try testing.expectError(expected, Module.compile(engine, bytes));
}

// =============================================================================
// 1. Type Section & GC Subtyping Rules (Issue #8)
// =============================================================================

test "validator rejects retyping mutable struct field in subtype" {
    // Type 0: (sub (struct (field (mut anyref))))
    // Type 1: (sub 0 (struct (field (mut eqref))))  -- invalid: mutable field must be invariant
    const bytes = wasm_header ++ [_]u8{
        0x01, 0x0d, 0x02,
        0x50, 0x00, 0x5f, 0x01, 0x6e, 0x01,
        0x50, 0x01, 0x00, 0x5f, 0x01, 0x6d, 0x01,
    };
    try compileModuleExpectError(&bytes, error.InvalidSubtype);
}

test "validator rejects dropping struct field in subtype" {
    // Type 0: (sub (struct i32 i64))
    // Type 1: (sub 0 (struct i32))  -- invalid: subtype must preserve all parent fields
    const bytes = wasm_header ++ [_]u8{
        0x01, 0x0e, 0x02,
        0x50, 0x00, 0x5f, 0x02, 0x7f, 0x00, 0x7e, 0x00,
        0x50, 0x01, 0x00, 0x5f, 0x01, 0x7f, 0x00,
    };
    try compileModuleExpectError(&bytes, error.InvalidSubtype);
}

test "validator rejects retyping immutable struct field to unrelated type" {
    // Type 0: (sub (struct i32))
    // Type 1: (sub 0 (struct i64))  -- invalid: i64 </: i32
    const bytes = wasm_header ++ [_]u8{
        0x01, 0x0d, 0x02,
        0x50, 0x00, 0x5f, 0x01, 0x7f, 0x00,
        0x50, 0x01, 0x00, 0x5f, 0x01, 0x7e, 0x00,
    };
    try compileModuleExpectError(&bytes, error.InvalidSubtype);
}

test "validator accepts covariant immutable struct width and depth subtyping" {
    // Type 0: (sub (struct i32 anyref))
    // Type 1: (sub 0 (struct i32 eqref f32))
    const bytes = wasm_header ++ [_]u8{
        0x01, 0x11, 0x02,
        0x50, 0x00, 0x5f, 0x02, 0x7f, 0x00, 0x6e, 0x00,
        0x50, 0x01, 0x00, 0x5f, 0x03, 0x7f, 0x00, 0x6d, 0x00, 0x7d, 0x00,
    };
    try compileModuleExpectOk(&bytes, Config{});
}

test "validator rejects extending a final type" {
    // Type 0: (struct i32)  -- implicitly final
    // Type 1: (sub 0 (struct i32))
    const bytes = wasm_header ++ [_]u8{
        0x01, 0x0b, 0x02,
        0x5f, 0x01, 0x7f, 0x00,
        0x50, 0x01, 0x00, 0x5f, 0x01, 0x7f, 0x00,
    };
    try compileModuleExpectError(&bytes, error.ExtendFinalType);
}

test "validator enforces maximum subtyping depth of 63" {
    const alloc = testing.allocator;

    // Depth 63: 64 types (0 root, 1..63 extending i-1) => valid
    {
        var type_sec: std.ArrayListUnmanaged(u8) = .empty;
        defer type_sec.deinit(alloc);
        try writeUleb(&type_sec, alloc, 64);
        // Root type 0: (sub (struct))
        try type_sec.appendSlice(alloc, &.{ 0x50, 0x00, 0x5f, 0x00 });
        for (1..64) |i| {
            try type_sec.appendSlice(alloc, &.{ 0x50, 0x01 });
            try writeUleb(&type_sec, alloc, @intCast(i - 1));
            try type_sec.appendSlice(alloc, &.{ 0x5f, 0x00 });
        }

        var mod_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer mod_buf.deinit(alloc);
        try mod_buf.appendSlice(alloc, &wasm_header);
        try appendSection(&mod_buf, alloc, 1, type_sec.items);
        try compileModuleExpectOk(mod_buf.items, Config{});
    }

    // Depth 64: 65 types (0 root, 1..64 extending i-1) => SubtypeDepthExceeded
    {
        var type_sec: std.ArrayListUnmanaged(u8) = .empty;
        defer type_sec.deinit(alloc);
        try writeUleb(&type_sec, alloc, 65);
        try type_sec.appendSlice(alloc, &.{ 0x50, 0x00, 0x5f, 0x00 });
        for (1..65) |i| {
            try type_sec.appendSlice(alloc, &.{ 0x50, 0x01 });
            try writeUleb(&type_sec, alloc, @intCast(i - 1));
            try type_sec.appendSlice(alloc, &.{ 0x5f, 0x00 });
        }

        var mod_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer mod_buf.deinit(alloc);
        try mod_buf.appendSlice(alloc, &wasm_header);
        try appendSection(&mod_buf, alloc, 1, type_sec.items);
        try compileModuleExpectError(mod_buf.items, error.SubtypeDepthExceeded);
    }
}

test "validator rejects forward type reference outside rec group and accepts inside rec group" {
    // Outside rec group: type 0 = (struct (ref null 1)), type 1 = (struct)
    const invalid_bytes = wasm_header ++ [_]u8{
        0x01, 0x08, 0x02,
        0x5f, 0x01, 0x63, 0x01, 0x00,
        0x5f, 0x00,
    };
    try compileModuleExpectError(&invalid_bytes, error.ForwardTypeReference);

    // Inside rec group: rec { type 0 = (struct (ref null 1)), type 1 = (struct) }
    const valid_bytes = wasm_header ++ [_]u8{
        0x01, 0x0a, 0x01,
        0x4e, 0x02,
        0x5f, 0x01, 0x63, 0x01, 0x00,
        0x5f, 0x00,
    };
    try compileModuleExpectOk(&valid_bytes, Config{});
}

// =============================================================================
// 2. Operand Stack, Control Flow, Function Arity (Issue #8)
// =============================================================================

test "validator rejects block result type mismatch" {
    // func () -> () { block (result i32) f32.const 1.0 end drop }
    const bytes = wasm_header ++ [_]u8{
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x00,
        0x0a, 0x0d, 0x01,
        0x0b, 0x00, 0x02, 0x7f, 0x43, 0x00, 0x00, 0x80, 0x3f, 0x0b, 0x1a, 0x0b,
    };
    try compileModuleExpectError(&bytes, error.TypeMismatch);
}

test "validator rejects wrong function result arity" {
    // func () -> (i32 i32) { i32.const 1 }  -- missing second i32
    const bytes = wasm_header ++ [_]u8{
        0x01, 0x06, 0x01, 0x60, 0x00, 0x02, 0x7f, 0x7f,
        0x03, 0x02, 0x01, 0x00,
        0x0a, 0x06, 0x01,
        0x04, 0x00, 0x41, 0x01, 0x0b,
    };
    try compileModuleExpectError(&bytes, error.TypeMismatch);
}

test "validator rejects if without else producing result value" {
    // func () -> i32 { i32.const 1; if (result i32) i32.const 2 end }
    const bytes = wasm_header ++ [_]u8{
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
        0x03, 0x02, 0x01, 0x00,
        0x0a, 0x0b, 0x01,
        0x09, 0x00, 0x41, 0x01, 0x04, 0x7f, 0x41, 0x02, 0x0b, 0x0b,
    };
    try compileModuleExpectError(&bytes, error.TypeMismatch);
}

test "validator accepts unreachable followed by ref.as_non_null as concrete non-null ref" {
    // Type 0: (struct)
    // Type 1: () -> (ref 0)
    // Body: unreachable ref.as_non_null
    const bytes = wasm_header ++ [_]u8{
        0x01, 0x09, 0x02,
        0x5f, 0x00,
        0x60, 0x00, 0x01, 0x64, 0x00,
        0x03, 0x02, 0x01, 0x01,
        0x0a, 0x06, 0x01,
        0x04, 0x00, 0x00, 0xd4, 0x0b,
    };
    try compileModuleExpectOk(&bytes, Config{});
}

test "validator rejects br_table target label arity mismatch" {
    // block (result i32) block (i32.const 0; br_table 0 1) end i32.const 0 end drop
    const bytes = wasm_header ++ [_]u8{
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x00,
        0x0a, 0x11, 0x01,
        0x0f, 0x00,
        0x02, 0x7f, // outer block (result i32)
        0x02, 0x40, // inner block void
        0x41, 0x00, // i32.const 0
        0x0e, 0x01, 0x00, 0x01, // br_table 0 1 (arity 0 != arity 1)
        0x0b,
        0x0b,
        0x1a,
        0x0b,
    };
    try compileModuleExpectError(&bytes, error.InvalidArity);
}

test "validator rejects untyped select on reference type and multi-result select_with_type" {
    // Untyped select on anyref: ref.null any; ref.null any; i32.const 0; select; drop => TypeMismatch
    const untyped_ref_select = wasm_header ++ [_]u8{
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x00,
        0x0a, 0x0c, 0x01,
        0x0a, 0x00, 0xd0, 0x6e, 0xd0, 0x6e, 0x41, 0x00, 0x1b, 0x1a, 0x0b,
    };
    try compileModuleExpectError(&untyped_ref_select, error.TypeMismatch);

    // Typed select with 2 types => InvalidSelectType
    const multi_typed_select = wasm_header ++ [_]u8{
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x00,
        0x0a, 0x08, 0x01,
        0x06, 0x00, 0x1c, 0x02, 0x7f, 0x7f, 0x0b,
    };
    try compileModuleExpectError(&multi_typed_select, error.InvalidSelectType);
}

// =============================================================================
// 3. GC Instructions, Defaultability, Mutability, Locals, C.refs (Issue #8)
// =============================================================================

test "validator rejects array.new_default on non-defaultable element type" {
    // Type 0: (struct)
    // Type 1: (array (ref 0))  -- non-nullable ref is not defaultable
    // Type 2: () -> (ref 1)
    // Body: i32.const 1; array.new_default 1
    const bytes = wasm_header ++ [_]u8{
        0x01, 0x0d, 0x03,
        0x5f, 0x00,
        0x5e, 0x64, 0x00, 0x01,
        0x60, 0x00, 0x01, 0x64, 0x01,
        0x03, 0x02, 0x01, 0x02,
        0x0a, 0x09, 0x01,
        0x07, 0x00, 0x41, 0x01, 0xfb, 0x07, 0x01, 0x0b,
    };
    try compileModuleExpectError(&bytes, error.NonDefaultableType);
}

test "validator rejects struct.new_default on non-defaultable field" {
    // Type 0: (struct)
    // Type 1: (struct (field (ref 0)))
    // Type 2: () -> ()
    // Body: struct.new_default 1; drop
    const bytes = wasm_header ++ [_]u8{
        0x01, 0x0c, 0x03,
        0x5f, 0x00,
        0x5f, 0x01, 0x64, 0x00, 0x00,
        0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x02,
        0x0a, 0x08, 0x01,
        0x06, 0x00, 0xfb, 0x01, 0x01, 0x1a, 0x0b,
    };
    try compileModuleExpectError(&bytes, error.NonDefaultableType);
}

test "validator rejects array.copy narrowing and accepts array.copy widening" {
    // Type 0: $base = (sub (struct))
    // Type 1: $der = (sub 0 (struct))
    // Type 2: $arr_base = (array (mut (ref null 0)))
    // Type 3: $arr_der  = (array (mut (ref null 1)))
    // Type 4: () -> ()
    const type_sec = [_]u8{
        0x05,
        0x50, 0x00, 0x5f, 0x00, // 0: $base
        0x50, 0x01, 0x00, 0x5f, 0x00, // 1: $der
        0x5e, 0x63, 0x00, 0x01, // 2: (array (mut (ref null 0)))
        0x5e, 0x63, 0x01, 0x01, // 3: (array (mut (ref null 1)))
        0x60, 0x00, 0x00, // 4: () -> ()
    };

    // Invalid narrowing copy: dst = $arr_der (3), src = $arr_base (2)
    // array.new_default 3; i32.const 0; array.new_default 2; i32.const 0; i32.const 0; array.copy 3 2
    var bad_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer bad_buf.deinit(testing.allocator);
    try bad_buf.appendSlice(testing.allocator, &wasm_header);
    try appendSection(&bad_buf, testing.allocator, 1, &type_sec);
    try appendSection(&bad_buf, testing.allocator, 3, &.{ 0x01, 0x04 });
    const bad_body = [_]u8{
        0x00,
        0x41, 0x01, 0xfb, 0x07, 0x03, // dst $arr_der
        0x41, 0x00,
        0x41, 0x01, 0xfb, 0x07, 0x02, // src $arr_base
        0x41, 0x00,
        0x41, 0x00,
        0xfb, 0x11, 0x03, 0x02, // array.copy dst=3 src=2
        0x0b,
    };
    try appendCodeSection(&bad_buf, testing.allocator, &.{&bad_body});
    try compileModuleExpectError(bad_buf.items, error.TypeMismatch);

    // Valid widening copy: dst = $arr_base (2), src = $arr_der (3)
    var good_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer good_buf.deinit(testing.allocator);
    try good_buf.appendSlice(testing.allocator, &wasm_header);
    try appendSection(&good_buf, testing.allocator, 1, &type_sec);
    try appendSection(&good_buf, testing.allocator, 3, &.{ 0x01, 0x04 });
    const good_body = [_]u8{
        0x00,
        0x41, 0x01, 0xfb, 0x07, 0x02, // dst $arr_base
        0x41, 0x00,
        0x41, 0x01, 0xfb, 0x07, 0x03, // src $arr_der
        0x41, 0x00,
        0x41, 0x00,
        0xfb, 0x11, 0x02, 0x03, // array.copy dst=2 src=3
        0x0b,
    };
    try appendCodeSection(&good_buf, testing.allocator, &.{&good_body});
    try compileModuleExpectOk(good_buf.items, Config{});
}

test "validator rejects struct.set and array.set on immutable targets" {
    // Immutable struct.set: Type 0 = (struct i32)
    const imm_struct = wasm_header ++ [_]u8{
        0x01, 0x08, 0x02,
        0x5f, 0x01, 0x7f, 0x00,
        0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x01,
        0x0a, 0x0f, 0x01,
        0x0d, 0x00,
        0x41, 0x01, 0xfb, 0x00, 0x00,
        0x41, 0x02,
        0xfb, 0x05, 0x00, 0x00,
        0x0b,
    };
    try compileModuleExpectError(&imm_struct, error.ImmutableField);

    // Immutable array.set: Type 0 = (array i32 const)
    const imm_array = wasm_header ++ [_]u8{
        0x01, 0x07, 0x02,
        0x5e, 0x7f, 0x00,
        0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x01,
        0x0a, 0x10, 0x01,
        0x0e, 0x00,
        0x41, 0x01, 0xfb, 0x07, 0x00,
        0x41, 0x00,
        0x41, 0x02,
        0xfb, 0x0e, 0x00,
        0x0b,
    };
    try compileModuleExpectError(&imm_array, error.ImmutableField);
}

test "validator tracks non-defaultable local initialization across block boundaries" {
    // Type 0: (struct), Type 1: () -> ()
    // Local 0: (ref 0) non-nullable
    const type_sec = [_]u8{ 0x02, 0x5f, 0x00, 0x60, 0x00, 0x00 };

    // Case A: local.get 0 immediately (never initialized) => UninitializedLocal
    var uninit_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer uninit_buf.deinit(testing.allocator);
    try uninit_buf.appendSlice(testing.allocator, &wasm_header);
    try appendSection(&uninit_buf, testing.allocator, 1, &type_sec);
    try appendSection(&uninit_buf, testing.allocator, 3, &.{ 0x01, 0x01 });
    const uninit_body = [_]u8{ 0x01, 0x01, 0x64, 0x00, 0x20, 0x00, 0x1a, 0x0b };
    try appendCodeSection(&uninit_buf, testing.allocator, &.{&uninit_body});
    try compileModuleExpectError(uninit_buf.items, error.UninitializedLocal);

    // Case B: local.set 0 inside block, then local.get 0 after block end => UninitializedLocal
    var reset_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer reset_buf.deinit(testing.allocator);
    try reset_buf.appendSlice(testing.allocator, &wasm_header);
    try appendSection(&reset_buf, testing.allocator, 1, &type_sec);
    try appendSection(&reset_buf, testing.allocator, 3, &.{ 0x01, 0x01 });
    const reset_body = [_]u8{
        0x01, 0x01, 0x64, 0x00, // 1 local: (ref 0)
        0x02, 0x40, // block
        0xfb, 0x00, 0x00, // struct.new 0
        0x21, 0x00, // local.set 0
        0x0b, // end block -> resets init status of local 0
        0x20, 0x00, // local.get 0 -> must fail!
        0x1a,
        0x0b,
    };
    try appendCodeSection(&reset_buf, testing.allocator, &.{&reset_body});
    try compileModuleExpectError(reset_buf.items, error.UninitializedLocal);

    // Case C: local.set 0 then local.get 0 in same block => valid
    var ok_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer ok_buf.deinit(testing.allocator);
    try ok_buf.appendSlice(testing.allocator, &wasm_header);
    try appendSection(&ok_buf, testing.allocator, 1, &type_sec);
    try appendSection(&ok_buf, testing.allocator, 3, &.{ 0x01, 0x01 });
    const ok_body = [_]u8{
        0x01, 0x01, 0x64, 0x00,
        0x02, 0x40,
        0xfb, 0x00, 0x00,
        0x21, 0x00,
        0x20, 0x00,
        0x1a,
        0x0b,
        0x0b,
    };
    try appendCodeSection(&ok_buf, testing.allocator, &.{&ok_body});
    try compileModuleExpectOk(ok_buf.items, Config{});
}

test "validator enforces C.refs declaration for ref.func" {
    // Missing elem declare / export for func 0 => UndeclaredFuncRef
    const undeclared = wasm_header ++ [_]u8{
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x00,
        0x0a, 0x07, 0x01,
        0x05, 0x00, 0xd2, 0x00, 0x1a, 0x0b,
    };
    try compileModuleExpectError(&undeclared, error.UndeclaredFuncRef);

    // With declarative element segment `elem declare func 0` => valid
    const declared = wasm_header ++ [_]u8{
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x00,
        0x09, 0x05, 0x01, 0x03, 0x00, 0x01, 0x00,
        0x0a, 0x07, 0x01,
        0x05, 0x00, 0xd2, 0x00, 0x1a, 0x0b,
    };
    try compileModuleExpectOk(&declared, Config{});
}

// =============================================================================
// 4. Globals, Memory Limits, Start/Tag, Alignment, SIMD, Reader, Opt-out
// =============================================================================

test "validator rejects global.set on immutable global" {
    // Global 0: immutable i32
    const bytes = wasm_header ++ [_]u8{
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x00,
        0x06, 0x06, 0x01, 0x7f, 0x00, 0x41, 0x00, 0x0b,
        0x0a, 0x08, 0x01,
        0x06, 0x00, 0x41, 0x01, 0x24, 0x00, 0x0b,
    };
    try compileModuleExpectError(&bytes, error.ImmutableGlobal);
}

test "validator enforces memory limits (max 65536, shared requires max, min <= max)" {
    // min 65537 pages in 32-bit memory => InvalidMemoryLimits
    const too_many_pages = wasm_header ++ [_]u8{
        0x05, 0x05, 0x01, 0x00, 0x81, 0x80, 0x04,
    };
    try compileModuleExpectError(&too_many_pages, error.InvalidMemoryLimits);

    // shared memory (flags 0x02 = shared without max!) => InvalidMemoryLimits
    const shared_no_max = wasm_header ++ [_]u8{
        0x05, 0x03, 0x01, 0x02, 0x01,
    };
    try compileModuleExpectError(&shared_no_max, error.InvalidMemoryLimits);

    // min > max => InvalidMemoryLimits
    const min_gt_max = wasm_header ++ [_]u8{
        0x05, 0x04, 0x01, 0x01, 0x05, 0x02,
    };
    try compileModuleExpectError(&min_gt_max, error.InvalidMemoryLimits);
}

test "validator rejects start function with non-empty signature" {
    // Func 0 has type () -> i32; Start = 0 => InvalidStartFunction
    const bytes = wasm_header ++ [_]u8{
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
        0x03, 0x02, 0x01, 0x00,
        0x08, 0x01, 0x00,
        0x0a, 0x06, 0x01,
        0x04, 0x00, 0x41, 0x00, 0x0b,
    };
    try compileModuleExpectError(&bytes, error.InvalidStartFunction);
}

test "validator rejects tag with non-empty result types" {
    // Tag 0 uses type 0: () -> i32 => InvalidTagType
    const bytes = wasm_header ++ [_]u8{
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
        0x0d, 0x03, 0x01, 0x00, 0x00,
    };
    try compileModuleExpectError(&bytes, error.InvalidTagType);
}

test "validator rejects memory alignment larger than natural access width" {
    // 1 memory, func () -> () { i32.const 0; i32.load align=3 offset=0; drop } (2^3=8 > 4)
    const bytes = wasm_header ++ [_]u8{
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x00,
        0x05, 0x03, 0x01, 0x00, 0x01,
        0x0a, 0x0a, 0x01,
        0x08, 0x00, 0x41, 0x00, 0x28, 0x03, 0x00, 0x1a, 0x0b,
    };
    try compileModuleExpectError(&bytes, error.InvalidAlignment);
}

test "validator rejects out-of-bounds SIMD lane index" {
    // func () -> () { v128.const 0..0; i8x16.extract_lane_s 16; drop } => InvalidLaneIndex
    const bytes = wasm_header ++ [_]u8{
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x00,
        0x0a, 0x1a, 0x01,
        0x18, 0x00,
        0xfd, 0x0c, // v128.const + 16 zero bytes
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0xfd, 0x15, 0x10, // i8x16.extract_lane_s lane=16 (>= 16)
        0x1a,
        0x0b,
    };
    try compileModuleExpectError(&bytes, error.InvalidLaneIndex);
}

test "validator runs under compileReader and checks DataCount mismatch" {
    // DataCount = 2, Data section has 1 segment => DataCountMismatch
    const bad_dc = wasm_header ++ [_]u8{
        0x05, 0x03, 0x01, 0x00, 0x01,
        0x0c, 0x01, 0x02, // DataCount = 2
        0x0b, 0x07, 0x01, 0x00, 0x41, 0x00, 0x0b, 0x01, 0xaa, // 1 active data segment
    };

    var engine = try Engine.init(testing.allocator, Config{});
    defer engine.deinit();
    var reader: std.Io.Reader = .fixed(&bad_dc);
    try testing.expectError(error.DataCountMismatch, Module.compileReader(engine, &reader));
}

test "Engine Config validate = false bypasses validation on invalid module" {
    // Wrong block result type (Issue #8): fails with validate = true, compiles with validate = false.
    const invalid_module = wasm_header ++ [_]u8{
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x00,
        0x0a, 0x0d, 0x01,
        0x0b, 0x00, 0x02, 0x7f, 0x43, 0x00, 0x00, 0x80, 0x3f, 0x0b, 0x1a, 0x0b,
    };
    try compileModuleExpectError(&invalid_module, error.TypeMismatch);
    try compileModuleExpectOk(&invalid_module, Config{ .validate = false });
}

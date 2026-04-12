/// sqlite_test.zig — Integration tests for SQLite compiled as wasm32-wasi reactor
///
/// Tests that wasmz can host a real-world, non-trivial WASM module:
/// SQLite 3.53 compiled as a WASI reactor with exported C API functions.
///
/// The sqlite3.wasm fixture is built by:
///   zig build sqlite-wasm
/// (or manually via: cd tests/sqlite/fixtures/sqlite_wasm && zig build)
///
/// Exported functions tested:
///   _initialize()                                  — reactor init
///   alloc(size: i32) -> i32                        — wasm allocator
///   dealloc(ptr: i32, size: i32)                   — wasm free
///   db_open(path_ptr, path_len, db_out_ptr) -> i32 — open :memory: db
///   db_exec(db_handle, sql_ptr, sql_len) -> i32    — execute SQL
///   db_close(db_handle) -> i32                     — close db
///   db_last_insert_rowid(db_handle) -> i64         — last INSERT rowid
///   db_changes(db_handle) -> i32                   — rows changed
///   result_buf_ptr() -> i32                        — exec result buffer ptr
///   result_buf_len() -> i32                        — exec result buffer length
const std = @import("std");
const testing = std.testing;

const wasmz = @import("wasmz");
const wasi_mod = @import("wasi");

const Engine = wasmz.Engine;
const Config = wasmz.Config;
const Store = wasmz.Store;
const Module = wasmz.Module;
const ArcModule = wasmz.ArcModule;
const Instance = wasmz.Instance;
const Linker = wasmz.Linker;
const RawVal = wasmz.RawVal;

const sqlite3_wasm = @embedFile("fixtures/sqlite_wasm/sqlite3.wasm");

const SQLITE_OK = 0;

// ── Helpers ────────────────────────────────────────────────────────────────────

/// Write `data` into wasm linear memory at `offset`.
fn writeWasmMem(instance: *Instance, offset: u32, data: []const u8) void {
    const mem = instance.memory.bytes();
    @memcpy(mem[offset .. offset + data.len], data);
}

/// Read a NUL-terminated string from wasm linear memory at `ptr`.
fn readWasmStr(instance: *Instance, ptr: u32) []const u8 {
    const mem = instance.memory.bytes();
    return std.mem.sliceTo(mem[ptr..], 0);
}

/// Read `n` bytes from wasm linear memory at `ptr`.
fn readWasmBytes(instance: *Instance, ptr: u32, len: u32) []const u8 {
    const mem = instance.memory.bytes();
    return mem[ptr .. ptr + len];
}

/// Call a wasm function that returns i32.
fn callI32(instance: *Instance, name: []const u8, args: []const RawVal) !i32 {
    const r = try instance.call(name, args);
    const val = r.ok orelse return error.MissingReturn;
    return val.readAs(i32);
}

/// Call a wasm function that returns i64.
fn callI64(instance: *Instance, name: []const u8, args: []const RawVal) !i64 {
    const r = try instance.call(name, args);
    const val = r.ok orelse return error.MissingReturn;
    return val.readAs(i64);
}

/// Call a wasm function that returns nothing (void/no return).
fn callVoid(instance: *Instance, name: []const u8, args: []const RawVal) !void {
    _ = try instance.call(name, args);
}

/// Allocate `size` bytes in wasm linear memory and return the guest pointer.
fn wasmAlloc(instance: *Instance, size: i32) !i32 {
    const ptr = try callI32(instance, "alloc", &.{RawVal.from(size)});
    if (ptr == 0) return error.WasmAllocFailed;
    return ptr;
}

/// Free wasm memory at `ptr` with `size`.
fn wasmDealloc(instance: *Instance, ptr: i32, size: i32) !void {
    try callVoid(instance, "dealloc", &.{ RawVal.from(ptr), RawVal.from(size) });
}

/// Write `str` into wasm memory and return (guest_ptr, len).
/// Caller must free with wasmDealloc(ptr, len).
fn writeStrToWasm(instance: *Instance, str: []const u8) !struct { ptr: i32, len: i32 } {
    const len: i32 = @intCast(str.len);
    const ptr = try wasmAlloc(instance, len);
    writeWasmMem(instance, @intCast(ptr), str);
    return .{ .ptr = ptr, .len = len };
}

/// Open an in-memory SQLite database. Returns a guest db handle (i32).
fn openMemoryDb(instance: *Instance) !i32 {
    const path = ":memory:";
    const path_buf = try writeStrToWasm(instance, path);
    defer wasmDealloc(instance, path_buf.ptr, path_buf.len) catch {};

    // Allocate space for the db handle output (i32 = 4 bytes)
    const db_out = try wasmAlloc(instance, 4);
    defer wasmDealloc(instance, db_out, 4) catch {};

    const rc = try callI32(instance, "db_open", &.{
        RawVal.from(path_buf.ptr),
        RawVal.from(path_buf.len),
        RawVal.from(db_out),
    });
    if (rc != SQLITE_OK) return error.SqliteOpenFailed;

    // Read back the db handle (i32) from wasm memory
    const mem = instance.memory.bytes();
    const db_handle = std.mem.readInt(i32, mem[@intCast(db_out)..][0..4], .little);
    return db_handle;
}

/// Execute SQL and return the result buffer contents (slice into wasm memory).
fn execSql(instance: *Instance, db_handle: i32, sql: []const u8) ![]const u8 {
    const sql_buf = try writeStrToWasm(instance, sql);
    defer wasmDealloc(instance, sql_buf.ptr, sql_buf.len) catch {};

    const rc = try callI32(instance, "db_exec", &.{
        RawVal.from(db_handle),
        RawVal.from(sql_buf.ptr),
        RawVal.from(sql_buf.len),
    });
    if (rc != SQLITE_OK) return error.SqliteExecFailed;

    const buf_ptr = try callI32(instance, "result_buf_ptr", &.{});
    const buf_len = try callI32(instance, "result_buf_len", &.{});

    if (buf_ptr == 0 or buf_len == 0) return "";
    return readWasmBytes(instance, @intCast(buf_ptr), @intCast(buf_len));
}

// ── Test setup helper ──────────────────────────────────────────────────────────

/// TestCtx is always heap-allocated so that Store and Instance never move.
/// Store.linkBudget() must be called after Store reaches its permanent address,
/// and Instance holds a raw *Store pointer — both require pointer stability.
const TestCtx = struct {
    engine: Engine,
    store: Store,
    arc: ArcModule,
    instance: Instance,
    linker: Linker,
    wasi_host: wasi_mod.preview1.Host,

    /// Allocate a TestCtx on the heap and fully initialize it.
    /// The caller owns the returned pointer and must call destroy() when done.
    fn create() !*TestCtx {
        const ctx = try testing.allocator.create(TestCtx);
        errdefer testing.allocator.destroy(ctx);

        ctx.engine = try Engine.init(testing.allocator, Config{});
        errdefer ctx.engine.deinit();

        ctx.wasi_host = wasi_mod.preview1.Host.init(testing.allocator);
        errdefer ctx.wasi_host.deinit();

        ctx.linker = Linker.empty;
        try ctx.wasi_host.addToLinker(&ctx.linker, testing.allocator);
        errdefer ctx.linker.deinit(testing.allocator);

        ctx.store = try Store.init(testing.allocator, ctx.engine);
        errdefer ctx.store.deinit();
        // Store is now at its permanent heap address — patch the GC budget pointer.
        ctx.store.linkBudget();

        ctx.arc = try Module.compileArc(ctx.engine, sqlite3_wasm);
        errdefer if (ctx.arc.releaseUnwrap()) |m| {
            var mm = m;
            mm.deinit();
        };

        ctx.instance = try Instance.init(&ctx.store, ctx.arc.retain(), ctx.linker);
        errdefer ctx.instance.deinit();

        // Run reactor _initialize
        const init_result = try ctx.instance.initializeReactor();
        if (init_result) |r| switch (r) {
            .ok => {},
            .trap => return error.InitTrap,
        };

        return ctx;
    }

    fn destroy(self: *TestCtx) void {
        self.instance.deinit();
        if (self.arc.releaseUnwrap()) |m| {
            var mm = m;
            mm.deinit();
        }
        self.store.deinit();
        self.engine.deinit();
        self.linker.deinit(testing.allocator);
        self.wasi_host.deinit();
        testing.allocator.destroy(self);
    }
};

// ── Test 1: Module loads and reactor initializes ───────────────────────────────

test "sqlite: module loads and _initialize succeeds" {
    const ctx = try TestCtx.create();
    defer ctx.destroy();

    // If we got here, _initialize ran successfully
    try testing.expect(ctx.instance.isReactor());
}

// ── Test 2: alloc / dealloc roundtrip ─────────────────────────────────────────

test "sqlite: alloc and dealloc roundtrip" {
    const ctx = try TestCtx.create();
    defer ctx.destroy();

    const ptr = try wasmAlloc(&ctx.instance, 64);
    try testing.expect(ptr != 0);

    // Write and read back a known pattern
    writeWasmMem(&ctx.instance, @intCast(ptr), "hello sqlite");
    const s = readWasmBytes(&ctx.instance, @intCast(ptr), 12);
    try testing.expectEqualSlices(u8, "hello sqlite", s);

    try wasmDealloc(&ctx.instance, ptr, 64);
}

// ── Test 3: open and close in-memory database ─────────────────────────────────

test "sqlite: open and close :memory: database" {
    const ctx = try TestCtx.create();
    defer ctx.destroy();

    const db = try openMemoryDb(&ctx.instance);
    try testing.expect(db != 0);

    const rc = try callI32(&ctx.instance, "db_close", &.{RawVal.from(db)});
    try testing.expectEqual(SQLITE_OK, rc);
}

// ── Test 4: CREATE TABLE succeeds ─────────────────────────────────────────────

test "sqlite: CREATE TABLE executes without error" {
    const ctx = try TestCtx.create();
    defer ctx.destroy();

    const db = try openMemoryDb(&ctx.instance);
    defer _ = callI32(&ctx.instance, "db_close", &.{RawVal.from(db)}) catch {};

    _ = try execSql(&ctx.instance, db, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, score REAL)");
}

// ── Test 5: INSERT and last_insert_rowid ──────────────────────────────────────

test "sqlite: INSERT and last_insert_rowid" {
    const ctx = try TestCtx.create();
    defer ctx.destroy();

    const db = try openMemoryDb(&ctx.instance);
    defer _ = callI32(&ctx.instance, "db_close", &.{RawVal.from(db)}) catch {};

    _ = try execSql(&ctx.instance, db, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, score REAL)");

    _ = try execSql(&ctx.instance, db, "INSERT INTO users (name, score) VALUES ('alice', 9.5)");

    const rowid = try callI64(&ctx.instance, "db_last_insert_rowid", &.{RawVal.from(db)});
    try testing.expectEqual(@as(i64, 1), rowid);
}

// ── Test 6: db_changes ────────────────────────────────────────────────────────

test "sqlite: db_changes returns correct count" {
    const ctx = try TestCtx.create();
    defer ctx.destroy();

    const db = try openMemoryDb(&ctx.instance);
    defer _ = callI32(&ctx.instance, "db_close", &.{RawVal.from(db)}) catch {};

    _ = try execSql(&ctx.instance, db, "CREATE TABLE t (x INTEGER)");
    _ = try execSql(&ctx.instance, db, "INSERT INTO t VALUES (1), (2), (3)");

    const changes = try callI32(&ctx.instance, "db_changes", &.{RawVal.from(db)});
    try testing.expectEqual(@as(i32, 3), changes);
}

// ── Test 7: SELECT returns rows ───────────────────────────────────────────────

test "sqlite: SELECT returns correct rows in result buffer" {
    const ctx = try TestCtx.create();
    defer ctx.destroy();

    const db = try openMemoryDb(&ctx.instance);
    defer _ = callI32(&ctx.instance, "db_close", &.{RawVal.from(db)}) catch {};

    _ = try execSql(&ctx.instance, db, "CREATE TABLE t (id INTEGER, val TEXT)");
    _ = try execSql(&ctx.instance, db, "INSERT INTO t VALUES (1, 'foo'), (2, 'bar'), (3, 'baz')");

    const result = try execSql(&ctx.instance, db, "SELECT id, val FROM t ORDER BY id");

    // Result format: "col1\tcol2\n" per row
    try testing.expectEqualSlices(u8, "1\tfoo\n2\tbar\n3\tbaz\n", result);
}

// ── Test 8: UPDATE ────────────────────────────────────────────────────────────

test "sqlite: UPDATE modifies rows correctly" {
    const ctx = try TestCtx.create();
    defer ctx.destroy();

    const db = try openMemoryDb(&ctx.instance);
    defer _ = callI32(&ctx.instance, "db_close", &.{RawVal.from(db)}) catch {};

    _ = try execSql(&ctx.instance, db, "CREATE TABLE t (x INTEGER)");
    _ = try execSql(&ctx.instance, db, "INSERT INTO t VALUES (10)");
    _ = try execSql(&ctx.instance, db, "UPDATE t SET x = 42 WHERE x = 10");

    const result = try execSql(&ctx.instance, db, "SELECT x FROM t");
    try testing.expectEqualSlices(u8, "42\n", result);
}

// ── Test 9: Multiple independent databases ────────────────────────────────────

test "sqlite: multiple independent :memory: databases" {
    const ctx = try TestCtx.create();
    defer ctx.destroy();

    const db1 = try openMemoryDb(&ctx.instance);
    const db2 = try openMemoryDb(&ctx.instance);
    defer _ = callI32(&ctx.instance, "db_close", &.{RawVal.from(db1)}) catch {};
    defer _ = callI32(&ctx.instance, "db_close", &.{RawVal.from(db2)}) catch {};

    _ = try execSql(&ctx.instance, db1, "CREATE TABLE t (v TEXT)");
    _ = try execSql(&ctx.instance, db2, "CREATE TABLE t (v TEXT)");
    _ = try execSql(&ctx.instance, db1, "INSERT INTO t VALUES ('from_db1')");
    _ = try execSql(&ctx.instance, db2, "INSERT INTO t VALUES ('from_db2')");

    // The result buffer is shared wasm memory — copy r1 before calling execSql again.
    const r1_raw = try execSql(&ctx.instance, db1, "SELECT v FROM t");
    const r1 = try testing.allocator.dupe(u8, r1_raw);
    defer testing.allocator.free(r1);

    const r2 = try execSql(&ctx.instance, db2, "SELECT v FROM t");

    try testing.expectEqualSlices(u8, "from_db1\n", r1);
    try testing.expectEqualSlices(u8, "from_db2\n", r2);
}

// ── Test 10: SQL aggregate function ───────────────────────────────────────────

test "sqlite: SQL aggregate SUM works" {
    const ctx = try TestCtx.create();
    defer ctx.destroy();

    const db = try openMemoryDb(&ctx.instance);
    defer _ = callI32(&ctx.instance, "db_close", &.{RawVal.from(db)}) catch {};

    _ = try execSql(&ctx.instance, db, "CREATE TABLE nums (n INTEGER)");
    _ = try execSql(&ctx.instance, db, "INSERT INTO nums VALUES (1),(2),(3),(4),(5)");

    const result = try execSql(&ctx.instance, db, "SELECT SUM(n) FROM nums");
    try testing.expectEqualSlices(u8, "15\n", result);
}

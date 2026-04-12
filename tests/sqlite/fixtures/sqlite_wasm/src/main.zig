// sqlite_wasm.zig — Zig wrapper that compiles sqlite3.c into wasm32-wasi
// and exports a minimal sqlite3 API callable by a WASM host.
//
// Exported functions (all use i32 for pointers since wasm is 32-bit):
//   _initialize()              — reactor init (no-op, but marks reactor model)
//   sqlite3_open(path_ptr, path_len, db_out_ptr) -> i32
//   sqlite3_close(db_ptr) -> i32
//   sqlite3_exec(db_ptr, sql_ptr, sql_len) -> i32
//   sqlite3_errmsg(db_ptr) -> i32  (returns pointer to null-terminated string)
//   sqlite3_last_insert_rowid(db_ptr) -> i64
//   sqlite3_changes(db_ptr) -> i32
//   alloc(size) -> i32   — allocate memory for host to write strings into
//   dealloc(ptr, size)   — free memory allocated by alloc
//   result_buf_ptr() -> i32   — pointer to exec result buffer
//   result_buf_len() -> i32   — length of exec result buffer

const std = @import("std");
const c = @cImport({
    @cDefine("SQLITE_OMIT_LOAD_EXTENSION", "1");
    @cDefine("SQLITE_THREADSAFE", "0");
    @cDefine("SQLITE_DEFAULT_MEMSTATUS", "0");
    @cDefine("SQLITE_OMIT_DECLTYPE", "1");
    @cDefine("SQLITE_OMIT_DEPRECATED", "1");
    @cInclude("sqlite3.h");
});

// Simple bump allocator backed by wasm memory — enough for our test wrapper
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

// Shared result buffer: sqlite3_exec stores rows here as length-prefixed text
// Format: each row is "col1\tcol2\t...\n"
var result_buf: std.ArrayListUnmanaged(u8) = .empty;

fn ensureResultBuf() void {
    // nothing to initialize — .empty is valid initial state
}

// Reactor _initialize — called by wasi-libc crt1-reactor.c automatically.
// We provide our own init logic via this exported function.
// Note: wasi reactor mode already provides _initialize via crt1-reactor.o,
// so we hook into it via a constructor attribute instead.
// Our exported init function for the host to call explicitly:
export fn sqlite_init() void {}

// alloc: let the host allocate memory in wasm linear memory
export fn alloc(size: i32) i32 {
    const mem = allocator.alloc(u8, @intCast(size)) catch return 0;
    return @intCast(@intFromPtr(mem.ptr));
}

// dealloc: free memory previously allocated with alloc
export fn dealloc(ptr: i32, size: i32) void {
    if (ptr == 0) return;
    const slice: []u8 = @as([*]u8, @ptrFromInt(@as(usize, @intCast(ptr))))[0..@intCast(size)];
    allocator.free(slice);
}

// result_buf_ptr / result_buf_len: access to the query result buffer
export fn result_buf_ptr() i32 {
    if (result_buf.items.len == 0) return 0;
    return @intCast(@intFromPtr(result_buf.items.ptr));
}

export fn result_buf_len() i32 {
    return @intCast(result_buf.items.len);
}

// sqlite3_open: open a database.
//   path_ptr: pointer to UTF-8 path string in wasm memory
//   path_len: length of the path string (NOT null-terminated required)
//   db_out_ptr: pointer to an i32 in wasm memory; written with the db handle
// Returns SQLITE_OK (0) on success.
export fn db_open(path_ptr: i32, path_len: i32, db_out_ptr: i32) i32 {
    // Build null-terminated path
    const path_slice: []const u8 = @as([*]const u8, @ptrFromInt(@as(usize, @intCast(path_ptr))))[0..@intCast(path_len)];
    const path_z = allocator.dupeZ(u8, path_slice) catch return c.SQLITE_NOMEM;
    defer allocator.free(path_z);

    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open(path_z.ptr, &db);

    // Write the db pointer (as i32) into wasm memory at db_out_ptr
    const out_ptr: *i32 = @ptrFromInt(@as(usize, @intCast(db_out_ptr)));
    out_ptr.* = if (db != null) @intCast(@intFromPtr(db.?)) else 0;

    return rc;
}

// sqlite3_close: close a database handle.
//   db_handle: value previously written by db_open (i32 representation of pointer)
export fn db_close(db_handle: i32) i32 {
    if (db_handle == 0) return c.SQLITE_OK;
    const db: *c.sqlite3 = @ptrFromInt(@as(usize, @intCast(db_handle)));
    return c.sqlite3_close(db);
}

// Callback for sqlite3_exec that appends rows to result_buf
fn execCallback(
    _: ?*anyopaque,
    argc: c_int,
    argv: [*c][*c]u8,
    _: [*c][*c]u8,
) callconv(.c) c_int {
    for (0..@intCast(argc)) |i| {
        if (i > 0) result_buf.append(allocator, '\t') catch return 1;
        const val = argv[i];
        if (val != null) {
            const s = std.mem.sliceTo(val, 0);
            result_buf.appendSlice(allocator, s) catch return 1;
        } else {
            result_buf.appendSlice(allocator, "NULL") catch return 1;
        }
    }
    result_buf.append(allocator, '\n') catch return 1;
    return 0;
}

// db_exec: execute SQL on an open database.
//   db_handle: value from db_open
//   sql_ptr: pointer to UTF-8 SQL string in wasm memory
//   sql_len: length of sql string
// Results are written to the result buffer (access via result_buf_ptr/len).
// Returns SQLITE_OK (0) on success.
export fn db_exec(db_handle: i32, sql_ptr: i32, sql_len: i32) i32 {
    result_buf.clearRetainingCapacity();

    if (db_handle == 0) return c.SQLITE_MISUSE;

    const db: *c.sqlite3 = @ptrFromInt(@as(usize, @intCast(db_handle)));
    const sql_slice: []const u8 = @as([*]const u8, @ptrFromInt(@as(usize, @intCast(sql_ptr))))[0..@intCast(sql_len)];
    const sql_z = allocator.dupeZ(u8, sql_slice) catch return c.SQLITE_NOMEM;
    defer allocator.free(sql_z);

    const rc = c.sqlite3_exec(db, sql_z.ptr, execCallback, null, null);
    return rc;
}

// db_errmsg: get the last error message for a db handle.
// Returns a pointer to a null-terminated string in wasm memory.
export fn db_errmsg(db_handle: i32) i32 {
    if (db_handle == 0) return 0;
    const db: *c.sqlite3 = @ptrFromInt(@as(usize, @intCast(db_handle)));
    const msg = c.sqlite3_errmsg(db);
    return @intCast(@intFromPtr(msg));
}

// db_last_insert_rowid: returns the rowid of the last INSERT.
export fn db_last_insert_rowid(db_handle: i32) i64 {
    if (db_handle == 0) return 0;
    const db: *c.sqlite3 = @ptrFromInt(@as(usize, @intCast(db_handle)));
    return c.sqlite3_last_insert_rowid(db);
}

// db_changes: returns number of rows changed by last DML.
export fn db_changes(db_handle: i32) i32 {
    if (db_handle == 0) return 0;
    const db: *c.sqlite3 = @ptrFromInt(@as(usize, @intCast(db_handle)));
    return c.sqlite3_changes(db);
}

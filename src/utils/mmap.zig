/// Cross-platform read-only file memory mapping.
///
/// - POSIX (macOS, Linux, *BSD …): `mmap(2)` / `munmap(2)`
/// - Windows: `NtCreateSection` / `NtMapViewOfSection` / `NtUnmapViewOfSection`
/// - WASI: plain heap read via `readAllAlloc` (no mmap on wasm)
///
/// The returned slice borrows directly from the OS page cache (or heap on WASI)
/// and must not be written to.  The mapping must be released with `unmap()`.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const page_align = std.heap.page_size_min;

const is_wasi = builtin.os.tag == .wasi;
const is_windows = builtin.os.tag == .windows;

pub const MappedFile = struct {
    /// The mapped read-only byte slice.
    data: []align(page_align) const u8,

    /// Section handle (Windows only).
    section_handle: if (is_windows) std.os.windows.HANDLE else void = if (is_windows) undefined else {},

    /// Owned heap buffer (WASI only); freed on unmap.
    wasi_buf: if (is_wasi) []align(page_align) u8 else void = if (is_wasi) undefined else {},
};

pub const MapError = error{
    EmptyFile,
    MapFailed,
};

/// Memory-map (or read) an open file for reading.
pub fn mapFile(file: std.Io.File, io: Io) MapError!MappedFile {
    const stat = file.stat(io) catch return error.MapFailed;
    if (stat.size == 0) return error.EmptyFile;

    if (comptime is_wasi) {
        return mapFileWasi(file, io, stat.size);
    } else if (comptime is_windows) {
        return mapFileWindows(file.handle, stat.size);
    } else {
        return mapFilePosix(file.handle, stat.size);
    }
}

/// Release a mapping.
pub fn unmap(m: MappedFile) void {
    if (comptime is_wasi) {
        unmapWasi(m);
    } else if (comptime is_windows) {
        unmapWindows(m);
    } else {
        std.posix.munmap(m.data);
    }
}

// WASI implementation — plain heap allocation + file read

fn mapFileWasi(file: std.Io.File, io: Io, size: u64) MapError!MappedFile {
    const len: usize = std.math.cast(usize, size) orelse return error.MapFailed;
    const allocator = std.heap.page_allocator;
    const buf = allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(page_align), len) catch return error.MapFailed;
    errdefer allocator.free(buf);
    _ = file.readStreaming(io, &.{buf}) catch |err| {
        allocator.free(buf);
        return if (err == error.EndOfStream) error.MapFailed else error.MapFailed;
    };
    return .{
        .data = buf,
        .wasi_buf = buf,
    };
}

fn unmapWasi(m: MappedFile) void {
    std.heap.page_allocator.free(m.wasi_buf);
}

// POSIX implementation

fn mapFilePosix(fd: std.posix.fd_t, size: u64) MapError!MappedFile {
    const len: usize = std.math.cast(usize, size) orelse return error.MapFailed;
    const mapped = std.posix.mmap(
        null,
        len,
        std.posix.PROT{ .READ = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    ) catch return error.MapFailed;
    return .{ .data = mapped };
}

// Windows implementation

fn mapFileWindows(handle: std.os.windows.HANDLE, size: u64) MapError!MappedFile {
    const windows = std.os.windows;
    const ntdll = windows.ntdll;

    var section_handle: windows.HANDLE = undefined;
    const create_rc = ntdll.NtCreateSection(
        &section_handle,
        .{
            .SPECIFIC = .{ .SECTION = .{
                .QUERY = true,
                .MAP_READ = true,
            } },
            .STANDARD = .{ .RIGHTS = .REQUIRED },
        },
        null,
        null,
        .{ .READONLY = true },
        .{ .COMMIT = true },
        handle,
    );
    if (create_rc != .SUCCESS) return error.MapFailed;
    errdefer windows.CloseHandle(section_handle);

    var base_addr: usize = 0;
    var view_size: usize = 0;
    const map_rc = ntdll.NtMapViewOfSection(
        section_handle,
        windows.current_process,
        @ptrCast(&base_addr),
        null,
        0,
        null,
        &view_size,
        .Unmap,
        .{},
        .{ .READONLY = true },
    );
    if (map_rc != .SUCCESS) return error.MapFailed;

    const len: usize = std.math.cast(usize, size) orelse {
        unmapViewRaw(base_addr);
        return error.MapFailed;
    };

    const ptr: [*]align(page_align) const u8 = @ptrFromInt(base_addr);
    return .{
        .data = ptr[0..len],
        .section_handle = section_handle,
    };
}

fn unmapWindows(m: MappedFile) void {
    const windows = std.os.windows;
    unmapViewRaw(@intFromPtr(m.data.ptr));
    windows.CloseHandle(m.section_handle);
}

fn unmapViewRaw(base_addr: usize) void {
    const windows = std.os.windows;
    _ = windows.ntdll.NtUnmapViewOfSection(
        windows.current_process,
        @ptrFromInt(base_addr),
    );
}

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

const page_align = std.heap.page_size_min;

const is_windows = builtin.os.tag == .windows;

pub const MappedFile = struct {
    /// The mapped read-only byte slice.
    data: []align(page_align) const u8,

    /// Section handle (Windows only).
    section_handle: if (is_windows) std.os.windows.HANDLE else void = if (is_windows) undefined else {},

    /// Owned heap buffer (WASI only); freed on unmap.
    wasi_buf: if (builtin.os.tag == .wasi) []align(page_align) u8 else void = if (builtin.os.tag == .wasi) undefined else {},
};

pub const MapError = error{
    EmptyFile,
    MapFailed,
};

/// Memory-map (or read) an open file for reading.
pub fn mapFile(fd: std.c.fd_t, file_size: u64) MapError!MappedFile {
    if (file_size == 0) return error.EmptyFile;

    if (comptime is_windows) {
        const handle = @as(std.os.windows.HANDLE, @ptrFromInt(@as(usize, @intCast(fd))));
        return mapFileWindows(handle, file_size);
    } else {
        return mapFilePosix(fd, file_size);
    }
}

/// Release a mapping.
pub fn unmap(m: MappedFile) void {
    if (comptime builtin.os.tag == .wasi) {
        const buf: []align(page_align) u8 = @alignCast(@constCast(m.data));
        std.heap.c_allocator.free(buf);
    } else if (comptime is_windows) {
        unmapWindows(m);
    } else {
        std.posix.munmap(m.data);
    }
}

// POSIX implementation

fn mapFilePosix(fd: std.posix.fd_t, size: u64) MapError!MappedFile {
    const len: usize = std.math.cast(usize, size) orelse return error.MapFailed;
    const mapped = std.posix.mmap(
        null,
        len,
        @as(std.posix.PROT, .{ .READ = true }),
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
        windows.STANDARD_RIGHTS_REQUIRED | windows.SECTION_QUERY | windows.SECTION_MAP_READ,
        null,
        null,
        windows.PAGE_READONLY,
        windows.SEC_COMMIT,
        handle,
    );
    if (create_rc != .SUCCESS) return error.MapFailed;
    errdefer windows.CloseHandle(section_handle);

    var base_addr: usize = 0;
    var view_size: usize = 0;
    const map_rc = ntdll.NtMapViewOfSection(
        section_handle,
        windows.self_process_handle,
        @ptrCast(&base_addr),
        null,
        0,
        null,
        &view_size,
        .ViewUnmap,
        0,
        windows.PAGE_READONLY,
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
        windows.self_process_handle,
        @ptrFromInt(base_addr),
    );
}

/// Cross-platform read-only file memory mapping.
///
/// - POSIX (macOS, Linux, *BSD …): `mmap(2)` / `munmap(2)`
/// - Windows: `NtCreateSection` / `NtMapViewOfSection` / `NtUnmapViewOfSection`
///
/// The returned slice borrows directly from the OS page cache so the data
/// must not be written to.  The mapping must be released with `unmap()`.
const std = @import("std");
const builtin = @import("builtin");

const page_align = std.heap.page_size_min;

pub const MappedFile = struct {
    /// The mapped read-only byte slice.
    data: []align(page_align) const u8,

    // ── Windows-only bookkeeping ─────────────────────────────────────────────
    /// Section handle that must be closed after unmapping (Windows only).
    section_handle: if (is_windows) std.os.windows.HANDLE else void =
        if (is_windows) undefined else {},

    const is_windows = builtin.os.tag == .windows;
};

pub const MapError = error{
    /// The file is empty (0 bytes); nothing to map.
    EmptyFile,
    /// OS refused the mapping (permissions, resource limits, …).
    MapFailed,
};

/// Memory-map an open file for reading.
///
/// The caller must eventually call `unmap()` on the returned `MappedFile`.
/// The underlying `file` can be closed immediately after this returns —
/// the mapping keeps its own reference.
pub fn mapFile(file: std.fs.File) MapError!MappedFile {
    const stat = file.stat() catch return error.MapFailed;
    if (stat.size == 0) return error.EmptyFile;

    if (comptime builtin.os.tag == .windows) {
        return mapFileWindows(file.handle, stat.size);
    } else {
        return mapFilePosix(file.handle, stat.size);
    }
}

/// Release a mapping previously obtained from `mapFile()`.
pub fn unmap(m: MappedFile) void {
    if (comptime builtin.os.tag == .windows) {
        unmapWindows(m);
    } else {
        std.posix.munmap(m.data);
    }
}

// ── POSIX implementation ─────────────────────────────────────────────────────

fn mapFilePosix(fd: std.posix.fd_t, size: u64) MapError!MappedFile {
    const len: usize = std.math.cast(usize, size) orelse return error.MapFailed;
    const mapped = std.posix.mmap(
        null,
        len,
        std.posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    ) catch return error.MapFailed;
    return .{ .data = mapped };
}

// ── Windows implementation ───────────────────────────────────────────────────

fn mapFileWindows(handle: std.os.windows.HANDLE, size: u64) MapError!MappedFile {
    const windows = std.os.windows;
    const ntdll = windows.ntdll;

    // 1. Create a read-only section backed by the file.
    var section_handle: windows.HANDLE = undefined;
    const create_rc = ntdll.NtCreateSection(
        &section_handle,
        windows.STANDARD_RIGHTS_REQUIRED | windows.SECTION_QUERY | windows.SECTION_MAP_READ,
        null, // ObjectAttributes
        null, // MaximumSize — use file size
        windows.PAGE_READONLY,
        windows.SEC_COMMIT,
        handle,
    );
    if (create_rc != .SUCCESS) return error.MapFailed;
    errdefer windows.CloseHandle(section_handle);

    // 2. Map the section into our address space.
    var base_addr: usize = 0;
    var view_size: usize = 0; // 0 → map entire section
    const map_rc = ntdll.NtMapViewOfSection(
        section_handle,
        windows.self_process_handle,
        @ptrCast(&base_addr),
        null, // ZeroBits
        0, // CommitSize
        null, // SectionOffset
        &view_size,
        .ViewUnmap,
        0, // AllocationType
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

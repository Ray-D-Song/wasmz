/// Cross-platform RSS (Resident Set Size) reading.
///
/// - macOS : mach_task_info(MACH_TASK_BASIC_INFO)
/// - Linux : /proc/self/statm
/// - Windows: K32GetProcessMemoryInfo (kernel32)
///
/// Returns bytes, or 0 when the platform is unsupported / on error.
const std = @import("std");
const builtin = @import("builtin");

// ── public API ────────────────────────────────────────────────────────────────

/// Returns the current RSS of this process in bytes, or 0 on error.
pub fn currentRssBytes() usize {
    return switch (builtin.os.tag) {
        .macos => currentRssMacOS(),
        .linux => currentRssLinux(),
        .windows => currentRssWindows(),
        else => 0,
    };
}

// ── macOS implementation ─────────────────────────────────────────────────────

const MachTaskBasicInfo = extern struct {
    virtual_size: u64,
    resident_size: u64,
    resident_size_max: u64,
    user_time: TimeValue,
    system_time: TimeValue,
    policy: i32,
    suspend_count: i32,
};

const TimeValue = extern struct {
    seconds: i32,
    microseconds: i32,
};

extern "c" fn mach_task_self() std.c.mach_port_t;
extern "c" fn task_info(
    target_task: std.c.mach_port_t,
    flavor: u32,
    task_info_out: *anyopaque,
    task_info_outCnt: *u32,
) i32;

const MACH_TASK_BASIC_INFO: u32 = 20;
const MACH_TASK_BASIC_INFO_COUNT: u32 = @sizeOf(MachTaskBasicInfo) / @sizeOf(u32);

fn currentRssMacOS() usize {
    var info: MachTaskBasicInfo = undefined;
    var count: u32 = MACH_TASK_BASIC_INFO_COUNT;
    const kr = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, &info, &count);
    if (kr != 0) return 0;
    return @intCast(info.resident_size);
}

// ── Linux implementation ─────────────────────────────────────────────────────

fn currentRssLinux() usize {
    // /proc/self/statm fields: size resident shared text lib data dt  (in pages)
    var buf: [256]u8 = undefined;
    const fd = std.posix.open("/proc/self/statm", .{}, 0) catch return 0;
    defer std.posix.close(fd);
    const n = std.posix.read(fd, &buf) catch return 0;
    if (n == 0) return 0;
    const line = buf[0..n];

    // Skip first field (size), parse second field (resident).
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next(); // skip "size"
    const rss_pages_str = it.next() orelse return 0;
    const rss_pages = std.fmt.parseInt(usize, rss_pages_str, 10) catch return 0;
    return rss_pages * std.mem.page_size;
}

// ── Windows implementation ───────────────────────────────────────────────────

fn currentRssWindows() usize {
    if (comptime builtin.os.tag != .windows) return 0;
    const windows = std.os.windows;

    const PROCESS_MEMORY_COUNTERS = extern struct {
        cb: u32,
        PageFaultCount: u32,
        PeakWorkingSetSize: usize,
        WorkingSetSize: usize,
        QuotaPeakPagedPoolUsage: usize,
        QuotaPagedPoolUsage: usize,
        QuotaPeakNonPagedPoolUsage: usize,
        QuotaNonPagedPoolUsage: usize,
        PagefileUsage: usize,
        PeakPagefileUsage: usize,
    };

    const k32 = struct {
        extern "kernel32" fn K32GetProcessMemoryInfo(
            hProcess: windows.HANDLE,
            ppsmemCounters: *PROCESS_MEMORY_COUNTERS,
            cb: u32,
        ) callconv(.winapi) std.os.windows.BOOL;
    };

    var counters: PROCESS_MEMORY_COUNTERS = undefined;
    counters.cb = @sizeOf(PROCESS_MEMORY_COUNTERS);
    const ok = k32.K32GetProcessMemoryInfo(
        windows.self_process_handle,
        &counters,
        @sizeOf(PROCESS_MEMORY_COUNTERS),
    );
    if (ok == 0) return 0;
    return counters.WorkingSetSize;
}

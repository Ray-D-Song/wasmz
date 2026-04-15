/// common.zig — shared helpers for threaded-dispatch handlers
///
/// Each public `handle_*` function is an instruction handler with the
/// unified Handler signature.  At the end of every non-terminating handler
/// the `dispatch.next()` helper reads the handler pointer embedded at the
/// next instruction and tail-calls it.
const std = @import("std");
const builtin = @import("builtin");
const ir = @import("../../compiler/ir.zig");
const encode = @import("../../compiler/encode.zig");
const dispatch = @import("../dispatch.zig");
const gc_mod = @import("../gc/root.zig");
const core = @import("core");
const store_mod = @import("../../wasmz/store.zig");
const host_mod = @import("../../wasmz/host.zig");
const module_mod = @import("../../wasmz/module.zig");

const Allocator = std.mem.Allocator;
const RawVal = dispatch.RawVal;
const ExecResult = dispatch.ExecResult;
const Trap = dispatch.Trap;
const Global = dispatch.Global;
const Handler = dispatch.Handler;
const DispatchState = dispatch.DispatchState;
const ExecEnv = dispatch.ExecEnv;
const CallFrame = dispatch.CallFrame;
const EhFrame = dispatch.EhFrame;
const EncodedFunction = ir.EncodedFunction;
const CatchHandlerEntry = ir.CatchHandlerEntry;
const CatchHandlerKind = ir.CatchHandlerKind;
const Slot = ir.Slot;
const Store = store_mod.Store;
const GcHeap = gc_mod.GcHeap;
const GcHeader = gc_mod.GcHeader;
const GcRef = core.GcRef;
const GcRefKind = core.GcRefKind;
const StructLayout = gc_mod.StructLayout;
const ArrayLayout = gc_mod.ArrayLayout;
const storageTypeSize = gc_mod.storageTypeSize;
const Memory = core.Memory;
const HostFunc = host_mod.HostFunc;
const HostContext = host_mod.HostContext;
const HostInstance = host_mod.HostInstance;
const CompositeType = core.CompositeType;
const heap_type = core.heap_type;
const gcRefKindFromHeapType = heap_type.gcRefKindFromHeapType;
const helper = core.helper;
const simd = core.simd;

const HANDLER_SIZE = dispatch.HANDLER_SIZE;

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Read the operand struct for an instruction.
/// `ip` points to the start of the instruction (the 8-byte handler pointer).
/// The operands begin at ip + HANDLER_SIZE.
/// Uses bytesAsValue to safely handle unaligned access.
pub inline fn readOps(comptime T: type, ip: [*]u8) T {
    if (@sizeOf(T) == 0) return .{};
    const bytes = ip[HANDLER_SIZE..][0..@sizeOf(T)];
    return std.mem.bytesAsValue(T, bytes).*;
}

/// Instruction stride: handler pointer + operand bytes (no alignment padding).
pub inline fn stride(comptime OpsT: type) usize {
    return HANDLER_SIZE + @sizeOf(OpsT);
}

// ── Inline cross-platform RSS reading ────────────────────────────────────────
// Duplicated/inlined here to avoid cross-module import issues (handlers.zig
// is inside the wasmz module which cannot import main's utils).

/// Returns the current RSS in bytes, or 0 on unsupported platforms / error.
pub fn currentRssBytes() usize {
    return switch (builtin.os.tag) {
        .macos => currentRssMacOS(),
        .linux => currentRssLinux(),
        .windows => currentRssWindows(),
        else => 0,
    };
}

fn currentRssMacOS() usize {
    const MachTaskBasicInfo = extern struct {
        virtual_size: u64,
        resident_size: u64,
        resident_size_max: u64,
        user_time: extern struct { seconds: i32, microseconds: i32 },
        system_time: extern struct { seconds: i32, microseconds: i32 },
        policy: i32,
        suspend_count: i32,
    };
    const mach_task_self = struct {
        extern "c" fn mach_task_self() std.c.mach_port_t;
    }.mach_task_self;
    const task_info_fn = struct {
        extern "c" fn task_info(std.c.mach_port_t, u32, *anyopaque, *u32) i32;
    }.task_info;
    var info: MachTaskBasicInfo = undefined;
    var count: u32 = @sizeOf(MachTaskBasicInfo) / @sizeOf(u32);
    if (task_info_fn(mach_task_self(), 20, &info, &count) != 0) return 0;
    return @intCast(info.resident_size);
}

fn currentRssLinux() usize {
    var buf: [256]u8 = undefined;
    const fd = std.posix.open("/proc/self/statm", .{}, 0) catch return 0;
    defer std.posix.close(fd);
    const n = std.posix.read(fd, &buf) catch return 0;
    if (n == 0) return 0;
    var it = std.mem.tokenizeScalar(u8, buf[0..n], ' ');
    _ = it.next(); // skip "size"
    const rss_str = it.next() orelse return 0;
    const rss_pages = std.fmt.parseInt(usize, rss_str, 10) catch return 0;
    return rss_pages * std.mem.page_size;
}

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
            windows.HANDLE,
            *PROCESS_MEMORY_COUNTERS,
            u32,
        ) callconv(.winapi) windows.BOOL;
    };
    var counters: PROCESS_MEMORY_COUNTERS = undefined;
    counters.cb = @sizeOf(PROCESS_MEMORY_COUNTERS);
    if (k32.K32GetProcessMemoryInfo(
        windows.self_process_handle,
        &counters,
        @sizeOf(PROCESS_MEMORY_COUNTERS),
    ) == 0) return 0;
    return counters.WorkingSetSize;
}

/// Compute effective address with bounds check.
/// Returns null if out-of-bounds.
pub inline fn effectiveAddr(slots: [*]RawVal, addr_slot: Slot, offset: u32, size: usize, mem: []const u8) ?u32 {
    const base = slots[addr_slot].readAs(u32);
    const ea = base +% offset;
    if (@as(usize, ea) + size > mem.len) return null;
    return ea;
}

pub inline fn trapReturn(frame: *DispatchState, code: core.TrapCode) void {
    var trap = Trap.fromTrapCode(code);
    if (frame.captureStackTrace()) |trace| {
        trap.allocator = frame.allocator;
        trap.stack_trace = trace;
    }
    frame.result = .{ .trap = trap };
}

pub inline fn UnsignedOf(comptime T: type) type {
    return std.meta.Int(.unsigned, @bitSizeOf(T));
}

pub inline fn trapFromTruncateError(err: helper.TruncateError) Trap {
    return Trap.fromTrapCode(switch (err) {
        error.NaN => .BadConversionToInteger,
        error.OutOfRange => .IntegerOverflow,
    });
}

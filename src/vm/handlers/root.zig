/// handlers.zig — M3 threaded-dispatch instruction handlers
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
const vm_root = @import("../root.zig");
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
inline fn readOps(comptime T: type, ip: [*]u8) T {
    if (@sizeOf(T) == 0) return .{};
    const bytes = ip[HANDLER_SIZE..][0..@sizeOf(T)];
    return std.mem.bytesAsValue(T, bytes).*;
}

/// Instruction stride: handler pointer + operand bytes (no alignment padding).
inline fn stride(comptime OpsT: type) usize {
    return HANDLER_SIZE + @sizeOf(OpsT);
}

// ── Inline cross-platform RSS reading ────────────────────────────────────────
// Duplicated/inlined here to avoid cross-module import issues (handlers.zig
// is inside the wasmz module which cannot import main's utils).

/// Returns the current RSS in bytes, or 0 on unsupported platforms / error.
fn currentRssBytes() usize {
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
inline fn effectiveAddr(slots: [*]RawVal, addr_slot: Slot, offset: u32, size: usize, mem: []const u8) ?u32 {
    const base = slots[addr_slot].readAs(u32);
    const ea = base +% offset;
    if (@as(usize, ea) + size > mem.len) return null;
    return ea;
}

inline fn trapReturn(frame: *DispatchState, code: core.TrapCode) void {
    var trap = Trap.fromTrapCode(code);
    if (frame.captureStackTrace()) |trace| {
        trap.allocator = frame.allocator;
        trap.stack_trace = trace;
    }
    frame.result = .{ .trap = trap };
}

inline fn UnsignedOf(comptime T: type) type {
    return std.meta.Int(.unsigned, @bitSizeOf(T));
}

inline fn trapReturnTruncate(frame: *DispatchState, err: helper.TruncateError) void {
    trapReturn(frame, switch (err) {
        error.NaN => .BadConversionToInteger,
        error.OutOfRange => .IntegerOverflow,
    });
}

// ── Terminators ──────────────────────────────────────────────────────────────

pub fn handle_unreachable(
    ip: [*]u8,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
    r0: u64,
    fp0: f64,
) callconv(.c) void {
    dispatch.countOp("trap_unreachable");

    _ = ip;
    _ = slots;
    _ = env;
    _ = r0;
    _ = fp0;
    trapReturn(frame, .UnreachableCodeReached);
}

pub fn handle_ret(
    ip: [*]u8,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
    r0: u64,
    fp0: f64,
) callconv(.c) void {
    dispatch.countOp("call_ret");

    _ = r0;
    _ = fp0;
    const ops = readOps(encode.OpsRet, ip);
    const ret_val: ?RawVal = if (ops.has_value != 0) slots[ops.value] else null;

    // Pop current frame and release its slots back to the value stack.
    const popped = frame.callStackPop();
    frame.valStackFree(popped.slots_sp_base);

    if (frame.call_depth == 0) {
        // Top-level return: write result and return (terminates dispatch chain).
        frame.result = .{ .ok = ret_val };
        return;
    }

    // Return to caller: write return value into caller's dst slot.
    const caller_idx = frame.call_depth - 1;
    if (popped.dst) |dst_slot| {
        if (ret_val) |rv| {
            frame.callStackAt(caller_idx).slots[dst_slot] = rv;
        }
    }

    // Resume caller.
    const caller = frame.callStackAt(caller_idx);
    dispatch.dispatch(caller.ip, caller.slots.ptr, frame, env, 0, 0.0);
}

// ── Fused binop+ret handlers (Peephole I) ────────────────────────────────────
// Compute result and return immediately, saving one dispatch event per call.

inline fn doRetWithVal(
    frame: *DispatchState,
    env: *const ExecEnv,
    ret_val: RawVal,
) void {
    const popped = frame.callStackPop();
    frame.valStackFree(popped.slots_sp_base);
    if (frame.call_depth == 0) {
        frame.result = .{ .ok = ret_val };
        return;
    }
    const caller_idx = frame.call_depth - 1;
    if (popped.dst) |dst_slot| {
        frame.callStackAt(caller_idx).slots[dst_slot] = ret_val;
    }
    const caller = frame.callStackAt(caller_idx);
    dispatch.dispatch(caller.ip, caller.slots.ptr, frame, env, 0, 0.0);
}

pub fn handle_i32_add_ret(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    _ = fp0;
    const ops = readOps(encode.OpsLhsRhs, ip);
    const result = slots[ops.lhs].readAs(i32) +% slots[ops.rhs].readAs(i32);
    doRetWithVal(frame, env, RawVal.from(result));
}

pub fn handle_i32_sub_ret(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    _ = fp0;
    const ops = readOps(encode.OpsLhsRhs, ip);
    const result = slots[ops.lhs].readAs(i32) -% slots[ops.rhs].readAs(i32);
    doRetWithVal(frame, env, RawVal.from(result));
}

pub fn handle_i64_add_ret(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    _ = fp0;
    const ops = readOps(encode.OpsLhsRhs, ip);
    const result = slots[ops.lhs].readAs(i64) +% slots[ops.rhs].readAs(i64);
    doRetWithVal(frame, env, RawVal.from(result));
}

pub fn handle_i64_sub_ret(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    _ = fp0;
    const ops = readOps(encode.OpsLhsRhs, ip);
    const result = slots[ops.lhs].readAs(i64) -% slots[ops.rhs].readAs(i64);
    doRetWithVal(frame, env, RawVal.from(result));
}
// ── Constants ────────────────────────────────────────────────────────────────

pub fn handle_const_i32(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("constant");

    _ = r0;
    const ops = readOps(encode.OpsConstI32, ip);
    slots[ops.dst] = RawVal.from(ops.value);
    dispatch.next(ip, stride(encode.OpsConstI32), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(ops.value)))), fp0);
}

pub fn handle_const_i64(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("constant");

    _ = r0;
    const ops = readOps(encode.OpsConstI64, ip);
    slots[ops.dst] = RawVal.from(ops.value);
    dispatch.next(ip, stride(encode.OpsConstI64), slots, frame, env, @as(u64, @bitCast(ops.value)), fp0);
}

pub fn handle_const_f32(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("constant");

    _ = fp0;
    const ops = readOps(encode.OpsConstF32, ip);
    slots[ops.dst] = RawVal.from(ops.value);
    dispatch.next(ip, stride(encode.OpsConstF32), slots, frame, env, r0, @as(f64, @floatCast(ops.value)));
}

pub fn handle_const_f64(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("constant");

    _ = fp0;
    const ops = readOps(encode.OpsConstF64, ip);
    slots[ops.dst] = RawVal.from(ops.value);
    dispatch.next(ip, stride(encode.OpsConstF64), slots, frame, env, r0, ops.value);
}

pub fn handle_const_v128(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("simd");

    const ops = readOps(encode.OpsConstV128, ip);
    const sv = core.SimdVal.fromV128(.{ .bytes = ops.value });
    sv.toSlots(&slots[ops.dst], &slots[ops.dst + 1]);
    dispatch.next(ip, stride(encode.OpsConstV128), slots, frame, env, r0, fp0);
}

pub fn handle_const_ref_null(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("ref_select");

    const ops = readOps(encode.OpsDst, ip);
    slots[ops.dst] = RawVal.fromBits64(0);
    dispatch.next(ip, stride(encode.OpsDst), slots, frame, env, r0, fp0);
}

// ── References ───────────────────────────────────────────────────────────────

pub fn handle_ref_is_null(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("ref_select");

    _ = r0;
    const ops = readOps(encode.OpsDstSrc, ip);
    const is_null: i32 = if (slots[ops.src].readAs(u64) == 0) 1 else 0;
    slots[ops.dst] = RawVal.from(is_null);
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(is_null)))), fp0);
}

pub fn handle_ref_func(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("ref_select");

    _ = r0;
    const ops = readOps(encode.OpsRefFunc, ip);
    slots[ops.dst] = RawVal.fromBits64(@as(u64, ops.func_idx) + 1);
    dispatch.next(ip, stride(encode.OpsRefFunc), slots, frame, env, @as(u64, ops.func_idx) + 1, fp0);
}

pub fn handle_ref_eq(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("ref_select");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const eq: i32 = if (slots[ops.lhs].readAs(u64) == slots[ops.rhs].readAs(u64)) 1 else 0;
    slots[ops.dst] = RawVal.from(eq);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(eq)))), fp0);
}

// ── Variables ────────────────────────────────────────────────────────────────

pub fn handle_local_get(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("local_get");

    const ops = readOps(encode.OpsLocalGet, ip);
    slots[ops.dst] = slots[ops.local];
    dispatch.next(ip, stride(encode.OpsLocalGet), slots, frame, env, r0, fp0);
}

pub fn handle_local_set(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("local_set");

    const ops = readOps(encode.OpsLocalSet, ip);
    slots[ops.local] = slots[ops.src];
    dispatch.next(ip, stride(encode.OpsLocalSet), slots, frame, env, r0, fp0);
}

pub fn handle_global_get(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("global");

    const ops = readOps(encode.OpsGlobalGet, ip);
    slots[ops.dst] = env.globals[ops.global_idx].getRawValue();
    dispatch.next(ip, stride(encode.OpsGlobalGet), slots, frame, env, r0, fp0);
}

pub fn handle_global_set(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("global");

    const ops = readOps(encode.OpsGlobalSet, ip);
    env.globals[ops.global_idx].value = slots[ops.src];
    dispatch.next(ip, stride(encode.OpsGlobalSet), slots, frame, env, r0, fp0);
}

pub fn handle_copy(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("copy");

    const ops = readOps(encode.OpsCopy, ip);
    slots[ops.dst] = slots[ops.src];
    dispatch.next(ip, stride(encode.OpsCopy), slots, frame, env, r0, fp0);
}

/// Peephole K: fused copy + conditional branch (wasm3 PreserveSetSlot equivalent).
/// slots[dst] = slots[src]; if slots[cond] != 0 then jump to target, else fall through.
/// Replaces the two-instruction sequence: `copy { dst, src }` + `jump_if_nz { cond, target }`.
pub fn handle_copy_jump_if_nz(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("copy_jump_if_nz");

    const ops = readOps(encode.OpsCopyJumpIfNz, ip);
    slots[ops.dst] = slots[ops.src];
    if (slots[ops.cond].readAs(i32) != 0) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsCopyJumpIfNz), slots, frame, env, r0, fp0);
    }
}

// ── Control flow ─────────────────────────────────────────────────────────────

pub fn handle_jump(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    const ops = readOps(encode.OpsJump, ip);
    // rel_target is a signed byte offset from instruction start
    const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
    dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
}

pub fn handle_jump_if_z(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    const ops = readOps(encode.OpsJumpIfZ, ip);
    if (slots[ops.cond].readAs(i32) == 0) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsJumpIfZ), slots, frame, env, r0, fp0);
    }
}

/// Peephole J: jump when cond != 0 (i.e. when br_if condition is true).
pub fn handle_jump_if_nz(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    const ops = readOps(encode.OpsJumpIfZ, ip);
    if (slots[ops.cond].readAs(i32) != 0) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsJumpIfZ), slots, frame, env, r0, fp0);
    }
}

pub fn handle_jump_table(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    const ops = readOps(encode.OpsJumpTable, ip);
    const idx = slots[ops.index].readAs(u32);
    const entry = if (idx < ops.targets_len) idx else ops.targets_len;
    const func = frame.callStackTop().func;
    const target = func.br_table_targets[ops.targets_start + entry];
    const target_ip: [*]u8 = func.code.ptr + target;
    dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
}

pub fn handle_select(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("ref_select");

    const ops = readOps(encode.OpsSelect, ip);
    const cond = slots[ops.cond].readAs(i32);
    slots[ops.dst] = if (cond != 0) slots[ops.val1] else slots[ops.val2];
    dispatch.next(ip, stride(encode.OpsSelect), slots, frame, env, r0, fp0);
}

// ── i32 binary arithmetic ────────────────────────────────────────────────────

fn binOpI32(comptime op: enum { add, sub, mul }, slots: [*]RawVal, ops: encode.OpsDstLhsRhs) i32 {
    const lhs = slots[ops.lhs].readAs(i32);
    const rhs = slots[ops.rhs].readAs(i32);
    const result: i32 = switch (op) {
        .add => lhs +% rhs,
        .sub => lhs -% rhs,
        .mul => lhs *% rhs,
    };
    slots[ops.dst] = RawVal.from(result);
    return result;
}

pub fn handle_i32_add(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = binOpI32(.add, slots, ops);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}
pub fn handle_i32_sub(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = binOpI32(.sub, slots, ops);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}
pub fn handle_i32_mul(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = binOpI32(.mul, slots, ops);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}

pub fn handle_i32_div_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.divS(slots[ops.lhs].readAs(i32), slots[ops.rhs].readAs(i32)) catch |e| {
        trapReturn(frame, switch (e) {
            error.IntegerDivisionByZero => .IntegerDivisionByZero,
            error.IntegerOverflow => .IntegerOverflow,
        });
        return;
    };
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}

pub fn handle_i32_div_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.divU(i32, slots[ops.lhs].readAs(u32), slots[ops.rhs].readAs(u32)) catch {
        trapReturn(frame, .IntegerDivisionByZero);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i32, @bitCast(result)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @intCast(result)), fp0);
}

pub fn handle_i32_rem_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.remS(slots[ops.lhs].readAs(i32), slots[ops.rhs].readAs(i32)) catch {
        trapReturn(frame, .IntegerDivisionByZero);
        return;
    };
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}

pub fn handle_i32_rem_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.remU(i32, slots[ops.lhs].readAs(u32), slots[ops.rhs].readAs(u32)) catch {
        trapReturn(frame, .IntegerDivisionByZero);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i32, @bitCast(result)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @intCast(result)), fp0);
}

pub fn handle_i32_and(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = slots[ops.lhs].readAs(i32) & slots[ops.rhs].readAs(i32);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}
pub fn handle_i32_or(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = slots[ops.lhs].readAs(i32) | slots[ops.rhs].readAs(i32);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}
pub fn handle_i32_xor(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = slots[ops.lhs].readAs(i32) ^ slots[ops.rhs].readAs(i32);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}
pub fn handle_i32_shl(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.shl(slots[ops.lhs].readAs(i32), slots[ops.rhs].readAs(i32));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}
pub fn handle_i32_shr_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.shrS(slots[ops.lhs].readAs(i32), slots[ops.rhs].readAs(i32));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}
pub fn handle_i32_shr_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: i32 = @bitCast(helper.shrU(i32, slots[ops.lhs].readAs(u32), slots[ops.rhs].readAs(u32)));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}
pub fn handle_i32_rotl(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.rotl(slots[ops.lhs].readAs(i32), slots[ops.rhs].readAs(i32));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}
pub fn handle_i32_rotr(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.rotr(slots[ops.lhs].readAs(i32), slots[ops.rhs].readAs(i32));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}

// ── i64 binary arithmetic ────────────────────────────────────────────────────

pub fn handle_i64_add(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: i64 = slots[ops.lhs].readAs(i64) +% slots[ops.rhs].readAs(i64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_sub(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: i64 = slots[ops.lhs].readAs(i64) -% slots[ops.rhs].readAs(i64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_mul(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: i64 = slots[ops.lhs].readAs(i64) *% slots[ops.rhs].readAs(i64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}

pub fn handle_i64_div_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.divS(slots[ops.lhs].readAs(i64), slots[ops.rhs].readAs(i64)) catch |e| {
        trapReturn(frame, switch (e) {
            error.IntegerDivisionByZero => .IntegerDivisionByZero,
            error.IntegerOverflow => .IntegerOverflow,
        });
        return;
    };
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_div_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.divU(i64, slots[ops.lhs].readAs(u64), slots[ops.rhs].readAs(u64)) catch {
        trapReturn(frame, .IntegerDivisionByZero);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i64, @bitCast(result)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, result, fp0);
}
pub fn handle_i64_rem_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.remS(slots[ops.lhs].readAs(i64), slots[ops.rhs].readAs(i64)) catch {
        trapReturn(frame, .IntegerDivisionByZero);
        return;
    };
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_rem_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.remU(i64, slots[ops.lhs].readAs(u64), slots[ops.rhs].readAs(u64)) catch {
        trapReturn(frame, .IntegerDivisionByZero);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i64, @bitCast(result)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, result, fp0);
}
pub fn handle_i64_and(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: i64 = slots[ops.lhs].readAs(i64) & slots[ops.rhs].readAs(i64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_or(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: i64 = slots[ops.lhs].readAs(i64) | slots[ops.rhs].readAs(i64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_xor(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: i64 = slots[ops.lhs].readAs(i64) ^ slots[ops.rhs].readAs(i64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_shl(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.shl(slots[ops.lhs].readAs(i64), slots[ops.rhs].readAs(i64));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_shr_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.shrS(slots[ops.lhs].readAs(i64), slots[ops.rhs].readAs(i64));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_shr_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: i64 = @bitCast(helper.shrU(i64, slots[ops.lhs].readAs(u64), slots[ops.rhs].readAs(u64)));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_rotl(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.rotl(slots[ops.lhs].readAs(i64), slots[ops.rhs].readAs(i64));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_rotr(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = r0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.rotr(slots[ops.lhs].readAs(i64), slots[ops.rhs].readAs(i64));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}

// ── f32 binary ───────────────────────────────────────────────────────────────

pub fn handle_f32_add(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = fp0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: f32 = slots[ops.lhs].readAs(f32) + slots[ops.rhs].readAs(f32);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, @as(f64, @floatCast(result)));
}
pub fn handle_f32_sub(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = fp0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: f32 = slots[ops.lhs].readAs(f32) - slots[ops.rhs].readAs(f32);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, @as(f64, @floatCast(result)));
}
pub fn handle_f32_mul(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = fp0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: f32 = slots[ops.lhs].readAs(f32) * slots[ops.rhs].readAs(f32);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, @as(f64, @floatCast(result)));
}
pub fn handle_f32_div(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = fp0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: f32 = slots[ops.lhs].readAs(f32) / slots[ops.rhs].readAs(f32);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, @as(f64, @floatCast(result)));
}
pub fn handle_f32_min(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = fp0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: f32 = helper.min(slots[ops.lhs].readAs(f32), slots[ops.rhs].readAs(f32));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, @as(f64, @floatCast(result)));
}
pub fn handle_f32_max(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = fp0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: f32 = helper.max(slots[ops.lhs].readAs(f32), slots[ops.rhs].readAs(f32));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, @as(f64, @floatCast(result)));
}
pub fn handle_f32_copysign(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = fp0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: f32 = helper.copySign(slots[ops.lhs].readAs(f32), slots[ops.rhs].readAs(f32));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, @as(f64, @floatCast(result)));
}

// ── f64 binary ───────────────────────────────────────────────────────────────

pub fn handle_f64_add(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = fp0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: f64 = slots[ops.lhs].readAs(f64) + slots[ops.rhs].readAs(f64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, result);
}
pub fn handle_f64_sub(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = fp0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: f64 = slots[ops.lhs].readAs(f64) - slots[ops.rhs].readAs(f64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, result);
}
pub fn handle_f64_mul(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = fp0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: f64 = slots[ops.lhs].readAs(f64) * slots[ops.rhs].readAs(f64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, result);
}
pub fn handle_f64_div(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = fp0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: f64 = slots[ops.lhs].readAs(f64) / slots[ops.rhs].readAs(f64);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, result);
}
pub fn handle_f64_min(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = fp0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: f64 = helper.min(slots[ops.lhs].readAs(f64), slots[ops.rhs].readAs(f64));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, result);
}
pub fn handle_f64_max(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = fp0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: f64 = helper.max(slots[ops.lhs].readAs(f64), slots[ops.rhs].readAs(f64));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, result);
}
pub fn handle_f64_copysign(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    _ = fp0;
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result: f64 = helper.copySign(slots[ops.lhs].readAs(f64), slots[ops.rhs].readAs(f64));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, result);
}

// ── Integer unary ────────────────────────────────────────────────────────────

pub fn handle_i32_clz(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.leadingZeros(slots[ops.src].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_i32_ctz(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.trailingZeros(slots[ops.src].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_i32_popcnt(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.countOnes(slots[ops.src].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_i32_eqz(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.src].readAs(i32) == 0) 1 else 0));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_i64_clz(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.leadingZeros(slots[ops.src].readAs(i64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_i64_ctz(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.trailingZeros(slots[ops.src].readAs(i64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_i64_popcnt(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.countOnes(slots[ops.src].readAs(i64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_i64_eqz(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.src].readAs(i64) == 0) 1 else 0));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

// ── Float unary ──────────────────────────────────────────────────────────────

pub fn handle_f32_abs(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.abs(slots[ops.src].readAs(f32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_f32_neg(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(-slots[ops.src].readAs(f32));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_f32_ceil(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.ceil(slots[ops.src].readAs(f32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_f32_floor(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.floor(slots[ops.src].readAs(f32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_f32_trunc(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.trunc(slots[ops.src].readAs(f32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_f32_nearest(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.nearest(slots[ops.src].readAs(f32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_f32_sqrt(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.sqrt(slots[ops.src].readAs(f32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_f64_abs(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.abs(slots[ops.src].readAs(f64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_f64_neg(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(-slots[ops.src].readAs(f64));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_f64_ceil(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.ceil(slots[ops.src].readAs(f64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_f64_floor(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.floor(slots[ops.src].readAs(f64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_f64_trunc(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.trunc(slots[ops.src].readAs(f64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_f64_nearest(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.nearest(slots[ops.src].readAs(f64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}
pub fn handle_f64_sqrt(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("unary");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.sqrt(slots[ops.src].readAs(f64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

// ── Comparisons ──────────────────────────────────────────────────────────────

fn cmpI32(comptime op: enum { eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u }, slots: [*]RawVal, ops: encode.OpsDstLhsRhs) void {
    const result: i32 = switch (op) {
        .eq => if (slots[ops.lhs].readAs(i32) == slots[ops.rhs].readAs(i32)) @as(i32, 1) else 0,
        .ne => if (slots[ops.lhs].readAs(i32) != slots[ops.rhs].readAs(i32)) @as(i32, 1) else 0,
        .lt_s => if (slots[ops.lhs].readAs(i32) < slots[ops.rhs].readAs(i32)) @as(i32, 1) else 0,
        .lt_u => if (slots[ops.lhs].readAs(u32) < slots[ops.rhs].readAs(u32)) @as(i32, 1) else 0,
        .gt_s => if (slots[ops.lhs].readAs(i32) > slots[ops.rhs].readAs(i32)) @as(i32, 1) else 0,
        .gt_u => if (slots[ops.lhs].readAs(u32) > slots[ops.rhs].readAs(u32)) @as(i32, 1) else 0,
        .le_s => if (slots[ops.lhs].readAs(i32) <= slots[ops.rhs].readAs(i32)) @as(i32, 1) else 0,
        .le_u => if (slots[ops.lhs].readAs(u32) <= slots[ops.rhs].readAs(u32)) @as(i32, 1) else 0,
        .ge_s => if (slots[ops.lhs].readAs(i32) >= slots[ops.rhs].readAs(i32)) @as(i32, 1) else 0,
        .ge_u => if (slots[ops.lhs].readAs(u32) >= slots[ops.rhs].readAs(u32)) @as(i32, 1) else 0,
    };
    slots[ops.dst] = RawVal.from(result);
}

pub fn handle_i32_eq(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI32(.eq, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_i32_ne(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI32(.ne, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_i32_lt_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI32(.lt_s, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_i32_lt_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI32(.lt_u, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_i32_gt_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI32(.gt_s, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_i32_gt_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI32(.gt_u, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_i32_le_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI32(.le_s, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_i32_le_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI32(.le_u, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_i32_ge_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI32(.ge_s, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_i32_ge_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI32(.ge_u, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}

fn cmpI64(comptime op: enum { eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u }, slots: [*]RawVal, ops: encode.OpsDstLhsRhs) void {
    const result: i32 = switch (op) {
        .eq => if (slots[ops.lhs].readAs(i64) == slots[ops.rhs].readAs(i64)) @as(i32, 1) else 0,
        .ne => if (slots[ops.lhs].readAs(i64) != slots[ops.rhs].readAs(i64)) @as(i32, 1) else 0,
        .lt_s => if (slots[ops.lhs].readAs(i64) < slots[ops.rhs].readAs(i64)) @as(i32, 1) else 0,
        .lt_u => if (slots[ops.lhs].readAs(u64) < slots[ops.rhs].readAs(u64)) @as(i32, 1) else 0,
        .gt_s => if (slots[ops.lhs].readAs(i64) > slots[ops.rhs].readAs(i64)) @as(i32, 1) else 0,
        .gt_u => if (slots[ops.lhs].readAs(u64) > slots[ops.rhs].readAs(u64)) @as(i32, 1) else 0,
        .le_s => if (slots[ops.lhs].readAs(i64) <= slots[ops.rhs].readAs(i64)) @as(i32, 1) else 0,
        .le_u => if (slots[ops.lhs].readAs(u64) <= slots[ops.rhs].readAs(u64)) @as(i32, 1) else 0,
        .ge_s => if (slots[ops.lhs].readAs(i64) >= slots[ops.rhs].readAs(i64)) @as(i32, 1) else 0,
        .ge_u => if (slots[ops.lhs].readAs(u64) >= slots[ops.rhs].readAs(u64)) @as(i32, 1) else 0,
    };
    slots[ops.dst] = RawVal.from(result);
}

fn cmpI32ToLocal(comptime op: enum { eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u }, slots: [*]RawVal, ops: encode.OpsCmpToLocal) i32 {
    return switch (op) {
        .eq => if (slots[ops.lhs].readAs(i32) == slots[ops.rhs].readAs(i32)) @as(i32, 1) else 0,
        .ne => if (slots[ops.lhs].readAs(i32) != slots[ops.rhs].readAs(i32)) @as(i32, 1) else 0,
        .lt_s => if (slots[ops.lhs].readAs(i32) < slots[ops.rhs].readAs(i32)) @as(i32, 1) else 0,
        .lt_u => if (slots[ops.lhs].readAs(u32) < slots[ops.rhs].readAs(u32)) @as(i32, 1) else 0,
        .gt_s => if (slots[ops.lhs].readAs(i32) > slots[ops.rhs].readAs(i32)) @as(i32, 1) else 0,
        .gt_u => if (slots[ops.lhs].readAs(u32) > slots[ops.rhs].readAs(u32)) @as(i32, 1) else 0,
        .le_s => if (slots[ops.lhs].readAs(i32) <= slots[ops.rhs].readAs(i32)) @as(i32, 1) else 0,
        .le_u => if (slots[ops.lhs].readAs(u32) <= slots[ops.rhs].readAs(u32)) @as(i32, 1) else 0,
        .ge_s => if (slots[ops.lhs].readAs(i32) >= slots[ops.rhs].readAs(i32)) @as(i32, 1) else 0,
        .ge_u => if (slots[ops.lhs].readAs(u32) >= slots[ops.rhs].readAs(u32)) @as(i32, 1) else 0,
    };
}

fn cmpI64ToLocal(comptime op: enum { eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u }, slots: [*]RawVal, ops: encode.OpsCmpToLocal) i32 {
    return switch (op) {
        .eq => if (slots[ops.lhs].readAs(i64) == slots[ops.rhs].readAs(i64)) @as(i32, 1) else 0,
        .ne => if (slots[ops.lhs].readAs(i64) != slots[ops.rhs].readAs(i64)) @as(i32, 1) else 0,
        .lt_s => if (slots[ops.lhs].readAs(i64) < slots[ops.rhs].readAs(i64)) @as(i32, 1) else 0,
        .lt_u => if (slots[ops.lhs].readAs(u64) < slots[ops.rhs].readAs(u64)) @as(i32, 1) else 0,
        .gt_s => if (slots[ops.lhs].readAs(i64) > slots[ops.rhs].readAs(i64)) @as(i32, 1) else 0,
        .gt_u => if (slots[ops.lhs].readAs(u64) > slots[ops.rhs].readAs(u64)) @as(i32, 1) else 0,
        .le_s => if (slots[ops.lhs].readAs(i64) <= slots[ops.rhs].readAs(i64)) @as(i32, 1) else 0,
        .le_u => if (slots[ops.lhs].readAs(u64) <= slots[ops.rhs].readAs(u64)) @as(i32, 1) else 0,
        .ge_s => if (slots[ops.lhs].readAs(i64) >= slots[ops.rhs].readAs(i64)) @as(i32, 1) else 0,
        .ge_u => if (slots[ops.lhs].readAs(u64) >= slots[ops.rhs].readAs(u64)) @as(i32, 1) else 0,
    };
}

pub fn handle_i64_eq(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI64(.eq, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_i64_ne(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI64(.ne, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_i64_lt_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI64(.lt_s, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_i64_lt_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI64(.lt_u, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_i64_gt_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI64(.gt_s, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_i64_gt_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI64(.gt_u, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_i64_le_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI64(.le_s, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_i64_le_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI64(.le_u, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_i64_ge_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI64(.ge_s, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_i64_ge_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpI64(.ge_u, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}

// ── Fused: comparison + local_set (cmp_to_local, i32) ───────────────────

pub fn handle_i32_eq_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI32ToLocal(.eq, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_ne_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI32ToLocal(.ne, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_lt_s_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI32ToLocal(.lt_s, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_lt_u_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI32ToLocal(.lt_u, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_gt_s_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI32ToLocal(.gt_s, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_gt_u_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI32ToLocal(.gt_u, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_le_s_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI32ToLocal(.le_s, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_le_u_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI32ToLocal(.le_u, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_ge_s_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI32ToLocal(.ge_s, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_ge_u_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI32ToLocal(.ge_u, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}

// ── Fused: comparison + local_set (cmp_to_local, i64) ───────────────────

pub fn handle_i64_eq_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI64ToLocal(.eq, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i64_ne_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI64ToLocal(.ne, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i64_lt_s_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI64ToLocal(.lt_s, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i64_lt_u_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI64ToLocal(.lt_u, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i64_gt_s_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI64ToLocal(.gt_s, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i64_gt_u_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI64ToLocal(.gt_u, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i64_le_s_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI64ToLocal(.le_s, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i64_le_u_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI64ToLocal(.le_u, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i64_ge_s_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI64ToLocal(.ge_s, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i64_ge_u_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp_to_local");
    const ops = readOps(encode.OpsCmpToLocal, ip);
    slots[ops.local] = RawVal.from(cmpI64ToLocal(.ge_u, slots, ops));
    dispatch.next(ip, stride(encode.OpsCmpToLocal), slots, frame, env, r0, fp0);
}

fn cmpF32(comptime op: enum { eq, ne, lt, gt, le, ge }, slots: [*]RawVal, ops: encode.OpsDstLhsRhs) void {
    const lhs = slots[ops.lhs].readAs(f32);
    const rhs = slots[ops.rhs].readAs(f32);
    const result: i32 = switch (op) {
        .eq => if (lhs == rhs) @as(i32, 1) else 0,
        .ne => if (lhs != rhs) @as(i32, 1) else 0,
        .lt => if (lhs < rhs) @as(i32, 1) else 0,
        .gt => if (lhs > rhs) @as(i32, 1) else 0,
        .le => if (lhs <= rhs) @as(i32, 1) else 0,
        .ge => if (lhs >= rhs) @as(i32, 1) else 0,
    };
    slots[ops.dst] = RawVal.from(result);
}

pub fn handle_f32_eq(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpF32(.eq, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_f32_ne(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpF32(.ne, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_f32_lt(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpF32(.lt, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_f32_gt(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpF32(.gt, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_f32_le(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpF32(.le, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_f32_ge(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpF32(.ge, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}

fn cmpF64(comptime op: enum { eq, ne, lt, gt, le, ge }, slots: [*]RawVal, ops: encode.OpsDstLhsRhs) void {
    const lhs = slots[ops.lhs].readAs(f64);
    const rhs = slots[ops.rhs].readAs(f64);
    const result: i32 = switch (op) {
        .eq => if (lhs == rhs) @as(i32, 1) else 0,
        .ne => if (lhs != rhs) @as(i32, 1) else 0,
        .lt => if (lhs < rhs) @as(i32, 1) else 0,
        .gt => if (lhs > rhs) @as(i32, 1) else 0,
        .le => if (lhs <= rhs) @as(i32, 1) else 0,
        .ge => if (lhs >= rhs) @as(i32, 1) else 0,
    };
    slots[ops.dst] = RawVal.from(result);
}

pub fn handle_f64_eq(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpF64(.eq, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_f64_ne(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpF64(.ne, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_f64_lt(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpF64(.lt, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_f64_gt(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpF64(.gt, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_f64_le(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpF64(.le, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}
pub fn handle_f64_ge(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("cmp");

    cmpF64(.ge, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env, r0, fp0);
}

// ── Conversions ─────────────────────────────────────────────────────────────

inline fn reinterpretUnsignedAsSigned(comptime T: type, value: UnsignedOf(T)) T {
    return @as(T, @bitCast(value));
}

pub fn handle_i32_wrap_i64(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    const bits = @as(u32, @truncate(slots[ops.src].readAs(u64)));
    slots[ops.dst] = RawVal.from(@as(i32, @bitCast(bits)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_i64_extend_i32_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(i64, slots[ops.src].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_i64_extend_i32_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(i64, @intCast(slots[ops.src].readAs(u32))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

// Trapping truncations (float → signed int)
pub fn handle_i32_trunc_f32_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.tryTruncateInto(i32, slots[ops.src].readAs(f32)) catch |err| {
        trapReturnTruncate(frame, err);
        return;
    };
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_i32_trunc_f64_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.tryTruncateInto(i32, slots[ops.src].readAs(f64)) catch |err| {
        trapReturnTruncate(frame, err);
        return;
    };
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_i64_trunc_f32_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.tryTruncateInto(i64, slots[ops.src].readAs(f32)) catch |err| {
        trapReturnTruncate(frame, err);
        return;
    };
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_i64_trunc_f64_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.tryTruncateInto(i64, slots[ops.src].readAs(f64)) catch |err| {
        trapReturnTruncate(frame, err);
        return;
    };
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

// Trapping truncations (float → unsigned int, stored as signed)
pub fn handle_i32_trunc_f32_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.tryTruncateInto(u32, slots[ops.src].readAs(f32)) catch |err| {
        trapReturnTruncate(frame, err);
        return;
    };
    slots[ops.dst] = RawVal.from(reinterpretUnsignedAsSigned(i32, result));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_i32_trunc_f64_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.tryTruncateInto(u32, slots[ops.src].readAs(f64)) catch |err| {
        trapReturnTruncate(frame, err);
        return;
    };
    slots[ops.dst] = RawVal.from(reinterpretUnsignedAsSigned(i32, result));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_i64_trunc_f32_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.tryTruncateInto(u64, slots[ops.src].readAs(f32)) catch |err| {
        trapReturnTruncate(frame, err);
        return;
    };
    slots[ops.dst] = RawVal.from(reinterpretUnsignedAsSigned(i64, result));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_i64_trunc_f64_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.tryTruncateInto(u64, slots[ops.src].readAs(f64)) catch |err| {
        trapReturnTruncate(frame, err);
        return;
    };
    slots[ops.dst] = RawVal.from(reinterpretUnsignedAsSigned(i64, result));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

// Saturating truncations (signed)
pub fn handle_i32_trunc_sat_f32_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.truncateSaturateInto(i32, slots[ops.src].readAs(f32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_i32_trunc_sat_f64_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.truncateSaturateInto(i32, slots[ops.src].readAs(f64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_i64_trunc_sat_f32_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.truncateSaturateInto(i64, slots[ops.src].readAs(f32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_i64_trunc_sat_f64_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.truncateSaturateInto(i64, slots[ops.src].readAs(f64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

// Saturating truncations (unsigned)
pub fn handle_i32_trunc_sat_f32_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.truncateSaturateInto(u32, slots[ops.src].readAs(f32));
    slots[ops.dst] = RawVal.from(reinterpretUnsignedAsSigned(i32, result));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_i32_trunc_sat_f64_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.truncateSaturateInto(u32, slots[ops.src].readAs(f64));
    slots[ops.dst] = RawVal.from(reinterpretUnsignedAsSigned(i32, result));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_i64_trunc_sat_f32_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.truncateSaturateInto(u64, slots[ops.src].readAs(f32));
    slots[ops.dst] = RawVal.from(reinterpretUnsignedAsSigned(i64, result));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_i64_trunc_sat_f64_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.truncateSaturateInto(u64, slots[ops.src].readAs(f64));
    slots[ops.dst] = RawVal.from(reinterpretUnsignedAsSigned(i64, result));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

// int → float conversions (signed)
pub fn handle_f32_convert_i32_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f32, @floatFromInt(slots[ops.src].readAs(i32))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_f32_convert_i64_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f32, @floatFromInt(slots[ops.src].readAs(i64))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_f64_convert_i32_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f64, @floatFromInt(slots[ops.src].readAs(i32))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_f64_convert_i64_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f64, @floatFromInt(slots[ops.src].readAs(i64))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

// int → float conversions (unsigned)
pub fn handle_f32_convert_i32_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f32, @floatFromInt(slots[ops.src].readAs(u32))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_f32_convert_i64_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f32, @floatFromInt(slots[ops.src].readAs(u64))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_f64_convert_i32_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f64, @floatFromInt(slots[ops.src].readAs(u32))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_f64_convert_i64_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("misc");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f64, @floatFromInt(slots[ops.src].readAs(u64))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

// Float resize
pub fn handle_f32_demote_f64(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f32, @floatCast(slots[ops.src].readAs(f64))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_f64_promote_f32(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f64, @floatCast(slots[ops.src].readAs(f32))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

// Reinterpret
pub fn handle_i32_reinterpret_f32(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(i32, @bitCast(slots[ops.src].readAs(f32))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_i64_reinterpret_f64(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(i64, @bitCast(slots[ops.src].readAs(f64))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_f32_reinterpret_i32(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f32, @bitCast(slots[ops.src].readAs(i32))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_f64_reinterpret_i64(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f64, @bitCast(slots[ops.src].readAs(i64))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

// Sign-extension
pub fn handle_i32_extend8_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.signExtendFrom(i8, slots[ops.src].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_i32_extend16_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.signExtendFrom(i16, slots[ops.src].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_i64_extend8_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.signExtendFrom(i8, slots[ops.src].readAs(i64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_i64_extend16_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.signExtendFrom(i16, slots[ops.src].readAs(i64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

pub fn handle_i64_extend32_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("conv");

    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.signExtendFrom(i32, slots[ops.src].readAs(i64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env, r0, fp0);
}

// ── Fused: i32 binop-imm (Candidate C) ──────────────────────────────────────

pub fn handle_i32_add_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i32) +% ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env, r0, fp0);
}
pub fn handle_i32_sub_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i32) -% ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env, r0, fp0);
}
pub fn handle_i32_mul_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i32) *% ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env, r0, fp0);
}
pub fn handle_i32_and_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i32) & ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env, r0, fp0);
}
pub fn handle_i32_or_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i32) | ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env, r0, fp0);
}
pub fn handle_i32_xor_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i32) ^ ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env, r0, fp0);
}
pub fn handle_i32_shl_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(helper.shl(slots[ops.lhs].readAs(i32), ops.imm));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env, r0, fp0);
}
pub fn handle_i32_shr_s_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(helper.shrS(slots[ops.lhs].readAs(i32), ops.imm));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env, r0, fp0);
}
pub fn handle_i32_shr_u_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, @bitCast(helper.shrU(i32, slots[ops.lhs].readAs(u32), @as(u32, @bitCast(ops.imm))))));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env, r0, fp0);
}
// compare-imm variants (result = i32 boolean)
pub fn handle_i32_eq_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(i32) == ops.imm) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env, r0, fp0);
}
pub fn handle_i32_ne_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(i32) != ops.imm) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env, r0, fp0);
}
pub fn handle_i32_lt_s_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(i32) < ops.imm) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env, r0, fp0);
}
pub fn handle_i32_lt_u_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(u32) < @as(u32, @bitCast(ops.imm))) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env, r0, fp0);
}
pub fn handle_i32_gt_s_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(i32) > ops.imm) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env, r0, fp0);
}
pub fn handle_i32_gt_u_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(u32) > @as(u32, @bitCast(ops.imm))) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env, r0, fp0);
}
pub fn handle_i32_le_s_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(i32) <= ops.imm) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env, r0, fp0);
}
pub fn handle_i32_le_u_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(u32) <= @as(u32, @bitCast(ops.imm))) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env, r0, fp0);
}
pub fn handle_i32_ge_s_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(i32) >= ops.imm) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env, r0, fp0);
}
pub fn handle_i32_ge_u_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(u32) >= @as(u32, @bitCast(ops.imm))) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env, r0, fp0);
}

// ── Fused: i32 compare-jump (Candidate F) ───────────────────────────────────
// Jumps to rel_target (from instruction start) when the comparison is FALSE.

inline fn cmpJumpI32(
    comptime op: enum { eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u },
    ip: [*]u8,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
    r0: u64,
    fp0: f64,
) void {
    const ops = readOps(encode.OpsCompareJump, ip);
    const taken = switch (op) {
        .eq => slots[ops.lhs].readAs(i32) == slots[ops.rhs].readAs(i32),
        .ne => slots[ops.lhs].readAs(i32) != slots[ops.rhs].readAs(i32),
        .lt_s => slots[ops.lhs].readAs(i32) < slots[ops.rhs].readAs(i32),
        .lt_u => slots[ops.lhs].readAs(u32) < slots[ops.rhs].readAs(u32),
        .gt_s => slots[ops.lhs].readAs(i32) > slots[ops.rhs].readAs(i32),
        .gt_u => slots[ops.lhs].readAs(u32) > slots[ops.rhs].readAs(u32),
        .le_s => slots[ops.lhs].readAs(i32) <= slots[ops.rhs].readAs(i32),
        .le_u => slots[ops.lhs].readAs(u32) <= slots[ops.rhs].readAs(u32),
        .ge_s => slots[ops.lhs].readAs(i32) >= slots[ops.rhs].readAs(i32),
        .ge_u => slots[ops.lhs].readAs(u32) >= slots[ops.rhs].readAs(u32),
    };
    if (!taken) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsCompareJump), slots, frame, env, r0, fp0);
    }
}

pub fn handle_i32_eq_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32(.eq, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_ne_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32(.ne, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_lt_s_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32(.lt_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_lt_u_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32(.lt_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_gt_s_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32(.gt_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_gt_u_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32(.gt_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_le_s_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32(.le_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_le_u_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32(.le_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_ge_s_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32(.ge_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_ge_u_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32(.ge_u, ip, slots, frame, env, r0, fp0);
}
/// Fused i32.eqz + br_if: jumps when src != 0 (i.e. eqz is false).
pub fn handle_i32_eqz_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    const ops = readOps(encode.OpsEqzJump, ip);
    if (slots[ops.src].readAs(i32) != 0) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsEqzJump), slots, frame, env, r0, fp0);
    }
}

// ── Fused: i32 compare-jump-if-true (Peephole J) ─────────────────────────────
// Jumps to target when comparison is TRUE. Replaces jump_if_false+jump pattern.

inline fn cmpJumpI32True(
    comptime op: enum { eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u },
    ip: [*]u8,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
    r0: u64,
    fp0: f64,
) void {
    const ops = readOps(encode.OpsCompareJump, ip);
    const taken = switch (op) {
        .eq => slots[ops.lhs].readAs(i32) == slots[ops.rhs].readAs(i32),
        .ne => slots[ops.lhs].readAs(i32) != slots[ops.rhs].readAs(i32),
        .lt_s => slots[ops.lhs].readAs(i32) < slots[ops.rhs].readAs(i32),
        .lt_u => slots[ops.lhs].readAs(u32) < slots[ops.rhs].readAs(u32),
        .gt_s => slots[ops.lhs].readAs(i32) > slots[ops.rhs].readAs(i32),
        .gt_u => slots[ops.lhs].readAs(u32) > slots[ops.rhs].readAs(u32),
        .le_s => slots[ops.lhs].readAs(i32) <= slots[ops.rhs].readAs(i32),
        .le_u => slots[ops.lhs].readAs(u32) <= slots[ops.rhs].readAs(u32),
        .ge_s => slots[ops.lhs].readAs(i32) >= slots[ops.rhs].readAs(i32),
        .ge_u => slots[ops.lhs].readAs(u32) >= slots[ops.rhs].readAs(u32),
    };
    if (taken) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsCompareJump), slots, frame, env, r0, fp0);
    }
}

pub fn handle_i32_eq_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32True(.eq, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_ne_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32True(.ne, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_lt_s_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32True(.lt_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_lt_u_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32True(.lt_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_gt_s_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32True(.gt_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_gt_u_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32True(.gt_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_le_s_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32True(.le_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_le_u_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32True(.le_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_ge_s_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32True(.ge_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_ge_u_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI32True(.ge_u, ip, slots, frame, env, r0, fp0);
}
/// Fused i32.eqz + br_if: jumps when src == 0 (i.e. eqz is true).
pub fn handle_i32_eqz_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    const ops = readOps(encode.OpsEqzJump, ip);
    if (slots[ops.src].readAs(i32) == 0) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsEqzJump), slots, frame, env, r0, fp0);
    }
}

// ── Fused: i32 binop-to-local (Candidate D) ─────────────────────────────────

pub fn handle_i32_add_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_to_local");
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i32) +% slots[ops.rhs].readAs(i32));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_sub_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_to_local");
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i32) -% slots[ops.rhs].readAs(i32));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_mul_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_to_local");
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i32) *% slots[ops.rhs].readAs(i32));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_and_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_to_local");
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i32) & slots[ops.rhs].readAs(i32));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_or_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_to_local");
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i32) | slots[ops.rhs].readAs(i32));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_xor_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_to_local");
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i32) ^ slots[ops.rhs].readAs(i32));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_shl_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_to_local");
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(helper.shl(slots[ops.lhs].readAs(i32), slots[ops.rhs].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_shr_s_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_to_local");
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(helper.shrS(slots[ops.lhs].readAs(i32), slots[ops.rhs].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_shr_u_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_to_local");
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(@as(i32, @bitCast(helper.shrU(i32, slots[ops.lhs].readAs(u32), slots[ops.rhs].readAs(u32)))));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env, r0, fp0);
}

// ── Fused: i64 binop-imm (Candidate C, i64) ─────────────────────────────────

pub fn handle_i64_add_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm64, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i64) +% ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImm64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_sub_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm64, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i64) -% ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImm64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_mul_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm64, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i64) *% ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImm64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_and_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm64, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i64) & ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImm64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_or_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm64, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i64) | ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImm64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_xor_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm64, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i64) ^ ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImm64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_shl_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm64, ip);
    slots[ops.dst] = RawVal.from(helper.shl(slots[ops.lhs].readAs(i64), ops.imm));
    dispatch.next(ip, stride(encode.OpsBinopImm64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_shr_s_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm64, ip);
    slots[ops.dst] = RawVal.from(helper.shrS(slots[ops.lhs].readAs(i64), ops.imm));
    dispatch.next(ip, stride(encode.OpsBinopImm64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_shr_u_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm64, ip);
    slots[ops.dst] = RawVal.from(@as(i64, @bitCast(helper.shrU(i64, slots[ops.lhs].readAs(u64), @as(u64, @bitCast(ops.imm))))));
    dispatch.next(ip, stride(encode.OpsBinopImm64), slots, frame, env, r0, fp0);
}
// i64 compare-imm variants (result = i32 boolean)
pub fn handle_i64_eq_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm64, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(i64) == ops.imm) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_ne_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm64, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(i64) != ops.imm) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_lt_s_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm64, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(i64) < ops.imm) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_lt_u_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm64, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(u64) < @as(u64, @bitCast(ops.imm))) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_gt_s_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm64, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(i64) > ops.imm) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_gt_u_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm64, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(u64) > @as(u64, @bitCast(ops.imm))) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_le_s_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm64, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(i64) <= ops.imm) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_le_u_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm64, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(u64) <= @as(u64, @bitCast(ops.imm))) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_ge_s_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm64, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(i64) >= ops.imm) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_ge_u_imm(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm");

    const ops = readOps(encode.OpsBinopImm64, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(u64) >= @as(u64, @bitCast(ops.imm))) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm64), slots, frame, env, r0, fp0);
}

// ── r0 variants: i32 binop-imm-r (lhs from r0 accumulator) ─────────────────

pub fn handle_i32_add_imm_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm_r");

    const ops = readOps(encode.OpsBinopImmR0, ip);
    const result = @as(i32, @truncate(@as(i64, @bitCast(r0)))) +% ops.imm;
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopImmR0), slots, frame, env, @as(u64, @bitCast(@as(i64, result))), fp0);
}
pub fn handle_i32_sub_imm_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm_r");

    const ops = readOps(encode.OpsBinopImmR0, ip);
    const result = @as(i32, @truncate(@as(i64, @bitCast(r0)))) -% ops.imm;
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopImmR0), slots, frame, env, @as(u64, @bitCast(@as(i64, result))), fp0);
}
pub fn handle_i32_mul_imm_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm_r");

    const ops = readOps(encode.OpsBinopImmR0, ip);
    const result = @as(i32, @truncate(@as(i64, @bitCast(r0)))) *% ops.imm;
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopImmR0), slots, frame, env, @as(u64, @bitCast(@as(i64, result))), fp0);
}
pub fn handle_i32_and_imm_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm_r");

    const ops = readOps(encode.OpsBinopImmR0, ip);
    const result = @as(i32, @truncate(@as(i64, @bitCast(r0)))) & ops.imm;
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopImmR0), slots, frame, env, @as(u64, @bitCast(@as(i64, result))), fp0);
}
pub fn handle_i32_or_imm_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm_r");

    const ops = readOps(encode.OpsBinopImmR0, ip);
    const result = @as(i32, @truncate(@as(i64, @bitCast(r0)))) | ops.imm;
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopImmR0), slots, frame, env, @as(u64, @bitCast(@as(i64, result))), fp0);
}
pub fn handle_i32_xor_imm_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm_r");

    const ops = readOps(encode.OpsBinopImmR0, ip);
    const result = @as(i32, @truncate(@as(i64, @bitCast(r0)))) ^ ops.imm;
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopImmR0), slots, frame, env, @as(u64, @bitCast(@as(i64, result))), fp0);
}
pub fn handle_i32_shl_imm_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm_r");

    const ops = readOps(encode.OpsBinopImmR0, ip);
    const lhs = @as(i32, @truncate(@as(i64, @bitCast(r0))));
    const result = helper.shl(lhs, ops.imm);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopImmR0), slots, frame, env, @as(u64, @bitCast(@as(i64, result))), fp0);
}
pub fn handle_i32_shr_s_imm_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm_r");

    const ops = readOps(encode.OpsBinopImmR0, ip);
    const lhs = @as(i32, @truncate(@as(i64, @bitCast(r0))));
    const result = helper.shrS(lhs, ops.imm);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopImmR0), slots, frame, env, @as(u64, @bitCast(@as(i64, result))), fp0);
}
pub fn handle_i32_shr_u_imm_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm_r");

    const ops = readOps(encode.OpsBinopImmR0, ip);
    const lhs = @as(u32, @truncate(r0));
    const result = @as(i32, @bitCast(helper.shrU(i32, lhs, @as(u32, @bitCast(ops.imm)))));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopImmR0), slots, frame, env, @as(u64, @bitCast(@as(i64, result))), fp0);
}

// ── r0 variants: i64 binop-imm-r (lhs from r0 accumulator) ─────────────────

pub fn handle_i64_add_imm_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm_r");

    const ops = readOps(encode.OpsBinopImmR064, ip);
    const result = @as(i64, @bitCast(r0)) +% ops.imm;
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopImmR064), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_sub_imm_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm_r");

    const ops = readOps(encode.OpsBinopImmR064, ip);
    const result = @as(i64, @bitCast(r0)) -% ops.imm;
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopImmR064), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_mul_imm_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm_r");

    const ops = readOps(encode.OpsBinopImmR064, ip);
    const result = @as(i64, @bitCast(r0)) *% ops.imm;
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopImmR064), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_and_imm_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm_r");

    const ops = readOps(encode.OpsBinopImmR064, ip);
    const result = @as(i64, @bitCast(r0)) & ops.imm;
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopImmR064), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_or_imm_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm_r");

    const ops = readOps(encode.OpsBinopImmR064, ip);
    const result = @as(i64, @bitCast(r0)) | ops.imm;
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopImmR064), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_xor_imm_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm_r");

    const ops = readOps(encode.OpsBinopImmR064, ip);
    const result = @as(i64, @bitCast(r0)) ^ ops.imm;
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopImmR064), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_shl_imm_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm_r");

    const ops = readOps(encode.OpsBinopImmR064, ip);
    const result = helper.shl(@as(i64, @bitCast(r0)), ops.imm);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopImmR064), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_shr_s_imm_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm_r");

    const ops = readOps(encode.OpsBinopImmR064, ip);
    const result = helper.shrS(@as(i64, @bitCast(r0)), ops.imm);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopImmR064), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_shr_u_imm_r(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("imm_r");

    const ops = readOps(encode.OpsBinopImmR064, ip);
    const result = @as(i64, @bitCast(helper.shrU(i64, r0, @as(u64, @bitCast(ops.imm)))));
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopImmR064), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}

// ── Fused: i64 compare-jump (Candidate F, i64) ──────────────────────────────

inline fn cmpJumpI64(
    comptime op: enum { eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u },
    ip: [*]u8,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
    r0: u64,
    fp0: f64,
) void {
    const ops = readOps(encode.OpsCompareJump, ip);
    const taken = switch (op) {
        .eq => slots[ops.lhs].readAs(i64) == slots[ops.rhs].readAs(i64),
        .ne => slots[ops.lhs].readAs(i64) != slots[ops.rhs].readAs(i64),
        .lt_s => slots[ops.lhs].readAs(i64) < slots[ops.rhs].readAs(i64),
        .lt_u => slots[ops.lhs].readAs(u64) < slots[ops.rhs].readAs(u64),
        .gt_s => slots[ops.lhs].readAs(i64) > slots[ops.rhs].readAs(i64),
        .gt_u => slots[ops.lhs].readAs(u64) > slots[ops.rhs].readAs(u64),
        .le_s => slots[ops.lhs].readAs(i64) <= slots[ops.rhs].readAs(i64),
        .le_u => slots[ops.lhs].readAs(u64) <= slots[ops.rhs].readAs(u64),
        .ge_s => slots[ops.lhs].readAs(i64) >= slots[ops.rhs].readAs(i64),
        .ge_u => slots[ops.lhs].readAs(u64) >= slots[ops.rhs].readAs(u64),
    };
    if (!taken) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsCompareJump), slots, frame, env, r0, fp0);
    }
}

pub fn handle_i64_eq_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64(.eq, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_ne_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64(.ne, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_lt_s_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64(.lt_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_lt_u_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64(.lt_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_gt_s_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64(.gt_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_gt_u_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64(.gt_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_le_s_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64(.le_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_le_u_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64(.le_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_ge_s_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64(.ge_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_ge_u_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64(.ge_u, ip, slots, frame, env, r0, fp0);
}
/// Fused i64.eqz + br_if: jumps when src != 0 (i.e. eqz is false).
pub fn handle_i64_eqz_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    const ops = readOps(encode.OpsEqzJump, ip);
    if (slots[ops.src].readAs(i64) != 0) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsEqzJump), slots, frame, env, r0, fp0);
    }
}

// ── Fused: i64 compare-jump-if-true (Peephole J) ─────────────────────────────

inline fn cmpJumpI64True(
    comptime op: enum { eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u },
    ip: [*]u8,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
    r0: u64,
    fp0: f64,
) void {
    const ops = readOps(encode.OpsCompareJump, ip);
    const taken = switch (op) {
        .eq => slots[ops.lhs].readAs(i64) == slots[ops.rhs].readAs(i64),
        .ne => slots[ops.lhs].readAs(i64) != slots[ops.rhs].readAs(i64),
        .lt_s => slots[ops.lhs].readAs(i64) < slots[ops.rhs].readAs(i64),
        .lt_u => slots[ops.lhs].readAs(u64) < slots[ops.rhs].readAs(u64),
        .gt_s => slots[ops.lhs].readAs(i64) > slots[ops.rhs].readAs(i64),
        .gt_u => slots[ops.lhs].readAs(u64) > slots[ops.rhs].readAs(u64),
        .le_s => slots[ops.lhs].readAs(i64) <= slots[ops.rhs].readAs(i64),
        .le_u => slots[ops.lhs].readAs(u64) <= slots[ops.rhs].readAs(u64),
        .ge_s => slots[ops.lhs].readAs(i64) >= slots[ops.rhs].readAs(i64),
        .ge_u => slots[ops.lhs].readAs(u64) >= slots[ops.rhs].readAs(u64),
    };
    if (taken) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsCompareJump), slots, frame, env, r0, fp0);
    }
}

pub fn handle_i64_eq_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64True(.eq, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_ne_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64True(.ne, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_lt_s_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64True(.lt_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_lt_u_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64True(.lt_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_gt_s_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64True(.gt_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_gt_u_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64True(.gt_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_le_s_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64True(.le_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_le_u_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64True(.le_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_ge_s_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64True(.ge_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_ge_u_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpJumpI64True(.ge_u, ip, slots, frame, env, r0, fp0);
}
/// Fused i64.eqz + br_if: jumps when src == 0 (i.e. eqz is true).
pub fn handle_i64_eqz_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    const ops = readOps(encode.OpsEqzJump, ip);
    if (slots[ops.src].readAs(i64) == 0) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsEqzJump), slots, frame, env, r0, fp0);
    }
}

// ── Fused: i64 binop-to-local (Candidate D, i64) ────────────────────────────

pub fn handle_i64_add_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_to_local");
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i64) +% slots[ops.rhs].readAs(i64));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i64_sub_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_to_local");
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i64) -% slots[ops.rhs].readAs(i64));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i64_mul_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_to_local");
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i64) *% slots[ops.rhs].readAs(i64));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i64_and_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_to_local");
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i64) & slots[ops.rhs].readAs(i64));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i64_or_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_to_local");
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i64) | slots[ops.rhs].readAs(i64));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i64_xor_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_to_local");
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i64) ^ slots[ops.rhs].readAs(i64));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i64_shl_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_to_local");
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(helper.shl(slots[ops.lhs].readAs(i64), slots[ops.rhs].readAs(i64)));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i64_shr_s_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_to_local");
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(helper.shrS(slots[ops.lhs].readAs(i64), slots[ops.rhs].readAs(i64)));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i64_shr_u_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_to_local");
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(@as(i64, @bitCast(helper.shrU(i64, slots[ops.lhs].readAs(u64), slots[ops.rhs].readAs(u64)))));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env, r0, fp0);
}

// ── Fused: binop + local_tee (i32) ──────────────────────────────────────

pub fn handle_i32_add_tee_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("tee_local");
    _ = r0;
    const ops = readOps(encode.OpsBinopTeeLocal, ip);
    const result = slots[ops.lhs].readAs(i32) +% slots[ops.rhs].readAs(i32);
    slots[ops.local] = RawVal.from(result);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopTeeLocal), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}
pub fn handle_i32_sub_tee_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("tee_local");
    _ = r0;
    const ops = readOps(encode.OpsBinopTeeLocal, ip);
    const result = slots[ops.lhs].readAs(i32) -% slots[ops.rhs].readAs(i32);
    slots[ops.local] = RawVal.from(result);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopTeeLocal), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}
pub fn handle_i32_mul_tee_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("tee_local");
    _ = r0;
    const ops = readOps(encode.OpsBinopTeeLocal, ip);
    const result = slots[ops.lhs].readAs(i32) *% slots[ops.rhs].readAs(i32);
    slots[ops.local] = RawVal.from(result);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopTeeLocal), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}
pub fn handle_i32_and_tee_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("tee_local");
    _ = r0;
    const ops = readOps(encode.OpsBinopTeeLocal, ip);
    const result = slots[ops.lhs].readAs(i32) & slots[ops.rhs].readAs(i32);
    slots[ops.local] = RawVal.from(result);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopTeeLocal), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}
pub fn handle_i32_or_tee_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("tee_local");
    _ = r0;
    const ops = readOps(encode.OpsBinopTeeLocal, ip);
    const result = slots[ops.lhs].readAs(i32) | slots[ops.rhs].readAs(i32);
    slots[ops.local] = RawVal.from(result);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopTeeLocal), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}
pub fn handle_i32_xor_tee_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("tee_local");
    _ = r0;
    const ops = readOps(encode.OpsBinopTeeLocal, ip);
    const result = slots[ops.lhs].readAs(i32) ^ slots[ops.rhs].readAs(i32);
    slots[ops.local] = RawVal.from(result);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopTeeLocal), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}
pub fn handle_i32_shl_tee_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("tee_local");
    _ = r0;
    const ops = readOps(encode.OpsBinopTeeLocal, ip);
    const result = helper.shl(slots[ops.lhs].readAs(i32), slots[ops.rhs].readAs(i32));
    slots[ops.local] = RawVal.from(result);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopTeeLocal), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}
pub fn handle_i32_shr_s_tee_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("tee_local");
    _ = r0;
    const ops = readOps(encode.OpsBinopTeeLocal, ip);
    const result = helper.shrS(slots[ops.lhs].readAs(i32), slots[ops.rhs].readAs(i32));
    slots[ops.local] = RawVal.from(result);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopTeeLocal), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}
pub fn handle_i32_shr_u_tee_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("tee_local");
    _ = r0;
    const ops = readOps(encode.OpsBinopTeeLocal, ip);
    const result: i32 = @bitCast(helper.shrU(i32, slots[ops.lhs].readAs(u32), slots[ops.rhs].readAs(u32)));
    slots[ops.local] = RawVal.from(result);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopTeeLocal), slots, frame, env, @as(u64, @intCast(@as(u32, @bitCast(result)))), fp0);
}

// ── Fused: binop + local_tee (i64) ──────────────────────────────────────

pub fn handle_i64_add_tee_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("tee_local");
    _ = r0;
    const ops = readOps(encode.OpsBinopTeeLocal, ip);
    const result: i64 = slots[ops.lhs].readAs(i64) +% slots[ops.rhs].readAs(i64);
    slots[ops.local] = RawVal.from(result);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopTeeLocal), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_sub_tee_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("tee_local");
    _ = r0;
    const ops = readOps(encode.OpsBinopTeeLocal, ip);
    const result: i64 = slots[ops.lhs].readAs(i64) -% slots[ops.rhs].readAs(i64);
    slots[ops.local] = RawVal.from(result);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopTeeLocal), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_mul_tee_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("tee_local");
    _ = r0;
    const ops = readOps(encode.OpsBinopTeeLocal, ip);
    const result: i64 = slots[ops.lhs].readAs(i64) *% slots[ops.rhs].readAs(i64);
    slots[ops.local] = RawVal.from(result);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopTeeLocal), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_and_tee_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("tee_local");
    _ = r0;
    const ops = readOps(encode.OpsBinopTeeLocal, ip);
    const result: i64 = slots[ops.lhs].readAs(i64) & slots[ops.rhs].readAs(i64);
    slots[ops.local] = RawVal.from(result);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopTeeLocal), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_or_tee_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("tee_local");
    _ = r0;
    const ops = readOps(encode.OpsBinopTeeLocal, ip);
    const result: i64 = slots[ops.lhs].readAs(i64) | slots[ops.rhs].readAs(i64);
    slots[ops.local] = RawVal.from(result);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopTeeLocal), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_xor_tee_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("tee_local");
    _ = r0;
    const ops = readOps(encode.OpsBinopTeeLocal, ip);
    const result: i64 = slots[ops.lhs].readAs(i64) ^ slots[ops.rhs].readAs(i64);
    slots[ops.local] = RawVal.from(result);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopTeeLocal), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_shl_tee_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("tee_local");
    _ = r0;
    const ops = readOps(encode.OpsBinopTeeLocal, ip);
    const result = helper.shl(slots[ops.lhs].readAs(i64), slots[ops.rhs].readAs(i64));
    slots[ops.local] = RawVal.from(result);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopTeeLocal), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_shr_s_tee_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("tee_local");
    _ = r0;
    const ops = readOps(encode.OpsBinopTeeLocal, ip);
    const result = helper.shrS(slots[ops.lhs].readAs(i64), slots[ops.rhs].readAs(i64));
    slots[ops.local] = RawVal.from(result);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopTeeLocal), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}
pub fn handle_i64_shr_u_tee_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("tee_local");
    _ = r0;
    const ops = readOps(encode.OpsBinopTeeLocal, ip);
    const result: i64 = @bitCast(helper.shrU(i64, slots[ops.lhs].readAs(u64), slots[ops.rhs].readAs(u64)));
    slots[ops.local] = RawVal.from(result);
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsBinopTeeLocal), slots, frame, env, @as(u64, @bitCast(result)), fp0);
}

const memory = @import("memory.zig");
pub const handle_i32_load = memory.handle_i32_load;
pub const handle_i32_load8_s = memory.handle_i32_load8_s;
pub const handle_i32_load8_u = memory.handle_i32_load8_u;
pub const handle_i32_load16_s = memory.handle_i32_load16_s;
pub const handle_i32_load16_u = memory.handle_i32_load16_u;
pub const handle_i64_load = memory.handle_i64_load;
pub const handle_i64_load8_s = memory.handle_i64_load8_s;
pub const handle_i64_load8_u = memory.handle_i64_load8_u;
pub const handle_i64_load16_s = memory.handle_i64_load16_s;
pub const handle_i64_load16_u = memory.handle_i64_load16_u;
pub const handle_i64_load32_s = memory.handle_i64_load32_s;
pub const handle_i64_load32_u = memory.handle_i64_load32_u;
pub const handle_f32_load = memory.handle_f32_load;
pub const handle_f64_load = memory.handle_f64_load;
pub const handle_i32_store = memory.handle_i32_store;
pub const handle_i32_store8 = memory.handle_i32_store8;
pub const handle_i32_store16 = memory.handle_i32_store16;
pub const handle_i64_store = memory.handle_i64_store;
pub const handle_i64_store8 = memory.handle_i64_store8;
pub const handle_i64_store16 = memory.handle_i64_store16;
pub const handle_i64_store32 = memory.handle_i64_store32;
pub const handle_f32_store = memory.handle_f32_store;
pub const handle_f64_store = memory.handle_f64_store;
pub const handle_memory_size = memory.handle_memory_size;
pub const handle_memory_grow = memory.handle_memory_grow;
pub const handle_memory_init = memory.handle_memory_init;
pub const handle_data_drop = memory.handle_data_drop;
pub const handle_memory_copy = memory.handle_memory_copy;
pub const handle_memory_fill = memory.handle_memory_fill;

// ── Fused: binop-imm-to-local (Candidate E, i32) ───────────────────────────
// const_i32 + binop + local_set → single instruction writing imm-op result to local.

pub fn handle_i32_add_imm_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_imm_to_local");
    dispatch.countOp("i32_to_local");
    const ops = readOps(encode.OpsBinopImmToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i32) +% ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImmToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_sub_imm_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_imm_to_local");
    dispatch.countOp("i32_to_local");
    const ops = readOps(encode.OpsBinopImmToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i32) -% ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImmToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_mul_imm_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_imm_to_local");
    dispatch.countOp("i32_to_local");
    const ops = readOps(encode.OpsBinopImmToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i32) *% ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImmToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_and_imm_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_imm_to_local");
    dispatch.countOp("i32_to_local");
    const ops = readOps(encode.OpsBinopImmToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i32) & ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImmToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_or_imm_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_imm_to_local");
    dispatch.countOp("i32_to_local");
    const ops = readOps(encode.OpsBinopImmToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i32) | ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImmToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_xor_imm_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_imm_to_local");
    dispatch.countOp("i32_to_local");
    const ops = readOps(encode.OpsBinopImmToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i32) ^ ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImmToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_shl_imm_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_imm_to_local");
    dispatch.countOp("i32_to_local");
    const ops = readOps(encode.OpsBinopImmToLocal, ip);
    slots[ops.local] = RawVal.from(helper.shl(slots[ops.lhs].readAs(i32), ops.imm));
    dispatch.next(ip, stride(encode.OpsBinopImmToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_shr_s_imm_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_imm_to_local");
    dispatch.countOp("i32_to_local");
    const ops = readOps(encode.OpsBinopImmToLocal, ip);
    slots[ops.local] = RawVal.from(helper.shrS(slots[ops.lhs].readAs(i32), ops.imm));
    dispatch.next(ip, stride(encode.OpsBinopImmToLocal), slots, frame, env, r0, fp0);
}
pub fn handle_i32_shr_u_imm_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_imm_to_local");
    dispatch.countOp("i32_to_local");
    const ops = readOps(encode.OpsBinopImmToLocal, ip);
    slots[ops.local] = RawVal.from(@as(i32, @bitCast(helper.shrU(i32, slots[ops.lhs].readAs(u32), @as(u32, @bitCast(ops.imm))))));
    dispatch.next(ip, stride(encode.OpsBinopImmToLocal), slots, frame, env, r0, fp0);
}

// ── Fused: binop-imm-to-local (Candidate E, i64) ───────────────────────────

pub fn handle_i64_add_imm_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_imm_to_local");
    dispatch.countOp("i64_to_local");
    const ops = readOps(encode.OpsBinopImmToLocal64, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i64) +% ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImmToLocal64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_sub_imm_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_imm_to_local");
    dispatch.countOp("i64_to_local");
    const ops = readOps(encode.OpsBinopImmToLocal64, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i64) -% ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImmToLocal64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_mul_imm_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_imm_to_local");
    dispatch.countOp("i64_to_local");
    const ops = readOps(encode.OpsBinopImmToLocal64, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i64) *% ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImmToLocal64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_and_imm_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_imm_to_local");
    dispatch.countOp("i64_to_local");
    const ops = readOps(encode.OpsBinopImmToLocal64, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i64) & ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImmToLocal64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_or_imm_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_imm_to_local");
    dispatch.countOp("i64_to_local");
    const ops = readOps(encode.OpsBinopImmToLocal64, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i64) | ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImmToLocal64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_xor_imm_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_imm_to_local");
    dispatch.countOp("i64_to_local");
    const ops = readOps(encode.OpsBinopImmToLocal64, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i64) ^ ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImmToLocal64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_shl_imm_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_imm_to_local");
    dispatch.countOp("i64_to_local");
    const ops = readOps(encode.OpsBinopImmToLocal64, ip);
    slots[ops.local] = RawVal.from(helper.shl(slots[ops.lhs].readAs(i64), ops.imm));
    dispatch.next(ip, stride(encode.OpsBinopImmToLocal64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_shr_s_imm_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_imm_to_local");
    dispatch.countOp("i64_to_local");
    const ops = readOps(encode.OpsBinopImmToLocal64, ip);
    slots[ops.local] = RawVal.from(helper.shrS(slots[ops.lhs].readAs(i64), ops.imm));
    dispatch.next(ip, stride(encode.OpsBinopImmToLocal64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_shr_u_imm_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_imm_to_local");
    dispatch.countOp("i64_to_local");
    const ops = readOps(encode.OpsBinopImmToLocal64, ip);
    slots[ops.local] = RawVal.from(@as(i64, @bitCast(helper.shrU(i64, slots[ops.lhs].readAs(u64), @as(u64, @bitCast(ops.imm))))));
    dispatch.next(ip, stride(encode.OpsBinopImmToLocal64), slots, frame, env, r0, fp0);
}

// ── Fused: local-inplace (Candidate H, i32) ─────────────────────────────────
// local_get + const_i32 + binop + local_set (same local) → single in-place update.

pub fn handle_i32_add_local_inplace(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_local_inplace");
    const ops = readOps(encode.OpsLocalInplace, ip);
    slots[ops.local] = RawVal.from(slots[ops.local].readAs(i32) +% ops.imm);
    dispatch.next(ip, stride(encode.OpsLocalInplace), slots, frame, env, r0, fp0);
}
pub fn handle_i32_sub_local_inplace(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_local_inplace");
    const ops = readOps(encode.OpsLocalInplace, ip);
    slots[ops.local] = RawVal.from(slots[ops.local].readAs(i32) -% ops.imm);
    dispatch.next(ip, stride(encode.OpsLocalInplace), slots, frame, env, r0, fp0);
}
pub fn handle_i32_mul_local_inplace(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_local_inplace");
    const ops = readOps(encode.OpsLocalInplace, ip);
    slots[ops.local] = RawVal.from(slots[ops.local].readAs(i32) *% ops.imm);
    dispatch.next(ip, stride(encode.OpsLocalInplace), slots, frame, env, r0, fp0);
}
pub fn handle_i32_and_local_inplace(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_local_inplace");
    const ops = readOps(encode.OpsLocalInplace, ip);
    slots[ops.local] = RawVal.from(slots[ops.local].readAs(i32) & ops.imm);
    dispatch.next(ip, stride(encode.OpsLocalInplace), slots, frame, env, r0, fp0);
}
pub fn handle_i32_or_local_inplace(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_local_inplace");
    const ops = readOps(encode.OpsLocalInplace, ip);
    slots[ops.local] = RawVal.from(slots[ops.local].readAs(i32) | ops.imm);
    dispatch.next(ip, stride(encode.OpsLocalInplace), slots, frame, env, r0, fp0);
}
pub fn handle_i32_xor_local_inplace(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_local_inplace");
    const ops = readOps(encode.OpsLocalInplace, ip);
    slots[ops.local] = RawVal.from(slots[ops.local].readAs(i32) ^ ops.imm);
    dispatch.next(ip, stride(encode.OpsLocalInplace), slots, frame, env, r0, fp0);
}
pub fn handle_i32_shl_local_inplace(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_local_inplace");
    const ops = readOps(encode.OpsLocalInplace, ip);
    slots[ops.local] = RawVal.from(helper.shl(slots[ops.local].readAs(i32), ops.imm));
    dispatch.next(ip, stride(encode.OpsLocalInplace), slots, frame, env, r0, fp0);
}
pub fn handle_i32_shr_s_local_inplace(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_local_inplace");
    const ops = readOps(encode.OpsLocalInplace, ip);
    slots[ops.local] = RawVal.from(helper.shrS(slots[ops.local].readAs(i32), ops.imm));
    dispatch.next(ip, stride(encode.OpsLocalInplace), slots, frame, env, r0, fp0);
}
pub fn handle_i32_shr_u_local_inplace(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i32_local_inplace");
    const ops = readOps(encode.OpsLocalInplace, ip);
    slots[ops.local] = RawVal.from(@as(i32, @bitCast(helper.shrU(i32, slots[ops.local].readAs(u32), @as(u32, @bitCast(ops.imm))))));
    dispatch.next(ip, stride(encode.OpsLocalInplace), slots, frame, env, r0, fp0);
}

// ── Fused: local-inplace (Candidate H, i64) ─────────────────────────────────

pub fn handle_i64_add_local_inplace(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_local_inplace");
    const ops = readOps(encode.OpsLocalInplace64, ip);
    slots[ops.local] = RawVal.from(slots[ops.local].readAs(i64) +% ops.imm);
    dispatch.next(ip, stride(encode.OpsLocalInplace64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_sub_local_inplace(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_local_inplace");
    const ops = readOps(encode.OpsLocalInplace64, ip);
    slots[ops.local] = RawVal.from(slots[ops.local].readAs(i64) -% ops.imm);
    dispatch.next(ip, stride(encode.OpsLocalInplace64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_mul_local_inplace(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_local_inplace");
    const ops = readOps(encode.OpsLocalInplace64, ip);
    slots[ops.local] = RawVal.from(slots[ops.local].readAs(i64) *% ops.imm);
    dispatch.next(ip, stride(encode.OpsLocalInplace64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_and_local_inplace(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_local_inplace");
    const ops = readOps(encode.OpsLocalInplace64, ip);
    slots[ops.local] = RawVal.from(slots[ops.local].readAs(i64) & ops.imm);
    dispatch.next(ip, stride(encode.OpsLocalInplace64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_or_local_inplace(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_local_inplace");
    const ops = readOps(encode.OpsLocalInplace64, ip);
    slots[ops.local] = RawVal.from(slots[ops.local].readAs(i64) | ops.imm);
    dispatch.next(ip, stride(encode.OpsLocalInplace64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_xor_local_inplace(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_local_inplace");
    const ops = readOps(encode.OpsLocalInplace64, ip);
    slots[ops.local] = RawVal.from(slots[ops.local].readAs(i64) ^ ops.imm);
    dispatch.next(ip, stride(encode.OpsLocalInplace64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_shl_local_inplace(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_local_inplace");
    const ops = readOps(encode.OpsLocalInplace64, ip);
    slots[ops.local] = RawVal.from(helper.shl(slots[ops.local].readAs(i64), ops.imm));
    dispatch.next(ip, stride(encode.OpsLocalInplace64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_shr_s_local_inplace(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_local_inplace");
    const ops = readOps(encode.OpsLocalInplace64, ip);
    slots[ops.local] = RawVal.from(helper.shrS(slots[ops.local].readAs(i64), ops.imm));
    dispatch.next(ip, stride(encode.OpsLocalInplace64), slots, frame, env, r0, fp0);
}
pub fn handle_i64_shr_u_local_inplace(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("i64_local_inplace");
    const ops = readOps(encode.OpsLocalInplace64, ip);
    slots[ops.local] = RawVal.from(@as(i64, @bitCast(helper.shrU(i64, slots[ops.local].readAs(u64), @as(u64, @bitCast(ops.imm))))));
    dispatch.next(ip, stride(encode.OpsLocalInplace64), slots, frame, env, r0, fp0);
}

// ── Fused: compare-imm-jump (Candidate G) ───────────────────────────────────
// Inline helpers for i32 and i64 compare-imm-jump.

inline fn cmpImmJumpI32(
    comptime op: enum { eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u },
    ip: [*]u8,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
    r0: u64,
    fp0: f64,
) void {
    const ops = readOps(encode.OpsCompareImmJump, ip);
    const taken = switch (op) {
        .eq => slots[ops.lhs].readAs(i32) == ops.imm,
        .ne => slots[ops.lhs].readAs(i32) != ops.imm,
        .lt_s => slots[ops.lhs].readAs(i32) < ops.imm,
        .lt_u => slots[ops.lhs].readAs(u32) < @as(u32, @bitCast(ops.imm)),
        .gt_s => slots[ops.lhs].readAs(i32) > ops.imm,
        .gt_u => slots[ops.lhs].readAs(u32) > @as(u32, @bitCast(ops.imm)),
        .le_s => slots[ops.lhs].readAs(i32) <= ops.imm,
        .le_u => slots[ops.lhs].readAs(u32) <= @as(u32, @bitCast(ops.imm)),
        .ge_s => slots[ops.lhs].readAs(i32) >= ops.imm,
        .ge_u => slots[ops.lhs].readAs(u32) >= @as(u32, @bitCast(ops.imm)),
    };
    if (!taken) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsCompareImmJump), slots, frame, env, r0, fp0);
    }
}

inline fn cmpImmJumpI64(
    comptime op: enum { eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u },
    ip: [*]u8,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
    r0: u64,
    fp0: f64,
) void {
    const ops = readOps(encode.OpsCompareImmJump64, ip);
    const taken = switch (op) {
        .eq => slots[ops.lhs].readAs(i64) == ops.imm,
        .ne => slots[ops.lhs].readAs(i64) != ops.imm,
        .lt_s => slots[ops.lhs].readAs(i64) < ops.imm,
        .lt_u => slots[ops.lhs].readAs(u64) < @as(u64, @bitCast(ops.imm)),
        .gt_s => slots[ops.lhs].readAs(i64) > ops.imm,
        .gt_u => slots[ops.lhs].readAs(u64) > @as(u64, @bitCast(ops.imm)),
        .le_s => slots[ops.lhs].readAs(i64) <= ops.imm,
        .le_u => slots[ops.lhs].readAs(u64) <= @as(u64, @bitCast(ops.imm)),
        .ge_s => slots[ops.lhs].readAs(i64) >= ops.imm,
        .ge_u => slots[ops.lhs].readAs(u64) >= @as(u64, @bitCast(ops.imm)),
    };
    if (!taken) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsCompareImmJump64), slots, frame, env, r0, fp0);
    }
}

pub fn handle_i32_eq_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32(.eq, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_ne_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32(.ne, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_lt_s_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32(.lt_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_lt_u_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32(.lt_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_gt_s_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32(.gt_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_gt_u_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32(.gt_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_le_s_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32(.le_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_le_u_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32(.le_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_ge_s_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32(.ge_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_ge_u_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32(.ge_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_eq_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64(.eq, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_ne_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64(.ne, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_lt_s_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64(.lt_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_lt_u_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64(.lt_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_gt_s_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64(.gt_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_gt_u_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64(.gt_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_le_s_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64(.le_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_le_u_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64(.le_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_ge_s_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64(.ge_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_ge_u_imm_jump_if_false(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64(.ge_u, ip, slots, frame, env, r0, fp0);
}

// ── compare-imm-jump, true-branch helpers (Peephole J-imm) ──────────────────

inline fn cmpImmJumpI32True(
    comptime op: enum { eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u },
    ip: [*]u8,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
    r0: u64,
    fp0: f64,
) void {
    const ops = readOps(encode.OpsCompareImmJump, ip);
    const taken = switch (op) {
        .eq => slots[ops.lhs].readAs(i32) == ops.imm,
        .ne => slots[ops.lhs].readAs(i32) != ops.imm,
        .lt_s => slots[ops.lhs].readAs(i32) < ops.imm,
        .lt_u => slots[ops.lhs].readAs(u32) < @as(u32, @bitCast(ops.imm)),
        .gt_s => slots[ops.lhs].readAs(i32) > ops.imm,
        .gt_u => slots[ops.lhs].readAs(u32) > @as(u32, @bitCast(ops.imm)),
        .le_s => slots[ops.lhs].readAs(i32) <= ops.imm,
        .le_u => slots[ops.lhs].readAs(u32) <= @as(u32, @bitCast(ops.imm)),
        .ge_s => slots[ops.lhs].readAs(i32) >= ops.imm,
        .ge_u => slots[ops.lhs].readAs(u32) >= @as(u32, @bitCast(ops.imm)),
    };
    if (taken) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsCompareImmJump), slots, frame, env, r0, fp0);
    }
}

inline fn cmpImmJumpI64True(
    comptime op: enum { eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u },
    ip: [*]u8,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
    r0: u64,
    fp0: f64,
) void {
    const ops = readOps(encode.OpsCompareImmJump64, ip);
    const taken = switch (op) {
        .eq => slots[ops.lhs].readAs(i64) == ops.imm,
        .ne => slots[ops.lhs].readAs(i64) != ops.imm,
        .lt_s => slots[ops.lhs].readAs(i64) < ops.imm,
        .lt_u => slots[ops.lhs].readAs(u64) < @as(u64, @bitCast(ops.imm)),
        .gt_s => slots[ops.lhs].readAs(i64) > ops.imm,
        .gt_u => slots[ops.lhs].readAs(u64) > @as(u64, @bitCast(ops.imm)),
        .le_s => slots[ops.lhs].readAs(i64) <= ops.imm,
        .le_u => slots[ops.lhs].readAs(u64) <= @as(u64, @bitCast(ops.imm)),
        .ge_s => slots[ops.lhs].readAs(i64) >= ops.imm,
        .ge_u => slots[ops.lhs].readAs(u64) >= @as(u64, @bitCast(ops.imm)),
    };
    if (taken) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsCompareImmJump64), slots, frame, env, r0, fp0);
    }
}

pub fn handle_i32_eq_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32True(.eq, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_ne_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32True(.ne, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_lt_s_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32True(.lt_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_lt_u_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32True(.lt_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_gt_s_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32True(.gt_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_gt_u_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32True(.gt_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_le_s_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32True(.le_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_le_u_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32True(.le_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_ge_s_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32True(.ge_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i32_ge_u_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI32True(.ge_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_eq_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64True(.eq, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_ne_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64True(.ne, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_lt_s_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64True(.lt_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_lt_u_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64True(.lt_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_gt_s_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64True(.gt_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_gt_u_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64True(.gt_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_le_s_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64True(.le_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_le_u_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64True(.le_u, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_ge_s_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64True(.ge_s, ip, slots, frame, env, r0, fp0);
}
pub fn handle_i64_ge_u_imm_jump_if_true(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("jump");

    cmpImmJumpI64True(.ge_u, ip, slots, frame, env, r0, fp0);
}

// ── Fused: const + local_set → const_to_local ────────────────────────────────

pub fn handle_i32_const_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("const_to_local");
    const ops = readOps(encode.OpsConstToLocal32, ip);
    slots[ops.local] = RawVal.from(ops.value);
    dispatch.next(ip, stride(encode.OpsConstToLocal32), slots, frame, env, r0, fp0);
}

pub fn handle_i64_const_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("const_to_local");
    const ops = readOps(encode.OpsConstToLocal64, ip);
    slots[ops.local] = RawVal.from(ops.value);
    dispatch.next(ip, stride(encode.OpsConstToLocal64), slots, frame, env, r0, fp0);
}

// ── Fused: global_get + local_set → global_get_to_local ─────────────────────

pub fn handle_global_get_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("global_to_local");
    const ops = readOps(encode.OpsGlobalGetToLocal, ip);
    slots[ops.local] = env.globals[ops.global_idx].getRawValue();
    dispatch.next(ip, stride(encode.OpsGlobalGetToLocal), slots, frame, env, r0, fp0);
}

// ── Fused: load + local_set → load_to_local ──────────────────────────────────

pub fn handle_i32_load_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("load_to_local");
    const ops = readOps(encode.OpsLoadToLocal, ip);
    const mem = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, mem) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.local] = RawVal.from(std.mem.readInt(i32, mem[ea..][0..4], .little));
    dispatch.next(ip, stride(encode.OpsLoadToLocal), slots, frame, env, r0, fp0);
}

pub fn handle_i64_load_to_local(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    dispatch.countOp("load_to_local");
    const ops = readOps(encode.OpsLoadToLocal, ip);
    const mem = frame.memSlice();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 8, mem) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.local] = RawVal.from(std.mem.readInt(i64, mem[ea..][0..8], .little));
    dispatch.next(ip, stride(encode.OpsLoadToLocal), slots, frame, env, r0, fp0);
}

/// handlers.zig — M3 threaded-dispatch instruction handlers
///
/// Each public `handle_*` function is an instruction handler with the
/// unified Handler signature.  At the end of every non-terminating handler
/// the `dispatch.next()` helper reads the handler pointer embedded at the
/// next instruction and tail-calls it.
const std = @import("std");
const ir = @import("../compiler/ir.zig");
const encode = @import("../compiler/encode.zig");
const dispatch = @import("dispatch.zig");
const vm_root = @import("root.zig");
const gc_mod = @import("gc/root.zig");
const core = @import("core");
const store_mod = @import("../wasmz/store.zig");
const host_mod = @import("../wasmz/host.zig");
const module_mod = @import("../wasmz/module.zig");

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
inline fn readOps(comptime T: type, ip: [*]align(8) u8) T {
    if (@sizeOf(T) == 0) return .{};
    return @as(*const T, @ptrCast(@alignCast(ip + HANDLER_SIZE))).*;
}

/// Instruction stride: handler pointer + operand bytes.
inline fn stride(comptime OpsT: type) usize {
    return std.mem.alignForward(usize, HANDLER_SIZE + @sizeOf(OpsT), 8);
}

/// Compute effective address with bounds check.
/// Returns null if out-of-bounds.
inline fn effectiveAddr(slots: [*]RawVal, addr_slot: u32, offset: u32, size: usize, mem: []const u8) ?u32 {
    const base = slots[addr_slot].readAs(u32);
    const ea = base +% offset;
    if (@as(usize, ea) + size > mem.len) return null;
    return ea;
}

inline fn trapReturn(frame: *DispatchState, code: core.TrapCode) void {
    frame.result = .{ .trap = Trap.fromTrapCode(code) };
}

inline fn UnsignedOf(comptime T: type) type {
    return std.meta.Int(.unsigned, @bitSizeOf(T));
}

inline fn trapFromTruncateError(err: helper.TruncateError) Trap {
    return Trap.fromTrapCode(switch (err) {
        error.NaN => .BadConversionToInteger,
        error.OutOfRange => .IntegerOverflow,
    });
}

// ── Terminators ──────────────────────────────────────────────────────────────

pub fn handle_unreachable(
    ip: [*]align(8) u8,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
) callconv(.c) void {
    _ = ip;
    _ = slots;
    _ = env;
    trapReturn(frame, .UnreachableCodeReached);
}

pub fn handle_ret(
    ip: [*]align(8) u8,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
) callconv(.c) void {
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
    dispatch.dispatch(caller.ip, caller.slots.ptr, frame, env);
}

// ── Constants ────────────────────────────────────────────────────────────────

pub fn handle_const_i32(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsConstI32, ip);
    slots[ops.dst] = RawVal.from(ops.value);
    dispatch.next(ip, stride(encode.OpsConstI32), slots, frame, env);
}

pub fn handle_const_i64(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsConstI64, ip);
    slots[ops.dst] = RawVal.from(ops.value);
    dispatch.next(ip, stride(encode.OpsConstI64), slots, frame, env);
}

pub fn handle_const_f32(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsConstF32, ip);
    slots[ops.dst] = RawVal.from(ops.value);
    dispatch.next(ip, stride(encode.OpsConstF32), slots, frame, env);
}

pub fn handle_const_f64(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsConstF64, ip);
    slots[ops.dst] = RawVal.from(ops.value);
    dispatch.next(ip, stride(encode.OpsConstF64), slots, frame, env);
}

pub fn handle_const_v128(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsConstV128, ip);
    const sv = core.SimdVal.fromV128(.{ .bytes = ops.value });
    sv.toSlots(&slots[ops.dst], &slots[ops.dst + 1]);
    dispatch.next(ip, stride(encode.OpsConstV128), slots, frame, env);
}

pub fn handle_const_ref_null(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDst, ip);
    slots[ops.dst] = RawVal.fromBits64(0);
    dispatch.next(ip, stride(encode.OpsDst), slots, frame, env);
}

// ── References ───────────────────────────────────────────────────────────────

pub fn handle_ref_is_null(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    const is_null: i32 = if (slots[ops.src].readAs(u64) == 0) 1 else 0;
    slots[ops.dst] = RawVal.from(is_null);
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_ref_func(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsRefFunc, ip);
    slots[ops.dst] = RawVal.fromBits64(@as(u64, ops.func_idx) + 1);
    dispatch.next(ip, stride(encode.OpsRefFunc), slots, frame, env);
}

pub fn handle_ref_eq(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const eq: i32 = if (slots[ops.lhs].readAs(u64) == slots[ops.rhs].readAs(u64)) 1 else 0;
    slots[ops.dst] = RawVal.from(eq);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}

// ── Variables ────────────────────────────────────────────────────────────────

pub fn handle_local_get(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsLocalGet, ip);
    slots[ops.dst] = slots[ops.local];
    dispatch.next(ip, stride(encode.OpsLocalGet), slots, frame, env);
}

pub fn handle_local_set(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsLocalSet, ip);
    slots[ops.local] = slots[ops.src];
    dispatch.next(ip, stride(encode.OpsLocalSet), slots, frame, env);
}

pub fn handle_global_get(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsGlobalGet, ip);
    slots[ops.dst] = env.globals[ops.global_idx].getRawValue();
    dispatch.next(ip, stride(encode.OpsGlobalGet), slots, frame, env);
}

pub fn handle_global_set(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsGlobalSet, ip);
    env.globals[ops.global_idx].value = slots[ops.src];
    dispatch.next(ip, stride(encode.OpsGlobalSet), slots, frame, env);
}

pub fn handle_copy(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsCopy, ip);
    slots[ops.dst] = slots[ops.src];
    dispatch.next(ip, stride(encode.OpsCopy), slots, frame, env);
}

// ── Control flow ─────────────────────────────────────────────────────────────

pub fn handle_jump(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsJump, ip);
    // rel_target is a signed byte offset from instruction start
    const target_ip: [*]align(8) u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
    dispatch.dispatch(target_ip, slots, frame, env);
}

pub fn handle_jump_if_z(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsJumpIfZ, ip);
    if (slots[ops.cond].readAs(i32) == 0) {
        const target_ip: [*]align(8) u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env);
    } else {
        dispatch.next(ip, stride(encode.OpsJumpIfZ), slots, frame, env);
    }
}

pub fn handle_jump_table(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsJumpTable, ip);
    const idx = slots[ops.index].readAs(u32);
    const entry = if (idx < ops.targets_len) idx else ops.targets_len;
    const func = frame.callStackTop().func;
    const target = func.br_table_targets[ops.targets_start + entry];
    const target_ip: [*]align(8) u8 = @alignCast(func.code.ptr + target);
    dispatch.dispatch(target_ip, slots, frame, env);
}

pub fn handle_select(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsSelect, ip);
    const cond = slots[ops.cond].readAs(i32);
    slots[ops.dst] = if (cond != 0) slots[ops.val1] else slots[ops.val2];
    dispatch.next(ip, stride(encode.OpsSelect), slots, frame, env);
}

// ── i32 binary arithmetic ────────────────────────────────────────────────────

fn binOpI32(comptime op: enum { add, sub, mul }, slots: [*]RawVal, ops: encode.OpsDstLhsRhs) void {
    const lhs = slots[ops.lhs].readAs(i32);
    const rhs = slots[ops.rhs].readAs(i32);
    slots[ops.dst] = RawVal.from(switch (op) {
        .add => lhs +% rhs,
        .sub => lhs -% rhs,
        .mul => lhs *% rhs,
    });
}

pub fn handle_i32_add(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    binOpI32(.add, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i32_sub(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    binOpI32(.sub, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i32_mul(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    binOpI32(.mul, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}

pub fn handle_i32_div_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.divS(slots[ops.lhs].readAs(i32), slots[ops.rhs].readAs(i32)) catch |e| {
        trapReturn(frame, switch (e) {
            error.IntegerDivisionByZero => .IntegerDivisionByZero,
            error.IntegerOverflow => .IntegerOverflow,
        });
        return;
    };
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}

pub fn handle_i32_div_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.divU(i32, slots[ops.lhs].readAs(u32), slots[ops.rhs].readAs(u32)) catch {
        trapReturn(frame, .IntegerDivisionByZero);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i32, @bitCast(result)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}

pub fn handle_i32_rem_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.remS(slots[ops.lhs].readAs(i32), slots[ops.rhs].readAs(i32)) catch {
        trapReturn(frame, .IntegerDivisionByZero);
        return;
    };
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}

pub fn handle_i32_rem_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.remU(i32, slots[ops.lhs].readAs(u32), slots[ops.rhs].readAs(u32)) catch {
        trapReturn(frame, .IntegerDivisionByZero);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i32, @bitCast(result)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}

pub fn handle_i32_and(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i32) & slots[ops.rhs].readAs(i32));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i32_or(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i32) | slots[ops.rhs].readAs(i32));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i32_xor(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i32) ^ slots[ops.rhs].readAs(i32));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i32_shl(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(helper.shl(slots[ops.lhs].readAs(i32), slots[ops.rhs].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i32_shr_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(helper.shrS(slots[ops.lhs].readAs(i32), slots[ops.rhs].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i32_shr_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(@as(i32, @bitCast(helper.shrU(i32, slots[ops.lhs].readAs(u32), slots[ops.rhs].readAs(u32)))));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i32_rotl(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(helper.rotl(slots[ops.lhs].readAs(i32), slots[ops.rhs].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i32_rotr(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(helper.rotr(slots[ops.lhs].readAs(i32), slots[ops.rhs].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}

// ── i64 binary arithmetic ────────────────────────────────────────────────────

pub fn handle_i64_add(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i64) +% slots[ops.rhs].readAs(i64));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_sub(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i64) -% slots[ops.rhs].readAs(i64));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_mul(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i64) *% slots[ops.rhs].readAs(i64));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}

pub fn handle_i64_div_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.divS(slots[ops.lhs].readAs(i64), slots[ops.rhs].readAs(i64)) catch |e| {
        trapReturn(frame, switch (e) {
            error.IntegerDivisionByZero => .IntegerDivisionByZero,
            error.IntegerOverflow => .IntegerOverflow,
        });
        return;
    };
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_div_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.divU(i64, slots[ops.lhs].readAs(u64), slots[ops.rhs].readAs(u64)) catch {
        trapReturn(frame, .IntegerDivisionByZero);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i64, @bitCast(result)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_rem_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.remS(slots[ops.lhs].readAs(i64), slots[ops.rhs].readAs(i64)) catch {
        trapReturn(frame, .IntegerDivisionByZero);
        return;
    };
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_rem_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    const result = helper.remU(i64, slots[ops.lhs].readAs(u64), slots[ops.rhs].readAs(u64)) catch {
        trapReturn(frame, .IntegerDivisionByZero);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i64, @bitCast(result)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_and(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i64) & slots[ops.rhs].readAs(i64));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_or(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i64) | slots[ops.rhs].readAs(i64));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_xor(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i64) ^ slots[ops.rhs].readAs(i64));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_shl(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(helper.shl(slots[ops.lhs].readAs(i64), slots[ops.rhs].readAs(i64)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_shr_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(helper.shrS(slots[ops.lhs].readAs(i64), slots[ops.rhs].readAs(i64)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_shr_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(@as(i64, @bitCast(helper.shrU(i64, slots[ops.lhs].readAs(u64), slots[ops.rhs].readAs(u64)))));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_rotl(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(helper.rotl(slots[ops.lhs].readAs(i64), slots[ops.rhs].readAs(i64)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_rotr(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(helper.rotr(slots[ops.lhs].readAs(i64), slots[ops.rhs].readAs(i64)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}

// ── f32 binary ───────────────────────────────────────────────────────────────

pub fn handle_f32_add(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(f32) + slots[ops.rhs].readAs(f32));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f32_sub(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(f32) - slots[ops.rhs].readAs(f32));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f32_mul(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(f32) * slots[ops.rhs].readAs(f32));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f32_div(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(f32) / slots[ops.rhs].readAs(f32));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f32_min(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(helper.min(slots[ops.lhs].readAs(f32), slots[ops.rhs].readAs(f32)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f32_max(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(helper.max(slots[ops.lhs].readAs(f32), slots[ops.rhs].readAs(f32)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f32_copysign(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(helper.copySign(slots[ops.lhs].readAs(f32), slots[ops.rhs].readAs(f32)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}

// ── f64 binary ───────────────────────────────────────────────────────────────

pub fn handle_f64_add(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(f64) + slots[ops.rhs].readAs(f64));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f64_sub(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(f64) - slots[ops.rhs].readAs(f64));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f64_mul(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(f64) * slots[ops.rhs].readAs(f64));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f64_div(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(f64) / slots[ops.rhs].readAs(f64));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f64_min(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(helper.min(slots[ops.lhs].readAs(f64), slots[ops.rhs].readAs(f64)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f64_max(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(helper.max(slots[ops.lhs].readAs(f64), slots[ops.rhs].readAs(f64)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f64_copysign(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstLhsRhs, ip);
    slots[ops.dst] = RawVal.from(helper.copySign(slots[ops.lhs].readAs(f64), slots[ops.rhs].readAs(f64)));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}

// ── Integer unary ────────────────────────────────────────────────────────────

pub fn handle_i32_clz(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.leadingZeros(slots[ops.src].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_i32_ctz(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.trailingZeros(slots[ops.src].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_i32_popcnt(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.countOnes(slots[ops.src].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_i32_eqz(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.src].readAs(i32) == 0) 1 else 0));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_i64_clz(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.leadingZeros(slots[ops.src].readAs(i64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_i64_ctz(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.trailingZeros(slots[ops.src].readAs(i64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_i64_popcnt(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.countOnes(slots[ops.src].readAs(i64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_i64_eqz(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.src].readAs(i64) == 0) 1 else 0));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

// ── Float unary ──────────────────────────────────────────────────────────────

pub fn handle_f32_abs(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.abs(slots[ops.src].readAs(f32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_f32_neg(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(-slots[ops.src].readAs(f32));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_f32_ceil(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.ceil(slots[ops.src].readAs(f32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_f32_floor(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.floor(slots[ops.src].readAs(f32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_f32_trunc(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.trunc(slots[ops.src].readAs(f32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_f32_nearest(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.nearest(slots[ops.src].readAs(f32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_f32_sqrt(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.sqrt(slots[ops.src].readAs(f32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_f64_abs(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.abs(slots[ops.src].readAs(f64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_f64_neg(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(-slots[ops.src].readAs(f64));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_f64_ceil(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.ceil(slots[ops.src].readAs(f64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_f64_floor(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.floor(slots[ops.src].readAs(f64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_f64_trunc(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.trunc(slots[ops.src].readAs(f64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_f64_nearest(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.nearest(slots[ops.src].readAs(f64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}
pub fn handle_f64_sqrt(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.sqrt(slots[ops.src].readAs(f64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
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

pub fn handle_i32_eq(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI32(.eq, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i32_ne(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI32(.ne, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i32_lt_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI32(.lt_s, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i32_lt_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI32(.lt_u, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i32_gt_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI32(.gt_s, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i32_gt_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI32(.gt_u, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i32_le_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI32(.le_s, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i32_le_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI32(.le_u, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i32_ge_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI32(.ge_s, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i32_ge_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI32(.ge_u, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
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

pub fn handle_i64_eq(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI64(.eq, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_ne(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI64(.ne, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_lt_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI64(.lt_s, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_lt_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI64(.lt_u, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_gt_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI64(.gt_s, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_gt_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI64(.gt_u, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_le_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI64(.le_s, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_le_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI64(.le_u, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_ge_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI64(.ge_s, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_i64_ge_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpI64(.ge_u, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
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

pub fn handle_f32_eq(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpF32(.eq, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f32_ne(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpF32(.ne, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f32_lt(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpF32(.lt, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f32_gt(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpF32(.gt, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f32_le(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpF32(.le, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f32_ge(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpF32(.ge, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
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

pub fn handle_f64_eq(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpF64(.eq, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f64_ne(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpF64(.ne, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f64_lt(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpF64(.lt, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f64_gt(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpF64(.gt, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f64_le(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpF64(.le, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}
pub fn handle_f64_ge(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpF64(.ge, slots, readOps(encode.OpsDstLhsRhs, ip));
    dispatch.next(ip, stride(encode.OpsDstLhsRhs), slots, frame, env);
}

// ── Conversions ─────────────────────────────────────────────────────────────

inline fn reinterpretUnsignedAsSigned(comptime T: type, value: UnsignedOf(T)) T {
    return @as(T, @bitCast(value));
}

pub fn handle_i32_wrap_i64(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    const bits = @as(u32, @truncate(slots[ops.src].readAs(u64)));
    slots[ops.dst] = RawVal.from(@as(i32, @bitCast(bits)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_i64_extend_i32_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(i64, slots[ops.src].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_i64_extend_i32_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(i64, @intCast(slots[ops.src].readAs(u32))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

// Trapping truncations (float → signed int)
pub fn handle_i32_trunc_f32_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.tryTruncateInto(i32, slots[ops.src].readAs(f32)) catch |err| {
        frame.result = .{ .trap = trapFromTruncateError(err) };
        return;
    };
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_i32_trunc_f64_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.tryTruncateInto(i32, slots[ops.src].readAs(f64)) catch |err| {
        frame.result = .{ .trap = trapFromTruncateError(err) };
        return;
    };
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_i64_trunc_f32_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.tryTruncateInto(i64, slots[ops.src].readAs(f32)) catch |err| {
        frame.result = .{ .trap = trapFromTruncateError(err) };
        return;
    };
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_i64_trunc_f64_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.tryTruncateInto(i64, slots[ops.src].readAs(f64)) catch |err| {
        frame.result = .{ .trap = trapFromTruncateError(err) };
        return;
    };
    slots[ops.dst] = RawVal.from(result);
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

// Trapping truncations (float → unsigned int, stored as signed)
pub fn handle_i32_trunc_f32_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.tryTruncateInto(u32, slots[ops.src].readAs(f32)) catch |err| {
        frame.result = .{ .trap = trapFromTruncateError(err) };
        return;
    };
    slots[ops.dst] = RawVal.from(reinterpretUnsignedAsSigned(i32, result));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_i32_trunc_f64_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.tryTruncateInto(u32, slots[ops.src].readAs(f64)) catch |err| {
        frame.result = .{ .trap = trapFromTruncateError(err) };
        return;
    };
    slots[ops.dst] = RawVal.from(reinterpretUnsignedAsSigned(i32, result));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_i64_trunc_f32_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.tryTruncateInto(u64, slots[ops.src].readAs(f32)) catch |err| {
        frame.result = .{ .trap = trapFromTruncateError(err) };
        return;
    };
    slots[ops.dst] = RawVal.from(reinterpretUnsignedAsSigned(i64, result));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_i64_trunc_f64_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.tryTruncateInto(u64, slots[ops.src].readAs(f64)) catch |err| {
        frame.result = .{ .trap = trapFromTruncateError(err) };
        return;
    };
    slots[ops.dst] = RawVal.from(reinterpretUnsignedAsSigned(i64, result));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

// Saturating truncations (signed)
pub fn handle_i32_trunc_sat_f32_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.truncateSaturateInto(i32, slots[ops.src].readAs(f32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_i32_trunc_sat_f64_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.truncateSaturateInto(i32, slots[ops.src].readAs(f64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_i64_trunc_sat_f32_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.truncateSaturateInto(i64, slots[ops.src].readAs(f32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_i64_trunc_sat_f64_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.truncateSaturateInto(i64, slots[ops.src].readAs(f64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

// Saturating truncations (unsigned)
pub fn handle_i32_trunc_sat_f32_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.truncateSaturateInto(u32, slots[ops.src].readAs(f32));
    slots[ops.dst] = RawVal.from(reinterpretUnsignedAsSigned(i32, result));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_i32_trunc_sat_f64_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.truncateSaturateInto(u32, slots[ops.src].readAs(f64));
    slots[ops.dst] = RawVal.from(reinterpretUnsignedAsSigned(i32, result));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_i64_trunc_sat_f32_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.truncateSaturateInto(u64, slots[ops.src].readAs(f32));
    slots[ops.dst] = RawVal.from(reinterpretUnsignedAsSigned(i64, result));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_i64_trunc_sat_f64_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    const result = helper.truncateSaturateInto(u64, slots[ops.src].readAs(f64));
    slots[ops.dst] = RawVal.from(reinterpretUnsignedAsSigned(i64, result));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

// int → float conversions (signed)
pub fn handle_f32_convert_i32_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f32, @floatFromInt(slots[ops.src].readAs(i32))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_f32_convert_i64_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f32, @floatFromInt(slots[ops.src].readAs(i64))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_f64_convert_i32_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f64, @floatFromInt(slots[ops.src].readAs(i32))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_f64_convert_i64_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f64, @floatFromInt(slots[ops.src].readAs(i64))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

// int → float conversions (unsigned)
pub fn handle_f32_convert_i32_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f32, @floatFromInt(slots[ops.src].readAs(u32))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_f32_convert_i64_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f32, @floatFromInt(slots[ops.src].readAs(u64))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_f64_convert_i32_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f64, @floatFromInt(slots[ops.src].readAs(u32))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_f64_convert_i64_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f64, @floatFromInt(slots[ops.src].readAs(u64))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

// Float resize
pub fn handle_f32_demote_f64(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f32, @floatCast(slots[ops.src].readAs(f64))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_f64_promote_f32(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f64, @floatCast(slots[ops.src].readAs(f32))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

// Reinterpret
pub fn handle_i32_reinterpret_f32(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(i32, @bitCast(slots[ops.src].readAs(f32))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_i64_reinterpret_f64(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(i64, @bitCast(slots[ops.src].readAs(f64))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_f32_reinterpret_i32(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f32, @bitCast(slots[ops.src].readAs(i32))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_f64_reinterpret_i64(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(@as(f64, @bitCast(slots[ops.src].readAs(i64))));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

// Sign-extension
pub fn handle_i32_extend8_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.signExtendFrom(i8, slots[ops.src].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_i32_extend16_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.signExtendFrom(i16, slots[ops.src].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_i64_extend8_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.signExtendFrom(i8, slots[ops.src].readAs(i64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_i64_extend16_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.signExtendFrom(i16, slots[ops.src].readAs(i64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

pub fn handle_i64_extend32_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDstSrc, ip);
    slots[ops.dst] = RawVal.from(helper.signExtendFrom(i32, slots[ops.src].readAs(i64)));
    dispatch.next(ip, stride(encode.OpsDstSrc), slots, frame, env);
}

// ── Fused: i32 binop-imm (Candidate C) ──────────────────────────────────────

pub fn handle_i32_add_imm(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i32) +% ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env);
}
pub fn handle_i32_sub_imm(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i32) -% ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env);
}
pub fn handle_i32_mul_imm(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i32) *% ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env);
}
pub fn handle_i32_and_imm(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i32) & ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env);
}
pub fn handle_i32_or_imm(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i32) | ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env);
}
pub fn handle_i32_xor_imm(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(slots[ops.lhs].readAs(i32) ^ ops.imm);
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env);
}
pub fn handle_i32_shl_imm(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(helper.shl(slots[ops.lhs].readAs(i32), ops.imm));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env);
}
pub fn handle_i32_shr_s_imm(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(helper.shrS(slots[ops.lhs].readAs(i32), ops.imm));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env);
}
pub fn handle_i32_shr_u_imm(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, @bitCast(helper.shrU(i32, slots[ops.lhs].readAs(u32), @as(u32, @bitCast(ops.imm))))));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env);
}
// compare-imm variants (result = i32 boolean)
pub fn handle_i32_eq_imm(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(i32) == ops.imm) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env);
}
pub fn handle_i32_ne_imm(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(i32) != ops.imm) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env);
}
pub fn handle_i32_lt_s_imm(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(i32) < ops.imm) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env);
}
pub fn handle_i32_lt_u_imm(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(u32) < @as(u32, @bitCast(ops.imm))) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env);
}
pub fn handle_i32_gt_s_imm(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(i32) > ops.imm) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env);
}
pub fn handle_i32_gt_u_imm(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(u32) > @as(u32, @bitCast(ops.imm))) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env);
}
pub fn handle_i32_le_s_imm(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(i32) <= ops.imm) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env);
}
pub fn handle_i32_le_u_imm(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(u32) <= @as(u32, @bitCast(ops.imm))) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env);
}
pub fn handle_i32_ge_s_imm(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(i32) >= ops.imm) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env);
}
pub fn handle_i32_ge_u_imm(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopImm, ip);
    slots[ops.dst] = RawVal.from(@as(i32, if (slots[ops.lhs].readAs(u32) >= @as(u32, @bitCast(ops.imm))) 1 else 0));
    dispatch.next(ip, stride(encode.OpsBinopImm), slots, frame, env);
}

// ── Fused: i32 compare-jump (Candidate F) ───────────────────────────────────
// Jumps to rel_target (from instruction start) when the comparison is FALSE.

inline fn cmpJumpI32(
    comptime op: enum { eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u },
    ip: [*]align(8) u8,
    slots: [*]RawVal,
    frame: *DispatchState,
    env: *const ExecEnv,
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
        const target_ip: [*]align(8) u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env);
    } else {
        dispatch.next(ip, stride(encode.OpsCompareJump), slots, frame, env);
    }
}

pub fn handle_i32_eq_jump_if_false(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpJumpI32(.eq, ip, slots, frame, env);
}
pub fn handle_i32_ne_jump_if_false(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpJumpI32(.ne, ip, slots, frame, env);
}
pub fn handle_i32_lt_s_jump_if_false(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpJumpI32(.lt_s, ip, slots, frame, env);
}
pub fn handle_i32_lt_u_jump_if_false(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpJumpI32(.lt_u, ip, slots, frame, env);
}
pub fn handle_i32_gt_s_jump_if_false(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpJumpI32(.gt_s, ip, slots, frame, env);
}
pub fn handle_i32_gt_u_jump_if_false(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpJumpI32(.gt_u, ip, slots, frame, env);
}
pub fn handle_i32_le_s_jump_if_false(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpJumpI32(.le_s, ip, slots, frame, env);
}
pub fn handle_i32_le_u_jump_if_false(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpJumpI32(.le_u, ip, slots, frame, env);
}
pub fn handle_i32_ge_s_jump_if_false(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpJumpI32(.ge_s, ip, slots, frame, env);
}
pub fn handle_i32_ge_u_jump_if_false(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    cmpJumpI32(.ge_u, ip, slots, frame, env);
}
/// Fused i32.eqz + br_if: jumps when src != 0 (i.e. eqz is false).
pub fn handle_i32_eqz_jump_if_false(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsEqzJump, ip);
    if (slots[ops.src].readAs(i32) != 0) {
        const target_ip: [*]align(8) u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env);
    } else {
        dispatch.next(ip, stride(encode.OpsEqzJump), slots, frame, env);
    }
}

// ── Fused: i32 binop-to-local (Candidate D) ─────────────────────────────────

pub fn handle_i32_add_to_local(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i32) +% slots[ops.rhs].readAs(i32));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env);
}
pub fn handle_i32_sub_to_local(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i32) -% slots[ops.rhs].readAs(i32));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env);
}
pub fn handle_i32_mul_to_local(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i32) *% slots[ops.rhs].readAs(i32));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env);
}
pub fn handle_i32_and_to_local(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i32) & slots[ops.rhs].readAs(i32));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env);
}
pub fn handle_i32_or_to_local(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i32) | slots[ops.rhs].readAs(i32));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env);
}
pub fn handle_i32_xor_to_local(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(slots[ops.lhs].readAs(i32) ^ slots[ops.rhs].readAs(i32));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env);
}
pub fn handle_i32_shl_to_local(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(helper.shl(slots[ops.lhs].readAs(i32), slots[ops.rhs].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env);
}
pub fn handle_i32_shr_s_to_local(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(helper.shrS(slots[ops.lhs].readAs(i32), slots[ops.rhs].readAs(i32)));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env);
}
pub fn handle_i32_shr_u_to_local(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsBinopToLocal, ip);
    slots[ops.local] = RawVal.from(@as(i32, @bitCast(helper.shrU(i32, slots[ops.lhs].readAs(u32), slots[ops.rhs].readAs(u32)))));
    dispatch.next(ip, stride(encode.OpsBinopToLocal), slots, frame, env);
}

// ── Memory Loads ────────────────────────────────────────────────────────────

pub fn handle_i32_load(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsLoad, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.dst] = RawVal.from(std.mem.readInt(i32, memory[ea..][0..4], .little));
    dispatch.next(ip, stride(encode.OpsLoad), slots, frame, env);
}

pub fn handle_i32_load8_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsLoad, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 1, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i32, @as(i8, @bitCast(memory[ea]))));
    dispatch.next(ip, stride(encode.OpsLoad), slots, frame, env);
}

pub fn handle_i32_load8_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsLoad, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 1, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i32, memory[ea]));
    dispatch.next(ip, stride(encode.OpsLoad), slots, frame, env);
}

pub fn handle_i32_load16_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsLoad, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 2, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const half: i16 = @bitCast(std.mem.readInt(u16, memory[ea..][0..2], .little));
    slots[ops.dst] = RawVal.from(@as(i32, half));
    dispatch.next(ip, stride(encode.OpsLoad), slots, frame, env);
}

pub fn handle_i32_load16_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsLoad, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 2, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i32, std.mem.readInt(u16, memory[ea..][0..2], .little)));
    dispatch.next(ip, stride(encode.OpsLoad), slots, frame, env);
}

pub fn handle_i64_load(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsLoad, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 8, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.dst] = RawVal.from(std.mem.readInt(i64, memory[ea..][0..8], .little));
    dispatch.next(ip, stride(encode.OpsLoad), slots, frame, env);
}

pub fn handle_i64_load8_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsLoad, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 1, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i64, @as(i8, @bitCast(memory[ea]))));
    dispatch.next(ip, stride(encode.OpsLoad), slots, frame, env);
}

pub fn handle_i64_load8_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsLoad, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 1, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i64, memory[ea]));
    dispatch.next(ip, stride(encode.OpsLoad), slots, frame, env);
}

pub fn handle_i64_load16_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsLoad, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 2, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const half: i16 = @bitCast(std.mem.readInt(u16, memory[ea..][0..2], .little));
    slots[ops.dst] = RawVal.from(@as(i64, half));
    dispatch.next(ip, stride(encode.OpsLoad), slots, frame, env);
}

pub fn handle_i64_load16_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsLoad, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 2, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i64, std.mem.readInt(u16, memory[ea..][0..2], .little)));
    dispatch.next(ip, stride(encode.OpsLoad), slots, frame, env);
}

pub fn handle_i64_load32_s(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsLoad, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const word: i32 = @bitCast(std.mem.readInt(u32, memory[ea..][0..4], .little));
    slots[ops.dst] = RawVal.from(@as(i64, word));
    dispatch.next(ip, stride(encode.OpsLoad), slots, frame, env);
}

pub fn handle_i64_load32_u(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsLoad, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i64, std.mem.readInt(u32, memory[ea..][0..4], .little)));
    dispatch.next(ip, stride(encode.OpsLoad), slots, frame, env);
}

pub fn handle_f32_load(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsLoad, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const bits = std.mem.readInt(u32, memory[ea..][0..4], .little);
    slots[ops.dst] = RawVal.from(@as(f32, @bitCast(bits)));
    dispatch.next(ip, stride(encode.OpsLoad), slots, frame, env);
}

pub fn handle_f64_load(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsLoad, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 8, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    const bits = std.mem.readInt(u64, memory[ea..][0..8], .little);
    slots[ops.dst] = RawVal.from(@as(f64, @bitCast(bits)));
    dispatch.next(ip, stride(encode.OpsLoad), slots, frame, env);
}

// ── Memory Stores ───────────────────────────────────────────────────────────

pub fn handle_i32_store(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsStore, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(i32, memory[ea..][0..4], slots[ops.src].readAs(i32), .little);
    dispatch.next(ip, stride(encode.OpsStore), slots, frame, env);
}

pub fn handle_i32_store8(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsStore, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 1, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    memory[ea] = @truncate(@as(u32, @bitCast(slots[ops.src].readAs(i32))));
    dispatch.next(ip, stride(encode.OpsStore), slots, frame, env);
}

pub fn handle_i32_store16(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsStore, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 2, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(u16, memory[ea..][0..2], @truncate(@as(u32, @bitCast(slots[ops.src].readAs(i32)))), .little);
    dispatch.next(ip, stride(encode.OpsStore), slots, frame, env);
}

pub fn handle_i64_store(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsStore, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 8, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(i64, memory[ea..][0..8], slots[ops.src].readAs(i64), .little);
    dispatch.next(ip, stride(encode.OpsStore), slots, frame, env);
}

pub fn handle_i64_store8(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsStore, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 1, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    memory[ea] = @truncate(@as(u64, @bitCast(slots[ops.src].readAs(i64))));
    dispatch.next(ip, stride(encode.OpsStore), slots, frame, env);
}

pub fn handle_i64_store16(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsStore, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 2, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(u16, memory[ea..][0..2], @truncate(@as(u64, @bitCast(slots[ops.src].readAs(i64)))), .little);
    dispatch.next(ip, stride(encode.OpsStore), slots, frame, env);
}

pub fn handle_i64_store32(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsStore, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(u32, memory[ea..][0..4], @truncate(@as(u64, @bitCast(slots[ops.src].readAs(i64)))), .little);
    dispatch.next(ip, stride(encode.OpsStore), slots, frame, env);
}

pub fn handle_f32_store(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsStore, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 4, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(u32, memory[ea..][0..4], @as(u32, @bitCast(slots[ops.src].readAs(f32))), .little);
    dispatch.next(ip, stride(encode.OpsStore), slots, frame, env);
}

pub fn handle_f64_store(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsStore, ip);
    const memory = env.memory.bytes();
    const ea = effectiveAddr(slots, ops.addr, ops.offset, 8, memory) orelse {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    };
    std.mem.writeInt(u64, memory[ea..][0..8], @as(u64, @bitCast(slots[ops.src].readAs(f64))), .little);
    dispatch.next(ip, stride(encode.OpsStore), slots, frame, env);
}

// ── Bulk Memory ─────────────────────────────────────────────────────────────

pub fn handle_memory_size(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsMemorySize, ip);
    const page_count: i32 = @intCast(env.memory.pageCount());
    slots[ops.dst] = RawVal.from(page_count);
    dispatch.next(ip, stride(encode.OpsMemorySize), slots, frame, env);
}

pub fn handle_memory_grow(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsMemoryGrow, ip);
    const delta = @as(u32, @bitCast(slots[ops.delta].readAs(i32)));
    if (delta > 0) {
        if (env.memory_budget) |b| {
            const additional_bytes = @as(u64, delta) * core.WASM_PAGE_SIZE;
            if (!b.canGrow(additional_bytes)) {
                slots[ops.dst] = RawVal.from(@as(i32, -1));
                dispatch.next(ip, stride(encode.OpsMemoryGrow), slots, frame, env);
                return;
            }
        }
    }
    const old = env.memory.grow(delta);
    const result: i32 = if (old == std.math.maxInt(u32)) -1 else @intCast(old);
    slots[ops.dst] = RawVal.from(result);
    if (result != -1) {
        if (env.memory_budget) |b| {
            b.recordLinearGrow(env.memory.byteLen());
        }
    }
    dispatch.next(ip, stride(encode.OpsMemoryGrow), slots, frame, env);
}

pub fn handle_memory_init(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsMemoryInit, ip);
    const memory = env.memory.bytes();
    const dst_addr = slots[ops.dst_addr].readAs(u32);
    const src_offset = slots[ops.src_offset].readAs(u32);
    const len = slots[ops.len].readAs(u32);

    if (ops.segment_idx >= env.data_segments.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }
    if (env.data_segments_dropped[ops.segment_idx]) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }

    const segment = env.data_segments[ops.segment_idx];
    const src_end = src_offset +% len;
    const dst_end = dst_addr +% len;
    if (src_end > segment.data.len or dst_end > memory.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }
    @memcpy(memory[dst_addr..][0..len], segment.data[src_offset..][0..len]);
    dispatch.next(ip, stride(encode.OpsMemoryInit), slots, frame, env);
}

pub fn handle_data_drop(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsDataDrop, ip);
    if (ops.segment_idx >= env.data_segments.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }
    env.data_segments_dropped[ops.segment_idx] = true;
    dispatch.next(ip, stride(encode.OpsDataDrop), slots, frame, env);
}

pub fn handle_memory_copy(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsMemoryCopy, ip);
    const memory = env.memory.bytes();
    const dst_addr = slots[ops.dst_addr].readAs(u32);
    const src_addr = slots[ops.src_addr].readAs(u32);
    const len = slots[ops.len].readAs(u32);

    const src_end = src_addr +% len;
    const dst_end = dst_addr +% len;
    if (src_end > memory.len or dst_end > memory.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }
    if (len > 0) {
        if (dst_addr <= src_addr) {
            std.mem.copyForwards(u8, memory[dst_addr .. dst_addr + len], memory[src_addr .. src_addr + len]);
        } else {
            std.mem.copyBackwards(u8, memory[dst_addr .. dst_addr + len], memory[src_addr .. src_addr + len]);
        }
    }
    dispatch.next(ip, stride(encode.OpsMemoryCopy), slots, frame, env);
}

pub fn handle_memory_fill(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsMemoryFill, ip);
    const memory = env.memory.bytes();
    const dst_addr = slots[ops.dst_addr].readAs(u32);
    const value = slots[ops.value].readAs(u32);
    const len = slots[ops.len].readAs(u32);

    const dst_end = dst_addr +% len;
    if (dst_end > memory.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }
    @memset(memory[dst_addr .. dst_addr + len], @truncate(value));
    dispatch.next(ip, stride(encode.OpsMemoryFill), slots, frame, env);
}

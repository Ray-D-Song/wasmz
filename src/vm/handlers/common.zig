/// common.zig — shared helpers for threaded-dispatch handlers
///
/// Each public `handle_*` function is an instruction handler with the
/// unified Handler signature.  At the end of every non-terminating handler
/// the `dispatch.next()` helper reads the handler pointer embedded at the
/// next instruction and tail-calls it.
const std = @import("std");
const builtin = @import("builtin");
const ir = @import("../../compiler/ir.zig");
const encode = @import("../../compiler/encode/encode.zig");
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

// Helpers

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

// currentRssBytes() moved to src/utils/profiling.zig (unified profiling module).
// Callers should use profiling.currentRssBytes() instead.

/// Compute effective address with bounds check.
/// Returns null if out-of-bounds.
pub inline fn effectiveAddr(slots: [*]RawVal, addr_slot: Slot, offset: u32, size: usize, mem: []const u8, memory64: bool) ?usize {
    const base: u64 = if (memory64) @bitCast(slots[addr_slot].readAs(i64)) else slots[addr_slot].readAs(u32);
    const ea = std.math.add(u64, base, offset) catch return null;
    const end = std.math.add(u64, ea, @as(u64, size)) catch return null;
    if (end > mem.len) return null;
    return @intCast(ea);
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

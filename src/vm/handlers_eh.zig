/// handlers_eh.zig — M3 threaded-dispatch exception handling instruction handlers
///
/// throw, throw_ref, try_table_enter, try_table_leave + dispatchException helper
const std = @import("std");
const ir = @import("../compiler/ir.zig");
const encode = @import("../compiler/encode.zig");
const dispatch = @import("dispatch.zig");
const core = @import("core");
const gc_mod = @import("gc/root.zig");
const store_mod = @import("../wasmz/store.zig");

const Allocator = std.mem.Allocator;
const RawVal = dispatch.RawVal;
const Trap = dispatch.Trap;
const Handler = dispatch.Handler;
const DispatchState = dispatch.DispatchState;
const ExecEnv = dispatch.ExecEnv;
const CallFrame = dispatch.CallFrame;
const EhFrame = dispatch.EhFrame;
const EncodedFunction = ir.EncodedFunction;
const CatchHandlerEntry = ir.CatchHandlerEntry;
const CatchHandlerKind = ir.CatchHandlerKind;
const Store = store_mod.Store;
const GcHeap = gc_mod.GcHeap;
const GcRef = core.GcRef;
const GcRefKind = core.GcRefKind;
const GcHeader = gc_mod.GcHeader;
const Global = dispatch.Global;
const CompositeType = core.CompositeType;
const StructLayout = gc_mod.StructLayout;
const ArrayLayout = gc_mod.ArrayLayout;

const HANDLER_SIZE = dispatch.HANDLER_SIZE;

// ── Helpers ──────────────────────────────────────────────────────────────────

inline fn readOps(comptime T: type, ip: [*]align(8) u8) T {
    if (@sizeOf(T) == 0) return .{};
    return @as(*const T, @ptrCast(@alignCast(ip + HANDLER_SIZE))).*;
}

inline fn stride(comptime OpsT: type) usize {
    return std.mem.alignForward(usize, HANDLER_SIZE + @sizeOf(OpsT), 8);
}

inline fn trapReturn(frame: *DispatchState, code: core.TrapCode) void {
    frame.result = .{ .trap = Trap.fromTrapCode(code) };
}

fn collectGcRoots(
    allocator: Allocator,
    frame: *DispatchState,
    globals: []const Global,
) Allocator.Error![]GcRef {
    var roots = std.ArrayListUnmanaged(GcRef){};
    errdefer roots.deinit(allocator);

    for (0..frame.call_depth) |i| {
        for (frame.callStackAt(i).slots) |slot| {
            const ref = slot.readAsGcRef();
            if (ref.isHeapRef()) {
                try roots.append(allocator, ref);
            }
        }
    }

    for (globals) |g| {
        const ref = g.getRawValue().readAsGcRef();
        if (ref.isHeapRef()) {
            try roots.append(allocator, ref);
        }
    }

    return roots.toOwnedSlice(allocator);
}

/// Dispatch an exception by walking the EH stack. Returns true if a handler was found.
fn dispatchException(
    tag_index: u32,
    exn_ref: GcRef,
    frame: *DispatchState,
    store: *Store,
    env: *const ExecEnv,
) bool {
    _ = env;

    while (frame.eh_stack.items.len > 0) {
        const eh = &frame.eh_stack.items[frame.eh_stack.items.len - 1];

        const target_frame_idx = eh.call_stack_depth - 1;
        const target_frame = frame.callStackAt(target_frame_idx);
        const handlers = target_frame.func.catch_handler_tables[eh.handlers_start .. eh.handlers_start + eh.handlers_len];

        for (handlers) |h| {
            const matched: bool = switch (h.kind) {
                .catch_tag, .catch_tag_ref => h.tag_index == tag_index,
                .catch_all, .catch_all_ref => true,
            };
            if (!matched) continue;

            // Found a matching handler. Unwind call frames using val stack restore.
            while (frame.call_depth > eh.call_stack_depth) {
                const popped = frame.callStackPop();
                frame.valStackFree(popped.slots_sp_base);
            }
            // Pop nested EH frames
            while (frame.eh_stack.items.len > 0 and
                frame.eh_stack.items[frame.eh_stack.items.len - 1].call_stack_depth > frame.call_depth)
            {
                _ = frame.eh_stack.pop();
            }
            // Pop this EH frame
            _ = frame.eh_stack.pop();

            const tgt = frame.callStackTop();
            const tgt_slots = tgt.slots;
            const tgt_func = tgt.func;

            switch (h.kind) {
                .catch_tag => {
                    const n = h.dst_slots_len;
                    const dst_start = h.dst_slots_start;
                    const dst_slots = tgt_func.call_args[dst_start .. dst_start + n];
                    var i: u32 = 0;
                    while (i < n) : (i += 1) {
                        tgt_slots[dst_slots[i]] = store.gc_heap.exceptionArg(exn_ref, i);
                    }
                },
                .catch_tag_ref => {
                    const n = h.dst_slots_len;
                    const dst_start = h.dst_slots_start;
                    const dst_slots = tgt_func.call_args[dst_start .. dst_start + n];
                    var i: u32 = 0;
                    while (i < n) : (i += 1) {
                        tgt_slots[dst_slots[i]] = store.gc_heap.exceptionArg(exn_ref, i);
                    }
                    tgt_slots[h.dst_ref] = RawVal.fromGcRef(exn_ref);
                },
                .catch_all_ref => {
                    tgt_slots[h.dst_ref] = RawVal.fromGcRef(exn_ref);
                },
                .catch_all => {},
            }

            // Jump to handler target
            const target_byte_offset = h.target;
            frame.callStackTop().ip = @alignCast(tgt_func.code.ptr + target_byte_offset);
            return true;
        }

        _ = frame.eh_stack.pop();
    }

    return false;
}

// ── throw ────────────────────────────────────────────────────────────────────

pub fn handle_throw(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsThrow, ip);

    const caller_func = frame.callStackTop().func;
    const arg_slots = caller_func.call_args[ops.args_start .. ops.args_start + ops.args_len];

    const exc_args = frame.allocator.alloc(RawVal, arg_slots.len) catch {
        trapReturn(frame, .OutOfMemory);
        return;
    };
    for (arg_slots, 0..) |slot, i| {
        exc_args[i] = slots[slot];
    }

    // Allocate exception on GC heap
    const exn_ref: GcRef = blk: {
        if (env.store.gc_heap.allocException(ops.tag_index, exc_args)) |r| {
            frame.allocator.free(exc_args);
            break :blk r;
        }
        const roots = collectGcRoots(frame.allocator, frame, env.globals) catch {
            frame.allocator.free(exc_args);
            trapReturn(frame, .OutOfMemory);
            return;
        };
        env.store.gc_heap.collect(roots, env.composite_types, env.struct_layouts, env.array_layouts);
        frame.allocator.free(roots);
        const ref = env.store.gc_heap.allocException(ops.tag_index, exc_args) orelse {
            frame.allocator.free(exc_args);
            trapReturn(frame, .OutOfMemory);
            return;
        };
        frame.allocator.free(exc_args);
        break :blk ref;
    };

    if (dispatchException(ops.tag_index, exn_ref, frame, env.store, env)) {
        // Handler found, dispatch to the handler target
        const cur = frame.callStackTop();
        dispatch.dispatch(cur.ip, cur.slots.ptr, frame, env);
    } else {
        trapReturn(frame, .UnhandledException);
    }
}

// ── throw_ref ────────────────────────────────────────────────────────────────

pub fn handle_throw_ref(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsThrowRef, ip);

    const exn_ref = slots[ops.ref].readAsGcRef();
    if (exn_ref.asHeapIndex() == null) {
        trapReturn(frame, .NullReference);
        return;
    }
    const tag_index = env.store.gc_heap.exceptionTagIndex(exn_ref);

    if (dispatchException(tag_index, exn_ref, frame, env.store, env)) {
        const cur = frame.callStackTop();
        dispatch.dispatch(cur.ip, cur.slots.ptr, frame, env);
    } else {
        trapReturn(frame, .UnhandledException);
    }
}

// ── try_table_enter ──────────────────────────────────────────────────────────

pub fn handle_try_table_enter(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsTryTableEnter, ip);

    frame.eh_stack.append(frame.allocator, .{
        .call_stack_depth = frame.call_depth,
        .handlers_start = ops.handlers_start,
        .handlers_len = ops.handlers_len,
        .handler_table = frame.callStackTop().func.catch_handler_tables,
    }) catch {
        trapReturn(frame, .OutOfMemory);
        return;
    };
    dispatch.next(ip, stride(encode.OpsTryTableEnter), slots, frame, env);
}

// ── try_table_leave ──────────────────────────────────────────────────────────

pub fn handle_try_table_leave(ip: [*]align(8) u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv) callconv(.c) void {
    const ops = readOps(encode.OpsTryTableLeave, ip);

    _ = frame.eh_stack.pop();

    const func = frame.callStackTop().func;
    const target_ip: [*]align(8) u8 = @alignCast(func.code.ptr + ops.target);
    dispatch.dispatch(target_ip, slots, frame, env);
}

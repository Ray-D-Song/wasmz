/// handlers_gc.zig — M3 threaded-dispatch GC (Wasm GC) instruction handlers
///
/// struct_new/new_default/get/get_s/get_u/set, array_new/new_default/new_fixed/
/// new_data/new_elem/get/get_s/get_u/set/len/fill/copy/init_data/init_elem,
/// ref_i31, i31_get_s/u, ref_test, ref_cast, ref_as_non_null,
/// br_on_null/non_null, br_on_cast/cast_fail, any_convert_extern, extern_convert_any
/// + gcAlloc / collectGcRoots helpers
const std = @import("std");
const ir = @import("../../compiler/ir.zig");
const encode = @import("../../compiler/encode.zig");
const dispatch = @import("../dispatch.zig");
const core = @import("core");
const gc_mod = @import("../gc/root.zig");
const store_mod = @import("../../wasmz/store.zig");

const Allocator = std.mem.Allocator;
const RawVal = dispatch.RawVal;
const SimdVal = core.SimdVal;
const Trap = dispatch.Trap;
const Handler = dispatch.Handler;
const DispatchState = dispatch.DispatchState;
const ExecEnv = dispatch.ExecEnv;
const CallFrame = dispatch.CallFrame;
const Global = dispatch.Global;
const EncodedFunction = ir.EncodedFunction;
const Store = store_mod.Store;
const GcHeap = gc_mod.GcHeap;
const GcHeader = gc_mod.GcHeader;
const GcRef = core.GcRef;
const GcRefKind = core.GcRefKind;
const StructLayout = gc_mod.StructLayout;
const ArrayLayout = gc_mod.ArrayLayout;
const CompositeType = core.CompositeType;
const StorageType = core.StorageType;
const storageTypeSize = gc_mod.storageTypeSize;
const heap_type = core.heap_type;
const gcRefKindFromHeapType = heap_type.gcRefKindFromHeapType;

const HANDLER_SIZE = dispatch.HANDLER_SIZE;

// ── Helpers ──────────────────────────────────────────────────────────────────

inline fn readOps(comptime T: type, ip: [*]u8) T {
    if (@sizeOf(T) == 0) return .{};
    const bytes = ip[HANDLER_SIZE..][0..@sizeOf(T)];
    return std.mem.bytesAsValue(T, bytes).*;
}

/// Returns true if the storage type is a V128 (SIMD) value.
inline fn storageIsV128(st: StorageType) bool {
    return st == .valtype and st.valtype == .V128;
}

/// Build a SimdVal from a slot (or two slots for V128).
inline fn simdValFromSlots(slots: [*]RawVal, idx: u32, st: StorageType) SimdVal {
    if (storageIsV128(st)) {
        return SimdVal.fromSlots(slots[idx], slots[idx + 1]);
    }
    return SimdVal.fromScalar(slots[idx]);
}

/// Write a SimdVal into slot(s). V128 writes two consecutive slots.
inline fn writeSimdValToSlots(slots: [*]RawVal, idx: u32, sv: SimdVal, st: StorageType) void {
    if (storageIsV128(st)) {
        sv.toSlots(&slots[idx], &slots[idx + 1]);
    } else {
        slots[idx] = sv.toScalar();
    }
}

inline fn stride(comptime OpsT: type) usize {
    return HANDLER_SIZE + @sizeOf(OpsT);
}

inline fn trapReturn(frame: *DispatchState, code: core.TrapCode) void {
    frame.result = .{ .trap = Trap.fromTrapCode(code) };
}

fn collectGcRoots(
    allocator: Allocator,
    frame: *const DispatchState,
    globals: []const Global,
) Allocator.Error![]GcRef {
    var roots = std.ArrayListUnmanaged(GcRef){};
    errdefer roots.deinit(allocator);

    for (0..frame.call_depth) |i| {
        for (frame.call_stack[i].slots) |slot| {
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

/// Allocate `size` bytes from the GC heap, triggering a collection cycle and
/// retrying once if the first attempt fails. Returns null on true OOM.
fn gcAlloc(
    allocator: Allocator,
    gc_heap: *GcHeap,
    size: u32,
    frame: *const DispatchState,
    globals: []const Global,
    composite_types: []const CompositeType,
    struct_layouts: []const ?StructLayout,
    array_layouts: []const ?ArrayLayout,
) ?GcRef {
    if (gc_heap.alloc(size)) |ref| return ref;

    // First attempt failed — run a collection cycle and retry.
    const roots = collectGcRoots(allocator, frame, globals) catch return null;
    defer allocator.free(roots);
    gc_heap.collect(roots, composite_types, struct_layouts, array_layouts);

    return gc_heap.alloc(size);
}

// ── struct_new ───────────────────────────────────────────────────────────────

pub fn handle_struct_new(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsStructNew, ip);

    const struct_type = env.composite_types[ops.type_idx].struct_type;
    const layout = env.struct_layouts[ops.type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };

    const total_size = @sizeOf(GcHeader) + layout.size;
    const gc_ref = gcAlloc(frame.allocator, &env.store.gc_heap, total_size, frame, env.globals, env.composite_types, env.struct_layouts, env.array_layouts) orelse {
        trapReturn(frame, .OutOfMemory);
        return;
    };

    const header_ptr = env.store.gc_heap.getHeader(gc_ref);
    header_ptr.* = GcHeader.initFromRefKind(GcRefKind.init(GcRefKind.Struct), ops.type_idx);

    // Read inline arg slots directly from the bytecode stream (zero pointer chasing)
    const arg_slots = encode.readInlineArgs(encode.OpsStructNew, ip, ops.args_len);

    for (arg_slots, 0..) |arg_slot, i| {
        const field_st = struct_type.fields[i].storage_type;
        env.store.gc_heap.writeField(gc_ref, struct_type, layout, @intCast(i), simdValFromSlots(slots, arg_slot, field_st));
    }

    slots[ops.dst] = RawVal.fromGcRef(gc_ref);
    dispatch.next(ip, encode.varStride(encode.OpsStructNew, ops.args_len), slots, frame, env, r0, fp0);
}

// ── struct_new_default ───────────────────────────────────────────────────────

pub fn handle_struct_new_default(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsStructNewDefault, ip);

    const layout = env.struct_layouts[ops.type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };

    const total_size = @sizeOf(GcHeader) + layout.size;
    const gc_ref = gcAlloc(frame.allocator, &env.store.gc_heap, total_size, frame, env.globals, env.composite_types, env.struct_layouts, env.array_layouts) orelse {
        trapReturn(frame, .OutOfMemory);
        return;
    };

    const header_ptr = env.store.gc_heap.getHeader(gc_ref);
    header_ptr.* = GcHeader.initFromRefKind(GcRefKind.init(GcRefKind.Struct), ops.type_idx);

    const data = env.store.gc_heap.getBytesAt(gc_ref, @sizeOf(GcHeader));
    @memset(data[0..layout.size], 0);

    slots[ops.dst] = RawVal.fromGcRef(gc_ref);
    dispatch.next(ip, stride(encode.OpsStructNewDefault), slots, frame, env, r0, fp0);
}

// ── struct_get ───────────────────────────────────────────────────────────────

pub fn handle_struct_get(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsStructGet, ip);

    const gc_ref = slots[ops.ref].readAsGcRef();
    if (gc_ref.isNull()) {
        trapReturn(frame, .NullReference);
        return;
    }

    const struct_type = env.composite_types[ops.type_idx].struct_type;
    const layout = env.struct_layouts[ops.type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };

    const field_st_get = struct_type.fields[ops.field_idx].storage_type;
    writeSimdValToSlots(slots, ops.dst, env.store.gc_heap.readField(gc_ref, struct_type, layout, ops.field_idx), field_st_get);
    dispatch.next(ip, stride(encode.OpsStructGet), slots, frame, env, r0, fp0);
}

// ── struct_get_s ─────────────────────────────────────────────────────────────

pub fn handle_struct_get_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsStructGet, ip);

    const gc_ref = slots[ops.ref].readAsGcRef();
    if (gc_ref.isNull()) {
        trapReturn(frame, .NullReference);
        return;
    }

    const struct_type = env.composite_types[ops.type_idx].struct_type;
    const layout = env.struct_layouts[ops.type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };

    const field_st_gets = struct_type.fields[ops.field_idx].storage_type;
    writeSimdValToSlots(slots, ops.dst, env.store.gc_heap.readField(gc_ref, struct_type, layout, ops.field_idx), field_st_gets);
    dispatch.next(ip, stride(encode.OpsStructGet), slots, frame, env, r0, fp0);
}

// ── struct_get_u ─────────────────────────────────────────────────────────────

pub fn handle_struct_get_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsStructGet, ip);

    const gc_ref = slots[ops.ref].readAsGcRef();
    if (gc_ref.isNull()) {
        trapReturn(frame, .NullReference);
        return;
    }

    const struct_type = env.composite_types[ops.type_idx].struct_type;
    const layout = env.struct_layouts[ops.type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };

    const field_st_getu = struct_type.fields[ops.field_idx].storage_type;
    writeSimdValToSlots(slots, ops.dst, env.store.gc_heap.readFieldUnsigned(gc_ref, struct_type, layout, ops.field_idx), field_st_getu);
    dispatch.next(ip, stride(encode.OpsStructGet), slots, frame, env, r0, fp0);
}

// ── struct_set ───────────────────────────────────────────────────────────────

pub fn handle_struct_set(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsStructSet, ip);

    const gc_ref = slots[ops.ref].readAsGcRef();
    if (gc_ref.isNull()) {
        trapReturn(frame, .NullReference);
        return;
    }

    const struct_type = env.composite_types[ops.type_idx].struct_type;
    const layout = env.struct_layouts[ops.type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };

    const field_st = struct_type.fields[ops.field_idx].storage_type;
    env.store.gc_heap.writeField(gc_ref, struct_type, layout, ops.field_idx, simdValFromSlots(slots, ops.value, field_st));
    dispatch.next(ip, stride(encode.OpsStructSet), slots, frame, env, r0, fp0);
}

// ── array_new ────────────────────────────────────────────────────────────────

pub fn handle_array_new(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsArrayNew, ip);

    const array_type = env.composite_types[ops.type_idx].array_type;
    const layout = env.array_layouts[ops.type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };

    const len = slots[ops.len].readAs(u32);
    const total_size = layout.base_size + len * layout.elem_size;
    const gc_ref = gcAlloc(frame.allocator, &env.store.gc_heap, total_size, frame, env.globals, env.composite_types, env.struct_layouts, env.array_layouts) orelse {
        trapReturn(frame, .OutOfMemory);
        return;
    };

    const header_ptr = env.store.gc_heap.getHeader(gc_ref);
    header_ptr.* = GcHeader.initFromRefKind(GcRefKind.init(GcRefKind.Array), ops.type_idx);

    env.store.gc_heap.setLength(gc_ref, len);

    const elem_st_new = array_type.field.storage_type;
    const init_sv = simdValFromSlots(slots, ops.init, elem_st_new);
    for (0..len) |i| {
        env.store.gc_heap.writeElem(gc_ref, array_type, layout, @intCast(i), init_sv);
    }

    slots[ops.dst] = RawVal.fromGcRef(gc_ref);
    dispatch.next(ip, stride(encode.OpsArrayNew), slots, frame, env, r0, fp0);
}

// ── array_new_default ────────────────────────────────────────────────────────

pub fn handle_array_new_default(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsArrayNewDefault, ip);

    const layout = env.array_layouts[ops.type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };

    const len = slots[ops.len].readAs(u32);
    const total_size = layout.base_size + len * layout.elem_size;
    const gc_ref = gcAlloc(frame.allocator, &env.store.gc_heap, total_size, frame, env.globals, env.composite_types, env.struct_layouts, env.array_layouts) orelse {
        trapReturn(frame, .OutOfMemory);
        return;
    };

    const header_ptr = env.store.gc_heap.getHeader(gc_ref);
    header_ptr.* = GcHeader.initFromRefKind(GcRefKind.init(GcRefKind.Array), ops.type_idx);

    env.store.gc_heap.setLength(gc_ref, len);

    const data = env.store.gc_heap.getBytesAt(gc_ref, layout.base_size);
    @memset(data[0 .. len * layout.elem_size], 0);

    slots[ops.dst] = RawVal.fromGcRef(gc_ref);
    dispatch.next(ip, stride(encode.OpsArrayNewDefault), slots, frame, env, r0, fp0);
}

// ── array_new_fixed ──────────────────────────────────────────────────────────

pub fn handle_array_new_fixed(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsArrayNewFixed, ip);

    const array_type = env.composite_types[ops.type_idx].array_type;
    const layout = env.array_layouts[ops.type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };

    const len = ops.args_len;
    const total_size = layout.base_size + len * layout.elem_size;
    const gc_ref = gcAlloc(frame.allocator, &env.store.gc_heap, total_size, frame, env.globals, env.composite_types, env.struct_layouts, env.array_layouts) orelse {
        trapReturn(frame, .OutOfMemory);
        return;
    };

    const header_ptr = env.store.gc_heap.getHeader(gc_ref);
    header_ptr.* = GcHeader.initFromRefKind(GcRefKind.init(GcRefKind.Array), ops.type_idx);

    env.store.gc_heap.setLength(gc_ref, @intCast(len));

    // Read inline arg slots directly from the bytecode stream (zero pointer chasing)
    const arg_slots = encode.readInlineArgs(encode.OpsArrayNewFixed, ip, ops.args_len);

    for (arg_slots, 0..) |arg_slot, i| {
        const elem_st_fixed = array_type.field.storage_type;
        env.store.gc_heap.writeElem(gc_ref, array_type, layout, @intCast(i), simdValFromSlots(slots, arg_slot, elem_st_fixed));
    }

    slots[ops.dst] = RawVal.fromGcRef(gc_ref);
    dispatch.next(ip, encode.varStride(encode.OpsArrayNewFixed, ops.args_len), slots, frame, env, r0, fp0);
}

// ── array_new_data ───────────────────────────────────────────────────────────

pub fn handle_array_new_data(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsArrayNewData, ip);

    if (ops.data_idx >= env.data_segments.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }
    if (env.data_segments_dropped[ops.data_idx]) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }
    const seg = env.data_segments[ops.data_idx];

    const array_type = env.composite_types[ops.type_idx].array_type;
    const layout = env.array_layouts[ops.type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };

    const src_offset = slots[ops.offset].readAs(u32);
    const len = slots[ops.len].readAs(u32);
    const elem_byte_size = storageTypeSize(array_type.field.storage_type);

    // Trap if segment bytes are out of range.
    const byte_count = @as(u64, len) * @as(u64, elem_byte_size);
    const src_end = @as(u64, src_offset) + byte_count;
    if (src_end > seg.data.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }

    const total_size = layout.base_size + len * layout.elem_size;
    const gc_ref = gcAlloc(frame.allocator, &env.store.gc_heap, total_size, frame, env.globals, env.composite_types, env.struct_layouts, env.array_layouts) orelse {
        trapReturn(frame, .OutOfMemory);
        return;
    };

    const header_ptr = env.store.gc_heap.getHeader(gc_ref);
    header_ptr.* = GcHeader.initFromRefKind(GcRefKind.init(GcRefKind.Array), ops.type_idx);
    env.store.gc_heap.setLength(gc_ref, len);

    // Read each element from the data segment using the element storage type.
    for (0..len) |i| {
        const byte_offset = src_offset + @as(u32, @intCast(i)) * elem_byte_size;
        const sv = switch (array_type.field.storage_type) {
            .packed_type => |p| switch (p) {
                .I8 => SimdVal.fromScalar(RawVal.from(@as(i32, @as(i8, @bitCast(seg.data[byte_offset]))))),
                .I16 => SimdVal.fromScalar(RawVal.from(@as(i32, @as(i16, @bitCast(std.mem.readInt(u16, seg.data[byte_offset..][0..2], .little)))))),
            },
            .valtype => |v| switch (v) {
                .I32 => SimdVal.fromScalar(RawVal.from(std.mem.readInt(i32, seg.data[byte_offset..][0..4], .little))),
                .I64 => SimdVal.fromScalar(RawVal.from(std.mem.readInt(i64, seg.data[byte_offset..][0..8], .little))),
                .F32 => SimdVal.fromScalar(RawVal.from(std.mem.readInt(u32, seg.data[byte_offset..][0..4], .little))),
                .F64 => SimdVal.fromScalar(RawVal.from(std.mem.readInt(u64, seg.data[byte_offset..][0..8], .little))),
                .V128 => blk: {
                    var sv128: SimdVal = undefined;
                    @memcpy(&sv128.bytes, seg.data[byte_offset..][0..16]);
                    break :blk sv128;
                },
                .Ref => SimdVal.fromScalar(RawVal.fromGcRef(GcRef.encode(std.mem.readInt(u32, seg.data[byte_offset..][0..4], .little)))),
            },
        };
        env.store.gc_heap.writeElem(gc_ref, array_type, layout, @intCast(i), sv);
    }

    slots[ops.dst] = RawVal.fromGcRef(gc_ref);
    dispatch.next(ip, stride(encode.OpsArrayNewData), slots, frame, env, r0, fp0);
}

// ── array_new_elem ───────────────────────────────────────────────────────────

pub fn handle_array_new_elem(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsArrayNewElem, ip);

    if (ops.elem_idx >= env.elem_segments.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    if (env.elem_segments_dropped[ops.elem_idx]) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    const seg = env.elem_segments[ops.elem_idx];

    const array_type = env.composite_types[ops.type_idx].array_type;
    const layout = env.array_layouts[ops.type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };

    const src_offset = slots[ops.offset].readAs(u32);
    const len = slots[ops.len].readAs(u32);

    const src_end, const src_overflow = @addWithOverflow(src_offset, len);
    if (src_overflow != 0 or src_end > seg.func_indices.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }

    const total_size = layout.base_size + len * layout.elem_size;
    const gc_ref = gcAlloc(frame.allocator, &env.store.gc_heap, total_size, frame, env.globals, env.composite_types, env.struct_layouts, env.array_layouts) orelse {
        trapReturn(frame, .OutOfMemory);
        return;
    };

    const header_ptr = env.store.gc_heap.getHeader(gc_ref);
    header_ptr.* = GcHeader.initFromRefKind(GcRefKind.init(GcRefKind.Array), ops.type_idx);
    env.store.gc_heap.setLength(gc_ref, len);

    // Elem segments store func_idx (maxInt(u32) = null).
    // Encode as funcref slot value: null -> 0, func_idx -> func_idx+1.
    for (0..len) |i| {
        const func_idx = seg.func_indices[src_offset + i];
        const ref_val: u64 = if (func_idx == std.math.maxInt(u32)) 0 else @as(u64, func_idx) + 1;
        env.store.gc_heap.writeElem(gc_ref, array_type, layout, @intCast(i), SimdVal.fromScalar(RawVal.fromBits64(ref_val)));
    }

    slots[ops.dst] = RawVal.fromGcRef(gc_ref);
    dispatch.next(ip, stride(encode.OpsArrayNewElem), slots, frame, env, r0, fp0);
}

// ── array_get ────────────────────────────────────────────────────────────────

pub fn handle_array_get(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsArrayGet, ip);

    const gc_ref = slots[ops.ref].readAsGcRef();
    if (gc_ref.isNull()) {
        trapReturn(frame, .NullReference);
        return;
    }

    const index = slots[ops.index].readAs(u32);
    const length = env.store.gc_heap.getLength(gc_ref);
    if (index >= length) {
        trapReturn(frame, .ArrayOutOfBounds);
        return;
    }

    const array_type = env.composite_types[ops.type_idx].array_type;
    const layout = env.array_layouts[ops.type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };

    const elem_st_ag = array_type.field.storage_type;
    writeSimdValToSlots(slots, ops.dst, env.store.gc_heap.readElem(gc_ref, array_type, layout, index), elem_st_ag);
    dispatch.next(ip, stride(encode.OpsArrayGet), slots, frame, env, r0, fp0);
}

// ── array_get_s ──────────────────────────────────────────────────────────────

pub fn handle_array_get_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsArrayGet, ip);

    const gc_ref = slots[ops.ref].readAsGcRef();
    if (gc_ref.isNull()) {
        trapReturn(frame, .NullReference);
        return;
    }

    const index = slots[ops.index].readAs(u32);
    const length = env.store.gc_heap.getLength(gc_ref);
    if (index >= length) {
        trapReturn(frame, .ArrayOutOfBounds);
        return;
    }

    const array_type = env.composite_types[ops.type_idx].array_type;
    const layout = env.array_layouts[ops.type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };

    const elem_st_ags = array_type.field.storage_type;
    writeSimdValToSlots(slots, ops.dst, env.store.gc_heap.readElem(gc_ref, array_type, layout, index), elem_st_ags);
    dispatch.next(ip, stride(encode.OpsArrayGet), slots, frame, env, r0, fp0);
}

// ── array_get_u ──────────────────────────────────────────────────────────────

pub fn handle_array_get_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsArrayGet, ip);

    const gc_ref = slots[ops.ref].readAsGcRef();
    if (gc_ref.isNull()) {
        trapReturn(frame, .NullReference);
        return;
    }

    const index = slots[ops.index].readAs(u32);
    const length = env.store.gc_heap.getLength(gc_ref);
    if (index >= length) {
        trapReturn(frame, .ArrayOutOfBounds);
        return;
    }

    const array_type = env.composite_types[ops.type_idx].array_type;
    const layout = env.array_layouts[ops.type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };

    // Use unsigned (zero-extending) read for packed types.
    const elem_st_agu = array_type.field.storage_type;
    writeSimdValToSlots(slots, ops.dst, env.store.gc_heap.readElemUnsigned(gc_ref, array_type, layout, index), elem_st_agu);
    dispatch.next(ip, stride(encode.OpsArrayGet), slots, frame, env, r0, fp0);
}

// ── array_set ────────────────────────────────────────────────────────────────

pub fn handle_array_set(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsArraySet, ip);

    const gc_ref = slots[ops.ref].readAsGcRef();
    if (gc_ref.isNull()) {
        trapReturn(frame, .NullReference);
        return;
    }

    const index = slots[ops.index].readAs(u32);
    const length = env.store.gc_heap.getLength(gc_ref);
    if (index >= length) {
        trapReturn(frame, .ArrayOutOfBounds);
        return;
    }

    const array_type = env.composite_types[ops.type_idx].array_type;
    const layout = env.array_layouts[ops.type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };

    const elem_st_as = array_type.field.storage_type;
    env.store.gc_heap.writeElem(gc_ref, array_type, layout, index, simdValFromSlots(slots, ops.value, elem_st_as));
    dispatch.next(ip, stride(encode.OpsArraySet), slots, frame, env, r0, fp0);
}

// ── array_len ────────────────────────────────────────────────────────────────

pub fn handle_array_len(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsArrayLen, ip);

    const gc_ref = slots[ops.ref].readAsGcRef();
    if (gc_ref.isNull()) {
        trapReturn(frame, .NullReference);
        return;
    }

    const len = env.store.gc_heap.getLength(gc_ref);
    slots[ops.dst] = RawVal.from(@as(i32, @intCast(len)));
    dispatch.next(ip, stride(encode.OpsArrayLen), slots, frame, env, r0, fp0);
}

// ── array_fill ───────────────────────────────────────────────────────────────

pub fn handle_array_fill(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsArrayFill, ip);

    const gc_ref = slots[ops.ref].readAsGcRef();
    if (gc_ref.isNull()) {
        trapReturn(frame, .NullReference);
        return;
    }

    const offset = slots[ops.offset].readAs(u32);
    const n = slots[ops.n].readAs(u32);
    const length = env.store.gc_heap.getLength(gc_ref);
    const end, const end_overflow = @addWithOverflow(offset, n);
    if (end_overflow != 0 or end > length) {
        trapReturn(frame, .ArrayOutOfBounds);
        return;
    }

    const array_type = env.composite_types[ops.type_idx].array_type;
    const layout = env.array_layouts[ops.type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };

    const elem_st_fill = array_type.field.storage_type;
    const fill_sv = simdValFromSlots(slots, ops.value, elem_st_fill);
    for (offset..end) |i| {
        env.store.gc_heap.writeElem(gc_ref, array_type, layout, @intCast(i), fill_sv);
    }
    dispatch.next(ip, stride(encode.OpsArrayFill), slots, frame, env, r0, fp0);
}

// ── array_copy ───────────────────────────────────────────────────────────────

pub fn handle_array_copy(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsArrayCopy, ip);

    const dst_ref = slots[ops.dst_ref].readAsGcRef();
    if (dst_ref.isNull()) {
        trapReturn(frame, .NullReference);
        return;
    }
    const src_ref = slots[ops.src_ref].readAsGcRef();
    if (src_ref.isNull()) {
        trapReturn(frame, .NullReference);
        return;
    }

    const dst_offset = slots[ops.dst_offset].readAs(u32);
    const src_offset = slots[ops.src_offset].readAs(u32);
    const n = slots[ops.n].readAs(u32);

    const dst_length = env.store.gc_heap.getLength(dst_ref);
    const src_length = env.store.gc_heap.getLength(src_ref);

    const dst_end, const dst_end_overflow = @addWithOverflow(dst_offset, n);
    const src_end, const src_end_overflow = @addWithOverflow(src_offset, n);
    if (dst_end_overflow != 0 or src_end_overflow != 0 or dst_end > dst_length or src_end > src_length) {
        trapReturn(frame, .ArrayOutOfBounds);
        return;
    }

    const dst_array_type = env.composite_types[ops.dst_type_idx].array_type;
    const dst_layout = env.array_layouts[ops.dst_type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };
    const src_array_type = env.composite_types[ops.src_type_idx].array_type;
    const src_layout = env.array_layouts[ops.src_type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };

    if (dst_offset < src_offset) {
        for (0..n) |i| {
            const val = env.store.gc_heap.readElem(src_ref, src_array_type, src_layout, src_offset + @as(u32, @intCast(i)));
            env.store.gc_heap.writeElem(dst_ref, dst_array_type, dst_layout, dst_offset + @as(u32, @intCast(i)), val);
        }
    } else {
        var i: u32 = n;
        while (i > 0) {
            i -= 1;
            const val = env.store.gc_heap.readElem(src_ref, src_array_type, src_layout, src_offset + i);
            env.store.gc_heap.writeElem(dst_ref, dst_array_type, dst_layout, dst_offset + i, val);
        }
    }
    dispatch.next(ip, stride(encode.OpsArrayCopy), slots, frame, env, r0, fp0);
}

// ── array_init_data ──────────────────────────────────────────────────────────

pub fn handle_array_init_data(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsArrayInitData, ip);

    if (ops.data_idx >= env.data_segments.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }
    if (env.data_segments_dropped[ops.data_idx]) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }
    const seg = env.data_segments[ops.data_idx];

    const gc_ref = slots[ops.ref].readAsGcRef();
    if (gc_ref.isNull()) {
        trapReturn(frame, .NullReference);
        return;
    }

    const array_type = env.composite_types[ops.type_idx].array_type;
    const layout = env.array_layouts[ops.type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };

    const dst_offset = slots[ops.d].readAs(u32);
    const src_offset = slots[ops.s].readAs(u32);
    const n = slots[ops.n].readAs(u32);
    const arr_len = env.store.gc_heap.getLength(gc_ref);
    const elem_byte_size = storageTypeSize(array_type.field.storage_type);

    // Bounds check on destination array.
    const dst_end, const dst_overflow = @addWithOverflow(dst_offset, n);
    if (dst_overflow != 0 or dst_end > arr_len) {
        trapReturn(frame, .ArrayOutOfBounds);
        return;
    }

    // Bounds check on source data segment.
    const byte_count = @as(u64, n) * @as(u64, elem_byte_size);
    const src_end = @as(u64, src_offset) + byte_count;
    if (src_end > seg.data.len) {
        trapReturn(frame, .MemoryOutOfBounds);
        return;
    }

    for (0..n) |i| {
        const byte_offset = src_offset + @as(u32, @intCast(i)) * elem_byte_size;
        const sv_id = switch (array_type.field.storage_type) {
            .packed_type => |p| switch (p) {
                .I8 => SimdVal.fromScalar(RawVal.from(@as(i32, @as(i8, @bitCast(seg.data[byte_offset]))))),
                .I16 => SimdVal.fromScalar(RawVal.from(@as(i32, @as(i16, @bitCast(std.mem.readInt(u16, seg.data[byte_offset..][0..2], .little)))))),
            },
            .valtype => |v| switch (v) {
                .I32 => SimdVal.fromScalar(RawVal.from(std.mem.readInt(i32, seg.data[byte_offset..][0..4], .little))),
                .I64 => SimdVal.fromScalar(RawVal.from(std.mem.readInt(i64, seg.data[byte_offset..][0..8], .little))),
                .F32 => SimdVal.fromScalar(RawVal.from(std.mem.readInt(u32, seg.data[byte_offset..][0..4], .little))),
                .F64 => SimdVal.fromScalar(RawVal.from(std.mem.readInt(u64, seg.data[byte_offset..][0..8], .little))),
                .V128 => blk: {
                    var sv128: SimdVal = undefined;
                    @memcpy(&sv128.bytes, seg.data[byte_offset..][0..16]);
                    break :blk sv128;
                },
                .Ref => SimdVal.fromScalar(RawVal.fromGcRef(GcRef.encode(std.mem.readInt(u32, seg.data[byte_offset..][0..4], .little)))),
            },
        };
        env.store.gc_heap.writeElem(gc_ref, array_type, layout, dst_offset + @as(u32, @intCast(i)), sv_id);
    }
    dispatch.next(ip, stride(encode.OpsArrayInitData), slots, frame, env, r0, fp0);
}

// ── array_init_elem ──────────────────────────────────────────────────────────

pub fn handle_array_init_elem(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsArrayInitElem, ip);

    if (ops.elem_idx >= env.elem_segments.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    if (env.elem_segments_dropped[ops.elem_idx]) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }
    const seg = env.elem_segments[ops.elem_idx];

    const gc_ref = slots[ops.ref].readAsGcRef();
    if (gc_ref.isNull()) {
        trapReturn(frame, .NullReference);
        return;
    }

    const array_type = env.composite_types[ops.type_idx].array_type;
    const layout = env.array_layouts[ops.type_idx] orelse {
        trapReturn(frame, .BadSignature);
        return;
    };

    const dst_offset = slots[ops.d].readAs(u32);
    const src_offset = slots[ops.s].readAs(u32);
    const n = slots[ops.n].readAs(u32);
    const arr_len = env.store.gc_heap.getLength(gc_ref);

    // Bounds check on destination array.
    const dst_end, const dst_overflow = @addWithOverflow(dst_offset, n);
    if (dst_overflow != 0 or dst_end > arr_len) {
        trapReturn(frame, .ArrayOutOfBounds);
        return;
    }

    // Bounds check on source elem segment.
    const src_end, const src_overflow = @addWithOverflow(src_offset, n);
    if (src_overflow != 0 or src_end > seg.func_indices.len) {
        trapReturn(frame, .TableOutOfBounds);
        return;
    }

    for (0..n) |i| {
        const func_idx = seg.func_indices[src_offset + i];
        const ref_val: u64 = if (func_idx == std.math.maxInt(u32)) 0 else @as(u64, func_idx) + 1;
        env.store.gc_heap.writeElem(gc_ref, array_type, layout, dst_offset + @as(u32, @intCast(i)), SimdVal.fromScalar(RawVal.fromBits64(ref_val)));
    }
    dispatch.next(ip, stride(encode.OpsArrayInitElem), slots, frame, env, r0, fp0);
}

// ── ref_i31 ──────────────────────────────────────────────────────────────────

pub fn handle_ref_i31(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsRefI31, ip);

    const value = slots[ops.value].readAs(i32);
    const truncated: i31 = @truncate(value);
    slots[ops.dst] = RawVal.fromGcRef(GcRef.fromI31(truncated));
    dispatch.next(ip, stride(encode.OpsRefI31), slots, frame, env, r0, fp0);
}

// ── i31_get_s ────────────────────────────────────────────────────────────────

pub fn handle_i31_get_s(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsI31Get, ip);

    const gc_ref = slots[ops.ref].readAsGcRef();
    if (gc_ref.isNull()) {
        trapReturn(frame, .NullReference);
        return;
    }
    if (!gc_ref.isI31()) {
        trapReturn(frame, .CastFailure);
        return;
    }

    const value = gc_ref.asI31() orelse {
        trapReturn(frame, .CastFailure);
        return;
    };
    slots[ops.dst] = RawVal.from(@as(i32, value));
    dispatch.next(ip, stride(encode.OpsI31Get), slots, frame, env, r0, fp0);
}

// ── i31_get_u ────────────────────────────────────────────────────────────────

pub fn handle_i31_get_u(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsI31Get, ip);

    const gc_ref = slots[ops.ref].readAsGcRef();
    if (gc_ref.isNull()) {
        trapReturn(frame, .NullReference);
        return;
    }
    if (!gc_ref.isI31()) {
        trapReturn(frame, .CastFailure);
        return;
    }

    const value = gc_ref.asI31() orelse {
        trapReturn(frame, .CastFailure);
        return;
    };
    const extended: i32 = value;
    slots[ops.dst] = RawVal.from(@as(i32, @bitCast(@as(u32, @bitCast(extended)) & @as(u32, 0x7FFFFFFF))));
    dispatch.next(ip, stride(encode.OpsI31Get), slots, frame, env, r0, fp0);
}

// ── ref_test ─────────────────────────────────────────────────────────────────

pub fn handle_ref_test(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsRefTest, ip);

    const gc_ref = slots[ops.ref].readAsGcRef();
    const nullable = ops.nullable != 0;

    if (gc_ref.isNull()) {
        // ref.test_null (nullable=true): null always matches the nullable type.
        // ref.test (nullable=false): null never matches.
        slots[ops.dst] = RawVal.from(@as(i32, if (nullable) 1 else 0));
    } else if (gc_ref.isI31()) {
        const target_kind = gcRefKindFromHeapType(@as(core.HeapType, @enumFromInt(ops.type_idx)));
        if (target_kind) |kind| {
            const is_match = GcRefKind.init(GcRefKind.I31).isSubtypeOf(kind);
            slots[ops.dst] = RawVal.from(@as(i32, if (is_match) 1 else 0));
        } else {
            slots[ops.dst] = RawVal.from(@as(i32, 0));
        }
    } else {
        const obj_header = env.store.gc_heap.getHeader(gc_ref);
        const target_kind = gcRefKindFromHeapType(@as(core.HeapType, @enumFromInt(ops.type_idx)));
        if (target_kind) |kind| {
            const kind_bits: u32 = @as(u32, kind.bits) << 26;
            const is_match = obj_header.isSubtypeOf(kind_bits);
            slots[ops.dst] = RawVal.from(@as(i32, if (is_match) 1 else 0));
        } else {
            // Concrete type -- decode the raw type index from HeapType encoding.
            const target_heap = @as(core.HeapType, @enumFromInt(ops.type_idx));
            const target_type_idx = target_heap.concreteType() orelse {
                slots[ops.dst] = RawVal.from(@as(i32, 0));
                dispatch.next(ip, stride(encode.OpsRefTest), slots, frame, env, r0, fp0);
                return;
            };
            const obj_idx = obj_header.type_index;
            const is_match = obj_idx == target_type_idx or blk: {
                if (obj_idx < env.type_ancestors.len) {
                    for (env.type_ancestors[obj_idx]) |anc| {
                        if (anc == target_type_idx) break :blk true;
                    }
                }
                break :blk false;
            };
            slots[ops.dst] = RawVal.from(@as(i32, if (is_match) 1 else 0));
        }
    }
    dispatch.next(ip, stride(encode.OpsRefTest), slots, frame, env, r0, fp0);
}

// ── ref_cast ─────────────────────────────────────────────────────────────────

pub fn handle_ref_cast(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsRefTest, ip); // ref_cast uses same operand struct as ref_test
    const nullable = ops.nullable != 0;

    const gc_ref = slots[ops.ref].readAsGcRef();
    if (gc_ref.isNull()) {
        if (nullable) {
            // ref.cast_null: null passes through.
            slots[ops.dst] = RawVal.fromGcRef(gc_ref);
            dispatch.next(ip, stride(encode.OpsRefTest), slots, frame, env, r0, fp0);
            return;
        }
        trapReturn(frame, .CastFailure);
        return;
    }

    if (gc_ref.isI31()) {
        const target_kind = gcRefKindFromHeapType(@as(core.HeapType, @enumFromInt(ops.type_idx)));
        if (target_kind) |kind| {
            const is_match = GcRefKind.init(GcRefKind.I31).isSubtypeOf(kind);
            if (!is_match) {
                trapReturn(frame, .CastFailure);
                return;
            }
        } else {
            trapReturn(frame, .CastFailure);
            return;
        }
        slots[ops.dst] = RawVal.fromGcRef(gc_ref);
    } else {
        const obj_header = env.store.gc_heap.getHeader(gc_ref);
        const target_kind = gcRefKindFromHeapType(@as(core.HeapType, @enumFromInt(ops.type_idx)));
        if (target_kind) |kind| {
            const kind_bits: u32 = @as(u32, kind.bits) << 26;
            if (!obj_header.isSubtypeOf(kind_bits)) {
                trapReturn(frame, .CastFailure);
                return;
            }
        } else {
            // Concrete type -- decode the raw type index from HeapType encoding.
            const target_heap = @as(core.HeapType, @enumFromInt(ops.type_idx));
            const target_type_idx = target_heap.concreteType() orelse {
                trapReturn(frame, .CastFailure);
                return;
            };
            const obj_idx = obj_header.type_index;
            const is_match = obj_idx == target_type_idx or blk: {
                if (obj_idx < env.type_ancestors.len) {
                    for (env.type_ancestors[obj_idx]) |anc| {
                        if (anc == target_type_idx) break :blk true;
                    }
                }
                break :blk false;
            };
            if (!is_match) {
                trapReturn(frame, .CastFailure);
                return;
            }
        }
        slots[ops.dst] = RawVal.fromGcRef(gc_ref);
    }
    dispatch.next(ip, stride(encode.OpsRefTest), slots, frame, env, r0, fp0);
}

// ── ref_as_non_null ──────────────────────────────────────────────────────────

pub fn handle_ref_as_non_null(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsRefAsNonNull, ip);

    const gc_ref = slots[ops.ref].readAsGcRef();
    if (gc_ref.isNull()) {
        trapReturn(frame, .NullReference);
        return;
    }
    slots[ops.dst] = RawVal.fromGcRef(gc_ref);
    dispatch.next(ip, stride(encode.OpsRefAsNonNull), slots, frame, env, r0, fp0);
}

// ── br_on_null ───────────────────────────────────────────────────────────────

pub fn handle_br_on_null(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsBrOnNull, ip);

    const gc_ref = slots[ops.ref].readAsGcRef();
    if (gc_ref.isNull()) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsBrOnNull), slots, frame, env, r0, fp0);
    }
}

// ── br_on_non_null ───────────────────────────────────────────────────────────

pub fn handle_br_on_non_null(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsBrOnNull, ip); // Same operand struct

    const gc_ref = slots[ops.ref].readAsGcRef();
    if (!gc_ref.isNull()) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsBrOnNull), slots, frame, env, r0, fp0);
    }
}

// ── br_on_cast ───────────────────────────────────────────────────────────────

pub fn handle_br_on_cast(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsBrOnCast, ip);

    const gc_ref = slots[ops.ref].readAsGcRef();
    var should_branch = false;

    if (gc_ref.isNull()) {
        // If the target type is nullable, null satisfies the cast => branch.
        should_branch = ops.to_nullable != 0;
    } else if (gc_ref.isI31()) {
        const target_kind = gcRefKindFromHeapType(@as(core.HeapType, @enumFromInt(ops.to_type_idx)));
        if (target_kind) |kind| {
            should_branch = GcRefKind.init(GcRefKind.I31).isSubtypeOf(kind);
        }
    } else {
        const obj_header = env.store.gc_heap.getHeader(gc_ref);
        const target_kind = gcRefKindFromHeapType(@as(core.HeapType, @enumFromInt(ops.to_type_idx)));
        if (target_kind) |kind| {
            const kind_bits: u32 = @as(u32, kind.bits) << 26;
            should_branch = obj_header.isSubtypeOf(kind_bits);
        } else {
            const target_heap = @as(core.HeapType, @enumFromInt(ops.to_type_idx));
            if (target_heap.concreteType()) |target_type_idx| {
                const obj_idx = obj_header.type_index;
                should_branch = obj_idx == target_type_idx or blk: {
                    if (obj_idx < env.type_ancestors.len) {
                        for (env.type_ancestors[obj_idx]) |anc| {
                            if (anc == target_type_idx) break :blk true;
                        }
                    }
                    break :blk false;
                };
            }
        }
    }

    if (should_branch) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsBrOnCast), slots, frame, env, r0, fp0);
    }
}

// ── br_on_cast_fail ──────────────────────────────────────────────────────────

pub fn handle_br_on_cast_fail(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsBrOnCast, ip); // Same operand struct

    const gc_ref = slots[ops.ref].readAsGcRef();
    var should_branch = false;

    if (gc_ref.isNull()) {
        // If the target type is nullable, null satisfies the cast => do NOT branch.
        should_branch = ops.to_nullable == 0;
    } else if (gc_ref.isI31()) {
        const target_kind = gcRefKindFromHeapType(@as(core.HeapType, @enumFromInt(ops.to_type_idx)));
        if (target_kind) |kind| {
            should_branch = !GcRefKind.init(GcRefKind.I31).isSubtypeOf(kind);
        } else {
            should_branch = true;
        }
    } else {
        const obj_header = env.store.gc_heap.getHeader(gc_ref);
        const target_kind = gcRefKindFromHeapType(@as(core.HeapType, @enumFromInt(ops.to_type_idx)));
        if (target_kind) |kind| {
            const kind_bits: u32 = @as(u32, kind.bits) << 26;
            should_branch = !obj_header.isSubtypeOf(kind_bits);
        } else {
            const target_heap = @as(core.HeapType, @enumFromInt(ops.to_type_idx));
            if (target_heap.concreteType()) |target_type_idx| {
                const obj_idx = obj_header.type_index;
                const is_match = obj_idx == target_type_idx or blk: {
                    if (obj_idx < env.type_ancestors.len) {
                        for (env.type_ancestors[obj_idx]) |anc| {
                            if (anc == target_type_idx) break :blk true;
                        }
                    }
                    break :blk false;
                };
                should_branch = !is_match;
            } else {
                should_branch = true;
            }
        }
    }

    if (should_branch) {
        const target_ip: [*]u8 = @ptrFromInt(@as(usize, @intCast(@as(isize, @intCast(@intFromPtr(ip))) + ops.rel_target)));
        dispatch.dispatch(target_ip, slots, frame, env, r0, fp0);
    } else {
        dispatch.next(ip, stride(encode.OpsBrOnCast), slots, frame, env, r0, fp0);
    }
}

// ── any_convert_extern ───────────────────────────────────────────────────────

pub fn handle_any_convert_extern(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsConvertRef, ip);
    slots[ops.dst] = slots[ops.ref];
    dispatch.next(ip, stride(encode.OpsConvertRef), slots, frame, env, r0, fp0);
}

// ── extern_convert_any ───────────────────────────────────────────────────────

pub fn handle_extern_convert_any(ip: [*]u8, slots: [*]RawVal, frame: *DispatchState, env: *const ExecEnv, r0: u64, fp0: f64) callconv(.c) void {
    const ops = readOps(encode.OpsConvertRef, ip);
    slots[ops.dst] = slots[ops.ref];
    dispatch.next(ip, stride(encode.OpsConvertRef), slots, frame, env, r0, fp0);
}

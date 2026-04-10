const std = @import("std");
const ir = @import("../compiler/ir.zig");
const core = @import("core");
const host_mod = @import("../wasmz/host.zig");
const module_mod = @import("../wasmz/module.zig");
const store_mod = @import("../wasmz/store.zig");
const gc_mod = @import("./gc/root.zig");

const helper = core.helper;
const simd = core.simd;
const heap_type = core.heap_type;
const CompiledFunction = ir.CompiledFunction;
const CompiledDataSegment = module_mod.CompiledDataSegment;
const CompiledElemSegment = module_mod.CompiledElemSegment;
const FuncType = core.func_type.FuncType;
const CompositeType = core.CompositeType;
const StructType = core.StructType;
const ArrayType = core.ArrayType;
const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const GcHeap = gc_mod.GcHeap;
const GcHeader = gc_mod.GcHeader;
const GcRef = core.GcRef;
const GcRefKind = core.GcRefKind;
const StructLayout = gc_mod.StructLayout;
const ArrayLayout = gc_mod.ArrayLayout;
const gcRefKindFromHeapType = heap_type.gcRefKindFromHeapType;
pub const RawVal = core.raw.RawVal;
pub const Global = core.Global;
pub const Trap = core.Trap;
pub const TrapCode = core.TrapCode;
pub const HostFunc = host_mod.HostFunc;
const HostContext = host_mod.HostContext;
const HostInstance = host_mod.HostInstance;

/// VM execute result either be void or Wasm trap
/// Allocation failures and other host environment errors are still propagated through Zig error unions (Allocator.Error).
pub const ExecResult = union(enum) {
    /// Normal return, ?RawVal is null for void functions
    ok: ?RawVal,
    /// Runtime trap (MemoryOutOfBounds, UnreachableCodeReached, etc.)
    trap: Trap,
};

pub const ExecEnv = struct {
    store: *Store,
    host_instance: *HostInstance,
    globals: []Global,
    memory: []u8,
    functions: []const CompiledFunction,
    func_types: []const FuncType,
    host_funcs: []const HostFunc,
    tables: [][]u32,
    func_type_indices: []const u32,
    data_segments: []const CompiledDataSegment,
    data_segments_dropped: []bool,
    elem_segments: []const CompiledElemSegment,
    elem_segments_dropped: []bool,
    composite_types: []const CompositeType,
    struct_layouts: []const ?StructLayout,
    array_layouts: []const ?ArrayLayout,
};

/// One call frame is one function call
///
/// - func:  be called fn（owned ops and call_args reference, does not own their lifetime）
/// - slots: allocated slots for the current frame (allocated by VM, freed when the frame is popped)
/// - pc:    program counter for the current frame (index of the next op to execute)
/// - dst:   slot in the caller frame to receive the return value (null for void functions)
const CallFrame = struct {
    func: CompiledFunction,
    slots: []RawVal,
    pc: usize,
    // return value destination slot in caller frame (null if void function)
    dst: ?ir.Slot,
};

/// Compute effective address and perform bounds check.
/// Returns the effective address (EA = base +% offset) if in-bounds, null if out-of-bounds.
inline fn effectiveAddr(slots: []RawVal, addr_slot: u32, offset: u32, size: usize, memory: []u8) ?u32 {
    const base = slots[addr_slot].readAs(u32);
    const ea = base +% offset;
    if (@as(usize, ea) + size > memory.len) return null;
    return ea;
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

inline fn reinterpretUnsignedAsSigned(comptime T: type, value: UnsignedOf(T)) T {
    return @as(T, @bitCast(value));
}

fn invokeHostCall(
    self: *VM,
    store: *Store,
    host_instance: *HostInstance,
    host_func: HostFunc,
    arg_slots: []const ir.Slot,
    slots: []RawVal,
    result_len: usize,
) Allocator.Error!ExecResult {
    const host_params = try self.allocator.alloc(RawVal, arg_slots.len);
    defer self.allocator.free(host_params);
    for (arg_slots, 0..) |arg_slot, i| {
        host_params[i] = slots[arg_slot];
    }

    const host_results = try self.allocator.alloc(RawVal, result_len);
    defer self.allocator.free(host_results);
    @memset(host_results, std.mem.zeroes(RawVal));

    var ctx = HostContext.init(store, host_instance, host_func.host_data);
    host_func.call(&ctx, host_params, host_results) catch |err| switch (err) {
        error.HostTrap => return .{ .trap = ctx.takeTrap() },
        error.OutOfMemory => return error.OutOfMemory,
    };

    return .{ .ok = if (result_len > 0) host_results[0] else null };
}

pub const VM = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) VM {
        return .{ .allocator = allocator };
    }

    /// Execute a compiled function inside a concrete runtime environment.
    pub fn execute(
        self: *VM,
        func: CompiledFunction,
        params: []const RawVal,
        env: ExecEnv,
    ) Allocator.Error!ExecResult {
        const store = env.store;
        const host_instance = env.host_instance;
        const globals = env.globals;
        const memory = env.memory;
        const functions = env.functions;
        const func_types = env.func_types;
        const host_funcs = env.host_funcs;
        const tables = env.tables;
        const func_type_indices = env.func_type_indices;
        const data_segments = env.data_segments;
        const data_segments_dropped = env.data_segments_dropped;
        const elem_segments = env.elem_segments;
        const elem_segments_dropped = env.elem_segments_dropped;
        const composite_types = env.composite_types;
        const struct_layouts = env.struct_layouts;
        const array_layouts = env.array_layouts;

        // ── Initialize entry frame ─────────────────────────────────────────────
        const entry_slots_len: usize = @max(
            @as(usize, @intCast(func.slots_len)),
            params.len,
        );
        var entry_slots = try self.allocator.alloc(RawVal, entry_slots_len);
        // entry_slots's ownership is transferred to call_stack after append,
        // so we don't use errdefer and instead manually free on append failure.

        for (params, 0..) |param, i| {
            entry_slots[i] = param;
        }

        // Explicit call stack; entry frame dst=null (return value is collected directly from the top-level ret)
        var call_stack: std.ArrayListUnmanaged(CallFrame) = .empty;
        defer {
            // Ensure all frame slots are freed (stack is empty on normal exit, clean up remaining frames on error)
            for (call_stack.items) |frame| {
                self.allocator.free(frame.slots);
            }
            call_stack.deinit(self.allocator);
        }

        call_stack.append(self.allocator, .{
            .func = func,
            .slots = entry_slots,
            .pc = 0,
            .dst = null,
        }) catch |err| {
            self.allocator.free(entry_slots);
            return err;
        };
        // append success: entry_slots ownership transferred to call_stack
        // defer will handle final cleanup

        // ── Main execution loop ───────────────────────────────────────────────
        while (call_stack.items.len > 0) {
            // Get the current frame index (cannot hold a pointer because append may invalidate the slice)
            const frame_idx = call_stack.items.len - 1;
            const op = blk: {
                const frame = &call_stack.items[frame_idx];
                if (frame.pc >= frame.func.ops.items.len) {
                    // Function body naturally reached the end (void functions have no explicit ret)
                    break :blk ir.Op{ .ret = .{ .value = null } };
                }
                const o = frame.func.ops.items[frame.pc];
                frame.pc += 1;
                break :blk o;
            };

            // Bind the current frame's slots once per iteration.
            // slots points to separately-allocated memory; call_stack.append() does not invalidate it.
            const slots = call_stack.items[frame_idx].slots;

            switch (op) {
                .unreachable_ => {
                    return .{ .trap = Trap.fromTrapCode(.UnreachableCodeReached) };
                },

                // ── Constants ─────────────────────────────────────────────────
                inline .const_i32, .const_i64, .const_f32, .const_f64 => |inst| {
                    slots[inst.dst] = RawVal.from(inst.value);
                },
                .const_v128 => |inst| {
                    slots[inst.dst] = RawVal.from(inst.value);
                },

                // ── Reference type constants ──────────────────────────────────
                // ref.null: push the null reference sentinel (maxInt(u64) in low64).
                .const_ref_null => |inst| {
                    slots[inst.dst] = RawVal.fromBits64(std.math.maxInt(u64));
                },
                // ref.is_null: 1 if the reference is the null sentinel, else 0.
                .ref_is_null => |inst| {
                    const is_null: i32 = if (slots[inst.src].readAs(u64) == std.math.maxInt(u64)) 1 else 0;
                    slots[inst.dst] = RawVal.from(is_null);
                },
                // ref.func: push the function index as a funcref value (stored in low64).
                .ref_func => |inst| {
                    slots[inst.dst] = RawVal.fromBits64(@as(u64, inst.func_idx));
                },
                // ref.eq: 1 if lhs and rhs have the same raw bits, else 0.
                .ref_eq => |inst| {
                    const eq: i32 = if (slots[inst.lhs].readAs(u64) == slots[inst.rhs].readAs(u64)) 1 else 0;
                    slots[inst.dst] = RawVal.from(eq);
                },

                // ── Variable access ───────────────────────────────────────────
                .local_get => |inst| {
                    slots[inst.dst] = slots[inst.local];
                },
                .local_set => |inst| {
                    slots[inst.local] = slots[inst.src];
                },
                .global_get => |inst| {
                    slots[inst.dst] = globals[inst.global_idx].getRawValue();
                },
                .global_set => |inst| {
                    globals[inst.global_idx].value = slots[inst.src];
                },
                .copy => |inst| {
                    slots[inst.dst] = slots[inst.src];
                },

                // ── Control flow ──────────────────────────────────────────────
                .jump => |inst| {
                    call_stack.items[frame_idx].pc = inst.target;
                },
                .jump_if_z => |inst| {
                    if (slots[inst.cond].readAs(i32) == 0) {
                        call_stack.items[frame_idx].pc = inst.target;
                    }
                },
                .jump_table => |inst| {
                    const idx = slots[inst.index].readAs(u32);
                    const entry = if (idx < inst.targets_len) idx else inst.targets_len;
                    const target = call_stack.items[frame_idx].func.br_table_targets.items[inst.targets_start + entry];
                    call_stack.items[frame_idx].pc = target;
                },
                .select => |inst| {
                    const cond = slots[inst.cond].readAs(i32);
                    slots[inst.dst] = if (cond != 0) slots[inst.val1] else slots[inst.val2];
                },

                // ── Arithmetic: add / sub / mul (integer wrapping + float) ────
                inline .i32_add, .i64_add, .f32_add, .f64_add => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    const lhs = slots[inst.lhs].readAs(T);
                    const rhs = slots[inst.rhs].readAs(T);
                    slots[inst.dst] = RawVal.from(if (comptime @typeInfo(T) == .int) lhs +% rhs else lhs + rhs);
                },
                inline .i32_sub, .i64_sub, .f32_sub, .f64_sub => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    const lhs = slots[inst.lhs].readAs(T);
                    const rhs = slots[inst.rhs].readAs(T);
                    slots[inst.dst] = RawVal.from(if (comptime @typeInfo(T) == .int) lhs -% rhs else lhs - rhs);
                },
                inline .i32_mul, .i64_mul, .f32_mul, .f64_mul => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    const lhs = slots[inst.lhs].readAs(T);
                    const rhs = slots[inst.rhs].readAs(T);
                    slots[inst.dst] = RawVal.from(if (comptime @typeInfo(T) == .int) lhs *% rhs else lhs * rhs);
                },

                // ── Float division ────────────────────────────────────────────
                inline .f32_div, .f64_div => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(slots[inst.lhs].readAs(T) / slots[inst.rhs].readAs(T));
                },

                // ── Integer signed division (may trap) ────────────────────────
                inline .i32_div_s, .i64_div_s => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    const result = helper.divS(slots[inst.lhs].readAs(T), slots[inst.rhs].readAs(T)) catch |e| return .{ .trap = Trap.fromTrapCode(switch (e) {
                        error.IntegerDivisionByZero => .IntegerDivisionByZero,
                        error.IntegerOverflow => .IntegerOverflow,
                    }) };
                    slots[inst.dst] = RawVal.from(result);
                },

                // ── Integer unsigned division (may trap) ──────────────────────
                inline .i32_div_u, .i64_div_u => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    const U = std.meta.Int(.unsigned, @bitSizeOf(T));
                    const result = helper.divU(T, slots[inst.lhs].readAs(U), slots[inst.rhs].readAs(U)) catch return .{ .trap = Trap.fromTrapCode(.IntegerDivisionByZero) };
                    slots[inst.dst] = RawVal.from(@as(T, @bitCast(result)));
                },

                // ── Integer signed remainder (may trap) ───────────────────────
                inline .i32_rem_s, .i64_rem_s => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    const result = helper.remS(slots[inst.lhs].readAs(T), slots[inst.rhs].readAs(T)) catch return .{ .trap = Trap.fromTrapCode(.IntegerDivisionByZero) };
                    slots[inst.dst] = RawVal.from(result);
                },

                // ── Integer unsigned remainder (may trap) ─────────────────────
                inline .i32_rem_u, .i64_rem_u => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    const U = std.meta.Int(.unsigned, @bitSizeOf(T));
                    const result = helper.remU(T, slots[inst.lhs].readAs(U), slots[inst.rhs].readAs(U)) catch return .{ .trap = Trap.fromTrapCode(.IntegerDivisionByZero) };
                    slots[inst.dst] = RawVal.from(@as(T, @bitCast(result)));
                },

                // ── Bitwise and / or / xor ────────────────────────────────────
                inline .i32_and, .i64_and => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(slots[inst.lhs].readAs(T) & slots[inst.rhs].readAs(T));
                },
                inline .i32_or, .i64_or => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(slots[inst.lhs].readAs(T) | slots[inst.rhs].readAs(T));
                },
                inline .i32_xor, .i64_xor => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(slots[inst.lhs].readAs(T) ^ slots[inst.rhs].readAs(T));
                },

                // ── Shifts ────────────────────────────────────────────────────
                inline .i32_shl, .i64_shl => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(helper.shl(slots[inst.lhs].readAs(T), slots[inst.rhs].readAs(T)));
                },
                inline .i32_shr_s, .i64_shr_s => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(helper.shrS(slots[inst.lhs].readAs(T), slots[inst.rhs].readAs(T)));
                },
                inline .i32_shr_u, .i64_shr_u => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    const U = std.meta.Int(.unsigned, @bitSizeOf(T));
                    slots[inst.dst] = RawVal.from(@as(T, @bitCast(
                        helper.shrU(T, slots[inst.lhs].readAs(U), slots[inst.rhs].readAs(U)),
                    )));
                },

                // ── Rotates ───────────────────────────────────────────────────
                inline .i32_rotl, .i64_rotl => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(helper.rotl(slots[inst.lhs].readAs(T), slots[inst.rhs].readAs(T)));
                },
                inline .i32_rotr, .i64_rotr => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(helper.rotr(slots[inst.lhs].readAs(T), slots[inst.rhs].readAs(T)));
                },

                // ── Float binary (min / max / copysign) ───────────────────────
                inline .f32_min, .f64_min => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(helper.min(slots[inst.lhs].readAs(T), slots[inst.rhs].readAs(T)));
                },
                inline .f32_max, .f64_max => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(helper.max(slots[inst.lhs].readAs(T), slots[inst.rhs].readAs(T)));
                },
                inline .f32_copysign, .f64_copysign => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(helper.copySign(slots[inst.lhs].readAs(T), slots[inst.rhs].readAs(T)));
                },

                // ── Integer unary: clz / ctz / popcnt ────────────────────────
                inline .i32_clz, .i64_clz => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(helper.leadingZeros(slots[inst.src].readAs(T)));
                },
                inline .i32_ctz, .i64_ctz => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(helper.trailingZeros(slots[inst.src].readAs(T)));
                },
                inline .i32_popcnt, .i64_popcnt => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(helper.countOnes(slots[inst.src].readAs(T)));
                },

                // ── Integer unary: eqz ────────────────────────────────────────
                inline .i32_eqz, .i64_eqz => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(@as(i32, if (slots[inst.src].readAs(T) == 0) 1 else 0));
                },

                // ── Float unary ───────────────────────────────────────────────
                inline .f32_abs, .f64_abs => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(helper.abs(slots[inst.src].readAs(T)));
                },
                inline .f32_neg, .f64_neg => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(-slots[inst.src].readAs(T));
                },
                inline .f32_ceil, .f64_ceil => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(helper.ceil(slots[inst.src].readAs(T)));
                },
                inline .f32_floor, .f64_floor => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(helper.floor(slots[inst.src].readAs(T)));
                },
                inline .f32_trunc, .f64_trunc => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(helper.trunc(slots[inst.src].readAs(T)));
                },
                inline .f32_nearest, .f64_nearest => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(helper.nearest(slots[inst.src].readAs(T)));
                },
                inline .f32_sqrt, .f64_sqrt => |inst| {
                    const T = @TypeOf(inst).ValueType;
                    slots[inst.dst] = RawVal.from(helper.sqrt(slots[inst.src].readAs(T)));
                },

                // ── Numeric conversion: wrap / extend ───────────────────────
                .i32_wrap_i64 => |inst| {
                    const bits = @as(u32, @truncate(slots[inst.src].readAs(u64)));
                    slots[inst.dst] = RawVal.from(@as(i32, @bitCast(bits)));
                },
                .i64_extend_i32_s => |inst| {
                    slots[inst.dst] = RawVal.from(@as(i64, slots[inst.src].readAs(i32)));
                },
                .i64_extend_i32_u => |inst| {
                    slots[inst.dst] = RawVal.from(@as(i64, @intCast(slots[inst.src].readAs(u32))));
                },

                // ── Numeric conversion: float -> int (may trap) ─────────────
                inline .i32_trunc_f32_s, .i32_trunc_f64_s, .i64_trunc_f32_s, .i64_trunc_f64_s => |inst| {
                    const SrcT = @TypeOf(inst).SrcType;
                    const DstT = @TypeOf(inst).DstType;
                    const result = helper.tryTruncateInto(DstT, slots[inst.src].readAs(SrcT)) catch |err| return .{ .trap = trapFromTruncateError(err) };
                    slots[inst.dst] = RawVal.from(result);
                },
                inline .i32_trunc_f32_u, .i32_trunc_f64_u, .i64_trunc_f32_u, .i64_trunc_f64_u => |inst| {
                    const SrcT = @TypeOf(inst).SrcType;
                    const DstT = @TypeOf(inst).DstType;
                    const U = UnsignedOf(DstT);
                    const result = helper.tryTruncateInto(U, slots[inst.src].readAs(SrcT)) catch |err| return .{ .trap = trapFromTruncateError(err) };
                    slots[inst.dst] = RawVal.from(reinterpretUnsignedAsSigned(DstT, result));
                },

                // ── Numeric conversion: float -> int (saturating, non-trapping) ───
                inline .i32_trunc_sat_f32_s, .i32_trunc_sat_f64_s, .i64_trunc_sat_f32_s, .i64_trunc_sat_f64_s => |inst| {
                    const SrcT = @TypeOf(inst).SrcType;
                    const DstT = @TypeOf(inst).DstType;
                    slots[inst.dst] = RawVal.from(helper.truncateSaturateInto(DstT, slots[inst.src].readAs(SrcT)));
                },
                inline .i32_trunc_sat_f32_u, .i32_trunc_sat_f64_u, .i64_trunc_sat_f32_u, .i64_trunc_sat_f64_u => |inst| {
                    const SrcT = @TypeOf(inst).SrcType;
                    const DstT = @TypeOf(inst).DstType;
                    const U = UnsignedOf(DstT);
                    const result = helper.truncateSaturateInto(U, slots[inst.src].readAs(SrcT));
                    slots[inst.dst] = RawVal.from(reinterpretUnsignedAsSigned(DstT, result));
                },

                // ── Numeric conversion: int -> float ────────────────────────
                inline .f32_convert_i32_s, .f32_convert_i64_s, .f64_convert_i32_s, .f64_convert_i64_s => |inst| {
                    const SrcT = @TypeOf(inst).SrcType;
                    const DstT = @TypeOf(inst).DstType;
                    slots[inst.dst] = RawVal.from(@as(DstT, @floatFromInt(slots[inst.src].readAs(SrcT))));
                },
                inline .f32_convert_i32_u, .f32_convert_i64_u, .f64_convert_i32_u, .f64_convert_i64_u => |inst| {
                    const SrcT = @TypeOf(inst).SrcType;
                    const DstT = @TypeOf(inst).DstType;
                    const U = UnsignedOf(SrcT);
                    slots[inst.dst] = RawVal.from(@as(DstT, @floatFromInt(slots[inst.src].readAs(U))));
                },

                // ── Numeric conversion: float resize ────────────────────────
                inline .f32_demote_f64, .f64_promote_f32 => |inst| {
                    const SrcT = @TypeOf(inst).SrcType;
                    const DstT = @TypeOf(inst).DstType;
                    slots[inst.dst] = RawVal.from(@as(DstT, @floatCast(slots[inst.src].readAs(SrcT))));
                },

                // ── Reinterpret ──────────────────────────────────────────────
                inline .i32_reinterpret_f32, .i64_reinterpret_f64, .f32_reinterpret_i32, .f64_reinterpret_i64 => |inst| {
                    const SrcT = @TypeOf(inst).SrcType;
                    const DstT = @TypeOf(inst).DstType;
                    slots[inst.dst] = RawVal.from(@as(DstT, @bitCast(slots[inst.src].readAs(SrcT))));
                },

                // ── Sign-extension ───────────────────────────────────────────
                .i32_extend8_s => |inst| {
                    slots[inst.dst] = RawVal.from(helper.signExtendFrom(i8, slots[inst.src].readAs(i32)));
                },
                .i32_extend16_s => |inst| {
                    slots[inst.dst] = RawVal.from(helper.signExtendFrom(i16, slots[inst.src].readAs(i32)));
                },
                .i64_extend8_s => |inst| {
                    slots[inst.dst] = RawVal.from(helper.signExtendFrom(i8, slots[inst.src].readAs(i64)));
                },
                .i64_extend16_s => |inst| {
                    slots[inst.dst] = RawVal.from(helper.signExtendFrom(i16, slots[inst.src].readAs(i64)));
                },
                .i64_extend32_s => |inst| {
                    slots[inst.dst] = RawVal.from(helper.signExtendFrom(i32, slots[inst.src].readAs(i64)));
                },

                // ── Comparisons: eq / ne (all 4 types) ───────────────────────
                inline .i32_eq, .i64_eq, .f32_eq, .f64_eq => |inst| {
                    const T = @TypeOf(inst).InputType;
                    slots[inst.dst] = RawVal.from(@as(i32, if (slots[inst.lhs].readAs(T) == slots[inst.rhs].readAs(T)) 1 else 0));
                },
                inline .i32_ne, .i64_ne, .f32_ne, .f64_ne => |inst| {
                    const T = @TypeOf(inst).InputType;
                    slots[inst.dst] = RawVal.from(@as(i32, if (slots[inst.lhs].readAs(T) != slots[inst.rhs].readAs(T)) 1 else 0));
                },

                // ── Signed / float comparisons: lt / gt / le / ge ────────────
                inline .i32_lt_s, .i64_lt_s, .f32_lt, .f64_lt => |inst| {
                    const T = @TypeOf(inst).InputType;
                    slots[inst.dst] = RawVal.from(@as(i32, if (slots[inst.lhs].readAs(T) < slots[inst.rhs].readAs(T)) 1 else 0));
                },
                inline .i32_gt_s, .i64_gt_s, .f32_gt, .f64_gt => |inst| {
                    const T = @TypeOf(inst).InputType;
                    slots[inst.dst] = RawVal.from(@as(i32, if (slots[inst.lhs].readAs(T) > slots[inst.rhs].readAs(T)) 1 else 0));
                },
                inline .i32_le_s, .i64_le_s, .f32_le, .f64_le => |inst| {
                    const T = @TypeOf(inst).InputType;
                    slots[inst.dst] = RawVal.from(@as(i32, if (slots[inst.lhs].readAs(T) <= slots[inst.rhs].readAs(T)) 1 else 0));
                },
                inline .i32_ge_s, .i64_ge_s, .f32_ge, .f64_ge => |inst| {
                    const T = @TypeOf(inst).InputType;
                    slots[inst.dst] = RawVal.from(@as(i32, if (slots[inst.lhs].readAs(T) >= slots[inst.rhs].readAs(T)) 1 else 0));
                },

                // ── Unsigned integer comparisons: lt_u / gt_u / le_u / ge_u ──
                inline .i32_lt_u, .i64_lt_u => |inst| {
                    const T = @TypeOf(inst).InputType;
                    const U = std.meta.Int(.unsigned, @bitSizeOf(T));
                    slots[inst.dst] = RawVal.from(@as(i32, if (slots[inst.lhs].readAs(U) < slots[inst.rhs].readAs(U)) 1 else 0));
                },
                inline .i32_gt_u, .i64_gt_u => |inst| {
                    const T = @TypeOf(inst).InputType;
                    const U = std.meta.Int(.unsigned, @bitSizeOf(T));
                    slots[inst.dst] = RawVal.from(@as(i32, if (slots[inst.lhs].readAs(U) > slots[inst.rhs].readAs(U)) 1 else 0));
                },
                inline .i32_le_u, .i64_le_u => |inst| {
                    const T = @TypeOf(inst).InputType;
                    const U = std.meta.Int(.unsigned, @bitSizeOf(T));
                    slots[inst.dst] = RawVal.from(@as(i32, if (slots[inst.lhs].readAs(U) <= slots[inst.rhs].readAs(U)) 1 else 0));
                },
                inline .i32_ge_u, .i64_ge_u => |inst| {
                    const T = @TypeOf(inst).InputType;
                    const U = std.meta.Int(.unsigned, @bitSizeOf(T));
                    slots[inst.dst] = RawVal.from(@as(i32, if (slots[inst.lhs].readAs(U) >= slots[inst.rhs].readAs(U)) 1 else 0));
                },

                .simd_unary => |inst| {
                    slots[inst.dst] = simd.executeUnary(inst.opcode, slots[inst.src]);
                },
                .simd_binary => |inst| {
                    slots[inst.dst] = simd.executeBinary(inst.opcode, slots[inst.lhs], slots[inst.rhs]);
                },
                .simd_ternary => |inst| {
                    slots[inst.dst] = simd.executeTernary(inst.opcode, slots[inst.first], slots[inst.second], slots[inst.third]);
                },
                .simd_compare => |inst| {
                    slots[inst.dst] = simd.executeCompare(inst.opcode, slots[inst.lhs], slots[inst.rhs]);
                },
                .simd_shift_scalar => |inst| {
                    slots[inst.dst] = simd.executeShift(inst.opcode, slots[inst.lhs], slots[inst.rhs]);
                },
                .simd_extract_lane => |inst| {
                    slots[inst.dst] = simd.extractLane(inst.opcode, slots[inst.src], inst.lane);
                },
                .simd_replace_lane => |inst| {
                    slots[inst.dst] = simd.replaceLane(inst.opcode, slots[inst.src_vec], slots[inst.src_lane], inst.lane);
                },
                .simd_shuffle => |inst| {
                    slots[inst.dst] = simd.shuffleVectors(slots[inst.lhs], slots[inst.rhs], inst.lanes);
                },
                .simd_load => |inst| {
                    const access_size: usize = if (simd.isLaneLoadOpcode(inst.opcode))
                        simd.laneImmediateFromOpcode(inst.opcode)
                    else switch (inst.opcode) {
                        .v128_load => 16,
                        .i16x8_load8x8_s, .i16x8_load8x8_u => 8,
                        .i32x4_load16x4_s, .i32x4_load16x4_u => 8,
                        .i64x2_load32x2_s, .i64x2_load32x2_u => 8,
                        .v8x16_load_splat => 1,
                        .v16x8_load_splat => 2,
                        .v32x4_load_splat, .v128_load32_zero => 4,
                        .v64x2_load_splat, .v128_load64_zero => 8,
                        else => unreachable,
                    };
                    _ = effectiveAddr(slots, inst.addr, inst.offset, access_size, memory) orelse {
                        return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    };
                    slots[inst.dst] = RawVal.from(simd.load(
                        inst.opcode,
                        memory,
                        slots[inst.addr].readAs(u32),
                        inst.offset,
                        inst.lane,
                        if (inst.src_vec) |slot_idx| slots[slot_idx] else null,
                    ));
                },
                .simd_store => |inst| {
                    const access_size: usize = if (simd.isLaneStoreOpcode(inst.opcode))
                        simd.laneImmediateFromOpcode(inst.opcode)
                    else switch (inst.opcode) {
                        .v128_store => 16,
                        else => unreachable,
                    };
                    _ = effectiveAddr(slots, inst.addr, inst.offset, access_size, memory) orelse {
                        return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    };
                    simd.store(inst.opcode, memory, slots[inst.addr].readAs(u32), inst.offset, inst.lane, slots[inst.src]);
                },

                // ── fn call ────────────────────────────────────────────────────
                .call => |inst| {
                    // Collect the argument values from the current (caller) frame.
                    // Capture caller_func before potential call_stack reallocation.
                    const caller_func = call_stack.items[frame_idx].func;
                    const arg_slots = caller_func.call_args.items[inst.args_start .. inst.args_start + inst.args_len];

                    if (inst.func_idx < host_funcs.len) {
                        const host_result = try invokeHostCall(
                            self,
                            store,
                            host_instance,
                            host_funcs[inst.func_idx],
                            arg_slots,
                            slots,
                            func_types[func_type_indices[inst.func_idx]].results().len,
                        );
                        switch (host_result) {
                            .trap => |t| return .{ .trap = t },
                            .ok => |ret_val| {
                                if (inst.dst) |dst_slot| {
                                    if (ret_val) |rv| {
                                        slots[dst_slot] = rv;
                                    }
                                }
                            },
                        }
                    } else {
                        // ── Local (compiled) function call ──────────────────
                        const callee = functions[inst.func_idx];

                        // Allocate slots for the callee (at least enough to hold the parameters).
                        const callee_slots_len: usize = @max(
                            @as(usize, @intCast(callee.slots_len)),
                            arg_slots.len,
                        );
                        const callee_slots = try self.allocator.alloc(RawVal, callee_slots_len);
                        // Initialize to zero (unused local variables should be 0).
                        @memset(callee_slots, std.mem.zeroes(RawVal));

                        // Copy argument values from caller slots to callee slots 0..n.
                        // slots points to separately-allocated memory; it remains valid after append.
                        for (arg_slots, 0..) |arg_slot, i| {
                            callee_slots[i] = slots[arg_slot];
                        }

                        const callee_dst = inst.dst;
                        call_stack.append(self.allocator, .{
                            .func = callee,
                            .slots = callee_slots,
                            .pc = 0,
                            .dst = callee_dst,
                        }) catch |err| {
                            self.allocator.free(callee_slots);
                            return err;
                        };
                        // append may reallocate call_stack.items; slots still valid (external allocation)
                    }
                },

                // ── indirect function call (call_indirect) ──────────────────
                .call_indirect => |inst| {
                    const caller_func = call_stack.items[frame_idx].func;
                    const arg_slots = caller_func.call_args.items[inst.args_start .. inst.args_start + inst.args_len];

                    // 1. Read runtime table index from slot.
                    const raw_index = slots[inst.index].readAs(u32);

                    // 2. Bounds check against the table.
                    if (inst.table_index >= tables.len) return .{ .trap = Trap.fromTrapCode(.TableOutOfBounds) };
                    const table = tables[inst.table_index];
                    if (raw_index >= table.len) return .{ .trap = Trap.fromTrapCode(.TableOutOfBounds) };

                    // 3. Resolve callee func_idx from the table.
                    const callee_func_idx = table[raw_index];

                    // 4. Null-element check (treat u32 max as null/uninitialized).
                    if (callee_func_idx == std.math.maxInt(u32)) return .{ .trap = Trap.fromTrapCode(.IndirectCallToNull) };

                    // 5. Signature check: callee's type index must match the expected type index.
                    if (callee_func_idx >= func_type_indices.len) return .{ .trap = Trap.fromTrapCode(.BadSignature) };
                    if (func_type_indices[callee_func_idx] != inst.type_index) return .{ .trap = Trap.fromTrapCode(.BadSignature) };

                    // 6. Dispatch (same logic as .call).
                    if (callee_func_idx < host_funcs.len) {
                        const host_result = try invokeHostCall(
                            self,
                            store,
                            host_instance,
                            host_funcs[callee_func_idx],
                            arg_slots,
                            slots,
                            func_types[func_type_indices[callee_func_idx]].results().len,
                        );
                        switch (host_result) {
                            .trap => |t| return .{ .trap = t },
                            .ok => |ret_val| {
                                if (inst.dst) |dst_slot| {
                                    if (ret_val) |rv| {
                                        slots[dst_slot] = rv;
                                    }
                                }
                            },
                        }
                    } else {
                        // ── Local (compiled) function call ──────────────────
                        const callee = functions[callee_func_idx];
                        const callee_slots_len: usize = @max(
                            @as(usize, @intCast(callee.slots_len)),
                            arg_slots.len,
                        );
                        const callee_slots = try self.allocator.alloc(RawVal, callee_slots_len);
                        @memset(callee_slots, std.mem.zeroes(RawVal));

                        // slots remains valid after append (external allocation)
                        for (arg_slots, 0..) |arg_slot, i| {
                            callee_slots[i] = slots[arg_slot];
                        }

                        const callee_dst = inst.dst;
                        call_stack.append(self.allocator, .{
                            .func = callee,
                            .slots = callee_slots,
                            .pc = 0,
                            .dst = callee_dst,
                        }) catch |err| {
                            self.allocator.free(callee_slots);
                            return err;
                        };
                    }
                },

                // ── tail call (return_call) ─────────────────────────────────────────
                .return_call => |inst| {
                    const caller_func = call_stack.items[frame_idx].func;
                    const arg_slots = caller_func.call_args.items[inst.args_start .. inst.args_start + inst.args_len];

                    if (inst.func_idx < host_funcs.len) {
                        // Tail call to host function: invoke and return result directly
                        const host_result = try invokeHostCall(
                            self,
                            store,
                            host_instance,
                            host_funcs[inst.func_idx],
                            arg_slots,
                            slots,
                            func_types[func_type_indices[inst.func_idx]].results().len,
                        );
                        switch (host_result) {
                            .trap => |t| return .{ .trap = t },
                            .ok => |ret_val| {
                                // Pop current frame and return result to caller's caller
                                const popped_frame = call_stack.pop().?;
                                self.allocator.free(popped_frame.slots);
                                if (call_stack.items.len == 0) {
                                    return .{ .ok = ret_val };
                                }
                                const caller_idx = call_stack.items.len - 1;
                                if (popped_frame.dst) |dst_slot| {
                                    if (ret_val) |rv| {
                                        call_stack.items[caller_idx].slots[dst_slot] = rv;
                                    }
                                }
                            },
                        }
                    } else {
                        // Tail call to local function: replace current frame
                        const callee = functions[inst.func_idx];
                        const callee_slots_len: usize = @max(
                            @as(usize, @intCast(callee.slots_len)),
                            arg_slots.len,
                        );
                        const callee_slots = try self.allocator.alloc(RawVal, callee_slots_len);
                        @memset(callee_slots, std.mem.zeroes(RawVal));

                        for (arg_slots, 0..) |arg_slot, i| {
                            callee_slots[i] = slots[arg_slot];
                        }

                        // Preserve the dst from current frame (return to caller's caller)
                        const tail_dst = call_stack.items[frame_idx].dst;

                        // Free current frame slots
                        self.allocator.free(call_stack.items[frame_idx].slots);

                        // Replace current frame with callee
                        call_stack.items[frame_idx] = .{
                            .func = callee,
                            .slots = callee_slots,
                            .pc = 0,
                            .dst = tail_dst,
                        };
                    }
                },

                // ── tail call indirect (return_call_indirect) ──────────────────────
                .return_call_indirect => |inst| {
                    const caller_func = call_stack.items[frame_idx].func;
                    const arg_slots = caller_func.call_args.items[inst.args_start .. inst.args_start + inst.args_len];

                    // 1. Read runtime table index from slot.
                    const raw_index = slots[inst.index].readAs(u32);

                    // 2. Bounds check against the table.
                    if (inst.table_index >= tables.len) return .{ .trap = Trap.fromTrapCode(.TableOutOfBounds) };
                    const table = tables[inst.table_index];
                    if (raw_index >= table.len) return .{ .trap = Trap.fromTrapCode(.TableOutOfBounds) };

                    // 3. Resolve callee func_idx from the table.
                    const callee_func_idx = table[raw_index];

                    // 4. Null-element check.
                    if (callee_func_idx == std.math.maxInt(u32)) return .{ .trap = Trap.fromTrapCode(.IndirectCallToNull) };

                    // 5. Signature check.
                    if (callee_func_idx >= func_type_indices.len) return .{ .trap = Trap.fromTrapCode(.BadSignature) };
                    if (func_type_indices[callee_func_idx] != inst.type_index) return .{ .trap = Trap.fromTrapCode(.BadSignature) };

                    // 6. Dispatch
                    if (callee_func_idx < host_funcs.len) {
                        // Tail call to host function
                        const host_result = try invokeHostCall(
                            self,
                            store,
                            host_instance,
                            host_funcs[callee_func_idx],
                            arg_slots,
                            slots,
                            func_types[func_type_indices[callee_func_idx]].results().len,
                        );
                        switch (host_result) {
                            .trap => |t| return .{ .trap = t },
                            .ok => |ret_val| {
                                const popped_frame = call_stack.pop().?;
                                self.allocator.free(popped_frame.slots);
                                if (call_stack.items.len == 0) {
                                    return .{ .ok = ret_val };
                                }
                                const caller_idx = call_stack.items.len - 1;
                                if (popped_frame.dst) |dst_slot| {
                                    if (ret_val) |rv| {
                                        call_stack.items[caller_idx].slots[dst_slot] = rv;
                                    }
                                }
                            },
                        }
                    } else {
                        // Tail call to local function: replace current frame
                        const callee = functions[callee_func_idx];
                        const callee_slots_len: usize = @max(
                            @as(usize, @intCast(callee.slots_len)),
                            arg_slots.len,
                        );
                        const callee_slots = try self.allocator.alloc(RawVal, callee_slots_len);
                        @memset(callee_slots, std.mem.zeroes(RawVal));

                        for (arg_slots, 0..) |arg_slot, i| {
                            callee_slots[i] = slots[arg_slot];
                        }

                        // Preserve the dst from current frame
                        const tail_dst = call_stack.items[frame_idx].dst;

                        // Free current frame slots
                        self.allocator.free(call_stack.items[frame_idx].slots);

                        // Replace current frame with callee
                        call_stack.items[frame_idx] = .{
                            .func = callee,
                            .slots = callee_slots,
                            .pc = 0,
                            .dst = tail_dst,
                        };
                    }
                },

                // ── i32 Memory load ───────────────────────────────────────────
                .i32_load => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 4, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    slots[inst.dst] = RawVal.from(std.mem.readInt(i32, memory[ea..][0..4], .little));
                },
                .i32_load8_s => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 1, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    slots[inst.dst] = RawVal.from(@as(i32, @as(i8, @bitCast(memory[ea]))));
                },
                .i32_load8_u => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 1, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    slots[inst.dst] = RawVal.from(@as(i32, memory[ea]));
                },
                .i32_load16_s => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 2, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    const half: i16 = @bitCast(std.mem.readInt(u16, memory[ea..][0..2], .little));
                    slots[inst.dst] = RawVal.from(@as(i32, half));
                },
                .i32_load16_u => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 2, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    slots[inst.dst] = RawVal.from(@as(i32, std.mem.readInt(u16, memory[ea..][0..2], .little)));
                },

                // ── i64 Memory load ───────────────────────────────────────────
                .i64_load => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 8, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    slots[inst.dst] = RawVal.from(std.mem.readInt(i64, memory[ea..][0..8], .little));
                },
                .i64_load8_s => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 1, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    slots[inst.dst] = RawVal.from(@as(i64, @as(i8, @bitCast(memory[ea]))));
                },
                .i64_load8_u => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 1, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    slots[inst.dst] = RawVal.from(@as(i64, memory[ea]));
                },
                .i64_load16_s => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 2, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    const half: i16 = @bitCast(std.mem.readInt(u16, memory[ea..][0..2], .little));
                    slots[inst.dst] = RawVal.from(@as(i64, half));
                },
                .i64_load16_u => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 2, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    slots[inst.dst] = RawVal.from(@as(i64, std.mem.readInt(u16, memory[ea..][0..2], .little)));
                },
                .i64_load32_s => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 4, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    const word: i32 = @bitCast(std.mem.readInt(u32, memory[ea..][0..4], .little));
                    slots[inst.dst] = RawVal.from(@as(i64, word));
                },
                .i64_load32_u => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 4, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    slots[inst.dst] = RawVal.from(@as(i64, std.mem.readInt(u32, memory[ea..][0..4], .little)));
                },

                // ── f32 / f64 Memory load ─────────────────────────────────────
                .f32_load => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 4, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    const bits = std.mem.readInt(u32, memory[ea..][0..4], .little);
                    slots[inst.dst] = RawVal.from(@as(f32, @bitCast(bits)));
                },
                .f64_load => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 8, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    const bits = std.mem.readInt(u64, memory[ea..][0..8], .little);
                    slots[inst.dst] = RawVal.from(@as(f64, @bitCast(bits)));
                },

                // ── i32 Memory store ──────────────────────────────────────────
                .i32_store => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 4, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    std.mem.writeInt(i32, memory[ea..][0..4], slots[inst.src].readAs(i32), .little);
                },
                .i32_store8 => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 1, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    memory[ea] = @truncate(@as(u32, @bitCast(slots[inst.src].readAs(i32))));
                },
                .i32_store16 => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 2, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    std.mem.writeInt(u16, memory[ea..][0..2], @truncate(@as(u32, @bitCast(slots[inst.src].readAs(i32)))), .little);
                },

                // ── i64 Memory store ──────────────────────────────────────────
                .i64_store => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 8, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    std.mem.writeInt(i64, memory[ea..][0..8], slots[inst.src].readAs(i64), .little);
                },
                .i64_store8 => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 1, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    memory[ea] = @truncate(@as(u64, @bitCast(slots[inst.src].readAs(i64))));
                },
                .i64_store16 => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 2, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    std.mem.writeInt(u16, memory[ea..][0..2], @truncate(@as(u64, @bitCast(slots[inst.src].readAs(i64)))), .little);
                },
                .i64_store32 => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 4, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    std.mem.writeInt(u32, memory[ea..][0..4], @truncate(@as(u64, @bitCast(slots[inst.src].readAs(i64)))), .little);
                },

                // ── f32 / f64 Memory store ────────────────────────────────────
                .f32_store => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 4, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    std.mem.writeInt(u32, memory[ea..][0..4], @as(u32, @bitCast(slots[inst.src].readAs(f32))), .little);
                },
                .f64_store => |inst| {
                    const ea = effectiveAddr(slots, inst.addr, inst.offset, 8, memory) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    std.mem.writeInt(u64, memory[ea..][0..8], @as(u64, @bitCast(slots[inst.src].readAs(f64))), .little);
                },

                // ── Bulk memory instructions ────────────────────────────────────────
                .memory_init => |inst| {
                    const dst_addr = slots[inst.dst_addr].readAs(u32);
                    const src_offset = slots[inst.src_offset].readAs(u32);
                    const len = slots[inst.len].readAs(u32);

                    if (inst.segment_idx >= data_segments.len) return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    if (data_segments_dropped[inst.segment_idx]) {
                        return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    }

                    const segment = data_segments[inst.segment_idx];
                    const src_end = src_offset +% len;
                    const dst_end = dst_addr +% len;
                    if (src_end > segment.data.len or dst_end > memory.len) {
                        return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    }
                    @memcpy(memory[dst_addr..][0..len], segment.data[src_offset..][0..len]);
                },
                .data_drop => |inst| {
                    if (inst.segment_idx >= data_segments.len) return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    data_segments_dropped[inst.segment_idx] = true;
                },
                .memory_copy => |inst| {
                    const dst_addr = slots[inst.dst_addr].readAs(u32);
                    const src_addr = slots[inst.src_addr].readAs(u32);
                    const len = slots[inst.len].readAs(u32);

                    const src_end = src_addr +% len;
                    const dst_end = dst_addr +% len;
                    if (src_end > memory.len or dst_end > memory.len) {
                        return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    }

                    if (len > 0) {
                        if (dst_addr < src_addr) {
                            @memcpy(memory[dst_addr .. dst_addr + len], memory[src_addr .. src_addr + len]);
                        } else if (dst_addr > src_addr) {
                            var i: usize = len;
                            while (i > 0) {
                                i -= 1;
                                memory[dst_addr + i] = memory[src_addr + i];
                            }
                        }
                    }
                },
                .memory_fill => |inst| {
                    const dst_addr = slots[inst.dst_addr].readAs(u32);
                    const value = slots[inst.value].readAs(u32);
                    const len = slots[inst.len].readAs(u32);

                    const dst_end = dst_addr +% len;
                    if (dst_end > memory.len) {
                        return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    }
                    @memset(memory[dst_addr .. dst_addr + len], @truncate(value));
                },

                // ── Table instructions ───────────────────────────────────────────────
                .table_get => |inst| {
                    if (inst.table_index >= tables.len) return .{ .trap = Trap.fromTrapCode(.TableOutOfBounds) };
                    const table = tables[inst.table_index];
                    const idx = slots[inst.index].readAs(u32);
                    if (idx >= table.len) return .{ .trap = Trap.fromTrapCode(.TableOutOfBounds) };
                    const func_idx = table[idx];
                    // Convert u32 table entry to u64 funcref: null sentinel maps to maxInt(u64)
                    const ref: u64 = if (func_idx == std.math.maxInt(u32)) std.math.maxInt(u64) else @as(u64, func_idx);
                    slots[inst.dst] = RawVal.fromBits64(ref);
                },
                .table_set => |inst| {
                    if (inst.table_index >= tables.len) return .{ .trap = Trap.fromTrapCode(.TableOutOfBounds) };
                    const table = tables[inst.table_index];
                    const idx = slots[inst.index].readAs(u32);
                    if (idx >= table.len) return .{ .trap = Trap.fromTrapCode(.TableOutOfBounds) };
                    const ref = slots[inst.value].readAs(u64);
                    // Convert funcref RawVal to u32 table entry: null sentinel maps to maxInt(u32)
                    tables[inst.table_index][idx] = if (ref == std.math.maxInt(u64)) std.math.maxInt(u32) else @as(u32, @truncate(ref));
                },
                .table_size => |inst| {
                    if (inst.table_index >= tables.len) return .{ .trap = Trap.fromTrapCode(.TableOutOfBounds) };
                    const size: i32 = @intCast(tables[inst.table_index].len);
                    slots[inst.dst] = RawVal.from(size);
                },
                .table_grow => |inst| {
                    const result: i32 = blk_table_grow: {
                        if (inst.table_index >= tables.len) break :blk_table_grow -1;
                        const old_len = tables[inst.table_index].len;
                        const delta = slots[inst.delta].readAs(u32);
                        const new_len = std.math.add(usize, old_len, @as(usize, delta)) catch break :blk_table_grow -1;
                        const init_ref = slots[inst.init].readAs(u64);
                        const init_val: u32 = if (init_ref == std.math.maxInt(u64)) std.math.maxInt(u32) else @as(u32, @truncate(init_ref));
                        const new_slice = self.allocator.realloc(tables[inst.table_index], new_len) catch break :blk_table_grow -1;
                        tables[inst.table_index] = new_slice;
                        @memset(tables[inst.table_index][old_len..], init_val);
                        break :blk_table_grow @intCast(old_len);
                    };
                    slots[inst.dst] = RawVal.from(result);
                },
                .table_fill => |inst| {
                    if (inst.table_index >= tables.len) return .{ .trap = Trap.fromTrapCode(.TableOutOfBounds) };
                    const table = tables[inst.table_index];
                    const dst_idx = slots[inst.dst_idx].readAs(u32);
                    const len = slots[inst.len].readAs(u32);
                    const end = dst_idx +% len;
                    if (end > table.len) return .{ .trap = Trap.fromTrapCode(.TableOutOfBounds) };
                    const ref = slots[inst.value].readAs(u64);
                    const val: u32 = if (ref == std.math.maxInt(u64)) std.math.maxInt(u32) else @as(u32, @truncate(ref));
                    @memset(tables[inst.table_index][dst_idx..][0..len], val);
                },
                .table_copy => |inst| {
                    if (inst.dst_table >= tables.len or inst.src_table >= tables.len) return .{ .trap = Trap.fromTrapCode(.TableOutOfBounds) };
                    const dst_tbl = tables[inst.dst_table];
                    const src_tbl = tables[inst.src_table];
                    const dst_idx = slots[inst.dst_idx].readAs(u32);
                    const src_idx = slots[inst.src_idx].readAs(u32);
                    const len = slots[inst.len].readAs(u32);
                    const src_end = src_idx +% len;
                    const dst_end = dst_idx +% len;
                    if (src_end > src_tbl.len or dst_end > dst_tbl.len) return .{ .trap = Trap.fromTrapCode(.TableOutOfBounds) };
                    if (len > 0) {
                        if (inst.dst_table == inst.src_table) {
                            // Same table: use memmove semantics (handle overlaps)
                            if (dst_idx < src_idx) {
                                @memcpy(tables[inst.dst_table][dst_idx..][0..len], tables[inst.src_table][src_idx..][0..len]);
                            } else if (dst_idx > src_idx) {
                                var i: usize = len;
                                while (i > 0) {
                                    i -= 1;
                                    tables[inst.dst_table][dst_idx + i] = tables[inst.src_table][src_idx + i];
                                }
                            }
                        } else {
                            @memcpy(tables[inst.dst_table][dst_idx..][0..len], tables[inst.src_table][src_idx..][0..len]);
                        }
                    }
                },
                .table_init => |inst| {
                    if (inst.table_index >= tables.len) return .{ .trap = Trap.fromTrapCode(.TableOutOfBounds) };
                    if (inst.segment_idx >= elem_segments.len) return .{ .trap = Trap.fromTrapCode(.TableOutOfBounds) };
                    if (elem_segments_dropped[inst.segment_idx]) return .{ .trap = Trap.fromTrapCode(.TableOutOfBounds) };
                    const seg = elem_segments[inst.segment_idx];
                    const dst_idx = slots[inst.dst_idx].readAs(u32);
                    const src_offset = slots[inst.src_offset].readAs(u32);
                    const len = slots[inst.len].readAs(u32);
                    const src_end = src_offset +% len;
                    const dst_end = dst_idx +% len;
                    if (src_end > seg.func_indices.len or dst_end > tables[inst.table_index].len) {
                        return .{ .trap = Trap.fromTrapCode(.TableOutOfBounds) };
                    }
                    for (0..len) |i| {
                        tables[inst.table_index][dst_idx + i] = seg.func_indices[src_offset + i];
                    }
                },
                .elem_drop => |inst| {
                    if (inst.segment_idx >= elem_segments.len) return .{ .trap = Trap.fromTrapCode(.TableOutOfBounds) };
                    elem_segments_dropped[inst.segment_idx] = true;
                },

                // ── GC instructions ─────────────────────────────────────────────────
                // Struct operations
                .struct_new => |inst| {
                    const struct_type = composite_types[inst.type_idx].struct_type;
                    const layout = struct_layouts[inst.type_idx] orelse return .{ .trap = Trap.fromTrapCode(.BadSignature) };

                    const total_size = @sizeOf(GcHeader) + layout.size;
                    const gc_ref = store.gc_heap.alloc(total_size) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };

                    const header_ptr = store.gc_heap.getHeader(gc_ref);
                    header_ptr.* = GcHeader.initFromRefKind(GcRefKind.init(GcRefKind.Struct), inst.type_idx);

                    const caller_func = call_stack.items[frame_idx].func;
                    const arg_slots = caller_func.call_args.items[inst.args_start .. inst.args_start + inst.args_len];

                    for (arg_slots, 0..) |arg_slot, i| {
                        store.gc_heap.writeField(gc_ref, struct_type, layout, @intCast(i), slots[arg_slot]);
                    }

                    slots[inst.dst] = RawVal.fromGcRef(gc_ref);
                },
                .struct_new_default => |inst| {
                    const layout = struct_layouts[inst.type_idx] orelse return .{ .trap = Trap.fromTrapCode(.BadSignature) };

                    const total_size = @sizeOf(GcHeader) + layout.size;
                    const gc_ref = store.gc_heap.alloc(total_size) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };

                    const header_ptr = store.gc_heap.getHeader(gc_ref);
                    header_ptr.* = GcHeader.initFromRefKind(GcRefKind.init(GcRefKind.Struct), inst.type_idx);

                    const data = store.gc_heap.getBytesAt(gc_ref, @sizeOf(GcHeader));
                    @memset(data[0..layout.size], 0);

                    slots[inst.dst] = RawVal.fromGcRef(gc_ref);
                },
                .struct_get => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    if (gc_ref.isNull()) return .{ .trap = Trap.fromTrapCode(.NullReference) };

                    const struct_type = composite_types[inst.type_idx].struct_type;
                    const layout = struct_layouts[inst.type_idx] orelse return .{ .trap = Trap.fromTrapCode(.BadSignature) };

                    slots[inst.dst] = store.gc_heap.readField(gc_ref, struct_type, layout, inst.field_idx);
                },
                .struct_get_s => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    if (gc_ref.isNull()) return .{ .trap = Trap.fromTrapCode(.NullReference) };

                    const struct_type = composite_types[inst.type_idx].struct_type;
                    const layout = struct_layouts[inst.type_idx] orelse return .{ .trap = Trap.fromTrapCode(.BadSignature) };

                    const value = store.gc_heap.readField(gc_ref, struct_type, layout, inst.field_idx);
                    slots[inst.dst] = value;
                },
                .struct_get_u => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    if (gc_ref.isNull()) return .{ .trap = Trap.fromTrapCode(.NullReference) };

                    const struct_type = composite_types[inst.type_idx].struct_type;
                    const layout = struct_layouts[inst.type_idx] orelse return .{ .trap = Trap.fromTrapCode(.BadSignature) };

                    const value = store.gc_heap.readField(gc_ref, struct_type, layout, inst.field_idx);
                    slots[inst.dst] = value;
                },
                .struct_set => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    if (gc_ref.isNull()) return .{ .trap = Trap.fromTrapCode(.NullReference) };

                    const struct_type = composite_types[inst.type_idx].struct_type;
                    const layout = struct_layouts[inst.type_idx] orelse return .{ .trap = Trap.fromTrapCode(.BadSignature) };

                    store.gc_heap.writeField(gc_ref, struct_type, layout, inst.field_idx, slots[inst.value]);
                },

                // Array operations
                .array_new => |inst| {
                    const array_type = composite_types[inst.type_idx].array_type;
                    const layout = array_layouts[inst.type_idx] orelse return .{ .trap = Trap.fromTrapCode(.BadSignature) };

                    const len = slots[inst.len].readAs(u32);
                    const total_size = layout.base_size + 4 + len * layout.elem_size;
                    const gc_ref = store.gc_heap.alloc(total_size) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };

                    const header_ptr = store.gc_heap.getHeader(gc_ref);
                    header_ptr.* = GcHeader.initFromRefKind(GcRefKind.init(GcRefKind.Array), inst.type_idx);

                    store.gc_heap.setLength(gc_ref, len);

                    const init_val = slots[inst.init];
                    for (0..len) |i| {
                        store.gc_heap.writeElem(gc_ref, array_type, layout, @intCast(i), init_val);
                    }

                    slots[inst.dst] = RawVal.fromGcRef(gc_ref);
                },
                .array_new_default => |inst| {
                    const layout = array_layouts[inst.type_idx] orelse return .{ .trap = Trap.fromTrapCode(.BadSignature) };

                    const len = slots[inst.len].readAs(u32);
                    const total_size = layout.base_size + 4 + len * layout.elem_size;
                    const gc_ref = store.gc_heap.alloc(total_size) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };

                    const header_ptr = store.gc_heap.getHeader(gc_ref);
                    header_ptr.* = GcHeader.initFromRefKind(GcRefKind.init(GcRefKind.Array), inst.type_idx);

                    store.gc_heap.setLength(gc_ref, len);

                    const data = store.gc_heap.getBytesAt(gc_ref, layout.base_size + 4);
                    @memset(data[0 .. len * layout.elem_size], 0);

                    slots[inst.dst] = RawVal.fromGcRef(gc_ref);
                },
                .array_new_fixed => |inst| {
                    const array_type = composite_types[inst.type_idx].array_type;
                    const layout = array_layouts[inst.type_idx] orelse return .{ .trap = Trap.fromTrapCode(.BadSignature) };

                    const len = inst.args_len;
                    const total_size = layout.base_size + 4 + len * layout.elem_size;
                    const gc_ref = store.gc_heap.alloc(total_size) orelse return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };

                    const header_ptr = store.gc_heap.getHeader(gc_ref);
                    header_ptr.* = GcHeader.initFromRefKind(GcRefKind.init(GcRefKind.Array), inst.type_idx);

                    store.gc_heap.setLength(gc_ref, @intCast(len));

                    const caller_func = call_stack.items[frame_idx].func;
                    const arg_slots = caller_func.call_args.items[inst.args_start .. inst.args_start + inst.args_len];

                    for (arg_slots, 0..) |arg_slot, i| {
                        store.gc_heap.writeElem(gc_ref, array_type, layout, @intCast(i), slots[arg_slot]);
                    }

                    slots[inst.dst] = RawVal.fromGcRef(gc_ref);
                },
                .array_new_data => |_| @panic("array_new_data not implemented"),
                .array_new_elem => |_| @panic("array_new_elem not implemented"),
                .array_get => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    if (gc_ref.isNull()) return .{ .trap = Trap.fromTrapCode(.NullReference) };

                    const index = slots[inst.index].readAs(u32);
                    const length = store.gc_heap.getLength(gc_ref);
                    if (index >= length) return .{ .trap = Trap.fromTrapCode(.ArrayOutOfBounds) };

                    const array_type = composite_types[inst.type_idx].array_type;
                    const layout = array_layouts[inst.type_idx] orelse return .{ .trap = Trap.fromTrapCode(.BadSignature) };

                    slots[inst.dst] = store.gc_heap.readElem(gc_ref, array_type, layout, index);
                },
                .array_get_s => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    if (gc_ref.isNull()) return .{ .trap = Trap.fromTrapCode(.NullReference) };

                    const index = slots[inst.index].readAs(u32);
                    const length = store.gc_heap.getLength(gc_ref);
                    if (index >= length) return .{ .trap = Trap.fromTrapCode(.ArrayOutOfBounds) };

                    const array_type = composite_types[inst.type_idx].array_type;
                    const layout = array_layouts[inst.type_idx] orelse return .{ .trap = Trap.fromTrapCode(.BadSignature) };

                    slots[inst.dst] = store.gc_heap.readElem(gc_ref, array_type, layout, index);
                },
                .array_get_u => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    if (gc_ref.isNull()) return .{ .trap = Trap.fromTrapCode(.NullReference) };

                    const index = slots[inst.index].readAs(u32);
                    const length = store.gc_heap.getLength(gc_ref);
                    if (index >= length) return .{ .trap = Trap.fromTrapCode(.ArrayOutOfBounds) };

                    const array_type = composite_types[inst.type_idx].array_type;
                    const layout = array_layouts[inst.type_idx] orelse return .{ .trap = Trap.fromTrapCode(.BadSignature) };

                    slots[inst.dst] = store.gc_heap.readElem(gc_ref, array_type, layout, index);
                },
                .array_set => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    if (gc_ref.isNull()) return .{ .trap = Trap.fromTrapCode(.NullReference) };

                    const index = slots[inst.index].readAs(u32);
                    const length = store.gc_heap.getLength(gc_ref);
                    if (index >= length) return .{ .trap = Trap.fromTrapCode(.ArrayOutOfBounds) };

                    const array_type = composite_types[inst.type_idx].array_type;
                    const layout = array_layouts[inst.type_idx] orelse return .{ .trap = Trap.fromTrapCode(.BadSignature) };

                    store.gc_heap.writeElem(gc_ref, array_type, layout, index, slots[inst.value]);
                },
                .array_len => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    if (gc_ref.isNull()) return .{ .trap = Trap.fromTrapCode(.NullReference) };

                    const len = store.gc_heap.getLength(gc_ref);
                    slots[inst.dst] = RawVal.from(@as(i32, @intCast(len)));
                },
                .array_fill => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    if (gc_ref.isNull()) return .{ .trap = Trap.fromTrapCode(.NullReference) };

                    const offset = slots[inst.offset].readAs(u32);
                    const n = slots[inst.n].readAs(u32);
                    const length = store.gc_heap.getLength(gc_ref);
                    const end = offset +% n;
                    if (end > length) return .{ .trap = Trap.fromTrapCode(.ArrayOutOfBounds) };

                    const array_type = composite_types[inst.type_idx].array_type;
                    const layout = array_layouts[inst.type_idx] orelse return .{ .trap = Trap.fromTrapCode(.BadSignature) };

                    const value = slots[inst.value];
                    for (offset..end) |i| {
                        store.gc_heap.writeElem(gc_ref, array_type, layout, @intCast(i), value);
                    }
                },
                .array_copy => |inst| {
                    const dst_ref = slots[inst.dst_ref].readAsGcRef();
                    if (dst_ref.isNull()) return .{ .trap = Trap.fromTrapCode(.NullReference) };
                    const src_ref = slots[inst.src_ref].readAsGcRef();
                    if (src_ref.isNull()) return .{ .trap = Trap.fromTrapCode(.NullReference) };

                    const dst_offset = slots[inst.dst_offset].readAs(u32);
                    const src_offset = slots[inst.src_offset].readAs(u32);
                    const n = slots[inst.n].readAs(u32);

                    const dst_length = store.gc_heap.getLength(dst_ref);
                    const src_length = store.gc_heap.getLength(src_ref);

                    const dst_end = dst_offset +% n;
                    const src_end = src_offset +% n;
                    if (dst_end > dst_length or src_end > src_length) return .{ .trap = Trap.fromTrapCode(.ArrayOutOfBounds) };

                    const dst_array_type = composite_types[inst.dst_type_idx].array_type;
                    const dst_layout = array_layouts[inst.dst_type_idx] orelse return .{ .trap = Trap.fromTrapCode(.BadSignature) };
                    const src_array_type = composite_types[inst.src_type_idx].array_type;
                    const src_layout = array_layouts[inst.src_type_idx] orelse return .{ .trap = Trap.fromTrapCode(.BadSignature) };

                    if (dst_offset < src_offset) {
                        for (0..n) |i| {
                            const val = store.gc_heap.readElem(src_ref, src_array_type, src_layout, src_offset + @as(u32, @intCast(i)));
                            store.gc_heap.writeElem(dst_ref, dst_array_type, dst_layout, dst_offset + @as(u32, @intCast(i)), val);
                        }
                    } else {
                        var i: u32 = n;
                        while (i > 0) {
                            i -= 1;
                            const val = store.gc_heap.readElem(src_ref, src_array_type, src_layout, src_offset + i);
                            store.gc_heap.writeElem(dst_ref, dst_array_type, dst_layout, dst_offset + i, val);
                        }
                    }
                },
                .array_init_data => |_| @panic("array_init_data not implemented"),
                .array_init_elem => |_| @panic("array_init_elem not implemented"),

                // i31 operations
                .ref_i31 => |inst| {
                    const value = slots[inst.value].readAs(i32);
                    const truncated: i31 = @truncate(value);
                    slots[inst.dst] = RawVal.fromGcRef(GcRef.fromI31(truncated));
                },
                .i31_get_s => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    if (gc_ref.isNull()) return .{ .trap = Trap.fromTrapCode(.NullReference) };
                    if (!gc_ref.isI31()) return .{ .trap = Trap.fromTrapCode(.CastFailure) };

                    const value = gc_ref.asI31() orelse return .{ .trap = Trap.fromTrapCode(.CastFailure) };
                    slots[inst.dst] = RawVal.from(@as(i32, value));
                },
                .i31_get_u => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    if (gc_ref.isNull()) return .{ .trap = Trap.fromTrapCode(.NullReference) };
                    if (!gc_ref.isI31()) return .{ .trap = Trap.fromTrapCode(.CastFailure) };

                    const value = gc_ref.asI31() orelse return .{ .trap = Trap.fromTrapCode(.CastFailure) };
                    const extended: i32 = value;
                    slots[inst.dst] = RawVal.from(@as(i32, @bitCast(@as(u32, @bitCast(extended)) & @as(u32, 0x7FFFFFFF))));
                },

                // Type test/cast operations
                .ref_test => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    if (gc_ref.isNull()) {
                        slots[inst.dst] = RawVal.from(@as(i32, 0));
                    } else if (gc_ref.isI31()) {
                        const target_kind = gcRefKindFromHeapType(core.HeapType.fromConcreteType(inst.type_idx));
                        if (target_kind) |kind| {
                            const is_match = GcRefKind.init(GcRefKind.I31).isSubtypeOf(kind);
                            slots[inst.dst] = RawVal.from(@as(i32, if (is_match) 1 else 0));
                        } else {
                            slots[inst.dst] = RawVal.from(@as(i32, 0));
                        }
                    } else {
                        const obj_header = store.gc_heap.getHeader(gc_ref);
                        const target_kind = gcRefKindFromHeapType(core.HeapType.fromConcreteType(inst.type_idx));
                        if (target_kind) |kind| {
                            const kind_bits: u32 = @as(u32, kind.bits) << 26;
                            const is_match = obj_header.isSubtypeOf(kind_bits);
                            slots[inst.dst] = RawVal.from(@as(i32, if (is_match) 1 else 0));
                        } else {
                            if (obj_header.type_index == inst.type_idx) {
                                slots[inst.dst] = RawVal.from(@as(i32, 1));
                            } else {
                                slots[inst.dst] = RawVal.from(@as(i32, 0));
                            }
                        }
                    }
                },
                .ref_cast => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    if (gc_ref.isNull()) return .{ .trap = Trap.fromTrapCode(.CastFailure) };

                    if (gc_ref.isI31()) {
                        const target_kind = gcRefKindFromHeapType(core.HeapType.fromConcreteType(inst.type_idx));
                        if (target_kind) |kind| {
                            const is_match = GcRefKind.init(GcRefKind.I31).isSubtypeOf(kind);
                            if (!is_match) return .{ .trap = Trap.fromTrapCode(.CastFailure) };
                        } else {
                            return .{ .trap = Trap.fromTrapCode(.CastFailure) };
                        }
                        slots[inst.dst] = RawVal.fromGcRef(gc_ref);
                    } else {
                        const obj_header = store.gc_heap.getHeader(gc_ref);
                        const target_kind = gcRefKindFromHeapType(core.HeapType.fromConcreteType(inst.type_idx));
                        if (target_kind) |kind| {
                            const kind_bits: u32 = @as(u32, kind.bits) << 26;
                            if (!obj_header.isSubtypeOf(kind_bits)) return .{ .trap = Trap.fromTrapCode(.CastFailure) };
                        } else {
                            if (obj_header.type_index != inst.type_idx) return .{ .trap = Trap.fromTrapCode(.CastFailure) };
                        }
                        slots[inst.dst] = RawVal.fromGcRef(gc_ref);
                    }
                },
                .ref_as_non_null => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    if (gc_ref.isNull()) return .{ .trap = Trap.fromTrapCode(.NullReference) };
                    slots[inst.dst] = RawVal.fromGcRef(gc_ref);
                },

                // Control flow operations
                .br_on_null => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    if (gc_ref.isNull()) {
                        call_stack.items[frame_idx].pc = inst.target;
                    }
                },
                .br_on_non_null => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    if (!gc_ref.isNull()) {
                        call_stack.items[frame_idx].pc = inst.target;
                    }
                },
                .br_on_cast => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    var should_branch = false;

                    if (gc_ref.isNull()) {
                        should_branch = false;
                    } else if (gc_ref.isI31()) {
                        const target_kind = gcRefKindFromHeapType(core.HeapType.fromConcreteType(inst.to_type_idx));
                        if (target_kind) |kind| {
                            should_branch = GcRefKind.init(GcRefKind.I31).isSubtypeOf(kind);
                        }
                    } else {
                        const obj_header = store.gc_heap.getHeader(gc_ref);
                        const target_kind = gcRefKindFromHeapType(core.HeapType.fromConcreteType(inst.to_type_idx));
                        if (target_kind) |kind| {
                            const kind_bits: u32 = @as(u32, kind.bits) << 26;
                            should_branch = obj_header.isSubtypeOf(kind_bits);
                        } else {
                            should_branch = obj_header.type_index == inst.to_type_idx;
                        }
                    }

                    if (should_branch) {
                        call_stack.items[frame_idx].pc = inst.target;
                    }
                },
                .br_on_cast_fail => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    var should_branch = false;

                    if (gc_ref.isNull()) {
                        should_branch = true;
                    } else if (gc_ref.isI31()) {
                        const target_kind = gcRefKindFromHeapType(core.HeapType.fromConcreteType(inst.to_type_idx));
                        if (target_kind) |kind| {
                            should_branch = !GcRefKind.init(GcRefKind.I31).isSubtypeOf(kind);
                        } else {
                            should_branch = true;
                        }
                    } else {
                        const obj_header = store.gc_heap.getHeader(gc_ref);
                        const target_kind = gcRefKindFromHeapType(core.HeapType.fromConcreteType(inst.to_type_idx));
                        if (target_kind) |kind| {
                            const kind_bits: u32 = @as(u32, kind.bits) << 26;
                            should_branch = !obj_header.isSubtypeOf(kind_bits);
                        } else {
                            should_branch = obj_header.type_index != inst.to_type_idx;
                        }
                    }

                    if (should_branch) {
                        call_stack.items[frame_idx].pc = inst.target;
                    }
                },

                // Call operations
                .call_ref => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    if (gc_ref.isNull()) return .{ .trap = Trap.fromTrapCode(.NullReference) };

                    const raw_bits = gc_ref.decode();
                    const callee_func_idx: u32 = raw_bits;
                    const caller_func = call_stack.items[frame_idx].func;
                    const arg_slots = caller_func.call_args.items[inst.args_start .. inst.args_start + inst.args_len];

                    if (callee_func_idx >= func_type_indices.len) return .{ .trap = Trap.fromTrapCode(.BadSignature) };
                    if (func_type_indices[callee_func_idx] != inst.type_idx) return .{ .trap = Trap.fromTrapCode(.BadSignature) };

                    if (callee_func_idx < host_funcs.len) {
                        const host_result = try invokeHostCall(
                            self,
                            store,
                            host_instance,
                            host_funcs[callee_func_idx],
                            arg_slots,
                            slots,
                            func_types[func_type_indices[callee_func_idx]].results().len,
                        );
                        switch (host_result) {
                            .trap => |t| return .{ .trap = t },
                            .ok => |ret_val| {
                                if (inst.dst) |dst_slot| {
                                    if (ret_val) |rv| {
                                        slots[dst_slot] = rv;
                                    }
                                }
                            },
                        }
                    } else {
                        const callee = functions[callee_func_idx];
                        const callee_slots_len: usize = @max(
                            @as(usize, @intCast(callee.slots_len)),
                            arg_slots.len,
                        );
                        const callee_slots = try self.allocator.alloc(RawVal, callee_slots_len);
                        @memset(callee_slots, std.mem.zeroes(RawVal));

                        for (arg_slots, 0..) |arg_slot, i| {
                            callee_slots[i] = slots[arg_slot];
                        }

                        const callee_dst = inst.dst;
                        call_stack.append(self.allocator, .{
                            .func = callee,
                            .slots = callee_slots,
                            .pc = 0,
                            .dst = callee_dst,
                        }) catch |err| {
                            self.allocator.free(callee_slots);
                            return err;
                        };
                    }
                },
                .return_call_ref => |inst| {
                    const gc_ref = slots[inst.ref].readAsGcRef();
                    if (gc_ref.isNull()) return .{ .trap = Trap.fromTrapCode(.NullReference) };

                    const raw_bits = gc_ref.decode();
                    const callee_func_idx: u32 = raw_bits;
                    const caller_func = call_stack.items[frame_idx].func;
                    const arg_slots = caller_func.call_args.items[inst.args_start .. inst.args_start + inst.args_len];

                    if (callee_func_idx >= func_type_indices.len) return .{ .trap = Trap.fromTrapCode(.BadSignature) };
                    if (func_type_indices[callee_func_idx] != inst.type_idx) return .{ .trap = Trap.fromTrapCode(.BadSignature) };

                    if (callee_func_idx < host_funcs.len) {
                        const host_result = try invokeHostCall(
                            self,
                            store,
                            host_instance,
                            host_funcs[callee_func_idx],
                            arg_slots,
                            slots,
                            func_types[func_type_indices[callee_func_idx]].results().len,
                        );
                        switch (host_result) {
                            .trap => |t| return .{ .trap = t },
                            .ok => |ret_val| {
                                const popped_frame = call_stack.pop().?;
                                self.allocator.free(popped_frame.slots);
                                if (call_stack.items.len == 0) {
                                    return .{ .ok = ret_val };
                                }
                                const caller_idx = call_stack.items.len - 1;
                                if (popped_frame.dst) |dst_slot| {
                                    if (ret_val) |rv| {
                                        call_stack.items[caller_idx].slots[dst_slot] = rv;
                                    }
                                }
                            },
                        }
                    } else {
                        const callee = functions[callee_func_idx];
                        const callee_slots_len: usize = @max(
                            @as(usize, @intCast(callee.slots_len)),
                            arg_slots.len,
                        );
                        const callee_slots = try self.allocator.alloc(RawVal, callee_slots_len);
                        @memset(callee_slots, std.mem.zeroes(RawVal));

                        for (arg_slots, 0..) |arg_slot, i| {
                            callee_slots[i] = slots[arg_slot];
                        }

                        const tail_dst = call_stack.items[frame_idx].dst;

                        self.allocator.free(call_stack.items[frame_idx].slots);

                        call_stack.items[frame_idx] = .{
                            .func = callee,
                            .slots = callee_slots,
                            .pc = 0,
                            .dst = tail_dst,
                        };
                    }
                },

                // Conversion operations
                .any_convert_extern => |inst| {
                    slots[inst.dst] = slots[inst.ref];
                },
                .extern_convert_any => |inst| {
                    slots[inst.dst] = slots[inst.ref];
                },

                // ── return ────────────────────────────────────────────────────────
                .ret => |inst| {
                    const ret_val: ?RawVal = if (inst.value) |slot|
                        slots[slot]
                    else
                        null;

                    const popped_frame = call_stack.pop().?;
                    self.allocator.free(popped_frame.slots);

                    if (call_stack.items.len == 0) {
                        return .{ .ok = ret_val };
                    }

                    const caller_idx = call_stack.items.len - 1;
                    if (popped_frame.dst) |dst_slot| {
                        if (ret_val) |rv| {
                            call_stack.items[caller_idx].slots[dst_slot] = rv;
                        }
                    }
                },
            }
        }

        return .{ .ok = null };
    }

    // TODO: GC
    // GC introduces heap memory blocks managed by the VM
    // and specific data structures that need to be stored on the heap
    // struct、array、anyref etc..

};

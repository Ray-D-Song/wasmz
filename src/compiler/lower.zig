// input:
// Function signature
// locals information
// operator sequence produced by the parser

// output:
// CompiledFunction { slots_len, ops }
const std = @import("std");
const ir = @import("./ir.zig");
const ValueStack = @import("./value_stack.zig").ValueStack;
const core = @import("core");
// Profiling stub — lower.zig cannot import ../utils/profiling.zig because the
// compiler_tests module root is src/compiler/ which cannot reach src/utils/.
// The frame-level counters are development-only; keep a minimal stub so the
// code compiles in both contexts.  When the full profiling module is needed,
// build with -Dprofiling=true via the wasmz module where the path resolves.
const profiling = struct {
    const enabled = false;
    const frame_prof = struct {
        var total_frames: usize = 0;
        var result_slots_0: usize = 0;
        var result_slots_1: usize = 0;
        var result_slots_2: usize = 0;
        var result_slots_gt2: usize = 0;
        var result_slots_max: usize = 0;
        var param_slots_0: usize = 0;
        var param_slots_1: usize = 0;
        var param_slots_2: usize = 0;
        var param_slots_gt2: usize = 0;
        var param_slots_max: usize = 0;
        var patch_sites_0: usize = 0;
        var patch_sites_1: usize = 0;
        var patch_sites_2: usize = 0;
        var patch_sites_3: usize = 0;
        var patch_sites_4: usize = 0;
        var patch_sites_gt4: usize = 0;
        var patch_sites_max: usize = 0;
    };
};
const translate_mod = @import("./translate.zig");
const payload_mod = @import("payload");
const OperatorInformation = payload_mod.OperatorInformation;
const OperatorCode = payload_mod.OperatorCode;

const Allocator = std.mem.Allocator;
const Slot = ir.Slot;
const Op = ir.Op;
const CompiledFunction = ir.CompiledFunction;
const ValType = core.ValType;
const simd = core.simd;
const SimdOpcode = simd.SimdOpcode;
const V128 = simd.V128;

pub const LowerError = error{
    StackUnderflow,
    ControlStackUnderflow,
    MismatchedEnd,
    InvalidFunctionType,
};

// ── Control flow ──────────────────────────────────────────────────────────────

/// Which WASM structured-control construct opened this frame.
pub const BlockKind = enum { block, loop, if_, try_table };

/// Inline small-buffer list for Slot values (result_slots / param_slots).
/// Holds up to INLINE_CAP elements without any heap allocation.
/// Overflows to a heap-allocated slice for the rare multi-value block case.
/// Data shows: result_slots is 0 in 99.999% of frames, 1 in the rest.
///             param_slots  is 0 in 100% of esbuild frames.
/// INLINE_CAP=2 covers all observed cases with zero heap traffic.
pub const SmallSlotList = struct {
    const INLINE_CAP = 2;
    inline_buf: [INLINE_CAP]Slot = undefined,
    len: u8 = 0,
    /// Non-null only when len > INLINE_CAP; owns a heap slice of length `len`.
    overflow: ?[]Slot = null,

    pub const empty: SmallSlotList = .{};

    /// Return a slice over the current contents (inline or overflow).
    pub fn items(self: *const SmallSlotList) []const Slot {
        if (self.overflow) |ov| return ov[0..self.len];
        return self.inline_buf[0..self.len];
    }

    pub fn append(self: *SmallSlotList, allocator: Allocator, slot: Slot) !void {
        if (self.len < INLINE_CAP) {
            self.inline_buf[self.len] = slot;
            self.len += 1;
            return;
        }
        // Need to spill to heap (very rare).
        const new_len = self.len + 1;
        if (self.overflow) |ov| {
            // Already on heap — grow.
            const new_ov = try allocator.realloc(ov, new_len);
            new_ov[self.len] = slot;
            self.overflow = new_ov;
        } else {
            // First spill: copy inline_buf to heap then append.
            const new_ov = try allocator.alloc(Slot, new_len);
            @memcpy(new_ov[0..INLINE_CAP], &self.inline_buf);
            new_ov[self.len] = slot;
            self.overflow = new_ov;
        }
        self.len = @intCast(new_len);
    }

    pub fn deinit(self: *SmallSlotList, allocator: Allocator) void {
        if (self.overflow) |ov| allocator.free(ov);
        self.* = .empty;
    }
};

/// Inline small-buffer list for patch-site op-indices (u32).
/// Holds up to INLINE_CAP entries without heap allocation.
/// Data shows: 80% len=1, 6% len=2, 7% len=3, 3% len=4, 3% len>4, max=1761.
/// INLINE_CAP=4 covers 97% of frames inline; the remaining 3% fall back to heap.
pub const SmallPatchList = struct {
    const INLINE_CAP = 4;
    inline_buf: [INLINE_CAP]u32 = undefined,
    len: u32 = 0,
    /// Non-null only when len > INLINE_CAP; owns a heap ArrayList for dynamic growth.
    overflow: ?std.ArrayListUnmanaged(u32) = null,

    pub const empty: SmallPatchList = .{};

    pub fn items(self: *const SmallPatchList) []const u32 {
        if (self.overflow) |*ov| return ov.items;
        return self.inline_buf[0..self.len];
    }

    pub fn append(self: *SmallPatchList, allocator: Allocator, site: u32) !void {
        if (self.overflow) |*ov| {
            try ov.append(allocator, site);
            return;
        }
        if (self.len < INLINE_CAP) {
            self.inline_buf[self.len] = site;
            self.len += 1;
            return;
        }
        // First spill: move inline_buf into ArrayList then append new entry.
        var list = std.ArrayListUnmanaged(u32){};
        try list.ensureTotalCapacity(allocator, INLINE_CAP + 1);
        list.appendSliceAssumeCapacity(self.inline_buf[0..INLINE_CAP]);
        list.appendAssumeCapacity(site);
        self.overflow = list;
        // len is no longer used once overflow is set; keep consistent.
        self.len = INLINE_CAP + 1;
    }

    pub fn clearRetainingCapacity(self: *SmallPatchList) void {
        if (self.overflow) |*ov| {
            ov.clearRetainingCapacity();
            // Keep overflow allocated so next use avoids realloc.
            self.len = 0;
            return;
        }
        self.len = 0;
    }

    pub fn deinit(self: *SmallPatchList, allocator: Allocator) void {
        if (self.overflow) |*ov| ov.deinit(allocator);
        self.* = .empty;
    }
};

/// A single entry on the control stack, created when we enter a block/loop/if.
pub const ControlFrame = struct {
    /// Number of values on the value stack at the time this block was entered
    /// (after consuming any block parameters for multi-value blocks).
    /// Used to restore the stack when we branch out of the block.
    stack_height: usize,
    /// The slots that hold this block's result values (empty = void block).
    /// For multi-value blocks these are allocated in order: result_slots[0] is
    /// the first result type, result_slots[N-1] is the last (top of stack).
    /// Data: 99.999% of frames have 0 or 1 result slots → stored inline.
    result_slots: SmallSlotList = .empty,
    /// For multi-value blocks: the slots that hold the block's parameter values.
    /// For loop: br targets param_slots (phi semantics, jumps back to header).
    /// For block/if: params are consumed on entry and re-pushed immediately,
    /// so param_slots is only needed to track their slot numbers.
    /// Data: 100% of frames have 0 param slots in practice → stored inline.
    param_slots: SmallSlotList = .empty,
    /// Indices into compiled.ops that hold `jump` / `jump_if_z` ops whose
    /// target needs to be patched when we know where `end` lands.
    /// Data: 97% of frames have ≤4 patch sites → stored inline.
    patch_sites: SmallPatchList = .empty,
    /// For try_table frames: the op-index of the `try_table_enter` op.
    /// We need it to backpatch the `end_target` field once we see `end`.
    try_table_enter_pc: ?u32 = null,
    /// For block/if: the op-index of the start of the continuation (filled in
    /// when we see `end`).  For loop: the op-index of the loop header (filled
    /// in immediately at open time, since `br` goes back to the top).
    /// While still open, forward-jump sites are stored in `patch_sites`.
    target_pc: u32,
    kind: BlockKind,
    /// True for the implicit function-level frame pushed at the start of each
    /// function body.  When `end` pops this frame it emits a `ret` instead of
    /// a continuation jump, mirroring the special-case that was previously
    /// triggered by `control_stack.len == 0`.
    is_function_frame: bool = false,
    /// True when an `else_` branch was seen for this `if_` block.
    /// Used at `end` to decide whether the false path needs explicit
    /// zero-init of result slots (for if-without-else with results).
    has_else: bool = false,
};

// ── Input op enum ─────────────────────────────────────────────────────────────

/// A single catch arm as parsed (used in try_table WasmOp).
/// This mirrors payload.CatchHandler but uses our local types.
pub const CatchHandlerWasm = struct {
    kind: @import("payload").CatchHandlerKind,
    tag_index: ?u32,
    /// Branch depth within the try_table block's label context.
    depth: u32,
    /// Number of values the tag carries (== tag FuncType params().len).
    /// 0 for catch_all / catch_all_ref.
    tag_arity: u32,
};

pub const WasmOp = union(enum) {
    unreachable_,
    nop,
    drop,
    block: ?BlockType,
    loop: ?BlockType,
    if_: ?BlockType,
    else_,
    end,
    br: u32,
    br_if: u32,
    /// br_table: targets is the full slice including the default as the last element.
    /// targets[0..len-1] are indexed targets; targets[len-1] is the default target.
    br_table: struct { targets: []const u32 },
    local_get: u32,
    local_set: u32,
    local_tee: u32,
    global_get: u32,
    global_set: u32,

    // ── Constants ─────────────────────────────────────────────────────────────
    i32_const: i32,
    i64_const: i64,
    f32_const: f32,
    f64_const: f64,
    v128_const: V128,

    // ── i32 arithmetic (binary) ───────────────────────────────────────────────
    i32_add,
    i32_sub,
    i32_mul,
    i32_div_s,
    i32_div_u,
    i32_rem_s,
    i32_rem_u,
    i32_and,
    i32_or,
    i32_xor,
    i32_shl,
    i32_shr_s,
    i32_shr_u,
    i32_rotl,
    i32_rotr,

    // ── i64 arithmetic (binary) ───────────────────────────────────────────────
    i64_add,
    i64_sub,
    i64_mul,
    i64_div_s,
    i64_div_u,
    i64_rem_s,
    i64_rem_u,
    i64_and,
    i64_or,
    i64_xor,
    i64_shl,
    i64_shr_s,
    i64_shr_u,
    i64_rotl,
    i64_rotr,

    // ── f32 arithmetic (binary) ───────────────────────────────────────────────
    f32_add,
    f32_sub,
    f32_mul,
    f32_div,
    f32_min,
    f32_max,
    f32_copysign,

    // ── f64 arithmetic (binary) ───────────────────────────────────────────────
    f64_add,
    f64_sub,
    f64_mul,
    f64_div,
    f64_min,
    f64_max,
    f64_copysign,

    // ── i32 unary ────────────────────────────────────────────────────────────
    i32_clz,
    i32_ctz,
    i32_popcnt,

    // ── i64 unary ────────────────────────────────────────────────────────────
    i64_clz,
    i64_ctz,
    i64_popcnt,

    // ── f32 unary ────────────────────────────────────────────────────────────
    f32_abs,
    f32_neg,
    f32_ceil,
    f32_floor,
    f32_trunc,
    f32_nearest,
    f32_sqrt,

    // ── f64 unary ────────────────────────────────────────────────────────────
    f64_abs,
    f64_neg,
    f64_ceil,
    f64_floor,
    f64_trunc,
    f64_nearest,
    f64_sqrt,

    // ── i32 comparisons ─────────────────────────────────────────────────────
    i32_eqz,
    i32_eq,
    i32_ne,
    i32_lt_s,
    i32_lt_u,
    i32_gt_s,
    i32_gt_u,
    i32_le_s,
    i32_le_u,
    i32_ge_s,
    i32_ge_u,

    // ── i64 comparisons ─────────────────────────────────────────────────────
    i64_eqz,
    i64_eq,
    i64_ne,
    i64_lt_s,
    i64_lt_u,
    i64_gt_s,
    i64_gt_u,
    i64_le_s,
    i64_le_u,
    i64_ge_s,
    i64_ge_u,

    // ── f32 comparisons ─────────────────────────────────────────────────────
    f32_eq,
    f32_ne,
    f32_lt,
    f32_gt,
    f32_le,
    f32_ge,

    // ── f64 comparisons ─────────────────────────────────────────────────────
    f64_eq,
    f64_ne,
    f64_lt,
    f64_gt,
    f64_le,
    f64_ge,

    // ── Numeric conversion and reinterpret operations ────────────────────────
    i32_wrap_i64,
    i32_trunc_f32_s,
    i32_trunc_f32_u,
    i32_trunc_f64_s,
    i32_trunc_f64_u,
    i64_extend_i32_s,
    i64_extend_i32_u,
    i64_trunc_f32_s,
    i64_trunc_f32_u,
    i64_trunc_f64_s,
    i64_trunc_f64_u,
    i32_trunc_sat_f32_s,
    i32_trunc_sat_f32_u,
    i32_trunc_sat_f64_s,
    i32_trunc_sat_f64_u,
    i64_trunc_sat_f32_s,
    i64_trunc_sat_f32_u,
    i64_trunc_sat_f64_s,
    i64_trunc_sat_f64_u,
    f32_convert_i32_s,
    f32_convert_i32_u,
    f32_convert_i64_s,
    f32_convert_i64_u,
    f32_demote_f64,
    f64_convert_i32_s,
    f64_convert_i32_u,
    f64_convert_i64_s,
    f64_convert_i64_u,
    f64_promote_f32,
    i32_reinterpret_f32,
    i64_reinterpret_f64,
    f32_reinterpret_i32,
    f64_reinterpret_i64,

    // ── Sign-extension operations ────────────────────────────────────────────
    i32_extend8_s,
    i32_extend16_s,
    i64_extend8_s,
    i64_extend16_s,
    i64_extend32_s,

    // ── SIMD operations ───────────────────────────────────────────────────────
    simd_unary: SimdOpcode,
    simd_binary: SimdOpcode,
    simd_ternary: SimdOpcode,
    simd_compare: SimdOpcode,
    simd_shift_scalar: SimdOpcode,
    simd_extract_lane: struct {
        opcode: SimdOpcode,
        lane: u8,
    },
    simd_replace_lane: struct {
        opcode: SimdOpcode,
        lane: u8,
    },
    simd_shuffle: [16]u8,
    simd_load: simd.SimdLoadInfo,
    simd_store: simd.SimdStoreInfo,

    ret,
    /// direct fn call with known func_idx, param count and result presence.
    /// n_params / has_result are filled in by the caller (module.zig) after querying the function type signature.
    call: struct {
        func_idx: u32,
        n_params: u32,
        has_result: bool,
    },
    /// indirect fn call via table.
    /// n_params / has_result are filled in by the caller (module.zig) after querying the type section entry.
    call_indirect: struct {
        type_index: u32,
        table_index: u32,
        n_params: u32,
        has_result: bool,
    },
    /// Tail call: direct function call that reuses the current stack frame.
    return_call: struct {
        func_idx: u32,
        n_params: u32,
    },
    /// Tail call indirect: indirect function call via table that reuses the current stack frame.
    return_call_indirect: struct {
        type_index: u32,
        table_index: u32,
        n_params: u32,
    },

    // ── Memory load instructions ─────────────────────────────────────────────
    // `offset` is the static immediate offset encoded in the Wasm instruction (memory_address.offset).
    i32_load: struct { offset: u32 },
    i32_load8_s: struct { offset: u32 },
    i32_load8_u: struct { offset: u32 },
    i32_load16_s: struct { offset: u32 },
    i32_load16_u: struct { offset: u32 },

    i64_load: struct { offset: u32 },
    i64_load8_s: struct { offset: u32 },
    i64_load8_u: struct { offset: u32 },
    i64_load16_s: struct { offset: u32 },
    i64_load16_u: struct { offset: u32 },
    i64_load32_s: struct { offset: u32 },
    i64_load32_u: struct { offset: u32 },

    f32_load: struct { offset: u32 },
    f64_load: struct { offset: u32 },

    // ── Memory store instructions ─────────────────────────────────────────────
    i32_store: struct { offset: u32 },
    i32_store8: struct { offset: u32 },
    i32_store16: struct { offset: u32 },

    i64_store: struct { offset: u32 },
    i64_store8: struct { offset: u32 },
    i64_store16: struct { offset: u32 },
    i64_store32: struct { offset: u32 },

    f32_store: struct { offset: u32 },
    f64_store: struct { offset: u32 },

    // ── Bulk memory instructions ──────────────────────────────────────────────
    memory_init: u32,
    data_drop: u32,
    memory_copy,
    memory_fill,
    memory_size,
    memory_grow,

    // ── Atomic memory instructions (Wasm Threads proposal) ───────────────────
    /// atomic.fence: sequentially-consistent full memory fence (no operands).
    atomic_fence,
    /// Atomic load: pop addr (i32), push loaded value (i32 or i64).
    atomic_load: struct { offset: u32, width: ir.AtomicWidth, ty: ir.AtomicType },
    /// Atomic store: pop value (i32/i64), pop addr (i32).
    atomic_store: struct { offset: u32, width: ir.AtomicWidth, ty: ir.AtomicType },
    /// Atomic RMW: pop src, pop addr, push old value.
    atomic_rmw: struct { offset: u32, op: ir.AtomicRmwOp, width: ir.AtomicWidth, ty: ir.AtomicType },
    /// Atomic cmpxchg: pop replacement, pop expected, pop addr, push old value.
    atomic_cmpxchg: struct { offset: u32, width: ir.AtomicWidth, ty: ir.AtomicType },
    /// memory.atomic.notify: pop count (i32), pop addr (i32), push woken (i32).
    atomic_notify: struct { offset: u32 },
    /// memory.atomic.wait32: pop timeout (i64), pop expected (i32), pop addr (i32), push result (i32).
    atomic_wait32: struct { offset: u32 },
    /// memory.atomic.wait64: pop timeout (i64), pop expected (i64), pop addr (i32), push result (i32).
    atomic_wait64: struct { offset: u32 },
    /// select: stack [val1, val2, cond] -> if cond != 0 then val1 else val2
    select,
    /// select with explicit type annotation (same semantics, type annotation ignored at runtime",)
    select_with_type,

    // ── Reference type instructions ───────────────────────────────────────────
    /// ref.null: push a null reference value.
    /// All reference types (funcref, externref, anyref, eqref, …) share the
    /// same null sentinel: low64 == 0.  funcref values are encoded as
    /// func_idx+1 so that func_idx=0 is never confused with null.
    ref_null,
    /// ref.is_null: test if TOS reference is null → i32 result (1 = null, 0 = non-null).
    ref_is_null,
    /// ref.func: push a reference to function func_idx.
    ref_func: u32,
    /// ref.eq: compare two references — i32 result (1 = equal, 0 = not equal).
    ref_eq,

    // ── Table instructions ─────────────────────────────────────────────────────────
    /// table.get: pop index (i32), push funcref from table[table_index][index].
    table_get: u32, // table_index
    /// table.set: pop value (funcref), pop index (i32), write to table[table_index][index].
    table_set: u32, // table_index
    /// table.size: push i32 size of table[table_index].
    table_size: u32, // table_index
    /// table.grow: pop delta (i32), pop init (funcref), grow table[table_index]. Push old size or -1.
    table_grow: u32, // table_index
    /// table.fill: pop len (i32), pop value (funcref), pop dst (i32). Fill table[table_index][dst..dst+len] = value.
    table_fill: u32, // table_index
    /// table.copy: pop len (i32), pop src_idx (i32), pop dst_idx (i32). Copy table[src][src_idx..] to table[dst][dst_idx..].
    table_copy: struct { dst_table: u32, src_table: u32 },
    /// table.init: pop len (i32), pop src_offset (i32), pop dst_idx (i32). Copy elem_seg[segment_idx][src_offset..] to table[table_index][dst_idx..].
    table_init: struct { table_index: u32, segment_idx: u32 },
    /// elem.drop: mark element segment as dropped.
    elem_drop: u32, // segment_idx

    // ── GC Struct instructions ─────────────────────────────────────────────────────
    /// struct.new: pop N field values, push new struct instance.
    /// type_idx is the type section index of the struct type.
    /// n_fields is the number of fields to pop from the stack.
    struct_new: struct { type_idx: u32, n_fields: u32 },
    /// struct.new_default: push new struct with default field values (0 for numeric, null for ref).
    struct_new_default: u32, // type_idx
    /// struct.get: pop struct ref, push field value at field_idx.
    struct_get: struct { type_idx: u32, field_idx: u32 },
    /// struct.get_s: pop struct ref, push signed field value (for packed types i8/i16).
    struct_get_s: struct { type_idx: u32, field_idx: u32 },
    /// struct.get_u: pop struct ref, push unsigned field value (for packed types i8/i16).
    struct_get_u: struct { type_idx: u32, field_idx: u32 },
    /// struct.set: pop value, pop struct ref, write value to field_idx.
    struct_set: struct { type_idx: u32, field_idx: u32 },

    // ── GC Array instructions ──────────────────────────────────────────────────────
    /// array.new: pop init value and len (i32), push new array with len copies of init.
    array_new: u32, // type_idx
    /// array.new_default: pop len (i32), push new array with default element values.
    array_new_default: u32, // type_idx
    /// array.new_fixed: pop N elements, push new fixed-size array.
    array_new_fixed: struct { type_idx: u32, n: u32 },
    /// array.new_data: pop len and offset (i32), push new array from data segment.
    array_new_data: struct { type_idx: u32, data_idx: u32 },
    /// array.new_elem: pop len and offset (i32), push new array from element segment.
    array_new_elem: struct { type_idx: u32, elem_idx: u32 },
    /// array.get: pop index (i32) and array ref, push element value.
    array_get: u32, // type_idx
    /// array.get_s: pop index (i32) and array ref, push signed element value (packed).
    array_get_s: u32, // type_idx
    /// array.get_u: pop index (i32) and array ref, push unsigned element value (packed).
    array_get_u: u32, // type_idx
    /// array.set: pop value, pop index (i32), pop array ref, write value to index.
    array_set: u32, // type_idx
    /// array.len: pop array ref, push i32 length.
    array_len,
    /// array.fill: pop n (i32), pop value, pop offset (i32), pop array ref. Fill array[offset..offset+n] with value.
    array_fill: u32, // type_idx
    /// array.copy: pop n (i32), pop src_offset (i32), pop src_ref, pop dst_offset (i32), pop dst_ref. Copy elements.
    array_copy: struct { dst_type_idx: u32, src_type_idx: u32 },
    /// array.init_data: pop n (i32), pop s (i32), pop d (i32), pop array ref. Copy from data segment.
    array_init_data: struct { type_idx: u32, data_idx: u32 },
    /// array.init_elem: pop n (i32), pop s (i32), pop d (i32), pop array ref. Copy from element segment.
    array_init_elem: struct { type_idx: u32, elem_idx: u32 },

    // ── GC i31 instructions ────────────────────────────────────────────────────────
    /// ref.i31: pop i32, push i31ref (small integer packed into reference).
    ref_i31,
    /// i31.get_s: pop i31ref, push signed i31 value (sign-extended to i32).
    i31_get_s,
    /// i31.get_u: pop i31ref, push unsigned i31 value (zero-extended to i32).
    i31_get_u,

    // ── GC Type Test/Cast instructions ─────────────────────────────────────────────
    /// ref.test / ref.test_null: pop ref, push i32 (1 if ref matches type_idx, 0 otherwise).
    /// nullable=true: a null ref also returns 1.
    ref_test: struct { type_idx: u32, nullable: bool },
    /// ref.cast / ref.cast_null: pop ref, trap if ref doesn't match type_idx (unless nullable+null), else push ref.
    /// nullable=true: a null ref passes through without trapping.
    ref_cast: struct { type_idx: u32, nullable: bool },
    /// ref.as_non_null: pop ref, trap if null, else push ref.
    ref_as_non_null,

    // ── GC Control Flow instructions ────────────────────────────────────────────────
    /// br_on_null: pop ref, branch if ref is null (ref is consumed), else push ref back and continue.
    br_on_null: u32, // br_depth
    /// br_on_non_null: pop ref, branch if ref is non-null (push ref back then branch), else continue.
    br_on_non_null: u32, // br_depth
    /// br_on_cast: pop ref, branch if ref matches target type (push downcast ref and branch), else continue.
    /// to_nullable=true: a null ref also satisfies the cast.
    br_on_cast: struct {
        br_depth: u32,
        from_type_idx: u32,
        to_type_idx: u32,
        to_nullable: bool,
    },
    /// br_on_cast_fail: pop ref, branch if ref does NOT match target type, else continue with downcast ref.
    /// to_nullable=true: a null ref satisfies the cast (does NOT branch).
    br_on_cast_fail: struct {
        br_depth: u32,
        from_type_idx: u32,
        to_type_idx: u32,
        to_nullable: bool,
    },

    // ── GC Call instructions ───────────────────────────────────────────────────────
    /// call_ref: pop funcref and N args, call function via reference.
    call_ref: struct {
        type_idx: u32,
        n_params: u32,
        has_result: bool,
    },
    /// return_call_ref: tail call via funcref.
    return_call_ref: struct {
        type_idx: u32,
        n_params: u32,
    },

    // ── GC Extern/Any conversion instructions ──────────────────────────────────────
    /// any.convert_extern: pop externref, push anyref (type conversion).
    any_convert_extern,
    /// extern.convert_any: pop anyref, push externref (type conversion).
    extern_convert_any,

    // ── Exception Handling instructions ───────────────────────────────────────────
    /// throw: pop N args from stack (per tag arity), throw exception with the given tag.
    throw: struct {
        tag_index: u32,
        /// Number of arguments to pop (== tag's FuncType param count). Filled by module.zig.
        n_args: u32,
    },
    /// throw_ref: pop exnref from stack, re-throw.
    throw_ref,
    /// try_table: begin a try block with a set of catch handlers.
    /// handlers is the slice of catch arms (from the parser).
    try_table: struct {
        block_type: ?BlockType,
        handlers: []const CatchHandlerWasm,
    },
};

/// Block/loop/if result type.
/// - null (as ?BlockType) means void (no result / empty_block_type 0x40).
/// - .val_type: single-value block result (i32, i64, f32, f64, v128, any ref type).
/// - .type_index: index into the module's Type Section (multi-value: params and/or multiple results).
pub const BlockType = union(enum) {
    val_type: ValType,
    type_index: u32,
};

// ── Lowering pass ─────────────────────────────────────────────────────────────

pub const Lower = struct {
    allocator: Allocator,
    compiled: CompiledFunction = .{
        .slots_len = 0,
        .locals_count = 0,
        .ops = .empty,
        .call_args = .empty,
        .br_table_targets = .empty,
        .catch_handler_tables = .empty,
    },
    stack: ValueStack = .{},
    next_slot: Slot = 0,
    /// Slots [0..reserved_slots) are params+locals and must never be recycled.
    /// Slots >= reserved_slots are SSA temporaries and can be put back in free_slots.
    reserved_slots: Slot = 0,
    /// Free-list of recycled temporary slots. alloc_slot() pops from here first.
    free_slots: std.ArrayListUnmanaged(Slot) = .empty,
    /// Control-flow nesting stack.
    control_stack: std.ArrayListUnmanaged(ControlFrame) = .empty,
    /// Unified type section (func, struct, array), used to resolve multi-value block types.
    composite_types: []const core.CompositeType = &.{},
    /// True when the current position is unreachable (after br, br_table, return, unreachable).
    /// In this state, subsequent instructions until the next `end`/`else` are dead code.
    is_unreachable: bool = false,
    /// Nesting depth of blocks opened while in unreachable state.
    unreachable_depth: u32 = 0,

    pub fn init(allocator: Allocator) Lower {
        return .{ .allocator = allocator };
    }

    pub fn initWithReservedSlots(allocator: Allocator, reserved_slots: u32, locals_count: u16) Lower {
        return .{
            .allocator = allocator,
            .compiled = .{
                .slots_len = reserved_slots,
                .locals_count = locals_count,
                .ops = .empty,
                .call_args = .empty,
                .br_table_targets = .empty,
                .catch_handler_tables = .empty,
            },
            .next_slot = reserved_slots,
            .reserved_slots = reserved_slots,
        };
    }

    /// Push the implicit function-level block frame onto the control stack.
    /// Must be called once after init, before lowering any ops.
    /// `n_results` is the number of values this function returns (0 for void).
    /// The frame uses `kind = .block`; `br depth` that resolves to this frame
    /// is treated as a `return` (just like the function's final `end`).
    pub fn pushFunctionFrame(self: *Lower, n_results: usize) !void {
        var result_slots: SmallSlotList = .empty;
        errdefer result_slots.deinit(self.allocator);
        // Allocate a result slot for each return value.
        // These slots are not used for the normal fall-through `end` path
        // (which emits `ret` directly), but `br` targeting this frame will
        // copy its results here and then emit `ret` via the patch mechanism.
        var i: usize = 0;
        while (i < n_results) : (i += 1) {
            try result_slots.append(self.allocator, self.alloc_slot());
        }
        try self.control_stack.append(self.allocator, .{
            .kind = .block,
            .stack_height = 0,
            .result_slots = result_slots,
            .target_pc = 0, // forward — patched when the function `end` is processed
            .is_function_frame = true,
        });
    }

    pub fn deinit(self: *Lower) void {
        self.stack.deinit(self.allocator);
        self.compiled.ops.deinit(self.allocator);
        self.compiled.call_args.deinit(self.allocator);
        self.compiled.br_table_targets.deinit(self.allocator);
        self.compiled.catch_handler_tables.deinit(self.allocator);
        for (self.control_stack.items) |*frame| {
            frame.patch_sites.deinit(self.allocator);
            frame.result_slots.deinit(self.allocator);
            frame.param_slots.deinit(self.allocator);
        }
        self.control_stack.deinit(self.allocator);
        self.free_slots.deinit(self.allocator);
    }

    /// Reset this Lower for reuse on a new function body, retaining all
    /// allocated buffer capacity to avoid repeated alloc/free churn.
    ///
    /// After `reset`, the Lower is in the same logical state as a fresh
    /// `initWithReservedSlots(self.allocator, reserved_slots, locals_count)`
    /// but without freeing and reallocating any backing memory.
    pub fn reset(self: *Lower, reserved_slots: u32, locals_count: u16) void {
        // Clear value stack retaining capacity.
        self.stack.slots.clearRetainingCapacity();

        // Clear compiled output lists retaining capacity.
        self.compiled.ops.clearRetainingCapacity();
        self.compiled.call_args.clearRetainingCapacity();
        self.compiled.br_table_targets.clearRetainingCapacity();
        self.compiled.catch_handler_tables.clearRetainingCapacity();
        self.compiled.slots_len = reserved_slots;
        self.compiled.locals_count = locals_count;

        // Clear and deinit each ControlFrame's inner lists.
        // We free the per-frame inner lists (they are typically tiny) and clear
        // the outer control_stack slice retaining its backing array.
        for (self.control_stack.items) |*frame| {
            frame.patch_sites.deinit(self.allocator);
            frame.result_slots.deinit(self.allocator);
            frame.param_slots.deinit(self.allocator);
        }
        self.control_stack.clearRetainingCapacity();

        // Reset scalar fields.
        self.next_slot = reserved_slots;
        self.reserved_slots = reserved_slots;
        self.composite_types = &.{};
        self.is_unreachable = false;
        self.unreachable_depth = 0;
        // Recycle the free-list capacity but discard stale slot numbers.
        self.free_slots.clearRetainingCapacity();
    }

    // ── Slot helpers ──────────────────────────────────────────────────────────

    /// Resolve a ?BlockType into allocated param_slots and result_slots lists.
    /// For void (null): both lists are empty.
    /// For .val_type: result_slots has one allocated slot; param_slots is empty.
    /// For .type_index: looks up the FuncType and allocates one slot per param
    ///   and one slot per result.
    ///
    /// The caller owns the returned lists and must deinit them.
    pub fn resolve_block_slots(
        self: *Lower,
        block_type: ?BlockType,
    ) !struct { params: SmallSlotList, results: SmallSlotList } {
        var params: SmallSlotList = .empty;
        errdefer params.deinit(self.allocator);
        var results: SmallSlotList = .empty;
        errdefer results.deinit(self.allocator);

        const bt = block_type orelse {
            record_frame_slots(0, 0);
            return .{ .params = params, .results = results };
        };
        switch (bt) {
            .val_type => {
                // Single result, no params.
                try results.append(self.allocator, self.alloc_slot());
            },
            .type_index => |idx| {
                if (idx >= self.composite_types.len) return error.InvalidFunctionType;
                const ft = switch (self.composite_types[idx]) {
                    .func_type => |*f| f,
                    else => return error.InvalidFunctionType,
                };
                for (ft.params()) |_| {
                    try params.append(self.allocator, self.alloc_slot());
                }
                for (ft.results()) |_| {
                    try results.append(self.allocator, self.alloc_slot());
                }
            },
        }
        record_frame_slots(params.items().len, results.items().len);
        return .{ .params = params, .results = results };
    }

    inline fn record_frame_slots(n_params: usize, n_results: usize) void {
        if (!profiling.enabled) return;
        profiling.frame_prof.total_frames += 1;
        switch (n_results) {
            0 => profiling.frame_prof.result_slots_0 += 1,
            1 => profiling.frame_prof.result_slots_1 += 1,
            2 => profiling.frame_prof.result_slots_2 += 1,
            else => profiling.frame_prof.result_slots_gt2 += 1,
        }
        if (n_results > profiling.frame_prof.result_slots_max)
            profiling.frame_prof.result_slots_max = n_results;
        switch (n_params) {
            0 => profiling.frame_prof.param_slots_0 += 1,
            1 => profiling.frame_prof.param_slots_1 += 1,
            2 => profiling.frame_prof.param_slots_2 += 1,
            else => profiling.frame_prof.param_slots_gt2 += 1,
        }
        if (n_params > profiling.frame_prof.param_slots_max)
            profiling.frame_prof.param_slots_max = n_params;
    }

    pub fn alloc_slot(self: *Lower) Slot {
        // Reuse a recycled temporary slot if available.
        if (self.free_slots.pop()) |slot| {
            return slot;
        }
        const slot = self.next_slot;
        self.next_slot += 1;
        if (self.compiled.slots_len < self.next_slot) {
            self.compiled.slots_len = self.next_slot;
        }
        return slot;
    }

    /// Allocates two consecutive slots for a V128 value.
    /// Returns the index of the first (low) slot; the caller uses slot and slot+1.
    /// Never reuses free-list entries because those are not guaranteed to be consecutive.
    pub fn alloc_simd_slot(self: *Lower) Slot {
        const slot = self.next_slot;
        self.next_slot += 2;
        if (self.compiled.slots_len < self.next_slot) {
            self.compiled.slots_len = self.next_slot;
        }
        return slot;
    }

    pub fn emit(self: *Lower, op: Op) !void {
        try self.compiled.ops.append(self.allocator, op);
    }

    /// Current index that the *next* emitted op will occupy.
    pub fn current_pc(self: *Lower) u32 {
        return @intCast(self.compiled.ops.items.len);
    }

    pub fn pop_slot(self: *Lower) LowerError!Slot {
        const slot = self.stack.pop() orelse return error.StackUnderflow;
        // Recycle SSA temporaries (slots >= reserved_slots) back into the free-list.
        // Params and locals ([0..reserved_slots)) live for the full function and must not be recycled.
        if (slot >= self.reserved_slots) {
            self.free_slots.append(self.allocator, slot) catch {};
        }
        return slot;
    }

    pub fn local_to_slot(_: *Lower, local: u32) Slot {
        return local;
    }

    // ── Control stack helpers ─────────────────────────────────────────────────

    /// Look up a frame by br depth (0 = innermost).
    fn frame_at_depth(self: *Lower, depth: u32) LowerError!*ControlFrame {
        const len = self.control_stack.items.len;
        if (depth >= len) return error.ControlStackUnderflow;
        return &self.control_stack.items[len - 1 - depth];
    }

    /// Restore the value stack to the height recorded in `frame`, then
    /// push the frame's result slots back (in order: first result at bottom).
    pub fn unwind_stack_to_frame(self: *Lower, frame: *const ControlFrame) !void {
        // Truncate the value stack to the frame's entry height.
        if (frame.stack_height > self.stack.slots.items.len) {
            return error.StackUnderflow;
        }
        self.stack.slots.shrinkRetainingCapacity(frame.stack_height);
        // Push result slots so downstream ops can consume them.
        for (frame.result_slots.items()) |rs| {
            try self.stack.push(self.allocator, rs);
        }
    }

    /// Record that the jump/jump_if_z op at `site` needs its target patched
    /// to point to the end of `frame`.
    fn add_patch_site(self: *Lower, frame: *ControlFrame, site: u32) !void {
        try frame.patch_sites.append(self.allocator, site);
    }

    /// Fill in all forward-jump targets in `frame` to point to `target_pc`.
    /// Patch sites with bit 31 set encode br_table_targets indices (bit 31 cleared gives the index).
    /// All other sites are op indices for jump / jump_if_z / br_on_* ops.
    pub fn patch_forward_jumps(self: *Lower, frame: *ControlFrame, target_pc: u32) void {
        if (profiling.enabled) {
            const n = frame.patch_sites.items().len;
            switch (n) {
                0 => profiling.frame_prof.patch_sites_0 += 1,
                1 => profiling.frame_prof.patch_sites_1 += 1,
                2 => profiling.frame_prof.patch_sites_2 += 1,
                3 => profiling.frame_prof.patch_sites_3 += 1,
                4 => profiling.frame_prof.patch_sites_4 += 1,
                else => profiling.frame_prof.patch_sites_gt4 += 1,
            }
            if (n > profiling.frame_prof.patch_sites_max)
                profiling.frame_prof.patch_sites_max = n;
        }
        for (frame.patch_sites.items()) |site| {
            if (site & 0x8000_0000 != 0) {
                // br_table_targets patch site
                const tgt_idx = site & 0x7FFF_FFFF;
                self.compiled.br_table_targets.items[tgt_idx] = target_pc;
            } else if (site & 0x4000_0000 != 0) {
                // catch_handler_tables patch site
                const handler_idx = site & 0x3FFF_FFFF;
                self.compiled.catch_handler_tables.items[handler_idx].target = target_pc;
            } else {
                switch (self.compiled.ops.items[site]) {
                    .jump => |*j| j.target = target_pc,
                    .jump_if_z => |*j| j.target = target_pc,
                    .br_on_null => |*j| j.target = target_pc,
                    .br_on_non_null => |*j| j.target = target_pc,
                    .br_on_cast => |*j| j.target = target_pc,
                    .br_on_cast_fail => |*j| j.target = target_pc,
                    .try_table_leave => |*j| j.target = target_pc,
                    // Fused compare-jump ops (Peephole F)
                    .i32_eq_jump_if_false => |*j| j.target = target_pc,
                    .i32_ne_jump_if_false => |*j| j.target = target_pc,
                    .i32_lt_s_jump_if_false => |*j| j.target = target_pc,
                    .i32_lt_u_jump_if_false => |*j| j.target = target_pc,
                    .i32_gt_s_jump_if_false => |*j| j.target = target_pc,
                    .i32_gt_u_jump_if_false => |*j| j.target = target_pc,
                    .i32_le_s_jump_if_false => |*j| j.target = target_pc,
                    .i32_le_u_jump_if_false => |*j| j.target = target_pc,
                    .i32_ge_s_jump_if_false => |*j| j.target = target_pc,
                    .i32_ge_u_jump_if_false => |*j| j.target = target_pc,
                    .i32_eqz_jump_if_false => |*j| j.target = target_pc,
                    // Fused i64 compare-jump ops (Peephole F, i64)
                    .i64_eq_jump_if_false => |*j| j.target = target_pc,
                    .i64_ne_jump_if_false => |*j| j.target = target_pc,
                    .i64_lt_s_jump_if_false => |*j| j.target = target_pc,
                    .i64_lt_u_jump_if_false => |*j| j.target = target_pc,
                    .i64_gt_s_jump_if_false => |*j| j.target = target_pc,
                    .i64_gt_u_jump_if_false => |*j| j.target = target_pc,
                    .i64_le_s_jump_if_false => |*j| j.target = target_pc,
                    .i64_le_u_jump_if_false => |*j| j.target = target_pc,
                    .i64_ge_s_jump_if_false => |*j| j.target = target_pc,
                    .i64_ge_u_jump_if_false => |*j| j.target = target_pc,
                    .i64_eqz_jump_if_false => |*j| j.target = target_pc,
                    // Fused compare-imm-jump ops (Peephole G)
                    .i32_eq_imm_jump_if_false => |*j| j.target = target_pc,
                    .i32_ne_imm_jump_if_false => |*j| j.target = target_pc,
                    .i32_lt_s_imm_jump_if_false => |*j| j.target = target_pc,
                    .i32_lt_u_imm_jump_if_false => |*j| j.target = target_pc,
                    .i32_gt_s_imm_jump_if_false => |*j| j.target = target_pc,
                    .i32_gt_u_imm_jump_if_false => |*j| j.target = target_pc,
                    .i32_le_s_imm_jump_if_false => |*j| j.target = target_pc,
                    .i32_le_u_imm_jump_if_false => |*j| j.target = target_pc,
                    .i32_ge_s_imm_jump_if_false => |*j| j.target = target_pc,
                    .i32_ge_u_imm_jump_if_false => |*j| j.target = target_pc,
                    .i64_eq_imm_jump_if_false => |*j| j.target = target_pc,
                    .i64_ne_imm_jump_if_false => |*j| j.target = target_pc,
                    .i64_lt_s_imm_jump_if_false => |*j| j.target = target_pc,
                    .i64_lt_u_imm_jump_if_false => |*j| j.target = target_pc,
                    .i64_gt_s_imm_jump_if_false => |*j| j.target = target_pc,
                    .i64_gt_u_imm_jump_if_false => |*j| j.target = target_pc,
                    .i64_le_s_imm_jump_if_false => |*j| j.target = target_pc,
                    .i64_le_u_imm_jump_if_false => |*j| j.target = target_pc,
                    .i64_ge_s_imm_jump_if_false => |*j| j.target = target_pc,
                    .i64_ge_u_imm_jump_if_false => |*j| j.target = target_pc,
                    else => unreachable,
                }
            }
        }
        frame.patch_sites.clearRetainingCapacity();
    }

    // ── Emit a branch to `frame` ──────────────────────────────────────────────

    /// Copy the top-of-stack into the frame's result slot (if any), then emit
    /// an unconditional jump toward the frame's target.
    /// Returns the index of the emitted jump op (so callers can add it as a
    /// patch site if needed).
    fn emit_branch_to(self: *Lower, frame: *ControlFrame) !u32 {
        // For a loop: br passes params (phi semantics, back to header).
        // For block/if: br passes results.
        const target_slots = if (frame.kind == .loop)
            frame.param_slots.items()
        else
            frame.result_slots.items();

        // Copy values from stack top into the target slots (reverse order:
        // TOS = last slot, bottom = first slot).
        if (target_slots.len > 0) {
            var ri: usize = target_slots.len;
            while (ri > 0) {
                ri -= 1;
                const src = self.stack.peek() orelse return error.StackUnderflow;
                try self.emit(.{ .copy = .{ .dst = target_slots[ri], .src = src } });
                _ = self.stack.pop();
            }
        }

        const jump_pc = self.current_pc();
        if (frame.kind == .loop) {
            // Loop targets are known immediately (backward jump).
            try self.emit(.{ .jump = .{ .target = frame.target_pc } });
        } else {
            // Forward jump — target will be patched at `end`.
            try self.emit(.{ .jump = .{ .target = 0 } }); // placeholder
            try self.add_patch_site(frame, jump_pc);
        }
        return jump_pc;
    }

    // ── Generic operation helpers ─────────────────────────────────────────────

    /// Peephole F helper: attempts to fuse the last emitted compare op with
    /// an upcoming jump_if_z whose condition slot is `cond`.
    ///
    /// If the last op is one of the i32 binary compare ops (i32_eq … i32_ge_u)
    /// or i32_eqz, and its `dst` field equals `cond`, the compare op is removed
    /// and replaced with a fused `i32_xxx_jump_if_false` / `i32_eqz_jump_if_false`
    /// that jumps when the comparison is FALSE.
    ///
    /// Returns `true` if the fusion was performed (caller should NOT emit
    /// jump_if_z in that case), `false` otherwise.
    ///
    /// The `target` argument is the op-index of the branch destination.
    /// For forward jumps that haven't been patched yet, pass 0 — the caller
    /// must patch the target afterward using the returned op index.
    ///
    /// After a successful fusion the emitted fused op occupies
    /// `self.compiled.ops.items.len - 1`; the caller can patch its target via:
    ///   switch (self.compiled.ops.items[fused_pc]) {
    ///       .i32_eq_jump_if_false => |*j| j.target = real_target, ...
    ///   }
    fn try_fuse_compare_jump(self: *Lower, cond: Slot, target: u32) !bool {
        const ops = self.compiled.ops.items;
        if (ops.len == 0) return false;
        switch (ops[ops.len - 1]) {
            .i32_eq => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_eq_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i32_ne => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_ne_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i32_lt_s => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_lt_s_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i32_lt_u => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_lt_u_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i32_gt_s => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_gt_s_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i32_gt_u => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_gt_u_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i32_le_s => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_le_s_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i32_le_u => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_le_u_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i32_ge_s => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_ge_s_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i32_ge_u => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_ge_u_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i32_eqz => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_eqz_jump_if_false = .{ .src = c.src, .target = target } });
                return true;
            },
            // ── i64 compare-jump variants ─────────────────────────────────────
            .i64_eq => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_eq_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i64_ne => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_ne_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i64_lt_s => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_lt_s_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i64_lt_u => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_lt_u_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i64_gt_s => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_gt_s_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i64_gt_u => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_gt_u_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i64_le_s => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_le_s_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i64_le_u => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_le_u_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i64_ge_s => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_ge_s_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i64_ge_u => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_ge_u_jump_if_false = .{ .lhs = c.lhs, .rhs = c.rhs, .target = target } });
                return true;
            },
            .i64_eqz => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_eqz_jump_if_false = .{ .src = c.src, .target = target } });
                return true;
            },
            // ── Candidate G: fuse _imm compare + jump → _imm_jump_if_false ──────
            .i32_eq_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_eq_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            .i32_ne_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_ne_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            .i32_lt_s_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_lt_s_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            .i32_lt_u_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_lt_u_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            .i32_gt_s_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_gt_s_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            .i32_gt_u_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_gt_u_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            .i32_le_s_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_le_s_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            .i32_le_u_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_le_u_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            .i32_ge_s_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_ge_s_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            .i32_ge_u_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i32_ge_u_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            .i64_eq_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_eq_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            .i64_ne_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_ne_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            .i64_lt_s_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_lt_s_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            .i64_lt_u_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_lt_u_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            .i64_gt_s_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_gt_s_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            .i64_gt_u_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_gt_u_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            .i64_le_s_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_le_s_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            .i64_le_u_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_le_u_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            .i64_ge_s_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_ge_s_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            .i64_ge_u_imm => |c| if (c.dst == cond) {
                _ = self.compiled.ops.pop();
                try self.emit(.{ .i64_ge_u_imm_jump_if_false = .{ .lhs = c.lhs, .imm = c.imm, .target = target } });
                return true;
            },
            else => {},
        }
        return false;
    }

    /// Peephole D helper: attempts to fuse the last emitted i32 binop with an
    /// upcoming `local_set` whose source slot is `src`, writing the result
    /// directly into `local` instead of a temporary.
    ///
    /// Returns `true` if the fusion was performed (caller should NOT emit
    /// `local_set`); `false` otherwise.
    ///
    /// NOTE: Do NOT call this for `local_tee` because the value must also
    /// remain on the stack.
    fn try_fuse_local_set(self: *Lower, local: u32, src: Slot) bool {
        const ops = self.compiled.ops.items;
        if (ops.len == 0) return false;
        const last = &ops[ops.len - 1];
        switch (last.*) {
            .i32_add => |b| {
                if (b.dst != src) return false;
                last.* = .{ .i32_add_to_local = .{ .local = local, .lhs = b.lhs, .rhs = b.rhs } };
            },
            .i32_sub => |b| {
                if (b.dst != src) return false;
                last.* = .{ .i32_sub_to_local = .{ .local = local, .lhs = b.lhs, .rhs = b.rhs } };
            },
            .i32_mul => |b| {
                if (b.dst != src) return false;
                last.* = .{ .i32_mul_to_local = .{ .local = local, .lhs = b.lhs, .rhs = b.rhs } };
            },
            .i32_and => |b| {
                if (b.dst != src) return false;
                last.* = .{ .i32_and_to_local = .{ .local = local, .lhs = b.lhs, .rhs = b.rhs } };
            },
            .i32_or => |b| {
                if (b.dst != src) return false;
                last.* = .{ .i32_or_to_local = .{ .local = local, .lhs = b.lhs, .rhs = b.rhs } };
            },
            .i32_xor => |b| {
                if (b.dst != src) return false;
                last.* = .{ .i32_xor_to_local = .{ .local = local, .lhs = b.lhs, .rhs = b.rhs } };
            },
            .i32_shl => |b| {
                if (b.dst != src) return false;
                last.* = .{ .i32_shl_to_local = .{ .local = local, .lhs = b.lhs, .rhs = b.rhs } };
            },
            .i32_shr_s => |b| {
                if (b.dst != src) return false;
                last.* = .{ .i32_shr_s_to_local = .{ .local = local, .lhs = b.lhs, .rhs = b.rhs } };
            },
            .i32_shr_u => |b| {
                if (b.dst != src) return false;
                last.* = .{ .i32_shr_u_to_local = .{ .local = local, .lhs = b.lhs, .rhs = b.rhs } };
            },
            // ── i64 binop-to-local variants ───────────────────────────────────
            .i64_add => |b| {
                if (b.dst != src) return false;
                last.* = .{ .i64_add_to_local = .{ .local = local, .lhs = b.lhs, .rhs = b.rhs } };
            },
            .i64_sub => |b| {
                if (b.dst != src) return false;
                last.* = .{ .i64_sub_to_local = .{ .local = local, .lhs = b.lhs, .rhs = b.rhs } };
            },
            .i64_mul => |b| {
                if (b.dst != src) return false;
                last.* = .{ .i64_mul_to_local = .{ .local = local, .lhs = b.lhs, .rhs = b.rhs } };
            },
            .i64_and => |b| {
                if (b.dst != src) return false;
                last.* = .{ .i64_and_to_local = .{ .local = local, .lhs = b.lhs, .rhs = b.rhs } };
            },
            .i64_or => |b| {
                if (b.dst != src) return false;
                last.* = .{ .i64_or_to_local = .{ .local = local, .lhs = b.lhs, .rhs = b.rhs } };
            },
            .i64_xor => |b| {
                if (b.dst != src) return false;
                last.* = .{ .i64_xor_to_local = .{ .local = local, .lhs = b.lhs, .rhs = b.rhs } };
            },
            .i64_shl => |b| {
                if (b.dst != src) return false;
                last.* = .{ .i64_shl_to_local = .{ .local = local, .lhs = b.lhs, .rhs = b.rhs } };
            },
            .i64_shr_s => |b| {
                if (b.dst != src) return false;
                last.* = .{ .i64_shr_s_to_local = .{ .local = local, .lhs = b.lhs, .rhs = b.rhs } };
            },
            .i64_shr_u => |b| {
                if (b.dst != src) return false;
                last.* = .{ .i64_shr_u_to_local = .{ .local = local, .lhs = b.lhs, .rhs = b.rhs } };
            },
            // ── Candidate H/E: _imm variants → local_inplace or imm_to_local ─────
            // H has higher priority: if the lhs slot IS the same local being set,
            // fuse into local_inplace (local op= imm pattern).
            // Otherwise fall through to E: fuse into imm_to_local.
            .i32_add_imm => |b| {
                if (b.dst != src) return false;
                if (b.lhs == self.local_to_slot(local)) {
                    last.* = .{ .i32_add_local_inplace = .{ .local = local, .imm = b.imm } };
                } else {
                    last.* = .{ .i32_add_imm_to_local = .{ .local = local, .lhs = b.lhs, .imm = b.imm } };
                }
            },
            .i32_sub_imm => |b| {
                if (b.dst != src) return false;
                if (b.lhs == self.local_to_slot(local)) {
                    last.* = .{ .i32_sub_local_inplace = .{ .local = local, .imm = b.imm } };
                } else {
                    last.* = .{ .i32_sub_imm_to_local = .{ .local = local, .lhs = b.lhs, .imm = b.imm } };
                }
            },
            .i32_mul_imm => |b| {
                if (b.dst != src) return false;
                if (b.lhs == self.local_to_slot(local)) {
                    last.* = .{ .i32_mul_local_inplace = .{ .local = local, .imm = b.imm } };
                } else {
                    last.* = .{ .i32_mul_imm_to_local = .{ .local = local, .lhs = b.lhs, .imm = b.imm } };
                }
            },
            .i32_and_imm => |b| {
                if (b.dst != src) return false;
                if (b.lhs == self.local_to_slot(local)) {
                    last.* = .{ .i32_and_local_inplace = .{ .local = local, .imm = b.imm } };
                } else {
                    last.* = .{ .i32_and_imm_to_local = .{ .local = local, .lhs = b.lhs, .imm = b.imm } };
                }
            },
            .i32_or_imm => |b| {
                if (b.dst != src) return false;
                if (b.lhs == self.local_to_slot(local)) {
                    last.* = .{ .i32_or_local_inplace = .{ .local = local, .imm = b.imm } };
                } else {
                    last.* = .{ .i32_or_imm_to_local = .{ .local = local, .lhs = b.lhs, .imm = b.imm } };
                }
            },
            .i32_xor_imm => |b| {
                if (b.dst != src) return false;
                if (b.lhs == self.local_to_slot(local)) {
                    last.* = .{ .i32_xor_local_inplace = .{ .local = local, .imm = b.imm } };
                } else {
                    last.* = .{ .i32_xor_imm_to_local = .{ .local = local, .lhs = b.lhs, .imm = b.imm } };
                }
            },
            .i32_shl_imm => |b| {
                if (b.dst != src) return false;
                if (b.lhs == self.local_to_slot(local)) {
                    last.* = .{ .i32_shl_local_inplace = .{ .local = local, .imm = b.imm } };
                } else {
                    last.* = .{ .i32_shl_imm_to_local = .{ .local = local, .lhs = b.lhs, .imm = b.imm } };
                }
            },
            .i32_shr_s_imm => |b| {
                if (b.dst != src) return false;
                if (b.lhs == self.local_to_slot(local)) {
                    last.* = .{ .i32_shr_s_local_inplace = .{ .local = local, .imm = b.imm } };
                } else {
                    last.* = .{ .i32_shr_s_imm_to_local = .{ .local = local, .lhs = b.lhs, .imm = b.imm } };
                }
            },
            .i32_shr_u_imm => |b| {
                if (b.dst != src) return false;
                if (b.lhs == self.local_to_slot(local)) {
                    last.* = .{ .i32_shr_u_local_inplace = .{ .local = local, .imm = b.imm } };
                } else {
                    last.* = .{ .i32_shr_u_imm_to_local = .{ .local = local, .lhs = b.lhs, .imm = b.imm } };
                }
            },
            // ── i64 _imm variants ─────────────────────────────────────────────────
            .i64_add_imm => |b| {
                if (b.dst != src) return false;
                if (b.lhs == self.local_to_slot(local)) {
                    last.* = .{ .i64_add_local_inplace = .{ .local = local, .imm = b.imm } };
                } else {
                    last.* = .{ .i64_add_imm_to_local = .{ .local = local, .lhs = b.lhs, .imm = b.imm } };
                }
            },
            .i64_sub_imm => |b| {
                if (b.dst != src) return false;
                if (b.lhs == self.local_to_slot(local)) {
                    last.* = .{ .i64_sub_local_inplace = .{ .local = local, .imm = b.imm } };
                } else {
                    last.* = .{ .i64_sub_imm_to_local = .{ .local = local, .lhs = b.lhs, .imm = b.imm } };
                }
            },
            .i64_mul_imm => |b| {
                if (b.dst != src) return false;
                if (b.lhs == self.local_to_slot(local)) {
                    last.* = .{ .i64_mul_local_inplace = .{ .local = local, .imm = b.imm } };
                } else {
                    last.* = .{ .i64_mul_imm_to_local = .{ .local = local, .lhs = b.lhs, .imm = b.imm } };
                }
            },
            .i64_and_imm => |b| {
                if (b.dst != src) return false;
                if (b.lhs == self.local_to_slot(local)) {
                    last.* = .{ .i64_and_local_inplace = .{ .local = local, .imm = b.imm } };
                } else {
                    last.* = .{ .i64_and_imm_to_local = .{ .local = local, .lhs = b.lhs, .imm = b.imm } };
                }
            },
            .i64_or_imm => |b| {
                if (b.dst != src) return false;
                if (b.lhs == self.local_to_slot(local)) {
                    last.* = .{ .i64_or_local_inplace = .{ .local = local, .imm = b.imm } };
                } else {
                    last.* = .{ .i64_or_imm_to_local = .{ .local = local, .lhs = b.lhs, .imm = b.imm } };
                }
            },
            .i64_xor_imm => |b| {
                if (b.dst != src) return false;
                if (b.lhs == self.local_to_slot(local)) {
                    last.* = .{ .i64_xor_local_inplace = .{ .local = local, .imm = b.imm } };
                } else {
                    last.* = .{ .i64_xor_imm_to_local = .{ .local = local, .lhs = b.lhs, .imm = b.imm } };
                }
            },
            .i64_shl_imm => |b| {
                if (b.dst != src) return false;
                if (b.lhs == self.local_to_slot(local)) {
                    last.* = .{ .i64_shl_local_inplace = .{ .local = local, .imm = b.imm } };
                } else {
                    last.* = .{ .i64_shl_imm_to_local = .{ .local = local, .lhs = b.lhs, .imm = b.imm } };
                }
            },
            .i64_shr_s_imm => |b| {
                if (b.dst != src) return false;
                if (b.lhs == self.local_to_slot(local)) {
                    last.* = .{ .i64_shr_s_local_inplace = .{ .local = local, .imm = b.imm } };
                } else {
                    last.* = .{ .i64_shr_s_imm_to_local = .{ .local = local, .lhs = b.lhs, .imm = b.imm } };
                }
            },
            .i64_shr_u_imm => |b| {
                if (b.dst != src) return false;
                if (b.lhs == self.local_to_slot(local)) {
                    last.* = .{ .i64_shr_u_local_inplace = .{ .local = local, .imm = b.imm } };
                } else {
                    last.* = .{ .i64_shr_u_imm_to_local = .{ .local = local, .lhs = b.lhs, .imm = b.imm } };
                }
            },
            else => return false,
        }
        return true;
    }

    /// Handle binary operations: pop two operands, allocate result slot, emit, push result.
    /// The op_tag parameter is a string literal representing the Op field name.
    pub fn lower_binary_op(
        self: *Lower,
        comptime op_tag: []const u8,
    ) !void {
        const rhs = try self.pop_slot();
        const lhs = try self.pop_slot();
        const dst = self.alloc_slot();

        // ── Peephole C: const_i32/i64 + xxx → xxx_imm ────────────────────────
        // If there is a fused _imm variant for this op AND the previous emitted
        // op is `const_i32`/`const_i64` whose dst matches rhs, fold it into an immediate.
        const imm_tag = op_tag ++ "_imm";
        if (comptime @hasField(Op, imm_tag)) {
            // Determine imm type from the fused op's struct field at compile time.
            const ImmType = @TypeOf(@field(@as(std.meta.TagPayload(Op, @field(Op, imm_tag)), undefined), "imm"));
            const ops = self.compiled.ops.items;
            if (ops.len > 0) {
                switch (ops[ops.len - 1]) {
                    .const_i32 => |c| if (ImmType == i32 and c.dst == rhs) {
                        // Remove the const_i32 and emit the fused imm op instead.
                        _ = self.compiled.ops.pop();
                        try self.emit(@unionInit(Op, imm_tag, .{
                            .dst = dst,
                            .lhs = lhs,
                            .imm = c.value,
                        }));
                        try self.stack.push(self.allocator, dst);
                        return;
                    },
                    .const_i64 => |c| if (ImmType == i64 and c.dst == rhs) {
                        _ = self.compiled.ops.pop();
                        try self.emit(@unionInit(Op, imm_tag, .{
                            .dst = dst,
                            .lhs = lhs,
                            .imm = c.value,
                        }));
                        try self.stack.push(self.allocator, dst);
                        return;
                    },
                    else => {},
                }
            }
        }

        try self.emit(@unionInit(Op, op_tag, .{
            .dst = dst,
            .lhs = lhs,
            .rhs = rhs,
        }));

        try self.stack.push(self.allocator, dst);
    }

    /// Handle unary operations: pop one operand, allocate result slot, emit, push result.
    pub fn lower_unary_op(
        self: *Lower,
        comptime op_tag: []const u8,
    ) !void {
        const src = try self.pop_slot();
        const dst = self.alloc_slot();

        try self.emit(@unionInit(Op, op_tag, .{
            .dst = dst,
            .src = src,
        }));

        try self.stack.push(self.allocator, dst);
    }

    /// Handle conversion operations: pop one operand, allocate result slot, emit, push result.
    pub fn lower_convert_op(
        self: *Lower,
        comptime op_tag: []const u8,
    ) !void {
        const src = try self.pop_slot();
        const dst = self.alloc_slot();

        try self.emit(@unionInit(Op, op_tag, .{
            .dst = dst,
            .src = src,
        }));

        try self.stack.push(self.allocator, dst);
    }

    /// Handle comparison operations: pop two operands, allocate result slot (i32), emit, push result.
    pub fn lower_compare_op(
        self: *Lower,
        comptime op_tag: []const u8,
    ) !void {
        const rhs = try self.pop_slot();
        const lhs = try self.pop_slot();
        const dst = self.alloc_slot();

        // ── Peephole C (compare variant): const_i32/i64 + xxx_cmp → xxx_cmp_imm ──
        const imm_tag = op_tag ++ "_imm";
        if (comptime @hasField(Op, imm_tag)) {
            const ImmType = @TypeOf(@field(@as(std.meta.TagPayload(Op, @field(Op, imm_tag)), undefined), "imm"));
            const ops = self.compiled.ops.items;
            if (ops.len > 0) {
                switch (ops[ops.len - 1]) {
                    .const_i32 => |c| if (ImmType == i32 and c.dst == rhs) {
                        _ = self.compiled.ops.pop();
                        try self.emit(@unionInit(Op, imm_tag, .{
                            .dst = dst,
                            .lhs = lhs,
                            .imm = c.value,
                        }));
                        try self.stack.push(self.allocator, dst);
                        return;
                    },
                    .const_i64 => |c| if (ImmType == i64 and c.dst == rhs) {
                        _ = self.compiled.ops.pop();
                        try self.emit(@unionInit(Op, imm_tag, .{
                            .dst = dst,
                            .lhs = lhs,
                            .imm = c.value,
                        }));
                        try self.stack.push(self.allocator, dst);
                        return;
                    },
                    else => {},
                }
            }
        }

        try self.emit(@unionInit(Op, op_tag, .{
            .dst = dst,
            .lhs = lhs,
            .rhs = rhs,
        }));

        try self.stack.push(self.allocator, dst);
    }

    fn lower_simd_unary(self: *Lower, opcode: SimdOpcode) !void {
        const src = try self.pop_slot();
        // Splat: scalar src → V128 dst (two slots)
        // Scalar-result (any_true/all_true/bitmask): V128 src → scalar dst (one slot)
        // All other unary: V128 src → V128 dst (two slots)
        const dst = if (!simd.isVectorResultOpcode(opcode))
            self.alloc_slot() // scalar result
        else
            self.alloc_simd_slot(); // V128 result
        try self.emit(.{ .simd_unary = .{ .dst = dst, .opcode = opcode, .src = src } });
        try self.stack.push(self.allocator, dst);
    }

    fn lower_simd_binary(self: *Lower, opcode: SimdOpcode) !void {
        const rhs = try self.pop_slot();
        const lhs = try self.pop_slot();
        const dst = self.alloc_simd_slot();
        try self.emit(.{ .simd_binary = .{ .dst = dst, .opcode = opcode, .lhs = lhs, .rhs = rhs } });
        try self.stack.push(self.allocator, dst);
    }

    fn lower_simd_ternary(self: *Lower, opcode: SimdOpcode) !void {
        const third = try self.pop_slot();
        const second = try self.pop_slot();
        const first = try self.pop_slot();
        const dst = self.alloc_simd_slot();
        try self.emit(.{ .simd_ternary = .{
            .dst = dst,
            .opcode = opcode,
            .first = first,
            .second = second,
            .third = third,
        } });
        try self.stack.push(self.allocator, dst);
    }

    // ── Main dispatch ─────────────────────────────────────────────────────────

    pub fn lowerOp(self: *Lower, op: WasmOp) !void {
        // Dead-code elimination: when in unreachable state, only track control-flow
        // nesting depth. Real processing resumes at the matching `end` or `else`.
        var was_unreachable = false;
        if (self.is_unreachable) {
            switch (op) {
                .block, .loop, .if_, .try_table => {
                    self.unreachable_depth += 1;
                    return;
                },
                .end => {
                    if (self.unreachable_depth > 0) {
                        self.unreachable_depth -= 1;
                        return;
                    }
                    // This end matches the block that contains the unreachable br/return.
                    self.is_unreachable = false;
                    was_unreachable = true;
                    // Reset the stack to the frame's entry height before the normal
                    // end handler tries to pop result values that don't exist.
                    if (self.control_stack.items.len > 0) {
                        const frame = &self.control_stack.items[self.control_stack.items.len - 1];
                        self.stack.slots.shrinkRetainingCapacity(frame.stack_height);
                    }
                    // Fall through to normal end handling (but skip result copying).
                },
                .else_ => {
                    if (self.unreachable_depth > 0) {
                        return;
                    }
                    // The then-branch was unreachable but else may be reachable.
                    self.is_unreachable = false;
                    // Fall through to normal else handling.
                },
                else => return, // skip all other ops in unreachable code
            }
        }

        switch (op) {
            .unreachable_ => {
                try self.emit(.unreachable_);
                self.is_unreachable = true;
            },

            .nop => {
                // No-op: nothing to emit.
            },

            .drop => {
                _ = try self.pop_slot();
            },

            // ── Structured control flow ───────────────────────────────────────

            .block => |block_type| {
                const slots = try self.resolve_block_slots(block_type);
                // For multi-value blocks: pop params from stack, re-push so body can access them.
                // Copy param values from stack into param_slots (in order, lowest first).
                for (slots.params.items()) |ps| {
                    _ = ps; // slot already allocated; we'll copy from stack below
                }
                // Actually we need to pop params from the stack top (last param = TOS) and
                // store them in param_slots, then re-push them back for the body.
                // Stack before: [..., param0, param1, ..., paramN-1]  (paramN-1 = TOS)
                // We need to copy them into param_slots[0..N], then restore the stack.
                const n_params = slots.params.items().len;
                if (n_params > 0) {
                    // Pop params off the value stack (TOS = last param).
                    // We re-push them back after so the block body sees them.
                    var pi: usize = n_params;
                    while (pi > 0) {
                        pi -= 1;
                        const src = try self.pop_slot();
                        try self.emit(.{ .copy = .{ .dst = slots.params.items()[pi], .src = src } });
                    }
                }
                // Record the stack height AFTER consuming params (before block body).
                const height_after_params = self.stack.len();
                // Re-push param slots so the block body can use them.
                for (slots.params.items()) |ps| {
                    try self.stack.push(self.allocator, ps);
                }

                try self.control_stack.append(self.allocator, .{
                    .kind = .block,
                    .stack_height = height_after_params,
                    .result_slots = slots.results,
                    .param_slots = slots.params,
                    .target_pc = 0, // forward — filled at end
                });
            },

            .loop => |block_type| {
                const slots = try self.resolve_block_slots(block_type);
                // Pop params from stack (TOS = last param), copy to param_slots, re-push.
                const n_params = slots.params.items().len;
                if (n_params > 0) {
                    var pi: usize = n_params;
                    while (pi > 0) {
                        pi -= 1;
                        const src = try self.pop_slot();
                        try self.emit(.{ .copy = .{ .dst = slots.params.items()[pi], .src = src } });
                    }
                }
                const height_after_params = self.stack.len();
                for (slots.params.items()) |ps| {
                    try self.stack.push(self.allocator, ps);
                }

                // The loop target is right here (top of the loop body).
                const loop_header_pc = self.current_pc();
                try self.control_stack.append(self.allocator, .{
                    .kind = .loop,
                    .stack_height = height_after_params,
                    .result_slots = slots.results,
                    .param_slots = slots.params,
                    .target_pc = loop_header_pc,
                });
            },

            .if_ => |block_type| {
                const cond = try self.pop_slot();
                const slots = try self.resolve_block_slots(block_type);
                // Pop params from stack (TOS = last param), copy to param_slots, re-push.
                const n_params = slots.params.items().len;
                if (n_params > 0) {
                    var pi: usize = n_params;
                    while (pi > 0) {
                        pi -= 1;
                        const src = try self.pop_slot();
                        try self.emit(.{ .copy = .{ .dst = slots.params.items()[pi], .src = src } });
                    }
                }
                const height_after_params = self.stack.len();
                for (slots.params.items()) |ps| {
                    try self.stack.push(self.allocator, ps);
                }

                // Emit a conditional jump that skips the then-body if cond==0.
                // Target is patched at else_ or end.
                // ── Peephole F: fuse preceding compare + jump_if_z ────────────
                if (!try self.try_fuse_compare_jump(cond, 0)) {
                    try self.emit(.{ .jump_if_z = .{ .cond = cond, .target = 0 } });
                }
                const jiz_pc = self.current_pc() - 1; // index of the jump_if_z or fused op

                try self.control_stack.append(self.allocator, .{
                    .kind = .if_,
                    .stack_height = height_after_params,
                    .result_slots = slots.results,
                    .param_slots = slots.params,
                    .target_pc = 0, // forward
                    .patch_sites = blk: {
                        // The jump_if_z is a forward patch site for the else/end.
                        var ps: SmallPatchList = .empty;
                        try ps.append(self.allocator, jiz_pc);
                        break :blk ps;
                    },
                });
            },

            .else_ => {
                const len = self.control_stack.items.len;
                if (len == 0) return error.MismatchedEnd;
                const frame = &self.control_stack.items[len - 1];
                frame.has_else = true;

                // Copy the then-branch results into the result slots before leaving the then-body.
                // The stack top holds the last result; result_slots[N-1] is the last result slot.
                {
                    const n = frame.result_slots.items().len;
                    var ri: usize = n;
                    while (ri > 0) {
                        ri -= 1;
                        const src = self.stack.peek() orelse break;
                        try self.emit(.{ .copy = .{ .dst = frame.result_slots.items()[ri], .src = src } });
                        _ = self.stack.pop();
                    }
                }

                // Emit an unconditional jump to skip the else-body (from end of then-body).
                const then_end_jump_pc = self.current_pc();
                try self.emit(.{ .jump = .{ .target = 0 } }); // placeholder

                // The else body starts here — patch all the if's forward jumps.
                const else_start_pc = self.current_pc();
                self.patch_forward_jumps(frame, else_start_pc);

                // The then_end_jump is now the new forward patch site for `end`.
                try self.add_patch_site(frame, then_end_jump_pc);

                // Reset the value stack to block-entry height, then re-push param slots
                // so the else body sees the same inputs as the then body.
                self.stack.slots.shrinkRetainingCapacity(frame.stack_height);
                for (frame.param_slots.items()) |ps| {
                    try self.stack.push(self.allocator, ps);
                }
            },

            .end => {
                if (self.control_stack.items.len == 0) {
                    // The final `end` of the function body — emit return.
                    // This path is taken only when no implicit function frame was pushed
                    // (legacy code path kept for safety).
                    if (!was_unreachable) {
                        const value = self.stack.pop();
                        try self.emit(.{ .ret = .{ .value = value } });
                    } else {
                        // Even for unreachable code, emit a sentinel ret so the M3 code
                        // buffer always ends with a valid terminator (never actually executed).
                        try self.emit(.{ .ret = .{ .value = null } });
                    }
                    return;
                }

                var frame = self.control_stack.pop().?;
                defer frame.patch_sites.deinit(self.allocator);
                defer frame.result_slots.deinit(self.allocator);
                defer frame.param_slots.deinit(self.allocator);

                // ── Function-level implicit frame ─────────────────────────────
                // When the implicit function frame is popped we emit `ret` instead
                // of a continuation jump, exactly like the `control_stack.len == 0`
                // path above.  Any `br` that targeted this frame already emitted a
                // `copy` + forward `jump` that will be patched to land right here,
                // just before the `ret`.
                if (frame.is_function_frame) {
                    // Patch all forward jumps (from `br depth` targeting the function
                    // frame) to land at the upcoming `ret`.
                    const ret_pc = self.current_pc();
                    self.patch_forward_jumps(&frame, ret_pc);
                    if (!was_unreachable) {
                        const value = self.stack.pop();
                        try self.emit(.{ .ret = .{ .value = value } });
                    } else {
                        // Emit a sentinel ret so the M3 code buffer always ends with a
                        // valid terminator (this ret is never actually executed).
                        try self.emit(.{ .ret = .{ .value = null } });
                    }
                    return;
                }

                // Copy block results from the stack top into the result slots.
                // Skip this when coming from unreachable code — the br/return already
                // copied values into result_slots and the stack has been trimmed.
                if (!was_unreachable) {
                    // Stack top = last result (result_slots[N-1]); bottom of N values = first result.
                    const n = frame.result_slots.items().len;
                    var ri: usize = n;
                    while (ri > 0) {
                        ri -= 1;
                        if (self.stack.peek()) |src| {
                            try self.emit(.{ .copy = .{ .dst = frame.result_slots.items()[ri], .src = src } });
                            _ = self.stack.pop();
                        }
                    }
                }

                // ── If-without-else zero-init ────────────────────────────────
                // When an `if` block has result types but no `else` branch, the
                // false path (jump_if_z) lands directly at `end`.  The result
                // slots were never written on the false path and must be
                // explicitly zero-initialised (the Wasm spec says the implicit
                // else produces default zero values).
                //
                // Layout:
                //   [then-body result copies]
                //   jump → continuation         ← skip false-path zeroing
                // false_path:
                //   const_i64 0 → result_slots[0..N]
                // continuation:                 ← both paths merge here
                if (frame.kind == .if_ and !frame.has_else and frame.result_slots.items().len > 0) {
                    // Emit a jump from the then-path over the false-path zeroing.
                    const then_skip_pc = self.current_pc();
                    try self.emit(.{ .jump = .{ .target = 0 } }); // placeholder, patched below

                    // Patch jump_if_z (and any other forward jumps) to land here.
                    const false_path_pc = self.current_pc();
                    self.patch_forward_jumps(&frame, false_path_pc);

                    // Emit explicit zero-init for each result slot.
                    for (frame.result_slots.items()) |rs| {
                        try self.emit(.{ .const_i64 = .{ .dst = rs, .value = 0 } });
                    }

                    // Patch the then-skip jump to land here (continuation).
                    const continuation_pc = self.current_pc();
                    switch (self.compiled.ops.items[then_skip_pc]) {
                        .jump => |*j| j.target = continuation_pc,
                        else => unreachable,
                    }

                    // Clear patch_sites so the normal patch_forward_jumps below is a no-op.
                    frame.patch_sites.clearRetainingCapacity();
                }

                // For try_table: emit try_table_leave (normal-exit jump) and
                // backpatch try_table_enter.end_target to point here.
                if (frame.kind == .try_table) {
                    // Record pc of try_table_leave as a patch site (forward jump to continuation).
                    const leave_pc = self.current_pc();
                    try self.emit(.{ .try_table_leave = .{ .target = 0 } });
                    try frame.patch_sites.append(self.allocator, leave_pc);

                    // Backpatch try_table_enter.end_target.
                    if (frame.try_table_enter_pc) |epc| {
                        switch (self.compiled.ops.items[epc]) {
                            .try_table_enter => |*e| e.end_target = leave_pc,
                            else => unreachable,
                        }
                    }
                }

                // The continuation starts at the next op.
                const end_pc = self.current_pc();
                self.patch_forward_jumps(&frame, end_pc);

                // Restore value stack and push result slots.
                try self.unwind_stack_to_frame(&frame);
            },

            .br => |depth| {
                const frame = try self.frame_at_depth(depth);
                _ = try self.emit_branch_to(frame);
                // After an unconditional br the rest of the block is unreachable;
                // reset the stack to the frame's height so further ops (up to the
                // matching end) do not see stale values.
                const target = @min(frame.stack_height, self.stack.slots.items.len);
                self.stack.slots.shrinkRetainingCapacity(target);
                self.is_unreachable = true;
            },

            .br_if => |depth| {
                const cond = try self.pop_slot();
                const frame = try self.frame_at_depth(depth);

                // For a loop: br_if passes params; for block/if: passes results.
                const target_slots = if (frame.kind == .loop)
                    frame.param_slots.items()
                else
                    frame.result_slots.items();

                // Copy values from stack into target slots (peek, don't pop — fall-through
                // needs the values still on stack).
                // Stack top = last result slot; we peek from TOS downward.
                if (target_slots.len > 0) {
                    const stack_len = self.stack.len();
                    if (stack_len < target_slots.len) return error.StackUnderflow;
                    var ri: usize = target_slots.len;
                    while (ri > 0) {
                        ri -= 1;
                        // stack[stack_len - 1 - (target_slots.len - 1 - ri)]
                        // = stack[stack_len - target_slots.len + ri]
                        const src = self.stack.slots.items[stack_len - target_slots.len + ri];
                        try self.emit(.{ .copy = .{ .dst = target_slots[ri], .src = src } });
                    }
                }

                // Emit conditional jump.
                // We jump when cond != 0, but our op is jump_if_z.
                // Work-around: emit jump_if_z to skip the unconditional jump,
                // then emit the unconditional jump to the target.
                //   jump_if_z cond → skip_jump
                //   jump → target
                //   skip_jump: (fall-through, continue)
                // ── Peephole F: fuse preceding compare + jump_if_z ────────────
                if (!try self.try_fuse_compare_jump(cond, 0)) {
                    try self.emit(.{ .jump_if_z = .{ .cond = cond, .target = 0 } }); // skip the jump below if cond==0
                }
                const jiz_pc = self.current_pc() - 1; // index of the jump_if_z or fused op

                // Now emit the actual branch to the target frame.
                const branch_jump_pc = self.current_pc();
                if (frame.kind == .loop) {
                    try self.emit(.{ .jump = .{ .target = frame.target_pc } });
                } else {
                    try self.emit(.{ .jump = .{ .target = 0 } }); // forward — patch at end
                    try self.add_patch_site(frame, branch_jump_pc);
                }

                // Patch the jump_if_z (or fused compare-jump) to skip just past the unconditional jump.
                const continue_pc = self.current_pc();
                switch (self.compiled.ops.items[jiz_pc]) {
                    .jump_if_z => |*j| j.target = continue_pc,
                    .i32_eq_jump_if_false => |*j| j.target = continue_pc,
                    .i32_ne_jump_if_false => |*j| j.target = continue_pc,
                    .i32_lt_s_jump_if_false => |*j| j.target = continue_pc,
                    .i32_lt_u_jump_if_false => |*j| j.target = continue_pc,
                    .i32_gt_s_jump_if_false => |*j| j.target = continue_pc,
                    .i32_gt_u_jump_if_false => |*j| j.target = continue_pc,
                    .i32_le_s_jump_if_false => |*j| j.target = continue_pc,
                    .i32_le_u_jump_if_false => |*j| j.target = continue_pc,
                    .i32_ge_s_jump_if_false => |*j| j.target = continue_pc,
                    .i32_ge_u_jump_if_false => |*j| j.target = continue_pc,
                    .i32_eqz_jump_if_false => |*j| j.target = continue_pc,
                    .i64_eq_jump_if_false => |*j| j.target = continue_pc,
                    .i64_ne_jump_if_false => |*j| j.target = continue_pc,
                    .i64_lt_s_jump_if_false => |*j| j.target = continue_pc,
                    .i64_lt_u_jump_if_false => |*j| j.target = continue_pc,
                    .i64_gt_s_jump_if_false => |*j| j.target = continue_pc,
                    .i64_gt_u_jump_if_false => |*j| j.target = continue_pc,
                    .i64_le_s_jump_if_false => |*j| j.target = continue_pc,
                    .i64_le_u_jump_if_false => |*j| j.target = continue_pc,
                    .i64_ge_s_jump_if_false => |*j| j.target = continue_pc,
                    .i64_ge_u_jump_if_false => |*j| j.target = continue_pc,
                    .i64_eqz_jump_if_false => |*j| j.target = continue_pc,
                    // Fused compare-imm-jump ops (Peephole G)
                    .i32_eq_imm_jump_if_false => |*j| j.target = continue_pc,
                    .i32_ne_imm_jump_if_false => |*j| j.target = continue_pc,
                    .i32_lt_s_imm_jump_if_false => |*j| j.target = continue_pc,
                    .i32_lt_u_imm_jump_if_false => |*j| j.target = continue_pc,
                    .i32_gt_s_imm_jump_if_false => |*j| j.target = continue_pc,
                    .i32_gt_u_imm_jump_if_false => |*j| j.target = continue_pc,
                    .i32_le_s_imm_jump_if_false => |*j| j.target = continue_pc,
                    .i32_le_u_imm_jump_if_false => |*j| j.target = continue_pc,
                    .i32_ge_s_imm_jump_if_false => |*j| j.target = continue_pc,
                    .i32_ge_u_imm_jump_if_false => |*j| j.target = continue_pc,
                    .i64_eq_imm_jump_if_false => |*j| j.target = continue_pc,
                    .i64_ne_imm_jump_if_false => |*j| j.target = continue_pc,
                    .i64_lt_s_imm_jump_if_false => |*j| j.target = continue_pc,
                    .i64_lt_u_imm_jump_if_false => |*j| j.target = continue_pc,
                    .i64_gt_s_imm_jump_if_false => |*j| j.target = continue_pc,
                    .i64_gt_u_imm_jump_if_false => |*j| j.target = continue_pc,
                    .i64_le_s_imm_jump_if_false => |*j| j.target = continue_pc,
                    .i64_le_u_imm_jump_if_false => |*j| j.target = continue_pc,
                    .i64_ge_s_imm_jump_if_false => |*j| j.target = continue_pc,
                    .i64_ge_u_imm_jump_if_false => |*j| j.target = continue_pc,
                    else => unreachable,
                }
            },

            .br_table => |inst| {
                // inst.targets slice: [depth_0, depth_1, ..., depth_n-1, default_depth]
                // Length is n_indexed + 1. Last entry is always the default.
                const index_slot = try self.pop_slot();
                const all_targets = inst.targets;
                const n_indexed: u32 = if (all_targets.len > 0) @intCast(all_targets.len - 1) else 0;
                const default_depth = if (all_targets.len > 0) all_targets[all_targets.len - 1] else 0;

                // Record where our entries start in br_table_targets.
                const targets_start: u32 = @intCast(self.compiled.br_table_targets.items.len);

                // Helper closure (inline): for a given depth, emit optional copy and record target.
                // For loop targets: target PC is known immediately (backward).
                // For block/if targets: append placeholder 0 and record a patch site.
                const reserve_and_patch = struct {
                    fn run(
                        l: *Lower,
                        depth: u32,
                    ) !void {
                        const f = try l.frame_at_depth(depth);
                        // Copy results/params into the frame's slots.
                        const target_slots = if (f.kind == .loop)
                            f.param_slots.items()
                        else
                            f.result_slots.items();
                        if (target_slots.len > 0) {
                            const stack_len = l.stack.len();
                            if (stack_len < target_slots.len) return error.StackUnderflow;
                            var ri: usize = target_slots.len;
                            while (ri > 0) {
                                ri -= 1;
                                const src = l.stack.slots.items[stack_len - target_slots.len + ri];
                                try l.emit(.{ .copy = .{ .dst = target_slots[ri], .src = src } });
                            }
                        }
                        if (f.kind == .loop) {
                            try l.compiled.br_table_targets.append(l.allocator, f.target_pc);
                        } else {
                            const tgt_idx: u32 = @intCast(l.compiled.br_table_targets.items.len);
                            try l.compiled.br_table_targets.append(l.allocator, 0); // placeholder
                            // Encode as a br_table_targets patch site (bit 31 set).
                            try l.add_patch_site(f, 0x8000_0000 | tgt_idx);
                        }
                    }
                }.run;

                // Process indexed arms.
                for (all_targets[0..n_indexed]) |depth| {
                    try reserve_and_patch(self, depth);
                }
                // Process default arm (at br_table_targets[targets_start + n_indexed]).
                try reserve_and_patch(self, default_depth);

                // Emit the jump_table op. Indexed targets: [targets_start .. targets_start + n_indexed],
                // Default at br_table_targets[targets_start + n_indexed].
                try self.emit(.{ .jump_table = .{
                    .index = index_slot,
                    .targets_start = targets_start,
                    .targets_len = n_indexed,
                } });

                // After br_table, the rest of the block is unreachable.
                // Restore the stack to the outermost frame's height.
                if (self.control_stack.items.len > 0) {
                    const outermost = self.control_stack.items[0];
                    self.stack.slots.shrinkRetainingCapacity(outermost.stack_height);
                } else {
                    self.stack.slots.shrinkRetainingCapacity(0);
                }
                self.is_unreachable = true;
            },

            // ── Locals & constants ────────────────────────────────────────────

            .local_get => |local| {
                try self.stack.push(self.allocator, self.local_to_slot(local));
            },
            .local_set => |local| {
                const src = try self.pop_slot();
                // ── Peephole D: i32_xxx + local_set → i32_xxx_to_local ────────
                if (!self.try_fuse_local_set(local, src)) {
                    try self.emit(.{ .local_set = .{ .local = local, .src = src } });
                }
            },
            .local_tee => |local| {
                const src = self.stack.peek() orelse return error.StackUnderflow;
                try self.emit(.{ .local_set = .{ .local = local, .src = src } });
            },
            // ── Globals ──────────────────────────────────────────────────────────
            .global_get => |global_idx| {
                const dst = self.alloc_slot();
                try self.emit(.{ .global_get = .{ .dst = dst, .global_idx = global_idx } });
                try self.stack.push(self.allocator, dst);
            },
            .global_set => |global_idx| {
                const src = try self.pop_slot();
                try self.emit(.{ .global_set = .{ .src = src, .global_idx = global_idx } });
            },
            .i32_const => |value| {
                const dst = self.alloc_slot();
                try self.emit(.{ .const_i32 = .{ .dst = dst, .value = value } });
                try self.stack.push(self.allocator, dst);
            },

            // ── Constants (i64, f32, f64) ──────────────────────────────────────

            .i64_const => |value| {
                const dst = self.alloc_slot();
                try self.emit(.{ .const_i64 = .{ .dst = dst, .value = value } });
                try self.stack.push(self.allocator, dst);
            },
            .f32_const => |value| {
                const dst = self.alloc_slot();
                try self.emit(.{ .const_f32 = .{ .dst = dst, .value = value } });
                try self.stack.push(self.allocator, dst);
            },
            .f64_const => |value| {
                const dst = self.alloc_slot();
                try self.emit(.{ .const_f64 = .{ .dst = dst, .value = value } });
                try self.stack.push(self.allocator, dst);
            },
            .v128_const => |value| {
                const dst = self.alloc_simd_slot();
                try self.emit(.{ .const_v128 = .{ .dst = dst, .value = value } });
                try self.stack.push(self.allocator, dst);
            },

            // ── i32 arithmetic operations (binary) ──────────────────────────────
            // Using helper function to reduce boilerplate

            .i32_add => try self.lower_binary_op("i32_add"),
            .i32_sub => try self.lower_binary_op("i32_sub"),
            .i32_mul => try self.lower_binary_op("i32_mul"),
            .i32_div_s => try self.lower_binary_op("i32_div_s"),
            .i32_div_u => try self.lower_binary_op("i32_div_u"),
            .i32_rem_s => try self.lower_binary_op("i32_rem_s"),
            .i32_rem_u => try self.lower_binary_op("i32_rem_u"),
            .i32_and => try self.lower_binary_op("i32_and"),
            .i32_or => try self.lower_binary_op("i32_or"),
            .i32_xor => try self.lower_binary_op("i32_xor"),
            .i32_shl => try self.lower_binary_op("i32_shl"),
            .i32_shr_s => try self.lower_binary_op("i32_shr_s"),
            .i32_shr_u => try self.lower_binary_op("i32_shr_u"),
            .i32_rotl => try self.lower_binary_op("i32_rotl"),
            .i32_rotr => try self.lower_binary_op("i32_rotr"),

            // ── i64 arithmetic operations (binary) ──────────────────────────────

            .i64_add => try self.lower_binary_op("i64_add"),
            .i64_sub => try self.lower_binary_op("i64_sub"),
            .i64_mul => try self.lower_binary_op("i64_mul"),
            .i64_div_s => try self.lower_binary_op("i64_div_s"),
            .i64_div_u => try self.lower_binary_op("i64_div_u"),
            .i64_rem_s => try self.lower_binary_op("i64_rem_s"),
            .i64_rem_u => try self.lower_binary_op("i64_rem_u"),
            .i64_and => try self.lower_binary_op("i64_and"),
            .i64_or => try self.lower_binary_op("i64_or"),
            .i64_xor => try self.lower_binary_op("i64_xor"),
            .i64_shl => try self.lower_binary_op("i64_shl"),
            .i64_shr_s => try self.lower_binary_op("i64_shr_s"),
            .i64_shr_u => try self.lower_binary_op("i64_shr_u"),
            .i64_rotl => try self.lower_binary_op("i64_rotl"),
            .i64_rotr => try self.lower_binary_op("i64_rotr"),

            // ── f32 arithmetic operations (binary) ──────────────────────────────

            .f32_add => try self.lower_binary_op("f32_add"),
            .f32_sub => try self.lower_binary_op("f32_sub"),
            .f32_mul => try self.lower_binary_op("f32_mul"),
            .f32_div => try self.lower_binary_op("f32_div"),
            .f32_min => try self.lower_binary_op("f32_min"),
            .f32_max => try self.lower_binary_op("f32_max"),
            .f32_copysign => try self.lower_binary_op("f32_copysign"),

            // ── f64 arithmetic operations (binary) ──────────────────────────────

            .f64_add => try self.lower_binary_op("f64_add"),
            .f64_sub => try self.lower_binary_op("f64_sub"),
            .f64_mul => try self.lower_binary_op("f64_mul"),
            .f64_div => try self.lower_binary_op("f64_div"),
            .f64_min => try self.lower_binary_op("f64_min"),
            .f64_max => try self.lower_binary_op("f64_max"),
            .f64_copysign => try self.lower_binary_op("f64_copysign"),

            // ── i32 unary operations ────────────────────────────────────────────

            .i32_clz => try self.lower_unary_op("i32_clz"),
            .i32_ctz => try self.lower_unary_op("i32_ctz"),
            .i32_popcnt => try self.lower_unary_op("i32_popcnt"),

            // ── i64 unary operations ────────────────────────────────────────────

            .i64_clz => try self.lower_unary_op("i64_clz"),
            .i64_ctz => try self.lower_unary_op("i64_ctz"),
            .i64_popcnt => try self.lower_unary_op("i64_popcnt"),

            // ── f32 unary operations ────────────────────────────────────────────

            .f32_abs => try self.lower_unary_op("f32_abs"),
            .f32_neg => try self.lower_unary_op("f32_neg"),
            .f32_ceil => try self.lower_unary_op("f32_ceil"),
            .f32_floor => try self.lower_unary_op("f32_floor"),
            .f32_trunc => try self.lower_unary_op("f32_trunc"),
            .f32_nearest => try self.lower_unary_op("f32_nearest"),
            .f32_sqrt => try self.lower_unary_op("f32_sqrt"),

            // ── f64 unary operations ────────────────────────────────────────────

            .f64_abs => try self.lower_unary_op("f64_abs"),
            .f64_neg => try self.lower_unary_op("f64_neg"),
            .f64_ceil => try self.lower_unary_op("f64_ceil"),
            .f64_floor => try self.lower_unary_op("f64_floor"),
            .f64_trunc => try self.lower_unary_op("f64_trunc"),
            .f64_nearest => try self.lower_unary_op("f64_nearest"),
            .f64_sqrt => try self.lower_unary_op("f64_sqrt"),

            // ── i32 comparison operations ────────────────────────────────────────

            .i32_eqz => try self.lower_unary_op("i32_eqz"), // special: unary, result is i32
            .i32_eq => try self.lower_compare_op("i32_eq"),
            .i32_ne => try self.lower_compare_op("i32_ne"),
            .i32_lt_s => try self.lower_compare_op("i32_lt_s"),
            .i32_lt_u => try self.lower_compare_op("i32_lt_u"),
            .i32_gt_s => try self.lower_compare_op("i32_gt_s"),
            .i32_gt_u => try self.lower_compare_op("i32_gt_u"),
            .i32_le_s => try self.lower_compare_op("i32_le_s"),
            .i32_le_u => try self.lower_compare_op("i32_le_u"),
            .i32_ge_s => try self.lower_compare_op("i32_ge_s"),
            .i32_ge_u => try self.lower_compare_op("i32_ge_u"),

            // ── i64 comparison operations ────────────────────────────────────────

            .i64_eqz => try self.lower_unary_op("i64_eqz"),
            .i64_eq => try self.lower_compare_op("i64_eq"),
            .i64_ne => try self.lower_compare_op("i64_ne"),
            .i64_lt_s => try self.lower_compare_op("i64_lt_s"),
            .i64_lt_u => try self.lower_compare_op("i64_lt_u"),
            .i64_gt_s => try self.lower_compare_op("i64_gt_s"),
            .i64_gt_u => try self.lower_compare_op("i64_gt_u"),
            .i64_le_s => try self.lower_compare_op("i64_le_s"),
            .i64_le_u => try self.lower_compare_op("i64_le_u"),
            .i64_ge_s => try self.lower_compare_op("i64_ge_s"),
            .i64_ge_u => try self.lower_compare_op("i64_ge_u"),

            // ── f32 comparison operations ────────────────────────────────────────

            .f32_eq => try self.lower_compare_op("f32_eq"),
            .f32_ne => try self.lower_compare_op("f32_ne"),
            .f32_lt => try self.lower_compare_op("f32_lt"),
            .f32_gt => try self.lower_compare_op("f32_gt"),
            .f32_le => try self.lower_compare_op("f32_le"),
            .f32_ge => try self.lower_compare_op("f32_ge"),

            // ── f64 comparison operations ────────────────────────────────────────

            .f64_eq => try self.lower_compare_op("f64_eq"),
            .f64_ne => try self.lower_compare_op("f64_ne"),
            .f64_lt => try self.lower_compare_op("f64_lt"),
            .f64_gt => try self.lower_compare_op("f64_gt"),
            .f64_le => try self.lower_compare_op("f64_le"),
            .f64_ge => try self.lower_compare_op("f64_ge"),

            // ── Numeric conversion and reinterpret operations ───────────────
            .i32_wrap_i64 => try self.lower_convert_op("i32_wrap_i64"),
            .i32_trunc_f32_s => try self.lower_convert_op("i32_trunc_f32_s"),
            .i32_trunc_f32_u => try self.lower_convert_op("i32_trunc_f32_u"),
            .i32_trunc_f64_s => try self.lower_convert_op("i32_trunc_f64_s"),
            .i32_trunc_f64_u => try self.lower_convert_op("i32_trunc_f64_u"),
            .i64_extend_i32_s => try self.lower_convert_op("i64_extend_i32_s"),
            .i64_extend_i32_u => try self.lower_convert_op("i64_extend_i32_u"),
            .i64_trunc_f32_s => try self.lower_convert_op("i64_trunc_f32_s"),
            .i64_trunc_f32_u => try self.lower_convert_op("i64_trunc_f32_u"),
            .i64_trunc_f64_s => try self.lower_convert_op("i64_trunc_f64_s"),
            .i64_trunc_f64_u => try self.lower_convert_op("i64_trunc_f64_u"),
            .i32_trunc_sat_f32_s => try self.lower_convert_op("i32_trunc_sat_f32_s"),
            .i32_trunc_sat_f32_u => try self.lower_convert_op("i32_trunc_sat_f32_u"),
            .i32_trunc_sat_f64_s => try self.lower_convert_op("i32_trunc_sat_f64_s"),
            .i32_trunc_sat_f64_u => try self.lower_convert_op("i32_trunc_sat_f64_u"),
            .i64_trunc_sat_f32_s => try self.lower_convert_op("i64_trunc_sat_f32_s"),
            .i64_trunc_sat_f32_u => try self.lower_convert_op("i64_trunc_sat_f32_u"),
            .i64_trunc_sat_f64_s => try self.lower_convert_op("i64_trunc_sat_f64_s"),
            .i64_trunc_sat_f64_u => try self.lower_convert_op("i64_trunc_sat_f64_u"),
            .f32_convert_i32_s => try self.lower_convert_op("f32_convert_i32_s"),
            .f32_convert_i32_u => try self.lower_convert_op("f32_convert_i32_u"),
            .f32_convert_i64_s => try self.lower_convert_op("f32_convert_i64_s"),
            .f32_convert_i64_u => try self.lower_convert_op("f32_convert_i64_u"),
            .f32_demote_f64 => try self.lower_convert_op("f32_demote_f64"),
            .f64_convert_i32_s => try self.lower_convert_op("f64_convert_i32_s"),
            .f64_convert_i32_u => try self.lower_convert_op("f64_convert_i32_u"),
            .f64_convert_i64_s => try self.lower_convert_op("f64_convert_i64_s"),
            .f64_convert_i64_u => try self.lower_convert_op("f64_convert_i64_u"),
            .f64_promote_f32 => try self.lower_convert_op("f64_promote_f32"),
            .i32_reinterpret_f32 => try self.lower_convert_op("i32_reinterpret_f32"),
            .i64_reinterpret_f64 => try self.lower_convert_op("i64_reinterpret_f64"),
            .f32_reinterpret_i32 => try self.lower_convert_op("f32_reinterpret_i32"),
            .f64_reinterpret_i64 => try self.lower_convert_op("f64_reinterpret_i64"),

            // ── Sign-extension operations ────────────────────────────────────
            .i32_extend8_s => try self.lower_convert_op("i32_extend8_s"),
            .i32_extend16_s => try self.lower_convert_op("i32_extend16_s"),
            .i64_extend8_s => try self.lower_convert_op("i64_extend8_s"),
            .i64_extend16_s => try self.lower_convert_op("i64_extend16_s"),
            .i64_extend32_s => try self.lower_convert_op("i64_extend32_s"),

            .simd_unary => |opcode| try self.lower_simd_unary(opcode),
            .simd_binary => |opcode| try self.lower_simd_binary(opcode),
            .simd_ternary => |opcode| try self.lower_simd_ternary(opcode),
            .simd_compare => |opcode| {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_simd_slot();
                try self.emit(.{ .simd_compare = .{ .dst = dst, .opcode = opcode, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },
            .simd_shift_scalar => |opcode| {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_simd_slot();
                try self.emit(.{ .simd_shift_scalar = .{ .dst = dst, .opcode = opcode, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },
            .simd_extract_lane => |inst| {
                const src = try self.pop_slot();
                const dst = self.alloc_slot(); // scalar result
                try self.emit(.{ .simd_extract_lane = .{
                    .dst = dst,
                    .opcode = inst.opcode,
                    .src = src,
                    .lane = inst.lane,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .simd_replace_lane => |inst| {
                const src_lane = try self.pop_slot();
                const src_vec = try self.pop_slot();
                const dst = self.alloc_simd_slot();
                try self.emit(.{ .simd_replace_lane = .{
                    .dst = dst,
                    .opcode = inst.opcode,
                    .src_vec = src_vec,
                    .src_lane = src_lane,
                    .lane = inst.lane,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .simd_shuffle => |lanes| {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_simd_slot();
                try self.emit(.{ .simd_shuffle = .{ .dst = dst, .lhs = lhs, .rhs = rhs, .lanes = lanes } });
                try self.stack.push(self.allocator, dst);
            },
            .simd_load => |inst| {
                const src_vec: ?Slot = if (simd.isLaneLoadOpcode(inst.opcode)) try self.pop_slot() else null;
                const addr = try self.pop_slot();
                const dst = self.alloc_simd_slot();
                try self.emit(.{ .simd_load = .{
                    .dst = dst,
                    .opcode = inst.opcode,
                    .addr = addr,
                    .offset = inst.offset,
                    .lane = inst.lane,
                    .src_vec = src_vec,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .simd_store => |inst| {
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                try self.emit(.{ .simd_store = .{
                    .opcode = inst.opcode,
                    .addr = addr,
                    .src = src,
                    .offset = inst.offset,
                    .lane = inst.lane,
                } });
            },

            .ret => {
                const value = self.stack.pop();
                try self.emit(.{ .ret = .{ .value = value } });
                self.is_unreachable = true;
            },

            // ── function call ──────────────────────────────────────────────────────────

            .call => |inst| {
                // Pop n_params argument slots from the value stack in reverse order.
                // The top of the stack is the last argument, so we need to reverse them to restore the correct order.
                const args_start: u32 = @intCast(self.compiled.call_args.items.len);
                var i: u32 = 0;
                while (i < inst.n_params) : (i += 1) {
                    const slot = try self.pop_slot();
                    try self.compiled.call_args.append(self.allocator, slot);
                }
                // Reverse to match Wasm spec order (first pushed is first",)
                const args = self.compiled.call_args.items[args_start..];
                std.mem.reverse(Slot, args);

                const dst: ?Slot = if (inst.has_result) self.alloc_slot() else null;

                try self.emit(.{ .call = .{
                    .dst = dst,
                    .func_idx = inst.func_idx,
                    .args_start = args_start,
                    .args_len = inst.n_params,
                } });

                // If the call produces a result, push the result slot.
                if (dst) |s| try self.stack.push(self.allocator, s);
            },

            // ── indirect function call ─────────────────────────────────────────────────

            .call_indirect => |inst| {
                // Stack: [..., arg0, arg1, ..., argN-1, index]
                // Pop the runtime table index (TOS), then pop n_params arguments.
                const index = try self.pop_slot();

                const args_start: u32 = @intCast(self.compiled.call_args.items.len);
                var i: u32 = 0;
                while (i < inst.n_params) : (i += 1) {
                    const slot = try self.pop_slot();
                    try self.compiled.call_args.append(self.allocator, slot);
                }
                // Reverse to match Wasm spec order (first pushed is first",)
                const args = self.compiled.call_args.items[args_start..];
                std.mem.reverse(Slot, args);

                const dst: ?Slot = if (inst.has_result) self.alloc_slot() else null;

                try self.emit(.{ .call_indirect = .{
                    .dst = dst,
                    .index = index,
                    .type_index = inst.type_index,
                    .table_index = inst.table_index,
                    .args_start = args_start,
                    .args_len = inst.n_params,
                } });

                // If the call produces a result, push the result slot.
                if (dst) |s| try self.stack.push(self.allocator, s);
            },

            // ── tail call ─────────────────────────────────────────────────────────

            .return_call => |inst| {
                // Pop n_params argument slots from the value stack in reverse order.
                const args_start: u32 = @intCast(self.compiled.call_args.items.len);
                var i: u32 = 0;
                while (i < inst.n_params) : (i += 1) {
                    const slot = try self.pop_slot();
                    try self.compiled.call_args.append(self.allocator, slot);
                }
                // Reverse to match Wasm spec order.
                const args = self.compiled.call_args.items[args_start..];
                std.mem.reverse(Slot, args);

                try self.emit(.{ .return_call = .{
                    .func_idx = inst.func_idx,
                    .args_start = args_start,
                    .args_len = inst.n_params,
                } });

                // Tail call never returns; clear the stack.
                self.stack.slots.shrinkRetainingCapacity(0);
                self.is_unreachable = true;
            },

            // ── tail call indirect ─────────────────────────────────────────────────

            .return_call_indirect => |inst| {
                // Stack: [..., arg0, arg1, ..., argN-1, index]
                // Pop the runtime table index (TOS), then pop n_params arguments.
                const index = try self.pop_slot();

                const args_start: u32 = @intCast(self.compiled.call_args.items.len);
                var i: u32 = 0;
                while (i < inst.n_params) : (i += 1) {
                    const slot = try self.pop_slot();
                    try self.compiled.call_args.append(self.allocator, slot);
                }
                // Reverse to match Wasm spec order.
                const args = self.compiled.call_args.items[args_start..];
                std.mem.reverse(Slot, args);

                try self.emit(.{ .return_call_indirect = .{
                    .index = index,
                    .type_index = inst.type_index,
                    .table_index = inst.table_index,
                    .args_start = args_start,
                    .args_len = inst.n_params,
                } });

                // Tail call never returns; clear the stack.
                self.stack.slots.shrinkRetainingCapacity(0);
                self.is_unreachable = true;
            },

            // ── Memory load ──────────────────────────────────────────────────────────
            // For all load op: pop the address slot, allocate a result slot, emit the corresponding load Op, push the result slot.

            .i32_load => |inst| {
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_load = .{ .dst = dst, .addr = addr, .offset = inst.offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_load8_s => |inst| {
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_load8_s = .{ .dst = dst, .addr = addr, .offset = inst.offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_load8_u => |inst| {
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_load8_u = .{ .dst = dst, .addr = addr, .offset = inst.offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_load16_s => |inst| {
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_load16_s = .{ .dst = dst, .addr = addr, .offset = inst.offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_load16_u => |inst| {
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_load16_u = .{ .dst = dst, .addr = addr, .offset = inst.offset } });
                try self.stack.push(self.allocator, dst);
            },

            // ── i64 load instructions ─────────────────────────────────────────────

            .i64_load => |inst| {
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i64_load = .{ .dst = dst, .addr = addr, .offset = inst.offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i64_load8_s => |inst| {
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i64_load8_s = .{ .dst = dst, .addr = addr, .offset = inst.offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i64_load8_u => |inst| {
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i64_load8_u = .{ .dst = dst, .addr = addr, .offset = inst.offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i64_load16_s => |inst| {
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i64_load16_s = .{ .dst = dst, .addr = addr, .offset = inst.offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i64_load16_u => |inst| {
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i64_load16_u = .{ .dst = dst, .addr = addr, .offset = inst.offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i64_load32_s => |inst| {
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i64_load32_s = .{ .dst = dst, .addr = addr, .offset = inst.offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i64_load32_u => |inst| {
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i64_load32_u = .{ .dst = dst, .addr = addr, .offset = inst.offset } });
                try self.stack.push(self.allocator, dst);
            },

            // ── f32/f64 load instructions ─────────────────────────────────────────

            .f32_load => |inst| {
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .f32_load = .{ .dst = dst, .addr = addr, .offset = inst.offset } });
                try self.stack.push(self.allocator, dst);
            },
            .f64_load => |inst| {
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .f64_load = .{ .dst = dst, .addr = addr, .offset = inst.offset } });
                try self.stack.push(self.allocator, dst);
            },

            // ── i32 store instructions ─────────────────────────────────────────────
            // For all store op: Wasm stack top is value, below is addr (push addr first, then val).
            // According to Wasm spec pop order: pop val (top), then pop addr.

            .i32_store => |inst| {
                const src = try self.pop_slot(); // value
                const addr = try self.pop_slot(); // base address
                try self.emit(.{ .i32_store = .{ .addr = addr, .src = src, .offset = inst.offset } });
            },
            .i32_store8 => |inst| {
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                try self.emit(.{ .i32_store8 = .{ .addr = addr, .src = src, .offset = inst.offset } });
            },
            .i32_store16 => |inst| {
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                try self.emit(.{ .i32_store16 = .{ .addr = addr, .src = src, .offset = inst.offset } });
            },

            // ── i64 store instructions ─────────────────────────────────────────────

            .i64_store => |inst| {
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                try self.emit(.{ .i64_store = .{ .addr = addr, .src = src, .offset = inst.offset } });
            },
            .i64_store8 => |inst| {
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                try self.emit(.{ .i64_store8 = .{ .addr = addr, .src = src, .offset = inst.offset } });
            },
            .i64_store16 => |inst| {
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                try self.emit(.{ .i64_store16 = .{ .addr = addr, .src = src, .offset = inst.offset } });
            },
            .i64_store32 => |inst| {
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                try self.emit(.{ .i64_store32 = .{ .addr = addr, .src = src, .offset = inst.offset } });
            },

            // ── f32/f64 store instructions ─────────────────────────────────────────

            .f32_store => |inst| {
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                try self.emit(.{ .f32_store = .{ .addr = addr, .src = src, .offset = inst.offset } });
            },
            .f64_store => |inst| {
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                try self.emit(.{ .f64_store = .{ .addr = addr, .src = src, .offset = inst.offset } });
            },

            // ── Bulk memory ─────────────────────────────────────────────────────────
            // memory.init: [dst_addr, src_offset, len] -> []  (pop len, then src_offset, then dst_addr",)
            .memory_init => |segment_idx| {
                const len = try self.pop_slot();
                const src_offset = try self.pop_slot();
                const dst_addr = try self.pop_slot();
                try self.emit(.{ .memory_init = .{ .segment_idx = segment_idx, .dst_addr = dst_addr, .src_offset = src_offset, .len = len } });
            },
            // data.drop: no stack operands
            .data_drop => |segment_idx| {
                try self.emit(.{ .data_drop = .{ .segment_idx = segment_idx } });
            },
            // memory.copy: [dst_addr, src_addr, len] -> []  (pop len, then src_addr, then dst_addr",)
            .memory_copy => {
                const len = try self.pop_slot();
                const src_addr = try self.pop_slot();
                const dst_addr = try self.pop_slot();
                try self.emit(.{ .memory_copy = .{ .dst_addr = dst_addr, .src_addr = src_addr, .len = len } });
            },
            // memory.fill: [dst_addr, value, len] -> []  (pop len, then value, then dst_addr",)
            .memory_fill => {
                const len = try self.pop_slot();
                const value = try self.pop_slot();
                const dst_addr = try self.pop_slot();
                try self.emit(.{ .memory_fill = .{ .dst_addr = dst_addr, .value = value, .len = len } });
            },

            // memory.size: [] -> [i32 page count]
            .memory_size => {
                const dst = self.alloc_slot();
                try self.stack.push(self.allocator, dst);
                try self.emit(.{ .memory_size = .{ .dst = dst } });
            },

            // memory.grow: [delta: i32] -> [i32 old_size or -1]
            .memory_grow => {
                const delta = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.stack.push(self.allocator, dst);
                try self.emit(.{ .memory_grow = .{ .dst = dst, .delta = delta } });
            },

            // ── Atomic instructions ───────────────────────────────────────────────
            // atomic.fence: no operands, no result
            .atomic_fence => {
                try self.emit(.atomic_fence);
            },
            // atomic_load: [addr] -> [value]
            .atomic_load => |inst| {
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.stack.push(self.allocator, dst);
                try self.emit(.{ .atomic_load = .{
                    .dst = dst,
                    .addr = addr,
                    .offset = inst.offset,
                    .width = inst.width,
                    .ty = inst.ty,
                } });
            },
            // atomic_store: [addr, src] -> []  (src pushed last, so pop src first)
            .atomic_store => |inst| {
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                try self.emit(.{ .atomic_store = .{
                    .addr = addr,
                    .src = src,
                    .offset = inst.offset,
                    .width = inst.width,
                    .ty = inst.ty,
                } });
            },
            // atomic_rmw: [addr, src] -> [old_value]
            .atomic_rmw => |inst| {
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.stack.push(self.allocator, dst);
                try self.emit(.{ .atomic_rmw = .{
                    .dst = dst,
                    .addr = addr,
                    .src = src,
                    .offset = inst.offset,
                    .op = inst.op,
                    .width = inst.width,
                    .ty = inst.ty,
                } });
            },
            // atomic_cmpxchg: [addr, expected, replacement] -> [old_value]
            .atomic_cmpxchg => |inst| {
                const replacement = try self.pop_slot();
                const expected = try self.pop_slot();
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.stack.push(self.allocator, dst);
                try self.emit(.{ .atomic_cmpxchg = .{
                    .dst = dst,
                    .addr = addr,
                    .expected = expected,
                    .replacement = replacement,
                    .offset = inst.offset,
                    .width = inst.width,
                    .ty = inst.ty,
                } });
            },
            // atomic_notify: [addr, count] -> [woken]
            .atomic_notify => |inst| {
                const count = try self.pop_slot();
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.stack.push(self.allocator, dst);
                try self.emit(.{ .atomic_notify = .{
                    .dst = dst,
                    .addr = addr,
                    .count = count,
                    .offset = inst.offset,
                } });
            },
            // atomic_wait32: [addr, expected_i32, timeout_i64] -> [result_i32]
            .atomic_wait32 => |inst| {
                const timeout = try self.pop_slot();
                const expected = try self.pop_slot();
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.stack.push(self.allocator, dst);
                try self.emit(.{ .atomic_wait32 = .{
                    .dst = dst,
                    .addr = addr,
                    .expected = expected,
                    .timeout = timeout,
                    .offset = inst.offset,
                } });
            },
            // atomic_wait64: [addr, expected_i64, timeout_i64] -> [result_i32]
            .atomic_wait64 => |inst| {
                const timeout = try self.pop_slot();
                const expected = try self.pop_slot();
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.stack.push(self.allocator, dst);
                try self.emit(.{ .atomic_wait64 = .{
                    .dst = dst,
                    .addr = addr,
                    .expected = expected,
                    .timeout = timeout,
                    .offset = inst.offset,
                } });
            },

            // ── select ───────────────────────────────────────────────────────────
            // Stack order: val1 pushed first, val2 second, cond last (TOS).
            // Pop cond, then val2, then val1.

            .select, .select_with_type => {
                const cond = try self.pop_slot();
                const val2 = try self.pop_slot();
                const val1 = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .select = .{ .dst = dst, .val1 = val1, .val2 = val2, .cond = cond } });
                try self.stack.push(self.allocator, dst);
            },

            // ── Reference type instructions ──────────────────────────────────────
            // ref.null: push null reference (low64 = 0, unified for all ref types).
            .ref_null => {
                const dst = self.alloc_slot();
                try self.emit(.{ .const_ref_null = .{ .dst = dst } });
                try self.stack.push(self.allocator, dst);
            },

            // ref.is_null: pop reference, push i32 result (1 if null, 0 otherwise).
            .ref_is_null => {
                const src = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .ref_is_null = .{ .dst = dst, .src = src } });
                try self.stack.push(self.allocator, dst);
            },

            // ref.func: push funcref for func_idx.
            .ref_func => |func_idx| {
                const dst = self.alloc_slot();
                try self.emit(.{ .ref_func = .{ .dst = dst, .func_idx = func_idx } });
                try self.stack.push(self.allocator, dst);
            },

            // ref.eq: pop two references, push i32 result (1 if equal, 0 otherwise).
            .ref_eq => {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .ref_eq = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },

            // ── Table instructions ─────────────────────────────────────────────────
            // table.get: pop index, push funcref from table[table_index][index].
            .table_get => |table_index| {
                const index = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .table_get = .{ .dst = dst, .table_index = table_index, .index = index } });
                try self.stack.push(self.allocator, dst);
            },

            // table.set: pop value (funcref), pop index (i32).
            .table_set => |table_index| {
                const value = try self.pop_slot();
                const index = try self.pop_slot();
                try self.emit(.{ .table_set = .{ .table_index = table_index, .index = index, .value = value } });
            },

            // table.size: push i32 size of table.
            .table_size => |table_index| {
                const dst = self.alloc_slot();
                try self.emit(.{ .table_size = .{ .dst = dst, .table_index = table_index } });
                try self.stack.push(self.allocator, dst);
            },

            // table.grow: [init, delta] -> [old_size].  Stack: init pushed first, then delta (TOS).
            .table_grow => |table_index| {
                const delta = try self.pop_slot();
                const init_slot = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .table_grow = .{ .dst = dst, .table_index = table_index, .init = init_slot, .delta = delta } });
                try self.stack.push(self.allocator, dst);
            },

            // table.fill: [dst_idx, value, len] -> [].  Stack: dst_idx pushed first, then value, then len (TOS).
            .table_fill => |table_index| {
                const len = try self.pop_slot();
                const value = try self.pop_slot();
                const dst_idx = try self.pop_slot();
                try self.emit(.{ .table_fill = .{ .table_index = table_index, .dst_idx = dst_idx, .value = value, .len = len } });
            },

            // table.copy: [dst_idx, src_idx, len] -> [].  Stack: dst_idx pushed first, then src_idx, then len (TOS).
            .table_copy => |inst| {
                const len = try self.pop_slot();
                const src_idx = try self.pop_slot();
                const dst_idx = try self.pop_slot();
                try self.emit(.{ .table_copy = .{ .dst_table = inst.dst_table, .src_table = inst.src_table, .dst_idx = dst_idx, .src_idx = src_idx, .len = len } });
            },

            // table.init: [dst_idx, src_offset, len] -> [].  Stack: dst_idx pushed first, then src_offset, then len (TOS).
            .table_init => |inst| {
                const len = try self.pop_slot();
                const src_offset = try self.pop_slot();
                const dst_idx = try self.pop_slot();
                try self.emit(.{ .table_init = .{ .table_index = inst.table_index, .segment_idx = inst.segment_idx, .dst_idx = dst_idx, .src_offset = src_offset, .len = len } });
            },

            // elem.drop: no stack operands.
            .elem_drop => |segment_idx| {
                try self.emit(.{ .elem_drop = .{ .segment_idx = segment_idx } });
            },

            // ── GC Struct instructions ────────────────────────────────────────────────
            .struct_new => |inst| {
                // Pop n_fields values from stack (reverse order: last field = TOS)
                const args_start: u32 = @intCast(self.compiled.call_args.items.len);
                var i: u32 = 0;
                while (i < inst.n_fields) : (i += 1) {
                    const slot = try self.pop_slot();
                    try self.compiled.call_args.append(self.allocator, slot);
                }
                // Reverse to match Wasm field order
                const args = self.compiled.call_args.items[args_start..];
                std.mem.reverse(Slot, args);

                const dst = self.alloc_slot();
                try self.emit(.{ .struct_new = .{
                    .dst = dst,
                    .type_idx = inst.type_idx,
                    .args_start = args_start,
                    .args_len = inst.n_fields,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .struct_new_default => |type_idx| {
                const dst = self.alloc_slot();
                try self.emit(.{ .struct_new_default = .{
                    .dst = dst,
                    .type_idx = type_idx,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .struct_get => |inst| {
                const ref = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .struct_get = .{
                    .dst = dst,
                    .ref = ref,
                    .type_idx = inst.type_idx,
                    .field_idx = inst.field_idx,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .struct_get_s => |inst| {
                const ref = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .struct_get_s = .{
                    .dst = dst,
                    .ref = ref,
                    .type_idx = inst.type_idx,
                    .field_idx = inst.field_idx,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .struct_get_u => |inst| {
                const ref = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .struct_get_u = .{
                    .dst = dst,
                    .ref = ref,
                    .type_idx = inst.type_idx,
                    .field_idx = inst.field_idx,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .struct_set => |inst| {
                const value = try self.pop_slot();
                const ref = try self.pop_slot();
                try self.emit(.{ .struct_set = .{
                    .ref = ref,
                    .value = value,
                    .type_idx = inst.type_idx,
                    .field_idx = inst.field_idx,
                } });
            },

            // ── GC Array instructions ──────────────────────────────────────────────────
            .array_new => |type_idx| {
                // Stack: [..., init_val, len] (len = TOS)
                const len = try self.pop_slot();
                const init_val = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .array_new = .{
                    .dst = dst,
                    .init = init_val,
                    .len = len,
                    .type_idx = type_idx,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .array_new_default => |type_idx| {
                const len = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .array_new_default = .{
                    .dst = dst,
                    .len = len,
                    .type_idx = type_idx,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .array_new_fixed => |inst| {
                // Pop n elements from stack (reverse order)
                const args_start: u32 = @intCast(self.compiled.call_args.items.len);
                var i: u32 = 0;
                while (i < inst.n) : (i += 1) {
                    const slot = try self.pop_slot();
                    try self.compiled.call_args.append(self.allocator, slot);
                }
                const args = self.compiled.call_args.items[args_start..];
                std.mem.reverse(Slot, args);

                const dst = self.alloc_slot();
                try self.emit(.{ .array_new_fixed = .{
                    .dst = dst,
                    .type_idx = inst.type_idx,
                    .args_start = args_start,
                    .args_len = inst.n,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .array_new_data => |inst| {
                // Stack: [..., offset, len] (len = TOS)
                const len = try self.pop_slot();
                const offset = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .array_new_data = .{
                    .dst = dst,
                    .offset = offset,
                    .len = len,
                    .type_idx = inst.type_idx,
                    .data_idx = inst.data_idx,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .array_new_elem => |inst| {
                // Stack: [..., offset, len] (len = TOS)
                const len = try self.pop_slot();
                const offset = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .array_new_elem = .{
                    .dst = dst,
                    .offset = offset,
                    .len = len,
                    .type_idx = inst.type_idx,
                    .elem_idx = inst.elem_idx,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .array_get => |type_idx| {
                // Stack: [..., ref, index] (index = TOS)
                const index = try self.pop_slot();
                const ref = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .array_get = .{
                    .dst = dst,
                    .ref = ref,
                    .index = index,
                    .type_idx = type_idx,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .array_get_s => |type_idx| {
                const index = try self.pop_slot();
                const ref = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .array_get_s = .{
                    .dst = dst,
                    .ref = ref,
                    .index = index,
                    .type_idx = type_idx,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .array_get_u => |type_idx| {
                const index = try self.pop_slot();
                const ref = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .array_get_u = .{
                    .dst = dst,
                    .ref = ref,
                    .index = index,
                    .type_idx = type_idx,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .array_set => |type_idx| {
                // Stack: [..., ref, index, value] (value = TOS)
                const value = try self.pop_slot();
                const index = try self.pop_slot();
                const ref = try self.pop_slot();
                try self.emit(.{ .array_set = .{
                    .ref = ref,
                    .index = index,
                    .value = value,
                    .type_idx = type_idx,
                } });
            },
            .array_len => {
                const ref = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .array_len = .{
                    .dst = dst,
                    .ref = ref,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .array_fill => |type_idx| {
                // Stack: [..., ref, offset, value, n] (n = TOS)
                const n = try self.pop_slot();
                const value = try self.pop_slot();
                const offset = try self.pop_slot();
                const ref = try self.pop_slot();
                try self.emit(.{ .array_fill = .{
                    .ref = ref,
                    .offset = offset,
                    .value = value,
                    .n = n,
                    .type_idx = type_idx,
                } });
            },
            .array_copy => |inst| {
                // Stack: [..., dst_ref, dst_offset, src_ref, src_offset, n] (n = TOS)
                const n = try self.pop_slot();
                const src_offset = try self.pop_slot();
                const src_ref = try self.pop_slot();
                const dst_offset = try self.pop_slot();
                const dst_ref = try self.pop_slot();
                try self.emit(.{ .array_copy = .{
                    .dst_ref = dst_ref,
                    .dst_offset = dst_offset,
                    .src_ref = src_ref,
                    .src_offset = src_offset,
                    .n = n,
                    .dst_type_idx = inst.dst_type_idx,
                    .src_type_idx = inst.src_type_idx,
                } });
            },
            .array_init_data => |inst| {
                // Stack: [..., ref, d, s, n] (n = TOS)
                const n = try self.pop_slot();
                const s = try self.pop_slot();
                const d = try self.pop_slot();
                const ref = try self.pop_slot();
                try self.emit(.{ .array_init_data = .{
                    .ref = ref,
                    .d = d,
                    .s = s,
                    .n = n,
                    .type_idx = inst.type_idx,
                    .data_idx = inst.data_idx,
                } });
            },
            .array_init_elem => |inst| {
                const n = try self.pop_slot();
                const s = try self.pop_slot();
                const d = try self.pop_slot();
                const ref = try self.pop_slot();
                try self.emit(.{ .array_init_elem = .{
                    .ref = ref,
                    .d = d,
                    .s = s,
                    .n = n,
                    .type_idx = inst.type_idx,
                    .elem_idx = inst.elem_idx,
                } });
            },

            // ── GC i31 instructions ────────────────────────────────────────────────────
            .ref_i31 => {
                const value = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .ref_i31 = .{
                    .dst = dst,
                    .value = value,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .i31_get_s => {
                const ref = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i31_get_s = .{
                    .dst = dst,
                    .ref = ref,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .i31_get_u => {
                const ref = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i31_get_u = .{
                    .dst = dst,
                    .ref = ref,
                } });
                try self.stack.push(self.allocator, dst);
            },

            // ── GC Type Test/Cast instructions ─────────────────────────────────────────
            .ref_test => |ref_test_op| {
                const ref = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .ref_test = .{
                    .dst = dst,
                    .ref = ref,
                    .type_idx = ref_test_op.type_idx,
                    .nullable = ref_test_op.nullable,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .ref_cast => |ref_cast_op| {
                const ref = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .ref_cast = .{
                    .dst = dst,
                    .ref = ref,
                    .type_idx = ref_cast_op.type_idx,
                    .nullable = ref_cast_op.nullable,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .ref_as_non_null => {
                const ref = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .ref_as_non_null = .{
                    .dst = dst,
                    .ref = ref,
                } });
                try self.stack.push(self.allocator, dst);
            },

            // ── GC Control Flow instructions ────────────────────────────────────────────
            .br_on_null => |br_depth| {
                // br_on_null: if ref is null, branch; else continue with ref on stack
                const frame = try self.frame_at_depth(br_depth);
                const ref = try self.pop_slot();

                // Emit br_on_null op with placeholder target (will be patched)
                const op_pc = self.current_pc();
                try self.emit(.{
                    .br_on_null = .{
                        .ref = ref,
                        .target = 0, // placeholder
                    },
                });

                // Patch logic depends on frame type
                if (frame.kind == .loop) {
                    // Backward jump: target is known
                    switch (self.compiled.ops.items[op_pc]) {
                        .br_on_null => |*j| j.target = frame.target_pc,
                        else => unreachable,
                    }
                } else {
                    // Forward jump: need to patch at end
                    try self.add_patch_site(frame, op_pc);
                }

                // For non-null case, push ref back (stack manipulation for continuation)
                // But wait - the ref was already popped. We need to push it back.
                // Actually, br_on_null semantics: ref is consumed only if branch taken.
                // If not taken, ref remains on stack.
                // So we push it back here for the continuation path.
                try self.stack.push(self.allocator, ref);
            },
            .br_on_non_null => |br_depth| {
                // br_on_non_null: if ref is non-null, branch (with ref on stack); else continue
                const frame = try self.frame_at_depth(br_depth);
                const ref = try self.pop_slot();

                const op_pc = self.current_pc();
                try self.emit(.{
                    .br_on_non_null = .{
                        .ref = ref,
                        .target = 0, // placeholder
                    },
                });

                if (frame.kind == .loop) {
                    switch (self.compiled.ops.items[op_pc]) {
                        .br_on_non_null => |*j| j.target = frame.target_pc,
                        else => unreachable,
                    }
                } else {
                    try self.add_patch_site(frame, op_pc);
                }

                // For null case, push ref back (actually null refs don't continue)
                // Wait: br_on_non_null: if null, continue without ref
                // if non-null, branch with ref on stack
                // So for the null case (continuation), we don't push ref back
            },
            .br_on_cast => |inst| {
                const frame = try self.frame_at_depth(inst.br_depth);
                const ref = try self.pop_slot();

                const op_pc = self.current_pc();
                try self.emit(.{ .br_on_cast = .{
                    .ref = ref,
                    .target = 0,
                    .from_type_idx = inst.from_type_idx,
                    .to_type_idx = inst.to_type_idx,
                    .to_nullable = inst.to_nullable,
                } });

                if (frame.kind == .loop) {
                    switch (self.compiled.ops.items[op_pc]) {
                        .br_on_cast => |*j| j.target = frame.target_pc,
                        else => unreachable,
                    }
                } else {
                    try self.add_patch_site(frame, op_pc);
                }

                // Push ref back for non-taken path
                try self.stack.push(self.allocator, ref);
            },
            .br_on_cast_fail => |inst| {
                const frame = try self.frame_at_depth(inst.br_depth);
                const ref = try self.pop_slot();

                const op_pc = self.current_pc();
                try self.emit(.{ .br_on_cast_fail = .{
                    .ref = ref,
                    .target = 0,
                    .from_type_idx = inst.from_type_idx,
                    .to_type_idx = inst.to_type_idx,
                    .to_nullable = inst.to_nullable,
                } });

                if (frame.kind == .loop) {
                    switch (self.compiled.ops.items[op_pc]) {
                        .br_on_cast_fail => |*j| j.target = frame.target_pc,
                        else => unreachable,
                    }
                } else {
                    try self.add_patch_site(frame, op_pc);
                }

                // Push ref back for taken path (cast succeeded)
                try self.stack.push(self.allocator, ref);
            },

            // ── GC Call instructions ───────────────────────────────────────────────────
            // Note: n_params and has_result will be filled by module.zig
            .call_ref => |inst| {
                // Stack: [..., arg0, arg1, ..., argN-1, funcref] (funcref = TOS)
                const ref = try self.pop_slot();

                const args_start: u32 = @intCast(self.compiled.call_args.items.len);
                var i: u32 = 0;
                while (i < inst.n_params) : (i += 1) {
                    const slot = try self.pop_slot();
                    try self.compiled.call_args.append(self.allocator, slot);
                }
                const args = self.compiled.call_args.items[args_start..];
                std.mem.reverse(Slot, args);

                const dst: ?Slot = if (inst.has_result) self.alloc_slot() else null;

                try self.emit(.{ .call_ref = .{
                    .dst = dst,
                    .ref = ref,
                    .type_idx = inst.type_idx,
                    .args_start = args_start,
                    .args_len = inst.n_params,
                } });

                if (dst) |s| try self.stack.push(self.allocator, s);
            },
            .return_call_ref => |inst| {
                const ref = try self.pop_slot();

                const args_start: u32 = @intCast(self.compiled.call_args.items.len);
                var i: u32 = 0;
                while (i < inst.n_params) : (i += 1) {
                    const slot = try self.pop_slot();
                    try self.compiled.call_args.append(self.allocator, slot);
                }
                const args = self.compiled.call_args.items[args_start..];
                std.mem.reverse(Slot, args);

                try self.emit(.{ .return_call_ref = .{
                    .ref = ref,
                    .type_idx = inst.type_idx,
                    .args_start = args_start,
                    .args_len = inst.n_params,
                } });

                // Tail call never returns; clear the stack.
                self.stack.slots.shrinkRetainingCapacity(0);
                self.is_unreachable = true;
            },

            .any_convert_extern => {
                const ref = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .any_convert_extern = .{
                    .dst = dst,
                    .ref = ref,
                } });
                try self.stack.push(self.allocator, dst);
            },
            .extern_convert_any => {
                const ref = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .extern_convert_any = .{
                    .dst = dst,
                    .ref = ref,
                } });
                try self.stack.push(self.allocator, dst);
            },

            // ── Exception Handling ────────────────────────────────────────────────────

            // throw: pop n_args values from the stack (last pushed == first arg in reverse),
            // allocate exception args in call_args pool, emit throw.
            // n_args must have been filled in by module.zig before lowerOp is called.
            .throw => |inst| {
                const args_start: u32 = @intCast(self.compiled.call_args.items.len);
                var i: u32 = 0;
                while (i < inst.n_args) : (i += 1) {
                    const slot = try self.pop_slot();
                    try self.compiled.call_args.append(self.allocator, slot);
                }
                // Reverse so that the first argument comes first in call_args
                const args = self.compiled.call_args.items[args_start..];
                std.mem.reverse(Slot, args);

                try self.emit(.{ .throw = .{
                    .tag_index = inst.tag_index,
                    .args_start = args_start,
                    .args_len = inst.n_args,
                } });

                // throw is a control-flow terminator; mark subsequent code unreachable.
                self.stack.slots.shrinkRetainingCapacity(0);
                self.is_unreachable = true;
            },

            // throw_ref: pop exnref slot, emit throw_ref.
            .throw_ref => {
                const ref = try self.pop_slot();
                try self.emit(.{ .throw_ref = .{ .ref = ref } });
                // throw_ref is also a control-flow terminator.
                self.stack.slots.shrinkRetainingCapacity(0);
            },

            // try_table: begin a try block with catch handlers.
            //
            // Layout emitted:
            //   [try_table_enter { handlers_start, handlers_len, end_target=0(patched) }]
            //   <body ops ...>
            //   [try_table_leave { target=<after continuation> }]   <- normal exit
            //   [after continuation: ...]
            //
            // The try_table block itself acts as a label for br depth=0.
            // Each catch arm's br_depth is resolved to the appropriate enclosing frame.
            // The CatchHandlerEntry.target field is patched via the outer frame's patch_sites
            // using the encoding:  0x4000_0000 | catch_handler_tables_index.
            .try_table => |inst| {
                // Allocate result slots for the block type (try_table has no params per spec).
                const slots = try self.resolve_block_slots(inst.block_type);

                // Translate each CatchHandlerWasm into a CatchHandlerEntry and
                // store them in compiled.catch_handler_tables.
                // We also register forward patch sites on the target frames so that
                // when those frames' `end` is processed, CatchHandlerEntry.target is filled in.
                const handlers_start: u32 = @intCast(self.compiled.catch_handler_tables.items.len);
                for (inst.handlers) |h| {
                    const handler_kind: ir.CatchHandlerKind = switch (h.kind) {
                        .catch_ => .catch_tag,
                        .catch_ref => .catch_tag_ref,
                        .catch_all => .catch_all,
                        .catch_all_ref => .catch_all_ref,
                    };

                    const handler_idx: u32 = @intCast(self.compiled.catch_handler_tables.items.len);

                    // Resolve the target frame for this handler.
                    //
                    // IMPORTANT: depth is relative to the label stack *before* the
                    // try_table frame is pushed.  depth=0 refers to the immediately
                    // enclosing block/loop/if, NOT the try_table itself.
                    //
                    // For catch_tag with arity matching the target block's result_slots count,
                    // reuse those slots so the VM writes directly there (avoids extra copies).
                    // For catch_ref, the last result slot is the exnref; preceding slots are payload.
                    const target_frame_opt: ?*ControlFrame = if (h.depth < self.control_stack.items.len)
                        try self.frame_at_depth(h.depth)
                    else
                        null;

                    const dst_slots_start: u32 = @intCast(self.compiled.call_args.items.len);
                    var dst_slots_len: u32 = 0;
                    var dst_ref: Slot = 0;
                    switch (h.kind) {
                        .catch_ => {
                            dst_slots_len = h.tag_arity;
                            if (h.tag_arity > 0) {
                                if (target_frame_opt) |tf| {
                                    if (tf.result_slots.items().len == h.tag_arity) {
                                        // Reuse the target block's result slots directly.
                                        for (tf.result_slots.items()) |rs| {
                                            try self.compiled.call_args.append(self.allocator, rs);
                                        }
                                    } else {
                                        // Allocate one slot per tag argument.
                                        var ai: u32 = 0;
                                        while (ai < h.tag_arity) : (ai += 1) {
                                            try self.compiled.call_args.append(self.allocator, self.alloc_slot());
                                        }
                                    }
                                } else {
                                    var ai: u32 = 0;
                                    while (ai < h.tag_arity) : (ai += 1) {
                                        try self.compiled.call_args.append(self.allocator, self.alloc_slot());
                                    }
                                }
                            }
                        },
                        .catch_ref => {
                            // catch_ref <tag> <label>: branch delivers [tag_values... exnref].
                            // Allocate payload slots for the tag arguments.
                            dst_slots_len = h.tag_arity;
                            if (h.tag_arity > 0) {
                                if (target_frame_opt) |tf| {
                                    const n = tf.result_slots.items().len;
                                    if (h.tag_arity + 1 == n) {
                                        // Reuse the first n-1 result slots for tag payload.
                                        for (tf.result_slots.items()[0 .. n - 1]) |rs| {
                                            try self.compiled.call_args.append(self.allocator, rs);
                                        }
                                    } else {
                                        var ai: u32 = 0;
                                        while (ai < h.tag_arity) : (ai += 1) {
                                            try self.compiled.call_args.append(self.allocator, self.alloc_slot());
                                        }
                                    }
                                } else {
                                    var ai: u32 = 0;
                                    while (ai < h.tag_arity) : (ai += 1) {
                                        try self.compiled.call_args.append(self.allocator, self.alloc_slot());
                                    }
                                }
                            }
                            // The exnref is the last value on the target stack.
                            // Use the last result slot of the target block if the counts match;
                            // otherwise allocate a fresh slot.
                            if (target_frame_opt) |tf| {
                                const n = tf.result_slots.items().len;
                                if (n > 0) {
                                    dst_ref = tf.result_slots.items()[n - 1];
                                } else {
                                    dst_ref = self.alloc_slot();
                                }
                            } else {
                                dst_ref = self.alloc_slot();
                            }
                        },
                        .catch_all => {},
                        .catch_all_ref => {
                            // catch_all_ref: branch delivers [exnref].
                            // Use the target block's sole result slot if it has exactly one.
                            if (target_frame_opt) |tf| {
                                if (tf.result_slots.items().len == 1) {
                                    dst_ref = tf.result_slots.items()[0];
                                } else {
                                    dst_ref = self.alloc_slot();
                                }
                            } else {
                                dst_ref = self.alloc_slot();
                            }
                        },
                    }

                    try self.compiled.catch_handler_tables.append(self.allocator, .{
                        .kind = handler_kind,
                        .tag_index = h.tag_index orelse 0,
                        .target = 0, // patched via outer frame patch_sites
                        .dst_slots_start = dst_slots_start,
                        .dst_slots_len = dst_slots_len,
                        .dst_ref = dst_ref,
                    });

                    // Resolve the br_depth to the target frame and register a patch site.
                    //
                    // IMPORTANT: depth is relative to the label stack *before* the
                    // try_table frame is pushed.  All depths (including 0) refer to
                    // already-pushed frames on the control stack.
                    if (target_frame_opt) |target_frame| {
                        if (target_frame.kind == .loop) {
                            // Backward jump: target is known immediately.
                            self.compiled.catch_handler_tables.items[handler_idx].target = target_frame.target_pc;
                        } else {
                            // Forward jump: patch when target frame's 'end' is seen.
                            try target_frame.patch_sites.append(self.allocator, 0x4000_0000 | handler_idx);
                        }
                    }
                }
                const handlers_len: u32 = @intCast(inst.handlers.len);

                // Emit try_table_enter (end_target patched at 'end').
                const enter_pc = self.current_pc();
                try self.emit(.{
                    .try_table_enter = .{
                        .handlers_start = handlers_start,
                        .handlers_len = handlers_len,
                        .end_target = 0, // placeholder
                    },
                });

                // Push control frame for this try_table block.
                const try_frame: ControlFrame = .{
                    .kind = .try_table,
                    .stack_height = self.stack.len(),
                    .result_slots = slots.results,
                    .param_slots = slots.params,
                    .target_pc = 0, // forward — filled at end
                    .try_table_enter_pc = enter_pc,
                };

                // NOTE: depth-0 patch sites are already registered on the correct
                // enclosing frame above (not on try_frame).  The try_table frame's
                // own patch_sites are only for br instructions targeting the try_table
                // block from inside the body.

                try self.control_stack.append(self.allocator, try_frame);
            },
        }
    }

    // ── Direct OperatorInformation → IR dispatch (bypass WasmOp) ─────────────

    /// Attempt to lower an OperatorInformation directly to IR, bypassing the
    /// WasmOp intermediate tagged union.  Returns `true` if the opcode was
    /// handled, `false` if the caller should fall back to the old
    /// `buildWasmOp` + `lowerOp` path (for opcodes that need the resolver:
    /// call, call_indirect, return_call, return_call_indirect, throw,
    /// try_table, struct_new, call_ref, return_call_ref).
    pub fn lowerOpFromInfo(self: *Lower, info: OperatorInformation) !bool {
        // ── Dead-code elimination (same logic as lowerOp) ────────────────────
        var was_unreachable = false;
        if (self.is_unreachable) {
            switch (info.code) {
                .block, .loop, .if_, .try_table => {
                    self.unreachable_depth += 1;
                    return true;
                },
                .end => {
                    if (self.unreachable_depth > 0) {
                        self.unreachable_depth -= 1;
                        return true;
                    }
                    self.is_unreachable = false;
                    was_unreachable = true;
                    if (self.control_stack.items.len > 0) {
                        const frame = &self.control_stack.items[self.control_stack.items.len - 1];
                        self.stack.slots.shrinkRetainingCapacity(frame.stack_height);
                    }
                    // Fall through to normal end handling.
                },
                .else_ => {
                    if (self.unreachable_depth > 0) {
                        return true;
                    }
                    self.is_unreachable = false;
                    // Fall through to normal else handling.
                },
                else => return true, // skip all other ops in unreachable code
            }
        }

        // ── Special opcodes: fall back to buildWasmOp + lowerOp ──────────────
        switch (info.code) {
            .call,
            .call_indirect,
            .return_call,
            .return_call_indirect,
            .throw,
            .try_table,
            .struct_new,
            .call_ref,
            .return_call_ref,
            => {
                // Undo the unreachable state change we may have applied above.
                // Since these opcodes are NOT end/else, we only reach here when
                // is_unreachable was false at entry (the `else => return true`
                // catch above already handled the unreachable case).
                return false;
            },
            else => {},
        }

        // ── Dispatch directly from OperatorCode ──────────────────────────────
        switch (info.code) {
            .unreachable_ => {
                try self.emit(.unreachable_);
                self.is_unreachable = true;
            },
            .nop => {},
            .drop => {
                _ = try self.pop_slot();
            },

            // ── Structured control flow ──────────────────────────────────────
            .block => {
                const block_type = try translate_mod.wasmBlockTypeFromType(info.block_type);
                try self.lowerOp(.{ .block = block_type });
                // We already handled unreachable above, and lowerOp's unreachable
                // logic won't re-trigger since we cleared is_unreachable.
                // Actually — we need a cleaner approach. Let's inline.
                // WAIT: the problem is lowerOp will check is_unreachable again
                // and do different things. Since we already handled it above, and
                // set was_unreachable, we should inline. But block/loop/if/else/end
                // are complex — let's delegate to lowerOp for these.
            },
            .loop => {
                const block_type = try translate_mod.wasmBlockTypeFromType(info.block_type);
                try self.lowerOp(.{ .loop = block_type });
            },
            .if_ => {
                const block_type = try translate_mod.wasmBlockTypeFromType(info.block_type);
                try self.lowerOp(.{ .if_ = block_type });
            },
            .else_ => try self.lowerOp(.else_),
            .end => try self.lowerOpEnd(was_unreachable),
            .br => {
                const depth = info.br_depth orelse return error.UnsupportedOperator;
                try self.lowerOp(.{ .br = depth });
            },
            .br_if => {
                const depth = info.br_depth orelse return error.UnsupportedOperator;
                try self.lowerOp(.{ .br_if = depth });
            },
            .br_table => try self.lowerOp(.{ .br_table = .{ .targets = info.br_table } }),

            // ── Locals & globals ─────────────────────────────────────────────
            .local_get => {
                const local = info.local_index orelse return error.UnsupportedOperator;
                try self.stack.push(self.allocator, self.local_to_slot(local));
            },
            .local_set => {
                const local = info.local_index orelse return error.UnsupportedOperator;
                const src = try self.pop_slot();
                // ── Peephole D: i32_xxx + local_set → i32_xxx_to_local ────────
                if (!self.try_fuse_local_set(local, src)) {
                    try self.emit(.{ .local_set = .{ .local = local, .src = src } });
                }
            },
            .local_tee => {
                const local = info.local_index orelse return error.UnsupportedOperator;
                const src = self.stack.peek() orelse return error.StackUnderflow;
                try self.emit(.{ .local_set = .{ .local = local, .src = src } });
            },
            .global_get => {
                const global_idx = info.global_index orelse return error.UnsupportedOperator;
                const dst = self.alloc_slot();
                try self.emit(.{ .global_get = .{ .dst = dst, .global_idx = global_idx } });
                try self.stack.push(self.allocator, dst);
            },
            .global_set => {
                const global_idx = info.global_index orelse return error.UnsupportedOperator;
                const src = try self.pop_slot();
                try self.emit(.{ .global_set = .{ .src = src, .global_idx = global_idx } });
            },

            // ── Constants ────────────────────────────────────────────────────
            .i32_const => {
                const value = try translate_mod.literalAsI32(info);
                const dst = self.alloc_slot();
                try self.emit(.{ .const_i32 = .{ .dst = dst, .value = value } });
                try self.stack.push(self.allocator, dst);
            },
            .i64_const => {
                const value = try translate_mod.literalAsI64(info);
                const dst = self.alloc_slot();
                try self.emit(.{ .const_i64 = .{ .dst = dst, .value = value } });
                try self.stack.push(self.allocator, dst);
            },
            .f32_const => {
                const value = try translate_mod.literalAsF32(info);
                const dst = self.alloc_slot();
                try self.emit(.{ .const_f32 = .{ .dst = dst, .value = value } });
                try self.stack.push(self.allocator, dst);
            },
            .f64_const => {
                const value = try translate_mod.literalAsF64(info);
                const dst = self.alloc_slot();
                try self.emit(.{ .const_f64 = .{ .dst = dst, .value = value } });
                try self.stack.push(self.allocator, dst);
            },

            // ── i32 binary ───────────────────────────────────────────────────
            .i32_add => try self.lower_binary_op("i32_add"),
            .i32_sub => try self.lower_binary_op("i32_sub"),
            .i32_mul => try self.lower_binary_op("i32_mul"),
            .i32_div_s => try self.lower_binary_op("i32_div_s"),
            .i32_div_u => try self.lower_binary_op("i32_div_u"),
            .i32_rem_s => try self.lower_binary_op("i32_rem_s"),
            .i32_rem_u => try self.lower_binary_op("i32_rem_u"),
            .i32_and => try self.lower_binary_op("i32_and"),
            .i32_or => try self.lower_binary_op("i32_or"),
            .i32_xor => try self.lower_binary_op("i32_xor"),
            .i32_shl => try self.lower_binary_op("i32_shl"),
            .i32_shr_s => try self.lower_binary_op("i32_shr_s"),
            .i32_shr_u => try self.lower_binary_op("i32_shr_u"),
            .i32_rotl => try self.lower_binary_op("i32_rotl"),
            .i32_rotr => try self.lower_binary_op("i32_rotr"),

            // ── i64 binary ───────────────────────────────────────────────────
            .i64_add => try self.lower_binary_op("i64_add"),
            .i64_sub => try self.lower_binary_op("i64_sub"),
            .i64_mul => try self.lower_binary_op("i64_mul"),
            .i64_div_s => try self.lower_binary_op("i64_div_s"),
            .i64_div_u => try self.lower_binary_op("i64_div_u"),
            .i64_rem_s => try self.lower_binary_op("i64_rem_s"),
            .i64_rem_u => try self.lower_binary_op("i64_rem_u"),
            .i64_and => try self.lower_binary_op("i64_and"),
            .i64_or => try self.lower_binary_op("i64_or"),
            .i64_xor => try self.lower_binary_op("i64_xor"),
            .i64_shl => try self.lower_binary_op("i64_shl"),
            .i64_shr_s => try self.lower_binary_op("i64_shr_s"),
            .i64_shr_u => try self.lower_binary_op("i64_shr_u"),
            .i64_rotl => try self.lower_binary_op("i64_rotl"),
            .i64_rotr => try self.lower_binary_op("i64_rotr"),

            // ── f32 binary ───────────────────────────────────────────────────
            .f32_add => try self.lower_binary_op("f32_add"),
            .f32_sub => try self.lower_binary_op("f32_sub"),
            .f32_mul => try self.lower_binary_op("f32_mul"),
            .f32_div => try self.lower_binary_op("f32_div"),
            .f32_min => try self.lower_binary_op("f32_min"),
            .f32_max => try self.lower_binary_op("f32_max"),
            .f32_copysign => try self.lower_binary_op("f32_copysign"),

            // ── f64 binary ───────────────────────────────────────────────────
            .f64_add => try self.lower_binary_op("f64_add"),
            .f64_sub => try self.lower_binary_op("f64_sub"),
            .f64_mul => try self.lower_binary_op("f64_mul"),
            .f64_div => try self.lower_binary_op("f64_div"),
            .f64_min => try self.lower_binary_op("f64_min"),
            .f64_max => try self.lower_binary_op("f64_max"),
            .f64_copysign => try self.lower_binary_op("f64_copysign"),

            // ── i32 unary ────────────────────────────────────────────────────
            .i32_clz => try self.lower_unary_op("i32_clz"),
            .i32_ctz => try self.lower_unary_op("i32_ctz"),
            .i32_popcnt => try self.lower_unary_op("i32_popcnt"),

            // ── i64 unary ────────────────────────────────────────────────────
            .i64_clz => try self.lower_unary_op("i64_clz"),
            .i64_ctz => try self.lower_unary_op("i64_ctz"),
            .i64_popcnt => try self.lower_unary_op("i64_popcnt"),

            // ── f32 unary ────────────────────────────────────────────────────
            .f32_abs => try self.lower_unary_op("f32_abs"),
            .f32_neg => try self.lower_unary_op("f32_neg"),
            .f32_ceil => try self.lower_unary_op("f32_ceil"),
            .f32_floor => try self.lower_unary_op("f32_floor"),
            .f32_trunc => try self.lower_unary_op("f32_trunc"),
            .f32_nearest => try self.lower_unary_op("f32_nearest"),
            .f32_sqrt => try self.lower_unary_op("f32_sqrt"),

            // ── f64 unary ────────────────────────────────────────────────────
            .f64_abs => try self.lower_unary_op("f64_abs"),
            .f64_neg => try self.lower_unary_op("f64_neg"),
            .f64_ceil => try self.lower_unary_op("f64_ceil"),
            .f64_floor => try self.lower_unary_op("f64_floor"),
            .f64_trunc => try self.lower_unary_op("f64_trunc"),
            .f64_nearest => try self.lower_unary_op("f64_nearest"),
            .f64_sqrt => try self.lower_unary_op("f64_sqrt"),

            // ── i32 comparisons ──────────────────────────────────────────────
            .i32_eqz => try self.lower_unary_op("i32_eqz"),
            .i32_eq => try self.lower_compare_op("i32_eq"),
            .i32_ne => try self.lower_compare_op("i32_ne"),
            .i32_lt_s => try self.lower_compare_op("i32_lt_s"),
            .i32_lt_u => try self.lower_compare_op("i32_lt_u"),
            .i32_gt_s => try self.lower_compare_op("i32_gt_s"),
            .i32_gt_u => try self.lower_compare_op("i32_gt_u"),
            .i32_le_s => try self.lower_compare_op("i32_le_s"),
            .i32_le_u => try self.lower_compare_op("i32_le_u"),
            .i32_ge_s => try self.lower_compare_op("i32_ge_s"),
            .i32_ge_u => try self.lower_compare_op("i32_ge_u"),

            // ── i64 comparisons ──────────────────────────────────────────────
            .i64_eqz => try self.lower_unary_op("i64_eqz"),
            .i64_eq => try self.lower_compare_op("i64_eq"),
            .i64_ne => try self.lower_compare_op("i64_ne"),
            .i64_lt_s => try self.lower_compare_op("i64_lt_s"),
            .i64_lt_u => try self.lower_compare_op("i64_lt_u"),
            .i64_gt_s => try self.lower_compare_op("i64_gt_s"),
            .i64_gt_u => try self.lower_compare_op("i64_gt_u"),
            .i64_le_s => try self.lower_compare_op("i64_le_s"),
            .i64_le_u => try self.lower_compare_op("i64_le_u"),
            .i64_ge_s => try self.lower_compare_op("i64_ge_s"),
            .i64_ge_u => try self.lower_compare_op("i64_ge_u"),

            // ── f32 comparisons ──────────────────────────────────────────────
            .f32_eq => try self.lower_compare_op("f32_eq"),
            .f32_ne => try self.lower_compare_op("f32_ne"),
            .f32_lt => try self.lower_compare_op("f32_lt"),
            .f32_gt => try self.lower_compare_op("f32_gt"),
            .f32_le => try self.lower_compare_op("f32_le"),
            .f32_ge => try self.lower_compare_op("f32_ge"),

            // ── f64 comparisons ──────────────────────────────────────────────
            .f64_eq => try self.lower_compare_op("f64_eq"),
            .f64_ne => try self.lower_compare_op("f64_ne"),
            .f64_lt => try self.lower_compare_op("f64_lt"),
            .f64_gt => try self.lower_compare_op("f64_gt"),
            .f64_le => try self.lower_compare_op("f64_le"),
            .f64_ge => try self.lower_compare_op("f64_ge"),

            // ── Conversions & sign-extension ─────────────────────────────────
            .i32_wrap_i64 => try self.lower_convert_op("i32_wrap_i64"),
            .i32_trunc_f32_s => try self.lower_convert_op("i32_trunc_f32_s"),
            .i32_trunc_f32_u => try self.lower_convert_op("i32_trunc_f32_u"),
            .i32_trunc_f64_s => try self.lower_convert_op("i32_trunc_f64_s"),
            .i32_trunc_f64_u => try self.lower_convert_op("i32_trunc_f64_u"),
            .i64_extend_i32_s => try self.lower_convert_op("i64_extend_i32_s"),
            .i64_extend_i32_u => try self.lower_convert_op("i64_extend_i32_u"),
            .i64_trunc_f32_s => try self.lower_convert_op("i64_trunc_f32_s"),
            .i64_trunc_f32_u => try self.lower_convert_op("i64_trunc_f32_u"),
            .i64_trunc_f64_s => try self.lower_convert_op("i64_trunc_f64_s"),
            .i64_trunc_f64_u => try self.lower_convert_op("i64_trunc_f64_u"),
            .i32_trunc_sat_f32_s => try self.lower_convert_op("i32_trunc_sat_f32_s"),
            .i32_trunc_sat_f32_u => try self.lower_convert_op("i32_trunc_sat_f32_u"),
            .i32_trunc_sat_f64_s => try self.lower_convert_op("i32_trunc_sat_f64_s"),
            .i32_trunc_sat_f64_u => try self.lower_convert_op("i32_trunc_sat_f64_u"),
            .i64_trunc_sat_f32_s => try self.lower_convert_op("i64_trunc_sat_f32_s"),
            .i64_trunc_sat_f32_u => try self.lower_convert_op("i64_trunc_sat_f32_u"),
            .i64_trunc_sat_f64_s => try self.lower_convert_op("i64_trunc_sat_f64_s"),
            .i64_trunc_sat_f64_u => try self.lower_convert_op("i64_trunc_sat_f64_u"),
            .f32_convert_i32_s => try self.lower_convert_op("f32_convert_i32_s"),
            .f32_convert_i32_u => try self.lower_convert_op("f32_convert_i32_u"),
            .f32_convert_i64_s => try self.lower_convert_op("f32_convert_i64_s"),
            .f32_convert_i64_u => try self.lower_convert_op("f32_convert_i64_u"),
            .f32_demote_f64 => try self.lower_convert_op("f32_demote_f64"),
            .f64_convert_i32_s => try self.lower_convert_op("f64_convert_i32_s"),
            .f64_convert_i32_u => try self.lower_convert_op("f64_convert_i32_u"),
            .f64_convert_i64_s => try self.lower_convert_op("f64_convert_i64_s"),
            .f64_convert_i64_u => try self.lower_convert_op("f64_convert_i64_u"),
            .f64_promote_f32 => try self.lower_convert_op("f64_promote_f32"),
            .i32_reinterpret_f32 => try self.lower_convert_op("i32_reinterpret_f32"),
            .i64_reinterpret_f64 => try self.lower_convert_op("i64_reinterpret_f64"),
            .f32_reinterpret_i32 => try self.lower_convert_op("f32_reinterpret_i32"),
            .f64_reinterpret_i64 => try self.lower_convert_op("f64_reinterpret_i64"),
            .i32_extend8_s => try self.lower_convert_op("i32_extend8_s"),
            .i32_extend16_s => try self.lower_convert_op("i32_extend16_s"),
            .i64_extend8_s => try self.lower_convert_op("i64_extend8_s"),
            .i64_extend16_s => try self.lower_convert_op("i64_extend16_s"),
            .i64_extend32_s => try self.lower_convert_op("i64_extend32_s"),

            // ── Memory loads ─────────────────────────────────────────────────
            .i32_load => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_load = .{ .dst = dst, .addr = addr, .offset = offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_load8_s => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_load8_s = .{ .dst = dst, .addr = addr, .offset = offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_load8_u => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_load8_u = .{ .dst = dst, .addr = addr, .offset = offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_load16_s => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_load16_s = .{ .dst = dst, .addr = addr, .offset = offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_load16_u => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_load16_u = .{ .dst = dst, .addr = addr, .offset = offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i64_load => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i64_load = .{ .dst = dst, .addr = addr, .offset = offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i64_load8_s => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i64_load8_s = .{ .dst = dst, .addr = addr, .offset = offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i64_load8_u => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i64_load8_u = .{ .dst = dst, .addr = addr, .offset = offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i64_load16_s => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i64_load16_s = .{ .dst = dst, .addr = addr, .offset = offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i64_load16_u => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i64_load16_u = .{ .dst = dst, .addr = addr, .offset = offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i64_load32_s => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i64_load32_s = .{ .dst = dst, .addr = addr, .offset = offset } });
                try self.stack.push(self.allocator, dst);
            },
            .i64_load32_u => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i64_load32_u = .{ .dst = dst, .addr = addr, .offset = offset } });
                try self.stack.push(self.allocator, dst);
            },
            .f32_load => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .f32_load = .{ .dst = dst, .addr = addr, .offset = offset } });
                try self.stack.push(self.allocator, dst);
            },
            .f64_load => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const addr = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .f64_load = .{ .dst = dst, .addr = addr, .offset = offset } });
                try self.stack.push(self.allocator, dst);
            },

            // ── Memory stores ────────────────────────────────────────────────
            .i32_store => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                try self.emit(.{ .i32_store = .{ .addr = addr, .src = src, .offset = offset } });
            },
            .i32_store8 => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                try self.emit(.{ .i32_store8 = .{ .addr = addr, .src = src, .offset = offset } });
            },
            .i32_store16 => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                try self.emit(.{ .i32_store16 = .{ .addr = addr, .src = src, .offset = offset } });
            },
            .i64_store => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                try self.emit(.{ .i64_store = .{ .addr = addr, .src = src, .offset = offset } });
            },
            .i64_store8 => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                try self.emit(.{ .i64_store8 = .{ .addr = addr, .src = src, .offset = offset } });
            },
            .i64_store16 => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                try self.emit(.{ .i64_store16 = .{ .addr = addr, .src = src, .offset = offset } });
            },
            .i64_store32 => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                try self.emit(.{ .i64_store32 = .{ .addr = addr, .src = src, .offset = offset } });
            },
            .f32_store => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                try self.emit(.{ .f32_store = .{ .addr = addr, .src = src, .offset = offset } });
            },
            .f64_store => {
                const offset = (info.memory_address orelse return error.UnsupportedOperator).offset;
                const src = try self.pop_slot();
                const addr = try self.pop_slot();
                try self.emit(.{ .f64_store = .{ .addr = addr, .src = src, .offset = offset } });
            },

            // ── Bulk memory ──────────────────────────────────────────────────
            .memory_init => {
                const segment_idx = info.segment_index orelse return error.UnsupportedOperator;
                const len = try self.pop_slot();
                const src_offset = try self.pop_slot();
                const dst_addr = try self.pop_slot();
                try self.emit(.{ .memory_init = .{ .segment_idx = segment_idx, .dst_addr = dst_addr, .src_offset = src_offset, .len = len } });
            },
            .data_drop => {
                const segment_idx = info.segment_index orelse return error.UnsupportedOperator;
                try self.emit(.{ .data_drop = .{ .segment_idx = segment_idx } });
            },
            .memory_copy => {
                const len = try self.pop_slot();
                const src_addr = try self.pop_slot();
                const dst_addr = try self.pop_slot();
                try self.emit(.{ .memory_copy = .{ .dst_addr = dst_addr, .src_addr = src_addr, .len = len } });
            },
            .memory_fill => {
                const len = try self.pop_slot();
                const value = try self.pop_slot();
                const dst_addr = try self.pop_slot();
                try self.emit(.{ .memory_fill = .{ .dst_addr = dst_addr, .value = value, .len = len } });
            },
            .memory_size => {
                const dst = self.alloc_slot();
                try self.stack.push(self.allocator, dst);
                try self.emit(.{ .memory_size = .{ .dst = dst } });
            },
            .memory_grow => {
                const delta = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.stack.push(self.allocator, dst);
                try self.emit(.{ .memory_grow = .{ .dst = dst, .delta = delta } });
            },

            // ── Return ───────────────────────────────────────────────────────
            .return_ => {
                const value = self.stack.pop();
                try self.emit(.{ .ret = .{ .value = value } });
                self.is_unreachable = true;
            },

            // ── Select ───────────────────────────────────────────────────────
            .select, .select_with_type => {
                const cond = try self.pop_slot();
                const val2 = try self.pop_slot();
                const val1 = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .select = .{ .dst = dst, .val1 = val1, .val2 = val2, .cond = cond } });
                try self.stack.push(self.allocator, dst);
            },

            // ── Reference types ──────────────────────────────────────────────
            .ref_null => {
                const dst = self.alloc_slot();
                try self.emit(.{ .const_ref_null = .{ .dst = dst } });
                try self.stack.push(self.allocator, dst);
            },
            .ref_is_null => {
                const src = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .ref_is_null = .{ .dst = dst, .src = src } });
                try self.stack.push(self.allocator, dst);
            },
            .ref_func => {
                const func_idx = info.func_index orelse return error.UnsupportedOperator;
                const dst = self.alloc_slot();
                try self.emit(.{ .ref_func = .{ .dst = dst, .func_idx = func_idx } });
                try self.stack.push(self.allocator, dst);
            },
            .ref_eq => {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .ref_eq = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },

            // ── Table instructions ───────────────────────────────────────────
            .table_get => {
                const table_index = info.table_index orelse return error.UnsupportedOperator;
                const index = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .table_get = .{ .dst = dst, .table_index = table_index, .index = index } });
                try self.stack.push(self.allocator, dst);
            },
            .table_set => {
                const table_index = info.table_index orelse return error.UnsupportedOperator;
                const value = try self.pop_slot();
                const index = try self.pop_slot();
                try self.emit(.{ .table_set = .{ .table_index = table_index, .index = index, .value = value } });
            },
            .table_size => {
                const table_index = info.table_index orelse return error.UnsupportedOperator;
                const dst = self.alloc_slot();
                try self.emit(.{ .table_size = .{ .dst = dst, .table_index = table_index } });
                try self.stack.push(self.allocator, dst);
            },
            .table_grow => {
                const table_index = info.table_index orelse return error.UnsupportedOperator;
                const delta = try self.pop_slot();
                const init_slot = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .table_grow = .{ .dst = dst, .table_index = table_index, .init = init_slot, .delta = delta } });
                try self.stack.push(self.allocator, dst);
            },
            .table_fill => {
                const table_index = info.table_index orelse return error.UnsupportedOperator;
                const len = try self.pop_slot();
                const value = try self.pop_slot();
                const dst_idx = try self.pop_slot();
                try self.emit(.{ .table_fill = .{ .table_index = table_index, .dst_idx = dst_idx, .value = value, .len = len } });
            },
            .table_copy => {
                const dst_table = info.table_index orelse return error.UnsupportedOperator;
                const src_table = info.destination_index orelse return error.UnsupportedOperator;
                const len = try self.pop_slot();
                const src_idx = try self.pop_slot();
                const dst_idx = try self.pop_slot();
                try self.emit(.{ .table_copy = .{ .dst_table = dst_table, .src_table = src_table, .dst_idx = dst_idx, .src_idx = src_idx, .len = len } });
            },
            .table_init => {
                const table_index = info.table_index orelse return error.UnsupportedOperator;
                const segment_idx = info.segment_index orelse return error.UnsupportedOperator;
                const len = try self.pop_slot();
                const src_offset = try self.pop_slot();
                const dst_idx = try self.pop_slot();
                try self.emit(.{ .table_init = .{ .table_index = table_index, .segment_idx = segment_idx, .dst_idx = dst_idx, .src_offset = src_offset, .len = len } });
            },
            .elem_drop => {
                const segment_idx = info.segment_index orelse return error.UnsupportedOperator;
                try self.emit(.{ .elem_drop = .{ .segment_idx = segment_idx } });
            },

            // ── SIMD / Atomic / GC-non-struct_new / other rare opcodes ────
            // All handled by the `else` fallback below via operatorToWasmOp.

            // ── Special opcodes already returned false above ─────────────────
            .call,
            .call_indirect,
            .return_call,
            .return_call_indirect,
            .throw,
            .try_table,
            .struct_new,
            .call_ref,
            .return_call_ref,
            => unreachable,

            // ── Anything else: delegate to operatorToWasmOp + lowerOp ────────
            else => {
                const wasm_op = try translate_mod.operatorToWasmOp(info);
                try self.lowerOp(wasm_op);
            },
        }
        return true;
    }

    /// Helper: process `end` opcode when called from lowerOpFromInfo.
    /// This is needed because lowerOp's `end` case relies on `was_unreachable`
    /// being computed in the same function scope. lowerOpFromInfo computes it
    /// in its own scope and then needs to delegate just the `end` logic.
    pub fn lowerOpEnd(self: *Lower, was_unreachable: bool) !void {
        if (self.control_stack.items.len == 0) {
            if (!was_unreachable) {
                const value = self.stack.pop();
                try self.emit(.{ .ret = .{ .value = value } });
            } else {
                try self.emit(.{ .ret = .{ .value = null } });
            }
            return;
        }

        var frame = self.control_stack.pop().?;
        defer frame.patch_sites.deinit(self.allocator);
        defer frame.result_slots.deinit(self.allocator);
        defer frame.param_slots.deinit(self.allocator);

        if (frame.is_function_frame) {
            const ret_pc = self.current_pc();
            self.patch_forward_jumps(&frame, ret_pc);
            if (!was_unreachable) {
                const value = self.stack.pop();
                try self.emit(.{ .ret = .{ .value = value } });
            } else {
                try self.emit(.{ .ret = .{ .value = null } });
            }
            return;
        }

        if (!was_unreachable) {
            const n = frame.result_slots.items().len;
            var ri: usize = n;
            while (ri > 0) {
                ri -= 1;
                if (self.stack.peek()) |src| {
                    try self.emit(.{ .copy = .{ .dst = frame.result_slots.items()[ri], .src = src } });
                    _ = self.stack.pop();
                }
            }
        }

        if (frame.kind == .if_ and !frame.has_else and frame.result_slots.items().len > 0) {
            const then_skip_pc = self.current_pc();
            try self.emit(.{ .jump = .{ .target = 0 } });

            const false_path_pc = self.current_pc();
            self.patch_forward_jumps(&frame, false_path_pc);

            for (frame.result_slots.items()) |rs| {
                try self.emit(.{ .const_i64 = .{ .dst = rs, .value = 0 } });
            }

            const continuation_pc = self.current_pc();
            switch (self.compiled.ops.items[then_skip_pc]) {
                .jump => |*j| j.target = continuation_pc,
                else => unreachable,
            }

            frame.patch_sites.clearRetainingCapacity();
        }

        if (frame.kind == .try_table) {
            const leave_pc = self.current_pc();
            try self.emit(.{ .try_table_leave = .{ .target = 0 } });
            try frame.patch_sites.append(self.allocator, leave_pc);

            if (frame.try_table_enter_pc) |epc| {
                switch (self.compiled.ops.items[epc]) {
                    .try_table_enter => |*e| e.end_target = leave_pc,
                    else => unreachable,
                }
            }
        }

        const end_pc = self.current_pc();
        self.patch_forward_jumps(&frame, end_pc);

        try self.unwind_stack_to_frame(&frame);
    }

    pub fn finish(self: *Lower) CompiledFunction {
        return self.compiled;
    }
};

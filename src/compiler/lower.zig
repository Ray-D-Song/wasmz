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

const Allocator = std.mem.Allocator;
const Slot = ir.Slot;
const Op = ir.Op;
const CompiledFunction = ir.CompiledFunction;
const ValType = core.ValType;

pub const LowerError = error{
    StackUnderflow,
    ControlStackUnderflow,
    MismatchedEnd,
};

// ── Control flow ──────────────────────────────────────────────────────────────

/// Which WASM structured-control construct opened this frame.
pub const BlockKind = enum { block, loop, if_ };

/// A single entry on the control stack, created when we enter a block/loop/if.
pub const ControlFrame = struct {
    kind: BlockKind,
    /// Number of values on the value stack at the time this block was entered.
    /// Used to restore the stack when we branch out of the block.
    stack_height: usize,
    /// The slot that holds this block's result value (null = void block).
    result_slot: ?Slot,
    /// For block/if: the op-index of the start of the continuation (filled in
    /// when we see `end`).  For loop: the op-index of the loop header (filled
    /// in immediately at open time, since `br` goes back to the top).
    /// While still open, forward-jump sites are stored in `patch_sites`.
    target_pc: u32,
    /// Indices into compiled.ops that hold `jump` / `jump_if_z` ops whose
    /// target needs to be patched when we know where `end` lands.
    patch_sites: std.ArrayListUnmanaged(u32) = .empty,
};

// ── Input op enum ─────────────────────────────────────────────────────────────

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
    /// select: stack [val1, val2, cond] -> if cond != 0 then val1 else val2
    select,
    /// select with explicit type annotation (same semantics, type annotation ignored at runtime",)
    select_with_type,
};

/// Block/loop/if result type. null means void (no result).
/// TODO: support multi-value block types (positive type index referencing the Type Section),
/// which require a union(enum) { val_type: ValType, type_index: u32 } instead of a plain alias.
pub const BlockType = ValType;

// ── Lowering pass ─────────────────────────────────────────────────────────────

pub const Lower = struct {
    allocator: Allocator,
    compiled: CompiledFunction = .{
        .slots_len = 0,
        .ops = .empty,
        .call_args = .empty,
        .br_table_targets = .empty,
    },
    stack: ValueStack = .{},
    next_slot: Slot = 0,
    /// Control-flow nesting stack.
    control_stack: std.ArrayListUnmanaged(ControlFrame) = .empty,

    pub fn init(allocator: Allocator) Lower {
        return .{ .allocator = allocator };
    }

    pub fn init_with_reserved_slots(allocator: Allocator, reserved_slots: u32) Lower {
        return .{
            .allocator = allocator,
            .compiled = .{
                .slots_len = reserved_slots,
                .ops = .empty,
                .call_args = .empty,
                .br_table_targets = .empty,
            },
            .next_slot = reserved_slots,
        };
    }

    pub fn deinit(self: *Lower) void {
        self.stack.deinit(self.allocator);
        self.compiled.ops.deinit(self.allocator);
        self.compiled.call_args.deinit(self.allocator);
        self.compiled.br_table_targets.deinit(self.allocator);
        for (self.control_stack.items) |*frame| {
            frame.patch_sites.deinit(self.allocator);
        }
        self.control_stack.deinit(self.allocator);
    }

    // ── Slot helpers ──────────────────────────────────────────────────────────

    fn alloc_slot(self: *Lower) Slot {
        const slot = self.next_slot;
        self.next_slot += 1;
        if (self.compiled.slots_len < self.next_slot) {
            self.compiled.slots_len = self.next_slot;
        }
        return slot;
    }

    fn emit(self: *Lower, op: Op) !void {
        try self.compiled.ops.append(self.allocator, op);
    }

    /// Current index that the *next* emitted op will occupy.
    fn current_pc(self: *Lower) u32 {
        return @intCast(self.compiled.ops.items.len);
    }

    fn pop_slot(self: *Lower) LowerError!Slot {
        return self.stack.pop() orelse error.StackUnderflow;
    }

    fn local_to_slot(_: *Lower, local: u32) Slot {
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
    /// optionally push the frame's result slot back (if the frame has one).
    fn unwind_stack_to_frame(self: *Lower, frame: *const ControlFrame) !void {
        // Truncate the value stack to the frame's entry height.
        self.stack.slots.shrinkRetainingCapacity(frame.stack_height);
        // If this frame produces a value, push the result slot so downstream
        // ops can consume it.
        if (frame.result_slot) |rs| {
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
    /// All other sites are op indices for jump / jump_if_z ops.
    fn patch_forward_jumps(self: *Lower, frame: *ControlFrame, target_pc: u32) void {
        for (frame.patch_sites.items) |site| {
            if (site & 0x8000_0000 != 0) {
                // br_table_targets patch site
                const tgt_idx = site & 0x7FFF_FFFF;
                self.compiled.br_table_targets.items[tgt_idx] = target_pc;
            } else {
                switch (self.compiled.ops.items[site]) {
                    .jump => |*j| j.target = target_pc,
                    .jump_if_z => |*j| j.target = target_pc,
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
        // Copy result value into the frame's result slot before jumping.
        if (frame.result_slot) |rs| {
            const src = self.stack.peek() orelse return error.StackUnderflow;
            try self.emit(.{ .copy = .{ .dst = rs, .src = src } });
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

    /// Handle binary operations: pop two operands, allocate result slot, emit, push result.
    /// The op_tag parameter is a string literal representing the Op field name.
    fn lower_binary_op(
        self: *Lower,
        comptime op_tag: []const u8,
    ) !void {
        const rhs = try self.pop_slot();
        const lhs = try self.pop_slot();
        const dst = self.alloc_slot();

        try self.emit(@unionInit(Op, op_tag, .{
            .dst = dst,
            .lhs = lhs,
            .rhs = rhs,
        }));

        try self.stack.push(self.allocator, dst);
    }

    /// Handle unary operations: pop one operand, allocate result slot, emit, push result.
    fn lower_unary_op(
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
    fn lower_compare_op(
        self: *Lower,
        comptime op_tag: []const u8,
    ) !void {
        const rhs = try self.pop_slot();
        const lhs = try self.pop_slot();
        const dst = self.alloc_slot();

        try self.emit(@unionInit(Op, op_tag, .{
            .dst = dst,
            .lhs = lhs,
            .rhs = rhs,
        }));

        try self.stack.push(self.allocator, dst);
    }

    // ── Main dispatch ─────────────────────────────────────────────────────────

    pub fn lower_op(self: *Lower, op: WasmOp) !void {
        switch (op) {
            .unreachable_ => {
                try self.emit(.unreachable_);
            },

            .nop => {
                // No-op: nothing to emit.
            },

            .drop => {
                _ = try self.pop_slot();
            },

            // ── Structured control flow ───────────────────────────────────────

            .block => |block_type| {
                const result_slot: ?Slot = if (block_type != null) blk: {
                    const s = self.alloc_slot();
                    break :blk s;
                } else null;

                try self.control_stack.append(self.allocator, .{
                    .kind = .block,
                    .stack_height = self.stack.len(),
                    .result_slot = result_slot,
                    .target_pc = 0, // forward — filled at end
                });
            },

            .loop => |block_type| {
                const result_slot: ?Slot = if (block_type != null) blk: {
                    const s = self.alloc_slot();
                    break :blk s;
                } else null;

                // The loop target is right here (top of the loop body).
                const loop_header_pc = self.current_pc();
                try self.control_stack.append(self.allocator, .{
                    .kind = .loop,
                    .stack_height = self.stack.len(),
                    .result_slot = result_slot,
                    .target_pc = loop_header_pc,
                });
            },

            .if_ => |block_type| {
                const cond = try self.pop_slot();
                const result_slot: ?Slot = if (block_type != null) blk: {
                    const s = self.alloc_slot();
                    break :blk s;
                } else null;

                // Emit a conditional jump that skips the then-body if cond==0.
                // Target is patched at else_ or end.
                const jiz_pc = self.current_pc();
                try self.emit(.{ .jump_if_z = .{ .cond = cond, .target = 0 } });

                try self.control_stack.append(self.allocator, .{
                    .kind = .if_,
                    .stack_height = self.stack.len(),
                    .result_slot = result_slot,
                    .target_pc = 0, // forward
                    .patch_sites = blk: {
                        // The jump_if_z is a forward patch site for the else/end.
                        var ps: std.ArrayListUnmanaged(u32) = .empty;
                        try ps.append(self.allocator, jiz_pc);
                        break :blk ps;
                    },
                });
            },

            .else_ => {
                const len = self.control_stack.items.len;
                if (len == 0) return error.MismatchedEnd;
                const frame = &self.control_stack.items[len - 1];

                // If the block produces a value, copy the then-branch result into
                // the result slot before leaving the then-body.
                if (frame.result_slot) |rs| {
                    if (self.stack.peek()) |src| {
                        try self.emit(.{ .copy = .{ .dst = rs, .src = src } });
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

                // Reset the value stack to block-entry height.
                self.stack.slots.shrinkRetainingCapacity(frame.stack_height);
            },

            .end => {
                if (self.control_stack.items.len == 0) {
                    // The final `end` of the function body — emit return.
                    const value = self.stack.pop();
                    try self.emit(.{ .ret = .{ .value = value } });
                    return;
                }

                var frame = self.control_stack.pop().?;
                defer frame.patch_sites.deinit(self.allocator);

                // If the block has a result and there is a value on the stack,
                // copy it into the result slot.
                if (frame.result_slot) |rs| {
                    if (self.stack.peek()) |src| {
                        try self.emit(.{ .copy = .{ .dst = rs, .src = src } });
                    }
                }

                // The continuation starts at the next op.
                const end_pc = self.current_pc();
                self.patch_forward_jumps(&frame, end_pc);

                // Restore value stack and push result if any.
                try self.unwind_stack_to_frame(&frame);
            },

            .br => |depth| {
                const frame = try self.frame_at_depth(depth);
                _ = try self.emit_branch_to(frame);
                // After an unconditional br the rest of the block is unreachable;
                // reset the stack to the frame's height so further ops (up to the
                // matching end) do not see stale values.
                self.stack.slots.shrinkRetainingCapacity(frame.stack_height);
            },

            .br_if => |depth| {
                const cond = try self.pop_slot();
                const frame = try self.frame_at_depth(depth);

                // Copy result to frame's result slot (if any).
                if (frame.result_slot) |rs| {
                    const src = self.stack.peek() orelse return error.StackUnderflow;
                    try self.emit(.{ .copy = .{ .dst = rs, .src = src } });
                }

                // Emit conditional jump.
                const jiz_pc = self.current_pc();
                // We jump when cond != 0, but our op is jump_if_z.
                // Work-around: emit jump_if_z to skip the unconditional jump,
                // then emit the unconditional jump to the target.
                //   jump_if_z cond → skip_jump
                //   jump → target
                //   skip_jump: (fall-through, continue",)
                const skip_jump_placeholder_pc = self.current_pc();
                try self.emit(.{ .jump_if_z = .{ .cond = cond, .target = 0 } }); // skip the jump below if cond==0
                _ = skip_jump_placeholder_pc;

                // Now emit the actual branch to the target frame.
                const branch_jump_pc = self.current_pc();
                if (frame.kind == .loop) {
                    try self.emit(.{ .jump = .{ .target = frame.target_pc } });
                } else {
                    try self.emit(.{ .jump = .{ .target = 0 } }); // forward — patch at end
                    try self.add_patch_site(frame, branch_jump_pc);
                }

                // Patch the jump_if_z to skip just past the unconditional jump.
                const continue_pc = self.current_pc();
                switch (self.compiled.ops.items[jiz_pc]) {
                    .jump_if_z => |*j| j.target = continue_pc,
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
                        // Copy result into the frame's result slot (if any).
                        if (f.result_slot) |rs| {
                            if (l.stack.peek()) |src| {
                                try l.emit(.{ .copy = .{ .dst = rs, .src = src } });
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
            },

            // ── Locals & constants ────────────────────────────────────────────

            .local_get => |local| {
                try self.stack.push(self.allocator, self.local_to_slot(local));
            },
            .local_set => |local| {
                const src = try self.pop_slot();
                try self.emit(.{ .local_set = .{ .local = local, .src = src } });
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

            .ret => {
                const value = self.stack.pop();
                try self.emit(.{ .ret = .{ .value = value } });
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
        }
    }

    pub fn finish(self: *Lower) CompiledFunction {
        return self.compiled;
    }
};

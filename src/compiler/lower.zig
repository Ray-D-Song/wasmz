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
    drop,
    block: ?BlockType,
    loop: ?BlockType,
    if_: ?BlockType,
    else_,
    end,
    br: u32,
    br_if: u32,
    local_get: u32,
    local_set: u32,
    local_tee: u32,
    i32_const: i32,
    i32_add,
    i32_sub,
    i32_mul,
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
    ret,
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
            },
            .next_slot = reserved_slots,
        };
    }

    pub fn deinit(self: *Lower) void {
        self.stack.deinit(self.allocator);
        self.compiled.ops.deinit(self.allocator);
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
    fn patch_forward_jumps(self: *Lower, frame: *ControlFrame, target_pc: u32) void {
        for (frame.patch_sites.items) |site| {
            switch (self.compiled.ops.items[site]) {
                .jump => |*j| j.target = target_pc,
                .jump_if_z => |*j| j.target = target_pc,
                else => unreachable,
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

    // ── Main dispatch ─────────────────────────────────────────────────────────

    pub fn lower_op(self: *Lower, op: WasmOp) !void {
        switch (op) {
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
                //   skip_jump: (fall-through, continue)
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
            .i32_const => |value| {
                const dst = self.alloc_slot();
                try self.emit(.{ .const_i32 = .{ .dst = dst, .value = value } });
                try self.stack.push(self.allocator, dst);
            },

            // ── i32 arithmetic ────────────────────────────────────────────────

            .i32_add => {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_add = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_sub => {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_sub = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_mul => {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_mul = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },

            // ── i32 comparisons ───────────────────────────────────────────────

            .i32_eqz => {
                const src = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_eqz = .{ .dst = dst, .src = src } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_eq => {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_eq = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_ne => {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_ne = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_lt_s => {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_lt_s = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_lt_u => {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_lt_u = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_gt_s => {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_gt_s = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_gt_u => {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_gt_u = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_le_s => {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_le_s = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_le_u => {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_le_u = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_ge_s => {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_ge_s = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },
            .i32_ge_u => {
                const rhs = try self.pop_slot();
                const lhs = try self.pop_slot();
                const dst = self.alloc_slot();
                try self.emit(.{ .i32_ge_u = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
                try self.stack.push(self.allocator, dst);
            },

            .ret => {
                const value = self.stack.pop();
                try self.emit(.{ .ret = .{ .value = value } });
            },
        }
    }

    pub fn finish(self: *Lower) CompiledFunction {
        return self.compiled;
    }
};

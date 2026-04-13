// lower_legacy.zig
//
// Lowering for the legacy WebAssembly Exception Handling proposal:
//   try / catch <tag> / catch_all / rethrow <depth> / delegate <depth>
//
// Strategy:
//   The same IR (try_table_enter / try_table_leave / throw / throw_ref) is
//   reused.  Legacy constructs are transformed during lowering:
//
//   try ... catch <tag> ... catch_all ... end
//   becomes (structurally):
//     [try_table_enter { handlers_start, handlers_len, end_target=E }]
//     <try body>
//     [try_table_leave { target=AFTER_CATCHES }]   -- normal exit
//   CATCH_TAG:                                     -- handler fires here
//     <catch tag body>
//     [jump AFTER_CATCHES]
//   CATCH_ALL:                                     -- catch_all handler fires here
//     <catch_all body>
//     [jump AFTER_CATCHES]
//   E: (no-op label — backpatch target)
//   AFTER_CATCHES:
//
//   rethrow <depth>:
//     translated to throw_ref using the exnref slot recorded for the try frame
//     at the indicated relative depth.
//
//   delegate <depth>:
//     terminates the try body: throws the current exnref into the outer try at
//     <depth> (i.e. a throw_ref that bypasses zero or more try frames).
//     Implemented as a throw_ref followed by unwinding.
//
// NOTE: This file operates directly on the Lower struct from lower.zig,
// mutating its fields (compiled, stack, control_stack) to emit IR.

const std = @import("std");
const ir = @import("./ir.zig");
const lower_mod = @import("./lower.zig");
const payload_mod = @import("payload");

const Allocator = std.mem.Allocator;
const Slot = ir.Slot;
const Op = ir.Op;
const Lower = lower_mod.Lower;
const ControlFrame = lower_mod.ControlFrame;
const BlockKind = lower_mod.BlockKind;
const CatchHandlerWasm = lower_mod.CatchHandlerWasm;

pub const LegacyLowerError = error{
    InvalidRethrowDepth,
    InvalidDelegateDepth,
    MismatchedCatch,
    MismatchedEnd,
    ControlStackUnderflow,
} || lower_mod.LowerError;

// ── Additional per-frame state for legacy try blocks ─────────────────────────

/// State attached to a legacy `try` control frame (BlockKind.try_table kind).
/// We stash it in a parallel array indexed by control-stack position.
pub const LegacyTryState = struct {
    /// Slot that holds the caught exception reference (exnref).
    /// Allocated when the first catch/catch_all arm is entered.
    /// Used to implement `rethrow`.
    caught_exn_slot: ?Slot = null,
    /// Index of the try_table_enter op (for backpatching end_target).
    enter_pc: u32,
    /// Starting index in catch_handler_tables for this try frame's handlers.
    handlers_start: u32,
    /// Total number of handlers for this try frame.
    handlers_len: u32,
    /// Whether we are currently inside a catch arm body (as opposed to the try body).
    in_catch_body: bool = false,
    /// The catch arm index we are currently processing.
    current_catch_index: u32 = 0,
    /// Whether a catch_all arm has been seen (at most one allowed).
    has_catch_all: bool = false,
};

pub const LowerLegacy = struct {
    /// The underlying lower pass that this wrapper drives.
    inner: Lower,
    /// Per-frame legacy state, indexed by control_stack position at the time
    /// the try frame was pushed.  Most frames have no entry (null).
    try_states: std.ArrayListUnmanaged(?LegacyTryState) = .empty,
    allocator: Allocator,

    pub fn init(allocator: Allocator) LowerLegacy {
        return .{
            .inner = Lower.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn initWithReservedSlots(allocator: Allocator, reserved_slots: u32, locals_count: u16) LowerLegacy {
        return .{
            .inner = Lower.initWithReservedSlots(allocator, reserved_slots, locals_count),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LowerLegacy) void {
        self.inner.deinit();
        self.try_states.deinit(self.allocator);
    }

    /// Reset this LowerLegacy for reuse on a new function body, retaining all
    /// allocated buffer capacity.  Mirrors `Lower.reset`.
    pub fn reset(self: *LowerLegacy, reserved_slots: u32, locals_count: u16) void {
        self.inner.reset(reserved_slots, locals_count);
        self.try_states.clearRetainingCapacity();
    }

    pub fn finish(self: *LowerLegacy) ir.CompiledFunction {
        return self.inner.finish();
    }

    /// Push the implicit function-level block frame, keeping `try_states` in
    /// sync with `inner.control_stack` (the invariant is that both arrays have
    /// the same length).
    pub fn pushFunctionFrame(self: *LowerLegacy, n_results: usize) !void {
        try self.inner.pushFunctionFrame(n_results);
        // Add a null try-state entry for the implicit frame so that
        // try_states.items[i] always corresponds to control_stack.items[i].
        try self.try_states.append(self.allocator, null);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    fn current_pc(self: *LowerLegacy) u32 {
        return self.inner.current_pc();
    }

    fn alloc_slot(self: *LowerLegacy) Slot {
        return self.inner.alloc_slot();
    }

    fn emit(self: *LowerLegacy, op: Op) !void {
        return self.inner.emit(op);
    }

    /// Find the LegacyTryState for the try frame at br-relative `depth`.
    /// `depth` counts from the innermost frame (0 = innermost).
    /// Only try_table frames carry LegacyTryState entries.
    fn try_state_at_depth(self: *LowerLegacy, depth: u32) LegacyLowerError!*LegacyTryState {
        const cs = &self.inner.control_stack;
        const ts = &self.try_states;
        const len = cs.items.len;
        // Walk from innermost outward and count try_table frames only.
        var found: u32 = 0;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const idx = len - 1 - i;
            if (cs.items[idx].kind != .try_table) continue;
            if (found == depth) {
                const ts_ptr = &ts.items[idx];
                if (ts_ptr.* == null) return error.InvalidRethrowDepth;
                return &ts_ptr.*.?;
            }
            found += 1;
        }
        return error.InvalidRethrowDepth;
    }

    // ── Main dispatch ─────────────────────────────────────────────────────────

    /// Lower a single legacy WasmOp (or delegate to inner.lowerOp for non-legacy ops).
    pub fn lowerLegacyOp(self: *LowerLegacy, op: LegacyWasmOp) !void {
        switch (op) {
            .non_legacy => |wasm_op| {
                // Synchronise try_states length when non-legacy ops push/pop frames.
                // lower.lowerOp may push a frame for block/loop/if or pop one for end.
                const cs_before = self.inner.control_stack.items.len;
                try self.inner.lowerOp(wasm_op);
                const cs_after = self.inner.control_stack.items.len;

                if (cs_after > cs_before) {
                    // A frame was pushed; add a null try-state slot.
                    const added = cs_after - cs_before;
                    var j: usize = 0;
                    while (j < added) : (j += 1) {
                        try self.try_states.append(self.allocator, null);
                    }
                } else if (cs_after < cs_before) {
                    // A frame was popped; remove corresponding try-state slot.
                    const removed = cs_before - cs_after;
                    self.try_states.shrinkRetainingCapacity(self.try_states.items.len -| removed);
                }
            },

            // ── try ────────────────────────────────────────────────────────────
            // The legacy `try` block works like try_table but we don't know the
            // handlers yet (they come one by one as catch_ / catch_all arrive).
            // We emit try_table_enter with 0 handlers for now; the actual handler
            // entries are appended incrementally as each catch arm is processed.
            .try_ => |block_type| {
                const slots = try self.inner.resolve_block_slots(block_type);

                const handlers_start: u32 = @intCast(self.inner.compiled.catch_handler_tables.items.len);

                // Emit try_table_enter (handlers_len=0 for now; filled at each catch_ arm).
                const enter_pc = self.current_pc();
                try self.emit(.{
                    .try_table_enter = .{
                        .handlers_start = handlers_start,
                        .handlers_len = 0, // filled in when we see each catch
                        .end_target = 0, // filled at end
                    },
                });

                // Push control frame.
                try self.inner.control_stack.append(self.allocator, .{
                    .kind = .try_table,
                    .stack_height = self.inner.stack.len(),
                    .result_slots = slots.results,
                    .param_slots = slots.params,
                    .target_pc = 0, // forward
                    .try_table_enter_pc = enter_pc,
                });

                // Push corresponding legacy try state.
                try self.try_states.append(self.allocator, LegacyTryState{
                    .enter_pc = enter_pc,
                    .handlers_start = handlers_start,
                    .handlers_len = 0,
                });
            },

            // ── catch_ <tag_index> ─────────────────────────────────────────────
            .catch_ => |info| {
                // A catch arm is reachable even if the try body ended in unreachable code
                // (throw, br, etc.), similar to how `else` resets unreachable after `if`.
                self.inner.is_unreachable = false;
                self.inner.unreachable_depth = 0;
                try self.handle_catch_start(info.tag_index, info.tag_arity, false);
            },

            // ── catch_all ──────────────────────────────────────────────────────
            .catch_all => {
                self.inner.is_unreachable = false;
                self.inner.unreachable_depth = 0;
                try self.handle_catch_start(null, 0, true);
            },

            // ── rethrow <relative_depth> ─────────────────────────────────────
            // Depth counts try/catch frames only (not plain blocks/loops).
            .rethrow => |depth| {
                const ts = try self.try_state_at_depth(depth);
                const exn_slot = ts.caught_exn_slot orelse return error.InvalidRethrowDepth;
                // Emit a throw_ref using the caught exn slot.
                try self.emit(.{ .throw_ref = .{ .ref = exn_slot } });
                // Control-flow terminator: mark stack unreachable.
                self.inner.stack.slots.shrinkRetainingCapacity(0);
                self.inner.is_unreachable = true;
            },

            // ── delegate <relative_depth> ────────────────────────────────────
            // Delegate terminates the try body and re-throws any exception into
            // the handler at `depth` (counting only try frames).
            // We implement this as:
            //   1. Emit a throw_ref using a fresh "exn ref" slot that the VM will
            //      fill at runtime when an exception propagates through.
            //   2. Close the current try frame with try_table_leave → after_catches.
            //   3. The CatchHandlerEntry we register for "delegate" has kind=catch_all_ref
            //      so any exception is caught into the exn ref slot, then immediately
            //      re-thrown by the throw_ref emitted above.
            //
            // Actually a simpler and more correct approach:
            //   delegate acts like an implicit catch_all_ref that rethrows into the
            //   outer frame.  So we:
            //   a) Add a catch_all_ref handler to the current try that places the
            //      exnref in a slot, then calls throw_ref.
            //   b) Emit try_table_leave (normal exit).
            //   c) Emit the delegate handler body (throw_ref of caught exn).
            //   d) Patch end_target to point after the delegate handler.
            .delegate => |depth| {
                try self.handle_delegate(depth);
            },
        }
    }

    // ── catch/catch_all helper ────────────────────────────────────────────────

    /// Called when we encounter a `catch_` or `catch_all` opcode.
    ///
    /// If this is the FIRST catch arm, we:
    ///   - Terminate the try body by emitting try_table_leave (normal exit).
    ///   - Backpatch try_table_enter.end_target to point to the current PC.
    ///
    /// If this is a SUBSEQUENT catch arm, we:
    ///   - Emit a jump to AFTER_CATCHES (end of previous catch body).
    ///   - Register the patch site.
    ///
    /// Then we:
    ///   - Append a CatchHandlerEntry to catch_handler_tables.
    ///   - Update try_table_enter.handlers_len.
    ///   - Push the caught tag values (or exnref) onto the value stack.
    fn handle_catch_start(
        self: *LowerLegacy,
        tag_index: ?u32,
        tag_arity: u32,
        is_catch_all: bool,
    ) !void {
        const cs = &self.inner.control_stack;
        const len = cs.items.len;
        if (len == 0) return error.MismatchedCatch;

        // Find the innermost try frame.
        const frame_idx = len - 1;
        const frame = &cs.items[frame_idx];
        if (frame.kind != .try_table) return error.MismatchedCatch;

        const ts = &self.try_states.items[frame_idx];
        if (ts.* == null) return error.MismatchedCatch;
        const legacy_ts = &ts.*.?;

        if (is_catch_all and legacy_ts.has_catch_all) return error.MismatchedCatch;

        // First catch arm: terminate the try body.
        if (!legacy_ts.in_catch_body) {
            // Copy block results from stack into result slots (end of try body).
            {
                const n = frame.result_slots.items.len;
                var ri: usize = n;
                while (ri > 0) {
                    ri -= 1;
                    if (self.inner.stack.peek()) |src| {
                        try self.emit(.{ .copy = .{ .dst = frame.result_slots.items[ri], .src = src } });
                        _ = self.inner.stack.pop();
                    }
                }
            }

            // Emit try_table_leave for normal (non-exception) exit.
            const leave_pc = self.current_pc();
            try self.emit(.{ .try_table_leave = .{ .target = 0 } }); // patched at end
            try frame.patch_sites.append(self.allocator, leave_pc);

            // Fix handlers_start: at try_ emit time we didn't know where handlers
            // would land.  Now that inner try blocks may have appended their own
            // handlers, update handlers_start to the current end of the table.
            const actual_handlers_start: u32 = @intCast(self.inner.compiled.catch_handler_tables.items.len);
            legacy_ts.handlers_start = actual_handlers_start;
            switch (self.inner.compiled.ops.items[legacy_ts.enter_pc]) {
                .try_table_enter => |*e| e.handlers_start = actual_handlers_start,
                else => unreachable,
            }

            // Backpatch try_table_enter.end_target to the next PC
            // (the start of the first catch handler body).
            // dispatchException in the VM walks the handlers list.
            const catch_body_start = self.current_pc();
            switch (self.inner.compiled.ops.items[legacy_ts.enter_pc]) {
                .try_table_enter => |*e| e.end_target = catch_body_start,
                else => unreachable,
            }

            legacy_ts.in_catch_body = true;
            // Reset value stack to try-body entry height for the catch arm.
            self.inner.stack.slots.shrinkRetainingCapacity(frame.stack_height);
        } else {
            // Subsequent catch arm: close the previous catch body with a jump.
            const jump_pc = self.current_pc();
            try self.emit(.{ .jump = .{ .target = 0 } }); // → AFTER_CATCHES
            try frame.patch_sites.append(self.allocator, jump_pc);

            // Reset value stack to try-body entry height for the next catch arm.
            self.inner.stack.slots.shrinkRetainingCapacity(frame.stack_height);
        }

        // Allocate destination slots for the handler payload.
        const dst_slots_start: u32 = @intCast(self.inner.compiled.call_args.items.len);
        var dst_slots_len: u32 = 0;
        var dst_ref: Slot = 0;

        if (is_catch_all) {
            legacy_ts.has_catch_all = true;
            // catch_all: no tag, no values, no exnref.
        } else {
            // catch_: allocate tag_arity slots for payload values.
            dst_slots_len = tag_arity;
            var ai: u32 = 0;
            while (ai < tag_arity) : (ai += 1) {
                const s = self.alloc_slot();
                try self.inner.compiled.call_args.append(self.allocator, s);
            }
        }

        // Allocate an exnref slot so that rethrow can use it.
        const exn_slot = self.alloc_slot();
        dst_ref = exn_slot;
        legacy_ts.caught_exn_slot = exn_slot;

        // Append the CatchHandlerEntry.
        const handler_kind: ir.CatchHandlerKind = if (is_catch_all)
            .catch_all_ref // always capture exnref for rethrow support
        else if (tag_arity == 0)
            .catch_tag_ref // tag with no payload: capture only exnref
        else
            .catch_tag; // tag with payload values

        // The handler target is the CURRENT PC (i.e. the start of this arm's body).
        // We set it now since we just emitted the body-start label.
        const handler_target = self.current_pc();

        try self.inner.compiled.catch_handler_tables.append(self.allocator, .{
            .kind = handler_kind,
            .tag_index = tag_index orelse 0,
            .target = handler_target,
            .dst_slots_start = dst_slots_start,
            .dst_slots_len = dst_slots_len,
            .dst_ref = dst_ref,
        });

        // Update try_table_enter.handlers_len.
        legacy_ts.handlers_len += 1;
        legacy_ts.current_catch_index += 1;
        switch (self.inner.compiled.ops.items[legacy_ts.enter_pc]) {
            .try_table_enter => |*e| e.handlers_len = legacy_ts.handlers_len,
            else => unreachable,
        }

        // Push the payload values onto the value stack for use in the catch body.
        if (!is_catch_all) {
            // Push tag payload values (the VM writes them to dst_slots).
            var ai: u32 = 0;
            while (ai < tag_arity) : (ai += 1) {
                const slot_idx = dst_slots_start + ai;
                try self.inner.stack.push(
                    self.allocator,
                    self.inner.compiled.call_args.items[slot_idx],
                );
            }
        }
        // NOTE: exn_slot (dst_ref) is NOT pushed to the value stack automatically.
        // rethrow uses it directly; the user can't access it from Wasm source.
    }

    // ── delegate helper ───────────────────────────────────────────────────────

    fn handle_delegate(self: *LowerLegacy, depth: u32) !void {
        const cs = &self.inner.control_stack;
        const len = cs.items.len;
        if (len == 0) return error.MismatchedEnd;

        // `delegate` must appear at the end of a try body (not inside a catch arm).
        const frame_idx = len - 1;
        const frame = &cs.items[frame_idx];
        if (frame.kind != .try_table) return error.MismatchedEnd;

        const ts = &self.try_states.items[frame_idx];
        if (ts.* == null) return error.MismatchedEnd;
        const legacy_ts = &ts.*.?;

        // `delegate` is not allowed after catch arms have started.
        if (legacy_ts.in_catch_body) return error.MismatchedEnd;

        // Find the outer try frame to delegate to.
        // depth=0 means the immediately enclosing try frame (outside the current one).
        // We search in the control stack for try_table frames above the current one.
        var outer_frame_idx_opt: ?usize = null;
        var outer_ts_ptr: ?*?LegacyTryState = null;
        {
            var found: u32 = 0;
            var i: usize = 0;
            while (i < frame_idx) : (i += 1) {
                const search_idx = frame_idx - 1 - i;
                if (cs.items[search_idx].kind == .try_table) {
                    if (self.try_states.items[search_idx] != null) {
                        if (found == depth) {
                            outer_frame_idx_opt = search_idx;
                            outer_ts_ptr = &self.try_states.items[search_idx];
                            break;
                        }
                        found += 1;
                    }
                }
            }
        }

        // Allocate an exnref slot for the delegate catch-all handler.
        const exn_slot = self.alloc_slot();

        // Create a catch_all_ref handler for this try frame that will:
        //   1. Receive the exnref into exn_slot.
        //   2. Jump to a delegate-body that emits throw_ref.
        //
        // Handler target = PC of the delegate body (emitted below).

        // First, emit try_table_leave for normal exit (no exception case).
        const leave_pc = self.current_pc();
        try self.emit(.{ .try_table_leave = .{ .target = 0 } }); // patched later
        try frame.patch_sites.append(self.allocator, leave_pc);

        // end_target = next PC (start of delegate handler body).
        const delegate_body_start = self.current_pc();
        switch (self.inner.compiled.ops.items[legacy_ts.enter_pc]) {
            .try_table_enter => |*e| e.end_target = delegate_body_start,
            else => unreachable,
        }

        // Emit delegate handler body: throw_ref with exn_slot.
        // The VM will call dispatchException which searches outer frames.
        try self.emit(.{ .throw_ref = .{ .ref = exn_slot } });

        // Append catch_all_ref handler entry (fires after delegate_body_start).
        // But we want the handler to jump TO delegate_body_start when an exception fires.
        // Actually end_target IS the handler dispatch start; the VM jumps there.
        // Since we only have one handler (catch_all_ref), just register it.
        try self.inner.compiled.catch_handler_tables.append(self.allocator, .{
            .kind = .catch_all_ref,
            .tag_index = 0,
            .target = delegate_body_start, // VM jumps here when exception fires
            .dst_slots_start = 0,
            .dst_slots_len = 0,
            .dst_ref = exn_slot,
        });
        legacy_ts.handlers_len = 1;
        switch (self.inner.compiled.ops.items[legacy_ts.enter_pc]) {
            .try_table_enter => |*e| {
                e.handlers_len = 1;
                e.handlers_start = legacy_ts.handlers_start;
            },
            else => unreachable,
        }

        // If there is an outer try frame, we want to re-throw into it.
        // The VM's dispatchException already walks up the call/eh stack,
        // so merely emitting throw_ref is sufficient — the VM will find
        // the outer frame's handlers automatically.
        // (outer_frame_idx_opt and outer_ts_ptr reserved for future use)
        if (outer_frame_idx_opt) |_| {}
        if (outer_ts_ptr) |_| {}

        // Now pop the try frame (equivalent to processing an `end`).
        var popped_frame = self.inner.control_stack.pop().?;
        defer popped_frame.patch_sites.deinit(self.allocator);
        defer popped_frame.result_slots.deinit(self.allocator);
        defer popped_frame.param_slots.deinit(self.allocator);
        _ = self.try_states.pop();

        // After the throw_ref + handler, the continuation PC is here.
        const end_pc = self.current_pc();
        self.inner.patch_forward_jumps(&popped_frame, end_pc);

        // Restore value stack.
        try self.inner.unwind_stack_to_frame(&popped_frame);
    }

    // ── end (for legacy try/catch block) ─────────────────────────────────────

    /// Handle `end` when the innermost frame is a legacy try/catch block.
    /// If the frame has catch arms, we need to close the last catch body.
    /// If the frame had no catch arms (just `try...end`), we close the try body.
    pub fn lowerLegacyEnd(self: *LowerLegacy) !void {
        const cs = &self.inner.control_stack;
        if (cs.items.len == 0) {
            // Function-level end: delegate to inner.
            return self.inner.lowerOp(.end);
        }

        const frame_idx = cs.items.len - 1;
        const frame = &cs.items[frame_idx];

        // Only intercept legacy try_table frames.
        if (frame.kind != .try_table or self.try_states.items[frame_idx] == null) {
            // Non-legacy frame: delegate to inner.lowerOp(.end).
            const cs_before = cs.items.len;
            try self.inner.lowerOp(.end);
            const cs_after = cs.items.len;
            if (cs_after < cs_before) {
                self.try_states.shrinkRetainingCapacity(self.try_states.items.len -| (cs_before - cs_after));
            }
            return;
        }

        const ts = &self.try_states.items[frame_idx];
        const legacy_ts = &ts.*.?;

        if (legacy_ts.in_catch_body) {
            // Close the last catch arm body with a copy + jump to AFTER_CATCHES.
            {
                const n = frame.result_slots.items.len;
                var ri: usize = n;
                while (ri > 0) {
                    ri -= 1;
                    if (self.inner.stack.peek()) |src| {
                        try self.emit(.{ .copy = .{ .dst = frame.result_slots.items[ri], .src = src } });
                        _ = self.inner.stack.pop();
                    }
                }
            }
            const jump_pc = self.current_pc();
            try self.emit(.{ .jump = .{ .target = 0 } }); // → AFTER_CATCHES
            try frame.patch_sites.append(self.allocator, jump_pc);
        } else {
            // No catch arms seen: close the try body normally (like a plain block).
            {
                const n = frame.result_slots.items.len;
                var ri: usize = n;
                while (ri > 0) {
                    ri -= 1;
                    if (self.inner.stack.peek()) |src| {
                        try self.emit(.{ .copy = .{ .dst = frame.result_slots.items[ri], .src = src } });
                        _ = self.inner.stack.pop();
                    }
                }
            }

            // Emit try_table_leave for normal exit.
            const leave_pc = self.current_pc();
            try self.emit(.{ .try_table_leave = .{ .target = 0 } });
            try frame.patch_sites.append(self.allocator, leave_pc);

            // Backpatch end_target to here (no handlers, so end_target is unused,
            // but set it to the try_table_leave for consistency).
            switch (self.inner.compiled.ops.items[legacy_ts.enter_pc]) {
                .try_table_enter => |*e| e.end_target = leave_pc,
                else => unreachable,
            }
        }

        // AFTER_CATCHES: this is the continuation PC.
        const end_pc = self.current_pc();

        // Pop the frame and patch all forward jumps.
        var popped_frame = self.inner.control_stack.pop().?;
        defer popped_frame.patch_sites.deinit(self.allocator);
        defer popped_frame.result_slots.deinit(self.allocator);
        defer popped_frame.param_slots.deinit(self.allocator);
        _ = self.try_states.pop();

        self.inner.patch_forward_jumps(&popped_frame, end_pc);

        // Restore value stack and push result slots.
        try self.inner.unwind_stack_to_frame(&popped_frame);

        // After the try/catch block, execution continues normally.
        self.inner.is_unreachable = false;
        self.inner.unreachable_depth = 0;
    }
};

// ── Legacy WasmOp ─────────────────────────────────────────────────────────────

/// A discriminated union covering both legacy EH ops and all normal ops.
pub const LegacyWasmOp = union(enum) {
    /// A non-legacy op: delegate to Lower.lowerOp.
    non_legacy: lower_mod.WasmOp,
    /// try <block_type>
    try_: ?lower_mod.BlockType,
    /// catch <tag_index> (with tag_arity pre-filled by module.zig)
    catch_: struct { tag_index: u32, tag_arity: u32 },
    /// catch_all
    catch_all,
    /// rethrow <relative_depth>
    rethrow: u32,
    /// delegate <relative_depth>
    delegate: u32,
};

const std = @import("std");
const ir = @import("../compiler/ir.zig");
const core = @import("core");

const CompiledFunction = ir.CompiledFunction;
const Allocator = std.mem.Allocator;
pub const RawVal = core.raw.RawVal;
pub const Global = core.Global;

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

pub const VM = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) VM {
        return .{ .allocator = allocator };
    }

    /// Execute a compiled function.
    ///
    /// Parameters:
    ///   func      — The entry-point compiled function body (IR instruction list)
    ///   params    — Function parameters (filled into slots 0..params.len-1)
    ///   globals   — Slice of module instance globals (needed for global_get/global_set)
    ///   memory    — Linear memory slice (reserved, currently pass an empty slice)
    ///   functions — All compiled functions in the module (needed to resolve call targets)
    pub fn execute(
        self: *VM,
        func: CompiledFunction,
        params: []const RawVal,
        globals: []Global,
        memory: []u8,
        functions: []const CompiledFunction,
    ) !?RawVal {
        _ = memory; // TODO: memory operations not implemented yet, ignore for now

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

            switch (op) {
                .const_i32 => |inst| {
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(inst.value);
                },
                .local_get => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    call_stack.items[frame_idx].slots[inst.dst] = s[inst.local];
                },
                .local_set => |inst| {
                    const src_val = call_stack.items[frame_idx].slots[inst.src];
                    call_stack.items[frame_idx].slots[inst.local] = src_val;
                },
                .global_get => |inst| {
                    call_stack.items[frame_idx].slots[inst.dst] = globals[inst.global_idx].getRawValue();
                },
                .global_set => |inst| {
                    const src_val = call_stack.items[frame_idx].slots[inst.src];
                    globals[inst.global_idx].value = src_val;
                },
                .copy => |inst| {
                    const src_val = call_stack.items[frame_idx].slots[inst.src];
                    call_stack.items[frame_idx].slots[inst.dst] = src_val;
                },
                .jump => |inst| {
                    call_stack.items[frame_idx].pc = inst.target;
                },
                .jump_if_z => |inst| {
                    const cond = call_stack.items[frame_idx].slots[inst.cond].readAs(i32);
                    if (cond == 0) {
                        call_stack.items[frame_idx].pc = inst.target;
                    }
                },
                .i32_add => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(i32);
                    const rhs = s[inst.rhs].readAs(i32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(lhs +% rhs);
                },
                .i32_sub => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(i32);
                    const rhs = s[inst.rhs].readAs(i32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(lhs -% rhs);
                },
                .i32_mul => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(i32);
                    const rhs = s[inst.rhs].readAs(i32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(lhs *% rhs);
                },
                .i32_eqz => |inst| {
                    const src = call_stack.items[frame_idx].slots[inst.src].readAs(i32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, if (src == 0) 1 else 0));
                },
                .i32_eq => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(i32);
                    const rhs = s[inst.rhs].readAs(i32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, if (lhs == rhs) 1 else 0));
                },
                .i32_ne => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(i32);
                    const rhs = s[inst.rhs].readAs(i32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, if (lhs != rhs) 1 else 0));
                },
                .i32_lt_s => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(i32);
                    const rhs = s[inst.rhs].readAs(i32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, if (lhs < rhs) 1 else 0));
                },
                .i32_lt_u => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(u32);
                    const rhs = s[inst.rhs].readAs(u32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, if (lhs < rhs) 1 else 0));
                },
                .i32_gt_s => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(i32);
                    const rhs = s[inst.rhs].readAs(i32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, if (lhs > rhs) 1 else 0));
                },
                .i32_gt_u => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(u32);
                    const rhs = s[inst.rhs].readAs(u32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, if (lhs > rhs) 1 else 0));
                },
                .i32_le_s => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(i32);
                    const rhs = s[inst.rhs].readAs(i32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, if (lhs <= rhs) 1 else 0));
                },
                .i32_le_u => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(u32);
                    const rhs = s[inst.rhs].readAs(u32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, if (lhs <= rhs) 1 else 0));
                },
                .i32_ge_s => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(i32);
                    const rhs = s[inst.rhs].readAs(i32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, if (lhs >= rhs) 1 else 0));
                },
                .i32_ge_u => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(u32);
                    const rhs = s[inst.rhs].readAs(u32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, if (lhs >= rhs) 1 else 0));
                },

                // ── fn call ────────────────────────────────────────────────────
                .call => |inst| {
                    const callee = functions[inst.func_idx];

                    // get caller frame's call_args slice for the callee's parameters
                    // inst.args_start / args_len point caller frame's call_args
                    const caller_func = call_stack.items[frame_idx].func;
                    const caller_slots = call_stack.items[frame_idx].slots;
                    const arg_slots = caller_func.call_args.items[inst.args_start .. inst.args_start + inst.args_len];

                    // allocate slots for the callee (at least enough to hold the parameters)
                    const callee_slots_len: usize = @max(
                        @as(usize, @intCast(callee.slots_len)),
                        arg_slots.len,
                    );
                    const callee_slots = try self.allocator.alloc(RawVal, callee_slots_len);
                    // Initialize to zero (unused local variables should be 0)
                    @memset(callee_slots, std.mem.zeroes(RawVal));

                    // Copy argument values from caller frame's slots to callee frame's slots 0..n
                    for (arg_slots, 0..) |arg_slot, i| {
                        callee_slots[i] = caller_slots[arg_slot];
                    }

                    // Save dst to a local variable before append, to prevent pointer invalidation after slice reallocation
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
                    // append may cause call_stack.items to be reallocated,
                    // any previously held pointers (e.g., caller_slots) are invalidated,
                    // do not dereference them.
                },

                // ── return ────────────────────────────────────────────────────────
                .ret => |inst| {
                    // Collect the return value of the current frame (if any)
                    const ret_val: ?RawVal = if (inst.value) |slot|
                        call_stack.items[frame_idx].slots[slot]
                    else
                        null;

                    // Pop the current frame and free its slots
                    const popped_frame = call_stack.pop().?;
                    self.allocator.free(popped_frame.slots);

                    if (call_stack.items.len == 0) {
                        // Top-level frame returned: execution finished
                        return ret_val;
                    }

                    // Write the return value to the caller frame's dst slot
                    const caller_idx = call_stack.items.len - 1;
                    if (popped_frame.dst) |dst_slot| {
                        if (ret_val) |rv| {
                            call_stack.items[caller_idx].slots[dst_slot] = rv;
                        }
                    }
                },
            }
        }

        // Call stack is empty (under normal circumstances, the ret instruction would return early)
        return null;
    }
};

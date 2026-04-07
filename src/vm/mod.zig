const std = @import("std");
const ir = @import("../compiler/ir.zig");
const core = @import("core");
const host_mod = @import("../wasmz/host.zig");

const CompiledFunction = ir.CompiledFunction;
const Allocator = std.mem.Allocator;
pub const RawVal = core.raw.RawVal;
pub const Global = core.Global;
pub const Trap = core.Trap;
pub const TrapCode = core.TrapCode;
pub const HostFunc = host_mod.HostFunc;

/// VM execute result either be void or Wasm trap
/// Allocation failures and other host environment errors are still propagated through Zig error unions (Allocator.Error).
pub const ExecResult = union(enum) {
    /// Normal return, ?RawVal is null for void functions
    ok: ?RawVal,
    /// Runtime trap (MemoryOutOfBounds, UnreachableCodeReached, etc.)
    trap: Trap,
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

pub const VM = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) VM {
        return .{ .allocator = allocator };
    }

    /// Execute a compiled function.
    ///
    /// Parameters:
    ///   func       — The entry-point compiled function body (IR instruction list)
    ///   params     — Function parameters (filled into slots 0..params.len-1)
    ///   globals    — Slice of module instance globals (needed for global_get/global_set)
    ///   memory     — Linear memory slice (byte array; null means the module has no memory)
    ///   functions  — All compiled functions in the module (needed to resolve call targets)
    ///   host_funcs — Host-provided functions for imported function slots (index matches Wasm func_idx;
    ///                length == number of imported functions, same as Module.imported_funcs.len)
    ///
    /// Returns:
    ///   Allocator.Error  — Host memory allocation failure (not a Wasm trap)
    ///   ExecResult.ok    — Normal execution completed, with optional return value
    ///   ExecResult.trap  — Wasm runtime trap, with TrapCode and description
    pub fn execute(
        self: *VM,
        func: CompiledFunction,
        params: []const RawVal,
        globals: []Global,
        memory: []u8,
        functions: []const CompiledFunction,
        host_funcs: []const HostFunc,
    ) Allocator.Error!ExecResult {
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
                .unreachable_ => {
                    return .{ .trap = Trap.fromTrapCode(.UnreachableCodeReached) };
                },
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
                .i32_div_s => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(i32);
                    const rhs = s[inst.rhs].readAs(i32);
                    if (rhs == 0) return .{ .trap = Trap.fromTrapCode(.IntegerDivisionByZero) };
                    if (lhs == std.math.minInt(i32) and rhs == -1) return .{ .trap = Trap.fromTrapCode(.IntegerOverflow) };
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@divTrunc(lhs, rhs));
                },
                .i32_div_u => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(u32);
                    const rhs = s[inst.rhs].readAs(u32);
                    if (rhs == 0) return .{ .trap = Trap.fromTrapCode(.IntegerDivisionByZero) };
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, @bitCast(lhs / rhs)));
                },
                .i32_rem_s => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(i32);
                    const rhs = s[inst.rhs].readAs(i32);
                    if (rhs == 0) return .{ .trap = Trap.fromTrapCode(.IntegerDivisionByZero) };
                    // INT_MIN % -1 == 0 per Wasm spec (no trap)
                    if (lhs == std.math.minInt(i32) and rhs == -1) {
                        call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, 0));
                    } else {
                        call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@rem(lhs, rhs));
                    }
                },
                .i32_rem_u => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(u32);
                    const rhs = s[inst.rhs].readAs(u32);
                    if (rhs == 0) return .{ .trap = Trap.fromTrapCode(.IntegerDivisionByZero) };
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, @bitCast(lhs % rhs)));
                },
                .i32_and => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(i32);
                    const rhs = s[inst.rhs].readAs(i32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(lhs & rhs);
                },
                .i32_or => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(i32);
                    const rhs = s[inst.rhs].readAs(i32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(lhs | rhs);
                },
                .i32_xor => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(i32);
                    const rhs = s[inst.rhs].readAs(i32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(lhs ^ rhs);
                },
                .i32_shl => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(i32);
                    const rhs = s[inst.rhs].readAs(i32);
                    const shift: u5 = @intCast(@as(u32, @bitCast(rhs)) & 0x1f);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(lhs << shift);
                },
                .i32_shr_s => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(i32);
                    const rhs = s[inst.rhs].readAs(i32);
                    const shift: u5 = @intCast(@as(u32, @bitCast(rhs)) & 0x1f);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(lhs >> shift);
                },
                .i32_shr_u => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(u32);
                    const rhs = s[inst.rhs].readAs(u32);
                    const shift: u5 = @intCast(rhs & 0x1f);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, @bitCast(lhs >> shift)));
                },
                .i32_rotl => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(u32);
                    const rhs = s[inst.rhs].readAs(u32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, @bitCast(std.math.rotl(u32, lhs, rhs & 0x1f))));
                },
                .i32_rotr => |inst| {
                    const s = call_stack.items[frame_idx].slots;
                    const lhs = s[inst.lhs].readAs(u32);
                    const rhs = s[inst.rhs].readAs(u32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, @bitCast(std.math.rotr(u32, lhs, rhs & 0x1f))));
                },
                .i32_clz => |inst| {
                    const src = call_stack.items[frame_idx].slots[inst.src].readAs(u32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, @intCast(@clz(src))));
                },
                .i32_ctz => |inst| {
                    const src = call_stack.items[frame_idx].slots[inst.src].readAs(u32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, @intCast(@ctz(src))));
                },
                .i32_popcnt => |inst| {
                    const src = call_stack.items[frame_idx].slots[inst.src].readAs(u32);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, @intCast(@popCount(src))));
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
                    // Collect the argument values from the current (caller) frame.
                    const caller_func = call_stack.items[frame_idx].func;
                    const caller_slots = call_stack.items[frame_idx].slots;
                    const arg_slots = caller_func.call_args.items[inst.args_start .. inst.args_start + inst.args_len];

                    if (inst.func_idx < host_funcs.len) {
                        // ── Host function call ──────────────────────────────
                        // Collect params into a temporary slice, call the host function,
                        // and write the result (if any) back to the caller frame's dst slot.
                        const host_params = try self.allocator.alloc(RawVal, arg_slots.len);
                        defer self.allocator.free(host_params);
                        for (arg_slots, 0..) |arg_slot, i| {
                            host_params[i] = caller_slots[arg_slot];
                        }

                        const host_result = try host_funcs[inst.func_idx].call(host_params, self.allocator);
                        switch (host_result) {
                            .trap => |t| return .{ .trap = t },
                            .ok => |ret_val| {
                                if (inst.dst) |dst_slot| {
                                    if (ret_val) |rv| {
                                        call_stack.items[frame_idx].slots[dst_slot] = rv;
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

                        // Copy argument values from caller frame's slots to callee frame's slots 0..n.
                        for (arg_slots, 0..) |arg_slot, i| {
                            callee_slots[i] = caller_slots[arg_slot];
                        }

                        // Save dst to a local variable before append, to prevent pointer invalidation after slice reallocation.
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
                    }
                },

                // ── Memory load ──────────────────────────────────────────────────────────

                .i32_load => |inst| {
                    const base: u32 = call_stack.items[frame_idx].slots[inst.addr].readAs(u32);
                    const ea = base +% inst.offset;
                    if (@as(usize, ea) + 4 > memory.len) return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    const val = std.mem.readInt(i32, memory[ea..][0..4], .little);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(val);
                },
                .i32_load8_s => |inst| {
                    const base: u32 = call_stack.items[frame_idx].slots[inst.addr].readAs(u32);
                    const ea = base +% inst.offset;
                    if (@as(usize, ea) + 1 > memory.len) return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    const byte: i8 = @bitCast(memory[ea]);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, byte));
                },
                .i32_load8_u => |inst| {
                    const base: u32 = call_stack.items[frame_idx].slots[inst.addr].readAs(u32);
                    const ea = base +% inst.offset;
                    if (@as(usize, ea) + 1 > memory.len) return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    const byte: u8 = memory[ea];
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, byte));
                },
                .i32_load16_s => |inst| {
                    const base: u32 = call_stack.items[frame_idx].slots[inst.addr].readAs(u32);
                    const ea = base +% inst.offset;
                    if (@as(usize, ea) + 2 > memory.len) return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    const half: i16 = @bitCast(std.mem.readInt(u16, memory[ea..][0..2], .little));
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, half));
                },
                .i32_load16_u => |inst| {
                    const base: u32 = call_stack.items[frame_idx].slots[inst.addr].readAs(u32);
                    const ea = base +% inst.offset;
                    if (@as(usize, ea) + 2 > memory.len) return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    const half: u16 = std.mem.readInt(u16, memory[ea..][0..2], .little);
                    call_stack.items[frame_idx].slots[inst.dst] = RawVal.from(@as(i32, half));
                },

                // ── Memory store ─────────────────────────────────────────────────────────

                .i32_store => |inst| {
                    const base: u32 = call_stack.items[frame_idx].slots[inst.addr].readAs(u32);
                    const ea = base +% inst.offset;
                    if (@as(usize, ea) + 4 > memory.len) return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    const val = call_stack.items[frame_idx].slots[inst.src].readAs(i32);
                    std.mem.writeInt(i32, memory[ea..][0..4], val, .little);
                },
                .i32_store8 => |inst| {
                    const base: u32 = call_stack.items[frame_idx].slots[inst.addr].readAs(u32);
                    const ea = base +% inst.offset;
                    if (@as(usize, ea) + 1 > memory.len) return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    const val = call_stack.items[frame_idx].slots[inst.src].readAs(i32);
                    memory[ea] = @truncate(@as(u32, @bitCast(val)));
                },
                .i32_store16 => |inst| {
                    const base: u32 = call_stack.items[frame_idx].slots[inst.addr].readAs(u32);
                    const ea = base +% inst.offset;
                    if (@as(usize, ea) + 2 > memory.len) return .{ .trap = Trap.fromTrapCode(.MemoryOutOfBounds) };
                    const val = call_stack.items[frame_idx].slots[inst.src].readAs(i32);
                    std.mem.writeInt(u16, memory[ea..][0..2], @truncate(@as(u32, @bitCast(val))), .little);
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
                        return .{ .ok = ret_val };
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

        return .{ .ok = null };
    }
};

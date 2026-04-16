pub const ops = @import("ops.zig");
pub const size = @import("size.zig");
pub const table = @import("table.zig");
pub const handlers = @import("handlers.zig");

pub const HandlerTable = table.HandlerTable;
pub const Handler = table.Handler;

const std = @import("std");
const ir = @import("../ir.zig");
const dispatch = @import("../../vm/dispatch.zig");

const Allocator = std.mem.Allocator;
const Op = ir.Op;
const Slot = ir.Slot;
const CompiledFunction = ir.CompiledFunction;
const EncodedFunction = ir.EncodedFunction;
const CatchHandlerEntry = ir.CatchHandlerEntry;
const HANDLER_SIZE = dispatch.HANDLER_SIZE;

pub inline fn readInlineArgs(comptime OpsT: type, ip: [*]u8, args_len: u32) []align(1) const Slot {
    const offset = HANDLER_SIZE + @sizeOf(OpsT);
    const ptr: [*]align(1) const Slot = @ptrCast(ip + offset);
    return ptr[0..args_len];
}

pub inline fn varStride(comptime OpsT: type, args_len: u32) usize {
    return HANDLER_SIZE + @sizeOf(OpsT) + @as(usize, args_len) * @sizeOf(Slot);
}

pub fn instrSize(op: Op) usize {
    return size.instrSize(op);
}

fn writeInlineArgs(ops_ptr: [*]u8, comptime OpsT: type, call_args: []const Slot, args_start: u32, args_len: u32) void {
    const base: [*]align(1) Slot = @ptrCast(ops_ptr + @sizeOf(OpsT));
    for (0..args_len) |j| {
        base[j] = call_args[args_start + j];
    }
}

inline fn writeOps(comptime T: type, ptr: [*]u8, value: T) void {
    @setEvalBranchQuota(4000);
    std.mem.bytesAsValue(T, ptr[0..@sizeOf(T)]).* = value;
}

pub fn encode(
    allocator: Allocator,
    cf: *CompiledFunction,
    handlers_ptr: *const HandlerTable,
) Allocator.Error!EncodedFunction {
    const ops_list = cf.ops.items;
    const n_ops = ops_list.len;

    const op_offset = try allocator.alloc(u32, n_ops + 1);
    defer allocator.free(op_offset);

    {
        var off: u32 = 0;
        for (ops_list, 0..) |op, i| {
            op_offset[i] = off;
            off += @intCast(instrSize(op));
        }
        op_offset[n_ops] = off;
    }

    const code_len = op_offset[n_ops];

    const code = try allocator.alignedAlloc(u8, .@"8", code_len);
    errdefer allocator.free(code);

    for (ops_list, 0..) |op, i| {
        const base = op_offset[i];
        const ptr = code.ptr + base;

        const h: Handler = handlers.handlerFor(op, handlers_ptr);
        std.mem.bytesAsValue(Handler, ptr[0..@sizeOf(Handler)]).* = h;

        const ops_ptr = ptr + HANDLER_SIZE;

        switch (op) {
            .unreachable_ => {},
            .const_i32 => |inst| {
                writeOps(ops.OpsConstI32, ops_ptr, .{
                    .dst = inst.dst,
                    .value = inst.value,
                });
            },
            .const_i64 => |inst| {
                writeOps(ops.OpsConstI64, ops_ptr, .{
                    .dst = inst.dst,
                    .value = inst.value,
                });
            },
            .const_f32 => |inst| {
                writeOps(ops.OpsConstF32, ops_ptr, .{
                    .dst = inst.dst,
                    .value = inst.value,
                });
            },
            .const_f64 => |inst| {
                writeOps(ops.OpsConstF64, ops_ptr, .{
                    .dst = inst.dst,
                    .value = inst.value,
                });
            },
            .const_v128 => |inst| {
                writeOps(ops.OpsConstV128, ops_ptr, .{
                    .dst = inst.dst,
                    .value = @bitCast(inst.value),
                });
            },
            .const_ref_null => |inst| {
                writeOps(ops.OpsDst, ops_ptr, .{ .dst = inst.dst });
            },
            .ref_is_null => |inst| {
                writeOps(ops.OpsDstSrc, ops_ptr, .{ .dst = inst.dst, .src = inst.src });
            },
            .ref_func => |inst| {
                writeOps(ops.OpsRefFunc, ops_ptr, .{ .dst = inst.dst, .func_idx = inst.func_idx });
            },
            .ref_eq => |inst| {
                writeOps(ops.OpsDstLhsRhs, ops_ptr, .{ .dst = inst.dst, .lhs = inst.lhs, .rhs = inst.rhs });
            },
            .local_get => |inst| {
                writeOps(ops.OpsLocalGet, ops_ptr, .{ .dst = inst.dst, .local = inst.local });
            },
            .local_set => |inst| {
                writeOps(ops.OpsLocalSet, ops_ptr, .{ .local = inst.local, .src = inst.src });
            },
            .global_get => |inst| {
                writeOps(ops.OpsGlobalGet, ops_ptr, .{ .dst = inst.dst, .global_idx = inst.global_idx });
            },
            .global_set => |inst| {
                writeOps(ops.OpsGlobalSet, ops_ptr, .{ .src = inst.src, .global_idx = inst.global_idx });
            },
            .copy => |inst| {
                writeOps(ops.OpsCopy, ops_ptr, .{ .dst = inst.dst, .src = inst.src });
            },
            .copy_jump_if_nz => |inst| {
                writeOps(ops.OpsCopyJumpIfNz, ops_ptr, .{
                    .dst = inst.dst,
                    .src = inst.src,
                    .cond = inst.cond,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .jump => |inst| {
                writeOps(ops.OpsJump, ops_ptr, .{
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .jump_if_z => |inst| {
                writeOps(ops.OpsJumpIfZ, ops_ptr, .{
                    .cond = inst.cond,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .jump_if_nz => |inst| {
                writeOps(ops.OpsJumpIfZ, ops_ptr, .{
                    .cond = inst.cond,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .jump_table => |inst| {
                writeOps(ops.OpsJumpTable, ops_ptr, .{
                    .index = inst.index,
                    .targets_start = inst.targets_start,
                    .targets_len = inst.targets_len,
                });
            },
            .select => |inst| {
                writeOps(ops.OpsSelect, ops_ptr, .{
                    .dst = inst.dst,
                    .val1 = inst.val1,
                    .val2 = inst.val2,
                    .cond = inst.cond,
                });
            },
            .ret => |inst| {
                writeOps(ops.OpsRet, ops_ptr, .{
                    .has_value = if (inst.value != null) 1 else 0,
                    .value = inst.value orelse 0,
                });
            },
            inline .i32_add_ret, .i32_sub_ret, .i64_add_ret, .i64_sub_ret => |inst| {
                writeOps(ops.OpsLhsRhs, ops_ptr, .{ .lhs = inst.lhs, .rhs = inst.rhs });
            },
            inline .f32_add_ret, .f32_sub_ret, .f64_add_ret, .f64_sub_ret => |inst| {
                writeOps(ops.OpsLhsRhs, ops_ptr, .{ .lhs = inst.lhs, .rhs = inst.rhs });
            },
            inline .i32_add,
            .i32_sub,
            .i32_mul,
            .i32_div_s,
            .i32_div_u,
            .i32_rem_s,
            .i32_rem_u,
            .i32_and,
            .i32_or,
            .i32_xor,
            .i32_shl,
            .i32_shr_s,
            .i32_shr_u,
            .i32_rotl,
            .i32_rotr,
            .i64_add,
            .i64_sub,
            .i64_mul,
            .i64_div_s,
            .i64_div_u,
            .i64_rem_s,
            .i64_rem_u,
            .i64_and,
            .i64_or,
            .i64_xor,
            .i64_shl,
            .i64_shr_s,
            .i64_shr_u,
            .i64_rotl,
            .i64_rotr,
            .f32_add,
            .f32_sub,
            .f32_mul,
            .f32_div,
            .f32_min,
            .f32_max,
            .f32_copysign,
            .f64_add,
            .f64_sub,
            .f64_mul,
            .f64_div,
            .f64_min,
            .f64_max,
            .f64_copysign,
            .i32_eq,
            .i32_ne,
            .i32_lt_s,
            .i32_lt_u,
            .i32_gt_s,
            .i32_gt_u,
            .i32_le_s,
            .i32_le_u,
            .i32_ge_s,
            .i32_ge_u,
            .i64_eq,
            .i64_ne,
            .i64_lt_s,
            .i64_lt_u,
            .i64_gt_s,
            .i64_gt_u,
            .i64_le_s,
            .i64_le_u,
            .i64_ge_s,
            .i64_ge_u,
            .f32_eq,
            .f32_ne,
            .f32_lt,
            .f32_gt,
            .f32_le,
            .f32_ge,
            .f64_eq,
            .f64_ne,
            .f64_lt,
            .f64_gt,
            .f64_le,
            .f64_ge,
            => |inst| {
                writeOps(ops.OpsDstLhsRhs, ops_ptr, .{
                    .dst = inst.dst,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },
            inline .i32_clz,
            .i32_ctz,
            .i32_popcnt,
            .i32_eqz,
            .i64_clz,
            .i64_ctz,
            .i64_popcnt,
            .i64_eqz,
            .f32_abs,
            .f32_neg,
            .f32_ceil,
            .f32_floor,
            .f32_trunc,
            .f32_nearest,
            .f32_sqrt,
            .f64_abs,
            .f64_neg,
            .f64_ceil,
            .f64_floor,
            .f64_trunc,
            .f64_nearest,
            .f64_sqrt,
            .i32_wrap_i64,
            .i32_trunc_f32_s,
            .i32_trunc_f32_u,
            .i32_trunc_f64_s,
            .i32_trunc_f64_u,
            .i64_extend_i32_s,
            .i64_extend_i32_u,
            .i64_trunc_f32_s,
            .i64_trunc_f32_u,
            .i64_trunc_f64_s,
            .i64_trunc_f64_u,
            .i32_trunc_sat_f32_s,
            .i32_trunc_sat_f32_u,
            .i32_trunc_sat_f64_s,
            .i32_trunc_sat_f64_u,
            .i64_trunc_sat_f32_s,
            .i64_trunc_sat_f32_u,
            .i64_trunc_sat_f64_s,
            .i64_trunc_sat_f64_u,
            .f32_convert_i32_s,
            .f32_convert_i32_u,
            .f32_convert_i64_s,
            .f32_convert_i64_u,
            .f32_demote_f64,
            .f64_promote_f32,
            .f64_convert_i32_s,
            .f64_convert_i32_u,
            .f64_convert_i64_s,
            .f64_convert_i64_u,
            .i32_reinterpret_f32,
            .i64_reinterpret_f64,
            .f32_reinterpret_i32,
            .f64_reinterpret_i64,
            .i32_extend8_s,
            .i32_extend16_s,
            .i64_extend8_s,
            .i64_extend16_s,
            .i64_extend32_s,
            => |inst| {
                writeOps(ops.OpsDstSrc, ops_ptr, .{
                    .dst = inst.dst,
                    .src = inst.src,
                });
            },
            inline .i32_load,
            .i32_load8_s,
            .i32_load8_u,
            .i32_load16_s,
            .i32_load16_u,
            .i64_load,
            .i64_load8_s,
            .i64_load8_u,
            .i64_load16_s,
            .i64_load16_u,
            .i64_load32_s,
            .i64_load32_u,
            .f32_load,
            .f64_load,
            => |inst| {
                writeOps(ops.OpsLoad, ops_ptr, .{
                    .dst = inst.dst,
                    .addr = inst.addr,
                    .offset = inst.offset,
                });
            },
            inline .i32_store,
            .i32_store8,
            .i32_store16,
            .i64_store,
            .i64_store8,
            .i64_store16,
            .i64_store32,
            .f32_store,
            .f64_store,
            => |inst| {
                writeOps(ops.OpsStore, ops_ptr, .{
                    .addr = inst.addr,
                    .src = inst.src,
                    .offset = inst.offset,
                });
            },
            .memory_size => |inst| {
                writeOps(ops.OpsMemorySize, ops_ptr, .{ .dst = inst.dst });
            },
            .memory_grow => |inst| {
                writeOps(ops.OpsMemoryGrow, ops_ptr, .{ .dst = inst.dst, .delta = inst.delta });
            },
            .memory_init => |inst| {
                writeOps(ops.OpsMemoryInit, ops_ptr, .{
                    .segment_idx = inst.segment_idx,
                    .dst_addr = inst.dst_addr,
                    .src_offset = inst.src_offset,
                    .len = inst.len,
                });
            },
            .data_drop => |inst| {
                writeOps(ops.OpsDataDrop, ops_ptr, .{ .segment_idx = inst.segment_idx });
            },
            .memory_copy => |inst| {
                writeOps(ops.OpsMemoryCopy, ops_ptr, .{
                    .dst_addr = inst.dst_addr,
                    .src_addr = inst.src_addr,
                    .len = inst.len,
                });
            },
            .memory_fill => |inst| {
                writeOps(ops.OpsMemoryFill, ops_ptr, .{
                    .dst_addr = inst.dst_addr,
                    .value = inst.value,
                    .len = inst.len,
                });
            },
            .call => |inst| {
                writeOps(ops.OpsCall, ops_ptr, .{
                    .dst_valid = if (inst.dst != null) 1 else 0,
                    .dst = inst.dst orelse 0,
                    .func_idx = inst.func_idx,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, ops.OpsCall, cf.call_args.items, inst.args_start, inst.args_len);
            },
            .call_to_local => |inst| {
                writeOps(ops.OpsCallToLocal, ops_ptr, .{
                    .local = inst.local,
                    .func_idx = inst.func_idx,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, ops.OpsCallToLocal, cf.call_args.items, inst.args_start, inst.args_len);
            },
            .call_leaf => |inst| {
                writeOps(ops.OpsCallLeaf, ops_ptr, .{
                    .func_idx = inst.func_idx,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, ops.OpsCallLeaf, cf.call_args.items, inst.args_start, inst.args_len);
            },
            .call_indirect => |inst| {
                writeOps(ops.OpsCallIndirect, ops_ptr, .{
                    .dst_valid = if (inst.dst != null) 1 else 0,
                    .dst = inst.dst orelse 0,
                    .index = inst.index,
                    .type_index = inst.type_index,
                    .table_index = inst.table_index,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, ops.OpsCallIndirect, cf.call_args.items, inst.args_start, inst.args_len);
            },
            .return_call => |inst| {
                writeOps(ops.OpsReturnCall, ops_ptr, .{
                    .func_idx = inst.func_idx,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, ops.OpsReturnCall, cf.call_args.items, inst.args_start, inst.args_len);
            },
            .return_call_indirect => |inst| {
                writeOps(ops.OpsReturnCallIndirect, ops_ptr, .{
                    .index = inst.index,
                    .type_index = inst.type_index,
                    .table_index = inst.table_index,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, ops.OpsReturnCallIndirect, cf.call_args.items, inst.args_start, inst.args_len);
            },
            .call_ref => |inst| {
                writeOps(ops.OpsCallRef, ops_ptr, .{
                    .dst_valid = if (inst.dst != null) 1 else 0,
                    .dst = inst.dst orelse 0,
                    .ref = inst.ref,
                    .type_idx = inst.type_idx,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, ops.OpsCallRef, cf.call_args.items, inst.args_start, inst.args_len);
            },
            .return_call_ref => |inst| {
                writeOps(ops.OpsReturnCallRef, ops_ptr, .{
                    .ref = inst.ref,
                    .type_idx = inst.type_idx,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, ops.OpsReturnCallRef, cf.call_args.items, inst.args_start, inst.args_len);
            },
            .atomic_load => |inst| {
                writeOps(ops.OpsAtomicLoad, ops_ptr, .{
                    .dst = inst.dst,
                    .addr = inst.addr,
                    .offset = inst.offset,
                    .width = @intFromEnum(inst.width),
                    .ty = @intFromEnum(inst.ty),
                });
            },
            .atomic_store => |inst| {
                writeOps(ops.OpsAtomicStore, ops_ptr, .{
                    .addr = inst.addr,
                    .src = inst.src,
                    .offset = inst.offset,
                    .width = @intFromEnum(inst.width),
                    .ty = @intFromEnum(inst.ty),
                });
            },
            .atomic_rmw => |inst| {
                writeOps(ops.OpsAtomicRmw, ops_ptr, .{
                    .dst = inst.dst,
                    .addr = inst.addr,
                    .src = inst.src,
                    .offset = inst.offset,
                    .op = @intFromEnum(inst.op),
                    .width = @intFromEnum(inst.width),
                    .ty = @intFromEnum(inst.ty),
                });
            },
            .atomic_cmpxchg => |inst| {
                writeOps(ops.OpsAtomicCmpxchg, ops_ptr, .{
                    .dst = inst.dst,
                    .addr = inst.addr,
                    .expected = inst.expected,
                    .replacement = inst.replacement,
                    .offset = inst.offset,
                    .width = @intFromEnum(inst.width),
                    .ty = @intFromEnum(inst.ty),
                });
            },
            .atomic_fence => {},
            .atomic_notify => |inst| {
                writeOps(ops.OpsAtomicNotify, ops_ptr, .{
                    .dst = inst.dst,
                    .addr = inst.addr,
                    .count = inst.count,
                    .offset = inst.offset,
                });
            },
            .atomic_wait32 => |inst| {
                writeOps(ops.OpsAtomicWait32, ops_ptr, .{
                    .dst = inst.dst,
                    .addr = inst.addr,
                    .expected = inst.expected,
                    .timeout = inst.timeout,
                    .offset = inst.offset,
                });
            },
            .atomic_wait64 => |inst| {
                writeOps(ops.OpsAtomicWait64, ops_ptr, .{
                    .dst = inst.dst,
                    .addr = inst.addr,
                    .expected = inst.expected,
                    .timeout = inst.timeout,
                    .offset = inst.offset,
                });
            },
            .table_get => |inst| {
                writeOps(ops.OpsTableGet, ops_ptr, .{
                    .dst = inst.dst,
                    .table_index = inst.table_index,
                    .index = inst.index,
                });
            },
            .table_set => |inst| {
                writeOps(ops.OpsTableSet, ops_ptr, .{
                    .table_index = inst.table_index,
                    .index = inst.index,
                    .value = inst.value,
                });
            },
            .table_size => |inst| {
                writeOps(ops.OpsTableSize, ops_ptr, .{
                    .dst = inst.dst,
                    .table_index = inst.table_index,
                });
            },
            .table_grow => |inst| {
                writeOps(ops.OpsTableGrow, ops_ptr, .{
                    .dst = inst.dst,
                    .table_index = inst.table_index,
                    .init = inst.init,
                    .delta = inst.delta,
                });
            },
            .table_fill => |inst| {
                writeOps(ops.OpsTableFill, ops_ptr, .{
                    .table_index = inst.table_index,
                    .dst_idx = inst.dst_idx,
                    .value = inst.value,
                    .len = inst.len,
                });
            },
            .table_copy => |inst| {
                writeOps(ops.OpsTableCopy, ops_ptr, .{
                    .dst_table = inst.dst_table,
                    .src_table = inst.src_table,
                    .dst_idx = inst.dst_idx,
                    .src_idx = inst.src_idx,
                    .len = inst.len,
                });
            },
            .table_init => |inst| {
                writeOps(ops.OpsTableInit, ops_ptr, .{
                    .table_index = inst.table_index,
                    .segment_idx = inst.segment_idx,
                    .dst_idx = inst.dst_idx,
                    .src_offset = inst.src_offset,
                    .len = inst.len,
                });
            },
            .elem_drop => |inst| {
                writeOps(ops.OpsElemDrop, ops_ptr, .{ .segment_idx = inst.segment_idx });
            },
            .struct_new => |inst| {
                writeOps(ops.OpsStructNew, ops_ptr, .{
                    .dst = inst.dst,
                    .type_idx = inst.type_idx,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, ops.OpsStructNew, cf.call_args.items, inst.args_start, inst.args_len);
            },
            .struct_new_default => |inst| {
                writeOps(ops.OpsStructNewDefault, ops_ptr, .{
                    .dst = inst.dst,
                    .type_idx = inst.type_idx,
                });
            },
            inline .struct_get, .struct_get_s, .struct_get_u => |inst| {
                writeOps(ops.OpsStructGet, ops_ptr, .{
                    .dst = inst.dst,
                    .ref = inst.ref,
                    .type_idx = inst.type_idx,
                    .field_idx = inst.field_idx,
                });
            },
            .struct_set => |inst| {
                writeOps(ops.OpsStructSet, ops_ptr, .{
                    .ref = inst.ref,
                    .value = inst.value,
                    .type_idx = inst.type_idx,
                    .field_idx = inst.field_idx,
                });
            },
            .array_new => |inst| {
                writeOps(ops.OpsArrayNew, ops_ptr, .{
                    .dst = inst.dst,
                    .init = inst.init,
                    .len = inst.len,
                    .type_idx = inst.type_idx,
                });
            },
            .array_new_default => |inst| {
                writeOps(ops.OpsArrayNewDefault, ops_ptr, .{
                    .dst = inst.dst,
                    .len = inst.len,
                    .type_idx = inst.type_idx,
                });
            },
            .array_new_fixed => |inst| {
                writeOps(ops.OpsArrayNewFixed, ops_ptr, .{
                    .dst = inst.dst,
                    .type_idx = inst.type_idx,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, ops.OpsArrayNewFixed, cf.call_args.items, inst.args_start, inst.args_len);
            },
            .array_new_data => |inst| {
                writeOps(ops.OpsArrayNewData, ops_ptr, .{
                    .dst = inst.dst,
                    .offset = inst.offset,
                    .len = inst.len,
                    .type_idx = inst.type_idx,
                    .data_idx = inst.data_idx,
                });
            },
            .array_new_elem => |inst| {
                writeOps(ops.OpsArrayNewElem, ops_ptr, .{
                    .dst = inst.dst,
                    .offset = inst.offset,
                    .len = inst.len,
                    .type_idx = inst.type_idx,
                    .elem_idx = inst.elem_idx,
                });
            },
            inline .array_get, .array_get_s, .array_get_u => |inst| {
                writeOps(ops.OpsArrayGet, ops_ptr, .{
                    .dst = inst.dst,
                    .ref = inst.ref,
                    .index = inst.index,
                    .type_idx = inst.type_idx,
                });
            },
            .array_set => |inst| {
                writeOps(ops.OpsArraySet, ops_ptr, .{
                    .ref = inst.ref,
                    .index = inst.index,
                    .value = inst.value,
                    .type_idx = inst.type_idx,
                });
            },
            .array_len => |inst| {
                writeOps(ops.OpsArrayLen, ops_ptr, .{
                    .dst = inst.dst,
                    .ref = inst.ref,
                });
            },
            .array_fill => |inst| {
                writeOps(ops.OpsArrayFill, ops_ptr, .{
                    .ref = inst.ref,
                    .offset = inst.offset,
                    .value = inst.value,
                    .n = inst.n,
                    .type_idx = inst.type_idx,
                });
            },
            .array_copy => |inst| {
                writeOps(ops.OpsArrayCopy, ops_ptr, .{
                    .dst_ref = inst.dst_ref,
                    .dst_offset = inst.dst_offset,
                    .src_ref = inst.src_ref,
                    .src_offset = inst.src_offset,
                    .n = inst.n,
                    .dst_type_idx = inst.dst_type_idx,
                    .src_type_idx = inst.src_type_idx,
                });
            },
            .array_init_data => |inst| {
                writeOps(ops.OpsArrayInitData, ops_ptr, .{
                    .ref = inst.ref,
                    .d = inst.d,
                    .s = inst.s,
                    .n = inst.n,
                    .type_idx = inst.type_idx,
                    .data_idx = inst.data_idx,
                });
            },
            .array_init_elem => |inst| {
                writeOps(ops.OpsArrayInitElem, ops_ptr, .{
                    .ref = inst.ref,
                    .d = inst.d,
                    .s = inst.s,
                    .n = inst.n,
                    .type_idx = inst.type_idx,
                    .elem_idx = inst.elem_idx,
                });
            },
            .ref_i31 => |inst| {
                writeOps(ops.OpsRefI31, ops_ptr, .{ .dst = inst.dst, .value = inst.value });
            },
            inline .i31_get_s, .i31_get_u => |inst| {
                writeOps(ops.OpsI31Get, ops_ptr, .{ .dst = inst.dst, .ref = inst.ref });
            },
            inline .ref_test, .ref_cast => |inst| {
                writeOps(ops.OpsRefTest, ops_ptr, .{
                    .dst = inst.dst,
                    .ref = inst.ref,
                    .type_idx = inst.type_idx,
                    .nullable = if (inst.nullable) 1 else 0,
                });
            },
            .ref_as_non_null => |inst| {
                writeOps(ops.OpsRefAsNonNull, ops_ptr, .{ .dst = inst.dst, .ref = inst.ref });
            },
            inline .br_on_null, .br_on_non_null => |inst| {
                writeOps(ops.OpsBrOnNull, ops_ptr, .{
                    .ref = inst.ref,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            inline .br_on_cast, .br_on_cast_fail => |inst| {
                writeOps(ops.OpsBrOnCast, ops_ptr, .{
                    .ref = inst.ref,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                    .from_type_idx = inst.from_type_idx,
                    .to_type_idx = inst.to_type_idx,
                    .to_nullable = if (inst.to_nullable) 1 else 0,
                });
            },
            inline .any_convert_extern, .extern_convert_any => |inst| {
                writeOps(ops.OpsConvertRef, ops_ptr, .{ .dst = inst.dst, .ref = inst.ref });
            },
            .throw => |inst| {
                writeOps(ops.OpsThrow, ops_ptr, .{
                    .tag_index = inst.tag_index,
                    .args_len = inst.args_len,
                });
                writeInlineArgs(ops_ptr, ops.OpsThrow, cf.call_args.items, inst.args_start, inst.args_len);
            },
            .throw_ref => |inst| {
                writeOps(ops.OpsThrowRef, ops_ptr, .{ .ref = inst.ref });
            },
            .try_table_enter => |inst| {
                writeOps(ops.OpsTryTableEnter, ops_ptr, .{
                    .handlers_start = inst.handlers_start,
                    .handlers_len = inst.handlers_len,
                    .end_target = op_offset[inst.end_target],
                });
            },
            .try_table_leave => |inst| {
                writeOps(ops.OpsTryTableLeave, ops_ptr, .{
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .i32_add_imm,
            .i32_sub_imm,
            .i32_mul_imm,
            .i32_and_imm,
            .i32_or_imm,
            .i32_xor_imm,
            .i32_shl_imm,
            .i32_shr_s_imm,
            .i32_shr_u_imm,
            .i32_eq_imm,
            .i32_ne_imm,
            .i32_lt_s_imm,
            .i32_lt_u_imm,
            .i32_gt_s_imm,
            .i32_gt_u_imm,
            .i32_le_s_imm,
            .i32_le_u_imm,
            .i32_ge_s_imm,
            .i32_ge_u_imm,
            => |inst| {
                writeOps(ops.OpsBinopImm, ops_ptr, .{
                    .dst = inst.dst,
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                });
            },
            .i64_add_imm,
            .i64_sub_imm,
            .i64_mul_imm,
            .i64_and_imm,
            .i64_or_imm,
            .i64_xor_imm,
            .i64_shl_imm,
            .i64_shr_s_imm,
            .i64_shr_u_imm,
            .i64_eq_imm,
            .i64_ne_imm,
            .i64_lt_s_imm,
            .i64_lt_u_imm,
            .i64_gt_s_imm,
            .i64_gt_u_imm,
            .i64_le_s_imm,
            .i64_le_u_imm,
            .i64_ge_s_imm,
            .i64_ge_u_imm,
            => |inst| {
                writeOps(ops.OpsBinopImm64, ops_ptr, .{
                    .dst = inst.dst,
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                });
            },
            .f32_add_imm,
            .f32_sub_imm,
            .f32_mul_imm,
            .f32_div_imm,
            => |inst| {
                writeOps(ops.OpsBinopImmF32, ops_ptr, .{
                    .dst = inst.dst,
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                });
            },
            .f64_add_imm,
            .f64_sub_imm,
            .f64_mul_imm,
            .f64_div_imm,
            => |inst| {
                writeOps(ops.OpsBinopImmF64, ops_ptr, .{
                    .dst = inst.dst,
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                });
            },
            .i32_add_imm_r,
            .i32_sub_imm_r,
            .i32_mul_imm_r,
            .i32_and_imm_r,
            .i32_or_imm_r,
            .i32_xor_imm_r,
            .i32_shl_imm_r,
            .i32_shr_s_imm_r,
            .i32_shr_u_imm_r,
            => |inst| {
                writeOps(ops.OpsBinopImmR0, ops_ptr, .{
                    .dst = inst.dst,
                    .imm = inst.imm,
                });
            },
            .i64_add_imm_r,
            .i64_sub_imm_r,
            .i64_mul_imm_r,
            .i64_and_imm_r,
            .i64_or_imm_r,
            .i64_xor_imm_r,
            .i64_shl_imm_r,
            .i64_shr_s_imm_r,
            .i64_shr_u_imm_r,
            => |inst| {
                writeOps(ops.OpsBinopImmR064, ops_ptr, .{
                    .dst = inst.dst,
                    .imm = inst.imm,
                });
            },
            .i32_eq_jump_if_false,
            .i32_ne_jump_if_false,
            .i32_lt_s_jump_if_false,
            .i32_lt_u_jump_if_false,
            .i32_gt_s_jump_if_false,
            .i32_gt_u_jump_if_false,
            .i32_le_s_jump_if_false,
            .i32_le_u_jump_if_false,
            .i32_ge_s_jump_if_false,
            .i32_ge_u_jump_if_false,
            => |inst| {
                writeOps(ops.OpsCompareJump, ops_ptr, .{
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .i32_eqz_jump_if_false => |inst| {
                writeOps(ops.OpsEqzJump, ops_ptr, .{
                    .src = inst.src,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .i64_eq_jump_if_false,
            .i64_ne_jump_if_false,
            .i64_lt_s_jump_if_false,
            .i64_lt_u_jump_if_false,
            .i64_gt_s_jump_if_false,
            .i64_gt_u_jump_if_false,
            .i64_le_s_jump_if_false,
            .i64_le_u_jump_if_false,
            .i64_ge_s_jump_if_false,
            .i64_ge_u_jump_if_false,
            => |inst| {
                writeOps(ops.OpsCompareJump, ops_ptr, .{
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .i64_eqz_jump_if_false => |inst| {
                writeOps(ops.OpsEqzJump, ops_ptr, .{
                    .src = inst.src,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .i32_eq_jump_if_true,
            .i32_ne_jump_if_true,
            .i32_lt_s_jump_if_true,
            .i32_lt_u_jump_if_true,
            .i32_gt_s_jump_if_true,
            .i32_gt_u_jump_if_true,
            .i32_le_s_jump_if_true,
            .i32_le_u_jump_if_true,
            .i32_ge_s_jump_if_true,
            .i32_ge_u_jump_if_true,
            => |inst| {
                writeOps(ops.OpsCompareJump, ops_ptr, .{
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .i32_eqz_jump_if_true => |inst| {
                writeOps(ops.OpsEqzJump, ops_ptr, .{
                    .src = inst.src,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .i64_eq_jump_if_true,
            .i64_ne_jump_if_true,
            .i64_lt_s_jump_if_true,
            .i64_lt_u_jump_if_true,
            .i64_gt_s_jump_if_true,
            .i64_gt_u_jump_if_true,
            .i64_le_s_jump_if_true,
            .i64_le_u_jump_if_true,
            .i64_ge_s_jump_if_true,
            .i64_ge_u_jump_if_true,
            => |inst| {
                writeOps(ops.OpsCompareJump, ops_ptr, .{
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .i64_eqz_jump_if_true => |inst| {
                writeOps(ops.OpsEqzJump, ops_ptr, .{
                    .src = inst.src,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .f32_eq_jump_if_false,
            .f32_ne_jump_if_false,
            .f32_lt_jump_if_false,
            .f32_gt_jump_if_false,
            .f32_le_jump_if_false,
            .f32_ge_jump_if_false,
            => |inst| {
                writeOps(ops.OpsCompareJump, ops_ptr, .{
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .f64_eq_jump_if_false,
            .f64_ne_jump_if_false,
            .f64_lt_jump_if_false,
            .f64_gt_jump_if_false,
            .f64_le_jump_if_false,
            .f64_ge_jump_if_false,
            => |inst| {
                writeOps(ops.OpsCompareJump, ops_ptr, .{
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .f32_eq_jump_if_true,
            .f32_ne_jump_if_true,
            .f32_lt_jump_if_true,
            .f32_gt_jump_if_true,
            .f32_le_jump_if_true,
            .f32_ge_jump_if_true,
            => |inst| {
                writeOps(ops.OpsCompareJump, ops_ptr, .{
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .f64_eq_jump_if_true,
            .f64_ne_jump_if_true,
            .f64_lt_jump_if_true,
            .f64_gt_jump_if_true,
            .f64_le_jump_if_true,
            .f64_ge_jump_if_true,
            => |inst| {
                writeOps(ops.OpsCompareJump, ops_ptr, .{
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .i32_add_to_local,
            .i32_sub_to_local,
            .i32_mul_to_local,
            .i32_and_to_local,
            .i32_or_to_local,
            .i32_xor_to_local,
            .i32_shl_to_local,
            .i32_shr_s_to_local,
            .i32_shr_u_to_local,
            => |inst| {
                writeOps(ops.OpsBinopToLocal, ops_ptr, .{
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },
            .i64_add_to_local,
            .i64_sub_to_local,
            .i64_mul_to_local,
            .i64_and_to_local,
            .i64_or_to_local,
            .i64_xor_to_local,
            .i64_shl_to_local,
            .i64_shr_s_to_local,
            .i64_shr_u_to_local,
            => |inst| {
                writeOps(ops.OpsBinopToLocal, ops_ptr, .{
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },
            .f32_add_to_local,
            .f32_sub_to_local,
            .f32_mul_to_local,
            .f32_div_to_local,
            => |inst| {
                writeOps(ops.OpsBinopToLocal, ops_ptr, .{
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },
            .f64_add_to_local,
            .f64_sub_to_local,
            .f64_mul_to_local,
            .f64_div_to_local,
            => |inst| {
                writeOps(ops.OpsBinopToLocal, ops_ptr, .{
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },
            .i32_add_tee_local,
            .i32_sub_tee_local,
            .i32_mul_tee_local,
            .i32_and_tee_local,
            .i32_or_tee_local,
            .i32_xor_tee_local,
            .i32_shl_tee_local,
            .i32_shr_s_tee_local,
            .i32_shr_u_tee_local,
            => |inst| {
                writeOps(ops.OpsBinopTeeLocal, ops_ptr, .{
                    .dst = inst.dst,
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },
            .i64_add_tee_local,
            .i64_sub_tee_local,
            .i64_mul_tee_local,
            .i64_and_tee_local,
            .i64_or_tee_local,
            .i64_xor_tee_local,
            .i64_shl_tee_local,
            .i64_shr_s_tee_local,
            .i64_shr_u_tee_local,
            => |inst| {
                writeOps(ops.OpsBinopTeeLocal, ops_ptr, .{
                    .dst = inst.dst,
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },
            .f32_add_tee_local,
            .f32_sub_tee_local,
            .f32_mul_tee_local,
            .f32_div_tee_local,
            => |inst| {
                writeOps(ops.OpsBinopTeeLocal, ops_ptr, .{
                    .dst = inst.dst,
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },
            .f64_add_tee_local,
            .f64_sub_tee_local,
            .f64_mul_tee_local,
            .f64_div_tee_local,
            => |inst| {
                writeOps(ops.OpsBinopTeeLocal, ops_ptr, .{
                    .dst = inst.dst,
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },
            .i32_eq_to_local,
            .i32_ne_to_local,
            .i32_lt_s_to_local,
            .i32_lt_u_to_local,
            .i32_gt_s_to_local,
            .i32_gt_u_to_local,
            .i32_le_s_to_local,
            .i32_le_u_to_local,
            .i32_ge_s_to_local,
            .i32_ge_u_to_local,
            => |inst| {
                writeOps(ops.OpsCmpToLocal, ops_ptr, .{
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },
            .i64_eq_to_local,
            .i64_ne_to_local,
            .i64_lt_s_to_local,
            .i64_lt_u_to_local,
            .i64_gt_s_to_local,
            .i64_gt_u_to_local,
            .i64_le_s_to_local,
            .i64_le_u_to_local,
            .i64_ge_s_to_local,
            .i64_ge_u_to_local,
            => |inst| {
                writeOps(ops.OpsCmpToLocal, ops_ptr, .{
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },
            .f32_eq_to_local,
            .f32_ne_to_local,
            .f32_lt_to_local,
            .f32_gt_to_local,
            .f32_le_to_local,
            .f32_ge_to_local,
            => |inst| {
                writeOps(ops.OpsCmpToLocal, ops_ptr, .{
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },
            .f64_eq_to_local,
            .f64_ne_to_local,
            .f64_lt_to_local,
            .f64_gt_to_local,
            .f64_le_to_local,
            .f64_ge_to_local,
            => |inst| {
                writeOps(ops.OpsCmpToLocal, ops_ptr, .{
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },
            .i32_add_imm_to_local,
            .i32_sub_imm_to_local,
            .i32_mul_imm_to_local,
            .i32_and_imm_to_local,
            .i32_or_imm_to_local,
            .i32_xor_imm_to_local,
            .i32_shl_imm_to_local,
            .i32_shr_s_imm_to_local,
            .i32_shr_u_imm_to_local,
            => |inst| {
                writeOps(ops.OpsBinopImmToLocal, ops_ptr, .{
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                });
            },
            .i64_add_imm_to_local,
            .i64_sub_imm_to_local,
            .i64_mul_imm_to_local,
            .i64_and_imm_to_local,
            .i64_or_imm_to_local,
            .i64_xor_imm_to_local,
            .i64_shl_imm_to_local,
            .i64_shr_s_imm_to_local,
            .i64_shr_u_imm_to_local,
            => |inst| {
                writeOps(ops.OpsBinopImmToLocal64, ops_ptr, .{
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                });
            },
            .f32_add_imm_to_local,
            .f32_sub_imm_to_local,
            .f32_mul_imm_to_local,
            .f32_div_imm_to_local,
            => |inst| {
                writeOps(ops.OpsBinopImmToLocalF32, ops_ptr, .{
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                });
            },
            .f64_add_imm_to_local,
            .f64_sub_imm_to_local,
            .f64_mul_imm_to_local,
            .f64_div_imm_to_local,
            => |inst| {
                writeOps(ops.OpsBinopImmToLocalF64, ops_ptr, .{
                    .local = inst.local,
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                });
            },
            .i32_add_local_inplace,
            .i32_sub_local_inplace,
            .i32_mul_local_inplace,
            .i32_and_local_inplace,
            .i32_or_local_inplace,
            .i32_xor_local_inplace,
            .i32_shl_local_inplace,
            .i32_shr_s_local_inplace,
            .i32_shr_u_local_inplace,
            => |inst| {
                writeOps(ops.OpsLocalInplace, ops_ptr, .{
                    .local = inst.local,
                    .imm = inst.imm,
                });
            },
            .i64_add_local_inplace,
            .i64_sub_local_inplace,
            .i64_mul_local_inplace,
            .i64_and_local_inplace,
            .i64_or_local_inplace,
            .i64_xor_local_inplace,
            .i64_shl_local_inplace,
            .i64_shr_s_local_inplace,
            .i64_shr_u_local_inplace,
            => |inst| {
                writeOps(ops.OpsLocalInplace64, ops_ptr, .{
                    .local = inst.local,
                    .imm = inst.imm,
                });
            },
            .f32_add_local_inplace,
            .f32_sub_local_inplace,
            .f32_mul_local_inplace,
            .f32_div_local_inplace,
            => |inst| {
                writeOps(ops.OpsLocalInplaceF32, ops_ptr, .{
                    .local = inst.local,
                    .imm = inst.imm,
                });
            },
            .f64_add_local_inplace,
            .f64_sub_local_inplace,
            .f64_mul_local_inplace,
            .f64_div_local_inplace,
            => |inst| {
                writeOps(ops.OpsLocalInplaceF64, ops_ptr, .{
                    .local = inst.local,
                    .imm = inst.imm,
                });
            },
            .i32_const_to_local,
            => |inst| {
                writeOps(ops.OpsConstToLocal32, ops_ptr, .{
                    .local = inst.local,
                    .value = inst.value,
                });
            },
            .i64_const_to_local,
            => |inst| {
                writeOps(ops.OpsConstToLocal64, ops_ptr, .{
                    .local = inst.local,
                    .value = inst.value,
                });
            },
            .i32_imm_to_local,
            => |inst| {
                writeOps(ops.OpsImm32ToLocal, ops_ptr, .{
                    .local = inst.local,
                    .src = inst.src,
                    .imm = inst.imm,
                });
            },
            .i64_imm_to_local,
            => |inst| {
                writeOps(ops.OpsImm64ToLocal, ops_ptr, .{
                    .local = inst.local,
                    .src = inst.src,
                    .imm = inst.imm,
                });
            },
            .global_get_to_local,
            => |inst| {
                writeOps(ops.OpsGlobalGetToLocal, ops_ptr, .{
                    .local = inst.local,
                    .global_idx = inst.global_idx,
                });
            },
            .i32_load_to_local,
            => |inst| {
                writeOps(ops.OpsLoadToLocal, ops_ptr, .{
                    .local = inst.local,
                    .addr = inst.addr,
                    .offset = inst.offset,
                });
            },
            .i64_load_to_local,
            => |inst| {
                writeOps(ops.OpsLoadToLocal, ops_ptr, .{
                    .local = inst.local,
                    .addr = inst.addr,
                    .offset = inst.offset,
                });
            },
            .i32_eq_imm_jump_if_false,
            .i32_ne_imm_jump_if_false,
            .i32_lt_s_imm_jump_if_false,
            .i32_lt_u_imm_jump_if_false,
            .i32_gt_s_imm_jump_if_false,
            .i32_gt_u_imm_jump_if_false,
            .i32_le_s_imm_jump_if_false,
            .i32_le_u_imm_jump_if_false,
            .i32_ge_s_imm_jump_if_false,
            .i32_ge_u_imm_jump_if_false,
            => |inst| {
                writeOps(ops.OpsCompareImmJump, ops_ptr, .{
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .i64_eq_imm_jump_if_false,
            .i64_ne_imm_jump_if_false,
            .i64_lt_s_imm_jump_if_false,
            .i64_lt_u_imm_jump_if_false,
            .i64_gt_s_imm_jump_if_false,
            .i64_gt_u_imm_jump_if_false,
            .i64_le_s_imm_jump_if_false,
            .i64_le_u_imm_jump_if_false,
            .i64_ge_s_imm_jump_if_false,
            .i64_ge_u_imm_jump_if_false,
            => |inst| {
                writeOps(ops.OpsCompareImmJump64, ops_ptr, .{
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .i32_eq_imm_jump_if_true,
            .i32_ne_imm_jump_if_true,
            .i32_lt_s_imm_jump_if_true,
            .i32_lt_u_imm_jump_if_true,
            .i32_gt_s_imm_jump_if_true,
            .i32_gt_u_imm_jump_if_true,
            .i32_le_s_imm_jump_if_true,
            .i32_le_u_imm_jump_if_true,
            .i32_ge_s_imm_jump_if_true,
            .i32_ge_u_imm_jump_if_true,
            => |inst| {
                writeOps(ops.OpsCompareImmJump, ops_ptr, .{
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .i64_eq_imm_jump_if_true,
            .i64_ne_imm_jump_if_true,
            .i64_lt_s_imm_jump_if_true,
            .i64_lt_u_imm_jump_if_true,
            .i64_gt_s_imm_jump_if_true,
            .i64_gt_u_imm_jump_if_true,
            .i64_le_s_imm_jump_if_true,
            .i64_le_u_imm_jump_if_true,
            .i64_ge_s_imm_jump_if_true,
            .i64_ge_u_imm_jump_if_true,
            => |inst| {
                writeOps(ops.OpsCompareImmJump64, ops_ptr, .{
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .f32_eq_imm_jump_if_false,
            .f32_ne_imm_jump_if_false,
            .f32_lt_imm_jump_if_false,
            .f32_gt_imm_jump_if_false,
            .f32_le_imm_jump_if_false,
            .f32_ge_imm_jump_if_false,
            => |inst| {
                writeOps(ops.OpsCompareImmJumpF32, ops_ptr, .{
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .f64_eq_imm_jump_if_false,
            .f64_ne_imm_jump_if_false,
            .f64_lt_imm_jump_if_false,
            .f64_gt_imm_jump_if_false,
            .f64_le_imm_jump_if_false,
            .f64_ge_imm_jump_if_false,
            => |inst| {
                writeOps(ops.OpsCompareImmJumpF64, ops_ptr, .{
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .f32_eq_imm_jump_if_true,
            .f32_ne_imm_jump_if_true,
            .f32_lt_imm_jump_if_true,
            .f32_gt_imm_jump_if_true,
            .f32_le_imm_jump_if_true,
            .f32_ge_imm_jump_if_true,
            => |inst| {
                writeOps(ops.OpsCompareImmJumpF32, ops_ptr, .{
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .f64_eq_imm_jump_if_true,
            .f64_ne_imm_jump_if_true,
            .f64_lt_imm_jump_if_true,
            .f64_gt_imm_jump_if_true,
            .f64_le_imm_jump_if_true,
            .f64_ge_imm_jump_if_true,
            => |inst| {
                writeOps(ops.OpsCompareImmJumpF64, ops_ptr, .{
                    .lhs = inst.lhs,
                    .imm = inst.imm,
                    .rel_target = @intCast(@as(i64, op_offset[inst.target]) - @as(i64, base)),
                });
            },
            .simd_unary => |inst| {
                writeOps(ops.OpsSimdUnary, ops_ptr, .{
                    .dst = inst.dst,
                    .opcode = @intFromEnum(inst.opcode),
                    .src = inst.src,
                });
            },
            .simd_binary => |inst| {
                writeOps(ops.OpsSimdBinary, ops_ptr, .{
                    .dst = inst.dst,
                    .opcode = @intFromEnum(inst.opcode),
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },
            .simd_ternary => |inst| {
                writeOps(ops.OpsSimdTernary, ops_ptr, .{
                    .dst = inst.dst,
                    .opcode = @intFromEnum(inst.opcode),
                    .first = inst.first,
                    .second = inst.second,
                    .third = inst.third,
                });
            },
            .simd_compare => |inst| {
                writeOps(ops.OpsSimdUnary, ops_ptr, .{
                    .dst = inst.dst,
                    .opcode = @intFromEnum(inst.opcode),
                    .src = inst.lhs,
                });
            },
            .simd_shift_scalar => |inst| {
                writeOps(ops.OpsSimdBinary, ops_ptr, .{
                    .dst = inst.dst,
                    .opcode = @intFromEnum(inst.opcode),
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                });
            },
            .simd_extract_lane => |inst| {
                writeOps(ops.OpsSimdExtractLane, ops_ptr, .{
                    .dst = inst.dst,
                    .opcode = @intFromEnum(inst.opcode),
                    .src = inst.src,
                    .lane = inst.lane,
                });
            },
            .simd_replace_lane => |inst| {
                writeOps(ops.OpsSimdReplaceLane, ops_ptr, .{
                    .dst = inst.dst,
                    .opcode = @intFromEnum(inst.opcode),
                    .src_vec = inst.src_vec,
                    .src_lane = inst.src_lane,
                    .lane = inst.lane,
                });
            },
            .simd_shuffle => |inst| {
                writeOps(ops.OpsSimdShuffle, ops_ptr, .{
                    .dst = inst.dst,
                    .lhs = inst.lhs,
                    .rhs = inst.rhs,
                    .lanes = inst.lanes,
                });
            },
            .simd_load => |inst| {
                writeOps(ops.OpsSimdLoad, ops_ptr, .{
                    .dst = inst.dst,
                    .opcode = @intFromEnum(inst.opcode),
                    .addr = inst.addr,
                    .offset = inst.offset,
                    .lane_valid = if (inst.lane != null) 1 else 0,
                    .lane = inst.lane orelse 0,
                    .src_vec_valid = if (inst.src_vec != null) 1 else 0,
                    .src_vec = inst.src_vec orelse 0,
                });
            },
            .simd_store => |inst| {
                writeOps(ops.OpsSimdStore, ops_ptr, .{
                    .opcode = @intFromEnum(inst.opcode),
                    .addr = inst.addr,
                    .src = inst.src,
                    .offset = inst.offset,
                    .lane_valid = if (inst.lane != null) 1 else 0,
                    .lane = inst.lane orelse 0,
                });
            },
        }
    }

    const cht_src = cf.catch_handler_tables.items;
    const catch_handler_tables = try allocator.dupe(CatchHandlerEntry, cht_src);
    errdefer allocator.free(catch_handler_tables);

    var eh_dst_total: u32 = 0;
    for (cht_src) |e| {
        eh_dst_total += e.dst_slots_len;
    }

    const eh_dst_slots = try allocator.alloc(Slot, eh_dst_total);
    errdefer allocator.free(eh_dst_slots);

    {
        var eh_off: u32 = 0;
        for (catch_handler_tables) |*e| {
            e.target = op_offset[e.target];
            if (e.dst_slots_len > 0) {
                const src_slots = cf.call_args.items[e.dst_slots_start .. e.dst_slots_start + e.dst_slots_len];
                @memcpy(eh_dst_slots[eh_off .. eh_off + e.dst_slots_len], src_slots);
                e.dst_slots_start = eh_off;
                eh_off += e.dst_slots_len;
            }
        }
    }

    const br_targets_src = cf.br_table_targets.items;
    const br_table_targets = try allocator.alloc(u32, br_targets_src.len);
    errdefer allocator.free(br_table_targets);
    for (br_targets_src, 0..) |t, j| {
        br_table_targets[j] = op_offset[t];
    }

    return EncodedFunction{
        .code = code,
        .slots_len = cf.slots_len,
        .locals_count = cf.locals_count,
        .eh_dst_slots = eh_dst_slots,
        .br_table_targets = br_table_targets,
        .catch_handler_tables = catch_handler_tables,
        .is_leaf = cf.is_leaf,
    };
}

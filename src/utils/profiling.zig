/// profiling.zig — Conditional call-phase profiling utilities.
///
/// When `profiling` is enabled (via `-Dprofiling=true`), this module provides
/// a `ScopedTimer` that accumulates nanoseconds into `CallProfiling` counters
/// and a `printReport` function that dumps a summary to stderr.
///
/// When profiling is disabled (the default), every API compiles to a no-op
/// with zero runtime cost.
const std = @import("std");
const build_options = @import("build_options");

pub const enabled = build_options.profiling;

// ── Call profiling counters ──────────────────────────────────────────────────

pub const CallProfiling = struct {
    calls: u64 = 0,
    ns_read_ops: u64 = 0,
    ns_ensure_compiled: u64 = 0,
    /// Sub-breakdown of ns_ensure_compiled (only incremented on lazy compiles):
    ns_compile_body: u64 = 0, // compileFunctionBodyNewInto / LegacyInto
    ns_encode_ir: u64 = 0, // encode_mod.encode()
    ns_alloc_slots: u64 = 0,
    ns_copy_args: u64 = 0,
    ns_push_dispatch: u64 = 0,
    slots_len_sum: u64 = 0,
    /// Number of calls that triggered lazy compilation
    lazy_compiles: u64 = 0,

    pub fn total(self: CallProfiling) u64 {
        return self.ns_read_ops + self.ns_ensure_compiled + self.ns_alloc_slots + self.ns_copy_args + self.ns_push_dispatch;
    }
};

pub var call_prof: CallProfiling = .{};

// ── Compile profiling counters ─────────────────────────────────────────────────

pub const CompileProfiling = struct {
    functions_compiled: u64 = 0,
    opcodes_processed: u64 = 0,
    ns_total: u64 = 0,
    ns_read_operator: u64 = 0,
    ns_build_wasm_op: u64 = 0,
    ns_lower_op: u64 = 0,
    ns_encode: u64 = 0,
    ns_arena_init: u64 = 0,
    ns_arena_deinit: u64 = 0,
    ns_lower_init: u64 = 0,
    ns_lower_deinit: u64 = 0,

    pub fn totalMeasured(self: CompileProfiling) u64 {
        return self.ns_read_operator + self.ns_build_wasm_op + self.ns_lower_op + self.ns_encode + self.ns_arena_init + self.ns_arena_deinit + self.ns_lower_init + self.ns_lower_deinit;
    }
};

// ── ControlFrame size distribution counters ───────────────────────────────────

pub const FrameSizeProfiling = struct {
    /// Total frames created (= total block/loop/if/try_table + function frames)
    total_frames: u64 = 0,
    /// patch_sites length at frame close time
    patch_sites_0: u64 = 0,
    patch_sites_1: u64 = 0,
    patch_sites_2: u64 = 0,
    patch_sites_3: u64 = 0,
    patch_sites_4: u64 = 0,
    patch_sites_gt4: u64 = 0,
    patch_sites_max: u64 = 0,
    /// result_slots length at frame open time
    result_slots_0: u64 = 0,
    result_slots_1: u64 = 0,
    result_slots_2: u64 = 0,
    result_slots_gt2: u64 = 0,
    result_slots_max: u64 = 0,
    /// param_slots length at frame open time
    param_slots_0: u64 = 0,
    param_slots_1: u64 = 0,
    param_slots_2: u64 = 0,
    param_slots_gt2: u64 = 0,
    param_slots_max: u64 = 0,
};

pub var frame_prof: FrameSizeProfiling = .{};

pub var compile_prof: CompileProfiling = .{};

// ── Scoped timer ─────────────────────────────────────────────────────────────

/// A lightweight lap timer that accumulates into `CallProfiling` fields.
/// When profiling is disabled the struct is zero-sized and all methods are no-ops.
pub const ScopedTimer = if (enabled) struct {
    timer: std.time.Timer,

    pub fn start() @This() {
        return .{ .timer = std.time.Timer.start() catch unreachable };
    }

    pub inline fn lap(self: *@This(), dest: *u64) void {
        dest.* += self.timer.lap();
    }

    pub inline fn read(self: *@This()) u64 {
        return self.timer.read();
    }
} else struct {
    pub inline fn start() @This() {
        return .{};
    }

    pub inline fn lap(self: *@This(), _: *u64) void {
        _ = self;
    }

    pub inline fn read(_: *@This()) u64 {
        return 0;
    }
};

// ── Report ───────────────────────────────────────────────────────────────────

pub fn printReport() void {
    if (!enabled) return;

    // Call profiling report
    const c = call_prof;
    if (c.calls > 0) {
        const t = c.total();
        std.debug.print(
            \\
            \\=== handle_call profiling ({d} local calls, {d} lazy compiles) ===
            \\  read_ops + top + slice : {d:>10} ns  ({d:.1}%)
            \\  ensureLocalCompiled    : {d:>10} ns  ({d:.1}%)
            \\    compile_body         : {d:>10} ns  ({d:.0} us/compile)
            \\    encode_ir            : {d:>10} ns  ({d:.0} us/compile)
            \\  allocCalleeSlots       : {d:>10} ns  ({d:.1}%)
            \\  copy args              : {d:>10} ns  ({d:.1}%)
            \\  push + dispatch        : {d:>10} ns  ({d:.1}%)
            \\  TOTAL measured         : {d:>10} ns
            \\  avg per call           : {d:.1} ns
            \\  avg slots_len          : {d:.1}
            \\
        , .{
            c.calls,
            c.lazy_compiles,
            c.ns_read_ops,
            pct(c.ns_read_ops, t),
            c.ns_ensure_compiled,
            pct(c.ns_ensure_compiled, t),
            c.ns_compile_body,
            if (c.lazy_compiles > 0) @as(f64, @floatFromInt(c.ns_compile_body)) / @as(f64, @floatFromInt(c.lazy_compiles)) / 1000.0 else 0.0,
            c.ns_encode_ir,
            if (c.lazy_compiles > 0) @as(f64, @floatFromInt(c.ns_encode_ir)) / @as(f64, @floatFromInt(c.lazy_compiles)) / 1000.0 else 0.0,
            c.ns_alloc_slots,
            pct(c.ns_alloc_slots, t),
            c.ns_copy_args,
            pct(c.ns_copy_args, t),
            c.ns_push_dispatch,
            pct(c.ns_push_dispatch, t),
            t,
            if (c.calls > 0) @as(f64, @floatFromInt(t)) / @as(f64, @floatFromInt(c.calls)) else 0.0,
            if (c.calls > 0) @as(f64, @floatFromInt(c.slots_len_sum)) / @as(f64, @floatFromInt(c.calls)) else 0.0,
        });
    }

    // Compile profiling report
    const cp = compile_prof;
    if (cp.functions_compiled > 0) {
        const tm = cp.totalMeasured();
        std.debug.print(
            \\
            \\=== compile profiling ({d} functions, {d} opcodes) ===
            \\  arena init             : {d:>10} ns  ({d:.1}%)
            \\  arena deinit           : {d:>10} ns  ({d:.1}%)
            \\  lower init             : {d:>10} ns  ({d:.1}%)
            \\  lower deinit           : {d:>10} ns  ({d:.1}%)
            \\  readNextOperator       : {d:>10} ns  ({d:.1}%)  {d:.0} ns/op
            \\  buildWasmOp            : {d:>10} ns  ({d:.1}%)  {d:.0} ns/op
            \\  lowerOp                : {d:>10} ns  ({d:.1}%)  {d:.0} ns/op
            \\  encode                 : {d:>10} ns  ({d:.1}%)
            \\  TOTAL measured         : {d:>10} ns
            \\  TOTAL (wall)           : {d:>10} ns
            \\  avg per function       : {d:.1} ns
            \\
        , .{
            cp.functions_compiled,
            cp.opcodes_processed,
            cp.ns_arena_init,
            pct(cp.ns_arena_init, tm),
            cp.ns_arena_deinit,
            pct(cp.ns_arena_deinit, tm),
            cp.ns_lower_init,
            pct(cp.ns_lower_init, tm),
            cp.ns_lower_deinit,
            pct(cp.ns_lower_deinit, tm),
            cp.ns_read_operator,
            pct(cp.ns_read_operator, tm),
            if (cp.opcodes_processed > 0) @as(f64, @floatFromInt(cp.ns_read_operator)) / @as(f64, @floatFromInt(cp.opcodes_processed)) else 0.0,
            cp.ns_build_wasm_op,
            pct(cp.ns_build_wasm_op, tm),
            if (cp.opcodes_processed > 0) @as(f64, @floatFromInt(cp.ns_build_wasm_op)) / @as(f64, @floatFromInt(cp.opcodes_processed)) else 0.0,
            cp.ns_lower_op,
            pct(cp.ns_lower_op, tm),
            if (cp.opcodes_processed > 0) @as(f64, @floatFromInt(cp.ns_lower_op)) / @as(f64, @floatFromInt(cp.opcodes_processed)) else 0.0,
            cp.ns_encode,
            pct(cp.ns_encode, tm),
            tm,
            cp.ns_total,
            if (cp.functions_compiled > 0) @as(f64, @floatFromInt(cp.ns_total)) / @as(f64, @floatFromInt(cp.functions_compiled)) else 0.0,
        });
    }

    // ControlFrame size distribution
    const fp = frame_prof;
    if (fp.total_frames > 0) {
        std.debug.print(
            \\
            \\=== ControlFrame size distribution ({d} frames) ===
            \\  patch_sites:  0={d}  1={d}  2={d}  3={d}  4={d}  >4={d}  max={d}
            \\  result_slots: 0={d}  1={d}  2={d}  >2={d}  max={d}
            \\  param_slots:  0={d}  1={d}  2={d}  >2={d}  max={d}
            \\
        , .{
            fp.total_frames,
            fp.patch_sites_0,
            fp.patch_sites_1,
            fp.patch_sites_2,
            fp.patch_sites_3,
            fp.patch_sites_4,
            fp.patch_sites_gt4,
            fp.patch_sites_max,
            fp.result_slots_0,
            fp.result_slots_1,
            fp.result_slots_2,
            fp.result_slots_gt2,
            fp.result_slots_max,
            fp.param_slots_0,
            fp.param_slots_1,
            fp.param_slots_2,
            fp.param_slots_gt2,
            fp.param_slots_max,
        });
    }
}

inline fn pct(part: u64, total: u64) f64 {
    if (total == 0) return 0.0;
    return @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(total)) * 100.0;
}

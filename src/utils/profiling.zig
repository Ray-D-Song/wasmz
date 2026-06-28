/// profiling.zig — Unified conditional profiling, diagnostics, and tracing.
///
/// All performance instrumentation lives here.  When `build_options.profiling`
/// is false (ReleaseFast / ReleaseSafe without `-Dprofiling=true`), every
/// struct becomes zero-sized and every function becomes a no-op — zero
/// runtime cost and no instrumentation in the binary.
///
/// Subsystems:
///   - RSS reading (cross-platform, always available)
///   - ScopedTimer (lap-based wall-clock measurement)
///   - CallProfiling (call dispatch overhead breakdown)
///   - CompileProfiling (compilation phase breakdown)
///   - FrameSizeProfiling (ControlFrame slot distributions)
///   - OpCounts (runtime instruction execution counts)
///   - WasiDiag (per-host-function call count + timing)
///   - PhaseDiag (mmap → compile → store → instantiate → _start wall-clock)
///   - MemTrace (RSS snapshots per execution phase)
///   - MemStats (full heap breakdown)
///   - OnExitCtx (combined proc_exit callback for mem-trace + mem-stats + profiling)
///   - printReport (dumps all subsystems to stderr)
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const store_mod = @import("../wasmz/store.zig");
const instance_mod = @import("../wasmz/instance.zig");

pub const enabled = build_options.profiling;

pub fn nanoNow() i128 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

// RSS
// Always available (not gated).  In release builds the call sites have
// runtime guards that evaluate to false, so the function is never invoked.

pub fn currentRssBytes() usize {
    return switch (builtin.os.tag) {
        .macos => currentRssMacOS(),
        .linux => currentRssLinux(),
        .windows => currentRssWindows(),
        else => 0,
    };
}

fn currentRssMacOS() usize {
    const MachTaskBasicInfo = extern struct {
        virtual_size: u64,
        resident_size: u64,
        resident_size_max: u64,
        user_time: extern struct { seconds: i32, microseconds: i32 },
        system_time: extern struct { seconds: i32, microseconds: i32 },
        policy: i32,
        suspend_count: i32,
    };
    const mach_task_self = struct {
        extern "c" fn mach_task_self() std.c.mach_port_t;
    }.mach_task_self;
    const task_info_fn = struct {
        extern "c" fn task_info(std.c.mach_port_t, u32, *anyopaque, *u32) i32;
    }.task_info;
    var info: MachTaskBasicInfo = undefined;
    var count: u32 = @sizeOf(MachTaskBasicInfo) / @sizeOf(u32);
    if (task_info_fn(mach_task_self(), 20, &info, &count) != 0) return 0;
    return @intCast(info.resident_size);
}

fn currentRssLinux() usize {
    var buf: [256]u8 = undefined;
    const rc = std.os.linux.open("/proc/self/statm", std.os.linux.O{}, 0);
    const fd: std.os.linux.fd_t = @intCast(rc);
    if (@as(isize, @bitCast(rc)) == -1) return 0;
    defer _ = std.os.linux.close(fd);
    const n = std.os.linux.read(fd, &buf, buf.len);
    if (@as(isize, @bitCast(n)) == -1) return 0;
    if (n == 0) return 0;
    var it = std.mem.tokenizeScalar(u8, buf[0..n], ' ');
    _ = it.next();
    const rss_str = it.next() orelse return 0;
    const rss_pages = std.fmt.parseInt(usize, rss_str, 10) catch return 0;
    return rss_pages * std.heap.pageSize();
}

fn currentRssWindows() usize {
    if (comptime builtin.os.tag != .windows) return 0;
    const windows = std.os.windows;
    const PROCESS_MEMORY_COUNTERS = extern struct {
        cb: u32,
        PageFaultCount: u32,
        PeakWorkingSetSize: usize,
        WorkingSetSize: usize,
        QuotaPeakPagedPoolUsage: usize,
        QuotaPagedPoolUsage: usize,
        QuotaPeakNonPagedPoolUsage: usize,
        QuotaNonPagedPoolUsage: usize,
        PagefileUsage: usize,
        PeakPagefileUsage: usize,
    };
    const k32 = struct {
        extern "kernel32" fn K32GetProcessMemoryInfo(
            windows.HANDLE,
            *PROCESS_MEMORY_COUNTERS,
            u32,
        ) callconv(.winapi) windows.BOOL;
    };
    var counters: PROCESS_MEMORY_COUNTERS = undefined;
    counters.cb = @sizeOf(PROCESS_MEMORY_COUNTERS);
    if (k32.K32GetProcessMemoryInfo(
        windows.self_process_handle,
        &counters,
        @sizeOf(PROCESS_MEMORY_COUNTERS),
    ) == 0) return 0;
    return counters.WorkingSetSize;
}

// Scoped timer

pub const ScopedTimer = if (enabled) struct {
    start_ts: i128,

    pub fn start() @This() {
        return .{ .start_ts = nanoNow() };
    }

    pub inline fn lap(self: *@This(), dest: *u64) void {
        const now = nanoNow();
        dest.* = @intCast(now - self.start_ts);
    }

    pub inline fn read(self: *@This()) u64 {
        return @intCast(nanoNow() - self.start_ts);
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

// Call profiling counters

pub const CallProfiling = if (enabled) struct {
    calls: u64 = 0,
    ns_read_ops: u64 = 0,
    ns_ensure_compiled: u64 = 0,
    ns_compile_body: u64 = 0,
    ns_encode_ir: u64 = 0,
    ns_alloc_slots: u64 = 0,
    ns_copy_args: u64 = 0,
    ns_push_dispatch: u64 = 0,
    slots_len_sum: u64 = 0,
    lazy_compiles: u64 = 0,
    arity_0: u64 = 0,
    arity_1: u64 = 0,
    arity_2: u64 = 0,
    arity_3: u64 = 0,
    arity_4: u64 = 0,
    arity_5: u64 = 0,
    arity_6: u64 = 0,
    arity_7: u64 = 0,
    arity_8: u64 = 0,
    arity_gt8: u64 = 0,
    resolved_hits: u64 = 0,

    pub fn total(self: CallProfiling) u64 {
        return self.ns_read_ops + self.ns_ensure_compiled + self.ns_alloc_slots + self.ns_copy_args + self.ns_push_dispatch;
    }
} else struct {
    calls: u64 = 0,
    ns_read_ops: u64 = 0,
    ns_ensure_compiled: u64 = 0,
    ns_compile_body: u64 = 0,
    ns_encode_ir: u64 = 0,
    ns_alloc_slots: u64 = 0,
    ns_copy_args: u64 = 0,
    ns_push_dispatch: u64 = 0,
    slots_len_sum: u64 = 0,
    lazy_compiles: u64 = 0,
    arity_0: u64 = 0,
    arity_1: u64 = 0,
    arity_2: u64 = 0,
    arity_3: u64 = 0,
    arity_4: u64 = 0,
    arity_5: u64 = 0,
    arity_6: u64 = 0,
    arity_7: u64 = 0,
    arity_8: u64 = 0,
    arity_gt8: u64 = 0,
    resolved_hits: u64 = 0,
};

pub var call_prof: CallProfiling = .{};

// Compile profiling counters

pub const CompileProfiling = if (enabled) struct {
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
} else struct {
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
};

pub var compile_prof: CompileProfiling = .{};

// ControlFrame size distribution counters

pub const FrameSizeProfiling = if (enabled) struct {
    total_frames: u64 = 0,
    patch_sites_0: u64 = 0,
    patch_sites_1: u64 = 0,
    patch_sites_2: u64 = 0,
    patch_sites_3: u64 = 0,
    patch_sites_4: u64 = 0,
    patch_sites_gt4: u64 = 0,
    patch_sites_max: u64 = 0,
    result_slots_0: u64 = 0,
    result_slots_1: u64 = 0,
    result_slots_2: u64 = 0,
    result_slots_gt2: u64 = 0,
    result_slots_max: u64 = 0,
    param_slots_0: u64 = 0,
    param_slots_1: u64 = 0,
    param_slots_2: u64 = 0,
    param_slots_gt2: u64 = 0,
    param_slots_max: u64 = 0,
} else struct {
    total_frames: u64 = 0,
    patch_sites_0: u64 = 0,
    patch_sites_1: u64 = 0,
    patch_sites_2: u64 = 0,
    patch_sites_3: u64 = 0,
    patch_sites_4: u64 = 0,
    patch_sites_gt4: u64 = 0,
    patch_sites_max: u64 = 0,
    result_slots_0: u64 = 0,
    result_slots_1: u64 = 0,
    result_slots_2: u64 = 0,
    result_slots_gt2: u64 = 0,
    result_slots_max: u64 = 0,
    param_slots_0: u64 = 0,
    param_slots_1: u64 = 0,
    param_slots_2: u64 = 0,
    param_slots_gt2: u64 = 0,
    param_slots_max: u64 = 0,
};

pub var frame_prof: FrameSizeProfiling = .{};

// Runtime op counts

pub const OpCounts = if (enabled) struct {
    copy: u64 = 0,
    local_get: u64 = 0,
    local_set: u64 = 0,
    copy_jump_if_nz: u64 = 0,
    jump: u64 = 0,
    call_ret: u64 = 0,
    global: u64 = 0,
    constant: u64 = 0,
    imm: u64 = 0,
    imm_r: u64 = 0,
    unary: u64 = 0,
    conv: u64 = 0,
    cmp: u64 = 0,
    binop: u64 = 0,
    ref_select: u64 = 0,
    mem_table: u64 = 0,
    simd: u64 = 0,
    atomic: u64 = 0,
    trap_unreachable: u64 = 0,
    i32_to_local: u64 = 0,
    i64_to_local: u64 = 0,
    f32_to_local: u64 = 0,
    f64_to_local: u64 = 0,
    i32_imm_to_local: u64 = 0,
    i64_imm_to_local: u64 = 0,
    f32_imm_to_local: u64 = 0,
    f64_imm_to_local: u64 = 0,
    i32_local_inplace: u64 = 0,
    i64_local_inplace: u64 = 0,
    f32_local_inplace: u64 = 0,
    f64_local_inplace: u64 = 0,
    const_to_local: u64 = 0,
    load_to_local: u64 = 0,
    global_to_local: u64 = 0,
    tee_local: u64 = 0,
    cmp_to_local: u64 = 0,
    misc: u64 = 0,
    total: u64 = 0,
    dispatch_dispatch: u64 = 0,
    dispatch_next: u64 = 0,
} else struct {};

pub var op_counts: OpCounts = .{};

pub inline fn countOp(comptime field: []const u8) void {
    if (enabled) {
        @field(op_counts, field) += 1;
    }
}

// WASI diagnostic counters

pub const WasiDiagOp = enum {
    args_sizes_get,
    args_get,
    environ_sizes_get,
    environ_get,
    clock_time_get,
    fd_fdstat_get,
    fd_prestat_get,
    fd_prestat_dir_name,
    fd_read,
    fd_seek,
    fd_write,
    path_open,
    poll_oneoff,
    proc_exit,
};

pub const WasiDiag = if (enabled) struct {
    args_sizes_get_count: u64 = 0,
    args_sizes_get_ns: u64 = 0,
    args_get_count: u64 = 0,
    args_get_ns: u64 = 0,
    environ_sizes_get_count: u64 = 0,
    environ_sizes_get_ns: u64 = 0,
    environ_get_count: u64 = 0,
    environ_get_ns: u64 = 0,
    clock_time_get_count: u64 = 0,
    clock_time_get_ns: u64 = 0,
    fd_fdstat_get_count: u64 = 0,
    fd_fdstat_get_ns: u64 = 0,
    fd_prestat_get_count: u64 = 0,
    fd_prestat_get_ns: u64 = 0,
    fd_prestat_dir_name_count: u64 = 0,
    fd_prestat_dir_name_ns: u64 = 0,
    fd_read_count: u64 = 0,
    fd_read_ns: u64 = 0,
    fd_seek_count: u64 = 0,
    fd_seek_ns: u64 = 0,
    fd_write_count: u64 = 0,
    fd_write_ns: u64 = 0,
    path_open_count: u64 = 0,
    path_open_ns: u64 = 0,
    poll_oneoff_count: u64 = 0,
    poll_oneoff_ns: u64 = 0,
    proc_exit_count: u64 = 0,
    proc_exit_ns: u64 = 0,

    pub fn print(self: *const WasiDiag) void {
        std.debug.print(
            \\[wasi-diag] wasmz summary
            \\[wasi-diag]   args_sizes_get      count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   args_get            count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   environ_sizes_get   count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   environ_get         count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   clock_time_get      count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   fd_fdstat_get       count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   fd_prestat_get      count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   fd_prestat_dir_name count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   fd_read             count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   fd_seek             count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   fd_write            count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   path_open           count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   poll_oneoff         count={d:>4}  total={d:8.3} ms
            \\[wasi-diag]   proc_exit           count={d:>4}  total={d:8.3} ms
            \\
        , .{
            self.args_sizes_get_count, @as(f64, @floatFromInt(self.args_sizes_get_ns)) / 1_000_000.0,
            self.args_get_count, @as(f64, @floatFromInt(self.args_get_ns)) / 1_000_000.0,
            self.environ_sizes_get_count, @as(f64, @floatFromInt(self.environ_sizes_get_ns)) / 1_000_000.0,
            self.environ_get_count, @as(f64, @floatFromInt(self.environ_get_ns)) / 1_000_000.0,
            self.clock_time_get_count, @as(f64, @floatFromInt(self.clock_time_get_ns)) / 1_000_000.0,
            self.fd_fdstat_get_count, @as(f64, @floatFromInt(self.fd_fdstat_get_ns)) / 1_000_000.0,
            self.fd_prestat_get_count, @as(f64, @floatFromInt(self.fd_prestat_get_ns)) / 1_000_000.0,
            self.fd_prestat_dir_name_count, @as(f64, @floatFromInt(self.fd_prestat_dir_name_ns)) / 1_000_000.0,
            self.fd_read_count, @as(f64, @floatFromInt(self.fd_read_ns)) / 1_000_000.0,
            self.fd_seek_count, @as(f64, @floatFromInt(self.fd_seek_ns)) / 1_000_000.0,
            self.fd_write_count, @as(f64, @floatFromInt(self.fd_write_ns)) / 1_000_000.0,
            self.path_open_count, @as(f64, @floatFromInt(self.path_open_ns)) / 1_000_000.0,
            self.poll_oneoff_count, @as(f64, @floatFromInt(self.poll_oneoff_ns)) / 1_000_000.0,
            self.proc_exit_count, @as(f64, @floatFromInt(self.proc_exit_ns)) / 1_000_000.0,
        });
    }

    pub fn record(self: *WasiDiag, op: WasiDiagOp, delta_ns: i128) void {
        const ns: u64 = if (delta_ns <= 0) 0 else @intCast(delta_ns);
        switch (op) {
            .args_sizes_get => {
                self.args_sizes_get_count += 1;
                self.args_sizes_get_ns += ns;
            },
            .args_get => {
                self.args_get_count += 1;
                self.args_get_ns += ns;
            },
            .environ_sizes_get => {
                self.environ_sizes_get_count += 1;
                self.environ_sizes_get_ns += ns;
            },
            .environ_get => {
                self.environ_get_count += 1;
                self.environ_get_ns += ns;
            },
            .clock_time_get => {
                self.clock_time_get_count += 1;
                self.clock_time_get_ns += ns;
            },
            .fd_fdstat_get => {
                self.fd_fdstat_get_count += 1;
                self.fd_fdstat_get_ns += ns;
            },
            .fd_prestat_get => {
                self.fd_prestat_get_count += 1;
                self.fd_prestat_get_ns += ns;
            },
            .fd_prestat_dir_name => {
                self.fd_prestat_dir_name_count += 1;
                self.fd_prestat_dir_name_ns += ns;
            },
            .fd_read => {
                self.fd_read_count += 1;
                self.fd_read_ns += ns;
            },
            .fd_seek => {
                self.fd_seek_count += 1;
                self.fd_seek_ns += ns;
            },
            .fd_write => {
                self.fd_write_count += 1;
                self.fd_write_ns += ns;
            },
            .path_open => {
                self.path_open_count += 1;
                self.path_open_ns += ns;
            },
            .poll_oneoff => {
                self.poll_oneoff_count += 1;
                self.poll_oneoff_ns += ns;
            },
            .proc_exit => {
                self.proc_exit_count += 1;
                self.proc_exit_ns += ns;
            },
        }
    }
} else struct {
    pub fn print(_: *const WasiDiag) void {}
    pub fn record(_: *WasiDiag, _: WasiDiagOp, _: i128) void {}
};

// Phase diagnostics

pub const PhaseDiag = if (enabled) struct {
    t0_ns: i128 = 0,
    after_mmap_ns: i128 = 0,
    after_compile_ns: i128 = 0,
    after_store_ns: i128 = 0,
    after_instantiate_ns: i128 = 0,
    after_run_start_ns: i128 = 0,
    enter_start_ns: i128 = 0,
    after_start_ns: i128 = 0,

    pub fn now(self: *PhaseDiag, comptime field: []const u8) void {
        @field(self, field) = nanoNow();
    }

    pub fn print(self: *const PhaseDiag, reason: []const u8) void {
        const now_ns = nanoNow();
        const mmap_done = if (self.after_mmap_ns != 0) self.after_mmap_ns else now_ns;
        const compile_done = if (self.after_compile_ns != 0) self.after_compile_ns else now_ns;
        const store_done = if (self.after_store_ns != 0) self.after_store_ns else now_ns;
        const instantiate_done = if (self.after_instantiate_ns != 0) self.after_instantiate_ns else now_ns;
        const run_start_done = if (self.after_run_start_ns != 0) self.after_run_start_ns else now_ns;
        const start_enter = if (self.enter_start_ns != 0) self.enter_start_ns else now_ns;
        const start_done = if (self.after_start_ns != 0) self.after_start_ns else now_ns;

        std.debug.print(
            \\[phase-diag] wasmz exit={s}
            \\[phase-diag]   open+mmap     : {d:8.3} ms
            \\[phase-diag]   compile       : {d:8.3} ms
            \\[phase-diag]   store+linker  : {d:8.3} ms
            \\[phase-diag]   instantiate   : {d:8.3} ms
            \\[phase-diag]   runStart      : {d:8.3} ms
            \\[phase-diag]   _start        : {d:8.3} ms
            \\[phase-diag]   total         : {d:8.3} ms
            \\
        , .{
            reason,
            nsToMs(mmap_done - self.t0_ns),
            nsToMs(compile_done - mmap_done),
            nsToMs(store_done - compile_done),
            nsToMs(instantiate_done - store_done),
            nsToMs(run_start_done - instantiate_done),
            nsToMs(start_done - start_enter),
            nsToMs(start_done - self.t0_ns),
        });
    }
} else struct {
    pub fn now(_: *PhaseDiag, comptime _: []const u8) void {}
    pub fn print(_: *const PhaseDiag, _: []const u8) void {}
};

// Mem-trace helper

pub fn tracePhase(prev: *usize, label: []const u8) void {
    if (!enabled) return;
    const cur = currentRssBytes();
    const cur_mb = @as(f64, @floatFromInt(cur)) / (1024.0 * 1024.0);
    const delta_bytes: i64 = @as(i64, @intCast(cur)) - @as(i64, @intCast(prev.*));
    const delta_mb = @as(f64, @floatFromInt(delta_bytes)) / (1024.0 * 1024.0);
    const sign: []const u8 = if (delta_bytes >= 0) "+" else "";
    std.debug.print(
        "[mem-trace] {s:<22}  RSS {d:.1} MB  ({s}{d:.1} MB)\n",
        .{ label, cur_mb, sign, delta_mb },
    );
    prev.* = cur;
}

// Mem-stats

pub fn printMemStats(store: *store_mod.Store, instance: *instance_mod.Instance) void {
    if (!enabled) return;

    const linear_bytes = instance.memory.byteLen();
    const linear_pages = instance.memory.pageCount();
    const gc_heap = store.gc_heap;
    const gc_used = if (gc_heap) |h| h.usedSize() else 0;
    const gc_cap = if (gc_heap) |h| h.totalSize() else 0;
    const shared_bytes: usize = @truncate(store.memory_budget.shared_bytes);

    const vm = instance.vmMemStats();
    const ms = instance.module.value.memStats();

    const runtime_total = linear_bytes + gc_cap + shared_bytes +
        vm.val_stack_bytes + vm.call_stack_bytes;
    const module_total = ms.total();
    const grand_total = runtime_total + module_total;

    const gc_alloc_count = if (gc_heap) |h| h.alloc_count else 0;
    const vm_alloc_count = vm.vm_alloc_count;
    const instance_alloc_count = instance.alloc_count;
    const total_alloc_count = gc_alloc_count + vm_alloc_count + instance_alloc_count;

    const mb = struct {
        fn f(b: usize) f64 {
            return @as(f64, @floatFromInt(b)) / (1024.0 * 1024.0);
        }
    }.f;
    const kb = struct {
        fn f(b: usize) f64 {
            return @as(f64, @floatFromInt(b)) / 1024.0;
        }
    }.f;

    const shared_annotation: []const u8 = if (shared_bytes == 0) "(none)" else "";

    var stderr_buf: [2048]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    var bw = std.Io.File.stderr().writer(io, &stderr_buf);
    bw.interface.print(
        \\Memory usage:
        \\
        \\  Runtime
        \\ 
        \\  Linear memory:     {d:.2} MB  ({d} pages)
        \\  GC heap:           {d:.2} MB  (used {d:.1} KB / cap {d:.1} KB)
        \\  Shared memory:     {d:.2} MB  {s}
        \\  VM val_stack:      {d:.2} MB  ({d} slots)
        \\  VM call_stack:     {d:.2} MB  ({d} frames)
        \\ 
        \\  Runtime subtotal:  {d:.2} MB
        \\
        \\  Module
        \\ 
        \\  Pending bodies:    {d:.2} MB  ({d} funcs, raw Wasm bytecode)
        \\  Encoded code:      {d:.2} MB  ({d} funcs, threaded-dispatch)
        \\  Encoded aux:       {d:.1} KB  (br_table / eh tables)
        \\  Data segments:     {d:.2} MB  (passive only after instantiation)
        \\ 
        \\  Module subtotal:   {d:.2} MB
        \\
        \\  ═════════════════════════════════════════
        \\  Grand total:       {d:.2} MB
        \\
        \\  Allocations
        \\ 
        \\  Instance:           {d}
        \\  VM (val/call stack): {d}
        \\  GC heap:            {d}
        \\ 
        \\  Total:              {d}
        \\
    ,
        .{
            mb(linear_bytes),          linear_pages,
            mb(gc_cap),                kb(gc_used),
            kb(gc_cap),                kb(@as(usize, @truncate(shared_bytes))),
            shared_annotation,         mb(vm.val_stack_bytes),
            vm.val_stack_slots,        mb(vm.call_stack_bytes),
            vm.call_stack_frames,      mb(runtime_total),
            mb(ms.pending_body_bytes), ms.pending_count,
            mb(ms.encoded_code_bytes), ms.encoded_count,
            kb(ms.encoded_aux_bytes),  mb(ms.data_segment_bytes),
            mb(module_total),
            mb(grand_total),
            instance_alloc_count,      vm_alloc_count,
            gc_alloc_count,            total_alloc_count,
        },
    ) catch {};
}

// On-exit (proc_exit callback)

pub const OnExitCtx = if (enabled) struct {
    mem_trace: bool = false,
    trace_label: []const u8 = "proc_exit (_start)",
    prev_rss: *usize,
    mem_stats: bool = false,
    store: *store_mod.Store,
    instance: *instance_mod.Instance,
    phase_diag: ?*const PhaseDiag = null,
} else struct {};

pub fn onExitCombined(exit_code: u32, data: ?*anyopaque) void {
    if (!enabled) return;
    if (data == null) return;
    const ctx: *OnExitCtx = @ptrCast(@alignCast(data.?));
    if (ctx.phase_diag) |diag| {
        var reason_buf: [32]u8 = undefined;
        const reason = std.fmt.bufPrint(&reason_buf, "proc_exit({d})", .{exit_code}) catch "proc_exit";
        diag.print(reason);
    }
    if (ctx.mem_stats) {
        printMemStats(ctx.store, ctx.instance);
    }
    if (ctx.mem_trace) {
        tracePhase(ctx.prev_rss, ctx.trace_label);
    }
    printReportImpl();
}

// Report

pub fn printReport() void {
    if (!enabled) return;
    printReportImpl();
}

fn printReportImpl() void {
    printCallReport();
    printCompileReport();
    printFrameReport();
    printOpCountsReport();
}

fn printCallReport() void {
    const c = call_prof;
    if (c.calls == 0) return;

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
        \\  resolved hits          : {d}
        \\  arity histogram        : 0={d} 1={d} 2={d} 3={d} 4={d} 5={d} 6={d} 7={d} 8={d} >8={d}
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
        c.resolved_hits,
        c.arity_0,
        c.arity_1,
        c.arity_2,
        c.arity_3,
        c.arity_4,
        c.arity_5,
        c.arity_6,
        c.arity_7,
        c.arity_8,
        c.arity_gt8,
    });
}

fn printCompileReport() void {
    const cp = compile_prof;
    if (cp.functions_compiled == 0) return;

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

fn printFrameReport() void {
    const fp = frame_prof;
    if (fp.total_frames == 0) return;

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

fn printOpCountsReport() void {
    const oc = op_counts;
    if (oc.total == 0) return;

    std.debug.print(
        \\=== Runtime op counts ===
        \\  copy              : {d:>12}  ({d:.1}%)
        \\  local_get         : {d:>12}  ({d:.1}%)
        \\  local_set         : {d:>12}  ({d:.1}%)
        \\  copy_jump_if_nz   : {d:>12}  ({d:.1}%)
        \\  jump              : {d:>12}  ({d:.1}%)
        \\  call_ret          : {d:>12}  ({d:.1}%)
        \\  global            : {d:>12}  ({d:.1}%)
        \\  constant          : {d:>12}  ({d:.1}%)
        \\  imm               : {d:>12}  ({d:.1}%)
        \\  imm_r             : {d:>12}  ({d:.1}%)
        \\
    , .{
        oc.copy,            pct(oc.copy, oc.total),
        oc.local_get,       pct(oc.local_get, oc.total),
        oc.local_set,       pct(oc.local_set, oc.total),
        oc.copy_jump_if_nz, pct(oc.copy_jump_if_nz, oc.total),
        oc.jump,            pct(oc.jump, oc.total),
        oc.call_ret,        pct(oc.call_ret, oc.total),
        oc.global,          pct(oc.global, oc.total),
        oc.constant,        pct(oc.constant, oc.total),
        oc.imm,             pct(oc.imm, oc.total),
        oc.imm_r,           pct(oc.imm_r, oc.total),
    });
    std.debug.print(
        \\  unary             : {d:>12}  ({d:.1}%)
        \\  conv              : {d:>12}  ({d:.1}%)
        \\  cmp               : {d:>12}  ({d:.1}%)
        \\  binop             : {d:>12}  ({d:.1}%)
        \\  ref_select        : {d:>12}  ({d:.1}%)
        \\  mem_table         : {d:>12}  ({d:.1}%)
        \\  simd              : {d:>12}  ({d:.1}%)
        \\  atomic            : {d:>12}  ({d:.1}%)
        \\  trap_unreachable  : {d:>12}  ({d:.1}%)
        \\  misc              : {d:>12}  ({d:.1}%)
        \\
    , .{
        oc.unary,            pct(oc.unary, oc.total),
        oc.conv,             pct(oc.conv, oc.total),
        oc.cmp,              pct(oc.cmp, oc.total),
        oc.binop,            pct(oc.binop, oc.total),
        oc.ref_select,       pct(oc.ref_select, oc.total),
        oc.mem_table,        pct(oc.mem_table, oc.total),
        oc.simd,             pct(oc.simd, oc.total),
        oc.atomic,           pct(oc.atomic, oc.total),
        oc.trap_unreachable, pct(oc.trap_unreachable, oc.total),
        oc.misc,             pct(oc.misc, oc.total),
    });
    std.debug.print(
        \\  --- Fused local ops ---
        \\  i32_to_local    : {d:>9}  ({d:.1}%)
        \\  i64_to_local    : {d:>9}  ({d:.1}%)
        \\  i32_imm_to_local: {d:>6}  ({d:.1}%)
        \\  i64_imm_to_local: {d:>6}  ({d:.1}%)
        \\  i32_local_inplace: {d:>5}  ({d:.1}%)
        \\  i64_local_inplace: {d:>5}  ({d:.1}%)
        \\  const_to_local : {d:>9}  ({d:.1}%)
        \\  load_to_local  : {d:>9}  ({d:.1}%)
        \\  global_to_local: {d:>9}  ({d:.1}%)
        \\  tee_local      : {d:>9}  ({d:.1}%)
        \\  cmp_to_local   : {d:>9}  ({d:.1}%)
        \\  --- Dispatch overhead ---
        \\  dispatch_dispatch : {d:>9}  ({d:.1}%)
        \\  dispatch_next     : {d:>9}  ({d:.1}%)
        \\  TOTAL             : {d:>12}
        \\
    , .{
        oc.i32_to_local,      pct(oc.i32_to_local, oc.total),
        oc.i64_to_local,      pct(oc.i64_to_local, oc.total),
        oc.i32_imm_to_local,  pct(oc.i32_imm_to_local, oc.total),
        oc.i64_imm_to_local,  pct(oc.i64_imm_to_local, oc.total),
        oc.i32_local_inplace, pct(oc.i32_local_inplace, oc.total),
        oc.i64_local_inplace, pct(oc.i64_local_inplace, oc.total),
        oc.const_to_local,    pct(oc.const_to_local, oc.total),
        oc.load_to_local,     pct(oc.load_to_local, oc.total),
        oc.global_to_local,   pct(oc.global_to_local, oc.total),
        oc.tee_local,         pct(oc.tee_local, oc.total),
        oc.cmp_to_local,      pct(oc.cmp_to_local, oc.total),
        oc.dispatch_dispatch, pct(oc.dispatch_dispatch, oc.total),
        oc.dispatch_next,     pct(oc.dispatch_next, oc.total),
        oc.total,
    });
}

// Helpers

inline fn pct(part: u64, total: u64) f64 {
    if (total == 0) return 0.0;
    return @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(total)) * 100.0;
}

inline fn nsToMs(delta_ns: i128) f64 {
    if (delta_ns <= 0) return 0.0;
    return @as(f64, @floatFromInt(delta_ns)) / 1_000_000.0;
}

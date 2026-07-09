const std = @import("std");
const wasmz = @import("wasmz");
const wasi_preview1 = @import("wasi").preview1;
const profiling = wasmz.profiling;

const Store = wasmz.Store;
const Instance = wasmz.Instance;

pub const DiagLabel = enum {
    t0,
    after_mmap,
    after_compile,
    after_store,
    after_instantiate,
    after_run_start,
    before_start,
    after_start,
};

pub const DiagSession = struct {
    phase: profiling.PhaseDiag = .{},
    phase_enabled: bool = false,
    mem_trace: bool = false,
    trace_prev: usize = 0,
    on_exit_ctx: profiling.OnExitCtx = .{},

    pub fn init(environ: *const std.process.Environ.Map, mem_trace: bool) DiagSession {
        var self: DiagSession = .{
            .phase_enabled = environ.contains("WASMZ_PHASE_DIAG"),
            .mem_trace = mem_trace,
        };
        if (self.phase_enabled) self.phase.now("t0_ns");
        return self;
    }

    pub fn mark(self: *DiagSession, label: DiagLabel) void {
        if (self.phase_enabled) {
            switch (label) {
                .t0 => self.phase.now("t0_ns"),
                .after_mmap => self.phase.now("after_mmap_ns"),
                .after_compile => self.phase.now("after_compile_ns"),
                .after_store => self.phase.now("after_store_ns"),
                .after_instantiate => self.phase.now("after_instantiate_ns"),
                .after_run_start => self.phase.now("after_run_start_ns"),
                .before_start => self.phase.now("enter_start_ns"),
                .after_start => self.phase.now("after_start_ns"),
            }
        }
        if (self.mem_trace) {
            const trace_label: []const u8 = switch (label) {
                .after_mmap => "baseline (file mapped)",
                .after_compile => "after compile",
                .after_instantiate => "after instantiate",
                .after_run_start => "after runStart",
                .before_start => "before _start",
                .after_start => "after _start",
                else => return,
            };
            profiling.tracePhase(&self.trace_prev, trace_label);
        }
    }

    pub fn printStartReturn(self: *const DiagSession) void {
        if (self.phase_enabled) self.phase.print("_start return");
    }

    pub fn setupOnExit(
        self: *DiagSession,
        wasi_host: ?*wasi_preview1.Host,
        store: *Store,
        instance: *Instance,
        mem_stats: bool,
    ) void {
        if (!profiling.enabled) return;
        self.on_exit_ctx = .{
            .mem_trace = self.mem_trace,
            .trace_label = "proc_exit (_start)",
            .prev_rss = &self.trace_prev,
            .mem_stats = mem_stats,
            .store = store,
            .instance = instance,
            .phase_diag = if (self.phase_enabled) &self.phase else null,
        };
        if (wasi_host) |h| h.setOnExit(profiling.onExitCombined, &self.on_exit_ctx);
    }
};
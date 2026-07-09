const std = @import("std");
const wasmz = @import("wasmz");
const wasi_preview1 = @import("wasi").preview1;
const mmap = @import("../utils/mmap.zig");
const args_mod = @import("args.zig");
const diag_mod = @import("diag.zig");
const errors = @import("errors.zig");

const CliArgs = args_mod.CliArgs;
const DiagSession = diag_mod.DiagSession;
const Engine = wasmz.Engine;
const Module = wasmz.Module;
const Store = wasmz.Store;
const Instance = wasmz.Instance;
const Linker = wasmz.Linker;
const RawVal = wasmz.RawVal;

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cli: *const CliArgs,
    mapped: mmap.MappedFile,
    engine: Engine,
    arc_module: wasmz.ArcModule,
    store: Store,
    instance: Instance,
    linker: Linker,
    wasi_host: ?wasi_preview1.Host,
    diag: DiagSession,

    pub fn init(
        self: *Runtime,
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        cli: *const CliArgs,
    ) void {
        self.allocator = allocator;
        self.io = io;
        self.cli = cli;
        self.linker = Linker.empty;
        self.wasi_host = null;
        self.diag = DiagSession.init(environ, cli.mem_trace);

        const file_path = cli.file_path;
        const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err|
            errors.fatal("Unable to open {s}: {s}", .{ file_path, @errorName(err) });
        defer file.close(io);

        self.mapped = mmap.mapFile(file, io) catch |err| switch (err) {
            error.EmptyFile => errors.fatal("{s}: file is empty", .{file_path}),
            error.MapFailed => errors.fatal("Failed to mmap {s}", .{file_path}),
        };
        const wasm_bytes = self.mapped.data;
        self.diag.mark(.after_mmap);

        const use_eager_compile = cli.eagerCompilePolicy(wasm_bytes.len);

        self.engine = Engine.init(allocator, .{
            .legacy_exceptions = cli.legacy_exceptions,
            .mem_limit_bytes = if (cli.mem_limit_mb) |mb| mb * 1024 * 1024 else null,
            .eager_compile = use_eager_compile,
        }) catch |err| errors.fatal("Failed to initialize engine: {s}", .{@errorName(err)});

        self.arc_module = Module.compileArc(self.engine, wasm_bytes) catch |err|
            errors.fatal("Failed to compile {s}: {s}", .{ file_path, @errorName(err) });
        self.diag.mark(.after_compile);

        self.store = Store.init(allocator, self.engine, io) catch |err|
            errors.fatal("Failed to init store: {s}", .{@errorName(err)});
        if (cli.mem_limit_mb != null) self.store.linkBudget();
        self.diag.mark(.after_store);

        if (errors.moduleNeedsWasi(self.arc_module.value)) {
            self.wasi_host = wasi_preview1.Host.init(allocator, io);
            self.wasi_host.?.setArgs(cli.wasi_args) catch |err|
                errors.fatal("Failed to set WASI args: {s}", .{@errorName(err)});
            self.wasi_host.?.addToLinker(&self.linker, allocator) catch |err|
                errors.fatal("Failed to add WASI to linker: {s}", .{@errorName(err)});
        }

        self.instance = Instance.init(&self.store, self.arc_module.retain(), self.linker) catch |err| {
            wasmz.printInitError(self.arc_module, self.linker, err);
            std.process.exit(1);
        };
        self.instance.mem_trace = cli.mem_trace;
        self.diag.mark(.after_instantiate);
        self.diag.setupOnExit(
            if (self.wasi_host) |*h| h else null,
            &self.store,
            &self.instance,
            cli.mem_stats,
        );

        self.runPreamble();
    }

    pub fn deinit(self: *Runtime) void {
        if (self.cli.mem_stats) wasmz.profiling.printMemStats(&self.store, &self.instance);
        self.instance.deinit();
        self.linker.deinit(self.allocator);
        if (self.wasi_host) |*h| h.deinit();
        self.store.deinit();
        if (self.arc_module.releaseUnwrap()) |m| {
            var mod = m;
            mod.deinit();
        }
        self.engine.deinit();
        mmap.unmap(self.mapped);
        self.* = undefined;
    }

    pub fn module(self: *const Runtime) *const Module {
        return self.arc_module.value;
    }

    pub fn listExports(self: *const Runtime, stdout: *std.Io.Writer) void {
        const m = self.module();
        if (m.exports.count() == 0) {
            stdout.writeAll("(module has no exported functions)\n") catch {};
            return;
        }
        stdout.writeAll("Exported functions:\n") catch {};
        var iter = m.exports.iterator();
        while (iter.next()) |entry| {
            stdout.print("  {s}\n", .{entry.key_ptr.*}) catch {};
        }
    }

    pub fn runStart(self: *Runtime) void {
        self.diag.mark(.before_start);
        const result = self.instance.call("_start", &.{}) catch |err|
            errors.fatal("Failed to call _start: {s}", .{@errorName(err)});
        if (result == .trap) errors.fatalTrap(result.trap, self.allocator, self.module(), "trap");
        self.diag.mark(.after_start);
        self.diag.printStartReturn();
    }

    pub fn callExport(
        self: *Runtime,
        stdout: *std.Io.Writer,
        func_name: []const u8,
        i32_args: []const []const u8,
    ) void {
        var call_args: std.ArrayList(RawVal) = .empty;
        defer call_args.deinit(self.allocator);

        for (i32_args) |arg| {
            const val = std.fmt.parseInt(i32, arg, 10) catch
                errors.fatal("Argument \"{s}\" is not a valid i32", .{arg});
            call_args.append(self.allocator, RawVal.from(val)) catch |err|
                errors.fatal("Failed to append arg: {s}", .{@errorName(err)});
        }

        const result = self.instance.call(func_name, call_args.items) catch |err|
            errors.fatal("Failed to call \"{s}\": {s}", .{ func_name, @errorName(err) });

        switch (result) {
            .ok => |val| if (val) |v| stdout.print("{d}\n", .{v.readAs(i32)}) catch {},
            .trap => |t| errors.fatalTrap(t, self.allocator, self.module(), "trap"),
        }
    }

    fn runPreamble(self: *Runtime) void {
        if (self.instance.runStartFunction() catch |err|
            errors.fatal("Failed to run start function: {s}", .{@errorName(err)})) |result|
        {
            if (result == .trap) errors.fatalTrap(result.trap, self.allocator, self.arc_module.value, "start function trapped");
        }
        self.diag.mark(.after_run_start);

        if (self.cli.reactor) {
            if (self.instance.initializeReactor() catch |err|
                errors.fatal("Failed to call _initialize: {s}", .{@errorName(err)})) |res|
            {
                if (res == .trap) errors.fatalTrap(res.trap, self.allocator, self.arc_module.value, "_initialize trapped");
            }
        }
    }
};
const std = @import("std");

pub fn build(b: *std.Build) void {
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Force-export our API functions so the linker keeps them
    root_mod.export_symbol_names = &.{
        "alloc",
        "dealloc",
        "result_buf_ptr",
        "result_buf_len",
        "db_open",
        "db_close",
        "db_exec",
        "db_errmsg",
        "db_last_insert_rowid",
        "db_changes",
        "sqlite_init",
    };

    const lib = b.addExecutable(.{
        .name = "sqlite_wasm",
        .root_module = root_mod,
    });

    // Add sqlite3.c as a C source file (download via ./download-sqlite.sh)
    root_mod.addCSourceFile(.{
        .file = b.path("lib/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_OMIT_LOAD_EXTENSION=1",
            "-DSQLITE_THREADSAFE=0",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_OMIT_DECLTYPE=1",
            "-DSQLITE_OMIT_DEPRECATED=1",
            "-DSQLITE_DQS=0",
            "-Os",
        },
    });

    // Make sqlite3.h findable
    root_mod.addIncludePath(b.path("lib"));

    // WASI reactor: export _initialize instead of _start
    lib.wasi_exec_model = .reactor;

    // Output to fixtures directory as sqlite3.wasm
    const install = b.addInstallArtifact(lib, .{
        .dest_dir = .{ .override = .{ .custom = ".." } },
    });
    install.dest_sub_path = "sqlite3.wasm";

    b.getInstallStep().dependOn(&install.step);

    const build_step = b.step("sqlite-wasm", "Build sqlite3.wasm for wasmz tests");
    build_step.dependOn(&install.step);
}

# WASI Support

wasmz implements **WASI Preview 1** (snapshot 1), enabling WebAssembly modules to interact with the host system.

## Implementation Status

All WASI Preview 1 functions are implemented:

### Environment

| Function | Status |
|----------|--------|
| `args_get` | ✅ |
| `args_sizes_get` | ✅ |
| `environ_get` | ✅ |
| `environ_sizes_get` | ✅ |

### Clock

| Function | Status |
|----------|--------|
| `clock_res_get` | ✅ |
| `clock_time_get` | ✅ |

### File Descriptors

| Function | Status |
|----------|--------|
| `fd_advise` | ✅ |
| `fd_allocate` | ✅ |
| `fd_close` | ✅ |
| `fd_datasync` | ✅ |
| `fd_fdstat_get` | ✅ |
| `fd_fdstat_set_flags` | ✅ |
| `fd_fdstat_set_rights` | ✅ |
| `fd_filestat_get` | ✅ |
| `fd_filestat_set_size` | ✅ |
| `fd_filestat_set_times` | ✅ |
| `fd_pread` | ✅ |
| `fd_prestat_get` | ✅ |
| `fd_prestat_dir_name` | ✅ |
| `fd_pwrite` | ✅ |
| `fd_read` | ✅ |
| `fd_readdir` | ✅ |
| `fd_renumber` | ✅ |
| `fd_seek` | ✅ |
| `fd_sync` | ✅ |
| `fd_tell` | ✅ |
| `fd_write` | ✅ |

### Path Operations

| Function | Status |
|----------|--------|
| `path_create_directory` | ✅ |
| `path_filestat_get` | ✅ |
| `path_filestat_set_times` | ✅ |
| `path_link` | ✅ |
| `path_open` | ✅ |
| `path_readlink` | ✅ |
| `path_remove_directory` | ✅ |
| `path_rename` | ✅ |
| `path_symlink` | ✅ |
| `path_unlink_file` | ✅ |

### Polling

| Function | Status |
|----------|--------|
| `poll_oneoff` | ✅ |

### Process

| Function | Status |
|----------|--------|
| `proc_exit` | ✅ |
| `proc_raise` | ✅ |
| `sched_yield` | ✅ |

### Random

| Function | Status |
|----------|--------|
| `random_get` | ✅ |

### Sockets

| Function | Status |
|----------|--------|
| `sock_accept` | ✅ |
| `sock_recv` | ✅ |
| `sock_send` | ✅ |
| `sock_shutdown` | ✅ |

## CLI Integration

### Passing Arguments

```bash
# Pass arguments to WASM module
wasmz program.wasm --args "arg1 arg2 'arg with spaces'"
```

### Environment Variables

Environment variables are automatically inherited from the host process.

## Zig API Integration

```zig
const wasi = @import("wasi").preview1;

// Create WASI host
var wasi_host = wasi.Host.init(allocator);
defer wasi_host.deinit();

// Set arguments
try wasi_host.setArgs(&[_][]const u8{
    "program.wasm",
    "--verbose",
    "input.txt",
});

// Set environment variables
try wasi_host.setEnv("MY_VAR", "value");

// Pre-open directory
try wasi_host.preopenDir("/data", "/data");

// Add to linker
var linker = wasmz.Linker.empty;
try wasi_host.addToLinker(&linker, allocator);
```

## Pre-opened Directories

WASI uses pre-opened directories for filesystem access. By default:

- `/` is pre-opened as the current working directory
- Additional directories can be pre-opened via the API

```zig
// Pre-open specific directories
try wasi_host.preopenDir("/tmp", "/tmp");
try wasi_host.preopenDir("/home/user/data", "/data");
```

## Exit Code

When a WASM module calls `proc_exit`, the exit code is returned:

```zig
const result = try instance.call("_start", &.{});
if (result.trap) |trap| {
    if (trap.code == .Exit) {
        const exit_code = trap.exit_code;
        // Handle exit code
    }
}
```

## Exit Callback

Register a callback for `proc_exit`:

```zig
fn onExit(code: u32, ctx: ?*anyopaque) void {
    std.debug.print("Module exited with code {d}\n", .{code});
}

wasi_host.setOnExit(onExit, &my_context);
```

## Preview 2

WASI Preview 2 (Component Model) is **not yet supported**.  
Currently, almost no languages are actually using the Preview2 proposal either, Planned for future releases.

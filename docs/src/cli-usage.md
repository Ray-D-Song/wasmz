# CLI Usage

The `wasmz` command-line tool runs WebAssembly modules directly from the terminal.

## Basic Usage

```bash
# List exported functions
wasmz <file.wasm>

# Call a function with i32 arguments
wasmz <file.wasm> <func_name> [i32_args...]

# Run _start with WASI arguments
wasmz <file.wasm> --args "<wasm_args...>"
```

## Examples

### List Exports

```bash
$ wasmz module.wasm
Exported functions:
  add
  multiply
  greet
```

### Call a Function

```bash
# Call "add" with arguments 3 and 4
$ wasmz module.wasm add 3 4
7
```

### WASI Command Model

```bash
# Run _start with arguments passed to the WASM module
$ wasmz program.wasm --args "--verbose --output=result.txt"
```

### Reactor Mode

```bash
# Initialize reactor and call a function
$ wasmz library.wasm --reactor --func process -- input.txt
```

## Flags

| Flag | Description |
|------|-------------|
| `--legacy-exceptions` | Use legacy exception handling proposal |
| `--args "<string>"` | Arguments to pass to WASM module (space-separated) |
| `--func <name>` | Exported function to call |
| `--reactor` | Call `_initialize` before the function |
| `--mem-stats` | Print memory usage after execution |
| `--mem-trace` | Print RSS snapshots at each execution phase |
| `--mem-limit <MB>` | Set memory limit in megabytes |
| `--eager-compile` | Compile all functions eagerly at load time |
| `--smart-compile` | Auto-select compile mode: eager for modules < 3 MB, lazy otherwise |

## Memory Statistics

Use `--mem-stats` to analyze memory usage:

```bash
$ wasmz program.wasm --mem-stats
Memory usage:
  Linear memory:  1.00 MB  (16 pages)
  GC heap:        0.12 MB  (used 45.2 KB / capacity 128.0 KB)
  Shared memory:  0.00 MB  (none)
  ────────────────────────────────
  Total:          1.12 MB
```

## Memory Tracing

Use `--mem-trace` to print RSS snapshots at each execution phase (open, compile, instantiate, run):

```bash
$ wasmz program.wasm --mem-trace
[mem-trace] baseline (file mapped)    RSS 12.3 MB  (+12.3 MB)
[mem-trace] after compile             RSS 18.7 MB  (+6.4 MB)
[mem-trace] after instantiate         RSS 20.1 MB  (+1.4 MB)
[mem-trace] after _start              RSS 21.5 MB  (+1.4 MB)
```

Set the `WASMZ_PHASE_DIAG=1` environment variable to print detailed wall-clock timing for each phase to stderr:

```bash
$ WASMZ_PHASE_DIAG=1 wasmz program.wasm
[phase-diag] wasmz exit=_start return
[phase-diag]   open+mmap     :    0.342 ms
[phase-diag]   compile       :   12.101 ms
[phase-diag]   store+linker  :    0.082 ms
[phase-diag]   instantiate   :    1.203 ms
[phase-diag]   runStart      :    0.004 ms
[phase-diag]   _start        :  245.881 ms
[phase-diag]   total         :  259.613 ms
```

## Compilation Modes

By default, wasmz compiles functions lazily (on first call). Two flags control this behaviour:

| Flag | Description |
|------|-------------|
| `--eager-compile` | Compile every function during module load. Higher startup cost, zero lazy overhead at runtime. |
| `--smart-compile` | Automatically choose: eager for modules &lt; 3 MB, lazy otherwise (good default for interactive use). |

## Error Handling

When a trap occurs, wasmz prints the trap message:

```bash
$ wasmz module.wasm divide 1 0
error: trap: integer divide by zero
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error (file not found, compilation error, etc.) |
| N | WASI `proc_exit` code (if called by module) |

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
| `--mem-limit <MB>` | Set memory limit in megabytes |

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

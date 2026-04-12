# wasmz

A WebAssembly runtime written in [Zig](https://ziglang.org/), designed to be fast, compact, and easy to embed.

### Real-World Tested

Validated with production WASM workloads:
- **esbuild** - JavaScript bundler compiled to WASM
- **QuickJS** - Lightweight JavaScript engine compiled to WASM
- **SQLite** - Database engine compiled to WASM

## Features

### WebAssembly Support

- **MVP** - All core instructions and validation rules
- **Multi-value** - Functions and blocks with multiple return values
- **Bulk operations** - Memory and table bulk operations
- **Sign-extension** - Sign-extension instructions
- **GC** - Structs, arrays, and reference types with automatic memory management
- **SIMD** - 128-bit vector operations
- **Exception Handling** - Both legacy and new proposal formats
- **Threading** - Shared memory and atomic operations

### WASI Preview 1

Full implementation including:
- File system operations
- Socket operations
- Environment variables and arguments
- Random number generation
- Process control
- Clock and time operations

## Quick Start

```bash
# Clone and build
git clone https://github.com/Ray-D-Song/wasmz.git
cd wasmz
make build

# Run a WASM file
./zig-out/bin/wasmz module.wasm

# Call a function with arguments
./zig-out/bin/wasmz module.wasm add 3 4
# Output: 7
```

## Installation

### Prerequisites

- **Zig 0.15.2** - Download from [ziglang.org](https://ziglang.org/download/)
- **Git** - For cloning the repository
- **make** - For build commands

### Build Commands

| Command | Description |
|---------|-------------|
| `make build` | ReleaseSafe build (recommended) |
| `make build-debug` | Debug build (unoptimized) |
| `make release` | ReleaseFast build (maximum performance) |
| `make test` | Run all unit tests |
| `make install` | Install to `~/.local/bin` |

## CLI Usage

```bash
# List exported functions
wasmz module.wasm

# Call a function
wasmz module.wasm add 3 4

# Run _start with WASI arguments
wasmz program.wasm --args "--verbose --output=result.txt"

# Reactor mode (call _initialize first)
wasmz library.wasm --reactor --func process

# Memory statistics
wasmz program.wasm --mem-stats
```

## Zig API

```zig
const std = @import("std");
const wasmz = @import("wasmz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try wasmz.Engine.init(allocator, .{});
    defer engine.deinit();

    const bytes = try std.fs.cwd().readFileAlloc(allocator, "module.wasm", 1024 * 1024);
    defer allocator.free(bytes);

    var module = try wasmz.Module.compile(engine, bytes);
    defer module.deinit();

    var store = try wasmz.Store.init(allocator, engine);
    defer store.deinit();

    var instance = try wasmz.Instance.init(&store, module, .empty);
    defer instance.deinit();

    const result = try instance.call("add", &.{ .{ .i32 = 1 }, .{ .i32 = 2 } });
    std.debug.print("Result: {d}\n", .{result.ok.?.readAs(i32)});
}
```

## C API

Build the shared library:

```bash
make clib
```

Output:
- `zig-out/lib/libwasmz.{so,dylib,dll}`
- `zig-out/include/wasmz.h`

## Project Structure

```
wasmz/
├── src/
│   ├── root.zig          # Public API entry point
│   ├── main.zig          # CLI implementation
│   ├── capi.zig          # C API implementation
│   ├── core/             # Core data types
│   ├── parser/           # WASM binary parser
│   ├── compiler/         # Stack-to-register compiler
│   ├── engine/           # Execution engine
│   ├── vm/               # Virtual machine
│   ├── wasmz/            # High-level API
│   └── wasi/             # WASI implementation
├── include/
│   └── wasmz.h           # C API header
├── tests/                # Integration tests
└── docs/                 # Documentation
```

## Dependencies

- **zigrc**: Reference counting implementation (inlined in `src/libs/`)
- **libc**: Only for the C API

No external libraries required for the core runtime.

## Documentation

Full documentation available at [docs/src/SUMMARY.md](docs/src/SUMMARY.md):

- [Introduction](docs/src/introduction.md)
- [Installation](docs/src/installation.md)
- [CLI Usage](docs/src/cli-usage.md)
- [Zig API](docs/src/zig-api/README.md)
- [C API](docs/src/c-api.md)
- [WASI Support](docs/src/wasi.md)
- [Architecture](docs/src/architecture/README.md)

## License

MIT License - see [LICENSE](LICENSE) file for details.

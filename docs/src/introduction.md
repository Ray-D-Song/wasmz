# Introduction

**wasmz** is a WebAssembly runtime written in [Zig](https://ziglang.org/), designed to be fast, compact, and easy to embed. It implements a full-featured interpreter with support for modern WebAssembly proposals.

## Real-World Testing

wasmz passes real-world WebAssembly module tests:

- **esbuild** - JavaScript bundler compiled to WASM
- **QuickJS** - Lightweight JavaScript engine compiled to WASM
- **SQLite** - Database engine compiled to WASM

These integration tests validate wasmz's compatibility with production WASM workloads.

## WebAssembly Support

wasmz supports all current WebAssembly proposals.

- **MVP** - All core instructions and validation rules
- **Multi-value** - Functions and blocks with multiple return values
- **Bulk operations** - Memory and table bulk operations
- **Sign-extension** - Sign-extension instructions
- **GC** - Structs, arrays, and reference types with automatic memory management
- **SIMD** - 128-bit vector operations
- **Exception Handling** - Both legacy and new proposal formats
- **Threading** - Shared memory and atomic operations

## WASI Support

**WASI Preview 1** - Full implementation

- File system operations (fd_read, fd_write, path_open, etc.)
- Socket operations (sock_accept, sock_recv, sock_send, etc.)
- Environment variables and arguments
- Random number generation
- Process control (proc_exit, proc_raise)
- Clock and time operations
- Polling (poll_oneoff)

## Embedding

- **Zig API** - Native Zig interface with full type safety
- **C API** - Minimal C ABI for embedding in any language
- **CLI tool** - Standalone command-line runner

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

wasmz has minimal dependencies:

- **zigrc**: Reference counting implementation (inlined in `src/libs/`)
- **libc**: Only for the C API

No external libraries or system dependencies are required for the core runtime.

## Zig Version

wasmz requires **Zig 0.15.2** or compatible version.

## License

MIT License - see LICENSE file for details.

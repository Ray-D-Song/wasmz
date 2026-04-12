# Contributing

Thank you for your interest in contributing to wasmz!

## Development Setup

### Prerequisites

- Zig 0.15.2
- Git

### Clone and Build

```bash
git clone https://github.com/anomalyco/wasmz.git
cd wasmz
make build
```

## Running Tests

```bash
# Run all tests
make test
```

## Project Structure

```
src/
├── root.zig          # Public API exports
├── main.zig          # CLI implementation
├── capi.zig          # C API implementation
├── core/             # Core types (no dependencies)
│   ├── root.zig
│   ├── func_type.zig
│   ├── ref_type.zig
│   ├── heap_type.zig
│   ├── trap.zig
│   └── ...
├── parser/           # WASM binary parser
│   ├── root.zig
│   ├── payload.zig
│   └── tests/
├── compiler/         # Stack-to-register compiler
│   ├── root.zig
│   ├── ir.zig
│   ├── translate.zig
│   └── tests/
├── engine/           # Execution engine
│   ├── root.zig
│   ├── config.zig
│   └── func_ty.zig
├── vm/               # Virtual machine
│   ├── root.zig
│   └── gc/
├── wasmz/            # High-level API
│   ├── module.zig
│   ├── store.zig
│   ├── instance.zig
│   ├── host.zig
│   └── tests/
├── wasi/             # WASI implementation
│   ├── root.zig
│   └── preview1/
└── libs/             # Vendored dependencies
    └── zigrc/
```

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

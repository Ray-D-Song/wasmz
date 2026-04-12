# Architecture

This section describes wasmz's internal architecture for contributors.

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        Public API                            │
│  (root.zig - Engine, Module, Store, Instance, Linker)       │
└─────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────────────────────────────────────┐
│                       wasmz Module                           │
│  (High-level API implementation)                             │
└─────────────────────────────────────────────────────────────┘
                              │
┌──────────────┬──────────────┼──────────────┬───────────────┐
│    Parser    │   Compiler   │      VM       │    WASI       │
│              │              │               │               │
│  Binary      │  Stack-to-   │  Interpreter  │  Preview 1    │
│  Parser      │  Register    │  Engine       │  Host         │
│              │  Compiler    │               │               │
└──────────────┴──────────────┴───────────────┴───────────────┘
                              │
┌─────────────────────────────────────────────────────────────┐
│                     Core Types                               │
│  (Value types, ref types, heap types, trap, etc.)           │
└─────────────────────────────────────────────────────────────┘
```

## Pipeline

1. **Parse** - Binary parser reads the WASM module
2. **Compile** - Stack-to-register IR transformation
3. **Execute** - VM interpreter runs compiled IR

> **Note**: wasmz does not implement a validator. Use external tools like [wasm-tools](https://github.com/bytecodealliance/wasm-tools) to validate WASM modules before execution.

## Key Directories

| Directory | Purpose |
|-----------|---------|
| `src/core/` | Core data types (types, values, traps) |
| `src/parser/` | WASM binary parser |
| `src/compiler/` | IR generation and optimization |
| `src/engine/` | Function type handling, config |
| `src/vm/` | Virtual machine, GC heap |
| `src/wasmz/` | High-level API implementation |
| `src/wasi/` | WASI system interface |
| `src/validator/` | Placeholder (not implemented) |
| `src/libs/` | Vendored dependencies |

## Next Sections

- [Parser](./parser.md) - Binary parsing implementation
- [Compiler](./compiler.md) - Stack-to-register compilation
- [VM & Execution](./vm.md) - Interpreter execution engine
- [Garbage Collection](./gc.md) - GC heap implementation

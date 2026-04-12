# Parser

The parser reads WebAssembly binary format incrementally.

## Design

The parser is designed for streaming - it can parse modules larger than available memory by processing sections incrementally.

## Interface

```zig
const Parser = parser_mod.Parser.init();

while (true) {
    const n = try reader.readSliceShort(pending_buf[pending_len..]);
    const eof = n == 0;
    var input = pending_buf[0 .. pending_len + n];

    while (true) {
        switch (parser.parse(input, eof)) {
            .parsed => |result| {
                // Handle payload
                switch (result.payload) {
                    .module_header => |header| { /* ... */ },
                    .func => |func| { /* ... */ },
                    .code_section => |code| { /* ... */ },
                    else => {},
                }
                input = input[result.consumed..];
            },
            .need_more_data => {
                // Buffer remaining data and read more
                break;
            },
            .end => return,
            .err => |e| return e,
        }
    }
}
```

## Payloads

The parser emits payloads for each parsed element:

| Payload | Description |
|---------|-------------|
| `module_header` | Module magic and version |
| `type_section` | Function types |
| `import_section` | Imports |
| `func_section` | Function declarations |
| `code_section` | Function bodies |
| `data_section` | Data segments |
| `elem_section` | Element segments |
| `global_section` | Globals |
| `memory_section` | Memories |
| `table_section` | Tables |
| `export_section` | Exports |
| `start_section` | Start function |

## Validation

wasmz does not implement a full validator. Use external tools to validate WASM modules:

- [wasm-tools](https://github.com/bytecodealliance/wasm-tools) - Recommended
- [wabt](https://github.com/WebAssembly/wabt) - WebAssembly Binary Toolkit

Basic sanity checks are performed during parsing (e.g., section structure, index bounds).

## Memory Model

The parser allocates:

- **Payload data** - Temporary, freed after handling
- **Module metadata** - Types, imports, exports (owned by Module)

## Key Files

| File | Purpose |
|------|---------|
| `src/parser/root.zig` | Parser implementation |
| `src/parser/payload.zig` | Payload types |
| `src/parser/range.zig` | Source ranges for debugging |
| `src/parser/helper.zig` | Parsing utilities |

## Parallel Compilation

The parser can trigger parallel compilation:

```zig
// For each code section, after parsing body:
// 1. validate body
// 2. lower body (compile to register machine)
// These can run in separate threads
```

## Extension Proposals

New proposals are handled by:

1. Adding new payload types
2. Adding new opcodes to the compiler
3. Adding new validation rules

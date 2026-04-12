# Getting Started

This chapter covers installing wasmz and running your first WebAssembly program.

## Quick Start

```bash
# Clone and build
git clone https://github.com/anomalyco/wasmz.git
cd wasmz
zig build

# Run a WASM file
./zig-out/bin/wasmz examples/hello.wasm

# Call a specific function
./zig-out/bin/wasmz examples/add.wasm add 3 4
```

Next: [Installation](./installation.md) for detailed setup instructions.

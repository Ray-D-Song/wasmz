# wasmz

Safe Rust bindings for [wasmz](https://github.com/Ray-D-Song/wasmz).

Builds `libwasmz` via Zig (`zig build static-lib`) and exposes the C API as safe-ish Rust wrappers.

The wasmz sources are built from the same Git checkout as these bindings. Set
`WASMZ_ROOT` to point at another checkout explicitly when developing locally.

## Requirements

- Zig 0.16

## Usage

```rust
use wasmz_sys::{Engine, Instance, Linker, Module, Store, Val, ValKind};

let engine = Engine::new().unwrap();
let store = Store::new(&engine).unwrap();
let module = Module::compile(&engine, &wasm_bytes).unwrap();
let instance = Instance::new(&store, &module, None).unwrap();
let result = instance
    .call("add", &[Val::i32(1), Val::i32(2)], &[ValKind::I32])
    .unwrap();
```

Note that `Instance` borrows the `Store` it was created from, so drop it before
the store. `call` takes the expected result kinds because wasmz writes each
result back into a slot tagged with the kind the caller asked for.

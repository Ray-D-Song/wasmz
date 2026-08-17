# wasmz-sys

Raw Rust FFI bindings for the [wasmz](https://github.com/Ray-D-Song/wasmz) C API.

The build script compiles the Zig static library from the same Git checkout. Zig
0.16 is required. Set `WASMZ_ROOT` to use a different wasmz checkout while
developing locally.

Most Rust users should depend on the higher-level `wasmz` crate instead.


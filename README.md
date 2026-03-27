## WASMZ
WASM interpreter written in Zig.

## Dependency

- libs/zigrc: Reference Counting Implemented in Zig by Alex Andreba

Considering Zig's current package management and the language's own upgrade strategy, all dependencies are inlined as source code directly into the project for better migration in the future.

The refs directory contains some git submodules that serve as reference projects, which are unrelated to the wasmz build and do not need to be initialized.
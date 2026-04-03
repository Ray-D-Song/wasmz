The Compiler's function is to convert WASM's native stack machine to a register machine and perform some performance optimizations

The parser finishes reading the WASM module header information, and for every code section it finishes reading, it performs the parse body -> validate body -> lower body(compile to register machine) process.

The validation and compilation processes can be performed in a separate thread

1. wasmz ./test.wasm
2. Read file
3. ctx = wasmi.Context.init(allocator, file) // Prase wasm in init function, and generate Module
4. ctx.start() // Instantiation wasm instance, and start
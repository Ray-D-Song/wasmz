/// wasmz public API entry
///
/// External consumers can access the following types via `@import("wasmz")`:
///   - Engine / Config  : Runtime engine and configuration
///   - Module           : Compiled Wasm module (read-only)
///   - Store            : Runtime context holding allocator and Engine
///   - Instance         : Runtime instance of the module (including globals / memory)
///   - RawVal           : Generic value type (i32/i64/f32/f64 all stored as u64)
pub const Engine = @import("engine/mod.zig").Engine;
pub const Config = @import("engine/config.zig").Config;
pub const Module = @import("wasmz/module.zig").Module;
pub const Store = @import("wasmz/store.zig").Store;
pub const Instance = @import("wasmz/instance.zig").Instance;
pub const RawVal = @import("wasmz/instance.zig").RawVal;

// Include all submodule tests in the coverage of `zig build test`
test {
    _ = @import("engine/func_ty.zig");
    _ = @import("wasmz/module.zig");
    _ = @import("wasmz/store.zig");
    _ = @import("wasmz/instance.zig");
    _ = @import("wasmz/tests/poc_test.zig");
}

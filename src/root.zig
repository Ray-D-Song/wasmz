/// wasmz public API entry
///
/// External consumers can access the following types via `@import("wasmz")`:
///   - Engine / Config  : Runtime engine and configuration
///   - Module           : Compiled Wasm module (read-only)
///   - Store            : Runtime context holding allocator and Engine
///   - Instance         : Runtime instance of the module (including globals / memory)
///   - RawVal           : Generic value type (i32/i64/f32/f64 all stored as u64)
///   - Imports          : Two-level map of host-provided functions (module_name -> func_name -> HostFunc)
///   - HostFunc         : A single host-provided callable function
///   - ExecResult       : VM execution result (ok with optional return value, or trap)
///   - Trap / TrapCode  : Wasm runtime trap type and trap code enumeration
pub const Engine = @import("engine/mod.zig").Engine;
pub const ExecResult = @import("vm/mod.zig").ExecResult;
pub const Config = @import("engine/config.zig").Config;
pub const Module = @import("wasmz/module.zig").Module;
pub const Store = @import("wasmz/store.zig").Store;
pub const Instance = @import("wasmz/instance.zig").Instance;
pub const RawVal = @import("wasmz/instance.zig").RawVal;
pub const Imports = @import("wasmz/instance.zig").Imports;
pub const HostFunc = @import("wasmz/instance.zig").HostFunc;
pub const Trap = @import("wasmz/instance.zig").Trap;
pub const TrapCode = @import("wasmz/instance.zig").TrapCode;

// Include all submodule tests in the coverage of `zig build test`
test {
    _ = @import("engine/func_ty.zig");
    _ = @import("wasmz/module.zig");
    _ = @import("wasmz/store.zig");
    _ = @import("wasmz/instance.zig");
    _ = @import("wasmz/tests/poc_test.zig");
}

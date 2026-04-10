/// wasmz public API entry
///
/// External consumers can access the following types via `@import("wasmz")`:
///   - Engine / Config  : Runtime engine and configuration
///   - Module           : Compiled Wasm module (read-only)
///   - Store            : Runtime context holding allocator, Engine, and embedder user data
///   - Instance         : Runtime instance of the module (including globals / memory)
///   - RawVal           : Generic value type (i32/i64/f32/f64 all stored as u64)
///   - Linker           : Two-level map of host-provided functions (module_name -> func_name -> HostFunc)
///   - HostContext      : Per-call runtime view exposed to host functions
///   - HostFunc         : A single host-provided callable function
///   - ExecResult       : VM execution result (ok with optional return value, or trap)
///   - Trap / TrapCode  : Wasm runtime trap type and trap code enumeration
pub const Engine = @import("engine/root.zig").Engine;
pub const ExecResult = @import("vm/root.zig").ExecResult;
pub const Config = @import("engine/config.zig").Config;
pub const Module = @import("wasmz/module.zig").Module;
pub const Store = @import("wasmz/store.zig").Store;
pub const Instance = @import("wasmz/instance.zig").Instance;
pub const RawVal = @import("wasmz/instance.zig").RawVal;
pub const ValType = @import("core").ValType;
pub const Linker = @import("wasmz/host.zig").Linker;
pub const Imports = Linker;
pub const HostContext = @import("wasmz/host.zig").HostContext;
pub const HostError = @import("wasmz/host.zig").HostError;
pub const HostFunc = @import("wasmz/host.zig").HostFunc;
pub const HostInstance = @import("wasmz/host.zig").HostInstance;
pub const Trap = @import("wasmz/instance.zig").Trap;
pub const TrapCode = @import("wasmz/instance.zig").TrapCode;

// Include all submodule tests in the coverage of `zig build test`
test {
    _ = @import("engine/func_ty.zig");
    _ = @import("wasmz/module.zig");
    _ = @import("wasmz/store.zig");
    _ = @import("wasmz/instance.zig");
    _ = @import("wasmz/tests/poc_test.zig");
    _ = @import("wasmz/tests/module_test.zig");
    _ = @import("wasmz/tests/instance_test.zig");
    _ = @import("wasmz/tests/store_test.zig");
    _ = @import("wasmz/tests/host_test.zig");
}

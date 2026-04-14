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
///
/// Reactor model support:
///   Instance.initializeReactor()  — calls `_initialize` export if present
///   Instance.isCommand()          — true if module exports `_start`
///   Instance.isReactor()          — true if module does NOT export `_start`
///
/// Typical reactor usage:
///   var instance = try Instance.init(&store, arc.retain(), linker);
///   _ = try instance.initializeReactor();   // runs _initialize if exported
///   const result = try instance.call("my_func", &args);
pub const Engine = @import("engine/root.zig").Engine;
pub const ExecResult = @import("vm/root.zig").ExecResult;
pub const Config = @import("engine/config.zig").Config;
pub const Module = @import("wasmz/module.zig").Module;
pub const Store = @import("wasmz/store.zig").Store;
const instance_mod = @import("wasmz/instance.zig");
pub const Instance = instance_mod.Instance;
pub const RawVal = instance_mod.RawVal;
pub const ArcModule = instance_mod.ArcModule;
pub const Trap = instance_mod.Trap;
pub const TrapCode = instance_mod.TrapCode;
pub const printInitError = instance_mod.printInitError;
pub const ValType = @import("core").ValType;
pub const Linker = @import("wasmz/host.zig").Linker;
pub const Imports = Linker;
pub const HostContext = @import("wasmz/host.zig").HostContext;
pub const HostError = @import("wasmz/host.zig").HostError;
pub const HostFunc = @import("wasmz/host.zig").HostFunc;

/// Profiling utilities (conditional on -Dprofiling=true build option).
pub const profiling = @import("utils/profiling.zig");

// Include all submodule tests in the coverage of `zig build test`
test {
    _ = @import("engine/func_ty.zig");
    _ = @import("wasmz/module.zig");
    _ = @import("wasmz/store.zig");
    _ = @import("wasmz/instance.zig");
    _ = @import("wasmz/tests/poc_test.zig");
    _ = @import("wasmz/tests/module_test.zig");
    _ = @import("wasmz/tests/instance_test.zig");
    _ = @import("wasmz/tests/reactor_test.zig");
    _ = @import("wasmz/tests/store_test.zig");
    _ = @import("wasmz/tests/host_test.zig");
    _ = @import("wasmz/tests/eh_test.zig");
    _ = @import("wasmz/tests/multi_value_test.zig");
    _ = @import("wasmz/tests/atomic_test.zig");
    _ = @import("wasmz/tests/threads_test.zig");
}

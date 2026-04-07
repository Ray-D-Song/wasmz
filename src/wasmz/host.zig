/// host.zig - Host function import types
///
/// Defines the types used for providing host functions to a Wasm module:
///   - HostFunc:  A single callable host function (function pointer + opaque context).
///   - Imports:   A two-level map (module_name -> func_name -> HostFunc) that the
///                host fills before instantiating a Module.
const std = @import("std");
const vm_mod = @import("../vm/mod.zig");

const Allocator = std.mem.Allocator;
pub const RawVal = vm_mod.RawVal;
pub const ExecResult = vm_mod.ExecResult;

/// Function signature that a host-provided function must implement.
///
/// Parameters:
///   ctx       — Opaque pointer to caller-supplied context (may be null).
///   params    — Slice of arguments passed from the Wasm module.
///   allocator — Allocator provided by the VM; needed only if the host function
///               must allocate intermediate memory.  Allocation failures are
///               propagated as Zig errors, not as Wasm traps.
///
/// Returns:
///   Allocator.Error  — Host memory allocation failure (not a Wasm trap).
///   ExecResult.ok    — Normal return, with an optional return value.
///   ExecResult.trap  — Wasm trap raised by the host function.
pub const HostFuncFn = *const fn (
    ctx: ?*anyopaque,
    params: []const RawVal,
    allocator: Allocator,
) Allocator.Error!ExecResult;

/// A host-provided function together with its opaque context pointer.
pub const HostFunc = struct {
    ctx: ?*anyopaque,
    func: HostFuncFn,

    /// Convenience wrapper — calls `func` with `ctx` and the given arguments.
    pub fn call(
        self: HostFunc,
        params: []const RawVal,
        allocator: Allocator,
    ) Allocator.Error!ExecResult {
        return self.func(self.ctx, params, allocator);
    }
};

/// Two-level string map: module_name -> func_name -> HostFunc.
///
/// Usage:
///   var imports = Imports.empty;
///   try imports.define(allocator, "env", "my_func", host_func);
///   // ...pass to Instance.init...
///   imports.deinit(allocator);
pub const Imports = struct {
    map: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(HostFunc)),

    /// An empty Imports that requires no allocation.
    pub const empty: Imports = .{ .map = .empty };

    /// Register a host function under (module_name, func_name).
    ///
    /// Both strings must remain valid for the lifetime of this Imports value;
    /// the map stores slices, not copies.
    pub fn define(
        self: *Imports,
        allocator: Allocator,
        module_name: []const u8,
        func_name: []const u8,
        host_func: HostFunc,
    ) Allocator.Error!void {
        // Get or create the inner map for module_name.
        const gop = try self.map.getOrPut(allocator, module_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.put(allocator, func_name, host_func);
    }

    /// Look up a host function by (module_name, func_name).
    /// Returns null if not registered.
    pub fn get(
        self: *const Imports,
        module_name: []const u8,
        func_name: []const u8,
    ) ?HostFunc {
        const inner = self.map.get(module_name) orelse return null;
        return inner.get(func_name);
    }

    /// Free all memory owned by this Imports.
    /// Does not free the strings stored as keys (caller-owned).
    pub fn deinit(self: *Imports, allocator: Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |inner| {
            inner.deinit(allocator);
        }
        self.map.deinit(allocator);
        self.* = .empty;
    }
};

const std = @import("std");
const zigrc = @import("zigrc");
const Engine = @import("../engine/mod.zig").Engine;

// Wasm module
pub const Module = struct {
    inner: ModuleInnerRef,

    pub fn init(allocator: std.mem.Allocator) Module {
        return .{
            .inner = try ModuleInnerRef.init(allocator, ModuleInner.init()),
        };
    }
};

// ModuleInner is the actual module structure that holds the data.
// Module is just a reference-counted wrapper around it.
pub const ModuleInner = struct {
    engine: Engine,
};

const ModuleInnerRef = zigrc.Arc(ModuleInner);
const ModuleInnerWeak = ModuleInnerRef.Weak;

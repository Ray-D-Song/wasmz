const std = @import("std");
const zigrc = @import("zigrc");

const Allocator = std.mem.Allocator;
const Config = @import("./config.zig").Config;
const FuncTypeRegistry = @import("./func_ty.zig").FuncTypeRegistry;

var current_engine_id: u32 = 0;

pub const EngineId = struct {
    id: u32,

    pub fn init() EngineId {
        const next_idx = @atomicRmw(u32, &current_engine_id, .Add, 1, .acq_rel);
        return .{ .id = next_idx };
    }

    pub fn wrap(self: EngineId, comptime T: type, value: T) EngineOwned(T) {
        return .{
            .engine_id = self,
            .value = value,
        };
    }

    pub fn unwrap(self: EngineId, comptime T: type, owned: EngineOwned(T)) ?T {
        if (self.id != owned.engine_id.id) return null;
        return owned.value;
    }
};

pub fn EngineOwned(comptime T: type) type {
    return struct {
        engine_id: EngineId,
        value: T,
    };
}

const EngineInner = struct {
    id: EngineId,
    config: Config,
    // code_map: CodeMap,
    func_types: FuncTypeRegistry,
    // allocs: ReusableAllocationStack,
    // stacks: EngineStacks,

    fn init(allocator: Allocator, config_value: Config) EngineInner {
        return .{
            .id = EngineId.init(),
            .config = config_value,
            .func_types = FuncTypeRegistry.init(allocator, EngineId.init()),
        };
    }

    fn deinit(self: *EngineInner) void {
        _ = self;
    }
};

const EngineInnerRef = zigrc.Arc(EngineInner);
const EngineInnerWeak = EngineInnerRef.Weak;

pub const EngineWeak = struct {
    inner: EngineInnerWeak,

    pub fn clone(self: EngineWeak) EngineWeak {
        return .{
            .inner = self.inner.retain(),
        };
    }

    pub fn deinit(self: EngineWeak) void {
        self.inner.release();
    }

    pub fn upgrade(self: *EngineWeak) ?Engine {
        const inner = self.inner.upgrade() orelse return null;
        return .{ .inner = inner };
    }
};

pub const Engine = struct {
    inner: EngineInnerRef,

    pub fn init(allocator: Allocator, config_value: Config) Allocator.Error!Engine {
        return .{
            .inner = try EngineInnerRef.init(allocator, EngineInner.init(allocator, config_value)),
        };
    }

    pub fn clone(self: Engine) Engine {
        return .{
            .inner = self.inner.retain(),
        };
    }

    pub fn deinit(self: Engine) void {
        var inner = self.inner.releaseUnwrap() orelse return;
        inner.deinit();
    }

    pub fn weak(self: Engine) EngineWeak {
        return .{
            .inner = self.inner.downgrade(),
        };
    }

    pub fn config(self: Engine) *const Config {
        return &self.inner.value.config;
    }

    pub fn id(self: Engine) EngineId {
        return self.inner.value.id;
    }

    pub fn same(a: Engine, b: Engine) bool {
        return a.inner.value == b.inner.value;
    }
};

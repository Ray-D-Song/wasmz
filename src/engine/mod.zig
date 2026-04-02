const std = @import("std");
const zigrc = @import("zigrc");

const Allocator = std.mem.Allocator;
const Config = @import("./config.zig").Config;

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

const State = struct {
    id: EngineId,
    config: Config,
    // code_map: CodeMap,
    // func_types: FuncTypeRegistry,
    // allocs: ReusableAllocationStack,
    // stacks: EngineStacks,

    fn init(config_value: Config) State {
        return .{
            .id = EngineId.init(),
            .config = config_value,
        };
    }

    fn deinit(self: *State) void {
        _ = self;
    }
};

const StateRef = zigrc.Arc(State);
const StateWeak = StateRef.Weak;

pub const EngineWeak = struct {
    state: StateWeak,

    pub fn clone(self: EngineWeak) EngineWeak {
        return .{
            .state = self.state.retain(),
        };
    }

    pub fn deinit(self: EngineWeak) void {
        self.state.release();
    }

    pub fn upgrade(self: *EngineWeak) ?Engine {
        const state = self.state.upgrade() orelse return null;
        return .{ .state = state };
    }
};

pub const Engine = struct {
    state: StateRef,

    pub fn init(allocator: Allocator, config_value: Config) Allocator.Error!Engine {
        return .{
            .state = try StateRef.init(allocator, State.init(config_value)),
        };
    }

    pub fn clone(self: Engine) Engine {
        return .{
            .state = self.state.retain(),
        };
    }

    pub fn deinit(self: Engine) void {
        var state = self.state.releaseUnwrap() orelse return;
        state.deinit();
    }

    pub fn weak(self: Engine) EngineWeak {
        return .{
            .state = self.state.downgrade(),
        };
    }

    pub fn config(self: Engine) *const Config {
        return &self.state.value.config;
    }

    pub fn id(self: Engine) EngineId {
        return self.state.value.id;
    }

    pub fn same(a: Engine, b: Engine) bool {
        return a.state.value == b.state.value;
    }
};

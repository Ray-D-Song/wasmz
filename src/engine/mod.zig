const std = @import("std");
const zigrc = @import("zigrc");
const Allocator = std.mem.Allocator;

var current_engine_id: u32 = 0;

const EngineId = struct {
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

fn EngineOwned(comptime T: type) type {
    return struct {
        engine_id: EngineId,
        value: T,
    };
}

const EngineStruct = struct { config: Config };

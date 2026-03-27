pub const LimiterError = enum {
    ResourceLimiterDeniedAllocation,
};

pub fn limiterErrorMsg(err: LimiterError) []const u8 {
    return switch (err) {
        .ResourceLimiterDeniedAllocation => "a resource limiter denied allocation or growth of a linear memory or table",
    };
}

// The limit unit is resource target
pub const DEFAULT_INSTANCE_LIMIT: usize = 10_000;
pub const DEFAULT_TABLE_LIMIT: usize = 10_000;
pub const DEFAULT_MEMORY_LIMIT: usize = 10_000;

pub const StoreLimitsBuilder = struct {
    inner: StoreLimits,

    const Self = @This();

    pub fn init() Self {
        return .{ .inner = StoreLimits.init() };
    }

    pub fn memorySize(self: Self, limit: usize) Self {
        var result = self;
        result.inner.memory_size = limit;
        return result;
    }

    pub fn tableElements(self: Self, limit: usize) Self {
        var result = self;
        result.inner.table_elements = limit;
        return result;
    }

    pub fn instances(self: Self, limit: usize) Self {
        var result = self;
        result.inner.instances = limit;
        return result;
    }

    pub fn tables(self: Self, limit: usize) Self {
        var result = self;
        result.inner.tables = limit;
        return result;
    }

    pub fn memories(self: Self, limit: usize) Self {
        var result = self;
        result.inner.memories = limit;
        return result;
    }

    pub fn trapOnGrowFailure(self: Self, trap: bool) Self {
        var result = self;
        result.inner.trap_on_grow_failure = trap;
        return result;
    }

    pub fn build(self: Self) StoreLimits {
        return self.inner;
    }
};

pub const StoreLimits = struct {
    memory_size: ?usize,
    table_elements: ?usize,
    instances: usize,
    tables: usize,
    memories: usize,
    trap_on_grow_failure: bool,

    const Self = @This();

    pub fn init() Self {
        return .{
            .memory_size = null,
            .table_elements = null,
            .instances = DEFAULT_INSTANCE_LIMIT,
            .tables = DEFAULT_TABLE_LIMIT,
            .memories = DEFAULT_MEMORY_LIMIT,
            .trap_on_grow_failure = false,
        };
    }

    pub fn builder() StoreLimitsBuilder {
        return StoreLimitsBuilder.init();
    }

    pub fn memoryGrowing(
        self: *Self,
        current: usize,
        desired: usize,
        maximum: ?usize,
    ) LimiterError!bool {
        _ = current;
        const allow = if (self.memory_size) |limit|
            desired <= limit and withinMaximum(desired, maximum)
        else
            withinMaximum(desired, maximum);

        if (!allow and self.trap_on_grow_failure) {
            return LimiterError.ResourceLimiterDeniedAllocation;
        }
        return allow;
    }

    pub fn memoryGrowFailed(self: *Self, err: anytype) LimiterError!void {
        _ = err;
        if (self.trap_on_grow_failure) {
            return LimiterError.ResourceLimiterDeniedAllocation;
        }
    }

    pub fn tableGrowing(
        self: *Self,
        current: usize,
        desired: usize,
        maximum: ?usize,
    ) LimiterError!bool {
        _ = current;
        const allow = if (self.table_elements) |limit|
            desired <= limit and withinMaximum(desired, maximum)
        else
            withinMaximum(desired, maximum);

        if (!allow and self.trap_on_grow_failure) {
            return LimiterError.ResourceLimiterDeniedAllocation;
        }
        return allow;
    }

    pub fn tableGrowFailed(self: *Self, err: anytype) LimiterError!void {
        _ = err;
        if (self.trap_on_grow_failure) {
            return LimiterError.ResourceLimiterDeniedAllocation;
        }
    }

    pub fn getInstances(self: Self) usize {
        return self.instances;
    }

    pub fn getTables(self: Self) usize {
        return self.tables;
    }

    pub fn getMemories(self: Self) usize {
        return self.memories;
    }

    fn withinMaximum(desired: usize, maximum: ?usize) bool {
        return if (maximum) |max| desired <= max else true;
    }
};

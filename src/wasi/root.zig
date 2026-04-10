pub const preview1 = struct {
    pub const Host = @import("./preview1/host.zig").Host;
    pub const types = @import("./preview1/types.zig");
};

pub const preview2 = struct {};

test {
    _ = @import("preview1/tests/host_test.zig");
}

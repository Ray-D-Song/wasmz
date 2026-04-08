/// host.zig - Host function and linking surface
const std = @import("std");
const core = @import("core");
const store_mod = @import("./store.zig");
const module_mod = @import("./module.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const Module = module_mod.Module;
const FuncType = core.func_type.FuncType;
const Global = core.Global;
const RawVal = core.RawVal;
const Trap = core.Trap;
const TrapCode = core.TrapCode;
const ValType = core.ValType;

pub const HostError = Allocator.Error || error{HostTrap};

/// A readonly runtime view of the current instance passed to host calls.
pub const HostInstance = struct {
    module: *const Module,
    globals: []Global,
    memory: []u8,
    tables: []const []const u32,
};

/// Runtime context exposed to host functions.
///
/// This object is created per-host-call and must not be cached.
pub const HostContext = struct {
    store: *Store,
    host_instance: *HostInstance,
    host_data_ptr: ?*anyopaque,
    pending_trap: ?Trap = null,

    pub fn init(store: *Store, host_instance: *HostInstance, host_data_ptr: ?*anyopaque) HostContext {
        return .{
            .store = store,
            .host_instance = host_instance,
            .host_data_ptr = host_data_ptr,
        };
    }

    pub fn allocator(self: *HostContext) Allocator {
        return self.store.allocator;
    }

    pub fn memory(self: *HostContext) ?[]u8 {
        return if (self.host_instance.memory.len == 0) null else self.host_instance.memory;
    }

    pub fn user_data(self: *HostContext, comptime T: type) ?*T {
        return self.store.getUserData(T);
    }

    pub fn host_data(self: *HostContext, comptime T: type) ?*T {
        const ptr = self.host_instancePtrCast(T, self.host_data_ptr);
        return ptr;
    }

    pub fn globals(self: *HostContext) []Global {
        return self.host_instance.globals;
    }

    pub fn tables(self: *HostContext) []const []const u32 {
        return self.host_instance.tables;
    }

    pub fn instance(self: *HostContext) *HostInstance {
        return self.host_instance;
    }

    pub fn readBytes(self: *HostContext, ptr: u32, len: usize) HostError![]const u8 {
        const mem = self.memory() orelse {
            try self.raiseTrap(Trap.fromTrapCode(.MemoryOutOfBounds));
            unreachable;
        };
        const start: usize = ptr;
        const end = std.math.add(usize, start, len) catch {
            try self.raiseTrap(Trap.fromTrapCode(.MemoryOutOfBounds));
            unreachable;
        };
        if (end > mem.len) {
            try self.raiseTrap(Trap.fromTrapCode(.MemoryOutOfBounds));
            unreachable;
        }
        return mem[start..end];
    }

    pub fn writeBytes(self: *HostContext, ptr: u32, bytes: []const u8) HostError!void {
        const mem = self.memory() orelse {
            try self.raiseTrap(Trap.fromTrapCode(.MemoryOutOfBounds));
            unreachable;
        };
        const start: usize = ptr;
        const end = std.math.add(usize, start, bytes.len) catch {
            try self.raiseTrap(Trap.fromTrapCode(.MemoryOutOfBounds));
            unreachable;
        };
        if (end > mem.len) {
            try self.raiseTrap(Trap.fromTrapCode(.MemoryOutOfBounds));
            unreachable;
        }
        @memcpy(mem[start..end], bytes);
    }

    pub fn readValue(self: *HostContext, ptr: u32, comptime T: type) HostError!T {
        const bytes = try self.readBytes(ptr, @sizeOf(T));
        return std.mem.bytesToValue(T, bytes[0..@sizeOf(T)]);
    }

    pub fn writeValue(self: *HostContext, ptr: u32, value: anytype) HostError!void {
        var copy = value;
        return self.writeBytes(ptr, std.mem.asBytes(&copy));
    }

    pub fn readSlice(self: *HostContext, ptr: u32, len: usize, comptime T: type) HostError![]align(1) const T {
        const byte_len = std.math.mul(usize, len, @sizeOf(T)) catch {
            try self.raiseTrap(Trap.fromTrapCode(.MemoryOutOfBounds));
            unreachable;
        };
        const bytes = try self.readBytes(ptr, byte_len);
        const typed_ptr: [*]align(1) const T = @ptrCast(bytes.ptr);
        return typed_ptr[0..len];
    }

    pub fn write_value(self: *HostContext, ptr: u32, value: anytype) HostError!void {
        var copy = value;
        return self.writeBytes(ptr, std.mem.asBytes(&copy));
    }

    pub fn read_slice(self: *HostContext, ptr: u32, len: usize, comptime T: type) HostError![]align(1) const T {
        const byte_len = std.math.mul(usize, len, @sizeOf(T)) catch {
            try self.raiseTrap(Trap.fromTrapCode(.MemoryOutOfBounds));
            unreachable;
        };
        const bytes = try self.readBytes(ptr, byte_len);
        const typed_ptr: [*]align(1) const T = @ptrCast(bytes.ptr);
        return typed_ptr[0..len];
    }

    pub fn raiseTrap(self: *HostContext, trap: Trap) HostError!void {
        self.pending_trap = trap;
        return error.HostTrap;
    }

    pub fn takeTrap(self: *HostContext) Trap {
        const trap = self.pending_trap orelse Trap.hostMessage("host trap raised without payload");
        self.pending_trap = null;
        return trap;
    }

    fn host_instancePtrCast(self: *HostContext, comptime T: type, ptr: ?*anyopaque) ?*T {
        _ = self;
        const raw = ptr orelse return null;
        return @ptrCast(@alignCast(raw));
    }
};

pub const HostFuncFn = *const fn (
    host_data: ?*anyopaque,
    ctx: *HostContext,
    params: []const RawVal,
    results: []RawVal,
) HostError!void;

/// A host function together with its opaque host object and declared core-wasm signature.
///
/// `param_types` and `result_types` must remain valid for as long as this value
/// is stored in a [`Linker`] or an instantiated [`Instance`].
pub const HostFunc = struct {
    host_data: ?*anyopaque,
    func: HostFuncFn,
    param_types: []const ValType,
    result_types: []const ValType,

    pub fn init(
        host_data: ?*anyopaque,
        func: HostFuncFn,
        param_types: []const ValType,
        result_types: []const ValType,
    ) HostFunc {
        return .{
            .host_data = host_data,
            .func = func,
            .param_types = param_types,
            .result_types = result_types,
        };
    }

    pub fn call(
        self: HostFunc,
        ctx: *HostContext,
        params: []const RawVal,
        results: []RawVal,
    ) HostError!void {
        return self.func(self.host_data, ctx, params, results);
    }

    pub fn matches(self: HostFunc, func_type: FuncType) bool {
        return std.mem.eql(ValType, self.param_types, func_type.params()) and
            std.mem.eql(ValType, self.result_types, func_type.results());
    }
};

/// Two-level string map: module name -> function name -> HostFunc.
pub const Linker = struct {
    map: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(HostFunc)),

    pub const empty: Linker = .{ .map = .empty };

    pub fn define(
        self: *Linker,
        allocator: Allocator,
        module_name: []const u8,
        func_name: []const u8,
        host_func: HostFunc,
    ) Allocator.Error!void {
        const gop = try self.map.getOrPut(allocator, module_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.put(allocator, func_name, host_func);
    }

    pub fn get(
        self: *const Linker,
        module_name: []const u8,
        func_name: []const u8,
    ) ?HostFunc {
        const inner = self.map.get(module_name) orelse return null;
        return inner.get(func_name);
    }

    pub fn deinit(self: *Linker, allocator: Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |inner| {
            inner.deinit(allocator);
        }
        self.map.deinit(allocator);
        self.* = .empty;
    }
};

test "HostContext userData and hostData cast opaque pointers" {
    const testing = std.testing;
    const engine_mod = @import("../engine/mod.zig");
    const config_mod = @import("../engine/config.zig");

    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var user_value: i32 = 7;
    var store = Store.init(testing.allocator, engine);
    defer store.deinit();
    store.setUserData(&user_value);

    var host_value: i32 = 42;
    var globals = [_]Global{};
    var memory = [_]u8{ 1, 2, 3 };
    const tables = [_][]const u32{};
    var dummy_module = try module_mod.Module.compile(engine, &[_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60,
        0x00, 0x00, 0x03, 0x02,
        0x01, 0x00, 0x0a, 0x04,
        0x01, 0x02, 0x00, 0x0b,
    });
    defer dummy_module.deinit();

    var host_instance = HostInstance{
        .module = &dummy_module,
        .globals = globals[0..],
        .memory = memory[0..],
        .tables = tables[0..],
    };
    var ctx = HostContext.init(&store, &host_instance, &host_value);

    try testing.expectEqual(@as(i32, 7), ctx.user_data(i32).?.*);
    try testing.expectEqual(@as(i32, 42), ctx.host_data(i32).?.*);
}

test "HostContext readBytes traps on out of bounds" {
    const testing = std.testing;
    const engine_mod = @import("../engine/mod.zig");
    const config_mod = @import("../engine/config.zig");

    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = Store.init(testing.allocator, engine);
    defer store.deinit();

    var globals = [_]Global{};
    var memory = [_]u8{ 1, 2, 3 };
    const tables = [_][]const u32{};
    var dummy_module = try module_mod.Module.compile(engine, &[_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60,
        0x00, 0x00, 0x03, 0x02,
        0x01, 0x00, 0x0a, 0x04,
        0x01, 0x02, 0x00, 0x0b,
    });
    defer dummy_module.deinit();

    var host_instance = HostInstance{
        .module = &dummy_module,
        .globals = globals[0..],
        .memory = memory[0..],
        .tables = tables[0..],
    };
    var ctx = HostContext.init(&store, &host_instance, null);

    try testing.expectError(error.HostTrap, ctx.readBytes(2, 2));
    const trap = ctx.takeTrap();
    try testing.expectEqual(@as(?TrapCode, .MemoryOutOfBounds), trap.trapCode());
}

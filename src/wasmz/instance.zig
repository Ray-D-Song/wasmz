/// instance.zig - WebAssembly Instance
///
/// Instance is a runtime instantiation of a Module, containing the mutable state during execution.
/// It is created from a compiled Module and holds:
///   - globals: an array of global variables copied and initialized from module.globals
///   - memory:  linear memory allocated based on module.memory.min_pages
///
/// TODO: support imports and exports
/// TODO: make Instance reference-counted (Arc) to allow sharing between multiple contexts (e.g. threads).
const std = @import("std");
const core = @import("core");
const store_mod = @import("./store.zig");
const module_mod = @import("./module.zig");
const vm_mod = @import("../vm/mod.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const Module = module_mod.Module;
const Global = core.Global;
const GlobalType = core.GlobalType;
const VM = vm_mod.VM;
pub const RawVal = vm_mod.RawVal;

/// The number of bytes in a single WebAssembly memory page (64 KiB).
const WASM_PAGE_SIZE: usize = 65536;

pub const InstanceError = Allocator.Error || error{
    ExportNotFound,
};

pub const Instance = struct {
    store: *Store,
    /// Read-only module reference; the caller is responsible for ensuring the Module remains valid for the lifetime of the Instance.
    /// TODO: Upgrade to Arc(Module) to support multiple Instances sharing the same Module.
    module: *const Module,
    /// Runtime globals, copied and initialized from module.globals.
    globals: []Global,
    /// Linear memory, allocated based on module.memory.min_pages * WASM_PAGE_SIZE.
    /// If the module has no memory section, this will be an empty slice.
    memory: []u8,

    /// Instantiate a Module.
    ///
    /// Parameters:
    ///   store   — The runtime context holding the allocator and engine.
    ///   module  — A compiled read-only Module (the caller is responsible for its lifetime).
    ///   imports — Not used now, pass void.
    pub fn init(store: *Store, module: *const Module, imports: anytype) InstanceError!Instance {
        _ = imports;
        const allocator = store.allocator;

        // ── 1. copy globals ──────────────────────────────────────────
        const globals = try allocator.alloc(Global, module.globals.len);
        errdefer allocator.free(globals);

        for (module.globals, 0..) |global_init, i| {
            globals[i] = Global.init(
                GlobalType.init(global_init.mutability, global_init.value.ty),
                global_init.value.value,
            );
        }

        // ── 2. allocate memory ──────────────────────────────────────────────────
        const memory: []u8 = if (module.memory) |mem_def| blk: {
            const byte_count = @as(usize, mem_def.min_pages) * WASM_PAGE_SIZE;
            const buf = try allocator.alloc(u8, byte_count);
            @memset(buf, 0);
            break :blk buf;
        } else &[0]u8{};

        return .{
            .store = store,
            .module = module,
            .globals = globals,
            .memory = memory,
        };
    }

    pub fn deinit(self: *Instance) void {
        const allocator = self.store.allocator;
        allocator.free(self.globals);
        // Only free memory if it exists (empty slice does not need free).
        if (self.memory.len > 0) {
            allocator.free(self.memory);
        }
        self.* = undefined;
    }

    /// Call an exported function by name.
    ///
    /// Parameters:
    ///   name — The name of the exported function
    ///   args — Function arguments
    ///
    /// Returns: The return value of the function (null for void functions)
    pub fn call(self: *Instance, name: []const u8, args: []const RawVal) !?RawVal {
        const export_entry = self.module.exports.get(name) orelse return error.ExportNotFound;
        const func = self.module.functions[export_entry.function_index];
        var vm = VM.init(self.store.allocator);
        return vm.execute(func, args, self.globals, self.memory);
    }
};

test "Instance.init allocates globals and memory" {
    const testing = std.testing;
    const engine_mod = @import("../engine/mod.zig");
    const config_mod = @import("../engine/config.zig");

    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = Store.init(testing.allocator, engine);
    defer store.deinit();

    // Use a minimal wasm module with a memory section and a global variable for end-to-end testing.
    // (type)   (func)   (global i32 const 42) (memory 1) (export)
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, // magic
        0x01, 0x00, 0x00, 0x00, // version
        // type section: () -> ()
        0x01, 0x04, 0x01, 0x60,
        0x00, 0x00,
        // function section: func 0 uses type 0
        0x03, 0x02,
        0x01, 0x00,
        // global section: i32 const 42
        0x06, 0x06,
        0x01, 0x7f, 0x00, 0x41,
        0x2a, 0x0b,
        // memory section: 1 page min, no max
        0x05, 0x03,
        0x01, 0x00, 0x01,
        // code section: empty body for func 0
        0x0a,
        0x04, 0x01, 0x02, 0x00,
        0x0b,
    };

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, {});
    defer instance.deinit();

    // Verify that globals are correctly copied
    try testing.expectEqual(@as(usize, 1), instance.globals.len);
    try testing.expectEqual(@as(i32, 42), instance.globals[0].getRawValue().readAs(i32));

    // Verify that linear memory is allocated and zero-initialized
    try testing.expectEqual(@as(usize, 65536), instance.memory.len);
    try testing.expectEqual(@as(u8, 0), instance.memory[0]);
    try testing.expectEqual(@as(u8, 0), instance.memory[65535]);
}

test "Instance.init with no memory section" {
    const testing = std.testing;
    const engine_mod = @import("../engine/mod.zig");
    const config_mod = @import("../engine/config.zig");

    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = Store.init(testing.allocator, engine);
    defer store.deinit();

    // Minimal wasm: only an empty function, no memory/global section
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type: () -> ()
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        // function: func 0 -> type 0
        0x03, 0x02,
        0x01, 0x00,
        // code: empty body
        0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
    };

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, {});
    defer instance.deinit();

    try testing.expectEqual(@as(usize, 0), instance.globals.len);
    try testing.expectEqual(@as(usize, 0), instance.memory.len);
}

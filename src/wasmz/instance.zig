/// instance.zig - WebAssembly Instance
///
/// Instance is a runtime instantiation of a Module, containing the mutable state during execution.
/// It is created from a compiled Module and holds:
///   - globals:    an array of global variables copied and initialized from module.globals
///   - memory:     linear memory allocated based on module.memory.min_pages
///   - host_funcs: resolved host functions for each imported function slot
///
/// TODO: make Instance reference-counted (Arc) to allow sharing between multiple contexts (e.g. threads).
const std = @import("std");
const core = @import("core");
const store_mod = @import("./store.zig");
const module_mod = @import("./module.zig");
const host_mod = @import("./host.zig");
const vm_mod = @import("../vm/mod.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const Module = module_mod.Module;
const Global = core.Global;
const GlobalType = core.GlobalType;
const VM = vm_mod.VM;
const HostInstance = host_mod.HostInstance;
pub const RawVal = vm_mod.RawVal;
/// Wasm runtime trap, carrying TrapCode and optional description
pub const Trap = vm_mod.Trap;
/// TrapCode enumeration, used to determine the type of trap in ExecResult.trap
pub const TrapCode = vm_mod.TrapCode;
/// Instance.call result: either a normal return (with optional value for void functions) or a Wasm trap
pub const ExecResult = vm_mod.ExecResult;
pub const HostFunc = host_mod.HostFunc;
pub const Linker = host_mod.Linker;
pub const Imports = Linker;

/// The number of bytes in a single WebAssembly memory page (64 KiB).
const WASM_PAGE_SIZE: usize = 65536;

pub const InstanceError = Allocator.Error || error{
    ExportNotFound,
    /// A function import required by the module was not provided in the Imports map
    ImportNotSatisfied,
    /// A host-provided function's signature does not match the imported function type.
    ImportSignatureMismatch,
    /// Start function index overflows the number of functions in the module
    InvalidStartFunctionIndex,
    /// Start function returns a value, which violates the Wasm specification that start functions must be void
    StartFunctionMustBeVoid,
    /// Start function raised a Wasm trap during instantiation
    StartFunctionTrapped,
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
    /// Resolved host functions for each imported function slot, in the same order as module.imported_funcs.
    /// Length == module.imported_funcs.len.
    host_funcs: []HostFunc,
    host_view: HostInstance,
    /// Tracks which data segments have been dropped via data.drop instruction.
    /// data_segments_dropped[i] == true means segment i cannot be used by memory.init.
    data_segments_dropped: []bool,

    /// Instantiate a Module.
    ///
    /// Parameters:
    ///   store   — The runtime context holding the allocator and engine.
    ///   module  — A compiled read-only Module (the caller is responsible for its lifetime).
    ///   imports — Host-provided functions satisfying the module's imports.
    ///             Pass `Imports.empty` for modules with no imports.
    pub fn init(store: *Store, module: *const Module, imports: Linker) InstanceError!Instance {
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
        errdefer if (memory.len > 0) allocator.free(memory);

        // ── 3. resolve host functions ────────────────────────────────────────────
        // Build a flat slice parallel to module.imported_funcs, looking up each
        // import by (module_name, func_name) in the provided Imports map.
        const host_funcs = try allocator.alloc(HostFunc, module.imported_funcs.len);
        errdefer allocator.free(host_funcs);

        for (module.imported_funcs, 0..) |def, i| {
            const hf = imports.get(def.module_name, def.func_name) orelse {
                std.debug.print("ImportNotSatisfied: module='{s}' func='{s}'\n", .{ def.module_name, def.func_name });
                return error.ImportNotSatisfied;
            };
            if (!hf.matches(module.func_types[def.type_index])) {
                return error.ImportSignatureMismatch;
            }
            host_funcs[i] = hf;
        }

        var host_view = HostInstance{
            .module = module,
            .globals = globals,
            .memory = memory,
            .tables = module.tables,
        };

        // ── 4. initialize data segment dropped flags ───────────────────────────────
        const data_segments_dropped = try allocator.alloc(bool, module.data_segments.len);
        errdefer allocator.free(data_segments_dropped);
        @memset(data_segments_dropped, false);

        store.registerInstance();
        errdefer store.unregisterInstance();

        // ── 5. call start function (if exists) ──────────────────────────────────
        // Wasm specification: The function specified in the Start Section is automatically executed during instantiation, with no parameters and no return value.
        if (module.start_function) |start_idx| {
            if (start_idx >= module.functions.len) {
                return error.InvalidStartFunctionIndex;
            }
            const start_func = module.functions[start_idx];
            var vm = VM.init(store.allocator);
            const exec_r = try vm.execute(
                start_func,
                &.{},
                store,
                &host_view,
                globals,
                memory,
                module.functions,
                module.func_types,
                host_funcs,
                module.tables,
                module.func_type_indices,
                module.data_segments,
                data_segments_dropped,
            );
            switch (exec_r) {
                // start function triggered a trap: instantiation failed
                .trap => return error.StartFunctionTrapped,
                // start function has a return value: violates Wasm specification
                .ok => |ret_val| if (ret_val != null) return error.StartFunctionMustBeVoid,
            }
        }

        return .{
            .store = store,
            .module = module,
            .globals = globals,
            .memory = memory,
            .host_funcs = host_funcs,
            .host_view = host_view,
            .data_segments_dropped = data_segments_dropped,
        };
    }

    pub fn deinit(self: *Instance) void {
        const allocator = self.store.allocator;
        allocator.free(self.globals);
        // Only free memory if it exists (empty slice does not need free).
        if (self.memory.len > 0) {
            allocator.free(self.memory);
        }
        allocator.free(self.host_funcs);
        allocator.free(self.data_segments_dropped);
        self.store.unregisterInstance();
        self.* = undefined;
    }

    /// Call an exported function by name.
    ///
    /// Parameters:
    ///   name — The name of the exported function
    ///   args — Function arguments
    ///
    /// Returns:
    ///   error.ExportNotFound     — The export with the given name does not exist
    ///   Allocator.Error          — Host memory allocation failure
    ///   ExecResult.ok(val)       — Normal execution completed, val is the return value (null for void functions)
    ///   ExecResult.trap(trap)    — Wasm runtime trap (e.g., out-of-bounds memory access)
    pub fn call(self: *Instance, name: []const u8, args: []const RawVal) (Allocator.Error || error{ExportNotFound})!ExecResult {
        const export_entry = self.module.exports.get(name) orelse return error.ExportNotFound;
        const func = self.module.functions[export_entry.function_index];
        var vm = VM.init(self.store.allocator);
        return vm.execute(
            func,
            args,
            self.store,
            &self.host_view,
            self.globals,
            self.memory,
            self.module.functions,
            self.module.func_types,
            self.host_funcs,
            self.module.tables,
            self.module.func_type_indices,
            self.module.data_segments,
            self.data_segments_dropped,
        );
    }
};

test "Instance.call executes exported function end-to-end" {
    const testing = std.testing;
    const engine_mod = @import("../engine/mod.zig");
    const config_mod = @import("../engine/config.zig");

    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = Store.init(testing.allocator, engine);
    defer store.deinit();

    // (i32, i32) -> i32  add function, exported as "add"
    // type: (i32,i32)->i32 | func[0]=type[0] | export "add"->func[0] | body: local.get 0, local.get 1, i32.add, end
    const add_wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type section
        0x03, 0x02, 0x01, 0x00, // function section
        0x07, 0x07, 0x01, 0x03, 'a', 'd', 'd', 0x00, 0x00, // export section
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b, // code section
    };

    var module = try Module.compile(engine, &add_wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
    defer instance.deinit();

    const args = [_]RawVal{
        RawVal.from(@as(i32, 20)),
        RawVal.from(@as(i32, 22)),
    };
    const exec_r = try instance.call("add", &args);
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 42), result.readAs(i32));
}

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

    var instance = try Instance.init(&store, &module, Imports.empty);
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

    var instance = try Instance.init(&store, &module, Imports.empty);
    defer instance.deinit();

    try testing.expectEqual(@as(usize, 0), instance.globals.len);
    try testing.expectEqual(@as(usize, 0), instance.memory.len);
}

test "Instance.call supports inter-function calls (double via add)" {
    // WAT：
    //   (module
    //     (func $add (param i32 i32) (result i32)
    //       local.get 0
    //       local.get 1
    //       i32.add)
    //     (func $double (export "double") (param i32) (result i32)
    //       local.get 0
    //       local.get 0
    //       call $add)
    //   )
    //
    const testing = std.testing;
    const engine_mod = @import("../engine/mod.zig");
    const config_mod = @import("../engine/config.zig");

    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = Store.init(testing.allocator, engine);
    defer store.deinit();

    //   type[0]: (i32,i32)->i32   type[1]: (i32)->i32
    //   func[0]=type[0] (add), func[1]=type[1] (double)
    //   export "double" -> func[1]
    //   add  body: local.get 0, local.get 1, i32.add, end
    //   double body: local.get 0, local.get 0, call 0, end
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x0c, 0x02, // type section: 2 types
        0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type[0]: (i32,i32)->i32
        0x60, 0x01, 0x7f, 0x01, 0x7f, // type[1]: (i32)->i32
        0x03, 0x03, 0x02, 0x00, 0x01, // function section: func[0]=type[0], func[1]=type[1]
        0x07, 0x0a, 0x01, // export section
        0x06, 0x64, 0x6f, 0x75, 0x62, 0x6c, 0x65, 0x00, 0x01, // "double" -> func[1]
        0x0a, 0x12, 0x02, // code section: 2 bodies
        // body[0] add: local.get 0; local.get 1; i32.add; end
        0x07, 0x00, 0x20,
        0x00, 0x20, 0x01,
        0x6a, 0x0b,
        // body[1] double: local.get 0; local.get 0; call 0; end
        0x08,
        0x00, 0x20, 0x00,
        0x20, 0x00, 0x10,
        0x00, 0x0b,
    };

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
    defer instance.deinit();

    const args = [_]RawVal{RawVal.from(@as(i32, 7))};
    const exec_r = try instance.call("double", &args);
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 14), result.readAs(i32));
}

test "Instance.init auto-calls start function" {
    // Verify that the start function is automatically called during instantiation:
    // The module contains a mutable global (initial value 0), and the start function sets it to 42;
    // After instantiation, we directly check that the global value has become 42.
    //
    // WAT equivalent:
    //   (module
    //     (global (mut i32) (i32.const 0))   ;; global 0
    //     (func (global.set 0 (i32.const 42)))  ;; func 0 = start
    //     (start 0)
    //   )
    //
    // Binary manually constructed:
    //   magic+version
    //   type section:   1 type, () -> ()
    //   func section:   func 0 -> type 0
    //   global section: 1 global, i32 mut, init = i32.const 0
    //   start section:  func index 0
    //   code section:   func 0 body: global.set 0 (i32.const 42), end
    const testing = std.testing;
    const engine_mod = @import("../engine/mod.zig");
    const config_mod = @import("../engine/config.zig");

    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = Store.init(testing.allocator, engine);
    defer store.deinit();

    const wasm = [_]u8{
        // magic + version
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type section: 1 type, () -> ()
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        // function section: func 0 -> type 0
        0x03, 0x02,
        0x01, 0x00,
        // global section: 1 global, i32 var, init = i32.const 0
        0x06, 0x06, 0x01, 0x7f, 0x01, 0x41,
        0x00, 0x0b,
        // start section: func index 0
        0x08, 0x01, 0x00,
        // code section: func 0 body = i32.const 42, global.set 0, end
        // body length = 6: local count = 0x00, i32.const (0x41) 42 (0x2a), global.set (0x24) 0 (0x00), end (0x0b)
        0x0a, 0x08, 0x01,
        0x06, 0x00, 0x41, 0x2a, 0x24, 0x00, 0x0b,
    };

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    // start_function field should be parsed as 0
    try testing.expectEqual(@as(?u32, 0), module.start_function);

    var instance = try Instance.init(&store, &module, Imports.empty);
    defer instance.deinit();

    // start function has been automatically executed during instantiation, global 0 value should be 42
    try testing.expectEqual(@as(i32, 42), instance.globals[0].getRawValue().readAs(i32));
}

test "Instance.call: i32.store and i32.load round-trip" {
    // WAT:
    //   (module
    //     (memory 1)
    //     (func (export "f") (param i32 i32) (result i32)
    //       local.get 0        ;; address
    //       local.get 1        ;; value
    //       i32.store          ;; store val at mem[addr]
    //       local.get 0        ;; address again
    //       i32.load)          ;; load from mem[addr] -> result
    //   )
    //
    // Binary layout:
    //   magic+version
    //   type section:     (i32,i32)->i32
    //   function section: func[0]=type[0]
    //   memory section:   1 page min, no max
    //   export section:   "f" -> func[0]
    //   code section:     body above
    //
    // i32.store encoding: 0x36 <align_leb> <offset_leb>  (align=2, offset=0)
    // i32.load  encoding: 0x28 <align_leb> <offset_leb>  (align=2, offset=0)
    const testing = std.testing;
    const engine_mod = @import("../engine/mod.zig");
    const config_mod = @import("../engine/config.zig");

    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = Store.init(testing.allocator, engine);
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, // type section: (i32,i32)->i32
        0x7f,
        0x03, 0x02, 0x01, 0x00, // function section
        0x05, 0x03, 0x01, 0x00, 0x01, // memory section: 1 page
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f" -> func[0]
        0x0a, 0x10, 0x01, // code section
        0x0e, 0x00, // body len=14, 0 locals
        0x20, 0x00, // local.get 0
        0x20, 0x01, // local.get 1
        0x36, 0x02, 0x00, // i32.store align=2 offset=0
        0x20, 0x00, // local.get 0
        0x28, 0x02, 0x00, // i32.load align=2 offset=0
        0x0b, // end
    };

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
    defer instance.deinit();

    // store 0xDEADBEEF at address 8, then load it back
    const addr = RawVal.from(@as(i32, 8));
    const val = RawVal.from(@as(i32, @bitCast(@as(u32, 0xDEADBEEF))));
    const exec_r = try instance.call("f", &.{ addr, val });
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, @bitCast(@as(u32, 0xDEADBEEF))), result.readAs(i32));
}

test "Instance.call: i32.store8, i32.load8_u, i32.load8_s" {
    // WAT:
    //   (module
    //     (memory 1)
    //     (func (export "store8") (param i32 i32)
    //       local.get 0
    //       local.get 1
    //       i32.store8)
    //     (func (export "load8u") (param i32) (result i32)
    //       local.get 0
    //       i32.load8_u)
    //     (func (export "load8s") (param i32) (result i32)
    //       local.get 0
    //       i32.load8_s)
    //   )
    //
    // i32.store8  = 0x3a align=0 offset=0
    // i32.load8_u = 0x2d align=0 offset=0
    // i32.load8_s = 0x2c align=0 offset=0
    const testing = std.testing;
    const engine_mod = @import("../engine/mod.zig");
    const config_mod = @import("../engine/config.zig");

    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = Store.init(testing.allocator, engine);
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0b, 0x02, 0x60,
        0x02, 0x7f, 0x7f, 0x00, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x03, 0x04, 0x03,
        0x00, 0x01, 0x01, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x1c, 0x03, 0x06,
        0x73, 0x74, 0x6f, 0x72, 0x65, 0x38, 0x00, 0x00, 0x06, 0x6c, 0x6f, 0x61,
        0x64, 0x38, 0x75, 0x00, 0x01, 0x06, 0x6c, 0x6f, 0x61, 0x64, 0x38, 0x73,
        0x00, 0x02, 0x0a, 0x1b, 0x03, 0x09, 0x00, 0x20, 0x00, 0x20, 0x01, 0x3a,
        0x00, 0x00, 0x0b, 0x07, 0x00, 0x20, 0x00, 0x2d, 0x00, 0x00, 0x0b, 0x07,
        0x00, 0x20, 0x00, 0x2c, 0x00, 0x00, 0x0b,
    };

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
    defer instance.deinit();

    // store 0xFF (= -1 signed, 255 unsigned) at address 4
    const addr = RawVal.from(@as(i32, 4));
    // store8 is a void function, expect ExecResult.ok(null)
    const store_r = try instance.call("store8", &.{ addr, RawVal.from(@as(i32, 0xFF)) });
    try testing.expectEqual(@as(?RawVal, null), store_r.ok);

    // load8_u should give 255 (zero-extended)
    const r_u = (try instance.call("load8u", &.{addr})).ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, 255), r_u.readAs(i32));

    // load8_s should give -1 (sign-extended)
    const r_s = (try instance.call("load8s", &.{addr})).ok orelse return error.MissingReturnValue;
    try testing.expectEqual(@as(i32, -1), r_s.readAs(i32));
}

test "Instance.call: memory out-of-bounds returns trap" {
    // A function that loads from address that exceeds the memory size.
    // WAT:
    //   (module
    //     (memory 1)           ;; 65536 bytes
    //     (func (export "f") (param i32) (result i32)
    //       local.get 0
    //       i32.load)          ;; load 4 bytes at param
    //   )
    const testing = std.testing;
    const engine_mod = @import("../engine/mod.zig");
    const config_mod = @import("../engine/config.zig");

    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = Store.init(testing.allocator, engine);
    defer store.deinit();

    const wasm = [_]u8{
        // magic + version
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type: (i32)->i32
        0x01, 0x05, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
        // function: func[0]=type[0]
        0x03, 0x02, 0x01, 0x00,
        // memory: 1 page min
        0x05, 0x03, 0x01, 0x00,
        0x01,
        // export: "f" -> func[0]
        0x07, 0x05, 0x01, 0x01, 'f',  0x00, 0x00,
        // code: local.get 0; i32.load align=2 offset=0; end
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x28,
        0x02, 0x00, 0x0b,
    };

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
    defer instance.deinit();

    // address 65533 + 4 bytes = 65537 > 65536: out of bounds
    const oob_addr = RawVal.from(@as(i32, 65533));
    const exec_r = try instance.call("f", &.{oob_addr});
    // Expect a trap, trap code should be MemoryOutOfBounds
    try testing.expectEqual(TrapCode.MemoryOutOfBounds, exec_r.trap.trapCode().?);
}

// ── Host function import tests ────────────────────────────────────────────────

test "Instance: host function import (env.add_one) is called correctly" {
    // WAT:
    //   (module
    //     (type (;0;) (func (param i32) (result i32)))
    //     (import "env" "add_one" (func (type 0)))   ;; func[0] = import
    //     (func (type 0)                              ;; func[1] = local
    //       local.get 0
    //       call 0)
    //     (export "run" (func 1))
    //   )
    const testing_mod = std.testing;
    const engine_mod = @import("../engine/mod.zig");
    const config_mod = @import("../engine/config.zig");

    var engine = try engine_mod.Engine.init(testing_mod.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = Store.init(testing_mod.allocator, engine);
    defer store.deinit();

    // Wasm binary for the module described above.
    const wasm = [_]u8{
        // magic + version
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type section: type[0] = (i32)->i32
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
        // import section: "env"."add_one" kind=func type=0
        0x02, 0x0f, 0x01,
        0x03, 0x65, 0x6e, 0x76, // module = "env"
        0x07, 0x61, 0x64, 0x64, 0x5f, 0x6f, 0x6e, 0x65, // field = "add_one"
        0x00, 0x00, // kind=function, type_index=0
        // function section: func[1] = type[0]
        0x03, 0x02,
        0x01, 0x00,
        // export section: "run" -> func[1]
        0x07, 0x07,
        0x01, 0x03,
        0x72, 0x75,
        0x6e, 0x00,
        0x01,
        // code section: 1 body (local.get 0; call 0; end)
        0x0a,
        0x08, 0x01,
        0x06, 0x00,
        0x20, 0x00,
        0x10, 0x00,
        0x0b,
    };

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    // Verify the import is recorded in module metadata.
    try testing_mod.expectEqual(@as(usize, 1), module.imported_funcs.len);
    try testing_mod.expectEqualStrings("env", module.imported_funcs[0].module_name);
    try testing_mod.expectEqualStrings("add_one", module.imported_funcs[0].func_name);

    // Host implementation: returns param + 1.
    const HostCtx = struct {
        fn add_one(
            _: ?*anyopaque,
            _: *host_mod.HostContext,
            params: []const RawVal,
            results: []RawVal,
        ) host_mod.HostError!void {
            const x = params[0].readAs(i32);
            results[0] = RawVal.from(x + 1);
        }
    };

    var imports = Imports.empty;
    defer imports.deinit(testing_mod.allocator);
    try imports.define(
        testing_mod.allocator,
        "env",
        "add_one",
        HostFunc.init(
            null,
            HostCtx.add_one,
            &[_]core.ValType{.I32},
            &[_]core.ValType{.I32},
        ),
    );

    var instance = try Instance.init(&store, &module, imports);
    defer instance.deinit();

    // Calling "run" with 41 should return 42 (host adds 1).
    const exec_r = try instance.call("run", &.{RawVal.from(@as(i32, 41))});
    const result = exec_r.ok orelse return error.MissingReturnValue;
    try testing_mod.expectEqual(@as(i32, 42), result.readAs(i32));
}

test "Instance: host function trap propagates to caller" {
    // Same Wasm module as the previous test.
    const testing_mod = std.testing;
    const engine_mod = @import("../engine/mod.zig");
    const config_mod = @import("../engine/config.zig");

    var engine = try engine_mod.Engine.init(testing_mod.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = Store.init(testing_mod.allocator, engine);
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
        0x02, 0x0f, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x07,
        0x61, 0x64, 0x64, 0x5f, 0x6f, 0x6e, 0x65, 0x00,
        0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
        0x03, 0x72, 0x75, 0x6e, 0x00, 0x01, 0x0a, 0x08,
        0x01, 0x06, 0x00, 0x20, 0x00, 0x10, 0x00, 0x0b,
    };

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    // Host implementation: always traps.
    const HostCtx = struct {
        fn always_trap(
            _: ?*anyopaque,
            ctx: *host_mod.HostContext,
            _: []const RawVal,
            _: []RawVal,
        ) host_mod.HostError!void {
            return ctx.raiseTrap(Trap.fromTrapCode(.UnreachableCodeReached));
        }
    };

    var imports = Imports.empty;
    defer imports.deinit(testing_mod.allocator);
    try imports.define(
        testing_mod.allocator,
        "env",
        "add_one",
        HostFunc.init(
            null,
            HostCtx.always_trap,
            &[_]core.ValType{.I32},
            &[_]core.ValType{.I32},
        ),
    );

    var instance = try Instance.init(&store, &module, imports);
    defer instance.deinit();

    const exec_r = try instance.call("run", &.{RawVal.from(@as(i32, 0))});
    try testing_mod.expectEqual(TrapCode.UnreachableCodeReached, exec_r.trap.trapCode().?);
}

test "Instance.call: unreachable instruction returns UnreachableCodeReached trap" {
    // WAT:
    //   (module
    //     (func (export "f")
    //       unreachable)
    //   )
    const testing = std.testing;
    const engine_mod = @import("../engine/mod.zig");
    const config_mod = @import("../engine/config.zig");

    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = Store.init(testing.allocator, engine);
    defer store.deinit();

    const wasm = [_]u8{
        // magic + version
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type section: 1 type, func () -> ()
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        // function section: func[0] = type[0]
        0x03, 0x02,
        0x01, 0x00,
        // export section: "f" -> func[0]
        0x07, 0x05, 0x01, 0x01, 'f',  0x00,
        0x00,
        // code section: 1 body, 3 bytes (no locals, unreachable, end)
        0x0a, 0x05, 0x01, 0x03, 0x00, 0x00, 0x0b,
    };

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    var instance = try Instance.init(&store, &module, Imports.empty);
    defer instance.deinit();

    const exec_r = try instance.call("f", &.{});
    try testing.expectEqual(TrapCode.UnreachableCodeReached, exec_r.trap.trapCode().?);
}

test "Instance.init returns ImportNotSatisfied when import is missing" {
    // Same Wasm module that requires env.add_one, but we pass Imports.empty.
    const testing_mod = std.testing;
    const engine_mod = @import("../engine/mod.zig");
    const config_mod = @import("../engine/config.zig");

    var engine = try engine_mod.Engine.init(testing_mod.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = Store.init(testing_mod.allocator, engine);
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
        0x02, 0x0f, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x07,
        0x61, 0x64, 0x64, 0x5f, 0x6f, 0x6e, 0x65, 0x00,
        0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
        0x03, 0x72, 0x75, 0x6e, 0x00, 0x01, 0x0a, 0x08,
        0x01, 0x06, 0x00, 0x20, 0x00, 0x10, 0x00, 0x0b,
    };

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    const result = Instance.init(&store, &module, Imports.empty);
    try testing_mod.expectError(error.ImportNotSatisfied, result);
}

test "Instance.init returns ImportSignatureMismatch when host signature differs" {
    const testing_mod = std.testing;
    const engine_mod = @import("../engine/mod.zig");
    const config_mod = @import("../engine/config.zig");

    var engine = try engine_mod.Engine.init(testing_mod.allocator, config_mod.Config{});
    defer engine.deinit();

    var store = Store.init(testing_mod.allocator, engine);
    defer store.deinit();

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
        0x02, 0x0f, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x07,
        0x61, 0x64, 0x64, 0x5f, 0x6f, 0x6e, 0x65, 0x00,
        0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
        0x03, 0x72, 0x75, 0x6e, 0x00, 0x01, 0x0a, 0x08,
        0x01, 0x06, 0x00, 0x20, 0x00, 0x10, 0x00, 0x0b,
    };

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    const HostCtx = struct {
        fn wrong_sig(
            _: ?*anyopaque,
            _: *host_mod.HostContext,
            _: []const RawVal,
            _: []RawVal,
        ) host_mod.HostError!void {}
    };

    var linker = Linker.empty;
    defer linker.deinit(testing_mod.allocator);
    try linker.define(
        testing_mod.allocator,
        "env",
        "add_one",
        HostFunc.init(
            null,
            HostCtx.wrong_sig,
            &.{},
            &[_]core.ValType{.I32},
        ),
    );

    try testing_mod.expectError(error.ImportSignatureMismatch, Instance.init(&store, &module, linker));
}

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
const vm_mod = @import("../vm/root.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const Module = module_mod.Module;
const Global = core.Global;
const GlobalType = core.GlobalType;
const VM = vm_mod.VM;
const ExecEnv = vm_mod.ExecEnv;
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
    /// Tracks which element segments have been dropped via elem.drop instruction.
    /// elem_segments_dropped[i] == true means segment i cannot be used by table.init.
    elem_segments_dropped: []bool,

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
            const hf = imports.get(def.module_name, def.func_name) orelse return error.ImportNotSatisfied;
            if (!hf.matches(module.func_types[def.type_index])) {
                return error.ImportSignatureMismatch;
            }
            host_funcs[i] = hf;
        }

        const host_view = HostInstance{
            .module = module,
            .globals = globals,
            .memory = memory,
            .tables = module.tables,
        };

        // ── 4. initialize data segment dropped flags ───────────────────────────────
        const data_segments_dropped = try allocator.alloc(bool, module.data_segments.len);
        errdefer allocator.free(data_segments_dropped);
        @memset(data_segments_dropped, false);

        // ── 5. initialize element segment dropped flags ──────────────────────────────
        const elem_segments_dropped = try allocator.alloc(bool, module.elem_segments.len);
        errdefer allocator.free(elem_segments_dropped);
        @memset(elem_segments_dropped, false);

        store.registerInstance();
        errdefer store.unregisterInstance();

        return .{
            .store = store,
            .module = module,
            .globals = globals,
            .memory = memory,
            .host_funcs = host_funcs,
            .host_view = host_view,
            .data_segments_dropped = data_segments_dropped,
            .elem_segments_dropped = elem_segments_dropped,
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
        allocator.free(self.elem_segments_dropped);
        self.store.unregisterInstance();
        self.* = undefined;
    }

    fn execEnv(self: *Instance) ExecEnv {
        return .{
            .store = self.store,
            .host_instance = &self.host_view,
            .globals = self.globals,
            .memory = self.memory,
            .functions = self.module.functions,
            .func_types = self.module.func_types,
            .host_funcs = self.host_funcs,
            .tables = self.module.tables,
            .func_type_indices = self.module.func_type_indices,
            .data_segments = self.module.data_segments,
            .data_segments_dropped = self.data_segments_dropped,
            .elem_segments = self.module.elem_segments,
            .elem_segments_dropped = self.elem_segments_dropped,
            .composite_types = self.module.composite_types,
            .struct_layouts = self.module.struct_layouts,
            .array_layouts = self.module.array_layouts,
            .type_ancestors = self.module.type_ancestors,
        };
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
        return vm.execute(func, args, self.execEnv());
    }
};

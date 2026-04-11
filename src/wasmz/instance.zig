/// instance.zig - WebAssembly Instance
///
/// Instance is a runtime instantiation of a Module, containing the mutable state during execution.
/// It is created from a compiled Module and holds:
///   - globals:    an array of global variables copied and initialized from module.globals
///   - memory:     linear memory, either exclusively-owned or a shared reference (Threads proposal)
///   - host_funcs: resolved host functions for each imported function slot
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
const Memory = core.Memory;
const SharedMemory = core.SharedMemory;
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

pub const InstanceError = Allocator.Error || error{
    ExportNotFound,
    /// A function import required by the module was not provided in the Imports map
    ImportNotSatisfied,
    /// A host-provided function's signature does not match the imported function type.
    ImportSignatureMismatch,
    /// Shared memory requires a maximum page count (Wasm spec).
    SharedMemoryMissingMax,
    /// The module does not declare a shared memory but a SharedMemory was provided.
    ModuleMemoryNotShared,
    /// The provided SharedMemory's capacity is smaller than what the module requires.
    SharedMemoryTooSmall,
};

pub const Instance = struct {
    store: *Store,
    /// Read-only module reference; the caller is responsible for ensuring the Module remains valid for the lifetime of the Instance.
    /// TODO: Upgrade to Arc(Module) to support multiple Instances sharing the same Module.
    module: *const Module,
    /// Runtime globals, copied and initialized from module.globals.
    globals: []Global,
    /// Linear memory, either exclusively owned or shared across instances (Threads proposal).
    memory: Memory,
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
        var mem: Memory = if (module.memory) |mem_def| blk: {
            if (mem_def.shared) {
                const max = mem_def.max_pages orelse return error.SharedMemoryMissingMax;
                const shared = try SharedMemory.init(allocator, mem_def.min_pages, max);
                break :blk Memory.initShared(shared);
            } else {
                break :blk try Memory.initOwned(allocator, mem_def.min_pages);
            }
        } else Memory.initEmpty();
        errdefer mem.deinit();

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
            .memory = &mem,
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
            .memory = mem,
            .host_funcs = host_funcs,
            .host_view = host_view,
            .data_segments_dropped = data_segments_dropped,
            .elem_segments_dropped = elem_segments_dropped,
        };
    }

    /// Instantiate a Module using an externally-created `SharedMemory`.
    ///
    /// This is the multi-threaded variant of `init`.  All Instance values created
    /// from the same Module with the same `shared` handle will operate on the same
    /// linear memory region, enabling cross-thread communication via atomic
    /// operations (memory.atomic.store / load / rmw / cmpxchg / wait / notify).
    ///
    /// Constraints
    /// -----------
    /// - The module must declare `(memory ... shared)`.
    /// - `shared.capacity()` must be >= `module.memory.max_pages * WASM_PAGE_SIZE`.
    ///
    /// Ownership
    /// ---------
    /// `initWithSharedMemory` clones the refcount on `shared`, so the caller may
    /// freely `deinit` its own handle after instantiation.  Each Instance's
    /// `deinit` decrements the refcount; the underlying bytes are freed when the
    /// last reference is dropped.
    pub fn initWithSharedMemory(
        store: *Store,
        module: *const Module,
        imports: Linker,
        shared: SharedMemory,
    ) InstanceError!Instance {
        const allocator = store.allocator;

        // ── Validate that the module declares a shared memory ──────────────────
        const mem_def = module.memory orelse return error.ModuleMemoryNotShared;
        if (!mem_def.shared) return error.ModuleMemoryNotShared;

        const max = mem_def.max_pages orelse return error.SharedMemoryMissingMax;
        const required_capacity = @as(usize, max) * @import("core").WASM_PAGE_SIZE;
        if (shared.capacity() < required_capacity) return error.SharedMemoryTooSmall;

        // ── 1. copy globals ────────────────────────────────────────────────────
        const globals = try allocator.alloc(Global, module.globals.len);
        errdefer allocator.free(globals);

        for (module.globals, 0..) |global_init, i| {
            globals[i] = Global.init(
                GlobalType.init(global_init.mutability, global_init.value.ty),
                global_init.value.value,
            );
        }

        // ── 2. wrap the provided shared memory (increments refcount) ───────────
        var mem = Memory.initShared(shared);
        errdefer mem.deinit();

        // ── 3. resolve host functions ──────────────────────────────────────────
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
            .memory = &mem,
            .tables = module.tables,
        };

        // ── 4. segment dropped flags ───────────────────────────────────────────
        const data_segments_dropped = try allocator.alloc(bool, module.data_segments.len);
        errdefer allocator.free(data_segments_dropped);
        @memset(data_segments_dropped, false);

        const elem_segments_dropped = try allocator.alloc(bool, module.elem_segments.len);
        errdefer allocator.free(elem_segments_dropped);
        @memset(elem_segments_dropped, false);

        store.registerInstance();
        errdefer store.unregisterInstance();

        return .{
            .store = store,
            .module = module,
            .globals = globals,
            .memory = mem,
            .host_funcs = host_funcs,
            .host_view = host_view,
            .data_segments_dropped = data_segments_dropped,
            .elem_segments_dropped = elem_segments_dropped,
        };
    }

    pub fn deinit(self: *Instance) void {
        const allocator = self.store.allocator;
        allocator.free(self.globals);
        self.memory.deinit();
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
            .memory = &self.memory,
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
    pub fn call(self: *Instance, name: []const u8, args: []const RawVal) (Allocator.Error || error{ ExportNotFound, ExportNotCallable })!ExecResult {
        const export_entry = self.module.exports.get(name) orelse return error.ExportNotFound;
        const func_index = switch (export_entry) {
            .function_index => |idx| idx,
            else => return error.ExportNotCallable,
        };
        const func = self.module.functions[func_index];
        var vm = VM.init(self.store.allocator);
        return vm.execute(func, args, self.execEnv());
    }
};

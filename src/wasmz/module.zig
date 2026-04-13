/// module.zig - WebAssembly module compile entry
///
/// It will parse the raw Wasm bytes using the Parser, extract necessary information from the Payloads,
/// and compile the function bodies into internal IR (CompiledFunction) using Lower.
/// Process:
///   1. Parse the bytecode into a sequence of Payload events using the Parser.
///   2. Extract types, functions, globals, memory, exports, etc., from the Payloads. (loop 1)
///   3. Compile each function body into internal IR (CompiledFunction) using Lower. (loop 2)
///   4. Assemble all compiled results into a Module for VM instantiation and execution.
const std = @import("std");
const zigrc = @import("zigrc");
const parser_mod = @import("parser");
const payload_mod = @import("payload");
const engine_mod = @import("../engine/root.zig");
const engine_config_mod = @import("../engine/config.zig");
const lower_mod = @import("../compiler/lower.zig");
const lower_legacy_mod = @import("../compiler/lower_legacy.zig");
const translate_mod = @import("../compiler/translate.zig");
const ir = @import("../compiler/ir.zig");
const core = @import("core");
const utils_parse = @import("../utils/parse.zig");
const func_type_mod = core.func_type;
const global_mod = core.global;
const raw_mod = core.raw;
const simd = core.simd;
const typed_mod = core.typed;
const value_type_mod = core.value_type;
const gc_mod = @import("../vm/gc/root.zig");
const profiling = @import("../utils/profiling.zig");

const Allocator = std.mem.Allocator;
const Parser = parser_mod.Parser;
const Payload = payload_mod.Payload;
const Type = payload_mod.Type;
const TypeKind = payload_mod.TypeKind;
const ExternalKind = payload_mod.ExternalKind;
const OperatorInformation = payload_mod.OperatorInformation;
const CompiledFunction = ir.CompiledFunction;
const EncodedFunction = ir.EncodedFunction;
const PendingFunction = ir.PendingFunction;
pub const FunctionSlot = ir.FunctionSlot;
const FuncType = func_type_mod.FuncType;
const Mutability = global_mod.Mutability;
const Global = core.Global;
const RawVal = raw_mod.RawVal;
const TypedRawVal = typed_mod.TypedRawVal;
const ValType = value_type_mod.ValType;
const CompositeType = core.CompositeType;
const StructLayout = gc_mod.StructLayout;
const ArrayLayout = gc_mod.ArrayLayout;
const GcRef = core.GcRef;
const Engine = engine_mod.Engine;
const Lower = lower_mod.Lower;
const LowerLegacy = lower_legacy_mod.LowerLegacy;
const LegacyWasmOp = lower_legacy_mod.LegacyWasmOp;
const EngineConfig = engine_config_mod.Config;
const encode_mod = @import("../compiler/encode.zig");
const handler_table_mod = @import("../vm/handler_table.zig");

/// Exported item from a Wasm module.
/// Currently function and tag exports are supported; memory/global/table exports are ignored.
pub const ExportEntry = union(enum) {
    /// Index into Module.functions (imports + locals, in Wasm function index space).
    function_index: u32,
    /// Index into Module.tags (imports + locals, in Wasm tag index space).
    tag_index: u32,
};

/// Exception tag definition.
/// The type_index refers to a FuncType whose params are the exception payload types
/// and whose results are always empty.
pub const TagDef = struct {
    type_index: u32,
};

/// Whether the module uses the new (try_table) or legacy (try/catch/rethrow/delegate) EH proposal.
pub const EHMode = enum {
    /// No exception handling instructions detected.
    none,
    /// New proposal: try_table / throw / throw_ref.
    new,
    /// Legacy proposal: try / catch / catch_all / rethrow / delegate.
    legacy,
};

/// Module-level configuration.
pub const ModuleConfig = struct {
    eh_mode: EHMode = .none,
};

/// Metadata for a single imported function, extracted from the Wasm Import Section.
/// The module_name / func_name slices are owned by the Module allocator.
pub const ImportedFuncDef = struct {
    /// The module namespace string (e.g. "env", "wasi_snapshot_preview1").
    module_name: []const u8,
    /// The function name within that namespace.
    func_name: []const u8,
    /// Index into Module.func_types giving this import's signature.
    type_index: u32,
};

/// Metadata for a single imported global variable, extracted from the Wasm Import Section.
/// The module_name / global_name slices are owned by the Module allocator.
pub const ImportedGlobalDef = struct {
    /// The module namespace string (e.g. "env").
    module_name: []const u8,
    /// The global name within that namespace.
    global_name: []const u8,
    /// Value type of the global.
    val_type: ValType,
    /// Whether the global is mutable.
    mutability: Mutability,
};

/// Global variable compilation result, including mutability and the initial value evaluated from constant expressions.
/// For simple const exprs (i32.const, ref.null, etc.) the value is pre-computed at compile time.
/// For GC const exprs (struct.new, array.new_fixed, etc.) the value cannot be evaluated until
/// instantiation time when the GC heap is available.  In that case, `init_expr` holds the raw
/// bytecode and `value` is set to a zero/null placeholder.
pub const GlobalInit = struct {
    mutability: Mutability,
    value: TypedRawVal,
    /// Non-null when this global requires runtime evaluation of a GC constant expression.
    /// The bytecode is the raw init_expr from the Wasm binary (ending with 0x0b).
    init_expr: ?[]const u8 = null,
};

/// Linear memory definition, recording the minimum and maximum number of pages (each page is 64 KiB).
/// max_pages being null indicates that there is no upper limit on the memory size.
/// shared being true means the memory was declared `shared` (Wasm Threads proposal).
/// Note: shared memories MUST have a max_pages (Wasm spec requirement).
pub const MemoryDef = struct {
    min_pages: u32,
    max_pages: ?u32,
    shared: bool = false,
};

/// Compiled data segment, holding the data bytes and metadata for runtime initialization.
pub const CompiledDataSegment = struct {
    mode: payload_mod.DataMode,
    memory_index: u32,
    /// For active segments, the offset in linear memory where data should be written.
    /// For passive segments, this is unused.
    offset: u32,
    /// The actual data bytes to be written to memory.
    data: []const u8,
};

/// Compiled element segment, holding the function indices and metadata for runtime table initialization.
/// Passive segments are stored here; active segments are applied during instantiation.
pub const CompiledElemSegment = struct {
    mode: payload_mod.ElementMode,
    table_index: u32,
    /// For active segments, the offset in the table where elements should be written.
    /// For passive segments, this is unused.
    offset: u32,
    func_indices: []const u32,
};

/// All possible errors that can occur during module compilation.
pub const ModuleCompileError = Allocator.Error ||
    parser_mod.ParseAllError ||
    parser_mod.CodeReadError ||
    lower_mod.LowerError ||
    lower_legacy_mod.LegacyLowerError ||
    func_type_mod.FuncTypeError ||
    translate_mod.TranslateError ||
    error{
        DuplicateExport,
        InvalidFunctionTypeIndex,
        InvalidMutability,
        InvalidI32Literal,
        InvalidI64Literal,
        InvalidLocalCount,
        MismatchedFunctionCount,
        MultipleMemories,
        UnsupportedBlockType,
        UnsupportedConstExpr,
        UnsupportedExportKind,
        UnsupportedFunctionType,
        UnsupportedGlobalType,
        UnsupportedOperator,
        DisabledSimd,
        DisabledRelaxedSimd,
        InvalidTagIndex,
        InvalidTagImport,
    };

/// Reusable allocations for function compilation, modelled after wasmi's
/// `FuncTranslatorAllocations`.  A single instance is kept per `Module` so
/// that the backing buffers of the lowering pass (the `Lower` / `LowerLegacy`
/// ArrayLists and the scratch `ArenaAllocator`) are reused across every lazy
/// compilation, avoiding the alloc/free churn of creating fresh structures for
/// each function body.
///
/// Lifecycle:
///   - Created on the first call to `compileFunctionAt`.
///   - Reused for every subsequent call via `reset()`.
///   - Freed in `Module.deinit()`.
pub const FuncTranslatorAllocations = struct {
    /// Reusable lowering state for the new EH path.
    lower: Lower,
    /// Reusable lowering state for the legacy EH path.
    lower_legacy: LowerLegacy,
    /// Scratch arena for per-operator temporary allocations inside the
    /// compilation loop (parse results, try_table handler slices, etc.).
    /// Reset with `.retain_capacity` after each function so the backing
    /// memory is reused without freeing.
    scratch: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator) FuncTranslatorAllocations {
        return .{
            .lower = Lower.init(allocator),
            .lower_legacy = LowerLegacy.init(allocator),
            .scratch = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *FuncTranslatorAllocations) void {
        self.lower.deinit();
        self.lower_legacy.deinit();
        self.scratch.deinit();
    }

    /// Prepare the allocations for compiling a new function with the new EH path.
    /// Resets all lists retaining capacity; resets the scratch arena.
    pub fn resetNew(self: *FuncTranslatorAllocations, reserved_slots: u32, locals_count: u16) void {
        self.lower.reset(reserved_slots, locals_count);
        _ = self.scratch.reset(.retain_capacity);
    }

    /// Prepare the allocations for compiling a new function with the legacy EH path.
    pub fn resetLegacy(self: *FuncTranslatorAllocations, reserved_slots: u32, locals_count: u16) void {
        self.lower_legacy.reset(reserved_slots, locals_count);
        _ = self.scratch.reset(.retain_capacity);
    }
};

/// Compiled WebAssembly module, holding all data required for runtime execution.
///
/// Field descriptions:
///   - functions:        List of function slots indexed by Wasm function index space (imports first).
///                       Each slot is `.import` for host imports, `.pending` for uncompiled locals,
///                       or `.encoded` for compiled locals.  Slots are compiled on first call (lazy).
///   - wasm_bytes:       Borrowed slice of the original Wasm binary.  Must outlive the Module.
///                       Used to re-access function bodies during lazy compilation.
///   - exports:          Mapping from export names to ExportEntry, currently only function exports are supported.
///   - globals:          List of global variables, each containing mutability and the initial value evaluated from constant expressions.
///   - memory:           Linear memory definition (optional), currently supports at most one memory segment.
///   - start_function:   Optional start function index (from the Wasm Start Section).
///   - imported_funcs:   Metadata for every imported function.
///   - tables:           Each entry is a slice of function indices for one table (table 0, table 1, ...).
///                       Populated from active element segments in the Element Section.
///   - func_type_indices: Maps func_idx → type section index for every function (imports + locals).
///                        Used by call_indirect for runtime type checking.
///   - composite_types:  Unified type index space from the Type Section (func, struct, array).
///                       Index matches the Wasm type section index.
///   - struct_layouts:   Precomputed memory layouts for struct types (index matches composite_types).
///   - array_layouts:    Precomputed memory layouts for array types (index matches composite_types).
pub const Module = struct {
    allocator: Allocator,
    /// Function slots in Wasm function index space (imports first, then locals).
    /// Slot variants: `.import` (host import), `.pending` (uncompiled), `.encoded` (compiled).
    functions: []FunctionSlot,
    /// Borrowed slice of the original Wasm binary bytes.
    /// Must remain valid for the entire lifetime of the Module.
    wasm_bytes: []const u8,
    exports: std.StringHashMapUnmanaged(ExportEntry),
    globals: []GlobalInit,
    memory: ?MemoryDef,
    /// Wasm Start Section (optional).
    /// If present, Instance.init will automatically call this function after instantiation.
    start_function: ?u32,
    /// Metadata for each imported function in the order they appear in the Import Section.
    /// Length == number of imported functions == offset of first local function in `functions`.
    imported_funcs: []ImportedFuncDef,
    /// Metadata for each imported global in the order they appear in the Import Section.
    /// global.get in constant expressions can only reference these imported globals.
    imported_globals: []ImportedGlobalDef,
    /// Tables: each entry is an owned slice of function indices (func_idx) for that table.
    /// tables[t][i] gives the func_idx stored at position i in table t.
    /// Populated from active externval element segments.
    tables: [][]u32,
    /// Type index for every function in the module (imports + locals), in func_idx order.
    /// func_type_indices[func_idx] = type section index.
    func_type_indices: []u32,
    /// Data segments: each entry holds data bytes and initialization metadata.
    /// Active segments are applied during instantiation; passive segments are used by memory.init.
    data_segments: []CompiledDataSegment,
    /// Element segments: each entry holds function indices and mode metadata.
    /// Passive segments are used by table.init; active segments are applied during instantiation.
    elem_segments: []CompiledElemSegment,
    /// GC composite types from the Type Section.
    composite_types: []CompositeType,
    /// Precomputed memory layouts for struct types.
    /// Index matches composite_types; null for non-struct types.
    struct_layouts: []?StructLayout,
    /// Precomputed memory layouts for array types.
    /// Index matches composite_types; null for non-array types.
    array_layouts: []?ArrayLayout,
    /// Transitive ancestor type indices for each composite type.
    /// type_ancestors[i] is a slice of all composite type indices that are strict ancestors of
    /// composite type i (i.e. the full inheritance chain, excluding i itself).
    /// Empty slice for types with no declared supertypes.
    /// Indexed by composite type index (same index space as composite_types).
    type_ancestors: []const []const u32,
    /// Exception tags defined in the Tag Section (and imported tag entries).
    /// tags[i].type_index is the FuncType index for tag i.
    tags: []TagDef,
    /// Module-level configuration.
    config: ModuleConfig,
    /// Reusable compilation state for lazy function compilation.
    /// Null until the first `compileFunctionAt` call; freed in `deinit`.
    translator: ?FuncTranslatorAllocations,

    /// Compile WebAssembly bytecode into a Module.
    ///
    /// The compilation is done in two passes:
    ///   1. First pass: Collect types, imports, function type indices, global variables, memory, exports, and other metadata.
    ///   2. Second pass: Compile each function body (function_info payload) into a CompiledFunction.
    /// The Arena allocator is used internally to store temporary data during the compilation process,
    /// which will be automatically released after compilation.
    pub fn compile(engine: Engine, bytes: []const u8) ModuleCompileError!Module {
        const allocator = engine.allocator();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var parser = Parser.init(arena.allocator());
        const payloads = try parser.parseAll(bytes);

        // Unified type section: composite_types covers ALL type entries (func, struct, array)
        // indexed by the unified type section index.
        var composite_types_list: std.ArrayListUnmanaged(CompositeType) = .empty;
        errdefer {
            for (composite_types_list.items) |*ct| {
                ct.deinit(allocator);
            }
            composite_types_list.deinit(allocator);
        }

        var struct_layouts_list: std.ArrayListUnmanaged(?StructLayout) = .empty;
        errdefer {
            for (struct_layouts_list.items) |*sl| {
                if (sl.*) |layout| {
                    layout.deinit(allocator);
                }
            }
            struct_layouts_list.deinit(allocator);
        }

        var array_layouts_list: std.ArrayListUnmanaged(?ArrayLayout) = .empty;
        errdefer array_layouts_list.deinit(allocator);

        // For each composite type (indexed by composite type index), store its direct parent
        // composite type index, or null if it has no concrete supertype.
        // Used after the first pass to compute the transitive ancestor closure.
        var direct_parents_list: std.ArrayListUnmanaged(?u32) = .empty;
        defer direct_parents_list.deinit(allocator);

        var function_type_indices: std.ArrayListUnmanaged(u32) = .empty;
        defer function_type_indices.deinit(allocator);

        // Temporary list of imported function definitions collected during the first pass.
        // module_name and func_name strings are duped into `allocator` and will be owned by
        // the resulting `imported_funcs` slice stored in the Module.
        var imported_funcs_list: std.ArrayListUnmanaged(ImportedFuncDef) = .empty;
        errdefer {
            for (imported_funcs_list.items) |def| {
                allocator.free(def.module_name);
                allocator.free(def.func_name);
            }
            imported_funcs_list.deinit(allocator);
        }

        // Temporary list of imported global definitions collected during the first pass.
        var imported_globals_list: std.ArrayListUnmanaged(ImportedGlobalDef) = .empty;
        errdefer {
            for (imported_globals_list.items) |def| {
                allocator.free(def.module_name);
                allocator.free(def.global_name);
            }
            imported_globals_list.deinit(allocator);
        }

        var globals_list: std.ArrayListUnmanaged(GlobalInit) = .empty;
        defer globals_list.deinit(allocator);

        var exports: std.StringHashMapUnmanaged(ExportEntry) = .empty;
        errdefer deinit_exports(allocator, &exports);

        var memory: ?MemoryDef = null;
        var start_function: ?u32 = null;

        // Element section: track pending segments to build tables.
        // We track the last seen element_segment (for mode/table_index) then consume
        // the func_indices from element_segment_body.
        var pending_element_mode: payload_mod.ElementMode = .passive;
        var pending_element_table_index: ?u32 = null;
        var tables_lists: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u32)) = .empty;
        errdefer {
            for (tables_lists.items) |*tl| tl.deinit(allocator);
            tables_lists.deinit(allocator);
        }

        // Data section: track pending segments to build data_segments.
        var pending_data_mode: payload_mod.DataMode = .passive;
        var pending_data_memory_index: ?u32 = null;
        var data_segments_list: std.ArrayListUnmanaged(CompiledDataSegment) = .empty;
        errdefer {
            for (data_segments_list.items) |*seg| allocator.free(seg.data);
            data_segments_list.deinit(allocator);
        }

        // Element section: track all element segments (both active and passive) for table.init/elem.drop.
        var elem_segments_list: std.ArrayListUnmanaged(CompiledElemSegment) = .empty;
        errdefer {
            for (elem_segments_list.items) |*seg| allocator.free(seg.func_indices);
            elem_segments_list.deinit(allocator);
        }

        // Tag section: collect exception tag definitions.
        var tags_list: std.ArrayListUnmanaged(TagDef) = .empty;
        defer tags_list.deinit(allocator);

        // EH mode detection: scan operator payloads for EH-specific opcodes.
        // Precedence: legacy indicators (delegate, rethrow-with-depth) override new;
        // new indicators (try_table, throw_ref, catch_ref, catch_all_ref) set new;
        // If no EH opcodes are seen, mode stays .none.
        var detected_eh_mode: EHMode = .none;

        // Pre-scan: collect tag definitions in Wasm tag index order:
        //   [imported tags (Import Section)]  then  [locally defined tags (Tag Section)]
        // Both sections may come before or after the Code Section, so we gather
        // everything here before the main compile loop.
        for (payloads) |pre_payload| {
            switch (pre_payload) {
                .import_entry => |entry| {
                    if (entry.kind == .tag) {
                        const tt = if (entry.typ) |t| t.tag else return error.InvalidTagImport;
                        try tags_list.append(allocator, .{ .type_index = tt.type_index });
                    }
                },
                .tag_type => |tt| {
                    try tags_list.append(allocator, .{ .type_index = tt.type_index });
                },
                else => {},
            }
        }

        for (payloads) |payload| {
            switch (payload) {
                .type_entry => |entry| {
                    switch (entry.type) {
                        .func => {
                            const func_type = try compile_func_type(allocator, arena.allocator(), entry);
                            // Add to the unified composite_types_list (sole owner of FuncType buffers).
                            try composite_types_list.append(allocator, CompositeType{ .func_type = func_type });
                            // func types have no struct/array layout
                            try struct_layouts_list.append(allocator, null);
                            try array_layouts_list.append(allocator, null);
                            // func types have no concrete supertype in the GC sense
                            try direct_parents_list.append(allocator, null);
                        },
                        .struct_type, .array_type => {
                            const composite_type = try translate_mod.wasmCompositeTypeFromTypeEntry(allocator, entry);
                            try composite_types_list.append(allocator, composite_type);

                            // Record the direct parent composite type index (if any) for the
                            // transitive ancestor computation done after the first pass.
                            // Only concrete (index-typed) supertypes count; abstract heap type supertypes
                            // (e.g. `any`, `eq`) are handled by the GcRefKind bitmask path.
                            const direct_parent: ?u32 = blk: {
                                for (entry.super_types) |st| {
                                    switch (st) {
                                        .index => |idx| break :blk idx,
                                        else => {},
                                    }
                                }
                                break :blk null;
                            };
                            try direct_parents_list.append(allocator, direct_parent);

                            switch (composite_type) {
                                .struct_type => |s| {
                                    const layout = try gc_mod.computeStructLayout(s, allocator);
                                    try struct_layouts_list.append(allocator, layout);
                                    try array_layouts_list.append(allocator, null);
                                },
                                .array_type => |a| {
                                    try struct_layouts_list.append(allocator, null);
                                    try array_layouts_list.append(allocator, gc_mod.computeArrayLayout(a));
                                },
                                .func_type => unreachable,
                            }
                        },
                        else => return error.UnsupportedFunctionType,
                    }
                },
                .import_entry => |entry| {
                    if (entry.kind == .function) {
                        // func_type_index is guaranteed non-null for function imports per Wasm spec.
                        const type_idx = entry.func_type_index orelse return error.InvalidFunctionTypeIndex;
                        // Dupe the strings so they are owned by the Module allocator.
                        const mod_name = try allocator.dupe(u8, entry.module);
                        errdefer allocator.free(mod_name);
                        const fn_name = try allocator.dupe(u8, entry.field);
                        errdefer allocator.free(fn_name);
                        try imported_funcs_list.append(allocator, .{
                            .module_name = mod_name,
                            .func_name = fn_name,
                            .type_index = type_idx,
                        });
                    } else if (entry.kind == .global) {
                        const global_typ = if (entry.typ) |t| switch (t) {
                            .global => |g| g,
                            else => return error.UnsupportedFunctionType,
                        } else return error.UnsupportedFunctionType;
                        const val_type = try translate_mod.wasmValTypeFromType(global_typ.content_type);
                        const mutability: Mutability = switch (global_typ.mutability) {
                            0 => .Const,
                            1 => .Var,
                            else => return error.InvalidMutability,
                        };
                        const mod_name = try allocator.dupe(u8, entry.module);
                        errdefer allocator.free(mod_name);
                        const global_name = try allocator.dupe(u8, entry.field);
                        errdefer allocator.free(global_name);
                        try imported_globals_list.append(allocator, .{
                            .module_name = mod_name,
                            .global_name = global_name,
                            .val_type = val_type,
                            .mutability = mutability,
                        });
                    }
                },
                .function_entry => |entry| {
                    try function_type_indices.append(allocator, entry.type_index);
                },
                .global_variable => |entry| {
                    try globals_list.append(
                        allocator,
                        try compile_global_init(allocator, arena.allocator(), entry),
                    );
                },
                .memory_type => |entry| {
                    if (memory != null) return error.MultipleMemories;
                    memory = .{
                        .min_pages = entry.limits.initial,
                        .max_pages = entry.limits.maximum,
                        .shared = entry.shared,
                    };
                },
                .export_entry => |entry| {
                    switch (entry.kind) {
                        .function => try put_function_export(
                            allocator,
                            &exports,
                            entry.field,
                            .{ .function_index = entry.index },
                        ),
                        .tag => try put_function_export(
                            allocator,
                            &exports,
                            entry.field,
                            .{ .tag_index = entry.index },
                        ),
                        else => {},
                    }
                },
                // Wasm Start Section: record the start function index, automatically called by Instance.init
                .start_entry => |entry| {
                    start_function = entry.index;
                },
                // Wasm Table Section: create a pre-sized table entry for each declared table.
                // Each slot is initialized to maxInt(u32) (null funcref sentinel).
                .table_type => |tbl| {
                    const tbl_idx = tables_lists.items.len;
                    try tables_lists.append(allocator, .empty);
                    const initial_size = tbl.limits.initial;
                    try tables_lists.items[tbl_idx].resize(allocator, initial_size);
                    @memset(tables_lists.items[tbl_idx].items, std.math.maxInt(u32));
                },
                .element_segment => |seg| {
                    // Record metadata for the upcoming element_segment_body.
                    pending_element_mode = seg.mode;
                    pending_element_table_index = seg.table_index;
                },
                .element_segment_body => |body| {
                    // Store all element segments (active + passive) for table.init / elem.drop.
                    const func_indices_copy = try allocator.dupe(u32, body.func_indices);
                    errdefer allocator.free(func_indices_copy);

                    // Calculate offset for active segments by evaluating the constant expression.
                    const offset: u32 = if (pending_element_mode == .active)
                        (try evaluate_const_expr(arena.allocator(), body.offset_expr, .I32)).readAs(u32)
                    else
                        0;

                    try elem_segments_list.append(allocator, .{
                        .mode = pending_element_mode,
                        .table_index = pending_element_table_index orelse 0,
                        .offset = offset,
                        .func_indices = func_indices_copy,
                    });

                    // For active segments, also populate the runtime table at the calculated offset.
                    // The table was pre-sized by the table section (or will be created here if absent).
                    if (pending_element_mode == .active) {
                        const tbl_idx = pending_element_table_index orelse 0;
                        // Ensure the table list exists.
                        while (tables_lists.items.len <= tbl_idx) {
                            try tables_lists.append(allocator, .empty);
                        }
                        const tbl = &tables_lists.items[tbl_idx];
                        const required_len = offset + body.func_indices.len;
                        if (tbl.items.len < required_len) {
                            // Table smaller than segment+offset: extend with nulls then overwrite.
                            const old_len = tbl.items.len;
                            try tbl.resize(allocator, required_len);
                            @memset(tbl.items[old_len..], std.math.maxInt(u32));
                        }
                        // Write func indices at the calculated offset (overwriting null-initialized slots).
                        for (body.func_indices, 0..) |fi, i| {
                            tbl.items[offset + i] = fi;
                        }
                    }
                },
                .data_segment => |seg| {
                    pending_data_mode = seg.mode;
                    pending_data_memory_index = seg.memory_index;
                },
                .data_segment_body => |body| {
                    const data_copy = try allocator.dupe(u8, body.data);
                    const compiled = CompiledDataSegment{
                        .mode = pending_data_mode,
                        .memory_index = pending_data_memory_index orelse 0,
                        .offset = if (pending_data_mode == .active)
                            (try evaluate_const_expr(arena.allocator(), body.offset_expr, .I32)).readAs(u32)
                        else
                            0,
                        .data = data_copy,
                    };
                    try data_segments_list.append(allocator, compiled);
                },
                // Tag section: handled in pre-scan above; skip here to avoid duplicates.
                .tag_type => {},
                // EH mode detection: scan function bodies for EH-specific opcodes.
                .function_info => |info| {
                    if (detected_eh_mode != .legacy) {
                        var cursor: usize = 0;
                        while (cursor < info.body.len) {
                            const parsed_op = parser_mod.readNextOperator(arena.allocator(), info.body[cursor..]) catch break;
                            cursor += parsed_op.consumed;
                            switch (parsed_op.info.code) {
                                // Legacy-only opcodes → force legacy mode
                                .delegate, .try_ => {
                                    detected_eh_mode = .legacy;
                                    break;
                                },
                                .rethrow => {
                                    detected_eh_mode = .legacy;
                                    break;
                                },
                                // New-proposal opcodes → set new (unless already legacy)
                                .try_table, .throw_ref => {
                                    if (detected_eh_mode == .none) {
                                        detected_eh_mode = .new;
                                    }
                                },
                                .throw => {
                                    if (detected_eh_mode == .none) {
                                        detected_eh_mode = .new;
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                },
                else => {},
            }
        }

        // Allow CLI/config to force legacy mode, overriding auto-detection.
        if (engine.config().legacy_exceptions) {
            detected_eh_mode = .legacy;
        }

        const imported_function_count = imported_funcs_list.items.len;
        const function_count = imported_function_count + function_type_indices.items.len;
        const functions = try allocator.alloc(FunctionSlot, function_count);
        errdefer {
            deinit_functions(allocator, functions);
            allocator.free(functions);
        }
        // Initialize import slots; local function slots will be filled as `.pending` below.
        for (functions[0..imported_function_count]) |*f| {
            f.* = .import;
        }
        for (functions[imported_function_count..]) |*f| {
            f.* = .import; // temporary; overwritten per-function below
        }

        // Build the import type index slice for FuncTypeResolver:
        // imported_funcs_list.items[i].type_index gives the type of import i.
        var import_type_indices_list: std.ArrayListUnmanaged(u32) = .empty;
        defer import_type_indices_list.deinit(allocator);
        for (imported_funcs_list.items) |def| {
            try import_type_indices_list.append(allocator, def.type_index);
        }

        var local_function_index: usize = 0;
        for (payloads) |payload| {
            switch (payload) {
                .function_info => |info| {
                    if (local_function_index >= function_type_indices.items.len) {
                        return error.MismatchedFunctionCount;
                    }

                    const type_index = function_type_indices.items[local_function_index];
                    // Validate against the unified type index space (composite_types_list).
                    if (type_index >= composite_types_list.items.len) {
                        return error.InvalidFunctionTypeIndex;
                    }
                    const func_type = switch (composite_types_list.items[type_index]) {
                        .func_type => |ft| ft,
                        else => return error.InvalidFunctionTypeIndex,
                    };

                    const reserved_slots = try compute_reserved_slots(func_type, info);
                    const params_count = func_type.params().len;
                    const locals_count: u16 = @intCast(reserved_slots - params_count);
                    const function_index = imported_function_count + local_function_index;

                    // Lazy compilation: store the raw bytecode and pre-computed metadata.
                    // The actual IR compilation + encoding happens on first call.
                    functions[function_index] = .{ .pending = .{
                        .body = info.body,
                        .type_index = type_index,
                        .reserved_slots = reserved_slots,
                        .locals_count = locals_count,
                    } };
                    local_function_index += 1;
                },
                else => {},
            }
        }
        if (local_function_index != function_type_indices.items.len) {
            return error.MismatchedFunctionCount;
        }

        const globals = try globals_list.toOwnedSlice(allocator);
        errdefer {
            for (globals) |g| {
                if (g.init_expr) |expr| allocator.free(expr);
            }
            allocator.free(globals);
        }

        const imported_funcs = try imported_funcs_list.toOwnedSlice(allocator);
        const imported_globals = try imported_globals_list.toOwnedSlice(allocator);

        // ── Build tables slice from tables_lists ──────────────────────────────
        // Convert ArrayListUnmanaged(ArrayListUnmanaged(u32)) -> [][]u32.
        const tables = try allocator.alloc([]u32, tables_lists.items.len);
        errdefer {
            for (tables) |t| allocator.free(t);
            allocator.free(tables);
        }
        for (tables_lists.items, 0..) |*tl, i| {
            tables[i] = try tl.toOwnedSlice(allocator);
        }
        tables_lists.deinit(allocator);

        // ── Build data_segments slice ────────────────────────────────────────
        const data_segments = try data_segments_list.toOwnedSlice(allocator);

        // ── Build elem_segments slice ────────────────────────────────────────
        const elem_segments = try elem_segments_list.toOwnedSlice(allocator);
        errdefer {
            for (elem_segments) |*seg| allocator.free(seg.func_indices);
            allocator.free(elem_segments);
        }

        // ── Build func_type_indices: imports first, then locals ───────────────
        // Total entries = imported_function_count + function_type_indices.items.len
        const func_type_indices = try allocator.alloc(u32, function_count);
        errdefer allocator.free(func_type_indices);
        for (import_type_indices_list.items, 0..) |ti, i| {
            func_type_indices[i] = ti;
        }
        for (function_type_indices.items, 0..) |ti, i| {
            func_type_indices[imported_function_count + i] = ti;
        }

        // ── Build composite_types, struct_layouts, array_layouts ──────────────
        const composite_types = try composite_types_list.toOwnedSlice(allocator);
        const struct_layouts = try struct_layouts_list.toOwnedSlice(allocator);
        const array_layouts = try array_layouts_list.toOwnedSlice(allocator);

        // ── Build tags slice ────────────────────────────────────────────────────
        const tags = try tags_list.toOwnedSlice(allocator);

        // ── Build type_ancestors: transitive closure of supertype chains ──────
        // For each composite type index i, type_ancestors[i] is the list of all
        // strict ancestor composite type indices (parent, grandparent, …) in order
        // from closest ancestor outward.
        //
        // Because Wasm GC sub-type declarations must reference a previously-defined
        // type (the spec enforces a topological order), we can compute ancestors by
        // a simple linear scan: for type i, its ancestors = [parent(i)] + ancestors[parent(i)].
        const n_composite = direct_parents_list.items.len;
        const type_ancestors_outer = try allocator.alloc([]const u32, n_composite);
        errdefer {
            for (type_ancestors_outer) |anc_slice| allocator.free(anc_slice);
            allocator.free(type_ancestors_outer);
        }
        for (0..n_composite) |i| {
            const direct_parent = direct_parents_list.items[i];
            if (direct_parent) |p| {
                // ancestors of i = [p] ++ ancestors[p]
                // ancestors[p] is already computed since p < i (Wasm spec ordering).
                const parent_ancestors = type_ancestors_outer[p];
                const anc_slice = try allocator.alloc(u32, 1 + parent_ancestors.len);
                anc_slice[0] = p;
                @memcpy(anc_slice[1..], parent_ancestors);
                type_ancestors_outer[i] = anc_slice;
            } else {
                type_ancestors_outer[i] = &.{};
            }
        }

        return .{
            .allocator = allocator,
            .functions = functions,
            .wasm_bytes = bytes,
            .exports = exports,
            .globals = globals,
            .memory = memory,
            .start_function = start_function,
            .imported_funcs = imported_funcs,
            .imported_globals = imported_globals,
            .tables = tables,
            .func_type_indices = func_type_indices,
            .data_segments = data_segments,
            .elem_segments = elem_segments,
            .composite_types = composite_types,
            .struct_layouts = struct_layouts,
            .array_layouts = array_layouts,
            .type_ancestors = type_ancestors_outer,
            .tags = tags,
            .config = .{ .eh_mode = detected_eh_mode },
            .translator = null,
        };
    }

    /// Compile and wrap the module in an `ArcModule`.
    ///
    /// Convenience wrapper: equivalent to
    ///   `ArcModule.init(allocator, try Module.compile(engine, bytes))`
    /// but handles the error path so that the Module is properly deinited on
    /// allocation failure.
    pub fn compileArc(engine: Engine, bytes: []const u8) (ModuleCompileError || std.mem.Allocator.Error)!ArcModule {
        var m = try compile(engine, bytes);
        errdefer m.deinit();
        return ArcModule.init(engine.allocator(), m);
    }

    /// Lazily compile a single function by its Wasm function index.
    ///
    /// If the slot is already `.encoded` or `.import`, this is a no-op.
    /// If the slot is `.pending`, the function body is compiled and the slot is
    /// updated to `.encoded` in place.
    ///
    /// This is called on the first invocation of any local function, either from
    /// `Instance.call()` (top-level export) or from `handlers_call` (call/call_indirect
    /// inside the VM).
    pub fn compileFunctionAt(self: *Module, engine: Engine, func_index: u32) ModuleCompileError!void {
        const slot = &self.functions[func_index];
        const pending = switch (slot.*) {
            .encoded, .import => return, // already compiled or an import
            .pending => |p| p,
        };

        const import_count = self.imported_funcs.len;

        // Build the FuncTypeResolver from module-level metadata.
        // The import_type_indices are stored in func_type_indices[0..import_count].
        const resolver = FuncTypeResolver{
            .composite_types = self.composite_types,
            .type_indices = self.func_type_indices[import_count..],
            .import_type_indices = self.func_type_indices[0..import_count],
            .import_count = import_count,
        };

        const func_type = switch (self.composite_types[pending.type_index]) {
            .func_type => |ft| ft,
            else => return error.InvalidFunctionTypeIndex,
        };

        // Lazily initialise the reusable translator allocations on first use.
        if (self.translator == null) {
            self.translator = FuncTranslatorAllocations.init(self.allocator);
        }
        const ta = &self.translator.?;

        var compile_timer = profiling.ScopedTimer.start();
        var compiled = if (self.config.eh_mode == .legacy)
            try compileFunctionBodyLegacyInto(
                ta,
                pending.reserved_slots,
                pending.locals_count,
                func_type.results().len,
                pending.body,
                engine.config().*,
                resolver,
                self.tags,
            )
        else
            try compileFunctionBodyNewInto(
                ta,
                pending.reserved_slots,
                pending.locals_count,
                func_type.results().len,
                pending.body,
                engine.config().*,
                resolver,
                self.tags,
            );
        profiling.call_prof.ns_compile_body += compile_timer.read();
        defer {
            compiled.ops.deinit(self.allocator);
            compiled.call_args.deinit(self.allocator);
            compiled.br_table_targets.deinit(self.allocator);
            compiled.catch_handler_tables.deinit(self.allocator);
        }

        var encode_timer = profiling.ScopedTimer.start();
        const encoded = try encode_mod.encode(
            self.allocator,
            &compiled,
            &handler_table_mod.handler_table,
        );
        profiling.call_prof.ns_encode_ir += encode_timer.read();
        slot.* = .{ .encoded = encoded };
    }

    pub fn deinit(self: *Module) void {
        if (self.translator) |*t| t.deinit();
        deinit_functions(self.allocator, self.functions);
        self.allocator.free(self.functions);

        deinit_exports(self.allocator, &self.exports);
        for (self.globals) |g| {
            if (g.init_expr) |expr| self.allocator.free(expr);
        }
        self.allocator.free(self.globals);

        for (self.imported_funcs) |def| {
            self.allocator.free(def.module_name);
            self.allocator.free(def.func_name);
        }
        self.allocator.free(self.imported_funcs);

        for (self.imported_globals) |def| {
            self.allocator.free(def.module_name);
            self.allocator.free(def.global_name);
        }
        self.allocator.free(self.imported_globals);

        for (self.tables) |t| {
            self.allocator.free(t);
        }
        self.allocator.free(self.tables);

        self.allocator.free(self.func_type_indices);

        for (self.data_segments) |*seg| {
            self.allocator.free(seg.data);
        }
        self.allocator.free(self.data_segments);

        for (self.elem_segments) |*seg| {
            self.allocator.free(seg.func_indices);
        }
        self.allocator.free(self.elem_segments);

        for (self.composite_types) |*ct| {
            ct.deinit(self.allocator);
        }
        self.allocator.free(self.composite_types);

        for (self.struct_layouts) |*sl| {
            if (sl.*) |layout| {
                layout.deinit(self.allocator);
            }
        }
        self.allocator.free(self.struct_layouts);

        self.allocator.free(self.array_layouts);

        for (self.type_ancestors) |anc_slice| {
            self.allocator.free(anc_slice);
        }
        self.allocator.free(self.type_ancestors);

        self.allocator.free(self.tags);

        self.* = undefined;
    }

    // ── deinit helpers ───────────────────────────────────────────────────────────

    /// Free heap memory held by each FunctionSlot.
    /// Only `.encoded` variants own memory; `.import` and `.pending` do not.
    fn deinit_functions(allocator: Allocator, functions: []FunctionSlot) void {
        for (functions) |*slot| {
            switch (slot.*) {
                .encoded => |*ef| ef.deinit(allocator),
                .import, .pending => {},
            }
        }
    }

    /// Free the exports map: first free each key (the heap memory of the export name), then free the map itself.
    fn deinit_exports(allocator: Allocator, exports_map: *std.StringHashMapUnmanaged(ExportEntry)) void {
        var iterator = exports_map.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        exports_map.deinit(allocator);
    }

    // ── compile helpers ──────────────────────────────────────────────────────────

    /// Insert a function export entry into the exports map.
    /// The export name `name` will be copied to heap memory (`owned_name`), and the exports map is responsible for its lifecycle.
    /// If an export with the same name already exists, a `DuplicateExport` error is returned.
    fn put_function_export(
        allocator: Allocator,
        exports_map: *std.StringHashMapUnmanaged(ExportEntry),
        name: []const u8,
        entry: ExportEntry,
    ) ModuleCompileError!void {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);

        const result = try exports_map.getOrPut(allocator, owned_name);
        if (result.found_existing) {
            return error.DuplicateExport;
        }
        result.value_ptr.* = entry;
    }

    /// Compile a TypeEntry from the parser into a runtime FuncType.
    /// Currently, only func types are supported; parameter and return types are temporarily allocated
    /// using temp_allocator, and finally copied into memory managed by allocator via FuncType.init.
    fn compile_func_type(
        allocator: Allocator,
        temp_allocator: Allocator,
        entry: payload_mod.TypeEntry,
    ) ModuleCompileError!FuncType {
        if (entry.type != .func) return error.UnsupportedFunctionType;

        const param_types = try temp_allocator.alloc(ValType, entry.params.len);
        for (entry.params, 0..) |param, index| {
            param_types[index] = try translate_mod.wasmValTypeFromType(param);
        }

        const result_types = try temp_allocator.alloc(ValType, entry.returns.len);
        for (entry.returns, 0..) |result, index| {
            result_types[index] = try translate_mod.wasmValTypeFromType(result);
        }

        return try FuncType.init(allocator, param_types, result_types);
    }

    /// Compile a GlobalVariable from the parser into a runtime GlobalInit.
    ///
    /// GlobalVariable contains:
    ///   - typ: value type (content_type) and mutability
    ///   - init_expr: the initialization expression of the global variable, which is a sequence of raw bytecode (constant expression)
    ///
    /// This function first attempts to statically evaluate the init_expr using evaluate_const_expr.
    /// If the expression contains GC instructions (struct.new, array.new_fixed, etc.) that require
    /// heap allocation, static evaluation will fail with UnsupportedConstExpr.  In that case, the
    /// raw init_expr bytecode is stored in GlobalInit.init_expr for deferred runtime evaluation
    /// during instantiation (when the GC heap is available).
    fn compile_global_init(
        allocator: Allocator,
        temp_allocator: Allocator,
        global_variable: payload_mod.GlobalVariable,
    ) ModuleCompileError!GlobalInit {
        const val_type = try translate_mod.wasmValTypeFromType(global_variable.typ.content_type);
        const mutability = switch (global_variable.typ.mutability) {
            0 => Mutability.Const,
            1 => Mutability.Var,
            else => return error.InvalidMutability,
        };

        // Try static evaluation first (works for i32.const, ref.null, etc.)
        if (evaluate_const_expr(temp_allocator, global_variable.init_expr, val_type)) |value| {
            return .{
                .mutability = mutability,
                .value = TypedRawVal.init(val_type, value),
            };
        } else |err| switch (err) {
            error.UnsupportedConstExpr => {
                // GC const expr — defer to runtime evaluation.
                // Store a copy of the raw init_expr bytecode.
                const expr_copy = try allocator.dupe(u8, global_variable.init_expr);
                return .{
                    .mutability = mutability,
                    .value = TypedRawVal.init(val_type, RawVal.fromBits64(0)),
                    .init_expr = expr_copy,
                };
            },
            else => return err,
        }
    }

    /// Evaluate a WebAssembly constant expression (init expression) and return the corresponding raw value.
    ///
    /// Constant expressions are restricted instruction sequences in the Wasm specification, allowing only:
    ///   - i32.const / i64.const / f32.const / f64.const
    ///   - ref.null
    ///   - global.get (only for imported globals; deferred to runtime via UnsupportedConstExpr)
    /// The expression must end with an end instruction.
    ///
    /// expected_type determines how to interpret the literal in the bytecode.
    fn evaluate_const_expr(
        allocator: Allocator,
        expr: []const u8,
        expected_type: ValType,
    ) ModuleCompileError!RawVal {
        var cursor: usize = 0;

        const init = try parser_mod.readNextOperator(allocator, expr[cursor..]);
        cursor += init.consumed;

        const value = switch (expected_type) {
            .I32, .I64, .F32, .F64 => {
                // global.get in a const expr defers to runtime (only imported globals are valid).
                if (init.info.code == .global_get) return error.UnsupportedConstExpr;
                return utils_parse.parseConstLiteral(init.info) catch error.UnsupportedConstExpr;
            },
            .Ref => |ref_ty| switch (ref_ty.heap_type) {
                // All null references use the unified sentinel: low64 == 0.
                // funcref non-null values are encoded as func_idx+1 so that
                // func_idx=0 is never confused with null.
                .Func, .Extern => switch (init.info.code) {
                    .ref_null => RawVal.fromBits64(0),
                    else => return error.UnsupportedConstExpr,
                },
                // GC abstract heap types — same null encoding.
                .Any, .Eq, .I31, .Struct, .Array, .None, .NoFunc, .NoExtern => switch (init.info.code) {
                    .ref_null => RawVal.fromBits64(0),
                    else => return error.UnsupportedConstExpr,
                },
                // Concrete (user-defined) GC types — same null encoding.
                else => switch (init.info.code) {
                    .ref_null => RawVal.fromBits64(0),
                    else => return error.UnsupportedConstExpr,
                },
            },
            else => return error.UnsupportedGlobalType,
        };

        const end = try parser_mod.readNextOperator(allocator, expr[cursor..]);
        cursor += end.consumed;
        if (end.info.code != .end or cursor != expr.len) {
            return error.UnsupportedConstExpr;
        }

        return value;
    }

    /// Compute the total number of value slots needed for executing a function,
    /// including both parameters and all local variables declared in the function body.
    fn compute_reserved_slots(func_type: FuncType, function_info: payload_mod.FunctionInformation) ModuleCompileError!u32 {
        var locals_count: usize = func_type.params().len;
        for (function_info.locals) |local_group| {
            locals_count += local_group.count;
        }
        return std.math.cast(u32, locals_count) orelse error.InvalidLocalCount;
    }
};

/// A reference-counted, thread-safe handle to a compiled `Module`.
///
/// Multiple `Instance` values can share the same `Module` without manual lifetime management.
/// Cloning increments the refcount; `release` decrements it and frees the module when it reaches zero.
///
/// Usage:
///   var arc = try ArcModule.init(allocator, try Module.compile(engine, bytes));
///   defer arc.release();
///   var instance = try Instance.init(&store, arc.retain(), linker);
pub const ArcModule = zigrc.Arc(Module);

/// Function type resolver: look up function signatures (parameter count, return count) by func_idx.
///
/// Wasm function index space = imported functions + local functions.
/// type_indices covers only local functions; import_type_indices covers only imported functions.
/// Uses the unified composite_types array (indexed by type section index).
pub const FuncTypeResolver = struct {
    composite_types: []const CompositeType,
    /// Type index for each local (non-imported) function, in order.
    type_indices: []const u32,
    /// Type index for each imported function, in the order they appear in the Import Section.
    /// Length must equal import_count.
    import_type_indices: []const u32,
    import_count: usize,

    /// Look up the FuncType by func_idx.
    /// Returns an error if func_idx is out of bounds or the type is not a func type.
    pub fn resolve(self: FuncTypeResolver, func_idx: u32) ModuleCompileError!*const FuncType {
        if (func_idx < self.import_count) {
            // Imported function: look up via import_type_indices.
            const type_idx = self.import_type_indices[func_idx];
            return self.getFuncType(type_idx);
        }
        const local_idx = func_idx - @as(u32, @intCast(self.import_count));
        if (local_idx >= self.type_indices.len) return error.InvalidFunctionTypeIndex;
        const type_idx = self.type_indices[local_idx];
        return self.getFuncType(type_idx);
    }

    /// Look up the FuncType by type section index.
    fn getFuncType(self: FuncTypeResolver, type_idx: u32) ModuleCompileError!*const FuncType {
        if (type_idx >= self.composite_types.len) return error.InvalidFunctionTypeIndex;
        return switch (self.composite_types[type_idx]) {
            .func_type => |*ft| ft,
            else => error.InvalidFunctionTypeIndex,
        };
    }
};

/// Compile a single function body from Wasm bytecode into a CompiledFunction.
///
/// reserved_slots is the total number of value slots needed for executing the function,
/// calculated by the caller based on the function signature and local variable declarations.
/// body is the raw bytecode of the Wasm function body (excluding the locals declaration part).
/// resolver is used to look up callee function signatures when translating call instructions.
pub fn compileFunctionBody(
    allocator: Allocator,
    reserved_slots: u32,
    locals_count: u16,
    n_results: usize,
    body: []const u8,
    config: EngineConfig,
    resolver: FuncTypeResolver,
    tags: []const TagDef,
    eh_mode: EHMode,
) ModuleCompileError!CompiledFunction {
    if (eh_mode == .legacy) {
        return compileFunctionBodyLegacy(allocator, reserved_slots, locals_count, n_results, body, config, resolver, tags);
    }
    return compileFunctionBodyNew(allocator, reserved_slots, locals_count, n_results, body, config, resolver, tags);
}

/// Compile a function body using the new EH proposal (try_table / throw / throw_ref).
fn compileFunctionBodyNew(
    allocator: Allocator,
    reserved_slots: u32,
    locals_count: u16,
    n_results: usize,
    body: []const u8,
    config: EngineConfig,
    resolver: FuncTypeResolver,
    tags: []const TagDef,
) ModuleCompileError!CompiledFunction {
    var timer = profiling.ScopedTimer.start();
    profiling.compile_prof.functions_compiled += 1;
    const start_total = timer.read();

    timer.lap(&profiling.compile_prof.ns_arena_init);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer {
        const before_deinit = timer.read();
        arena.deinit();
        profiling.compile_prof.ns_arena_deinit += timer.read() - before_deinit;
    }

    timer.lap(&profiling.compile_prof.ns_lower_init);
    var lower = Lower.initWithReservedSlots(allocator, reserved_slots, locals_count);
    lower.composite_types = resolver.composite_types;
    errdefer lower.deinit();

    // Push the implicit function-level block frame so that `br depth` targeting
    // the function body (e.g. `br 0` at top-level) resolves correctly instead
    // of triggering ControlStackUnderflow.
    try lower.pushFunctionFrame(n_results);

    var fbp = parser_mod.FunctionBodyParser.init(arena.allocator(), body);
    while (!fbp.done()) {
        const before_read = timer.read();
        const op_info = try fbp.next();
        profiling.compile_prof.ns_read_operator += timer.read() - before_read;
        profiling.compile_prof.opcodes_processed += 1;

        if (simd.isSimdOpcode(op_info.code)) {
            if (!config.simd) return error.DisabledSimd;
            if (simd.isRelaxedSimdOpcode(op_info.code) and !config.relaxed_simd) {
                return error.DisabledRelaxedSimd;
            }
        }

        const before_lower = timer.read();
        if (!try lower.lowerOpFromInfo(op_info)) {
            const before_build = timer.read();
            const wasm_op = try buildWasmOp(op_info, resolver, tags, arena.allocator());
            profiling.compile_prof.ns_build_wasm_op += timer.read() - before_build;

            lower.lowerOp(wasm_op) catch |err| {
                return err;
            };
        }
        profiling.compile_prof.ns_lower_op += timer.read() - before_lower;
    }

    const before_encode = timer.read();
    const compiled = lower.finish();
    lower.compiled.ops = .empty;
    lower.compiled.call_args = .empty;
    lower.compiled.br_table_targets = .empty;
    lower.compiled.catch_handler_tables = .empty;
    lower.deinit();
    profiling.compile_prof.ns_encode += timer.read() - before_encode;

    profiling.compile_prof.ns_total += timer.read() - start_total;
    return compiled;
}

/// Compile a function body using the legacy EH proposal (try / catch / rethrow / delegate).
fn compileFunctionBodyLegacy(
    allocator: Allocator,
    reserved_slots: u32,
    locals_count: u16,
    n_results: usize,
    body: []const u8,
    config: EngineConfig,
    resolver: FuncTypeResolver,
    tags: []const TagDef,
) ModuleCompileError!CompiledFunction {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var lower_legacy = LowerLegacy.initWithReservedSlots(allocator, reserved_slots, locals_count);
    lower_legacy.inner.composite_types = resolver.composite_types;
    errdefer lower_legacy.deinit();

    // Push the implicit function-level block frame (same rationale as the new path).
    // Use the LowerLegacy wrapper so that try_states stays in sync.
    try lower_legacy.pushFunctionFrame(n_results);

    var fbp_nonfunc = parser_mod.FunctionBodyParser.init(arena.allocator(), body);
    while (!fbp_nonfunc.done()) {
        const op_info = try fbp_nonfunc.next();

        if (simd.isSimdOpcode(op_info.code)) {
            if (!config.simd) return error.DisabledSimd;
            if (simd.isRelaxedSimdOpcode(op_info.code) and !config.relaxed_simd) {
                return error.DisabledRelaxedSimd;
            }
        }

        switch (op_info.code) {
            .try_ => {
                const block_type: ?lower_mod.BlockType = if (op_info.block_type) |bt|
                    try translate_mod.wasmBlockTypeFromType(bt)
                else
                    null;
                try lower_legacy.lowerLegacyOp(.{ .try_ = block_type });
            },
            .catch_ => {
                const tag_idx = op_info.tag_index orelse return error.UnsupportedOperator;
                if (tag_idx >= tags.len) return error.InvalidTagIndex;
                const tag_type_idx = tags[tag_idx].type_index;
                const tag_func_type = try resolver.getFuncType(tag_type_idx);
                const tag_arity: u32 = @intCast(tag_func_type.params().len);
                try lower_legacy.lowerLegacyOp(.{ .catch_ = .{
                    .tag_index = tag_idx,
                    .tag_arity = tag_arity,
                } });
            },
            .catch_all => {
                try lower_legacy.lowerLegacyOp(.catch_all);
            },
            .rethrow => {
                const depth = op_info.relative_depth orelse 0;
                try lower_legacy.lowerLegacyOp(.{ .rethrow = depth });
            },
            .delegate => {
                const depth = op_info.relative_depth orelse 0;
                try lower_legacy.lowerLegacyOp(.{ .delegate = depth });
            },
            .end => {
                // Use lowerLegacyEnd which handles closing legacy try/catch blocks.
                try lower_legacy.lowerLegacyEnd();
            },
            else => {
                const cs_before = lower_legacy.inner.control_stack.items.len;
                if (!try lower_legacy.inner.lowerOpFromInfo(op_info)) {
                    const wasm_op = try buildWasmOp(op_info, resolver, tags, arena.allocator());
                    try lower_legacy.lowerLegacyOp(.{ .non_legacy = wasm_op });
                } else {
                    // Sync try_states with control stack changes (mirrors lowerLegacyOp).
                    const cs_after = lower_legacy.inner.control_stack.items.len;
                    if (cs_after > cs_before) {
                        const added = cs_after - cs_before;
                        var j: usize = 0;
                        while (j < added) : (j += 1) {
                            try lower_legacy.try_states.append(lower_legacy.allocator, null);
                        }
                    } else if (cs_after < cs_before) {
                        const removed = cs_before - cs_after;
                        lower_legacy.try_states.shrinkRetainingCapacity(lower_legacy.try_states.items.len -| removed);
                    }
                }
            },
        }
    }

    const compiled = lower_legacy.finish();
    lower_legacy.inner.compiled.ops = .empty;
    lower_legacy.inner.compiled.call_args = .empty;
    lower_legacy.inner.compiled.br_table_targets = .empty;
    lower_legacy.inner.compiled.catch_handler_tables = .empty;
    lower_legacy.deinit();
    return compiled;
}

/// Compile a function body using the new EH proposal, reusing `ta`'s Lower and
/// scratch arena to avoid per-function allocation churn.
fn compileFunctionBodyNewInto(
    ta: *FuncTranslatorAllocations,
    reserved_slots: u32,
    locals_count: u16,
    n_results: usize,
    body: []const u8,
    config: EngineConfig,
    resolver: FuncTypeResolver,
    tags: []const TagDef,
) ModuleCompileError!CompiledFunction {
    var timer = profiling.ScopedTimer.start();
    profiling.compile_prof.functions_compiled += 1;
    const start_total = timer.read();

    timer.lap(&profiling.compile_prof.ns_lower_init);
    ta.resetNew(reserved_slots, locals_count);
    const lower = &ta.lower;
    lower.composite_types = resolver.composite_types;

    try lower.pushFunctionFrame(n_results);

    const scratch = ta.scratch.allocator();
    var fbp = parser_mod.FunctionBodyParser.init(scratch, body);
    while (!fbp.done()) {
        const before_read = timer.read();
        const op_info = try fbp.next();
        profiling.compile_prof.ns_read_operator += timer.read() - before_read;
        profiling.compile_prof.opcodes_processed += 1;

        if (simd.isSimdOpcode(op_info.code)) {
            if (!config.simd) return error.DisabledSimd;
            if (simd.isRelaxedSimdOpcode(op_info.code) and !config.relaxed_simd) {
                return error.DisabledRelaxedSimd;
            }
        }

        const before_lower = timer.read();
        if (!try lower.lowerOpFromInfo(op_info)) {
            const before_build = timer.read();
            const wasm_op = try buildWasmOp(op_info, resolver, tags, scratch);
            profiling.compile_prof.ns_build_wasm_op += timer.read() - before_build;

            lower.lowerOp(wasm_op) catch |err| return err;
        }
        profiling.compile_prof.ns_lower_op += timer.read() - before_lower;
    }

    // Transfer ownership of the compiled lists out of the reusable Lower.
    // Null the originals so the next reset() does not double-free them.
    const before_encode = timer.read();
    const compiled = lower.finish();
    lower.compiled.ops = .empty;
    lower.compiled.call_args = .empty;
    lower.compiled.br_table_targets = .empty;
    lower.compiled.catch_handler_tables = .empty;
    profiling.compile_prof.ns_encode += timer.read() - before_encode;

    profiling.compile_prof.ns_total += timer.read() - start_total;
    return compiled;
}

/// Compile a function body using the legacy EH proposal, reusing `ta`.
fn compileFunctionBodyLegacyInto(
    ta: *FuncTranslatorAllocations,
    reserved_slots: u32,
    locals_count: u16,
    n_results: usize,
    body: []const u8,
    config: EngineConfig,
    resolver: FuncTypeResolver,
    tags: []const TagDef,
) ModuleCompileError!CompiledFunction {
    ta.resetLegacy(reserved_slots, locals_count);
    const lower_legacy = &ta.lower_legacy;
    lower_legacy.inner.composite_types = resolver.composite_types;

    try lower_legacy.pushFunctionFrame(n_results);

    const scratch = ta.scratch.allocator();
    var fbp_legacy = parser_mod.FunctionBodyParser.init(scratch, body);
    while (!fbp_legacy.done()) {
        const op_info = try fbp_legacy.next();

        if (simd.isSimdOpcode(op_info.code)) {
            if (!config.simd) return error.DisabledSimd;
            if (simd.isRelaxedSimdOpcode(op_info.code) and !config.relaxed_simd) {
                return error.DisabledRelaxedSimd;
            }
        }

        switch (op_info.code) {
            .try_ => {
                const block_type: ?lower_mod.BlockType = if (op_info.block_type) |bt|
                    try translate_mod.wasmBlockTypeFromType(bt)
                else
                    null;
                try lower_legacy.lowerLegacyOp(.{ .try_ = block_type });
            },
            .catch_ => {
                const tag_idx = op_info.tag_index orelse return error.UnsupportedOperator;
                if (tag_idx >= tags.len) return error.InvalidTagIndex;
                const tag_type_idx = tags[tag_idx].type_index;
                const tag_func_type = try resolver.getFuncType(tag_type_idx);
                const tag_arity: u32 = @intCast(tag_func_type.params().len);
                try lower_legacy.lowerLegacyOp(.{ .catch_ = .{
                    .tag_index = tag_idx,
                    .tag_arity = tag_arity,
                } });
            },
            .catch_all => {
                try lower_legacy.lowerLegacyOp(.catch_all);
            },
            .rethrow => {
                const depth = op_info.relative_depth orelse 0;
                try lower_legacy.lowerLegacyOp(.{ .rethrow = depth });
            },
            .delegate => {
                const depth = op_info.relative_depth orelse 0;
                try lower_legacy.lowerLegacyOp(.{ .delegate = depth });
            },
            .end => {
                try lower_legacy.lowerLegacyEnd();
            },
            else => {
                const cs_before = lower_legacy.inner.control_stack.items.len;
                if (!try lower_legacy.inner.lowerOpFromInfo(op_info)) {
                    const wasm_op = try buildWasmOp(op_info, resolver, tags, scratch);
                    try lower_legacy.lowerLegacyOp(.{ .non_legacy = wasm_op });
                } else {
                    // Sync try_states with control stack changes (mirrors lowerLegacyOp).
                    const cs_after = lower_legacy.inner.control_stack.items.len;
                    if (cs_after > cs_before) {
                        const added = cs_after - cs_before;
                        var j: usize = 0;
                        while (j < added) : (j += 1) {
                            try lower_legacy.try_states.append(lower_legacy.allocator, null);
                        }
                    } else if (cs_after < cs_before) {
                        const removed = cs_before - cs_after;
                        lower_legacy.try_states.shrinkRetainingCapacity(lower_legacy.try_states.items.len -| removed);
                    }
                }
            },
        }
    }

    const compiled = lower_legacy.finish();
    lower_legacy.inner.compiled.ops = .empty;
    lower_legacy.inner.compiled.call_args = .empty;
    lower_legacy.inner.compiled.br_table_targets = .empty;
    lower_legacy.inner.compiled.catch_handler_tables = .empty;
    return compiled;
}

/// Build a WasmOp from an OperatorInformation, handling special cases that require
/// resolver and tag lookups (call, call_indirect, throw, try_table, etc.).
fn buildWasmOp(
    info: payload_mod.OperatorInformation,
    resolver: FuncTypeResolver,
    tags: []const TagDef,
    arena_allocator: Allocator,
) ModuleCompileError!lower_mod.WasmOp {
    return if (info.code == .call) blk: {
        const func_idx = info.func_index orelse return error.UnsupportedOperator;
        const func_type = try resolver.resolve(func_idx);
        break :blk .{ .call = .{
            .func_idx = func_idx,
            .n_params = @intCast(func_type.params().len),
            .has_result = func_type.results().len > 0,
        } };
    } else if (info.code == .call_indirect) blk: {
        // type_index is encoded as a HeapType in info.type_index.
        const heap_type = info.type_index orelse return error.UnsupportedOperator;
        const type_index: u32 = switch (heap_type) {
            .index => |idx| idx,
            .kind => return error.UnsupportedOperator,
        };
        if (type_index >= resolver.composite_types.len) return error.InvalidFunctionTypeIndex;
        const func_type = try resolver.getFuncType(type_index);
        // table_index: the parser discards it (reads as var_uint1), so always use 0.
        break :blk .{ .call_indirect = .{
            .type_index = type_index,
            .table_index = 0,
            .n_params = @intCast(func_type.params().len),
            .has_result = func_type.results().len > 0,
        } };
    } else if (info.code == .return_call) blk: {
        const func_idx = info.func_index orelse return error.UnsupportedOperator;
        const func_type = try resolver.resolve(func_idx);
        break :blk .{ .return_call = .{
            .func_idx = func_idx,
            .n_params = @intCast(func_type.params().len),
        } };
    } else if (info.code == .return_call_indirect) blk: {
        const heap_type = info.type_index orelse return error.UnsupportedOperator;
        const type_index: u32 = switch (heap_type) {
            .index => |idx| idx,
            .kind => return error.UnsupportedOperator,
        };
        if (type_index >= resolver.composite_types.len) return error.InvalidFunctionTypeIndex;
        const func_type = try resolver.getFuncType(type_index);
        break :blk .{ .return_call_indirect = .{
            .type_index = type_index,
            .table_index = 0,
            .n_params = @intCast(func_type.params().len),
        } };
    } else if (info.code == .throw) blk: {
        // Look up the tag's FuncType to determine n_args.
        const tag_idx = info.tag_index orelse return error.UnsupportedOperator;
        if (tag_idx >= tags.len) return error.InvalidTagIndex;
        const tag_type_idx = tags[tag_idx].type_index;
        const tag_func_type = try resolver.getFuncType(tag_type_idx);
        break :blk .{ .throw = .{
            .tag_index = tag_idx,
            .n_args = @intCast(tag_func_type.params().len),
        } };
    } else if (info.code == .try_table) blk: {
        // Build CatchHandlerWasm slice with tag_arity filled in from tag FuncTypes.
        const raw_handlers = info.try_table;
        var handlers_list = try std.ArrayListUnmanaged(lower_mod.CatchHandlerWasm).initCapacity(
            arena_allocator,
            raw_handlers.len,
        );
        for (raw_handlers) |h| {
            const tag_arity: u32 = if (h.tag_index) |ti| arity: {
                if (ti >= tags.len) return error.InvalidTagIndex;
                const ti_type = tags[ti].type_index;
                const ti_func_type = try resolver.getFuncType(ti_type);
                break :arity @intCast(ti_func_type.params().len);
            } else 0;
            try handlers_list.append(arena_allocator, .{
                .kind = h.kind,
                .tag_index = h.tag_index,
                .depth = h.depth,
                .tag_arity = tag_arity,
            });
        }
        const block_type: ?lower_mod.BlockType = if (info.block_type) |bt|
            // Use the same conversion as block/loop/if.
            // empty_block_type → null (void), otherwise the concrete ValType.
            try translate_mod.wasmBlockTypeFromType(bt)
        else
            null;
        break :blk .{ .try_table = .{
            .block_type = block_type,
            .handlers = handlers_list.items,
        } };
    } else if (info.code == .struct_new) blk: {
        // struct_new needs n_fields from the StructType definition.
        const type_idx = switch (info.ref_type orelse return error.UnsupportedOperator) {
            .index => |idx| idx,
            .kind => return error.UnsupportedOperator,
        };
        if (type_idx >= resolver.composite_types.len) return error.InvalidFunctionTypeIndex;
        const n_fields: u32 = switch (resolver.composite_types[type_idx]) {
            .struct_type => |st| @intCast(st.fields.len),
            else => return error.InvalidFunctionTypeIndex,
        };
        break :blk .{ .struct_new = .{
            .type_idx = type_idx,
            .n_fields = n_fields,
        } };
    } else if (info.code == .call_ref) blk: {
        // call_ref operand is a type index (functype); fill in n_params/has_result.
        const type_idx = switch (info.type_index orelse return error.UnsupportedOperator) {
            .index => |idx| idx,
            .kind => return error.UnsupportedOperator,
        };
        const func_type = try resolver.getFuncType(type_idx);
        break :blk .{ .call_ref = .{
            .type_idx = type_idx,
            .n_params = @intCast(func_type.params().len),
            .has_result = func_type.results().len > 0,
        } };
    } else if (info.code == .return_call_ref) blk: {
        // return_call_ref operand is a type index (functype); fill in n_params.
        const type_idx = switch (info.type_index orelse return error.UnsupportedOperator) {
            .index => |idx| idx,
            .kind => return error.UnsupportedOperator,
        };
        const func_type = try resolver.getFuncType(type_idx);
        break :blk .{ .return_call_ref = .{
            .type_idx = type_idx,
            .n_params = @intCast(func_type.params().len),
        } };
    } else try translate_mod.operatorToWasmOp(info);
}

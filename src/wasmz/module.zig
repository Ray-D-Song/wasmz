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
const parser_mod = @import("parser");
const payload_mod = @import("payload");
const engine_mod = @import("../engine/root.zig");
const engine_config_mod = @import("../engine/config.zig");
const lower_mod = @import("../compiler/lower.zig");
const lower_legacy_mod = @import("../compiler/lower_legacy.zig");
const translate_mod = @import("../compiler/translate.zig");
const ir = @import("../compiler/ir.zig");
const core = @import("core");
const func_type_mod = core.func_type;
const global_mod = core.global;
const raw_mod = core.raw;
const simd = core.simd;
const typed_mod = core.typed;
const value_type_mod = core.value_type;
const gc_mod = @import("../vm/gc/root.zig");

const Allocator = std.mem.Allocator;
const Parser = parser_mod.Parser;
const Payload = payload_mod.Payload;
const Type = payload_mod.Type;
const TypeKind = payload_mod.TypeKind;
const ExternalKind = payload_mod.ExternalKind;
const OperatorInformation = payload_mod.OperatorInformation;
const CompiledFunction = ir.CompiledFunction;
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

/// Global variable compilation result, including mutability and the initial value evaluated from constant expressions.
pub const GlobalInit = struct {
    mutability: Mutability,
    value: TypedRawVal,
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

/// Compiled WebAssembly module, holding all data required for runtime execution.
///
/// Field descriptions:
///   - functions:        List of compiled functions, indexed according to the Wasm function index space (imported functions come first).
///   - func_types:       All function signatures defined in the Type Section.
///   - exports:          Mapping from export names to ExportEntry, currently only function exports are supported.
///   - globals:          List of global variables, each containing mutability and the initial value evaluated from constant expressions.
///   - memory:           Linear memory definition (optional), currently supports at most one memory segment.
///   - start_function:   Optional start function index (from the Wasm Start Section).
///   - imported_funcs:   Metadata for every imported function.
///   - tables:           Each entry is a slice of function indices for one table (table 0, table 1, ...).
///                       Populated from active element segments in the Element Section.
///   - func_type_indices: Maps func_idx → type section index for every function (imports + locals).
///                        Used by call_indirect for runtime type checking.
///   - composite_types:  GC composite types from the Type Section (struct, array).
///   - struct_layouts:   Precomputed memory layouts for struct types (index matches composite_types).
///   - array_layouts:    Precomputed memory layouts for array types (index matches composite_types).
pub const Module = struct {
    allocator: Allocator,
    functions: []CompiledFunction,
    func_types: []FuncType,
    exports: std.StringHashMapUnmanaged(ExportEntry),
    globals: []GlobalInit,
    memory: ?MemoryDef,
    /// Wasm Start Section (optional).
    /// If present, Instance.init will automatically call this function after instantiation.
    start_function: ?u32,
    /// Metadata for each imported function in the order they appear in the Import Section.
    /// Length == number of imported functions == offset of first local function in `functions`.
    imported_funcs: []ImportedFuncDef,
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

        var func_types_list: std.ArrayListUnmanaged(FuncType) = .empty;
        errdefer deinit_func_type_list(allocator, &func_types_list);

        // GC types: struct/array composite types and their layouts.
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
                            try func_types_list.append(
                                allocator,
                                try compile_func_type(allocator, arena.allocator(), entry),
                            );
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
                    }
                },
                .function_entry => |entry| {
                    try function_type_indices.append(allocator, entry.type_index);
                },
                .global_variable => |entry| {
                    try globals_list.append(
                        allocator,
                        try compile_global_init(arena.allocator(), entry),
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
        const functions = try allocator.alloc(CompiledFunction, function_count);
        errdefer {
            deinit_functions(allocator, functions);
            allocator.free(functions);
        }
        @memset(functions, .{
            .slots_len = 0,
            .ops = .empty,
            .call_args = .empty,
            .br_table_targets = .empty,
            .catch_handler_tables = .empty,
        });

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
                    if (type_index >= func_types_list.items.len) {
                        return error.InvalidFunctionTypeIndex;
                    }

                    const reserved_slots = try compute_reserved_slots(func_types_list.items[type_index], info);
                    const function_index = imported_function_count + local_function_index;

                    // Build function type resolver for looking up callee signatures when translating call instructions.
                    // import_type_indices allows the resolver to return signatures for imported functions too.
                    const resolver = FuncTypeResolver{
                        .func_types = func_types_list.items,
                        .type_indices = function_type_indices.items,
                        .import_type_indices = import_type_indices_list.items,
                        .import_count = imported_function_count,
                    };

                    functions[function_index] = try compileFunctionBody(
                        allocator,
                        reserved_slots,
                        info.body,
                        engine.config().*,
                        resolver,
                        tags_list.items,
                        detected_eh_mode,
                    );
                    local_function_index += 1;
                },
                else => {},
            }
        }
        if (local_function_index != function_type_indices.items.len) {
            return error.MismatchedFunctionCount;
        }

        const func_types = try func_types_list.toOwnedSlice(allocator);
        errdefer {
            for (func_types) |func_type| {
                func_type.deinit(allocator);
            }
            allocator.free(func_types);
        }

        const globals = try globals_list.toOwnedSlice(allocator);
        errdefer allocator.free(globals);

        const imported_funcs = try imported_funcs_list.toOwnedSlice(allocator);

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
            .func_types = func_types,
            .exports = exports,
            .globals = globals,
            .memory = memory,
            .start_function = start_function,
            .imported_funcs = imported_funcs,
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
        };
    }

    pub fn deinit(self: *Module) void {
        deinit_functions(self.allocator, self.functions);
        self.allocator.free(self.functions);

        for (self.func_types) |func_type| {
            func_type.deinit(self.allocator);
        }
        self.allocator.free(self.func_types);

        deinit_exports(self.allocator, &self.exports);
        self.allocator.free(self.globals);

        for (self.imported_funcs) |def| {
            self.allocator.free(def.module_name);
            self.allocator.free(def.func_name);
        }
        self.allocator.free(self.imported_funcs);

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

    /// Free the operations list held by each CompiledFunction in the functions slice.
    fn deinit_functions(allocator: Allocator, functions: []CompiledFunction) void {
        for (functions) |*function| {
            function.call_args.deinit(allocator);
            function.ops.deinit(allocator);
            function.br_table_targets.deinit(allocator);
            function.catch_handler_tables.deinit(allocator);
        }
    }

    /// Free the FuncType list: first free each element, then free the list itself.
    fn deinit_func_type_list(allocator: Allocator, list: *std.ArrayListUnmanaged(FuncType)) void {
        for (list.items) |func_type| {
            func_type.deinit(allocator);
        }
        list.deinit(allocator);
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
    /// This function parses the init_expr bytecode and evaluates it (using evaluate_const_expr) to obtain the concrete initial value of the global variable.
    fn compile_global_init(
        temp_allocator: Allocator,
        global_variable: payload_mod.GlobalVariable,
    ) ModuleCompileError!GlobalInit {
        const val_type = try translate_mod.wasmValTypeFromType(global_variable.typ.content_type);
        const mutability = switch (global_variable.typ.mutability) {
            0 => Mutability.Const,
            1 => Mutability.Var,
            else => return error.InvalidMutability,
        };

        return .{
            .mutability = mutability,
            .value = TypedRawVal.init(
                val_type,
                try evaluate_const_expr(temp_allocator, global_variable.init_expr, val_type),
            ),
        };
    }

    /// Evaluate a WebAssembly constant expression (init expression) and return the corresponding raw value.
    ///
    /// Constant expressions are restricted instruction sequences in the Wasm specification, allowing only:
    ///   - i32.const / i64.const / f32.const / f64.const
    ///   - ref.null
    ///   - TODO: (Post-MVP) global.get (only for imported globals)
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
            .I32 => switch (init.info.code) {
                .i32_const => RawVal.from(try translate_mod.literalAsI32(init.info)),
                else => return error.UnsupportedConstExpr,
            },
            .I64 => switch (init.info.code) {
                .i64_const => RawVal.from(try translate_mod.literalAsI64(init.info)),
                else => return error.UnsupportedConstExpr,
            },
            .F32 => switch (init.info.code) {
                .f32_const => RawVal.from(try translate_mod.literalAsF32(init.info)),
                else => return error.UnsupportedConstExpr,
            },
            .F64 => switch (init.info.code) {
                .f64_const => RawVal.from(try translate_mod.literalAsF64(init.info)),
                else => return error.UnsupportedConstExpr,
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

/// Function type resolver: look up function signatures (parameter count, return count) by func_idx.
///
/// Wasm function index space = imported functions + local functions.
/// type_indices covers only local functions; import_type_indices covers only imported functions.
pub const FuncTypeResolver = struct {
    func_types: []const FuncType,
    /// Type index for each local (non-imported) function, in order.
    type_indices: []const u32,
    /// Type index for each imported function, in the order they appear in the Import Section.
    /// Length must equal import_count.
    import_type_indices: []const u32,
    import_count: usize,

    /// Look up the FuncType by func_idx.
    /// Returns an error if func_idx is out of bounds.
    pub fn resolve(self: FuncTypeResolver, func_idx: u32) ModuleCompileError!*const FuncType {
        if (func_idx < self.import_count) {
            // Imported function: look up via import_type_indices.
            const type_idx = self.import_type_indices[func_idx];
            if (type_idx >= self.func_types.len) return error.InvalidFunctionTypeIndex;
            return &self.func_types[type_idx];
        }
        const local_idx = func_idx - @as(u32, @intCast(self.import_count));
        if (local_idx >= self.type_indices.len) return error.InvalidFunctionTypeIndex;
        const type_idx = self.type_indices[local_idx];
        if (type_idx >= self.func_types.len) return error.InvalidFunctionTypeIndex;
        return &self.func_types[type_idx];
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
    body: []const u8,
    config: EngineConfig,
    resolver: FuncTypeResolver,
    tags: []const TagDef,
    eh_mode: EHMode,
) ModuleCompileError!CompiledFunction {
    if (eh_mode == .legacy) {
        return compileFunctionBodyLegacy(allocator, reserved_slots, body, config, resolver, tags);
    }
    return compileFunctionBodyNew(allocator, reserved_slots, body, config, resolver, tags);
}

/// Compile a function body using the new EH proposal (try_table / throw / throw_ref).
fn compileFunctionBodyNew(
    allocator: Allocator,
    reserved_slots: u32,
    body: []const u8,
    config: EngineConfig,
    resolver: FuncTypeResolver,
    tags: []const TagDef,
) ModuleCompileError!CompiledFunction {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var lower = Lower.initWithReservedSlots(allocator, reserved_slots);
    lower.func_types = resolver.func_types;
    errdefer lower.deinit();

    var cursor: usize = 0;
    while (cursor < body.len) {
        const parsed = try parser_mod.readNextOperator(arena.allocator(), body[cursor..]);
        cursor += parsed.consumed;

        if (simd.isSimdOpcode(parsed.info.code)) {
            if (!config.simd) return error.DisabledSimd;
            if (simd.isRelaxedSimdOpcode(parsed.info.code) and !config.relaxed_simd) {
                return error.DisabledRelaxedSimd;
            }
        }

        const wasm_op = try buildWasmOp(parsed.info, resolver, tags, arena.allocator());
        try lower.lowerOp(wasm_op);
    }

    const compiled = lower.finish();
    lower.compiled.ops = .empty;
    lower.compiled.call_args = .empty;
    lower.compiled.br_table_targets = .empty;
    lower.compiled.catch_handler_tables = .empty;
    lower.deinit();
    return compiled;
}

/// Compile a function body using the legacy EH proposal (try / catch / rethrow / delegate).
fn compileFunctionBodyLegacy(
    allocator: Allocator,
    reserved_slots: u32,
    body: []const u8,
    config: EngineConfig,
    resolver: FuncTypeResolver,
    tags: []const TagDef,
) ModuleCompileError!CompiledFunction {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var lower_legacy = LowerLegacy.initWithReservedSlots(allocator, reserved_slots);
    lower_legacy.inner.func_types = resolver.func_types;
    errdefer lower_legacy.deinit();

    var cursor: usize = 0;
    while (cursor < body.len) {
        const parsed = try parser_mod.readNextOperator(arena.allocator(), body[cursor..]);
        cursor += parsed.consumed;

        if (simd.isSimdOpcode(parsed.info.code)) {
            if (!config.simd) return error.DisabledSimd;
            if (simd.isRelaxedSimdOpcode(parsed.info.code) and !config.relaxed_simd) {
                return error.DisabledRelaxedSimd;
            }
        }

        switch (parsed.info.code) {
            .try_ => {
                const block_type: ?lower_mod.BlockType = if (parsed.info.block_type) |bt|
                    try translate_mod.wasmBlockTypeFromType(bt)
                else
                    null;
                try lower_legacy.lowerLegacyOp(.{ .try_ = block_type });
            },
            .catch_ => {
                const tag_idx = parsed.info.tag_index orelse return error.UnsupportedOperator;
                if (tag_idx >= tags.len) return error.InvalidTagIndex;
                const tag_type_idx = tags[tag_idx].type_index;
                if (tag_type_idx >= resolver.func_types.len) return error.InvalidFunctionTypeIndex;
                const tag_arity: u32 = @intCast(resolver.func_types[tag_type_idx].params().len);
                try lower_legacy.lowerLegacyOp(.{ .catch_ = .{
                    .tag_index = tag_idx,
                    .tag_arity = tag_arity,
                } });
            },
            .catch_all => {
                try lower_legacy.lowerLegacyOp(.catch_all);
            },
            .rethrow => {
                const depth = parsed.info.relative_depth orelse 0;
                try lower_legacy.lowerLegacyOp(.{ .rethrow = depth });
            },
            .delegate => {
                const depth = parsed.info.relative_depth orelse 0;
                try lower_legacy.lowerLegacyOp(.{ .delegate = depth });
            },
            .end => {
                // Use lowerLegacyEnd which handles closing legacy try/catch blocks.
                try lower_legacy.lowerLegacyEnd();
            },
            else => {
                const wasm_op = try buildWasmOp(parsed.info, resolver, tags, arena.allocator());
                try lower_legacy.lowerLegacyOp(.{ .non_legacy = wasm_op });
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
        if (type_index >= resolver.func_types.len) return error.InvalidFunctionTypeIndex;
        const func_type = &resolver.func_types[type_index];
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
        if (type_index >= resolver.func_types.len) return error.InvalidFunctionTypeIndex;
        const func_type = &resolver.func_types[type_index];
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
        if (tag_type_idx >= resolver.func_types.len) return error.InvalidFunctionTypeIndex;
        const tag_func_type = &resolver.func_types[tag_type_idx];
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
                if (ti_type >= resolver.func_types.len) return error.InvalidFunctionTypeIndex;
                break :arity @intCast(resolver.func_types[ti_type].params().len);
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
    } else try translate_mod.operatorToWasmOp(info);
}

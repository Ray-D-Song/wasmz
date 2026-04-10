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
const Engine = engine_mod.Engine;
const Lower = lower_mod.Lower;
const EngineConfig = engine_config_mod.Config;

// TODO: Currently only supports function exports; other export kinds (memory, global, table) are ignored.
pub const ExportEntry = struct {
    function_index: u32,
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
pub const MemoryDef = struct {
    min_pages: u32,
    max_pages: ?u32,
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
                else => {},
            }
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

        self.* = undefined;
    }

    // ── deinit helpers ───────────────────────────────────────────────────────────

    /// Free the operations list held by each CompiledFunction in the functions slice.
    fn deinit_functions(allocator: Allocator, functions: []CompiledFunction) void {
        for (functions) |*function| {
            function.call_args.deinit(allocator);
            function.ops.deinit(allocator);
            function.br_table_targets.deinit(allocator);
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
                .Func, .Extern => switch (init.info.code) {
                    .ref_null => RawVal.fromBits64(std.math.maxInt(u64)),
                    else => return error.UnsupportedConstExpr,
                },
                else => return error.UnsupportedGlobalType,
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
) ModuleCompileError!CompiledFunction {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var lower = Lower.initWithReservedSlots(allocator, reserved_slots);
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

        const wasm_op: lower_mod.WasmOp = if (parsed.info.code == .call) blk: {
            const func_idx = parsed.info.func_index orelse return error.UnsupportedOperator;
            const func_type = try resolver.resolve(func_idx);
            break :blk .{ .call = .{
                .func_idx = func_idx,
                .n_params = @intCast(func_type.params().len),
                .has_result = func_type.results().len > 0,
            } };
        } else if (parsed.info.code == .call_indirect) blk: {
            // type_index is encoded as a HeapType in parsed.info.type_index.
            const heap_type = parsed.info.type_index orelse return error.UnsupportedOperator;
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
        } else if (parsed.info.code == .return_call) blk: {
            const func_idx = parsed.info.func_index orelse return error.UnsupportedOperator;
            const func_type = try resolver.resolve(func_idx);
            break :blk .{ .return_call = .{
                .func_idx = func_idx,
                .n_params = @intCast(func_type.params().len),
            } };
        } else if (parsed.info.code == .return_call_indirect) blk: {
            const heap_type = parsed.info.type_index orelse return error.UnsupportedOperator;
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
        } else try translate_mod.operatorToWasmOp(parsed.info);

        try lower.lowerOp(wasm_op);
    }

    const compiled = lower.finish();
    lower.compiled.ops = .empty;
    lower.compiled.call_args = .empty;
    lower.compiled.br_table_targets = .empty;
    lower.deinit();
    return compiled;
}

test "module.compile builds exported function bodies" {
    const VM = @import("../vm/root.zig").VM;
    const Config = @import("../engine/config.zig").Config;
    const Store = @import("./store.zig").Store;
    const HostInstance = @import("./host.zig").HostInstance;

    const exported_const_wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07,
        0x05, 0x01, 0x01, 'f',
        0x00, 0x00, 0x0a, 0x06,
        0x01, 0x04, 0x00, 0x41,
        0x01, 0x0b,
    };

    var engine = try Engine.init(std.testing.allocator, Config{});
    defer engine.deinit();

    var module = try Module.compile(engine, &exported_const_wasm);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 1), module.functions.len);
    try std.testing.expectEqual(@as(usize, 1), module.func_types.len);
    try std.testing.expectEqual(@as(usize, 1), module.exports.count());

    const export_entry = module.exports.get("f") orelse return error.MissingExport;
    try std.testing.expectEqual(@as(u32, 0), export_entry.function_index);

    var vm = VM.init(std.testing.allocator);
    var store = Store.init(std.testing.allocator, engine);
    defer store.deinit();
    var globals = [_]Global{};
    var memory: [0]u8 = .{};
    var tables = [_][]u32{};
    var host_instance = HostInstance{
        .module = &module,
        .globals = globals[0..],
        .memory = memory[0..],
        .tables = tables[0..],
    };
    var data_segments_dropped = [_]bool{};
    var elem_segments_dropped = [_]bool{};
    const result = (try vm.execute(
        module.functions[@intCast(export_entry.function_index)],
        &.{},
        &store,
        &host_instance,
        globals[0..],
        memory[0..],
        &.{},
        module.func_types,
        &.{},
        tables[0..],
        &.{},
        module.data_segments,
        data_segments_dropped[0..],
        module.elem_segments,
        elem_segments_dropped[0..],
    )).ok orelse {
        return error.MissingReturnValue;
    };
    try std.testing.expectEqual(@as(i32, 1), result.readAs(i32));
}

test "module.compile captures global initializers" {
    const Config = @import("../engine/config.zig").Config;
    const global_module_wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x06, 0x06, 0x01, 0x7f,
        0x00, 0x41, 0x2a, 0x0b,
        0x07, 0x05, 0x01, 0x01,
        'g',  0x03, 0x00,
    };

    var engine = try Engine.init(std.testing.allocator, Config{});
    defer engine.deinit();

    var module = try Module.compile(engine, &global_module_wasm);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 1), module.globals.len);
    try std.testing.expectEqual(Mutability.Const, module.globals[0].mutability);
    try std.testing.expectEqual(ValType.I32, module.globals[0].value.valType());
    try std.testing.expectEqual(@as(i32, 42), module.globals[0].value.into(i32));
    try std.testing.expectEqual(@as(usize, 0), module.functions.len);
}

test "module.compile handles active element segment with non-zero offset" {
    // WAT:
    //   (module
    //     (type (func (result i32)))
    //     (func (result i32) i32.const 42)   ;; func 0
    //     (func (result i32) i32.const 88)   ;; func 1
    //     (table 8 funcref)
    //     (elem (i32.const 3) func 0 1)      ;; active elem at offset 3
    //   )
    // This test verifies that the parser captures the offset expression and
    // the module compiler evaluates it to place elements at the correct table slots.
    const testing = std.testing;
    const config_mod = @import("../engine/config.zig");

    var engine = try engine_mod.Engine.init(testing.allocator, config_mod.Config{});
    defer engine.deinit();

    // Manually construct the wasm bytes:
    // - Type section: one function type (result i32)
    // - Function section: two function type indices
    // - Table section: one table of 8 funcref
    // - Element section: active segment with offset 3
    // - Code section: two function bodies returning constants
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        // Type section (id=1)
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
        // Function section (id=3)
        0x03,
        0x03, 0x02, 0x00, 0x00,
        // Table section (id=4)
        0x04, 0x04, 0x01, 0x70,
        0x00,
        0x08,
        // Element section (id=9)
        0x09, 0x08, 0x01, 0x00, // section id, size, count, segment type (legacy_active_funcref_externval)
        0x41, 0x03, 0x0b, // offset expression: i32.const 3, end
        0x02, 0x00, 0x01, // 2 function indices: 0, 1
        // Code section (id=10)
        0x0a, 0x0a, 0x02, 0x04, 0x00, 0x41, 0x2a, 0x0b, // func 0: i32.const 42, end
        0x04, 0x00, 0x41, 0x58, 0x0b, // func 1: i32.const 88, end
    };

    var module = try Module.compile(engine, &wasm);
    defer module.deinit();

    // Verify the element segment has the correct offset
    try testing.expectEqual(@as(usize, 1), module.elem_segments.len);
    try testing.expectEqual(payload_mod.ElementMode.active, module.elem_segments[0].mode);
    try testing.expectEqual(@as(u32, 3), module.elem_segments[0].offset);
    try testing.expectEqualSlices(u32, &[_]u32{ 0, 1 }, module.elem_segments[0].func_indices);

    // Verify the table was populated at the correct slots
    try testing.expectEqual(@as(usize, 1), module.tables.len);
    try testing.expectEqual(@as(usize, 8), module.tables[0].len);

    // Slots 0-2 should be null (maxInt(u32))
    try testing.expectEqual(std.math.maxInt(u32), module.tables[0][0]);
    try testing.expectEqual(std.math.maxInt(u32), module.tables[0][1]);
    try testing.expectEqual(std.math.maxInt(u32), module.tables[0][2]);

    // Slots 3-4 should contain the function indices from the element segment
    try testing.expectEqual(@as(u32, 0), module.tables[0][3]);
    try testing.expectEqual(@as(u32, 1), module.tables[0][4]);

    // Slots 5-7 should be null
    try testing.expectEqual(std.math.maxInt(u32), module.tables[0][5]);
    try testing.expectEqual(std.math.maxInt(u32), module.tables[0][6]);
    try testing.expectEqual(std.math.maxInt(u32), module.tables[0][7]);
}

test "compileFunctionBody rejects simd when disabled" {
    const body = [_]u8{
        0xfd, 0x0c,
    } ++ ([_]u8{0} ** 16) ++ [_]u8{0x0b};

    try std.testing.expectError(error.DisabledSimd, compileFunctionBody(
        std.testing.allocator,
        0,
        body[0..],
        .{ .simd = false },
        .{
            .func_types = &.{},
            .type_indices = &.{},
            .import_type_indices = &.{},
            .import_count = 0,
        },
    ));
}

test "compileFunctionBody rejects relaxed simd when disabled" {
    const zero_vec = [_]u8{ 0xfd, 0x0c } ++ ([_]u8{0} ** 16);
    const body = zero_vec ++ zero_vec ++ [_]u8{
        0xfd, 0x80, 0x02, // i8x16.relaxed_swizzle
        0x0b,
    };

    try std.testing.expectError(error.DisabledRelaxedSimd, compileFunctionBody(
        std.testing.allocator,
        0,
        body[0..],
        .{ .relaxed_simd = false },
        .{
            .func_types = &.{},
            .type_indices = &.{},
            .import_type_indices = &.{},
            .import_count = 0,
        },
    ));
}

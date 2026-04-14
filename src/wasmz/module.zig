/// module.zig - WebAssembly module compile entry
///
/// It will parse the raw Wasm bytes using the Parser in streaming mode, extract necessary
/// information from each Payload event as it arrives, and compile function bodies into
/// internal IR (CompiledFunction) using Lower.
/// Process:
///   1. Stream-parse the bytecode: the Parser emits one Payload event at a time; each event
///      is processed immediately without materializing the full payload array.
///   2. Extract types, functions, globals, memory, exports, etc., from each event inline.
///   3. Compile each function body into internal IR (CompiledFunction) using Lower (lazily on first call).
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
    /// The actual data bytes.
    ///
    /// Ownership rules:
    ///   - passive segments: owned slice, freed in Module.deinit.
    ///   - active segments: owned slice until the first instantiation; after all
    ///     active segments have been copied into linear memory the slice is freed
    ///     and reset to `&.{}` by `Module.releaseActiveSegmentData`.  Once freed,
    ///     `data.len == 0` and the field must not be freed again.
    data: []u8,
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

pub const ModuleCompileReaderError = ModuleCompileError || std.Io.Reader.ShortError;

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

const BuildState = struct {
    allocator: Allocator,
    engine: Engine,
    arena: std.heap.ArenaAllocator,
    /// Arena for pending function body copies (compileReader path).
    /// null when bodies borrow external bytes (compile(bytes) path).
    body_arena: ?std.heap.ArenaAllocator = null,

    composite_types_list: std.ArrayListUnmanaged(CompositeType) = .empty,
    struct_layouts_list: std.ArrayListUnmanaged(?StructLayout) = .empty,
    array_layouts_list: std.ArrayListUnmanaged(?ArrayLayout) = .empty,
    direct_parents_list: std.ArrayListUnmanaged(?u32) = .empty,
    function_type_indices: std.ArrayListUnmanaged(u32) = .empty,
    imported_funcs_list: std.ArrayListUnmanaged(ImportedFuncDef) = .empty,
    imported_globals_list: std.ArrayListUnmanaged(ImportedGlobalDef) = .empty,
    globals_list: std.ArrayListUnmanaged(GlobalInit) = .empty,
    exports: std.StringHashMapUnmanaged(ExportEntry) = .empty,
    memory: ?MemoryDef = null,
    start_function: ?u32 = null,
    pending_element_mode: payload_mod.ElementMode = .passive,
    pending_element_table_index: ?u32 = null,
    tables_lists: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u32)) = .empty,
    pending_data_mode: payload_mod.DataMode = .passive,
    pending_data_memory_index: ?u32 = null,
    data_segments_list: std.ArrayListUnmanaged(CompiledDataSegment) = .empty,
    elem_segments_list: std.ArrayListUnmanaged(CompiledElemSegment) = .empty,
    tags_list: std.ArrayListUnmanaged(TagDef) = .empty,
    local_functions_list: std.ArrayListUnmanaged(FunctionSlot) = .empty,
    detected_eh_mode: EHMode = .none,

    fn init(engine: Engine) BuildState {
        const allocator = engine.allocator();
        return .{
            .allocator = allocator,
            .engine = engine,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    fn deinit(self: *BuildState) void {
        for (self.composite_types_list.items) |*ct| {
            ct.deinit(self.allocator);
        }
        self.composite_types_list.deinit(self.allocator);

        for (self.struct_layouts_list.items) |*sl| {
            if (sl.*) |layout| {
                layout.deinit(self.allocator);
            }
        }
        self.struct_layouts_list.deinit(self.allocator);
        self.array_layouts_list.deinit(self.allocator);
        self.direct_parents_list.deinit(self.allocator);
        self.function_type_indices.deinit(self.allocator);

        for (self.imported_funcs_list.items) |def| {
            self.allocator.free(def.module_name);
            self.allocator.free(def.func_name);
        }
        self.imported_funcs_list.deinit(self.allocator);

        for (self.imported_globals_list.items) |def| {
            self.allocator.free(def.module_name);
            self.allocator.free(def.global_name);
        }
        self.imported_globals_list.deinit(self.allocator);

        for (self.globals_list.items) |g| {
            if (g.init_expr) |expr| self.allocator.free(expr);
        }
        self.globals_list.deinit(self.allocator);

        var export_iter = self.exports.iterator();
        while (export_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.exports.deinit(self.allocator);

        for (self.tables_lists.items) |*table_list| {
            table_list.deinit(self.allocator);
        }
        self.tables_lists.deinit(self.allocator);

        for (self.data_segments_list.items) |*seg| {
            self.allocator.free(seg.data);
        }
        self.data_segments_list.deinit(self.allocator);

        for (self.elem_segments_list.items) |*seg| {
            self.allocator.free(seg.func_indices);
        }
        self.elem_segments_list.deinit(self.allocator);

        self.tags_list.deinit(self.allocator);
        deinit_function_slots(self.allocator, self.local_functions_list.items);
        self.local_functions_list.deinit(self.allocator);

        // Free body arena if still owned (not transferred to Module via finish()).
        if (self.body_arena) |*ba| ba.deinit();
        self.arena.deinit();
    }

    fn parserAllocator(self: *BuildState) Allocator {
        return self.arena.allocator();
    }

    fn handlePayload(self: *BuildState, payload: Payload) ModuleCompileError!void {
        switch (payload) {
            .type_entry => |entry| {
                switch (entry.type) {
                    .func => {
                        const func_type = try Module.compile_func_type(self.allocator, self.parserAllocator(), entry);
                        try self.composite_types_list.append(self.allocator, CompositeType{ .func_type = func_type });
                        try self.struct_layouts_list.append(self.allocator, null);
                        try self.array_layouts_list.append(self.allocator, null);
                        try self.direct_parents_list.append(self.allocator, null);
                    },
                    .struct_type, .array_type => {
                        const composite_type = try translate_mod.wasmCompositeTypeFromTypeEntry(self.allocator, entry);
                        try self.composite_types_list.append(self.allocator, composite_type);

                        const direct_parent: ?u32 = blk: {
                            for (entry.super_types) |st| {
                                switch (st) {
                                    .index => |idx| break :blk idx,
                                    else => {},
                                }
                            }
                            break :blk null;
                        };
                        try self.direct_parents_list.append(self.allocator, direct_parent);

                        switch (composite_type) {
                            .struct_type => |s| {
                                const layout = try gc_mod.computeStructLayout(s, self.allocator);
                                try self.struct_layouts_list.append(self.allocator, layout);
                                try self.array_layouts_list.append(self.allocator, null);
                            },
                            .array_type => |a| {
                                try self.struct_layouts_list.append(self.allocator, null);
                                try self.array_layouts_list.append(self.allocator, gc_mod.computeArrayLayout(a));
                            },
                            .func_type => unreachable,
                        }
                    },
                    else => return error.UnsupportedFunctionType,
                }
            },
            .import_entry => |entry| {
                if (entry.kind == .function) {
                    const type_idx = entry.func_type_index orelse return error.InvalidFunctionTypeIndex;
                    const mod_name = try self.allocator.dupe(u8, entry.module);
                    errdefer self.allocator.free(mod_name);
                    const fn_name = try self.allocator.dupe(u8, entry.field);
                    errdefer self.allocator.free(fn_name);
                    try self.imported_funcs_list.append(self.allocator, .{
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
                    const mod_name = try self.allocator.dupe(u8, entry.module);
                    errdefer self.allocator.free(mod_name);
                    const global_name = try self.allocator.dupe(u8, entry.field);
                    errdefer self.allocator.free(global_name);
                    try self.imported_globals_list.append(self.allocator, .{
                        .module_name = mod_name,
                        .global_name = global_name,
                        .val_type = val_type,
                        .mutability = mutability,
                    });
                } else if (entry.kind == .tag) {
                    const tt = if (entry.typ) |t| t.tag else return error.InvalidTagImport;
                    try self.tags_list.append(self.allocator, .{ .type_index = tt.type_index });
                }
            },
            .function_entry => |entry| {
                try self.function_type_indices.append(self.allocator, entry.type_index);
            },
            .global_variable => |entry| {
                try self.globals_list.append(
                    self.allocator,
                    try Module.compile_global_init(self.allocator, self.parserAllocator(), entry),
                );
            },
            .memory_type => |entry| {
                if (self.memory != null) return error.MultipleMemories;
                self.memory = .{
                    .min_pages = entry.limits.initial,
                    .max_pages = entry.limits.maximum,
                    .shared = entry.shared,
                };
            },
            .export_entry => |entry| {
                switch (entry.kind) {
                    .function => try Module.put_function_export(
                        self.allocator,
                        &self.exports,
                        entry.field,
                        .{ .function_index = entry.index },
                    ),
                    .tag => try Module.put_function_export(
                        self.allocator,
                        &self.exports,
                        entry.field,
                        .{ .tag_index = entry.index },
                    ),
                    else => {},
                }
            },
            .start_entry => |entry| {
                self.start_function = entry.index;
            },
            .table_type => |tbl| {
                const tbl_idx = self.tables_lists.items.len;
                try self.tables_lists.append(self.allocator, .empty);
                const initial_size = tbl.limits.initial;
                try self.tables_lists.items[tbl_idx].resize(self.allocator, initial_size);
                @memset(self.tables_lists.items[tbl_idx].items, std.math.maxInt(u32));
            },
            .element_segment => |seg| {
                self.pending_element_mode = seg.mode;
                self.pending_element_table_index = seg.table_index;
            },
            .element_segment_body => |body| {
                const func_indices_copy = try self.allocator.dupe(u32, body.func_indices);
                errdefer self.allocator.free(func_indices_copy);

                const offset: u32 = if (self.pending_element_mode == .active)
                    (try Module.evaluate_const_expr(self.parserAllocator(), body.offset_expr, .I32)).readAs(u32)
                else
                    0;

                try self.elem_segments_list.append(self.allocator, .{
                    .mode = self.pending_element_mode,
                    .table_index = self.pending_element_table_index orelse 0,
                    .offset = offset,
                    .func_indices = func_indices_copy,
                });

                if (self.pending_element_mode == .active) {
                    const tbl_idx = self.pending_element_table_index orelse 0;
                    while (self.tables_lists.items.len <= tbl_idx) {
                        try self.tables_lists.append(self.allocator, .empty);
                    }
                    const tbl = &self.tables_lists.items[tbl_idx];
                    const required_len = offset + body.func_indices.len;
                    if (tbl.items.len < required_len) {
                        const old_len = tbl.items.len;
                        try tbl.resize(self.allocator, required_len);
                        @memset(tbl.items[old_len..], std.math.maxInt(u32));
                    }
                    for (body.func_indices, 0..) |fi, i| {
                        tbl.items[offset + i] = fi;
                    }
                }
            },
            .data_segment => |seg| {
                self.pending_data_mode = seg.mode;
                self.pending_data_memory_index = seg.memory_index;
            },
            .data_segment_body => |body| {
                const data_copy = try self.allocator.dupe(u8, body.data);
                const compiled = CompiledDataSegment{
                    .mode = self.pending_data_mode,
                    .memory_index = self.pending_data_memory_index orelse 0,
                    .offset = if (self.pending_data_mode == .active)
                        (try Module.evaluate_const_expr(self.parserAllocator(), body.offset_expr, .I32)).readAs(u32)
                    else
                        0,
                    .data = data_copy,
                };
                try self.data_segments_list.append(self.allocator, compiled);
            },
            .tag_type => |tt| {
                try self.tags_list.append(self.allocator, .{ .type_index = tt.type_index });
            },
            .function_info => |info| {
                try self.handleFunctionInfo(info);
            },
            else => {},
        }
    }

    fn handleFunctionInfo(self: *BuildState, info: payload_mod.FunctionInformation) ModuleCompileError!void {
        const local_func_idx = self.local_functions_list.items.len;
        if (local_func_idx >= self.function_type_indices.items.len) {
            return error.MismatchedFunctionCount;
        }

        const type_index = self.function_type_indices.items[local_func_idx];
        if (type_index >= self.composite_types_list.items.len) {
            return error.InvalidFunctionTypeIndex;
        }
        const func_type = switch (self.composite_types_list.items[type_index]) {
            .func_type => |ft| ft,
            else => return error.InvalidFunctionTypeIndex,
        };

        if (self.tags_list.items.len > 0 and self.detected_eh_mode != .legacy and !self.engine.config().legacy_exceptions) {
            var fbp = parser_mod.FunctionBodyParser.init(self.parserAllocator(), info.body);
            while (!fbp.done()) {
                const op_info = fbp.next() catch break;
                switch (op_info.code) {
                    .delegate, .try_, .rethrow => {
                        self.detected_eh_mode = .legacy;
                        break;
                    },
                    .try_table, .throw_ref, .throw => {
                        if (self.detected_eh_mode == .none) {
                            self.detected_eh_mode = .new;
                        }
                    },
                    else => {},
                }
            }
        }

        const reserved_slots = try Module.compute_reserved_slots(func_type, info);
        var params_slots: usize = 0;
        for (func_type.params()) |p| params_slots += if (p == .V128) 2 else 1;
        const locals_count: u16 = @intCast(reserved_slots - params_slots);
        // If body_arena is set (compileReader path), dupe the body into the
        // arena so it outlives the parser's transient buffer.  Otherwise
        // (compile(bytes) path) borrow the slice directly from the caller's
        // long-lived input.
        const body: []const u8 = if (self.body_arena) |*ba|
            try ba.allocator().dupe(u8, info.body)
        else
            info.body;

        try self.local_functions_list.append(self.allocator, .{ .pending = .{
            .body = body,
            .type_index = type_index,
            .reserved_slots = reserved_slots,
            .locals_count = locals_count,
        } });
    }

    fn finish(self: *BuildState) ModuleCompileError!Module {
        if (self.engine.config().legacy_exceptions) {
            self.detected_eh_mode = .legacy;
        }

        if (self.local_functions_list.items.len != self.function_type_indices.items.len) {
            return error.MismatchedFunctionCount;
        }

        const globals = try self.globals_list.toOwnedSlice(self.allocator);
        errdefer {
            for (globals) |g| {
                if (g.init_expr) |expr| self.allocator.free(expr);
            }
            self.allocator.free(globals);
        }

        const imported_funcs = try self.imported_funcs_list.toOwnedSlice(self.allocator);
        errdefer {
            for (imported_funcs) |def| {
                self.allocator.free(def.module_name);
                self.allocator.free(def.func_name);
            }
            self.allocator.free(imported_funcs);
        }
        const imported_globals = try self.imported_globals_list.toOwnedSlice(self.allocator);
        errdefer {
            for (imported_globals) |def| {
                self.allocator.free(def.module_name);
                self.allocator.free(def.global_name);
            }
            self.allocator.free(imported_globals);
        }

        const tables = try self.allocator.alloc([]u32, self.tables_lists.items.len);
        errdefer {
            for (tables) |t| self.allocator.free(t);
            self.allocator.free(tables);
        }
        for (self.tables_lists.items, 0..) |*tl, i| {
            tables[i] = try tl.toOwnedSlice(self.allocator);
        }
        self.tables_lists.deinit(self.allocator);
        self.tables_lists = .empty;

        const data_segments = try self.data_segments_list.toOwnedSlice(self.allocator);
        errdefer {
            for (data_segments) |*seg| self.allocator.free(seg.data);
            self.allocator.free(data_segments);
        }

        const elem_segments = try self.elem_segments_list.toOwnedSlice(self.allocator);
        errdefer {
            for (elem_segments) |*seg| self.allocator.free(seg.func_indices);
            self.allocator.free(elem_segments);
        }

        const local_functions = try self.local_functions_list.toOwnedSlice(self.allocator);
        errdefer {
            deinit_function_slots(self.allocator, local_functions);
            self.allocator.free(local_functions);
        }

        const imported_function_count = imported_funcs.len;
        const function_count = imported_function_count + local_functions.len;
        const functions = try self.allocator.alloc(FunctionSlot, function_count);
        errdefer {
            deinit_function_slots(self.allocator, functions);
            self.allocator.free(functions);
        }
        for (functions[0..imported_function_count]) |*f| {
            f.* = .import;
        }
        for (local_functions, 0..) |slot, i| {
            functions[imported_function_count + i] = slot;
        }
        self.allocator.free(local_functions);

        const func_type_indices = try self.allocator.alloc(u32, function_count);
        errdefer self.allocator.free(func_type_indices);
        for (imported_funcs, 0..) |def, i| {
            func_type_indices[i] = def.type_index;
        }
        for (self.function_type_indices.items, 0..) |ti, i| {
            func_type_indices[imported_function_count + i] = ti;
        }

        const composite_types = try self.composite_types_list.toOwnedSlice(self.allocator);
        errdefer {
            for (composite_types) |*ct| ct.deinit(self.allocator);
            self.allocator.free(composite_types);
        }
        const struct_layouts = try self.struct_layouts_list.toOwnedSlice(self.allocator);
        errdefer {
            for (struct_layouts) |*sl| {
                if (sl.*) |layout| layout.deinit(self.allocator);
            }
            self.allocator.free(struct_layouts);
        }
        const array_layouts = try self.array_layouts_list.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(array_layouts);
        const tags = try self.tags_list.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(tags);

        const n_composite = self.direct_parents_list.items.len;
        const type_ancestors_outer = try self.allocator.alloc([]const u32, n_composite);
        errdefer {
            for (type_ancestors_outer) |anc_slice| self.allocator.free(anc_slice);
            self.allocator.free(type_ancestors_outer);
        }
        for (0..n_composite) |i| {
            const direct_parent = self.direct_parents_list.items[i];
            if (direct_parent) |p| {
                const parent_ancestors = type_ancestors_outer[p];
                const anc_slice = try self.allocator.alloc(u32, 1 + parent_ancestors.len);
                anc_slice[0] = p;
                @memcpy(anc_slice[1..], parent_ancestors);
                type_ancestors_outer[i] = anc_slice;
            } else {
                type_ancestors_outer[i] = &.{};
            }
        }

        const exports = self.exports;
        self.exports = .empty;

        // Transfer body_arena ownership to Module before returning.
        const body_arena = self.body_arena;
        self.body_arena = null;

        return .{
            .allocator = self.allocator,
            .functions = functions,
            .exports = exports,
            .globals = globals,
            .memory = self.memory,
            .start_function = self.start_function,
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
            .config = .{ .eh_mode = self.detected_eh_mode },
            .translator = null,
            .pending_count = @intCast(local_functions.len),
            .body_arena = body_arena,
        };
    }
};

fn deinit_function_slots(allocator: Allocator, functions: []FunctionSlot) void {
    for (functions) |*slot| {
        switch (slot.*) {
            .encoded => |*ef| ef.deinit(allocator),
            // Pending body bytes are either borrowed (compile(bytes) path)
            // or owned by the Module's body_arena (compileReader path).
            // Either way they are NOT freed individually here.
            .pending, .import => {},
        }
        slot.* = undefined;
    }
}

/// Compiled WebAssembly module, holding all data required for runtime execution.
///
/// Field descriptions:
///   - functions:        List of function slots indexed by Wasm function index space (imports first).
///                       Each slot is `.import` for host imports, `.pending` for uncompiled locals,
///                       or `.encoded` for compiled locals.  Slots are compiled on first call (lazy).
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
    /// Number of function slots still in the `.pending` state.
    /// Decremented by `compileFunctionAt`; used to release `translator` as
    /// soon as the last function body is compiled (O(1) check per compile).
    pending_count: u32,
    /// Arena owning all pending function body copies (compileReader path).
    /// null when bodies borrow external bytes (compile(bytes) / mmap path).
    /// Freed in deinit; individual body slices are never freed separately.
    body_arena: ?std.heap.ArenaAllocator = null,

    /// Compile WebAssembly bytecode held in memory into a Module.
    ///
    /// Pending function bodies are **borrowed references** into `bytes`.
    /// The caller MUST keep `bytes` alive for the entire lifetime of the
    /// returned Module (typically via mmap or a long-lived allocation).
    pub fn compile(engine: Engine, bytes: []const u8) ModuleCompileError!Module {
        var state = BuildState.init(engine);
        // body_arena stays null → bodies borrow from `bytes` directly.
        defer state.deinit();

        var parser = Parser.init(state.parserAllocator());
        var remaining_bytes = bytes;

        while (true) {
            switch (parser.parse(remaining_bytes, true)) {
                .parsed => |parsed| {
                    if (parsed.consumed == 0) return error.UnexpectedNeedMoreData;
                    remaining_bytes = remaining_bytes[parsed.consumed..];
                    try state.handlePayload(parsed.payload);
                },
                .need_more_data => return error.UnexpectedNeedMoreData,
                .end => break,
                .err => |err| return err,
            }
        }

        var module = try state.finish();
        if (engine.config().eager_compile) {
            try module.compileAll(engine);
        }
        return module;
    }

    /// Compile WebAssembly bytecode from a streaming reader into a Module.
    ///
    /// The reader is consumed incrementally.  Function body bytes are copied
    /// into a Module-owned arena so they outlive the parser's transient
    /// buffers.  The arena is freed as a whole on Module.deinit().
    pub fn compileReader(engine: Engine, reader: anytype) ModuleCompileReaderError!Module {
        const allocator = engine.allocator();

        var state = BuildState.init(engine);
        // Streaming path: parser buffers are transient, so we need an arena
        // to hold durable copies of each function body.
        state.body_arena = std.heap.ArenaAllocator.init(allocator);
        defer state.deinit();

        var parser = Parser.init(state.parserAllocator());
        var pending: std.ArrayListUnmanaged(u8) = .empty;
        defer pending.deinit(allocator);

        var pending_start: usize = 0;
        var eof = false;
        var read_buf: [64 * 1024]u8 = undefined;

        while (true) {
            while (true) {
                const input = pending.items[pending_start..];
                switch (parser.parse(input, eof)) {
                    .parsed => |parsed| {
                        if (parsed.consumed == 0) return error.UnexpectedNeedMoreData;
                        pending_start += parsed.consumed;
                        try state.handlePayload(parsed.payload);
                    },
                    .need_more_data => break,
                    .end => {
                        var module = try state.finish();
                        if (engine.config().eager_compile) {
                            try module.compileAll(engine);
                        }
                        return module;
                    },
                    .err => |err| return err,
                }
            }

            if (eof) return error.UnexpectedNeedMoreData;

            if (pending_start > 0) {
                const remaining = pending.items.len - pending_start;
                std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[pending_start..]);
                pending.items.len = remaining;
                pending_start = 0;
            }

            const n = try readSliceShortCompat(reader, &read_buf);
            eof = n == 0;
            try pending.appendSlice(allocator, read_buf[0..n]);
        }
    }

    /// Compile and wrap the module in an `ArcModule`.
    ///
    /// Pending function bodies borrow slices from `bytes`.  The caller MUST
    /// keep `bytes` alive for the lifetime of the returned ArcModule.
    pub fn compileArc(engine: Engine, bytes: []const u8) (ModuleCompileError || std.mem.Allocator.Error)!ArcModule {
        var m = try compile(engine, bytes);
        errdefer m.deinit();
        return ArcModule.init(engine.allocator(), m);
    }

    /// Compile a module from a streaming reader and wrap it in an `ArcModule`.
    pub fn compileArcReader(engine: Engine, reader: anytype) (ModuleCompileReaderError || std.mem.Allocator.Error)!ArcModule {
        var m = try compileReader(engine, reader);
        errdefer m.deinit();
        return ArcModule.init(engine.allocator(), m);
    }

    fn readSliceShortCompat(reader: anytype, buffer: []u8) ModuleCompileReaderError!usize {
        return switch (@typeInfo(@TypeOf(reader))) {
            .pointer => |ptr| blk: {
                const Child = ptr.child;
                if (@hasDecl(Child, "readSliceShort")) {
                    break :blk try reader.readSliceShort(buffer);
                }
                if (@hasDecl(Child, "read")) {
                    break :blk try reader.read(buffer);
                }
                if (@hasField(Child, "interface")) {
                    break :blk try reader.interface.readSliceShort(buffer);
                }
                @compileError("compileReader requires a reader with readSliceShort() or read()");
            },
            else => blk: {
                const ReaderType = @TypeOf(reader);
                if (@hasDecl(ReaderType, "readSliceShort")) {
                    break :blk try reader.readSliceShort(buffer);
                }
                if (@hasDecl(ReaderType, "read")) {
                    break :blk try reader.read(buffer);
                }
                if (@hasField(ReaderType, "interface")) {
                    var value = reader;
                    break :blk try value.interface.readSliceShort(buffer);
                }
                @compileError("compileReader requires a reader with readSliceShort() or read()");
            },
        };
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
        // Body bytes are either borrowed (compile(bytes) path) or owned by
        // body_arena (compileReader path).  No individual free needed.
        slot.* = .{ .encoded = encoded };

        // Decrement the pending counter and release the reusable translator
        // buffers as soon as the last pending slot is compiled.  This frees
        // the compilation high-water-mark memory (Lower's ArrayLists + scratch
        // ArenaAllocator) without scanning the whole functions slice.
        self.pending_count -= 1;
        if (self.pending_count == 0) self.releaseTranslator();
    }

    /// Free the reusable compilation buffers (`FuncTranslatorAllocations`).
    ///
    /// Called automatically by `compileFunctionAt` when the last pending slot
    /// is compiled, and by `compileAll` after all functions are compiled.
    /// May also be called manually after a batch of lazy compilations to
    /// reclaim the compilation high-water-mark memory early.
    pub fn releaseTranslator(self: *Module) void {
        if (self.translator) |*t| {
            t.deinit();
            self.translator = null;
        }
    }

    /// Eagerly compile all pending local functions.
    ///
    /// This avoids lazy-compilation overhead at first call by compiling
    /// every `.pending` function slot up front. Imports (`.import`) and
    /// already-compiled (`.encoded`) slots are skipped.
    /// After all functions are compiled the reusable translator buffers are
    /// freed unconditionally (equivalent to calling `releaseTranslator()`).
    pub fn compileAll(self: *Module, engine: Engine) ModuleCompileError!void {
        for (self.functions, 0..) |*slot, i| {
            switch (slot.*) {
                .pending => try self.compileFunctionAt(engine, @intCast(i)),
                .encoded, .import => {},
            }
        }
        // All slots are now encoded; release compilation buffers eagerly
        // rather than waiting for the per-slot auto-release inside
        // compileFunctionAt (which would scan the whole functions slice on
        // every call).
        self.releaseTranslator();
    }

    /// Detailed memory breakdown for a compiled Module.
    /// All byte counts are best-effort totals based on owned slice lengths.
    pub const MemStats = struct {
        /// Total bytes held in `.pending` function body copies (raw Wasm bytecode).
        pending_body_bytes: usize,
        /// Total bytes of `.encoded` function code streams (threaded-dispatch bytecode).
        encoded_code_bytes: usize,
        /// Total bytes of auxiliary encoded-function tables
        /// (eh_dst_slots + br_table_targets + catch_handler_tables).
        encoded_aux_bytes: usize,
        /// Number of local functions still in the `.pending` (uncompiled) state.
        pending_count: u32,
        /// Number of local functions already in the `.encoded` (compiled) state.
        encoded_count: u32,
        /// Total bytes remaining in data segment copies
        /// (active segments are freed after instantiation via releaseActiveSegmentData;
        ///  passive segments are freed only on Module.deinit).
        data_segment_bytes: usize,

        /// Grand total of all module-owned bytes tracked above.
        pub fn total(self: MemStats) usize {
            return self.pending_body_bytes +
                self.encoded_code_bytes +
                self.encoded_aux_bytes +
                self.data_segment_bytes;
        }
    };

    /// Compute a detailed memory breakdown for this module.
    ///
    /// Iterates `functions` once to sum pending body bytes and encoded code /
    /// auxiliary table bytes, and sums data segment bytes.  O(N) in the number
    /// of function slots.
    pub fn memStats(self: *const Module) MemStats {
        var pending_body_bytes: usize = 0;
        var encoded_code_bytes: usize = 0;
        var encoded_aux_bytes: usize = 0;
        var pending_cnt: u32 = 0;
        var encoded_cnt: u32 = 0;

        for (self.functions) |*slot| {
            switch (slot.*) {
                .pending => |p| {
                    pending_body_bytes += p.body.len;
                    pending_cnt += 1;
                },
                .encoded => |ef| {
                    encoded_code_bytes += ef.code.len;
                    encoded_aux_bytes += ef.eh_dst_slots.len * @sizeOf(ir.Slot);
                    encoded_aux_bytes += ef.br_table_targets.len * @sizeOf(u32);
                    encoded_aux_bytes += ef.catch_handler_tables.len * @sizeOf(ir.CatchHandlerEntry);
                    encoded_cnt += 1;
                },
                .import => {},
            }
        }

        var data_segment_bytes: usize = 0;
        for (self.data_segments) |seg| {
            data_segment_bytes += seg.data.len;
        }

        return .{
            .pending_body_bytes = pending_body_bytes,
            .encoded_code_bytes = encoded_code_bytes,
            .encoded_aux_bytes = encoded_aux_bytes,
            .pending_count = pending_cnt,
            .encoded_count = encoded_cnt,
            .data_segment_bytes = data_segment_bytes,
        };
    }

    pub fn deinit(self: *Module) void {
        if (self.translator) |*t| t.deinit();
        deinit_function_slots(self.allocator, self.functions);
        self.allocator.free(self.functions);
        // Free the arena that holds all pending body copies (compileReader path).
        // For the compile(bytes)/mmap path this is null (bodies are borrowed).
        if (self.body_arena) |*ba| ba.deinit();

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
            // Active segment data may have already been freed by
            // releaseActiveSegmentData() after instantiation; skip those.
            if (seg.data.len > 0) self.allocator.free(seg.data);
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

    /// Release the heap copies of all *active* data segments.
    ///
    /// Active segments are copied into linear memory during instantiation and
    /// are implicitly dropped afterwards (the WASM spec marks them as dropped so
    /// that `memory.init` traps on them).  Their in-module copies therefore
    /// serve no purpose once every instance that shares this Module has been
    /// initialised, and holding them wastes significant memory for data-heavy
    /// modules (e.g. ~5.5 MB for esbuild).
    ///
    /// Calling convention
    /// ------------------
    /// Call this method after every `Instance.init` / `Instance.initWithSharedMemory`
    /// that may need the active data has returned successfully.  It is safe to
    /// call multiple times: segments whose `data` slice has already been freed
    /// (len == 0) are skipped.
    ///
    /// Thread safety
    /// -------------
    /// This method is NOT thread-safe.  Do not call it concurrently with another
    /// `Instance.init` on the same Module.
    pub fn releaseActiveSegmentData(self: *Module) void {
        for (self.data_segments) |*seg| {
            if (seg.mode != .active) continue;
            if (seg.data.len == 0) continue; // already freed
            self.allocator.free(seg.data);
            seg.data = &.{};
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
    ///
    /// V128 (SIMD) values occupy two consecutive slots; all other types occupy one slot.
    fn compute_reserved_slots(func_type: FuncType, function_info: payload_mod.FunctionInformation) ModuleCompileError!u32 {
        var params_slots: usize = 0;
        for (func_type.params()) |param| {
            params_slots += if (param == .V128) 2 else 1;
        }
        var locals_slots: usize = 0;
        for (function_info.locals) |local_group| {
            const is_v128 = (local_group.typ == .kind and local_group.typ.kind == .v128);
            locals_slots += local_group.count * (if (is_v128) @as(usize, 2) else @as(usize, 1));
        }
        const total = params_slots + locals_slots;
        return std.math.cast(u32, total) orelse error.InvalidLocalCount;
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
    pub fn getFuncType(self: FuncTypeResolver, type_idx: u32) ModuleCompileError!*const FuncType {
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
    const p = fbp.getParser();
    while (!fbp.done()) {
        const before_decode = timer.read();
        const code = try decodeAndLower(p, lower, resolver, tags, scratch);
        profiling.compile_prof.ns_read_operator += timer.read() - before_decode;
        profiling.compile_prof.opcodes_processed += 1;

        if (simd.isSimdOpcode(code)) {
            if (!config.simd) return error.DisabledSimd;
            if (simd.isRelaxedSimdOpcode(code) and !config.relaxed_simd) {
                return error.DisabledRelaxedSimd;
            }
        }
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

// ── Decode-to-lower: fused opcode decode + lowering in one pass ──────────────
//
// Instead of: parser.readSingleOperator() → OperatorInformation → lowerOpFromInfo()
// We do:      read opcode byte → inline decode operands → call lower methods directly.
//
// This eliminates:
//   1. The OperatorInformation intermediate struct construction
//   2. The second opcode dispatch in lowerOpFromInfo
//   3. Temporary allocations for operands that are immediately consumed
//
// For prefix opcodes (0xfb/0xfc/0xfd/0xfe) and the legacy EH opcodes,
// we fall back to the old path since they're less common and more complex.

/// Fused decode+lower: reads one opcode from `p`, decodes operands inline,
/// and calls lower methods directly.  Returns the OperatorCode for SIMD
/// gating by the caller.
fn decodeAndLower(
    p: *parser_mod.Parser,
    lower: *Lower,
    resolver: FuncTypeResolver,
    tags: []const TagDef,
    scratch: Allocator,
) ModuleCompileError!payload_mod.OperatorCode {
    const start_pos = p.cur_pos;

    if (!p.has_bytes(1)) return error.NeedMoreData;
    const code_raw = p.read_u8();
    const code = std.meta.intToEnum(payload_mod.OperatorCode, code_raw) catch {
        return error.UnknownOperator;
    };

    // ── Prefix opcodes: fall back to full readSingleOperator + lowerOpFromInfo ──
    switch (code) {
        .prefix_0xfb, .prefix_0xfc, .prefix_0xfd, .prefix_0xfe => {
            // Reset cursor to before the opcode byte so readSingleOperator can
            // re-read it from scratch.
            p.cur_pos = start_pos;
            const op_info = try p.readSingleOperator();
            if (!try lower.lowerOpFromInfo(op_info)) {
                const wasm_op = try buildWasmOp(op_info, resolver, tags, scratch);
                lower.lowerOp(wasm_op) catch |err| return err;
            }
            return op_info.code;
        },
        else => {},
    }

    // ── Dead-code elimination ────────────────────────────────────────────────
    var was_unreachable = false;
    if (lower.is_unreachable) {
        switch (code) {
            .block, .loop, .if_, .try_table => {
                // Still need to consume operands from the byte stream.
                _ = try p.read_type_checked();
                if (code == .try_table) {
                    _ = try p.read_try_table();
                }
                lower.unreachable_depth += 1;
                return code;
            },
            .end => {
                if (lower.unreachable_depth > 0) {
                    lower.unreachable_depth -= 1;
                    return code;
                }
                lower.is_unreachable = false;
                was_unreachable = true;
                if (lower.control_stack.items.len > 0) {
                    const frame = &lower.control_stack.items[lower.control_stack.items.len - 1];
                    lower.stack.slots.shrinkRetainingCapacity(frame.stack_height);
                }
                // Fall through to normal end handling.
            },
            .else_ => {
                if (lower.unreachable_depth > 0) {
                    return code;
                }
                lower.is_unreachable = false;
                // Fall through to normal else handling.
            },
            else => {
                // Skip all other ops in unreachable code, but must consume operands.
                consumeOperands(p, code) catch {
                    p.cur_pos = start_pos;
                    return error.NeedMoreData;
                };
                return code;
            },
        }
    }

    // ── Main dispatch: decode operands inline + lower directly ────────────────
    switch (code) {
        // ── No-operand simple ops ────────────────────────────────────────────
        .unreachable_ => {
            try lower.emit(.unreachable_);
            lower.is_unreachable = true;
        },
        .nop => {},
        .drop => {
            _ = try lower.pop_slot();
        },

        // ── Structured control flow ──────────────────────────────────────────
        .block => {
            const block_type = try translate_mod.wasmBlockTypeFromType(try p.read_type_checked());
            try lower.lowerOp(.{ .block = block_type });
        },
        .loop => {
            const block_type = try translate_mod.wasmBlockTypeFromType(try p.read_type_checked());
            try lower.lowerOp(.{ .loop = block_type });
        },
        .if_ => {
            const block_type = try translate_mod.wasmBlockTypeFromType(try p.read_type_checked());
            try lower.lowerOp(.{ .if_ = block_type });
        },
        .else_ => try lower.lowerOp(.else_),
        .end => try lower.lowerOpEnd(was_unreachable),
        .br => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const depth = p.read_var_uint32();
            try lower.lowerOp(.{ .br = depth });
        },
        .br_if => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const depth = p.read_var_uint32();
            try lower.lowerOp(.{ .br_if = depth });
        },
        .br_table => {
            const targets = try p.read_br_table();
            try lower.lowerOp(.{ .br_table = .{ .targets = targets } });
        },

        // ── Locals & globals ─────────────────────────────────────────────────
        .local_get => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const local = p.read_var_uint32();
            try lower.stack.push(lower.allocator, lower.local_to_slot(local));
        },
        .local_set => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const local = p.read_var_uint32();
            const src = try lower.pop_slot();
            try lower.emit(.{ .local_set = .{ .local = local, .src = src } });
        },
        .local_tee => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const local = p.read_var_uint32();
            const src = lower.stack.peek() orelse return error.StackUnderflow;
            try lower.emit(.{ .local_set = .{ .local = local, .src = src } });
        },
        .global_get => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const global_idx = p.read_var_uint32();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .global_get = .{ .dst = dst, .global_idx = global_idx } });
            try lower.stack.push(lower.allocator, dst);
        },
        .global_set => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const global_idx = p.read_var_uint32();
            const src = try lower.pop_slot();
            try lower.emit(.{ .global_set = .{ .src = src, .global_idx = global_idx } });
        },

        // ── Constants ────────────────────────────────────────────────────────
        .i32_const => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const value = p.read_var_int32();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .const_i32 = .{ .dst = dst, .value = value } });
            try lower.stack.push(lower.allocator, dst);
        },
        .i64_const => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const value = p.read_var_int64();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .const_i64 = .{ .dst = dst, .value = value } });
            try lower.stack.push(lower.allocator, dst);
        },
        .f32_const => {
            if (!p.has_bytes(4)) return error.NeedMoreData;
            const bytes = p.read_bytes(4);
            const bits = std.mem.readInt(u32, bytes[0..4], .little);
            const value: f32 = @bitCast(bits);
            const dst = lower.alloc_slot();
            try lower.emit(.{ .const_f32 = .{ .dst = dst, .value = value } });
            try lower.stack.push(lower.allocator, dst);
        },
        .f64_const => {
            if (!p.has_bytes(8)) return error.NeedMoreData;
            const bytes = p.read_bytes(8);
            const bits = std.mem.readInt(u64, bytes[0..8], .little);
            const value: f64 = @bitCast(bits);
            const dst = lower.alloc_slot();
            try lower.emit(.{ .const_f64 = .{ .dst = dst, .value = value } });
            try lower.stack.push(lower.allocator, dst);
        },

        // ── i32 binary ───────────────────────────────────────────────────────
        .i32_add => try lower.lower_binary_op("i32_add"),
        .i32_sub => try lower.lower_binary_op("i32_sub"),
        .i32_mul => try lower.lower_binary_op("i32_mul"),
        .i32_div_s => try lower.lower_binary_op("i32_div_s"),
        .i32_div_u => try lower.lower_binary_op("i32_div_u"),
        .i32_rem_s => try lower.lower_binary_op("i32_rem_s"),
        .i32_rem_u => try lower.lower_binary_op("i32_rem_u"),
        .i32_and => try lower.lower_binary_op("i32_and"),
        .i32_or => try lower.lower_binary_op("i32_or"),
        .i32_xor => try lower.lower_binary_op("i32_xor"),
        .i32_shl => try lower.lower_binary_op("i32_shl"),
        .i32_shr_s => try lower.lower_binary_op("i32_shr_s"),
        .i32_shr_u => try lower.lower_binary_op("i32_shr_u"),
        .i32_rotl => try lower.lower_binary_op("i32_rotl"),
        .i32_rotr => try lower.lower_binary_op("i32_rotr"),

        // ── i64 binary ───────────────────────────────────────────────────────
        .i64_add => try lower.lower_binary_op("i64_add"),
        .i64_sub => try lower.lower_binary_op("i64_sub"),
        .i64_mul => try lower.lower_binary_op("i64_mul"),
        .i64_div_s => try lower.lower_binary_op("i64_div_s"),
        .i64_div_u => try lower.lower_binary_op("i64_div_u"),
        .i64_rem_s => try lower.lower_binary_op("i64_rem_s"),
        .i64_rem_u => try lower.lower_binary_op("i64_rem_u"),
        .i64_and => try lower.lower_binary_op("i64_and"),
        .i64_or => try lower.lower_binary_op("i64_or"),
        .i64_xor => try lower.lower_binary_op("i64_xor"),
        .i64_shl => try lower.lower_binary_op("i64_shl"),
        .i64_shr_s => try lower.lower_binary_op("i64_shr_s"),
        .i64_shr_u => try lower.lower_binary_op("i64_shr_u"),
        .i64_rotl => try lower.lower_binary_op("i64_rotl"),
        .i64_rotr => try lower.lower_binary_op("i64_rotr"),

        // ── f32 binary ───────────────────────────────────────────────────────
        .f32_add => try lower.lower_binary_op("f32_add"),
        .f32_sub => try lower.lower_binary_op("f32_sub"),
        .f32_mul => try lower.lower_binary_op("f32_mul"),
        .f32_div => try lower.lower_binary_op("f32_div"),
        .f32_min => try lower.lower_binary_op("f32_min"),
        .f32_max => try lower.lower_binary_op("f32_max"),
        .f32_copysign => try lower.lower_binary_op("f32_copysign"),

        // ── f64 binary ───────────────────────────────────────────────────────
        .f64_add => try lower.lower_binary_op("f64_add"),
        .f64_sub => try lower.lower_binary_op("f64_sub"),
        .f64_mul => try lower.lower_binary_op("f64_mul"),
        .f64_div => try lower.lower_binary_op("f64_div"),
        .f64_min => try lower.lower_binary_op("f64_min"),
        .f64_max => try lower.lower_binary_op("f64_max"),
        .f64_copysign => try lower.lower_binary_op("f64_copysign"),

        // ── i32 unary ────────────────────────────────────────────────────────
        .i32_clz => try lower.lower_unary_op("i32_clz"),
        .i32_ctz => try lower.lower_unary_op("i32_ctz"),
        .i32_popcnt => try lower.lower_unary_op("i32_popcnt"),

        // ── i64 unary ────────────────────────────────────────────────────────
        .i64_clz => try lower.lower_unary_op("i64_clz"),
        .i64_ctz => try lower.lower_unary_op("i64_ctz"),
        .i64_popcnt => try lower.lower_unary_op("i64_popcnt"),

        // ── f32 unary ────────────────────────────────────────────────────────
        .f32_abs => try lower.lower_unary_op("f32_abs"),
        .f32_neg => try lower.lower_unary_op("f32_neg"),
        .f32_ceil => try lower.lower_unary_op("f32_ceil"),
        .f32_floor => try lower.lower_unary_op("f32_floor"),
        .f32_trunc => try lower.lower_unary_op("f32_trunc"),
        .f32_nearest => try lower.lower_unary_op("f32_nearest"),
        .f32_sqrt => try lower.lower_unary_op("f32_sqrt"),

        // ── f64 unary ────────────────────────────────────────────────────────
        .f64_abs => try lower.lower_unary_op("f64_abs"),
        .f64_neg => try lower.lower_unary_op("f64_neg"),
        .f64_ceil => try lower.lower_unary_op("f64_ceil"),
        .f64_floor => try lower.lower_unary_op("f64_floor"),
        .f64_trunc => try lower.lower_unary_op("f64_trunc"),
        .f64_nearest => try lower.lower_unary_op("f64_nearest"),
        .f64_sqrt => try lower.lower_unary_op("f64_sqrt"),

        // ── i32 comparisons ──────────────────────────────────────────────────
        .i32_eqz => try lower.lower_unary_op("i32_eqz"),
        .i32_eq => try lower.lower_compare_op("i32_eq"),
        .i32_ne => try lower.lower_compare_op("i32_ne"),
        .i32_lt_s => try lower.lower_compare_op("i32_lt_s"),
        .i32_lt_u => try lower.lower_compare_op("i32_lt_u"),
        .i32_gt_s => try lower.lower_compare_op("i32_gt_s"),
        .i32_gt_u => try lower.lower_compare_op("i32_gt_u"),
        .i32_le_s => try lower.lower_compare_op("i32_le_s"),
        .i32_le_u => try lower.lower_compare_op("i32_le_u"),
        .i32_ge_s => try lower.lower_compare_op("i32_ge_s"),
        .i32_ge_u => try lower.lower_compare_op("i32_ge_u"),

        // ── i64 comparisons ──────────────────────────────────────────────────
        .i64_eqz => try lower.lower_unary_op("i64_eqz"),
        .i64_eq => try lower.lower_compare_op("i64_eq"),
        .i64_ne => try lower.lower_compare_op("i64_ne"),
        .i64_lt_s => try lower.lower_compare_op("i64_lt_s"),
        .i64_lt_u => try lower.lower_compare_op("i64_lt_u"),
        .i64_gt_s => try lower.lower_compare_op("i64_gt_s"),
        .i64_gt_u => try lower.lower_compare_op("i64_gt_u"),
        .i64_le_s => try lower.lower_compare_op("i64_le_s"),
        .i64_le_u => try lower.lower_compare_op("i64_le_u"),
        .i64_ge_s => try lower.lower_compare_op("i64_ge_s"),
        .i64_ge_u => try lower.lower_compare_op("i64_ge_u"),

        // ── f32 comparisons ──────────────────────────────────────────────────
        .f32_eq => try lower.lower_compare_op("f32_eq"),
        .f32_ne => try lower.lower_compare_op("f32_ne"),
        .f32_lt => try lower.lower_compare_op("f32_lt"),
        .f32_gt => try lower.lower_compare_op("f32_gt"),
        .f32_le => try lower.lower_compare_op("f32_le"),
        .f32_ge => try lower.lower_compare_op("f32_ge"),

        // ── f64 comparisons ──────────────────────────────────────────────────
        .f64_eq => try lower.lower_compare_op("f64_eq"),
        .f64_ne => try lower.lower_compare_op("f64_ne"),
        .f64_lt => try lower.lower_compare_op("f64_lt"),
        .f64_gt => try lower.lower_compare_op("f64_gt"),
        .f64_le => try lower.lower_compare_op("f64_le"),
        .f64_ge => try lower.lower_compare_op("f64_ge"),

        // ── Conversions & sign-extension ─────────────────────────────────────
        .i32_wrap_i64 => try lower.lower_convert_op("i32_wrap_i64"),
        .i32_trunc_f32_s => try lower.lower_convert_op("i32_trunc_f32_s"),
        .i32_trunc_f32_u => try lower.lower_convert_op("i32_trunc_f32_u"),
        .i32_trunc_f64_s => try lower.lower_convert_op("i32_trunc_f64_s"),
        .i32_trunc_f64_u => try lower.lower_convert_op("i32_trunc_f64_u"),
        .i64_extend_i32_s => try lower.lower_convert_op("i64_extend_i32_s"),
        .i64_extend_i32_u => try lower.lower_convert_op("i64_extend_i32_u"),
        .i64_trunc_f32_s => try lower.lower_convert_op("i64_trunc_f32_s"),
        .i64_trunc_f32_u => try lower.lower_convert_op("i64_trunc_f32_u"),
        .i64_trunc_f64_s => try lower.lower_convert_op("i64_trunc_f64_s"),
        .i64_trunc_f64_u => try lower.lower_convert_op("i64_trunc_f64_u"),
        .f32_convert_i32_s => try lower.lower_convert_op("f32_convert_i32_s"),
        .f32_convert_i32_u => try lower.lower_convert_op("f32_convert_i32_u"),
        .f32_convert_i64_s => try lower.lower_convert_op("f32_convert_i64_s"),
        .f32_convert_i64_u => try lower.lower_convert_op("f32_convert_i64_u"),
        .f32_demote_f64 => try lower.lower_convert_op("f32_demote_f64"),
        .f64_convert_i32_s => try lower.lower_convert_op("f64_convert_i32_s"),
        .f64_convert_i32_u => try lower.lower_convert_op("f64_convert_i32_u"),
        .f64_convert_i64_s => try lower.lower_convert_op("f64_convert_i64_s"),
        .f64_convert_i64_u => try lower.lower_convert_op("f64_convert_i64_u"),
        .f64_promote_f32 => try lower.lower_convert_op("f64_promote_f32"),
        .i32_reinterpret_f32 => try lower.lower_convert_op("i32_reinterpret_f32"),
        .i64_reinterpret_f64 => try lower.lower_convert_op("i64_reinterpret_f64"),
        .f32_reinterpret_i32 => try lower.lower_convert_op("f32_reinterpret_i32"),
        .f64_reinterpret_i64 => try lower.lower_convert_op("f64_reinterpret_i64"),
        .i32_extend8_s => try lower.lower_convert_op("i32_extend8_s"),
        .i32_extend16_s => try lower.lower_convert_op("i32_extend16_s"),
        .i64_extend8_s => try lower.lower_convert_op("i64_extend8_s"),
        .i64_extend16_s => try lower.lower_convert_op("i64_extend16_s"),
        .i64_extend32_s => try lower.lower_convert_op("i64_extend32_s"),

        // ── Memory loads ─────────────────────────────────────────────────────
        .i32_load => {
            const offset = (try p.read_memory_immediate()).offset;
            const addr = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .i32_load = .{ .dst = dst, .addr = addr, .offset = offset } });
            try lower.stack.push(lower.allocator, dst);
        },
        .i32_load8_s => {
            const offset = (try p.read_memory_immediate()).offset;
            const addr = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .i32_load8_s = .{ .dst = dst, .addr = addr, .offset = offset } });
            try lower.stack.push(lower.allocator, dst);
        },
        .i32_load8_u => {
            const offset = (try p.read_memory_immediate()).offset;
            const addr = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .i32_load8_u = .{ .dst = dst, .addr = addr, .offset = offset } });
            try lower.stack.push(lower.allocator, dst);
        },
        .i32_load16_s => {
            const offset = (try p.read_memory_immediate()).offset;
            const addr = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .i32_load16_s = .{ .dst = dst, .addr = addr, .offset = offset } });
            try lower.stack.push(lower.allocator, dst);
        },
        .i32_load16_u => {
            const offset = (try p.read_memory_immediate()).offset;
            const addr = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .i32_load16_u = .{ .dst = dst, .addr = addr, .offset = offset } });
            try lower.stack.push(lower.allocator, dst);
        },
        .i64_load => {
            const offset = (try p.read_memory_immediate()).offset;
            const addr = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .i64_load = .{ .dst = dst, .addr = addr, .offset = offset } });
            try lower.stack.push(lower.allocator, dst);
        },
        .i64_load8_s => {
            const offset = (try p.read_memory_immediate()).offset;
            const addr = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .i64_load8_s = .{ .dst = dst, .addr = addr, .offset = offset } });
            try lower.stack.push(lower.allocator, dst);
        },
        .i64_load8_u => {
            const offset = (try p.read_memory_immediate()).offset;
            const addr = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .i64_load8_u = .{ .dst = dst, .addr = addr, .offset = offset } });
            try lower.stack.push(lower.allocator, dst);
        },
        .i64_load16_s => {
            const offset = (try p.read_memory_immediate()).offset;
            const addr = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .i64_load16_s = .{ .dst = dst, .addr = addr, .offset = offset } });
            try lower.stack.push(lower.allocator, dst);
        },
        .i64_load16_u => {
            const offset = (try p.read_memory_immediate()).offset;
            const addr = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .i64_load16_u = .{ .dst = dst, .addr = addr, .offset = offset } });
            try lower.stack.push(lower.allocator, dst);
        },
        .i64_load32_s => {
            const offset = (try p.read_memory_immediate()).offset;
            const addr = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .i64_load32_s = .{ .dst = dst, .addr = addr, .offset = offset } });
            try lower.stack.push(lower.allocator, dst);
        },
        .i64_load32_u => {
            const offset = (try p.read_memory_immediate()).offset;
            const addr = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .i64_load32_u = .{ .dst = dst, .addr = addr, .offset = offset } });
            try lower.stack.push(lower.allocator, dst);
        },
        .f32_load => {
            const offset = (try p.read_memory_immediate()).offset;
            const addr = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .f32_load = .{ .dst = dst, .addr = addr, .offset = offset } });
            try lower.stack.push(lower.allocator, dst);
        },
        .f64_load => {
            const offset = (try p.read_memory_immediate()).offset;
            const addr = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .f64_load = .{ .dst = dst, .addr = addr, .offset = offset } });
            try lower.stack.push(lower.allocator, dst);
        },

        // ── Memory stores ────────────────────────────────────────────────────
        .i32_store => {
            const offset = (try p.read_memory_immediate()).offset;
            const src = try lower.pop_slot();
            const addr = try lower.pop_slot();
            try lower.emit(.{ .i32_store = .{ .addr = addr, .src = src, .offset = offset } });
        },
        .i32_store8 => {
            const offset = (try p.read_memory_immediate()).offset;
            const src = try lower.pop_slot();
            const addr = try lower.pop_slot();
            try lower.emit(.{ .i32_store8 = .{ .addr = addr, .src = src, .offset = offset } });
        },
        .i32_store16 => {
            const offset = (try p.read_memory_immediate()).offset;
            const src = try lower.pop_slot();
            const addr = try lower.pop_slot();
            try lower.emit(.{ .i32_store16 = .{ .addr = addr, .src = src, .offset = offset } });
        },
        .i64_store => {
            const offset = (try p.read_memory_immediate()).offset;
            const src = try lower.pop_slot();
            const addr = try lower.pop_slot();
            try lower.emit(.{ .i64_store = .{ .addr = addr, .src = src, .offset = offset } });
        },
        .i64_store8 => {
            const offset = (try p.read_memory_immediate()).offset;
            const src = try lower.pop_slot();
            const addr = try lower.pop_slot();
            try lower.emit(.{ .i64_store8 = .{ .addr = addr, .src = src, .offset = offset } });
        },
        .i64_store16 => {
            const offset = (try p.read_memory_immediate()).offset;
            const src = try lower.pop_slot();
            const addr = try lower.pop_slot();
            try lower.emit(.{ .i64_store16 = .{ .addr = addr, .src = src, .offset = offset } });
        },
        .i64_store32 => {
            const offset = (try p.read_memory_immediate()).offset;
            const src = try lower.pop_slot();
            const addr = try lower.pop_slot();
            try lower.emit(.{ .i64_store32 = .{ .addr = addr, .src = src, .offset = offset } });
        },
        .f32_store => {
            const offset = (try p.read_memory_immediate()).offset;
            const src = try lower.pop_slot();
            const addr = try lower.pop_slot();
            try lower.emit(.{ .f32_store = .{ .addr = addr, .src = src, .offset = offset } });
        },
        .f64_store => {
            const offset = (try p.read_memory_immediate()).offset;
            const src = try lower.pop_slot();
            const addr = try lower.pop_slot();
            try lower.emit(.{ .f64_store = .{ .addr = addr, .src = src, .offset = offset } });
        },

        // ── Bulk memory ──────────────────────────────────────────────────────
        .memory_size => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_uint32();
            const dst = lower.alloc_slot();
            try lower.stack.push(lower.allocator, dst);
            try lower.emit(.{ .memory_size = .{ .dst = dst } });
        },
        .memory_grow => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_uint32();
            const delta = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.stack.push(lower.allocator, dst);
            try lower.emit(.{ .memory_grow = .{ .dst = dst, .delta = delta } });
        },

        // ── Return ───────────────────────────────────────────────────────────
        .return_ => {
            const value = lower.stack.pop();
            try lower.emit(.{ .ret = .{ .value = value } });
            lower.is_unreachable = true;
        },

        // ── Select ───────────────────────────────────────────────────────────
        .select => {
            const cond = try lower.pop_slot();
            const val2 = try lower.pop_slot();
            const val1 = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .select = .{ .dst = dst, .val1 = val1, .val2 = val2, .cond = cond } });
            try lower.stack.push(lower.allocator, dst);
        },
        .select_with_type => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const num_types = p.read_var_int32();
            if (num_types == 1) {
                _ = try p.read_type_checked();
            }
            const cond = try lower.pop_slot();
            const val2 = try lower.pop_slot();
            const val1 = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .select = .{ .dst = dst, .val1 = val1, .val2 = val2, .cond = cond } });
            try lower.stack.push(lower.allocator, dst);
        },

        // ── Reference types ──────────────────────────────────────────────────
        .ref_null => {
            _ = try p.read_heap_type_checked();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .const_ref_null = .{ .dst = dst } });
            try lower.stack.push(lower.allocator, dst);
        },
        .ref_is_null => {
            const src = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .ref_is_null = .{ .dst = dst, .src = src } });
            try lower.stack.push(lower.allocator, dst);
        },
        .ref_func => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const func_idx = p.read_var_uint32();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .ref_func = .{ .dst = dst, .func_idx = func_idx } });
            try lower.stack.push(lower.allocator, dst);
        },
        .ref_eq => {
            const rhs = try lower.pop_slot();
            const lhs = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .ref_eq = .{ .dst = dst, .lhs = lhs, .rhs = rhs } });
            try lower.stack.push(lower.allocator, dst);
        },
        .ref_as_non_null => {
            const src = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .ref_as_non_null = .{ .dst = dst, .ref = src } });
            try lower.stack.push(lower.allocator, dst);
        },

        // ── Table instructions ───────────────────────────────────────────────
        .table_get => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const table_index = p.read_var_uint32();
            const index = try lower.pop_slot();
            const dst = lower.alloc_slot();
            try lower.emit(.{ .table_get = .{ .dst = dst, .table_index = table_index, .index = index } });
            try lower.stack.push(lower.allocator, dst);
        },
        .table_set => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const table_index = p.read_var_uint32();
            const value = try lower.pop_slot();
            const index = try lower.pop_slot();
            try lower.emit(.{ .table_set = .{ .table_index = table_index, .index = index, .value = value } });
        },

        // ── Branch-on-ref opcodes ────────────────────────────────────────────
        .br_on_null => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const depth = p.read_var_uint32();
            try lower.lowerOp(.{ .br_on_null = depth });
        },
        .br_on_non_null => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const depth = p.read_var_uint32();
            try lower.lowerOp(.{ .br_on_non_null = depth });
        },

        // ── Throw-ref ────────────────────────────────────────────────────────
        .throw_ref => {
            try lower.lowerOp(.throw_ref);
        },

        // ── 9 special opcodes: inline resolver logic ─────────────────────────
        .call => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const func_idx = p.read_var_uint32();
            const func_type = try resolver.resolve(func_idx);
            try lower.lowerOp(.{ .call = .{
                .func_idx = func_idx,
                .n_params = @intCast(func_type.params().len),
                .has_result = func_type.results().len > 0,
            } });
        },
        .call_indirect => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const type_index = p.read_var_uint32();
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_uint32(); // table index (discarded)
            if (type_index >= resolver.composite_types.len) return error.InvalidFunctionTypeIndex;
            const func_type = try resolver.getFuncType(type_index);
            try lower.lowerOp(.{ .call_indirect = .{
                .type_index = type_index,
                .table_index = 0,
                .n_params = @intCast(func_type.params().len),
                .has_result = func_type.results().len > 0,
            } });
        },
        .return_call => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const func_idx = p.read_var_uint32();
            const func_type = try resolver.resolve(func_idx);
            try lower.lowerOp(.{ .return_call = .{
                .func_idx = func_idx,
                .n_params = @intCast(func_type.params().len),
            } });
        },
        .return_call_indirect => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const type_index = p.read_var_uint32();
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_uint32(); // table index (discarded)
            if (type_index >= resolver.composite_types.len) return error.InvalidFunctionTypeIndex;
            const func_type = try resolver.getFuncType(type_index);
            try lower.lowerOp(.{ .return_call_indirect = .{
                .type_index = type_index,
                .table_index = 0,
                .n_params = @intCast(func_type.params().len),
            } });
        },
        .throw => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const tag_idx = p.read_var_uint32();
            if (tag_idx >= tags.len) return error.InvalidTagIndex;
            const tag_type_idx = tags[tag_idx].type_index;
            const tag_func_type = try resolver.getFuncType(tag_type_idx);
            try lower.lowerOp(.{ .throw = .{
                .tag_index = tag_idx,
                .n_args = @intCast(tag_func_type.params().len),
            } });
        },
        .try_table => {
            const block_type_raw = try p.read_type_checked();
            const raw_handlers = try p.read_try_table();
            var handlers_list = try std.ArrayListUnmanaged(lower_mod.CatchHandlerWasm).initCapacity(
                scratch,
                raw_handlers.len,
            );
            for (raw_handlers) |h| {
                const tag_arity: u32 = if (h.tag_index) |ti| arity: {
                    if (ti >= tags.len) return error.InvalidTagIndex;
                    const ti_type = tags[ti].type_index;
                    const ti_func_type = try resolver.getFuncType(ti_type);
                    break :arity @intCast(ti_func_type.params().len);
                } else 0;
                try handlers_list.append(scratch, .{
                    .kind = h.kind,
                    .tag_index = h.tag_index,
                    .depth = h.depth,
                    .tag_arity = tag_arity,
                });
            }
            const block_type = try translate_mod.wasmBlockTypeFromType(block_type_raw);
            try lower.lowerOp(.{ .try_table = .{
                .block_type = block_type,
                .handlers = handlers_list.items,
            } });
        },
        .call_ref => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const type_idx = p.read_var_uint32();
            const func_type = try resolver.getFuncType(type_idx);
            try lower.lowerOp(.{ .call_ref = .{
                .type_idx = type_idx,
                .n_params = @intCast(func_type.params().len),
                .has_result = func_type.results().len > 0,
            } });
        },
        .return_call_ref => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const type_idx = p.read_var_uint32();
            const func_type = try resolver.getFuncType(type_idx);
            try lower.lowerOp(.{ .return_call_ref = .{
                .type_idx = type_idx,
                .n_params = @intCast(func_type.params().len),
            } });
        },
        .struct_new => {
            // struct_new has prefix 0xfb — should be handled in prefix fallback.
            // This arm should not be reached for single-byte opcodes.
            unreachable;
        },

        // ── Legacy EH opcodes (try_, catch_, catch_all, rethrow, delegate) ───
        // These should only appear in the legacy path. If encountered in the
        // new-EH path, they have no operands to lower here; fall back.
        .try_ => {
            const block_type = try translate_mod.wasmBlockTypeFromType(try p.read_type_checked());
            try lower.lowerOp(.{ .block = block_type });
        },
        .catch_ => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_uint32();
            return error.UnsupportedOperator;
        },
        .catch_all => {
            return error.UnsupportedOperator;
        },
        .rethrow => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_uint32();
            return error.UnsupportedOperator;
        },
        .delegate => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_uint32();
            return error.UnsupportedOperator;
        },

        // ── Prefix opcodes already handled above ─────────────────────────────
        .prefix_0xfb, .prefix_0xfc, .prefix_0xfd, .prefix_0xfe => unreachable,

        // ── Anything else (unexpected single-byte opcode) ────────────────────
        else => {
            return error.UnknownOperator;
        },
    }
    return code;
}

/// In unreachable code, we need to consume operands from the byte stream
/// to keep the parser cursor in sync, even though we won't lower them.
fn consumeOperands(p: *parser_mod.Parser, code: payload_mod.OperatorCode) parser_mod.CodeReadError!void {
    switch (code) {
        .block, .loop, .if_, .try_ => {
            _ = try p.read_type_checked();
        },
        .br, .br_if, .br_on_null, .br_on_non_null => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_uint32();
        },
        .br_table => {
            _ = try p.read_br_table();
        },
        .rethrow, .delegate => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_uint32();
        },
        .catch_, .throw => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_uint32();
        },
        .try_table => {
            _ = try p.read_type_checked();
            _ = try p.read_try_table();
        },
        .ref_null => {
            _ = try p.read_heap_type_checked();
        },
        .call, .return_call, .ref_func => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_uint32();
        },
        .call_indirect, .return_call_indirect => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_uint32();
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_uint32();
        },
        .local_get, .local_set, .local_tee => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_uint32();
        },
        .global_get, .global_set => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_uint32();
        },
        .table_get, .table_set => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_uint32();
        },
        .call_ref, .return_call_ref => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_uint32();
        },
        .i32_load,
        .i64_load,
        .f32_load,
        .f64_load,
        .i32_load8_s,
        .i32_load8_u,
        .i32_load16_s,
        .i32_load16_u,
        .i64_load8_s,
        .i64_load8_u,
        .i64_load16_s,
        .i64_load16_u,
        .i64_load32_s,
        .i64_load32_u,
        .i32_store,
        .i64_store,
        .f32_store,
        .f64_store,
        .i32_store8,
        .i32_store16,
        .i64_store8,
        .i64_store16,
        .i64_store32,
        => _ = try p.read_memory_immediate(),
        .memory_size, .memory_grow => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_uint32();
        },
        .i32_const => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_int32();
        },
        .i64_const => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            _ = p.read_var_int64();
        },
        .f32_const => {
            if (!p.has_bytes(4)) return error.NeedMoreData;
            _ = p.read_bytes(4);
        },
        .f64_const => {
            if (!p.has_bytes(8)) return error.NeedMoreData;
            _ = p.read_bytes(8);
        },
        .select_with_type => {
            if (!p.has_var_int_bytes()) return error.NeedMoreData;
            const num_types = p.read_var_int32();
            if (num_types == 1) {
                _ = try p.read_type_checked();
            }
        },
        // All no-operand opcodes (arithmetic, comparisons, conversions, etc.)
        else => {},
    }
}

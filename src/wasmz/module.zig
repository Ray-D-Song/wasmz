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
const engine_mod = @import("../engine/mod.zig");
const lower_mod = @import("../compiler/lower.zig");
const translate_mod = @import("../compiler/translate.zig");
const ir = @import("../compiler/ir.zig");
const core = @import("core");
const func_type_mod = core.func_type;
const global_mod = core.global;
const raw_mod = core.raw;
const typed_mod = core.typed;
const value_type_mod = core.value_type;

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
const RawVal = raw_mod.RawVal;
const TypedRawVal = typed_mod.TypedRawVal;
const ValType = value_type_mod.ValType;
const Engine = engine_mod.Engine;
const Lower = lower_mod.Lower;

// TODO: Currently only supports function exports; other export kinds (memory, global, table) are ignored.
pub const ExportEntry = struct {
    function_index: u32,
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

/// All possible errors that can occur during module compilation.
pub const ModuleCompileError = Allocator.Error ||
    parser_mod.ParseAllError ||
    parser_mod.CodeReadError ||
    lower_mod.LowerError ||
    func_type_mod.FuncTypeError ||
    error{
        DuplicateExport,
        ImportedFunctionCallUnsupported,
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
    };

/// Compiled WebAssembly module, holding all data required for runtime execution.
///
/// Field descriptions:
///   - functions:         List of compiled functions, indexed according to the Wasm function index space (imported functions come first).
///   - func_types:        All function signatures defined in the Type Section.
///   - exports:           Mapping from export names to ExportEntry, currently only function exports are supported.
///   - globals:           List of global variables, each containing mutability and the initial value evaluated from constant expressions.
///   - memory:            Linear memory definition (optional), currently supports at most one memory segment.
///   - start_function:    Optional start function index (from the Wasm Start Section).
///                        Per the Wasm spec, this function is automatically called during module instantiation.
///                        It must have no parameters and no return values.
///   - import_func_count: Number of imported functions; used to offset func_idx when resolving call targets.
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
    /// Number of imported functions. The func_idx in the call instruction includes imported functions,
    /// local functions' index in functions = func_idx - import_func_count.
    import_func_count: u32,

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
        const payloads = try parser.parse_all(bytes);

        var func_types_list: std.ArrayListUnmanaged(FuncType) = .empty;
        errdefer deinitFuncTypeList(allocator, &func_types_list);

        var function_type_indices: std.ArrayListUnmanaged(u32) = .empty;
        defer function_type_indices.deinit(allocator);

        var globals_list: std.ArrayListUnmanaged(GlobalInit) = .empty;
        defer globals_list.deinit(allocator);

        var exports: std.StringHashMapUnmanaged(ExportEntry) = .empty;
        errdefer deinitExports(allocator, &exports);

        var imported_function_count: usize = 0;
        var memory: ?MemoryDef = null;
        var start_function: ?u32 = null;

        for (payloads) |payload| {
            switch (payload) {
                .type_entry => |entry| {
                    try func_types_list.append(
                        allocator,
                        try compileFuncType(allocator, arena.allocator(), entry),
                    );
                },
                .import_entry => |entry| {
                    if (entry.kind == .function) {
                        imported_function_count += 1;
                    }
                },
                .function_entry => |entry| {
                    try function_type_indices.append(allocator, entry.type_index);
                },
                .global_variable => |entry| {
                    try globals_list.append(
                        allocator,
                        try compileGlobalInit(arena.allocator(), entry),
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
                        .function => try putFunctionExport(
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
                else => {},
            }
        }

        const function_count = imported_function_count + function_type_indices.items.len;
        const functions = try allocator.alloc(CompiledFunction, function_count);
        errdefer {
            deinitFunctions(allocator, functions);
            allocator.free(functions);
        }
        @memset(functions, .{
            .slots_len = 0,
            .ops = .empty,
            .call_args = .empty,
        });

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

                    const reserved_slots = try computeReservedSlots(func_types_list.items[type_index], info);
                    const function_index = imported_function_count + local_function_index;

                    // build function type resolver for looking up callee signatures when translating call instructions
                    const resolver = FuncTypeResolver{
                        .func_types = func_types_list.items,
                        .type_indices = function_type_indices.items,
                        .import_count = imported_function_count,
                    };

                    functions[function_index] = try compileFunctionBody(
                        allocator,
                        reserved_slots,
                        info.body,
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

        return .{
            .allocator = allocator,
            .functions = functions,
            .func_types = func_types,
            .exports = exports,
            .globals = globals,
            .memory = memory,
            .start_function = start_function,
            .import_func_count = @intCast(imported_function_count),
        };
    }

    pub fn deinit(self: *Module) void {
        deinitFunctions(self.allocator, self.functions);
        self.allocator.free(self.functions);

        for (self.func_types) |func_type| {
            func_type.deinit(self.allocator);
        }
        self.allocator.free(self.func_types);

        deinitExports(self.allocator, &self.exports);
        self.allocator.free(self.globals);
        self.* = undefined;
    }

    // ── deinit helpers ───────────────────────────────────────────────────────────

    /// Free the operations list held by each CompiledFunction in the functions slice.
    fn deinitFunctions(allocator: Allocator, functions: []CompiledFunction) void {
        for (functions) |*function| {
            function.call_args.deinit(allocator);
            function.ops.deinit(allocator);
        }
    }

    /// Free the FuncType list: first free each element, then free the list itself.
    fn deinitFuncTypeList(allocator: Allocator, list: *std.ArrayListUnmanaged(FuncType)) void {
        for (list.items) |func_type| {
            func_type.deinit(allocator);
        }
        list.deinit(allocator);
    }

    /// Free the exports map: first free each key (the heap memory of the export name), then free the map itself.
    fn deinitExports(allocator: Allocator, exports_map: *std.StringHashMapUnmanaged(ExportEntry)) void {
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
    fn putFunctionExport(
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
    fn compileFuncType(
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
    /// This function parses the init_expr bytecode and evaluates it (using evaluateConstExpr) to obtain the concrete initial value of the global variable.
    fn compileGlobalInit(
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
                try evaluateConstExpr(temp_allocator, global_variable.init_expr, val_type),
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
    fn evaluateConstExpr(
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
            .FuncRef, .ExternRef => switch (init.info.code) {
                .ref_null => RawVal.fromBits64(0),
                else => return error.UnsupportedConstExpr,
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
    fn computeReservedSlots(func_type: FuncType, function_info: payload_mod.FunctionInformation) ModuleCompileError!u32 {
        var locals_count: usize = func_type.params().len;
        for (function_info.locals) |local_group| {
            locals_count += local_group.count;
        }
        return std.math.cast(u32, locals_count) orelse error.InvalidLocalCount;
    }
};

/// Function type resolver: look up function signatures (parameter count, return count) by func_idx.
///
/// Wasm function index space = imported functions + local functions, type_indices only cover local functions.
pub const FuncTypeResolver = struct {
    func_types: []const FuncType,
    type_indices: []const u32,
    import_count: usize,

    /// Look up the FuncType by func_idx.
    /// Returns an error if func_idx refers to an imported function or is out of bounds.
    pub fn resolve(self: FuncTypeResolver, func_idx: u32) ModuleCompileError!*const FuncType {
        if (func_idx < self.import_count) return error.ImportedFunctionCallUnsupported;
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
    resolver: FuncTypeResolver,
) ModuleCompileError!CompiledFunction {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var lower = Lower.init_with_reserved_slots(allocator, reserved_slots);
    errdefer lower.deinit();

    var cursor: usize = 0;
    while (cursor < body.len) {
        const parsed = try parser_mod.readNextOperator(arena.allocator(), body[cursor..]);
        cursor += parsed.consumed;

        const wasm_op: lower_mod.WasmOp = if (parsed.info.code == .call) blk: {
            const func_idx = parsed.info.func_index orelse return error.UnsupportedOperator;
            const func_type = try resolver.resolve(func_idx);
            break :blk .{ .call = .{
                .func_idx = func_idx,
                .n_params = @intCast(func_type.params().len),
                .has_result = func_type.results().len > 0,
            } };
        } else try translate_mod.operatorToWasmOp(parsed.info);

        try lower.lower_op(wasm_op);
    }

    const compiled = lower.finish();
    lower.compiled.ops = .empty;
    lower.compiled.call_args = .empty;
    lower.deinit();
    return compiled;
}

test "module.compile builds exported function bodies" {
    const VM = @import("../vm/mod.zig").VM;
    const Config = @import("../engine/config.zig").Config;

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
    const result = (try vm.execute(module.functions[@intCast(export_entry.function_index)], &.{}, &.{}, &.{}, &.{})).ok orelse {
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

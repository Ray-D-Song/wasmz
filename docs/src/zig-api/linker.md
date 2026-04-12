# Linker & Host Functions

The linker connects WASM imports to host-provided functions.

## Linker

### Creating a Linker

```zig
var linker = wasmz.Linker.empty;
defer linker.deinit(allocator);
```

### Defining Functions

```zig
try linker.define(
    allocator,
    "module_name",  // Import module name
    "func_name",    // Import function name
    wasmz.HostFunc.init(
        null,                    // Context (optional)
        host_function,           // Function pointer
        &[_]wasmz.ValType{ .I32 }, // Parameter types
        &[_]wasmz.ValType{ .I32 }, // Result types
    ),
);
```

### Methods

| Method | Description |
|--------|-------------|
| `define(alloc, module, name, func)` | Register a host function |
| `get(module, name)` | Look up a function |
| `deinit(alloc)` | Free linker resources |

## HostFunc

### Creating Host Functions

```zig
fn host_print(
    ctx: ?*anyopaque,
    hc: *wasmz.HostContext,
    params: []const wasmz.RawVal,
    results: []wasmz.RawVal,
) wasmz.HostError!void {
    const value = params[0].readAs(i32);
    std.debug.print("Value: {d}\n", .{value});
    // No return value - results is empty
}
```

### With Context

```zig
const MyContext = struct {
    counter: u32,
};

fn host_increment(
    ctx: ?*anyopaque,
    hc: *wasmz.HostContext,
    params: []const wasmz.RawVal,
    results: []wasmz.RawVal,
) wasmz.HostError!void {
    const my_ctx: *MyContext = @ptrCast(@alignCast(ctx.?));
    my_ctx.counter += params[0].readAs(u32);
    results[0] = wasmz.RawVal.from(@as(i32, @intCast(my_ctx.counter)));
}

var my_ctx = MyContext{ .counter = 0 };
try linker.define(allocator, "env", "increment", wasmz.HostFunc.init(
    &my_ctx,
    host_increment,
    &[_]wasmz.ValType{.I32},
    &[_]wasmz.ValType{.I32},
));
```

## HostContext

The `HostContext` provides access to runtime state:

```zig
fn host_memory_access(
    ctx: ?*anyopaque,
    hc: *wasmz.HostContext,
    params: []const wasmz.RawVal,
    results: []wasmz.RawVal,
) wasmz.HostError!void {
    // Access instance memory
    const offset = @as(usize, @intCast(params[0].readAs(u32)));
    const memory = hc.instance.memory;
    const byte = memory.readByte(offset);
    results[0] = wasmz.RawVal.from(@as(i32, byte));
}
```

### Properties

| Property | Description |
|----------|-------------|
| `instance` | Access to the instance |
| `store` | Access to the store |

## ValType

Value types for function signatures:

```zig
const ValType = enum {
    I32,
    I64,
    F32,
    F64,
    FuncRef,
    ExternRef,
};
```

## WASI Integration

Add WASI functions to the linker:

```zig
const wasi = @import("wasi").preview1;

var wasi_host = wasi.Host.init(allocator);
defer wasi_host.deinit();

// Set command-line arguments
try wasi_host.setArgs(&[_][]const u8{ "program.wasm", "--verbose" });

// Add to linker
try wasi_host.addToLinker(&linker, allocator);
```

## Error Handling from Host

Return errors from host functions:

```zig
fn host_may_fail(
    ctx: ?*anyopaque,
    hc: *wasmz.HostContext,
    params: []const wasmz.RawVal,
    results: []wasmz.RawVal,
) wasmz.HostError!void {
    const value = params[0].readAs(i32);
    if (value < 0) {
        return wasmz.HostError.Trap; // Will cause a trap
    }
    results[0] = wasmz.RawVal.from(value * 2);
}
```

## Complete Example

```zig
const std = @import("std");
const wasmz = @import("wasmz");

fn host_add(
    _: ?*anyopaque,
    _: *wasmz.HostContext,
    params: []const wasmz.RawVal,
    results: []wasmz.RawVal,
) wasmz.HostError!void {
    const a = params[0].readAs(i32);
    const b = params[1].readAs(i32);
    results[0] = wasmz.RawVal.from(a + b);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Setup
    var engine = try wasmz.Engine.init(allocator, .{});
    defer engine.deinit();

    var store = try wasmz.Store.init(allocator, engine);
    defer store.deinit();

    // Create linker with host function
    var linker = wasmz.Linker.empty;
    defer linker.deinit(allocator);

    try linker.define(allocator, "env", "host_add", wasmz.HostFunc.init(
        null,
        host_add,
        &[_]wasmz.ValType{ .I32, .I32 },
        &[_]wasmz.ValType{.I32},
    ));

    // Load and run WASM that imports "env::host_add"
    const bytes = try std.fs.cwd().readFileAlloc(allocator, "module.wasm", 1024 * 1024);
    defer allocator.free(bytes);

    var module = try wasmz.Module.compile(engine, bytes);
    defer module.deinit();

    var instance = try wasmz.Instance.init(&store, module, linker);
    defer instance.deinit();

    _ = try instance.runStartFunction();
}
```

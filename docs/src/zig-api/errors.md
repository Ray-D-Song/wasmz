# Error Handling

## Traps

A `Trap` represents a runtime error in WebAssembly execution.

### TrapCode

```zig
pub const TrapCode = enum {
    Unreachable,
    IntegerDivisionByZero,
    IntegerOverflow,
    IndirectCallToNull,
    UndefinedElement,
    UninitializedElement,
    OutOfBoundsMemoryAccess,
    OutOfBoundsTableAccess,
    IndirectCallTypeMismatch,
    StackOverflow,
    OutOfMemory,
    // ... more codes
};
```

### ExecResult

Function calls return an `ExecResult`:

```zig
const result = try instance.call("func", &args);

switch (result) {
    .ok => |val| {
        // Success - val may be null for void functions
        if (val) |v| {
            std.debug.print("Result: {d}\n", .{v.readAs(i32)});
        }
    },
    .trap => |trap| {
        // Trap occurred
        std.debug.print("Trap: {s}\n", .{@tagName(trap.code)});
        
        // Get detailed message
        const msg = try trap.allocPrint(allocator);
        defer allocator.free(msg);
        std.debug.print("Details: {s}\n", .{msg});
    },
}
```

### Trap Message

Get a human-readable trap message:

```zig
if (result.trap) |trap| {
    const msg = try trap.allocPrint(allocator);
    defer allocator.free(msg);
    std.debug.print("Trap: {s}\n", .{msg});
}
```

## Host Errors

Host functions can return errors:

```zig
fn host_divide(
    _: ?*anyopaque,
    _: *wasmz.HostContext,
    params: []const wasmz.RawVal,
    results: []wasmz.RawVal,
) wasmz.HostError!void {
    const a = params[0].readAs(i32);
    const b = params[1].readAs(i32);
    
    if (b == 0) {
        return wasmz.HostError.Trap;
    }
    
    results[0] = wasmz.RawVal.from(@divTrunc(a, b));
}
```

## Common Errors

### Module Compilation

```zig
var module = wasmz.Module.compile(engine, bytes) catch |err| {
    switch (err) {
        error.InvalidWasm => {
            std.debug.print("Invalid WASM binary\n", .{});
        },
        error.UnsupportedFeature => {
            std.debug.print("Feature not supported\n", .{});
        },
        error.OutOfMemory => {
            std.debug.print("Out of memory\n", .{});
        },
        else => return err,
    }
    return;
};
```

### Instantiation

```zig
var instance = wasmz.Instance.init(&store, module, linker) catch |err| {
    switch (err) {
        error.ImportNotSatisfied => {
            std.debug.print("Missing imports:\n", .{});
            for (module.imported_funcs) |imp| {
                if (linker.get(imp.module_name, imp.func_name) == null) {
                    std.debug.print("  {s}::{s}\n", .{ imp.module_name, imp.func_name });
                }
            }
        },
        error.ImportSignatureMismatch => {
            std.debug.print("Import signature mismatch\n", .{});
        },
        else => return err,
    }
    return;
};
```

## Memory Limit

When memory limit is exceeded:

```zig
var engine = try wasmz.Engine.init(allocator, .{
    .mem_limit_bytes = 64 * 1024 * 1024, // 64 MB
});

// If WASM tries to grow memory beyond limit:
// result.trap.code == .OutOfMemory
```

## Stack Overflow

When call stack is exhausted:

```zig
// Recursive function without base case
// result.trap.code == .StackOverflow
```

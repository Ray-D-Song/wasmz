# Module

A `Module` represents a compiled WebAssembly module (read-only).

## Compilation

### Basic Compilation

```zig
const bytes = try std.fs.cwd().readFileAlloc(allocator, "module.wasm", max_size);
defer allocator.free(bytes);

var module = try wasmz.Module.compile(engine, bytes);
defer module.deinit();
```

### Arc Module (Reference Counted)

For sharing modules across multiple instances:

```zig
// Compile with reference counting
var arc_module = try wasmz.Module.compileArc(engine, bytes);
defer if (arc_module.releaseUnwrap()) |m| {
    var mod = m;
    mod.deinit();
};

// Retain for each instance
var instance = try wasmz.Instance.init(&store, arc_module.retain(), linker);
```

## Methods

| Method | Description |
|--------|-------------|
| `compile(engine, bytes)` | Compile module from bytes |
| `compileArc(engine, bytes)` | Compile with ref counting |
| `deinit()` | Free module resources |
| `retain()` | Increment ref count (Arc only) |
| `releaseUnwrap()` | Decrement ref count (Arc only) |

## Module Information

### Exports

```zig
var iter = module.exports.iterator();
while (iter.next()) |entry| {
    std.debug.print("Export: {s}\n", .{entry.key_ptr.*});
}

// Check for specific export
if (module.exports.get("_start")) |_| {
    // Command module
}
```

### Imports

```zig
for (module.imported_funcs) |import| {
    std.debug.print("Import: {s}::{s}\n", .{ import.module_name, import.func_name });
}
```

## Validation

Modules are validated during compilation. Errors are returned:

```zig
var module = wasmz.Module.compile(engine, bytes) catch |err| {
    switch (err) {
        error.InvalidWasm => std.debug.print("Invalid WASM binary\n", .{}),
        error.OutOfMemory => std.debug.print("Out of memory\n", .{}),
        else => return err,
    }
    return;
};
```

## Module Types

### Command vs Reactor

| Type | Entry Point | Description |
|------|-------------|-------------|
| Command | `_start` | Runs once, may call `proc_exit` |
| Reactor | `_initialize` | Library, multiple function calls |

```zig
if (module.exports.get("_start")) |_| {
    // Command module
} else if (module.exports.get("_initialize")) |_| {
    // Reactor module
}
```

## Thread Safety

- **Module** - Not thread-safe for concurrent access.
- **ArcModule** - Reference counting is thread-safe (uses `zigrc.Arc`). Multiple threads can safely call `retain()`/`releaseUnwrap()`.

While ArcModule's reference counting is atomic, the underlying Module data should not be accessed concurrently. Create separate ArcModule handles per thread and avoid sharing the same Module across threads.

## Memory Management

- **compile()**: Module owned by caller, call `deinit()` when done
- **compileArc()**: Reference counted, use `retain()`/`releaseUnwrap()` for sharing

```zig
// Single instance - use compile()
var module = try wasmz.Module.compile(engine, bytes);
defer module.deinit();

// Multiple instances - use compileArc()
var arc = try wasmz.Module.compileArc(engine, bytes);

var inst1 = try wasmz.Instance.init(&store1, arc.retain(), linker);
var inst2 = try wasmz.Instance.init(&store2, arc.retain(), linker);

// When done
_ = arc.releaseUnwrap(); // Decrements and frees if zero
```

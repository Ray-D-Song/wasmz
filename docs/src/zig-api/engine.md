# Engine & Config

The `Engine` is the core runtime that manages compilation, configuration, and shared resources.

## Engine

### Initialization

```zig
const wasmz = @import("wasmz");

// Default configuration
var engine = try wasmz.Engine.init(allocator, .{});
defer engine.deinit();

// With configuration
var engine = try wasmz.Engine.init(allocator, .{
    .legacy_exceptions = true,
    .mem_limit_bytes = 256 * 1024 * 1024, // 256 MB limit
});
defer engine.deinit();
```

### Methods

| Method | Description |
|--------|-------------|
| `init(allocator, config)` | Create engine with config |
| `deinit()` | Free engine resources |

## Config

Configuration options for the engine:

```zig
const Config = struct {
    /// Use legacy exception handling proposal
    legacy_exceptions: bool = false,
    
    /// Memory limit in bytes (null = unlimited)
    mem_limit_bytes: ?u64 = null,
};
```

### Options

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `legacy_exceptions` | `bool` | `false` | Use legacy EH proposal |
| `mem_limit_bytes` | `?u64` | `null` | Max memory allocation |

### Example: Memory Limit

```zig
var engine = try wasmz.Engine.init(allocator, .{
    .mem_limit_bytes = 128 * 1024 * 1024, // 128 MB
});
```

### Example: Legacy Exceptions

For modules using the older exception handling proposal:

```zig
var engine = try wasmz.Engine.init(allocator, .{
    .legacy_exceptions = true,
});
```

## Thread Safety

- **Engine** - Reference counting is thread-safe (uses `zigrc.Arc`). Multiple threads can clone/deinit independently.
- **Config** - Immutable after creation, safe to share across threads.

Note: While reference counting is atomic, concurrent access to the same Engine instance (e.g., calling `config()`) is not synchronized. Create separate Engine instances per thread if needed.

## Lifecycle

The engine must outlive any stores or modules created from it:

```zig
var engine = try wasmz.Engine.init(allocator, .{});
defer engine.deinit(); // Must be called after store/module deinit

var store = try wasmz.Store.init(allocator, engine);
defer store.deinit();

var module = try wasmz.Module.compile(engine, bytes);
defer module.deinit();
```

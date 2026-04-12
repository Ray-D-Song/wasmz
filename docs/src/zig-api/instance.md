# Store & Instance

The `Store` holds runtime context, and `Instance` is an instantiated module.

## Store

The store manages the allocator, engine reference, and runtime state.

### Initialization

```zig
var store = try wasmz.Store.init(allocator, engine);
defer store.deinit();
```

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `gc_heap` | `GCHeap` | Garbage-collected heap |
| `memory_budget` | `MemoryBudget` | Memory tracking |

### Memory Budget

Link the memory budget for enforcement:

```zig
store.linkBudget(); // Enable memory limits
```

## Instance

### Initialization

```zig
var instance = try wasmz.Instance.init(&store, module, linker);
defer instance.deinit();
```

### Command Model

Run `_start`:

```zig
if (try instance.runStartFunction()) |result| {
    switch (result) {
        .ok => std.debug.print("Success\n", .{}),
        .trap => |t| std.debug.print("Trap: {s}\n", .{t.code}),
    }
}
```

### Reactor Model

Initialize and call functions:

```zig
// Call _initialize if present
if (try instance.initializeReactor()) |result| {
    switch (result) {
        .trap => |t| return error.InitFailed,
        .ok => {},
    }
}

// Call exported function
const result = try instance.call("process", &args);
```

### Methods

| Method | Description |
|--------|-------------|
| `init(store, module, linker)` | Create instance |
| `deinit()` | Free instance |
| `runStartFunction()` | Run `_start` if present |
| `initializeReactor()` | Run `_initialize` if present |
| `call(name, args)` | Call exported function |
| `isCommand()` | Returns true if exports `_start` |
| `isReactor()` | Returns true if no `_start` export |

## Linker

The linker provides host functions to the instance.

### Creating Linker

```zig
var linker = wasmz.Linker.empty;
defer linker.deinit(allocator);
```

### Adding Host Functions

```zig
fn host_add(ctx: ?*anyopaque, hc: *wasmz.HostContext, params: []const wasmz.RawVal, results: []wasmz.RawVal) wasmz.HostError!void {
    const a = params[0].readAs(i32);
    const b = params[1].readAs(i32);
    results[0] = wasmz.RawVal.from(a + b);
}

try linker.define(allocator, "env", "add", wasmz.HostFunc.init(
    null,
    host_add,
    &[_]wasmz.ValType{ .I32, .I32 },
    &[_]wasmz.ValType{.I32},
));
```

## RawVal

Generic value type for all numeric WASM types:

```zig
const RawVal = wasmz.RawVal;

// Creating values
const v1 = RawVal.from(@as(i32, 42));
const v2 = RawVal.from(@as(i64, 1000000));
const v3 = RawVal.from(@as(f32, 3.14));
const v4 = RawVal.from(@as(f64, 3.14159265359));

// Reading values
const i = v1.readAs(i32);
const j = v2.readAs(i64);
const f = v3.readAs(f32);
const d = v4.readAs(f64);
```

## ExecResult

Result of function execution:

```zig
const result = try instance.call("add", &.{ v1, v2 });

switch (result) {
    .ok => |val| {
        if (val) |v| {
            std.debug.print("Result: {d}\n", .{v.readAs(i32)});
        }
    },
    .trap => |t| {
        std.debug.print("Trap: {s}\n", .{@tagName(t.code)});
    },
}
```

## Complete Example

```zig
const std = @import("std");
const wasmz = @import("wasmz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try wasmz.Engine.init(allocator, .{});
    defer engine.deinit();

    const bytes = try std.fs.cwd().readFileAlloc(allocator, "add.wasm", 1024 * 1024);
    defer allocator.free(bytes);

    var module = try wasmz.Module.compile(engine, bytes);
    defer module.deinit();

    var store = try wasmz.Store.init(allocator, engine);
    defer store.deinit();

    var instance = try wasmz.Instance.init(&store, module, .empty);
    defer instance.deinit();

    const result = try instance.call("add", &.{
        RawVal.from(@as(i32, 3)),
        RawVal.from(@as(i32, 4)),
    });

    if (result.ok) |val| {
        std.debug.print("3 + 4 = {d}\n", .{val.readAs(i32)});
    }
}
```

## Thread Safety

- **Store** - Not thread-safe. Contains GC heap and mutable runtime state.
- **Instance** - Not thread-safe. Contains globals, memory, and execution state.

Create separate Store/Instance per thread for parallel execution. The ArcModule reference can be safely shared (retain/release is atomic), but each thread should have its own Store and Instance.

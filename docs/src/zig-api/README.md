# Zig API

This section documents the Zig API for embedding wasmz in your applications.

## Overview

```zig
const std = @import("std");
const wasmz = @import("wasmz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create engine
    var engine = try wasmz.Engine.init(allocator, .{});
    defer engine.deinit();

    // Compile module
    const bytes = try std.fs.cwd().readFileAlloc(allocator, "module.wasm", 1024 * 1024);
    defer allocator.free(bytes);

    var module = try wasmz.Module.compile(engine, bytes);
    defer module.deinit();

    // Create store and instance
    var store = try wasmz.Store.init(allocator, engine);
    defer store.deinit();

    var instance = try wasmz.Instance.init(&store, module, .empty);
    defer instance.deinit();

    // Call function
    const result = try instance.call("add", &.{ .{ .i32 = 1 }, .{ .i32 = 2 } });
    std.debug.print("Result: {d}\n", .{result.ok.?.readAs(i32)});
}
```

## Core Types

| Type | Description |
|------|-------------|
| `Engine` | Runtime engine with configuration |
| `Config` | Engine configuration options |
| `Module` | Compiled WebAssembly module |
| `Store` | Runtime context for instances |
| `Instance` | Instantiated module with memory/globals |
| `Linker` | Host function registry |
| `HostFunc` | Host-provided callable |
| `RawVal` | Generic value (i32/i64/f32/f64) |
| `ExecResult` | Execution result (ok or trap) |
| `Trap` | Runtime trap with code |

## Next Steps

- [Engine & Config](./engine.md) - Setting up the runtime
- [Module](./module.md) - Compiling WebAssembly
- [Store & Instance](./instance.md) - Running modules
- [Linker & Host Functions](./linker.md) - Host integration
- [Error Handling](./errors.md) - Traps and errors

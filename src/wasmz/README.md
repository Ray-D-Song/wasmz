var engine = try Engine.init(allocator, .{});
defer engine.deinit();

const wasm_bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_size);
var module = try Module.compile(engine, wasm_bytes);
defer module.deinit();

var store = Store.init(allocator, engine);
defer store.deinit();

var instance = try Instance.init(&store, module, imports);

const result = try instance.call("add", &.{ .{ .i32 = 1 }, .{ .i32 = 2 } });
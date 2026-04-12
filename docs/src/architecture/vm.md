# VM & Execution

The virtual machine executes compiled IR.

## Execution Model

The VM is a register-based interpreter:

1. Load compiled bytecode
2. Execute instructions sequentially
3. Handle branches and calls
4. Return results or traps

## Key Components

### Function Execution

```zig
pub fn executeFunction(
    store: *Store,
    func: *const Func,
    args: []const RawVal,
) ExecResult {
    // Setup frame
    // Execute instructions
    // Return result
}
```

### Instruction Dispatch

```zig
switch (opcode) {
    .I32Add => {
        const a = frame.getRegister(inst.src1).readAs(i32);
        const b = frame.getRegister(inst.src2).readAs(i32);
        frame.setRegister(inst.dst, RawVal.from(a + b));
    },
    .Call => {
        // Handle function call
    },
    .Br => {
        // Handle branch
    },
    // ...
}
```

## Call Stack

Each call creates a frame:

```zig
const Frame = struct {
    return_ip: usize,
    return_frame: ?*Frame,
    locals: []RawVal,
    module: *const Module,
    func_index: u32,
};
```

## Memory

Linear memory is managed per-instance:

```zig
const Memory = struct {
    data: []u8,
    min: u32,
    max: ?u32,
    
    pub fn readByte(self: *Memory, offset: usize) u8;
    pub fn writeByte(self: *Memory, offset: usize, value: u8);
    pub fn grow(self: *Memory, pages: u32) !void;
};
```

## Table

Tables store function references for indirect calls:

```zig
const Table = struct {
    elements: []?FuncRef,
    min: u32,
    max: ?u32,
};
```

## Global

Globals store mutable state:

```zig
const Global = struct {
    value: RawVal,
    mutable: bool,
};
```

## Traps

Traps abort execution with an error code:

```zig
pub const TrapCode = enum {
    Unreachable,
    IntegerDivisionByZero,
    IntegerOverflow,
    // ...
};
```

## Key Files

| File | Purpose |
|------|---------|
| `src/vm/root.zig` | VM entry point, ExecResult |
| `src/engine/root.zig` | Engine implementation |
| `src/engine/func_ty.zig` | Function type handling |
| `src/engine/code_map.zig` | Compiled code storage |

## Branch Handling

Branches use continuation-passing style:

```zig
// br $label
// Jump to block label, pass values
const block = frame.getBlock(inst.label);
frame.setValues(block.params);
frame.ip = block.start;
```

## Function Calls

### Direct Calls

```zig
// call $func
const callee = module.getFunc(inst.func_index);
try pushFrame(callee, args);
```

### Indirect Calls

```zig
// call_indirect $type
const table_index = frame.getRegister(inst.src).readAs(u32);
const func_ref = table.elements[table_index];
const sig = module.types[inst.type_index];
if (!func_ref.signature.matches(sig)) {
    return Trap{ .code = .IndirectCallTypeMismatch };
}
try pushFrame(func_ref, args);
```

## Host Calls

Host functions are called through `HostFunc`:

```zig
pub const HostFunc = struct {
    context: ?*anyopaque,
    callback: *const fn (...) HostError!void,
    param_types: []const ValType,
    result_types: []const ValType,
};
```

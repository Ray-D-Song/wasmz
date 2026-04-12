# Compiler

The compiler transforms WebAssembly's stack machine into a register-based IR for efficient interpretation.

## Purpose

WebAssembly is a stack machine - values are pushed and popped from an operand stack. This is inefficient for interpretation. The compiler transforms this into a register-based IR where values are stored in named registers.

## Pipeline

```
WASM Bytes → Parser → Stack Instructions → Validator → Compiler → Register IR
                                                              ↓
                                                         Optimizer
                                                              ↓
                                                        Code Gen (bytecode)
```

## Lowering Process

### Stack Machine

```wasm
local.get 0
local.get 1
i32.add
local.set 2
```

### Register IR

```
r0 = local[0]
r1 = local[1]
r2 = i32_add(r0, r1)
local[2] = r2
```

## IR Structure

```zig
const IR = struct {
    instructions: []Instruction,
    registers: RegisterInfo,
    locals: []LocalInfo,
    blocks: []BlockInfo,
};

const Instruction = struct {
    opcode: Opcode,
    dst: ?Register,
    src1: ?Register,
    src2: ?Register,
    // ...
};
```

## Key Files

| File | Purpose |
|------|---------|
| `src/compiler/root.zig` | Compiler entry point |
| `src/compiler/ir.zig` | IR data structures |
| `src/compiler/translate.zig` | Stack-to-IR translation |
| `src/compiler/lower.zig` | Modern lowering |
| `src/compiler/lower_legacy.zig` | Legacy EH lowering |
| `src/compiler/value_stack.zig` | Simulated operand stack |

## Internal Checks

The compiler performs internal checks during lowering (not full WASM validation):

1. **Type checking** - Operands match instruction requirements
2. **Reachability** - Unreachable code is handled
3. **Block typing** - Block inputs/outputs match

> **Note**: These are runtime checks for compilation, not WASM specification validation. Use external tools for full validation.

## Block Handling

Blocks (block, loop, if) are compiled with:

- Separate register scopes
- Branch targets
- Result values

```zig
// block $b (result i32)
//   ... instructions ...
//   br $b (value)
// end
```

## Exception Handling

Two proposals are supported:

### New Proposal

```
try $label
  ... instructions ...
catch $label
  ... exception handler ...
end
```

### Legacy Proposal

```
try
  ... instructions ...
catch
  ... handler ...
rethrow
delegate $label
end
```

Controlled by `Config.legacy_exceptions`.

## Thread Safety

Compilation of function bodies can be parallelized:

```zig
// Each code section can be compiled independently
for (module.functions) |func, i| {
    // spawn thread for compile(func)
}
```

## SIMD

SIMD instructions are handled specially:

- Vector operations execute directly
- SIMD-specific lowering rules

See `src/core/simd/` for implementation.

## Optimization

Current optimizations:

1. **Dead code elimination** - Remove unreachable instructions
2. **Register coalescing** - Reduce register count
3. **Constant folding** - Evaluate constants at compile time

Future optimizations:

- Value numbering
- Common subexpression elimination

# Benchmark Report: wasmz vs wasmi vs wasm3 vs wamr

**Date:** 2026-04-16 09:54
**OS:** Linux 6.17.0-1010-azure x86_64
**Runs per benchmark:** 20 (warmup: 5)

## Versions

| Runtime | Version |
|---------|---------|
| wasmz   | dev (ReleaseFast) |
| wasmi   | wasmi 2.0.0-beta.2 |
| wasm3   | Wasm3 v0.5.1 on x86_64 |
| wamr    | iwasm 2.4.3 |

## Binary Size

| Runtime | Size |
|---------|------|
| wasmz   | 892.6 KB |
| wasmi   | 7.0 MB |
| wasm3   | 466.3 KB |
| wamr    | 344.8 KB |

## Execution Time (median ms) — lower is better

### fib(30) — pure C compiled to WASM

| Runtime | Median (ms) | ± stddev |
|---------|-------------|----------|
| wasmz   | 37.0 | ± 1.5 |
| wasmi   | 38.4 | ± 0.6 |
| wasm3   | 39.7 | ± 1.0 |
| wamr    | 49.6 | ± 1.7 |

### QuickJS fib(25) — JS engine running inside WASM (1.4 MB module)

| Runtime | Median (ms) | ± stddev |
|---------|-------------|----------|
| wasmz   | 174.9 | ± 3.4 |
| wasmi   | 184.4 | ± 2.9 |
| wasm3   | 217.4 | ± 8.2 |
| wamr    | 242.9 | ± 4.5 |

### esbuild — JS bundler running inside WASM (19 MB module)

> Note: wamr is excluded from esbuild tests because it does not support stdin input and causes stack overflow with large workloads.

| Runtime | Median (ms) | ± stddev |
|---------|-------------|----------|
| wasmz   | 909.5 | ± 12.5 |
| wasmi   | 918.2 | ± 19.9 |
| wasm3   | 2215.0 | ± 19.5 |

## Peak RSS (memory) — lower is better

> Peak RSS = highest resident set size seen at any point during the run.
> Avg RSS  = time-weighted mean RSS sampled every 100 ms during one run
>            (reflects actual memory consumption over the process lifetime, not just the spike).

### fib(30)

| Runtime | Peak RSS | Avg RSS |
|---------|----------|---------|
| wasmz   | 17.3 MB | 8.7 MB |
| wasmi   | 21.9 MB | 11.0 MB |
| wasm3   | 18.9 MB | 9.5 MB |
| wamr    | 11.0 MB | 5.4 MB |

### QuickJS fib(25)

| Runtime | Peak RSS | Avg RSS |
|---------|----------|---------|
| wasmz   | 1.8 MB | 1.2 MB |
| wasmi   | 1.8 MB | 1.2 MB |
| wasm3   | 1.8 MB | 1.2 MB |
| wamr    | 1.8 MB | 1.4 MB |

### esbuild bundling

> Note: wamr is excluded due to stdin/stack limitations.

| Runtime | Peak RSS | Avg RSS |
|---------|----------|---------|
| wasmz   | 1.8 MB | 1.6 MB |
| wasmi   | 1.8 MB | 1.6 MB |
| wasm3   | 1.8 MB | 1.7 MB |

---

## Performance Optimizations

The benchmark results above are the product of a series of targeted optimizations applied to wasmz's compiler and runtime. This section documents each technique.

### Register-Based IR (Stack-to-Register Lowering)

WebAssembly is a stack machine. wasmz translates every function's stack bytecode into a flat array of typed register-IR ops during compilation. Each op carries explicit source and destination *slot* indices (16-bit unsigned), eliminating the push/pop bookkeeping that stack interpreters must perform at runtime.

### Direct Threaded Code Dispatch

Rather than a traditional `switch`/`case` bytecode loop typical of high-level interpreters, wasmz uses **direct threaded code** (inspired by [Marr et al., 2023](https://stefan-marr.de/2023/06/squeezing-a-little-more-performance-out-of-bytecode-interpreters/)). Each encoded instruction contains an 8-byte handler pointer followed by its operands. After executing each handler, the `next()` macro issues a tail call directly to the next handler via its pointer, eliminating the overhead of:

- An explicit loop-condition check at the top of the bytecode loop
- A single branch-prediction site (which saturates on complex control flow)

This approach spreads branch prediction across multiple dispatch points, improving predictor accuracy on modern CPUs.

### r0 and fp0 Accumulator Registers

Inspired by the [Wasm3 M3](https://github.com/wasm3/wasm3) architecture, wasmz maintains two **accumulator registers**:

- **r0** — holds the most recent i32/i64 result
- **fp0** — holds the most recent f32/f64 result (f32 values are bit-cast to f64)

Handlers that produce a numeric result write it to both the accumulator *and* the destination slot. This allows the CPU to keep the top-of-stack value in a real hardware register across instruction boundaries, avoiding a slot load on every back-to-back arithmetic instruction. The `*_imm_r` variants and other fusions leverage this by reading from r0 implicitly.

### Superinstructions (Instruction Fusion)

The compiler performs a single forward pass over the IR and merges common multi-op patterns into one instruction. This reduces the total number of dispatched operations and removes redundant slot reads/writes.

The fused families currently implemented are:

| Label | Pattern | Fused Op |
|-------|---------|----------|
| C | `const + binop` | `binop_imm` — immediate rhs embedded in the instruction |
| D | `binop + local_set` | `binop_to_local` — result written directly to a local slot |
| E | `const + binop + local_set` | `binop_imm_to_local` |
| F | `compare + jump_if_z` | `compare_jump_if_false` — one dispatch for test-and-branch |
| G | `const + compare + br_if` | `compare_imm_jump_if_false` |
| H | `local_get + binop_imm + local_set` (same local) | `local_inplace` — mutates local in-place, no temp slot |
| I | `binop + ret` | `binop_ret` — compute and return in one dispatch |
| J | `compare_jump_if_false + jump` | `compare_jump_if_true` |
| K | `copy + jump_if_nz` | `copy_jump_if_nz` — essential for `br_if` with a result value |

Additional local-slot specialized fusions:

- **`binop_tee_local`** — writes the result to both a stack slot and a local (`local.tee` pattern)
- **`cmp_to_local`** — comparison result written directly to a local slot
- **`const_to_local`** — constant written directly to a local slot
- **`imm_to_local`** — superinstruction combining a constant-to-temp with a copy-to-local, preserving the source slot for downstream use
- **`load_to_local`** — i32/i64 memory load result written directly to a local
- **`global_get_to_local`** — global read result written directly to a local
- **`call_to_local`** — direct call result written directly to a local slot (saves one dispatch vs `call` + `local_set`)

### r0 Accumulator Variants

For long chains of `const + binop_imm` sequences (common in tight loops), the compiler tracks an *accumulator register* `r0`. When the previous instruction's destination matches the next instruction's source, the `lhs` slot field is elided from the encoding, producing `*_imm_r` variants. This shrinks the instruction and saves one memory load per dispatch.

### `call_leaf` Superinstruction

When a direct-call site is proven to target a *leaf function* (a function that makes no further calls itself) whose result is not used (void call), the compiler emits `call_leaf` instead of `call`. The VM handler skips result-slot setup and the return-value copy path entirely, reducing call overhead on hot void-dispatches.

### Slot Recycling

During lowering, temporary slots created for intermediate values are recycled once their last use is seen. This reduces the total `slots_len` per compiled function, which directly shrinks the value-stack frame allocated at call time.

### Lazy Compilation

Functions are compiled on their first invocation rather than all at once at `Module.compile()` time. For large modules (esbuild is 19 MB), this makes startup near-instant and amortises compilation cost over actual execution. The `--eager-compile` flag or `Config.eager_compile = true` opts into up-front compilation when predictable latency matters more than startup time.

### mmap-Based Memory

Two mmap optimizations reduce peak RSS:

1. **File mapping** — the `.wasm` file is memory-mapped rather than heap-copied. Pending (uncompiled) function bodies borrow slices directly from the mapped region, so the bytecode is never duplicated in the heap until compilation.

2. **Virtual reservation for linear memory** — when allocating WebAssembly linear memory, wasmz reserves a large virtual address range with `mmap(PROT_NONE)` and then commits pages with `mprotect` as the module calls `memory.grow`. This avoids the RSS spike that `realloc` produces when doubling a backing buffer.

### Lazy GC Heap Initialization

The GC heap inside `Store` is not allocated until the first GC-typed value is actually created. Modules that use only numeric types (MVP, no GC proposal) never touch the allocator, keeping RSS minimal.

### Lazy WASI Initialization

The WASI Preview 1 host is only instantiated when the module's import table contains at least one `wasi_snapshot_preview1` import. Pure compute modules pay no initialization overhead.

### Slot Width Reduction (u32 → u16)

All slot indices were narrowed from 32-bit to 16-bit integers. This halves the per-instruction slot storage for the most common instruction layouts, improving cache utilization in the hot interpreter loop.

### Handler Ordering (Future Work)

[Recent research](https://stefan-marr.de/2023/06/squeezing-a-little-more-performance-out-of-bytecode-interpreters/) has shown that the *order* of bytecode handler definitions in memory affects CPU branch-prediction performance, with potential speedups of 7–23% on specific benchmarks. Genetic algorithms can search for near-optimal orderings tailored to specific workloads and CPU architectures.

wasmz does not yet implement handler reordering, but the architecture (direct threaded code with multiple dispatch sites per handler) is well-suited for such optimization. The decision to prioritize other techniques first (superinstructions, accumulator registers, lazy compilation, mmap) reflects a pragmatic tradeoff: the gains from reducing dispatch *count* via fusion exceed what handler ordering alone typically provides, and fusion benefits apply uniformly across all workloads.

# C API

The C API allows embedding wasmz in any C-compatible language.

## Header

```c
#include <wasmz.h>
```

## Lifecycle

### Engine

```c
// Create engine with default configuration
wasmz_engine_t *engine = wasmz_engine_new();

// Create engine with a memory limit (bytes)
wasmz_engine_t *engine = wasmz_engine_new_with_limit(256 * 1024 * 1024);

// Destroy (must outlive all stores and modules)
wasmz_engine_delete(engine);
```

### Store

```c
wasmz_store_t *store = wasmz_store_new(engine);
// ... use store ...
wasmz_store_delete(store);
```

### Module

```c
uint8_t *bytes = /* pointer to .wasm bytes */;
size_t len     = /* number of bytes */;

wasmz_module_t *module = NULL;
wasmz_error_t *err = wasmz_module_new(engine, bytes, len, &module);
if (err) {
    fprintf(stderr, "Compile error: %s\n", wasmz_error_message(err));
    wasmz_error_delete(err);
    return 1;
}

// When done:
wasmz_module_delete(module);
```

### Instance

```c
// Without host imports
wasmz_instance_t *instance = NULL;
wasmz_error_t *err = wasmz_instance_new(store, module, &instance);

// With host imports (see Linker section below)
wasmz_error_t *err = wasmz_instance_new_with_linker(store, module, linker, &instance);

if (err) {
    fprintf(stderr, "Instantiate error: %s\n", wasmz_error_message(err));
    wasmz_error_delete(err);
    return 1;
}

// When done:
wasmz_instance_delete(instance);
```

## Values

```c
typedef enum {
    WASMZ_VAL_I32        = 0,
    WASMZ_VAL_I64        = 1,
    WASMZ_VAL_F32        = 2,
    WASMZ_VAL_F64        = 3,
    WASMZ_VAL_V128       = 4,
    WASMZ_VAL_REF_NULL   = 5,
    WASMZ_VAL_REF_FUNC   = 6,
    WASMZ_VAL_EXTERN_REF = 7,
} wasmz_val_kind_t;

typedef struct {
    wasmz_val_kind_t kind;
    uint8_t _pad[4];
    union {
        int32_t  i32;
        int64_t  i64;
        float    f32;
        double   f64;
        uint8_t  v128[16];   // 128-bit SIMD vector (little-endian lane order)
        uint32_t func_ref;
        void    *extern_ref;
    } of;
} wasmz_val_t;

// Convenience constructors
wasmz_val_t v = wasmz_val_i32(42);
wasmz_val_t v = wasmz_val_i64(1000000);
wasmz_val_t v = wasmz_val_f32(3.14f);
wasmz_val_t v = wasmz_val_f64(3.14159);
```

## Function Calls

### Command Model

```c
// Run _start
wasmz_error_t *err = wasmz_instance_call_start(instance);
if (err) {
    fprintf(stderr, "Error: %s\n", wasmz_error_message(err));
    wasmz_error_delete(err);
}
```

### Reactor Model

```c
// Initialize
wasmz_error_t *err = wasmz_instance_initialize(instance);
if (err) {
    fprintf(stderr, "Init error: %s\n", wasmz_error_message(err));
    wasmz_error_delete(err);
    return 1;
}

// Call a function
wasmz_val_t args[2] = { wasmz_val_i32(3), wasmz_val_i32(4) };
wasmz_val_t result;
err = wasmz_instance_call(instance, "add", args, 2, &result, 1);
if (err) {
    fprintf(stderr, "Call error: %s\n", wasmz_error_message(err));
    wasmz_error_delete(err);
    return 1;
}
printf("Result: %d\n", result.of.i32);
```

## Module Type Detection

```c
if (wasmz_instance_is_command(instance)) {
    // Has _start export — run once
    wasmz_instance_call_start(instance);
}

if (wasmz_instance_is_reactor(instance)) {
    // No _start export — library mode
    wasmz_instance_initialize(instance);
    wasmz_instance_call(instance, "func", args, n, results, m);
}
```

## Linker (Host Functions)

The linker lets you register host-provided functions that the WASM module can import.

### Creating a Linker

```c
wasmz_linker_t *linker = wasmz_linker_new();
// ... define functions and globals ...
// Pass to wasmz_instance_new_with_linker(), then:
wasmz_linker_delete(linker);
```

### Defining a Host Function

```c
// Callback type:
//   host_data   — opaque user pointer passed at registration
//   ctx         — host context; use wasmz_context_* to access memory
//   params      — input values (array of length param_count)
//   results     — output values to fill (array of length result_count)
//   return 0    — success; non-zero triggers a trap
int my_add(void *host_data, void *ctx,
           const wasmz_val_t *params, size_t param_count,
           wasmz_val_t *results,      size_t result_count)
{
    results[0] = wasmz_val_i32(params[0].of.i32 + params[1].of.i32);
    return 0;
}

wasmz_val_kind_t param_kinds[]  = { WASMZ_VAL_I32, WASMZ_VAL_I32 };
wasmz_val_kind_t result_kinds[] = { WASMZ_VAL_I32 };

wasmz_error_t *err = wasmz_linker_define_func(
    linker,
    "env", "add",           // import module :: function name
    param_kinds,  2,
    result_kinds, 1,
    my_add, NULL            // callback, optional user data
);
if (err) {
    fprintf(stderr, "define_func: %s\n", wasmz_error_message(err));
    wasmz_error_delete(err);
}
```

### Defining a Global Import

```c
wasmz_error_t *err = wasmz_linker_define_global(
    linker,
    "env", "my_global",
    wasmz_val_i32(42)
);
```

### Instantiating with a Linker

```c
wasmz_instance_t *instance = NULL;
wasmz_error_t *err = wasmz_instance_new_with_linker(store, module, linker, &instance);
if (err) {
    fprintf(stderr, "Instantiate error: %s\n", wasmz_error_message(err));
    wasmz_error_delete(err);
    return 1;
}
```

## Host Context

Inside a host function callback, use `wasmz_context_*` to safely read and write the WASM instance's linear memory:

```c
int host_strlen(void *host_data, void *ctx,
                const wasmz_val_t *params, size_t param_count,
                wasmz_val_t *results,      size_t result_count)
{
    uint32_t ptr = (uint32_t)params[0].of.i32;

    uint8_t *mem  = wasmz_context_memory(ctx);
    size_t   size = wasmz_context_memory_size(ctx);

    if (!mem || ptr >= size) {
        wasmz_context_trap(ctx, "out of bounds pointer");
        return 1;
    }

    int32_t len = 0;
    while (ptr + len < size && mem[ptr + len] != '\0') len++;

    results[0] = wasmz_val_i32(len);
    return 0;
}
```

### Context Functions

| Function | Description |
|----------|-------------|
| `wasmz_context_memory(ctx)` | Raw pointer to linear memory (`NULL` if none) |
| `wasmz_context_memory_size(ctx)` | Size of linear memory in bytes |
| `wasmz_context_read_memory(ctx, addr, len, out)` | Bounds-checked read (returns 0 on success) |
| `wasmz_context_write_memory(ctx, addr, data, len)` | Bounds-checked write (returns 0 on success) |
| `wasmz_context_read_value(ctx, addr, out, size)` | Read a typed value from memory |
| `wasmz_context_write_value(ctx, addr, value, size)` | Write a typed value to memory |
| `wasmz_context_trap(ctx, msg)` | Raise a trap from inside the callback |

## Linear Memory (from outside host functions)

You can also access an instance's memory after instantiation:

```c
uint8_t *mem  = wasmz_instance_memory(instance);        // NULL if no memory
size_t   size = wasmz_instance_memory_size(instance);

// Grow memory by pages (1 page = 64 KiB)
int32_t ok = wasmz_instance_memory_grow(instance, 1);   // 0 on success
```

## Module Introspection

```c
// Does the module define a linear memory?
int has_mem = wasmz_module_has_memory(module);

// Initial and maximum page counts
uint32_t min_pages = wasmz_module_memory_min(module);
uint32_t max_pages = wasmz_module_memory_max(module); // UINT32_MAX = unlimited

// Enumerate exported function names
size_t n = wasmz_module_export_count(module);
for (size_t i = 0; i < n; i++) {
    const char *name = wasmz_module_export_name(module, i);
    printf("export[%zu]: %s\n", i, name);
}
```

## Store User Data

Attach arbitrary state to a store for retrieval inside host callbacks:

```c
wasmz_store_set_user_data(store, my_state_ptr);
// ... later, inside a host function or after a call:
void *state = wasmz_store_get_user_data(store);
```

## VM Statistics

```c
wasmz_vm_stats_t stats;
wasmz_instance_vm_stats(instance, &stats);
printf("value stack : %zu bytes (%zu slots)\n",
       stats.val_stack_bytes, stats.val_stack_slots);
printf("call stack  : %zu bytes (%zu frames)\n",
       stats.call_stack_bytes, stats.call_stack_frames);
```

## Error Handling

All fallible functions return `wasmz_error_t *`. `NULL` means success.

```c
wasmz_error_t *err = wasmz_module_new(engine, bytes, len, &module);
if (err != NULL) {
    fprintf(stderr, "Error: %s\n", wasmz_error_message(err));
    wasmz_error_delete(err);
    return 1;
}
```

## Complete Example

```c
#include <stdio.h>
#include <stdlib.h>
#include "wasmz.h"

// Host function: prints an i32 from WASM
static int host_print(void *data, void *ctx,
                      const wasmz_val_t *params, size_t param_count,
                      wasmz_val_t *results,      size_t result_count)
{
    printf("wasm says: %d\n", params[0].of.i32);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <file.wasm>\n", argv[0]);
        return 1;
    }

    // Load file
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("fopen"); return 1; }
    fseek(f, 0, SEEK_END);
    size_t len = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *bytes = malloc(len);
    fread(bytes, 1, len, f);
    fclose(f);

    // Engine + store
    wasmz_engine_t *engine = wasmz_engine_new();
    wasmz_store_t  *store  = wasmz_store_new(engine);

    // Compile
    wasmz_module_t *module = NULL;
    wasmz_error_t  *err    = wasmz_module_new(engine, bytes, len, &module);
    free(bytes);
    if (err) {
        fprintf(stderr, "Compile: %s\n", wasmz_error_message(err));
        wasmz_error_delete(err);
        wasmz_store_delete(store);
        wasmz_engine_delete(engine);
        return 1;
    }

    // Register a host function and instantiate
    wasmz_linker_t *linker = wasmz_linker_new();
    wasmz_val_kind_t p[] = { WASMZ_VAL_I32 };
    err = wasmz_linker_define_func(linker, "env", "print", p, 1, NULL, 0, host_print, NULL);
    if (err) {
        fprintf(stderr, "define_func: %s\n", wasmz_error_message(err));
        wasmz_error_delete(err);
        goto cleanup;
    }

    wasmz_instance_t *instance = NULL;
    err = wasmz_instance_new_with_linker(store, module, linker, &instance);
    if (err) {
        fprintf(stderr, "Instantiate: %s\n", wasmz_error_message(err));
        wasmz_error_delete(err);
        goto cleanup;
    }

    // Run
    if (wasmz_instance_is_command(instance)) {
        err = wasmz_instance_call_start(instance);
    } else {
        err = wasmz_instance_initialize(instance);
        if (!err) {
            wasmz_val_t result;
            err = wasmz_instance_call(instance, "run", NULL, 0, &result, 0);
        }
    }
    if (err) {
        fprintf(stderr, "Runtime: %s\n", wasmz_error_message(err));
        wasmz_error_delete(err);
    }

    wasmz_instance_delete(instance);
cleanup:
    wasmz_linker_delete(linker);
    wasmz_module_delete(module);
    wasmz_store_delete(store);
    wasmz_engine_delete(engine);
    return 0;
}
```

## Building

```bash
# Build the C shared library
zig build clib

# Compile your program against it
gcc -o myapp myapp.c -Lzig-out/lib -lwasmz -Izig-out/include
```

## Thread Safety

- **Engine** — Reference counting is thread-safe. Do not access the same engine instance concurrently.
- **Module** — Reference counting is thread-safe. The module data is read-only after compilation and safe to share.
- **Store** — Not thread-safe. Contains GC heap and mutable runtime state.
- **Instance** — Not thread-safe. Contains mutable execution state.

For multi-threaded applications, create a separate Store and Instance per thread. Sharing a compiled Module across threads is safe.

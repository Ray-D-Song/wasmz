# C API

The C API allows embedding wasmz in any C-compatible language.

## Header

```c
#include <wasmz.h>
```

## Lifecycle

### Engine

```c
// Create engine
wasmz_engine_t *engine = wasmz_engine_new();

// With memory limit
wasmz_engine_t *engine = wasmz_engine_new_with_limit(256 * 1024 * 1024);

// Destroy
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
// Load bytes
uint8_t *bytes = /* ... */;
size_t len = /* ... */;

// Compile
wasmz_module_t *module = NULL;
wasmz_error_t *err = wasmz_module_new(engine, bytes, len, &module);
if (err) {
    printf("Error: %s\n", wasmz_error_message(err));
    wasmz_error_delete(err);
    return;
}

// Destroy
wasmz_module_delete(module);
```

### Instance

```c
wasmz_instance_t *instance = NULL;
wasmz_error_t *err = wasmz_instance_new(store, module, &instance);
if (err) {
    printf("Error: %s\n", wasmz_error_message(err));
    wasmz_error_delete(err);
    return;
}

// Destroy
wasmz_instance_delete(instance);
```

## Values

```c
typedef struct {
    wasmz_val_kind_t kind;  // I32, I64, F32, F64
    union {
        int32_t  i32;
        int64_t  i64;
        float    f32;
        double   f64;
    } of;
} wasmz_val_t;

// Constructors
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
    printf("Error: %s\n", wasmz_error_message(err));
    wasmz_error_delete(err);
}
```

### Reactor Model

```c
// Initialize
wasmz_error_t *err = wasmz_instance_initialize(instance);
if (err) {
    printf("Init error: %s\n", wasmz_error_message(err));
    wasmz_error_delete(err);
    return;
}

// Call function
wasmz_val_t args[2] = { wasmz_val_i32(3), wasmz_val_i32(4) };
wasmz_val_t result;

err = wasmz_instance_call(instance, "add", args, 2, &result, 1);
if (err) {
    printf("Call error: %s\n", wasmz_error_message(err));
    wasmz_error_delete(err);
    return;
}

printf("Result: %d\n", result.of.i32);
```

## Module Type Detection

```c
if (wasmz_instance_is_command(instance)) {
    // Has _start export
    wasmz_instance_call_start(instance);
}

if (wasmz_instance_is_reactor(instance)) {
    // No _start export - library mode
    wasmz_instance_initialize(instance);
    wasmz_instance_call(instance, "func", args, n, results, m);
}
```

## Error Handling

```c
// All functions return wasmz_error_t* on error
// NULL means success

wasmz_error_t *err = wasmz_module_new(engine, bytes, len, &module);
if (err != NULL) {
    const char *msg = wasmz_error_message(err);
    fprintf(stderr, "Error: %s\n", msg);
    wasmz_error_delete(err);
    return 1;
}
```

## Complete Example

```c
#include <stdio.h>
#include <stdlib.h>
#include "wasmz.h"

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <file.wasm>\n", argv[0]);
        return 1;
    }

    // Load file
    FILE *f = fopen(argv[1], "rb");
    if (!f) {
        perror("fopen");
        return 1;
    }
    fseek(f, 0, SEEK_END);
    size_t len = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *bytes = malloc(len);
    fread(bytes, 1, len, f);
    fclose(f);

    // Create engine, store, module
    wasmz_engine_t *engine = wasmz_engine_new();
    wasmz_store_t *store = wasmz_store_new(engine);
    
    wasmz_module_t *module = NULL;
    wasmz_error_t *err = wasmz_module_new(engine, bytes, len, &module);
    if (err) {
        fprintf(stderr, "Compile error: %s\n", wasmz_error_message(err));
        wasmz_error_delete(err);
        goto cleanup;
    }

    // Create instance
    wasmz_instance_t *instance = NULL;
    err = wasmz_instance_new(store, module, &instance);
    if (err) {
        fprintf(stderr, "Instantiate error: %s\n", wasmz_error_message(err));
        wasmz_error_delete(err);
        goto cleanup;
    }

    // Run _start or call function
    if (wasmz_instance_is_command(instance)) {
        err = wasmz_instance_call_start(instance);
        if (err) {
            fprintf(stderr, "Runtime error: %s\n", wasmz_error_message(err));
            wasmz_error_delete(err);
        }
    } else {
        err = wasmz_instance_initialize(instance);
        if (err) {
            fprintf(stderr, "Init error: %s\n", wasmz_error_message(err));
            wasmz_error_delete(err);
        }
        
        wasmz_val_t result;
        err = wasmz_instance_call(instance, "add", NULL, 0, &result, 0);
        if (err) {
            fprintf(stderr, "Call error: %s\n", wasmz_error_message(err));
            wasmz_error_delete(err);
        }
    }

    wasmz_instance_delete(instance);
    wasmz_module_delete(module);

cleanup:
    wasmz_store_delete(store);
    wasmz_engine_delete(engine);
    free(bytes);

    return 0;
}
```

## Building

```bash
# Build library
zig build clib

# Link against it
gcc -o myapp myapp.c -Lzig-out/lib -lwasmz -Izig-out/include
```

## Thread Safety

- **Engine** - Reference counting is thread-safe. Concurrent access to the same instance is not synchronized.
- **Module** - Reference counting is thread-safe. The underlying module data should not be accessed concurrently.
- **Store** - Not thread-safe. Contains GC heap and mutable state.
- **Instance** - Not thread-safe. Contains mutable execution state.

For multi-threaded applications, create separate Store and Instance per thread. Engine and Module handles can be shared safely (retain/release is atomic).

## Limitations

The C API is intentionally minimal. For full functionality, use the Zig API.

| Feature | C API | Zig API | Reason |
|---------|-------|---------|--------|
| Host function registration | ❌ | ✅ | Requires function pointer callbacks and type registration |
| GC reference types | ❌ | ✅ | `wasmz_val_t` only supports i32/i64/f32/f64 |
| SIMD (V128) | ❌ | ✅ | V128 requires 16 bytes, exceeds `wasmz_val_t` union size |

### Workarounds

- **Host functions**: Use Zig API with `Linker.define()`, or pre-compile WASM modules that don't require imports
- **GC types**: Current limitation - use numeric types only
- **SIMD**: Functions using SIMD can still be called, but values cannot be passed/returned through C API

/**
 * wasmz C API
 *
 * A minimal C API for embedding the wasmz WebAssembly interpreter.
 *
 * Lifecycle
 * ---------
 *   wasmz_engine_t  *engine   = wasmz_engine_new();
 *   wasmz_store_t   *store    = wasmz_store_new(engine);
 *   wasmz_module_t  *module   = wasmz_module_new(engine, bytes, len);
 *   wasmz_instance_t *inst    = wasmz_instance_new(store, module);
 *
 *   // Command model (_start):
 *   wasmz_instance_call_start(inst);
 *
 *   // Reactor model (_initialize + arbitrary calls):
 *   wasmz_instance_initialize(inst);
 *   wasmz_val_t args[2] = { wasmz_val_i32(3), wasmz_val_i32(4) };
 *   wasmz_val_t result;
 *   wasmz_instance_call(inst, "add", args, 2, &result, 1);
 *
 *   wasmz_instance_delete(inst);
 *   wasmz_module_delete(module);
 *   wasmz_store_delete(store);
 *   wasmz_engine_delete(engine);
 *
 * Error handling
 * --------------
 * Most functions that can fail return a `wasmz_error_t *`.
 * A NULL return value means success.
 * A non-NULL return value is a heap-allocated error that must be freed
 * with `wasmz_error_delete`.
 *
 * Thread safety
 * -------------
 * Engine, Store, Module, and Instance are NOT thread-safe.
 * Use separate engine/store/instance per thread.
 */

#ifndef WASMZ_H
#define WASMZ_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Opaque handle types ─────────────────────────────────────────────────── */

typedef struct wasmz_engine   wasmz_engine_t;
typedef struct wasmz_store    wasmz_store_t;
typedef struct wasmz_module   wasmz_module_t;
typedef struct wasmz_instance wasmz_instance_t;

/* ── Error type ──────────────────────────────────────────────────────────── */

/**
 * An opaque error object.  NULL means no error (success).
 * Non-NULL must be freed with wasmz_error_delete().
 */
typedef struct wasmz_error wasmz_error_t;

/** Free an error object returned by a wasmz function. */
void wasmz_error_delete(wasmz_error_t *error);

/**
 * Get the error message as a NUL-terminated UTF-8 string.
 * The returned pointer is valid until wasmz_error_delete() is called.
 * Returns "(null)" if error is NULL.
 */
const char *wasmz_error_message(const wasmz_error_t *error);

/* ── Value types ─────────────────────────────────────────────────────────── */

typedef enum {
    WASMZ_VAL_I32 = 0,
    WASMZ_VAL_I64 = 1,
    WASMZ_VAL_F32 = 2,
    WASMZ_VAL_F64 = 3,
} wasmz_val_kind_t;

/**
 * A WebAssembly value.  Only numeric types (i32/i64/f32/f64) are exposed
 * through the C API.  GC references and SIMD values are not supported.
 */
typedef struct {
    wasmz_val_kind_t kind;
    union {
        int32_t  i32;
        int64_t  i64;
        float    f32;
        double   f64;
    } of;
} wasmz_val_t;

/** Convenience constructors */
static inline wasmz_val_t wasmz_val_i32(int32_t v) {
    wasmz_val_t val;
    val.kind = WASMZ_VAL_I32;
    val.of.i32 = v;
    return val;
}
static inline wasmz_val_t wasmz_val_i64(int64_t v) {
    wasmz_val_t val;
    val.kind = WASMZ_VAL_I64;
    val.of.i64 = v;
    return val;
}
static inline wasmz_val_t wasmz_val_f32(float v) {
    wasmz_val_t val;
    val.kind = WASMZ_VAL_F32;
    val.of.f32 = v;
    return val;
}
static inline wasmz_val_t wasmz_val_f64(double v) {
    wasmz_val_t val;
    val.kind = WASMZ_VAL_F64;
    val.of.f64 = v;
    return val;
}

/* ── Engine ──────────────────────────────────────────────────────────────── */

/**
 * Create a new engine with default configuration.
 * Returns NULL on allocation failure.
 */
wasmz_engine_t *wasmz_engine_new(void);

/**
 * Create a new engine with a memory limit (in bytes).
 * Pass 0 for mem_limit_bytes to use no limit.
 */
wasmz_engine_t *wasmz_engine_new_with_limit(uint64_t mem_limit_bytes);

/** Destroy an engine. The engine must not be in use by any live store. */
void wasmz_engine_delete(wasmz_engine_t *engine);

/* ── Store ───────────────────────────────────────────────────────────────── */

/**
 * Create a new store associated with the given engine.
 * Returns NULL on allocation failure.
 */
wasmz_store_t *wasmz_store_new(wasmz_engine_t *engine);

/** Destroy a store.  All instances using this store must be destroyed first. */
void wasmz_store_delete(wasmz_store_t *store);

/* ── Module ──────────────────────────────────────────────────────────────── */

/**
 * Compile a WebAssembly module from raw bytes.
 *
 * @param engine   The engine to use for compilation.
 * @param bytes    Pointer to the raw .wasm binary data.
 * @param len      Length of the binary data in bytes.
 * @param out_module  Set to the compiled module on success (must be freed with
 *                    wasmz_module_delete when no longer needed).
 * @return NULL on success, non-NULL error on failure.
 */
wasmz_error_t *wasmz_module_new(
    wasmz_engine_t  *engine,
    const uint8_t   *bytes,
    size_t           len,
    wasmz_module_t **out_module
);

/** Destroy a module.  Safe to call after all instances using it are destroyed. */
void wasmz_module_delete(wasmz_module_t *module);

/* ── Instance ────────────────────────────────────────────────────────────── */

/**
 * Instantiate a module.
 *
 * This does NOT call `_start` or `_initialize` — call wasmz_instance_call_start()
 * or wasmz_instance_initialize() explicitly after instantiation.
 *
 * @param store       The store to create the instance in.
 * @param module      The compiled module.
 * @param out_instance  Set to the created instance on success.
 * @return NULL on success, non-NULL error on failure.
 */
wasmz_error_t *wasmz_instance_new(
    wasmz_store_t    *store,
    wasmz_module_t   *module,
    wasmz_instance_t **out_instance
);

/** Destroy an instance and free its resources. */
void wasmz_instance_delete(wasmz_instance_t *instance);

/**
 * Call the module's `_start` function (command model).
 *
 * @return NULL on success (including if `_start` is not exported),
 *         non-NULL on trap or error.
 */
wasmz_error_t *wasmz_instance_call_start(wasmz_instance_t *instance);

/**
 * Call the module's `_initialize` function (reactor model).
 *
 * @return NULL on success (including if `_initialize` is not exported),
 *         non-NULL on trap or error.
 */
wasmz_error_t *wasmz_instance_initialize(wasmz_instance_t *instance);

/**
 * Call an exported function by name.
 *
 * @param instance     The instance to call into.
 * @param func_name    NUL-terminated name of the exported function.
 * @param args         Array of input arguments (may be NULL if args_len == 0).
 * @param args_len     Number of arguments.
 * @param results      Array to receive return values (may be NULL if results_len == 0).
 * @param results_len  Expected number of return values (must match the function signature).
 * @return NULL on success, non-NULL on trap, export-not-found, or error.
 */
wasmz_error_t *wasmz_instance_call(
    wasmz_instance_t *instance,
    const char       *func_name,
    const wasmz_val_t *args,
    size_t             args_len,
    wasmz_val_t       *results,
    size_t             results_len
);

/**
 * Returns 1 if the module exports `_start` (command model), 0 otherwise.
 */
int wasmz_instance_is_command(const wasmz_instance_t *instance);

/**
 * Returns 1 if the module does NOT export `_start` (reactor / library model), 0 otherwise.
 */
int wasmz_instance_is_reactor(const wasmz_instance_t *instance);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* WASMZ_H */

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
    WASMZ_VAL_V128 = 4,
    WASMZ_VAL_REF_NULL = 5,
    WASMZ_VAL_REF_FUNC = 6,
    WASMZ_VAL_EXTERN_REF = 7,
} wasmz_val_kind_t;

/**
 * A WebAssembly value.  Supports i32/i64/f32/f64, V128, and reference types.
 */
typedef struct {
    wasmz_val_kind_t kind;
    uint8_t _pad[4];
    union {
        int32_t  i32;
        int64_t  i64;
        float    f32;
        double   f64;
        uint8_t v128[16];
        uint32_t func_ref;
        void *extern_ref;
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

/* ── Memory ─────────────────────────────────────────────────────────────────── */

/**
 * Get the linear memory data pointer.
 *
 * Returns NULL if the instance has no linear memory.
 * The returned pointer is valid for the lifetime of the instance.
 */
uint8_t *wasmz_instance_memory(wasmz_instance_t *instance);

/**
 * Get the size of the linear memory in bytes.
 * Returns 0 if the instance has no linear memory.
 */
size_t wasmz_instance_memory_size(const wasmz_instance_t *instance);

/**
 * Grow the linear memory by the specified number of pages.
 *
 * @param instance  The instance to grow.
 * @param pages    Number of 64 KiB pages to add.
 * @return 0 on success, non-zero error code on failure (invalid page count or OOM).
 */
int32_t wasmz_instance_memory_grow(wasmz_instance_t *instance, uint32_t pages);

/* ── Linker (host function registration) ─────────────────────────────────────── */

/**
 * A host function callback.
 *
 * @param host_data   Opaque user data provided to wasmz_linker_define.
 * @param ctx        Host context (use wasmz_context_* functions to access memory/globals).
 * @param params     Input parameters (array of length param_count).
 * @param results   Output results (array of length result_count).
 * @return 0 on success, non-zero to indicate a trap.
 */
typedef int (*wasmz_func_t)(
    void *host_data,
    void *ctx,
    const wasmz_val_t *params,
    size_t param_count,
    wasmz_val_t *results,
    size_t result_count
);

typedef struct wasmz_linker wasmz_linker_t;

/**
 * Create a new linker (empty, with no functions defined).
 */
wasmz_linker_t *wasmz_linker_new(void);

/**
 * Destroy a linker and free its resources.
 */
void wasmz_linker_delete(wasmz_linker_t *linker);

/**
 * Define a host function.
 *
 * @param linker       The linker to add the function to.
 * @param module_name Module name (e.g., "env", "wasi_snapshot_preview1").
 * @param func_name  Function name (e.g., "my_host_func").
 * @param param_kinds Array of value kinds for parameters (e.g., {WASMZ_VAL_I32, WASMZ_VAL_I64}).
 * @param param_count  Number of parameters.
 * @param result_kinds Array of value kinds for results.
 * @param result_count Number of results.
 * @param func       The host function callback.
 * @param host_data  Opaque user data passed to the callback.
 * @return NULL on success, non-NULL error on failure.
 */
wasmz_error_t *wasmz_linker_define_func(
    wasmz_linker_t *linker,
    const char *module_name,
    const char *func_name,
    const wasmz_val_kind_t *param_kinds,
    size_t param_count,
    const wasmz_val_kind_t *result_kinds,
    size_t result_count,
    wasmz_func_t func,
    void *host_data
);

/**
 * Define a global import.
 *
 * @param linker       The linker to add the global to.
 * @param module_name Module name.
 * @param global_name Global name.
 * @param value      Initial value for the global.
 */
wasmz_error_t *wasmz_linker_define_global(
    wasmz_linker_t *linker,
    const char *module_name,
    const char *global_name,
    wasmz_val_t value
);

/**
 * Instantiate a module with host imports from a linker.
 *
 * @param store       The store to create the instance in.
 * @param module     The compiled module.
 * @param linker     The linker providing host imports (may be NULL for no imports).
 * @param out_instance Set to the created instance on success.
 * @return NULL on success, non-NULL error on failure.
 */
wasmz_error_t *wasmz_instance_new_with_linker(
    wasmz_store_t *store,
    wasmz_module_t *module,
    wasmz_linker_t *linker,
    wasmz_instance_t **out_instance
);

/* ── Host Context (for host functions) ─────────────────────────────────── */

/**
 * Get the linear memory from a host context.
 * Returns NULL if the instance has no linear memory.
 */
uint8_t *wasmz_context_memory(void *ctx);

/**
 * Get the size of the linear memory in bytes.
 * Returns 0 if the instance has no linear memory.
 */
size_t wasmz_context_memory_size(void *ctx);

/**
 * Read bytes from linear memory.
 *
 * @param ctx   Host context.
 * @param addr  Memory address.
 * @param len   Number of bytes to read.
 * @param out  Output buffer (must be at least len bytes).
 * @return 0 on success, non-zero on out-of-bounds.
 */
int wasmz_context_read_memory(void *ctx, uint32_t addr, size_t len, uint8_t *out);

/**
 * Write bytes to linear memory.
 *
 * @param ctx   Host context.
 * @param addr  Memory address.
 * @param data Data to write.
 * @param len   Number of bytes to write.
 * @return 0 on success, non-zero on out-of-bounds.
 */
int wasmz_context_write_memory(void *ctx, uint32_t addr, const uint8_t *data, size_t len);

/**
 * Read a typed value from memory.
 *
 * @param ctx   Host context.
 * @param addr  Memory address.
 * @param out  Output value (must be large enough for the type).
 */
int wasmz_context_read_value(void *ctx, uint32_t addr, void *out, size_t size);

/**
 * Write a typed value to memory.
 *
 * @param ctx   Host context.
 * @param addr  Memory address.
 * @param value Value to write.
 * @param size  Size of the value in bytes.
 */
int wasmz_context_write_value(void *ctx, uint32_t addr, const void *value, size_t size);

/**
 * Raise a trap from a host function.
 *
 * @param ctx   Host context.
 * @param msg  Trap message (NUL-terminated).
 */
void wasmz_context_trap(void *ctx, const char *msg);

/* ── Module introspection ─────────────────────────────────────────────── */

/**
 * Check if a module has a memory section.
 * Returns 1 if the module has memory, 0 otherwise.
 */
int wasmz_module_has_memory(const wasmz_module_t *module);

/**
 * Get the module's memory minimum pages.
 * Returns 0 if the module has no memory.
 */
uint32_t wasmz_module_memory_min(const wasmz_module_t *module);

/**
 * Get the module's memory maximum pages.
 * Returns 0xFFFFFFFF (UINT32_MAX) if unlimited.
 */
uint32_t wasmz_module_memory_max(const wasmz_module_t *module);

/**
 * Get the number of exported functions.
 */
size_t wasmz_module_export_count(const wasmz_module_t *module);

/**
 * Get an exported function's name.
 *
 * @param module   The module.
 * @param index   Index (0 to export_count-1).
 * @return NUL-terminated name, or NULL if index out of bounds.
 *         The returned pointer is valid for the lifetime of the module.
 */
const char *wasmz_module_export_name(const wasmz_module_t *module, size_t index);

/* ── Store user data ────────────────────────────────────────────────── */

/**
 * Set user data on a store.
 */
void wasmz_store_set_user_data(wasmz_store_t *store, void *user_data);

/**
 * Get user data from a store.
 */
void *wasmz_store_get_user_data(wasmz_store_t *store);

/* ── VM statistics ─────────────────────────────────────────────────────── */

/**
 * Get VM memory statistics for an instance.
 */
typedef struct {
    size_t val_stack_bytes;
    size_t val_stack_slots;
    size_t call_stack_bytes;
    size_t call_stack_frames;
    size_t vm_alloc_count;
} wasmz_vm_stats_t;

void wasmz_instance_vm_stats(const wasmz_instance_t *instance, wasmz_vm_stats_t *out_stats);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* WASMZ_H */

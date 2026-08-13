/*
 * C API regression tests.
 *
 * Build and run with: zig build test-capi
 *
 * These tests exercise the C API the way an embedder does (see the wasmz-sys
 * bindings in the wasmi-benchmarks fork), covering the three things that are
 * invisible from Zig-only tests:
 *
 *   1. The `wasmz_val_t` layout agreed on by this header and the Zig side.
 *      A stride mismatch only shows up with more than one parameter, so the
 *      host function signatures here go up to WASI's 9-parameter `path_open`.
 *   2. Host functions defined through `wasmz_linker_define_func`.
 *   3. Handle teardown in any order — an embedder that frees the store before
 *      the instance must not corrupt the heap.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

#include "wasmz.h"

static int failures = 0;

#define CHECK(cond, ...)                                    \
    do {                                                    \
        if (!(cond)) {                                      \
            failures++;                                     \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                   \
            fprintf(stderr, "\n");                          \
        }                                                   \
    } while (0)

/* Fails the test and frees the error. Returns 1 when an error was present. */
static int check_ok(wasmz_error_t *err, const char *what)
{
    if (err == NULL) {
        return 0;
    }
    failures++;
    fprintf(stderr, "FAIL %s: %s\n", what, wasmz_error_message(err));
    wasmz_error_delete(err);
    return 1;
}

/* ── Test modules ───────────────────────────────────────────────────────── */

/*
 * (module
 *   (global $count (mut i32) (i32.const 0))
 *   (func (export "run") (param $n i32) (result i32)
 *     (global.set $count (local.get $n))
 *     (loop $continue
 *       (global.set $count (i32.sub (global.get $count) (i32.const 1)))
 *       (br_if $continue (global.get $count)))
 *     (global.get $count)))
 *
 * Mirrors res/wat/counter-global.wat from wasmi-benchmarks.
 */
static const uint8_t COUNTER_GLOBAL_WASM[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60,
    0x01, 0x7f, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x06, 0x06, 0x01, 0x7f,
    0x01, 0x41, 0x00, 0x0b, 0x07, 0x07, 0x01, 0x03, 0x72, 0x75, 0x6e, 0x00,
    0x00, 0x0a, 0x18, 0x01, 0x16, 0x00, 0x20, 0x00, 0x24, 0x00, 0x03, 0x40,
    0x23, 0x00, 0x41, 0x01, 0x6b, 0x24, 0x00, 0x23, 0x00, 0x0d, 0x00, 0x0b,
    0x23, 0x00, 0x0b,
};

/*
 * (module
 *   (import "wasi_snapshot_preview1" "path_open"
 *     (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
 *   (import "env" "mix" (func $mix (param i32 i64 f32 f64) (result i64)))
 *   (import "env" "sink" (func $sink (param i32)))
 *   (import "env" "boom" (func $boom (result i32)))
 *   (func (export "call_path_open") (result i32)
 *     (call $path_open (i32.const 11) (i32.const 22) (i32.const 33)
 *                      (i32.const 44) (i32.const 55)
 *                      (i64.const 0x1122334455667788)
 *                      (i64.const -0x0011223344556677)
 *                      (i32.const 88) (i32.const 99)))
 *   (func (export "call_mix") (result i64)
 *     (call $mix (i32.const 7) (i64.const 0x0123456789abcdef)
 *                (f32.const 1.5) (f64.const 2.25)))
 *   (func (export "call_sink") (call $sink (i32.const 1234)))
 *   (func (export "get_f32") (result f32) (f32.const 3.5))
 *   (func (export "call_boom") (result i32) (call $boom)))
 */
static const uint8_t HOST_IMPORTS_WASM[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x29, 0x07, 0x60,
    0x09, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7e, 0x7e, 0x7f, 0x7f, 0x01, 0x7f,
    0x60, 0x04, 0x7f, 0x7e, 0x7d, 0x7c, 0x01, 0x7e, 0x60, 0x01, 0x7f, 0x00,
    0x60, 0x00, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x7e, 0x60, 0x00, 0x00, 0x60,
    0x00, 0x01, 0x7d, 0x02, 0x44, 0x04, 0x16, 0x77, 0x61, 0x73, 0x69, 0x5f,
    0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65,
    0x76, 0x69, 0x65, 0x77, 0x31, 0x09, 0x70, 0x61, 0x74, 0x68, 0x5f, 0x6f,
    0x70, 0x65, 0x6e, 0x00, 0x00, 0x03, 0x65, 0x6e, 0x76, 0x03, 0x6d, 0x69,
    0x78, 0x00, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x04, 0x73, 0x69, 0x6e, 0x6b,
    0x00, 0x02, 0x03, 0x65, 0x6e, 0x76, 0x04, 0x62, 0x6f, 0x6f, 0x6d, 0x00,
    0x03, 0x03, 0x06, 0x05, 0x03, 0x04, 0x05, 0x06, 0x03, 0x07, 0x3f, 0x05,
    0x0e, 0x63, 0x61, 0x6c, 0x6c, 0x5f, 0x70, 0x61, 0x74, 0x68, 0x5f, 0x6f,
    0x70, 0x65, 0x6e, 0x00, 0x04, 0x08, 0x63, 0x61, 0x6c, 0x6c, 0x5f, 0x6d,
    0x69, 0x78, 0x00, 0x05, 0x09, 0x63, 0x61, 0x6c, 0x6c, 0x5f, 0x73, 0x69,
    0x6e, 0x6b, 0x00, 0x06, 0x07, 0x67, 0x65, 0x74, 0x5f, 0x66, 0x33, 0x32,
    0x00, 0x07, 0x09, 0x63, 0x61, 0x6c, 0x6c, 0x5f, 0x62, 0x6f, 0x6f, 0x6d,
    0x00, 0x08, 0x0a, 0x5d, 0x05, 0x27, 0x00, 0x41, 0x0b, 0x41, 0x16, 0x41,
    0x21, 0x41, 0x2c, 0x41, 0x37, 0x42, 0x88, 0xef, 0x99, 0xab, 0xc5, 0xe8,
    0x8c, 0x91, 0x11, 0x42, 0x89, 0xb3, 0xaa, 0xdd, 0xcb, 0xb9, 0xb7, 0x77,
    0x41, 0xd8, 0x00, 0x41, 0xe3, 0x00, 0x10, 0x00, 0x0b, 0x1e, 0x00, 0x41,
    0x07, 0x42, 0xef, 0x9b, 0xaf, 0xcd, 0xf8, 0xac, 0xd1, 0x91, 0x01, 0x43,
    0x00, 0x00, 0xc0, 0x3f, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
    0x40, 0x10, 0x01, 0x0b, 0x07, 0x00, 0x41, 0xd2, 0x09, 0x10, 0x02, 0x0b,
    0x07, 0x00, 0x43, 0x00, 0x00, 0x60, 0x40, 0x0b, 0x04, 0x00, 0x10, 0x03,
    0x0b,
};

#define PATH_OPEN_DIRFLAGS 0x1122334455667788LL
#define PATH_OPEN_OFLAGS  (-0x0011223344556677LL)
#define MIX_I64            0x0123456789abcdefLL

/* ── Host functions ─────────────────────────────────────────────────────── */

/* Distinct sentinels so a swapped host_data pointer is caught. */
static const int PATH_OPEN_TAG = 0xA1;
static const int MIX_TAG = 0xB2;
static const int SINK_TAG = 0xC3;

static int sink_seen = 0;

static int host_path_open(void *host_data, void *ctx, const wasmz_val_t *params,
                          size_t param_count, wasmz_val_t *results, size_t result_count)
{
    (void)ctx;
    CHECK(host_data == &PATH_OPEN_TAG, "path_open: wrong host_data");
    CHECK(param_count == 9, "path_open: param_count = %zu", param_count);
    CHECK(result_count == 1, "path_open: result_count = %zu", result_count);

    const int32_t expected_i32[5] = { 11, 22, 33, 44, 55 };
    for (size_t i = 0; i < 5; i++) {
        CHECK(params[i].kind == WASMZ_VAL_I32, "path_open: param %zu kind = %d", i, params[i].kind);
        CHECK(params[i].of.i32 == expected_i32[i], "path_open: param %zu = %d, want %d",
              i, params[i].of.i32, expected_i32[i]);
    }
    CHECK(params[5].kind == WASMZ_VAL_I64, "path_open: param 5 kind = %d", params[5].kind);
    CHECK(params[5].of.i64 == PATH_OPEN_DIRFLAGS, "path_open: param 5 = %lld",
          (long long)params[5].of.i64);
    CHECK(params[6].kind == WASMZ_VAL_I64, "path_open: param 6 kind = %d", params[6].kind);
    CHECK(params[6].of.i64 == PATH_OPEN_OFLAGS, "path_open: param 6 = %lld",
          (long long)params[6].of.i64);
    CHECK(params[7].of.i32 == 88, "path_open: param 7 = %d", params[7].of.i32);
    CHECK(params[8].of.i32 == 99, "path_open: param 8 = %d", params[8].of.i32);

    results[0].kind = WASMZ_VAL_I32;
    results[0].of.i32 = 4242;
    return 0;
}

static int host_mix(void *host_data, void *ctx, const wasmz_val_t *params,
                    size_t param_count, wasmz_val_t *results, size_t result_count)
{
    (void)ctx;
    CHECK(host_data == &MIX_TAG, "mix: wrong host_data");
    CHECK(param_count == 4, "mix: param_count = %zu", param_count);
    CHECK(result_count == 1, "mix: result_count = %zu", result_count);

    CHECK(params[0].kind == WASMZ_VAL_I32 && params[0].of.i32 == 7, "mix: param 0");
    CHECK(params[1].kind == WASMZ_VAL_I64 && params[1].of.i64 == MIX_I64, "mix: param 1 = %lld",
          (long long)params[1].of.i64);
    CHECK(params[2].kind == WASMZ_VAL_F32 && params[2].of.f32 == 1.5f, "mix: param 2 = %f",
          (double)params[2].of.f32);
    CHECK(params[3].kind == WASMZ_VAL_F64 && params[3].of.f64 == 2.25, "mix: param 3 = %f",
          params[3].of.f64);

    results[0].kind = WASMZ_VAL_I64;
    results[0].of.i64 = 0x7fedcba987654321LL;
    return 0;
}

static int host_sink(void *host_data, void *ctx, const wasmz_val_t *params,
                     size_t param_count, wasmz_val_t *results, size_t result_count)
{
    (void)ctx;
    (void)results;
    CHECK(host_data == &SINK_TAG, "sink: wrong host_data");
    CHECK(param_count == 1, "sink: param_count = %zu", param_count);
    CHECK(result_count == 0, "sink: result_count = %zu", result_count);
    CHECK(params[0].of.i32 == 1234, "sink: param 0 = %d", params[0].of.i32);
    sink_seen++;
    return 0;
}

static int host_boom(void *host_data, void *ctx, const wasmz_val_t *params,
                     size_t param_count, wasmz_val_t *results, size_t result_count)
{
    (void)host_data;
    (void)params;
    (void)param_count;
    (void)results;
    (void)result_count;
    wasmz_context_trap(ctx, "boom from host");
    return 1;
}

/* ── Tests ──────────────────────────────────────────────────────────────── */

static void test_val_abi(void)
{
    /* The Zig side asserts the same numbers; keep both ends honest. */
    CHECK(sizeof(wasmz_val_t) == 24, "sizeof(wasmz_val_t) = %zu", sizeof(wasmz_val_t));
    CHECK(offsetof(wasmz_val_t, kind) == 0, "offsetof(kind) = %zu", offsetof(wasmz_val_t, kind));
    CHECK(offsetof(wasmz_val_t, of) == 8, "offsetof(of) = %zu", offsetof(wasmz_val_t, of));
}

static wasmz_linker_t *make_host_linker(void)
{
    static const wasmz_val_kind_t path_open_params[9] = {
        WASMZ_VAL_I32, WASMZ_VAL_I32, WASMZ_VAL_I32, WASMZ_VAL_I32, WASMZ_VAL_I32,
        WASMZ_VAL_I64, WASMZ_VAL_I64, WASMZ_VAL_I32, WASMZ_VAL_I32,
    };
    static const wasmz_val_kind_t mix_params[4] = {
        WASMZ_VAL_I32, WASMZ_VAL_I64, WASMZ_VAL_F32, WASMZ_VAL_F64,
    };
    static const wasmz_val_kind_t one_i32[1] = { WASMZ_VAL_I32 };
    static const wasmz_val_kind_t one_i64[1] = { WASMZ_VAL_I64 };

    wasmz_linker_t *linker = wasmz_linker_new();
    CHECK(linker != NULL, "wasmz_linker_new returned NULL");
    if (linker == NULL) {
        return NULL;
    }

    check_ok(wasmz_linker_define_func(linker, "wasi_snapshot_preview1", "path_open",
                                      path_open_params, 9, one_i32, 1,
                                      host_path_open, (void *)&PATH_OPEN_TAG),
             "define path_open");
    check_ok(wasmz_linker_define_func(linker, "env", "mix", mix_params, 4, one_i64, 1,
                                      host_mix, (void *)&MIX_TAG),
             "define mix");
    check_ok(wasmz_linker_define_func(linker, "env", "sink", one_i32, 1, NULL, 0,
                                      host_sink, (void *)&SINK_TAG),
             "define sink");
    check_ok(wasmz_linker_define_func(linker, "env", "boom", NULL, 0, one_i32, 1,
                                      host_boom, NULL),
             "define boom");
    return linker;
}

static void test_host_functions(void)
{
    wasmz_engine_t *engine = wasmz_engine_new();
    wasmz_store_t *store = wasmz_store_new(engine);
    wasmz_module_t *module = NULL;
    wasmz_instance_t *inst = NULL;
    wasmz_linker_t *linker = make_host_linker();

    if (check_ok(wasmz_module_new(engine, HOST_IMPORTS_WASM, sizeof(HOST_IMPORTS_WASM), &module),
                 "compile host imports module")) {
        goto cleanup;
    }
    if (check_ok(wasmz_instance_new_with_linker(store, module, linker, &inst),
                 "instantiate host imports module")) {
        goto cleanup;
    }

    wasmz_val_t result;

    result = wasmz_val_i32(0);
    if (!check_ok(wasmz_instance_call(inst, "call_path_open", NULL, 0, &result, 1),
                  "call_path_open")) {
        CHECK(result.of.i32 == 4242, "call_path_open returned %d", result.of.i32);
    }

    result = wasmz_val_i64(0);
    if (!check_ok(wasmz_instance_call(inst, "call_mix", NULL, 0, &result, 1), "call_mix")) {
        CHECK(result.of.i64 == 0x7fedcba987654321LL, "call_mix returned %lld",
              (long long)result.of.i64);
    }

    sink_seen = 0;
    check_ok(wasmz_instance_call(inst, "call_sink", NULL, 0, NULL, 0), "call_sink");
    CHECK(sink_seen == 1, "sink called %d times", sink_seen);

    /* CoreMark's `run` returns f32; the caller tags the slot and gets it back. */
    result = wasmz_val_f32(0.0f);
    if (!check_ok(wasmz_instance_call(inst, "get_f32", NULL, 0, &result, 1), "get_f32")) {
        CHECK(result.kind == WASMZ_VAL_F32, "get_f32 result kind = %d", result.kind);
        CHECK(result.of.f32 == 3.5f, "get_f32 returned %f", (double)result.of.f32);
    }

    /* A non-zero return from a host function must surface as a trap. */
    result = wasmz_val_i32(0);
    wasmz_error_t *trap = wasmz_instance_call(inst, "call_boom", NULL, 0, &result, 1);
    CHECK(trap != NULL, "call_boom did not trap");
    if (trap != NULL) {
        wasmz_error_delete(trap);
    }

cleanup:
    wasmz_instance_delete(inst);
    wasmz_module_delete(module);
    wasmz_linker_delete(linker);
    wasmz_store_delete(store);
    wasmz_engine_delete(engine);
}

/* Rejecting multi-value keeps callers from reading uninitialized slots. */
static void test_multivalue_rejected(void)
{
    wasmz_engine_t *engine = wasmz_engine_new();
    wasmz_store_t *store = wasmz_store_new(engine);
    wasmz_module_t *module = NULL;
    wasmz_instance_t *inst = NULL;

    if (!check_ok(wasmz_module_new(engine, COUNTER_GLOBAL_WASM, sizeof(COUNTER_GLOBAL_WASM), &module),
                  "compile counter-global") &&
        !check_ok(wasmz_instance_new(store, module, &inst), "instantiate counter-global")) {
        wasmz_val_t args[1] = { wasmz_val_i32(4) };
        wasmz_val_t results[2] = { wasmz_val_i32(0), wasmz_val_i32(0) };
        wasmz_error_t *err = wasmz_instance_call(inst, "run", args, 1, results, 2);
        CHECK(err != NULL, "multi-value call was not rejected");
        if (err != NULL) {
            wasmz_error_delete(err);
        }
    }

    wasmz_instance_delete(inst);
    wasmz_module_delete(module);
    wasmz_store_delete(store);
    wasmz_engine_delete(engine);
}

/*
 * The store is reference counted, so both teardown orders must be safe.
 * `store_first` reproduces what Rust does when `Store` is declared before
 * `Instance` in a struct: fields drop in declaration order.
 */
static void run_counter_global(int iterations, int store_first)
{
    wasmz_engine_t *engine = wasmz_engine_new();
    CHECK(engine != NULL, "wasmz_engine_new returned NULL");

    for (int i = 0; i < iterations; i++) {
        wasmz_store_t *store = wasmz_store_new(engine);
        wasmz_module_t *module = NULL;
        wasmz_instance_t *inst = NULL;

        if (check_ok(wasmz_module_new(engine, COUNTER_GLOBAL_WASM, sizeof(COUNTER_GLOBAL_WASM), &module),
                     "compile counter-global")) {
            wasmz_store_delete(store);
            break;
        }
        if (check_ok(wasmz_instance_new(store, module, &inst), "instantiate counter-global")) {
            wasmz_module_delete(module);
            wasmz_store_delete(store);
            break;
        }

        wasmz_val_t args[1] = { wasmz_val_i32(1000) };
        wasmz_val_t result = wasmz_val_i32(-1);
        if (check_ok(wasmz_instance_call(inst, "run", args, 1, &result, 1), "call run")) {
            break;
        }
        if (result.of.i32 != 0) {
            CHECK(0, "run(1000) = %d, want 0", result.of.i32);
            break;
        }

        if (store_first) {
            wasmz_store_delete(store);
            wasmz_module_delete(module);
            wasmz_instance_delete(inst);
        } else {
            wasmz_instance_delete(inst);
            wasmz_module_delete(module);
            wasmz_store_delete(store);
        }
    }

    wasmz_engine_delete(engine);
}

int main(void)
{
    test_val_abi();
    test_host_functions();
    test_multivalue_rejected();
    run_counter_global(300, 0);
    run_counter_global(300, 1);

    if (failures != 0) {
        fprintf(stderr, "\n%d check(s) failed\n", failures);
        return 1;
    }
    printf("all C API tests passed\n");
    return 0;
}

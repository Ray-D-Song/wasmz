//! Raw Rust declarations for the wasmz C API.
#![allow(non_camel_case_types, non_snake_case, dead_code)]

use std::os::raw::{c_char, c_int, c_void};

pub type wasmz_engine_t = c_void;
pub type wasmz_store_t = c_void;
pub type wasmz_module_t = c_void;
pub type wasmz_instance_t = c_void;
pub type wasmz_linker_t = c_void;
pub type wasmz_error_t = c_void;
pub type wasmz_memory_t = c_void;
pub type wasmz_global_t = c_void;
pub type wasmz_table_t = c_void;
pub type wasmz_table_host_func_t = c_void;
pub type wasmz_wasi_host_t = c_void;

#[repr(C)]
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum wasmz_error_kind_t {
    WASMZ_ERR_UNKNOWN = 0,
    WASMZ_ERR_COMPILE = 1,
    WASMZ_ERR_LINK = 2,
    WASMZ_ERR_RUNTIME = 3,
    WASMZ_ERR_HOST_TRAP = 4,
}

#[repr(C)]
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum wasmz_val_kind_t {
    WASMZ_VAL_I32 = 0,
    WASMZ_VAL_I64 = 1,
    WASMZ_VAL_F32 = 2,
    WASMZ_VAL_F64 = 3,
    WASMZ_VAL_V128 = 4,
    WASMZ_VAL_REF_NULL = 5,
    WASMZ_VAL_REF_FUNC = 6,
    WASMZ_VAL_EXTERN_REF = 7,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct wasmz_val_t {
    pub kind: wasmz_val_kind_t,
    pub _pad: [u8; 4],
    pub of: wasmz_val_union,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub union wasmz_val_union {
    pub i32: i32,
    pub i64: i64,
    pub f32: f32,
    pub f64: f64,
    pub v128: [u8; 16],
    pub func_ref: u32,
    pub extern_ref: *mut c_void,
}

// Must match `wasmz_val_t` in wasmz's include/wasmz.h and src/capi.zig, which
// assert the same numbers. A stride mismatch is invisible for single-value
// calls and corrupts every host function that takes more than one parameter.
const _: () = assert!(core::mem::size_of::<wasmz_val_t>() == 24);
const _: () = assert!(core::mem::align_of::<wasmz_val_t>() == 8);
const _: () = assert!(core::mem::offset_of!(wasmz_val_t, kind) == 0);
const _: () = assert!(core::mem::offset_of!(wasmz_val_t, of) == 8);

pub type wasmz_func_t = Option<
    unsafe extern "C" fn(
        host_data: *mut c_void,
        ctx: *mut c_void,
        params: *const wasmz_val_t,
        param_count: usize,
        results: *mut wasmz_val_t,
        result_count: usize,
    ) -> c_int,
>;

unsafe extern "C" {
    pub fn wasmz_error_delete(error: *mut wasmz_error_t);
    pub fn wasmz_error_message(error: *const wasmz_error_t) -> *const c_char;
    pub fn wasmz_error_kind(error: *const wasmz_error_t) -> wasmz_error_kind_t;

    pub fn wasmz_engine_new() -> *mut wasmz_engine_t;
    pub fn wasmz_engine_new_with_limit(mem_limit_bytes: u64) -> *mut wasmz_engine_t;
    pub fn wasmz_engine_delete(engine: *mut wasmz_engine_t);

    pub fn wasmz_store_new(engine: *mut wasmz_engine_t) -> *mut wasmz_store_t;
    pub fn wasmz_store_delete(store: *mut wasmz_store_t);

    pub fn wasmz_validate(bytes: *const u8, len: usize) -> *mut wasmz_error_t;
    pub fn wasmz_validate_with_engine(
        engine: *mut wasmz_engine_t,
        bytes: *const u8,
        len: usize,
    ) -> *mut wasmz_error_t;

    pub fn wasmz_module_new(
        engine: *mut wasmz_engine_t,
        bytes: *const u8,
        len: usize,
        out_module: *mut *mut wasmz_module_t,
    ) -> *mut wasmz_error_t;
    pub fn wasmz_module_delete(module: *mut wasmz_module_t);

    pub fn wasmz_instance_new(
        store: *mut wasmz_store_t,
        module: *mut wasmz_module_t,
        out_instance: *mut *mut wasmz_instance_t,
    ) -> *mut wasmz_error_t;
    pub fn wasmz_instance_new_with_linker(
        store: *mut wasmz_store_t,
        module: *mut wasmz_module_t,
        linker: *mut wasmz_linker_t,
        out_instance: *mut *mut wasmz_instance_t,
    ) -> *mut wasmz_error_t;
    pub fn wasmz_instance_delete(instance: *mut wasmz_instance_t);
    pub fn wasmz_instance_run_start(instance: *mut wasmz_instance_t) -> *mut wasmz_error_t;
    pub fn wasmz_instance_call_start(instance: *mut wasmz_instance_t) -> *mut wasmz_error_t;
    pub fn wasmz_instance_initialize(instance: *mut wasmz_instance_t) -> *mut wasmz_error_t;
    pub fn wasmz_instance_call(
        instance: *mut wasmz_instance_t,
        func_name: *const c_char,
        args: *const wasmz_val_t,
        args_len: usize,
        results: *mut wasmz_val_t,
        results_len: usize,
    ) -> *mut wasmz_error_t;
    pub fn wasmz_instance_call_index(
        instance: *mut wasmz_instance_t,
        func_index: u32,
        args: *const wasmz_val_t,
        args_len: usize,
        results: *mut wasmz_val_t,
        results_len: usize,
    ) -> *mut wasmz_error_t;
    pub fn wasmz_instance_id(instance: *const wasmz_instance_t) -> u64;
    pub fn wasmz_instance_export_func_info(
        instance: *const wasmz_instance_t,
        func_name: *const c_char,
        out_func_index: *mut u32,
        out_param_count: *mut usize,
        out_result_count: *mut usize,
    ) -> c_int;
    pub fn wasmz_instance_func_sig(
        instance: *const wasmz_instance_t,
        func_index: u32,
        out_params: *mut wasmz_val_kind_t,
        param_cap: usize,
        out_param_count: *mut usize,
        out_results: *mut wasmz_val_kind_t,
        result_cap: usize,
        out_result_count: *mut usize,
    ) -> c_int;

    pub fn wasmz_instance_memory(instance: *mut wasmz_instance_t) -> *mut u8;
    pub fn wasmz_instance_memory_size(instance: *mut wasmz_instance_t) -> usize;
    pub fn wasmz_instance_memory_grow(instance: *mut wasmz_instance_t, pages: u64) -> i32;
    pub fn wasmz_instance_memory64(instance: *const wasmz_instance_t) -> i32;

    pub fn wasmz_linker_new() -> *mut wasmz_linker_t;
    pub fn wasmz_linker_delete(linker: *mut wasmz_linker_t);
    pub fn wasmz_linker_define_func(
        linker: *mut wasmz_linker_t,
        module_name: *const c_char,
        func_name: *const c_char,
        param_kinds: *const wasmz_val_kind_t,
        param_count: usize,
        result_kinds: *const wasmz_val_kind_t,
        result_count: usize,
        func: wasmz_func_t,
        host_data: *mut c_void,
    ) -> *mut wasmz_error_t;
    pub fn wasmz_linker_define_global(
        linker: *mut wasmz_linker_t,
        module_name: *const c_char,
        global_name: *const c_char,
        value: wasmz_val_t,
    ) -> *mut wasmz_error_t;
    pub fn wasmz_linker_define_memory(
        linker: *mut wasmz_linker_t,
        module_name: *const c_char,
        field_name: *const c_char,
        mem: *mut wasmz_memory_t,
    ) -> *mut wasmz_error_t;
    pub fn wasmz_linker_define_global_handle(
        linker: *mut wasmz_linker_t,
        module_name: *const c_char,
        global_name: *const c_char,
        global: *mut wasmz_global_t,
    ) -> *mut wasmz_error_t;
    pub fn wasmz_linker_define_table(
        linker: *mut wasmz_linker_t,
        module_name: *const c_char,
        field_name: *const c_char,
        table: *mut wasmz_table_t,
    ) -> *mut wasmz_error_t;
    pub fn wasmz_linker_add_wasi(
        linker: *mut wasmz_linker_t,
        wasi: *mut wasmz_wasi_host_t,
    ) -> *mut wasmz_error_t;

    pub fn wasmz_context_trap(ctx: *mut c_void, msg: *const c_char);
    pub fn wasmz_context_memory(ctx: *mut c_void) -> *mut u8;
    pub fn wasmz_context_memory_size(ctx: *mut c_void) -> usize;

    pub fn wasmz_memory_new(
        initial: u64,
        max_pages: u64,
        has_max: c_int,
        is_shared: c_int,
        is_64: c_int,
        out_mem: *mut *mut wasmz_memory_t,
    ) -> *mut wasmz_error_t;
    pub fn wasmz_memory_clone(mem: *const wasmz_memory_t) -> *mut wasmz_memory_t;
    pub fn wasmz_memory_delete(mem: *mut wasmz_memory_t);
    pub fn wasmz_instance_export_memory(
        instance: *const wasmz_instance_t,
        name: *const c_char,
    ) -> *mut wasmz_memory_t;
    pub fn wasmz_memory_data(mem: *mut wasmz_memory_t) -> *mut u8;
    pub fn wasmz_memory_data_len(mem: *const wasmz_memory_t) -> usize;
    pub fn wasmz_memory_pages(mem: *const wasmz_memory_t) -> u64;
    pub fn wasmz_memory_min(mem: *const wasmz_memory_t) -> u64;
    pub fn wasmz_memory_max(mem: *const wasmz_memory_t, out_has_max: *mut c_int) -> u64;
    pub fn wasmz_memory_is_shared(mem: *const wasmz_memory_t) -> c_int;
    pub fn wasmz_memory_is_64(mem: *const wasmz_memory_t) -> c_int;
    pub fn wasmz_memory_grow_seq(mem: *const wasmz_memory_t) -> u64;
    pub fn wasmz_memory_identity(mem: *const wasmz_memory_t) -> u64;
    pub fn wasmz_memory_grow(
        mem: *mut wasmz_memory_t,
        delta: u64,
        out_prev_pages: *mut u64,
    ) -> c_int;

    pub fn wasmz_global_new(
        kind: wasmz_val_kind_t,
        is_mutable: c_int,
        initial: wasmz_val_t,
        out_global: *mut *mut wasmz_global_t,
    ) -> *mut wasmz_error_t;
    pub fn wasmz_global_clone(global: *const wasmz_global_t) -> *mut wasmz_global_t;
    pub fn wasmz_global_delete(global: *mut wasmz_global_t);
    pub fn wasmz_instance_export_global(
        instance: *const wasmz_instance_t,
        name: *const c_char,
    ) -> *mut wasmz_global_t;
    pub fn wasmz_global_kind(global: *const wasmz_global_t) -> wasmz_val_kind_t;
    pub fn wasmz_global_is_mutable(global: *const wasmz_global_t) -> c_int;
    pub fn wasmz_global_get(global: *const wasmz_global_t) -> wasmz_val_t;
    pub fn wasmz_global_identity(global: *const wasmz_global_t) -> u64;
    pub fn wasmz_global_set(
        global: *mut wasmz_global_t,
        value: wasmz_val_t,
    ) -> *mut wasmz_error_t;

    pub fn wasmz_table_new(
        elem_kind: wasmz_val_kind_t,
        initial: u32,
        max_len: u32,
        has_max: c_int,
        init_raw: u64,
        init_func_owner: *const wasmz_instance_t,
        init_func_idx: u32,
        out_table: *mut *mut wasmz_table_t,
    ) -> *mut wasmz_error_t;
    pub fn wasmz_table_clone(table: *const wasmz_table_t) -> *mut wasmz_table_t;
    pub fn wasmz_table_delete(table: *mut wasmz_table_t);
    pub fn wasmz_instance_export_table(
        instance: *const wasmz_instance_t,
        name: *const c_char,
    ) -> *mut wasmz_table_t;
    pub fn wasmz_table_len(table: *const wasmz_table_t) -> u32;
    pub fn wasmz_table_max(table: *const wasmz_table_t, out_has_max: *mut c_int) -> u32;
    pub fn wasmz_table_elem_kind(table: *const wasmz_table_t) -> wasmz_val_kind_t;
    pub fn wasmz_table_identity(table: *const wasmz_table_t) -> u64;
    pub fn wasmz_table_get_entry(
        table: *const wasmz_table_t,
        index: u32,
        out_is_null: *mut c_int,
        out_owner_id: *mut u64,
        out_func_idx: *mut u32,
        out_raw: *mut u64,
    ) -> c_int;
    pub fn wasmz_table_set_null(table: *mut wasmz_table_t, index: u32) -> c_int;
    pub fn wasmz_table_set_externref(table: *mut wasmz_table_t, index: u32, raw_ref: u64) -> c_int;
    pub fn wasmz_table_set_instance_func(
        table: *mut wasmz_table_t,
        index: u32,
        owner_inst: *const wasmz_instance_t,
        func_idx: u32,
    ) -> c_int;
    pub fn wasmz_table_grow(
        table: *mut wasmz_table_t,
        delta: u32,
        init_raw: u64,
        out_prev_len: *mut u32,
    ) -> c_int;
    pub fn wasmz_table_grow_instance_func(
        table: *mut wasmz_table_t,
        delta: u32,
        owner_inst: *const wasmz_instance_t,
        func_idx: u32,
        out_prev_len: *mut u32,
    ) -> c_int;
    pub fn wasmz_table_host_func_new(
        param_kinds: *const wasmz_val_kind_t,
        param_count: usize,
        result_kinds: *const wasmz_val_kind_t,
        result_count: usize,
        func: wasmz_func_t,
        host_data: *mut c_void,
        tag: u64,
        out_func: *mut *mut wasmz_table_host_func_t,
    ) -> *mut wasmz_error_t;
    pub fn wasmz_table_host_func_delete(func: *mut wasmz_table_host_func_t);
    pub fn wasmz_table_set_host_func(
        table: *mut wasmz_table_t,
        index: u32,
        func: *const wasmz_table_host_func_t,
    ) -> c_int;
    pub fn wasmz_table_grow_host_func(
        table: *mut wasmz_table_t,
        delta: u32,
        func: *const wasmz_table_host_func_t,
        out_prev_len: *mut u32,
    ) -> c_int;

    pub fn wasmz_wasi_host_new() -> *mut wasmz_wasi_host_t;
    pub fn wasmz_wasi_host_delete(wasi: *mut wasmz_wasi_host_t);
    pub fn wasmz_wasi_host_set_args(
        wasi: *mut wasmz_wasi_host_t,
        args: *const *const c_char,
        count: usize,
    ) -> *mut wasmz_error_t;
    pub fn wasmz_wasi_host_set_env(
        wasi: *mut wasmz_wasi_host_t,
        keys: *const *const c_char,
        values: *const *const c_char,
        count: usize,
    ) -> *mut wasmz_error_t;
    pub fn wasmz_wasi_host_add_preopen(
        wasi: *mut wasmz_wasi_host_t,
        guest_path: *const c_char,
        host_path: *const c_char,
    ) -> *mut wasmz_error_t;
    pub fn wasmz_wasi_host_set_stdio_fds(
        wasi: *mut wasmz_wasi_host_t,
        stdin_fd: i32,
        stdout_fd: i32,
        stderr_fd: i32,
    );
    pub fn wasmz_wasi_host_set_return_on_exit(
        wasi: *mut wasmz_wasi_host_t,
        return_on_exit: c_int,
    );
    pub fn wasmz_wasi_host_exit_code(
        wasi: *const wasmz_wasi_host_t,
        out_code: *mut u32,
    ) -> c_int;
}

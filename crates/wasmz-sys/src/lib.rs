//! Raw Rust declarations for the wasmz C API.
#![allow(non_camel_case_types, non_snake_case, dead_code)]

use std::os::raw::{c_char, c_int, c_void};

pub type wasmz_engine_t = c_void;
pub type wasmz_store_t = c_void;
pub type wasmz_module_t = c_void;
pub type wasmz_instance_t = c_void;
pub type wasmz_linker_t = c_void;
pub type wasmz_error_t = c_void;

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

    pub fn wasmz_engine_new() -> *mut wasmz_engine_t;
    pub fn wasmz_engine_new_with_limit(mem_limit_bytes: u64) -> *mut wasmz_engine_t;
    pub fn wasmz_engine_delete(engine: *mut wasmz_engine_t);

    pub fn wasmz_store_new(engine: *mut wasmz_engine_t) -> *mut wasmz_store_t;
    pub fn wasmz_store_delete(store: *mut wasmz_store_t);

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
    pub fn wasmz_instance_call_start(instance: *mut wasmz_instance_t) -> *mut wasmz_error_t;
    pub fn wasmz_instance_call(
        instance: *mut wasmz_instance_t,
        func_name: *const c_char,
        args: *const wasmz_val_t,
        args_len: usize,
        results: *mut wasmz_val_t,
        results_len: usize,
    ) -> *mut wasmz_error_t;

    pub fn wasmz_instance_memory(instance: *mut wasmz_instance_t) -> *mut u8;
    pub fn wasmz_instance_memory_size(instance: *mut wasmz_instance_t) -> usize;

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
}

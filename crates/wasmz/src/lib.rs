//! Rust bindings for the wasmz C API.

use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::fmt;
use std::os::raw::c_void;
use std::ptr;
use std::rc::Rc;
use std::slice;

use wasmz_sys as sys;
use wasmz_sys::{
    wasmz_context_memory, wasmz_context_memory_size, wasmz_context_trap, wasmz_engine_new,
    wasmz_engine_new_with_limit, wasmz_error_delete, wasmz_error_kind, wasmz_error_kind_t,
    wasmz_error_message, wasmz_global_clone, wasmz_global_delete, wasmz_global_get,
    wasmz_global_identity, wasmz_global_is_mutable, wasmz_global_kind, wasmz_global_new,
    wasmz_global_set, wasmz_instance_call, wasmz_instance_call_index, wasmz_instance_call_start,
    wasmz_instance_delete, wasmz_instance_export_func_info, wasmz_instance_export_global,
    wasmz_instance_export_memory, wasmz_instance_export_table, wasmz_instance_func_sig,
    wasmz_instance_id, wasmz_instance_initialize, wasmz_instance_memory,
    wasmz_instance_memory_grow, wasmz_instance_memory_size, wasmz_instance_memory64,
    wasmz_instance_new_with_linker, wasmz_instance_run_start, wasmz_linker_add_wasi,
    wasmz_linker_define_func, wasmz_linker_define_global_handle, wasmz_linker_define_memory,
    wasmz_linker_define_table, wasmz_linker_delete, wasmz_linker_new, wasmz_memory_clone,
    wasmz_memory_data, wasmz_memory_data_len, wasmz_memory_delete, wasmz_memory_grow,
    wasmz_memory_grow_seq, wasmz_memory_identity, wasmz_memory_is_64, wasmz_memory_is_shared,
    wasmz_memory_max, wasmz_memory_min, wasmz_memory_new, wasmz_memory_pages, wasmz_module_delete,
    wasmz_module_new, wasmz_store_delete, wasmz_store_new, wasmz_table_clone, wasmz_table_delete,
    wasmz_table_elem_kind, wasmz_table_get_entry, wasmz_table_grow, wasmz_table_grow_host_func,
    wasmz_table_grow_instance_func, wasmz_table_host_func_delete, wasmz_table_host_func_new,
    wasmz_table_identity, wasmz_table_len, wasmz_table_max, wasmz_table_new,
    wasmz_table_set_externref, wasmz_table_set_host_func, wasmz_table_set_instance_func,
    wasmz_table_set_null, wasmz_val_kind_t, wasmz_val_t, wasmz_validate, wasmz_validate_with_engine,
    wasmz_wasi_host_add_preopen, wasmz_wasi_host_delete, wasmz_wasi_host_exit_code,
    wasmz_wasi_host_new, wasmz_wasi_host_set_args, wasmz_wasi_host_set_env,
    wasmz_wasi_host_set_return_on_exit, wasmz_wasi_host_set_stdio_fds,
};

/// Coarse category of an error returned by wasmz.
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum ErrorKind {
    Unknown,
    Compile,
    Link,
    Runtime,
    HostTrap,
}

impl ErrorKind {
    fn from_c(kind: wasmz_error_kind_t) -> Self {
        match kind {
            wasmz_error_kind_t::WASMZ_ERR_COMPILE => Self::Compile,
            wasmz_error_kind_t::WASMZ_ERR_LINK => Self::Link,
            wasmz_error_kind_t::WASMZ_ERR_RUNTIME => Self::Runtime,
            wasmz_error_kind_t::WASMZ_ERR_HOST_TRAP => Self::HostTrap,
            wasmz_error_kind_t::WASMZ_ERR_UNKNOWN => Self::Unknown,
        }
    }
}

/// Error returned by wasmz operations.
#[derive(Debug)]
pub struct Error {
    kind: ErrorKind,
    message: String,
}

impl Error {
    fn from_ptr(ptr: *mut sys::wasmz_error_t) -> Self {
        if ptr.is_null() {
            return Self {
                kind: ErrorKind::Unknown,
                message: "unknown wasmz error".to_string(),
            };
        }
        let kind = ErrorKind::from_c(unsafe { wasmz_error_kind(ptr) });
        let msg = unsafe { CStr::from_ptr(wasmz_error_message(ptr)) };
        let message = msg.to_string_lossy().into_owned();
        unsafe { wasmz_error_delete(ptr) };
        Self { kind, message }
    }

    pub fn kind(&self) -> ErrorKind {
        self.kind
    }

    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.message.fmt(f)
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

/// WebAssembly value kind.
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum ValKind {
    I32,
    I64,
    F32,
    F64,
    FuncRef,
    ExternRef,
}

impl ValKind {
    fn to_c(self) -> wasmz_val_kind_t {
        match self {
            Self::I32 => wasmz_val_kind_t::WASMZ_VAL_I32,
            Self::I64 => wasmz_val_kind_t::WASMZ_VAL_I64,
            Self::F32 => wasmz_val_kind_t::WASMZ_VAL_F32,
            Self::F64 => wasmz_val_kind_t::WASMZ_VAL_F64,
            Self::FuncRef => wasmz_val_kind_t::WASMZ_VAL_REF_FUNC,
            Self::ExternRef => wasmz_val_kind_t::WASMZ_VAL_EXTERN_REF,
        }
    }

    fn from_c(kind: wasmz_val_kind_t) -> Option<Self> {
        match kind {
            wasmz_val_kind_t::WASMZ_VAL_I32 => Some(Self::I32),
            wasmz_val_kind_t::WASMZ_VAL_I64 => Some(Self::I64),
            wasmz_val_kind_t::WASMZ_VAL_F32 => Some(Self::F32),
            wasmz_val_kind_t::WASMZ_VAL_F64 => Some(Self::F64),
            wasmz_val_kind_t::WASMZ_VAL_REF_FUNC | wasmz_val_kind_t::WASMZ_VAL_REF_NULL => {
                Some(Self::FuncRef)
            }
            wasmz_val_kind_t::WASMZ_VAL_EXTERN_REF => Some(Self::ExternRef),
            wasmz_val_kind_t::WASMZ_VAL_V128 => None,
        }
    }
}

/// WebAssembly value.
#[derive(Debug, Copy, Clone, PartialEq)]
pub enum Val {
    I32(i32),
    I64(i64),
    F32(f32),
    F64(f64),
    FuncRef(Option<u32>),
    ExternRef(usize),
}

impl Val {
    pub fn i32(v: i32) -> Self {
        Self::I32(v)
    }

    /// Returns the zero / null value of `kind`.
    pub fn default_for_kind(kind: ValKind) -> Self {
        match kind {
            ValKind::I32 => Self::I32(0),
            ValKind::I64 => Self::I64(0),
            ValKind::F32 => Self::F32(0.0),
            ValKind::F64 => Self::F64(0.0),
            ValKind::FuncRef => Self::FuncRef(None),
            ValKind::ExternRef => Self::ExternRef(0),
        }
    }

    pub fn kind(&self) -> ValKind {
        match self {
            Self::I32(_) => ValKind::I32,
            Self::I64(_) => ValKind::I64,
            Self::F32(_) => ValKind::F32,
            Self::F64(_) => ValKind::F64,
            Self::FuncRef(_) => ValKind::FuncRef,
            Self::ExternRef(_) => ValKind::ExternRef,
        }
    }

    fn to_c(self) -> wasmz_val_t {
        match self {
            Self::I32(v) => wasmz_val_t {
                kind: wasmz_val_kind_t::WASMZ_VAL_I32,
                _pad: [0, 0, 0, 0],
                of: sys::wasmz_val_union { i32: v },
            },
            Self::I64(v) => wasmz_val_t {
                kind: wasmz_val_kind_t::WASMZ_VAL_I64,
                _pad: [0, 0, 0, 0],
                of: sys::wasmz_val_union { i64: v },
            },
            Self::F32(v) => wasmz_val_t {
                kind: wasmz_val_kind_t::WASMZ_VAL_F32,
                _pad: [0, 0, 0, 0],
                of: sys::wasmz_val_union { f32: v },
            },
            Self::F64(v) => wasmz_val_t {
                kind: wasmz_val_kind_t::WASMZ_VAL_F64,
                _pad: [0, 0, 0, 0],
                of: sys::wasmz_val_union { f64: v },
            },
            Self::FuncRef(idx) => wasmz_val_t {
                kind: wasmz_val_kind_t::WASMZ_VAL_REF_FUNC,
                _pad: [0, 0, 0, 0],
                of: sys::wasmz_val_union {
                    func_ref: idx.unwrap_or(u32::MAX),
                },
            },
            Self::ExternRef(raw) => wasmz_val_t {
                kind: wasmz_val_kind_t::WASMZ_VAL_EXTERN_REF,
                _pad: [0, 0, 0, 0],
                of: sys::wasmz_val_union {
                    extern_ref: raw as *mut c_void,
                },
            },
        }
    }

    fn from_c(val: wasmz_val_t) -> Self {
        match val.kind {
            wasmz_val_kind_t::WASMZ_VAL_I32 => Self::I32(unsafe { val.of.i32 }),
            wasmz_val_kind_t::WASMZ_VAL_I64 => Self::I64(unsafe { val.of.i64 }),
            wasmz_val_kind_t::WASMZ_VAL_F32 => Self::F32(unsafe { val.of.f32 }),
            wasmz_val_kind_t::WASMZ_VAL_F64 => Self::F64(unsafe { val.of.f64 }),
            wasmz_val_kind_t::WASMZ_VAL_REF_NULL => Self::FuncRef(None),
            wasmz_val_kind_t::WASMZ_VAL_REF_FUNC => {
                let raw = unsafe { val.of.func_ref };
                Self::FuncRef(if raw == u32::MAX { None } else { Some(raw) })
            }
            wasmz_val_kind_t::WASMZ_VAL_EXTERN_REF => {
                Self::ExternRef(unsafe { val.of.extern_ref } as usize)
            }
            other => panic!("unsupported wasmz value kind: {:?}", other),
        }
    }
}

/// Validates a WebAssembly binary against default engine settings.
pub fn validate(wasm: &[u8]) -> Result<()> {
    let err = unsafe { wasmz_validate(wasm.as_ptr(), wasm.len()) };
    if !err.is_null() {
        return Err(Error::from_ptr(err));
    }
    Ok(())
}

/// Wasmz engine.
pub struct Engine {
    ptr: *mut sys::wasmz_engine_t,
}

impl Engine {
    pub fn new() -> Result<Self> {
        let ptr = unsafe { wasmz_engine_new() };
        if ptr.is_null() {
            return Err(Error {
                kind: ErrorKind::Unknown,
                message: "wasmz_engine_new returned null".into(),
            });
        }
        Ok(Self { ptr })
    }

    pub fn new_with_limit(mem_limit_bytes: u64) -> Result<Self> {
        let ptr = unsafe { wasmz_engine_new_with_limit(mem_limit_bytes) };
        if ptr.is_null() {
            return Err(Error {
                kind: ErrorKind::Unknown,
                message: "wasmz_engine_new_with_limit returned null".into(),
            });
        }
        Ok(Self { ptr })
    }

    pub fn validate(&self, wasm: &[u8]) -> Result<()> {
        let err = unsafe { wasmz_validate_with_engine(self.ptr, wasm.as_ptr(), wasm.len()) };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(())
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        unsafe { sys::wasmz_engine_delete(self.ptr) };
    }
}

/// Wasmz store.
pub struct Store {
    ptr: *mut sys::wasmz_store_t,
}

impl Store {
    pub fn new(engine: &Engine) -> Result<Self> {
        let ptr = unsafe { wasmz_store_new(engine.ptr) };
        if ptr.is_null() {
            return Err(Error {
                kind: ErrorKind::Unknown,
                message: "wasmz_store_new returned null".into(),
            });
        }
        Ok(Self { ptr })
    }
}

impl Drop for Store {
    fn drop(&mut self) {
        unsafe { wasmz_store_delete(self.ptr) };
    }
}

/// Compiled Wasm module.
pub struct Module {
    ptr: *mut sys::wasmz_module_t,
}

impl Module {
    pub fn compile(engine: &Engine, wasm: &[u8]) -> Result<Self> {
        let mut out = ptr::null_mut();
        let err = unsafe { wasmz_module_new(engine.ptr, wasm.as_ptr(), wasm.len(), &mut out) };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        if out.is_null() {
            return Err(Error {
                kind: ErrorKind::Compile,
                message: "wasmz_module_new returned null module".into(),
            });
        }
        Ok(Self { ptr: out })
    }
}

impl Drop for Module {
    fn drop(&mut self) {
        unsafe { wasmz_module_delete(self.ptr) };
    }
}

/// Reference-counted WebAssembly linear memory handle.
pub struct Memory {
    ptr: *mut sys::wasmz_memory_t,
}

impl Memory {
    pub fn new(initial: u64, max: Option<u64>, is_shared: bool, is_64: bool) -> Result<Self> {
        let mut out = ptr::null_mut();
        let err = unsafe {
            wasmz_memory_new(
                initial,
                max.unwrap_or(0),
                if max.is_some() { 1 } else { 0 },
                if is_shared { 1 } else { 0 },
                if is_64 { 1 } else { 0 },
                &mut out,
            )
        };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(Self { ptr: out })
    }

    pub fn clone_handle(&self) -> Self {
        let ptr = unsafe { wasmz_memory_clone(self.ptr) };
        assert!(!ptr.is_null());
        Self { ptr }
    }

    pub fn data_ptr(&self) -> *mut u8 {
        unsafe { wasmz_memory_data(self.ptr) }
    }

    pub fn data_len(&self) -> usize {
        unsafe { wasmz_memory_data_len(self.ptr) }
    }

    /// # Safety
    /// Caller must ensure no concurrent mutable access / grow occurs while the slice is live.
    pub unsafe fn as_slice(&self) -> &[u8] {
        let ptr = self.data_ptr();
        let len = self.data_len();
        if ptr.is_null() || len == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(ptr, len) }
        }
    }

    /// # Safety
    /// Caller must ensure exclusive access while the mutable slice is live.
    pub unsafe fn as_slice_mut(&mut self) -> &mut [u8] {
        let ptr = self.data_ptr();
        let len = self.data_len();
        if ptr.is_null() || len == 0 {
            &mut []
        } else {
            unsafe { slice::from_raw_parts_mut(ptr, len) }
        }
    }

    pub fn pages(&self) -> u64 {
        unsafe { wasmz_memory_pages(self.ptr) }
    }

    pub fn min_pages(&self) -> u64 {
        unsafe { wasmz_memory_min(self.ptr) }
    }

    pub fn max_pages(&self) -> Option<u64> {
        let mut has_max = 0;
        let v = unsafe { wasmz_memory_max(self.ptr, &mut has_max) };
        if has_max != 0 { Some(v) } else { None }
    }

    pub fn is_shared(&self) -> bool {
        unsafe { wasmz_memory_is_shared(self.ptr) != 0 }
    }

    pub fn is_64(&self) -> bool {
        unsafe { wasmz_memory_is_64(self.ptr) != 0 }
    }

    pub fn grow_seq(&self) -> u64 {
        unsafe { wasmz_memory_grow_seq(self.ptr) }
    }

    pub fn identity(&self) -> u64 {
        unsafe { wasmz_memory_identity(self.ptr) }
    }

    pub fn grow(&mut self, delta: u64) -> Option<u64> {
        let mut prev = 0u64;
        let rc = unsafe { wasmz_memory_grow(self.ptr, delta, &mut prev) };
        if rc == 0 { Some(prev) } else { None }
    }
}

impl Clone for Memory {
    fn clone(&self) -> Self {
        self.clone_handle()
    }
}

impl Drop for Memory {
    fn drop(&mut self) {
        unsafe { wasmz_memory_delete(self.ptr) };
    }
}

/// Reference-counted WebAssembly Global handle.
pub struct Global {
    ptr: *mut sys::wasmz_global_t,
}

impl Global {
    pub fn new(kind: ValKind, is_mutable: bool, initial: Val) -> Result<Self> {
        let mut out = ptr::null_mut();
        let err = unsafe {
            wasmz_global_new(
                kind.to_c(),
                if is_mutable { 1 } else { 0 },
                initial.to_c(),
                &mut out,
            )
        };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(Self { ptr: out })
    }

    pub fn kind(&self) -> ValKind {
        ValKind::from_c(unsafe { wasmz_global_kind(self.ptr) }).unwrap_or(ValKind::I32)
    }

    pub fn is_mutable(&self) -> bool {
        unsafe { wasmz_global_is_mutable(self.ptr) != 0 }
    }

    pub fn get(&self) -> Val {
        Val::from_c(unsafe { wasmz_global_get(self.ptr) })
    }

    pub fn identity(&self) -> u64 {
        unsafe { wasmz_global_identity(self.ptr) }
    }

    pub fn set(&self, value: Val) -> Result<()> {
        let err = unsafe { wasmz_global_set(self.ptr, value.to_c()) };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(())
    }
}

impl Clone for Global {
    fn clone(&self) -> Self {
        let ptr = unsafe { wasmz_global_clone(self.ptr) };
        assert!(!ptr.is_null());
        Self { ptr }
    }
}

impl Drop for Global {
    fn drop(&mut self) {
        unsafe { wasmz_global_delete(self.ptr) };
    }
}

/// Entry metadata returned by `Table::get_entry`.
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum TableEntry {
    Null,
    Func {
        owner_id: u64,
        func_idx: u32,
        raw: u64,
    },
    ExternRef(usize),
}

/// Host function handle storable in a `Table` and invoked by `call_indirect`.
pub struct TableHostFunc {
    ptr: *mut sys::wasmz_table_host_func_t,
    _data: *mut TrappableHostFuncData,
}

impl TableHostFunc {
    pub fn new(
        params: &[ValKind],
        results: &[ValKind],
        tag: u64,
        func: TrappableHostFunc,
    ) -> Result<Self> {
        let param_kinds: Vec<wasmz_val_kind_t> = params.iter().copied().map(ValKind::to_c).collect();
        let result_kinds: Vec<wasmz_val_kind_t> =
            results.iter().copied().map(ValKind::to_c).collect();
        let data = Box::new(TrappableHostFuncData {
            func,
            result_kinds: results.to_vec(),
        });
        let data_ptr = Box::into_raw(data);
        let mut out = ptr::null_mut();
        let err = unsafe {
            wasmz_table_host_func_new(
                param_kinds.as_ptr(),
                param_kinds.len(),
                result_kinds.as_ptr(),
                result_kinds.len(),
                Some(trappable_trampoline),
                data_ptr as *mut c_void,
                tag,
                &mut out,
            )
        };
        if !err.is_null() {
            unsafe { drop(Box::from_raw(data_ptr)) };
            return Err(Error::from_ptr(err));
        }
        Ok(Self {
            ptr: out,
            _data: data_ptr,
        })
    }
}

impl Drop for TableHostFunc {
    fn drop(&mut self) {
        unsafe {
            wasmz_table_host_func_delete(self.ptr);
            drop(Box::from_raw(self._data));
        }
    }
}

/// Reference-counted WebAssembly Table handle.
pub struct Table {
    ptr: *mut sys::wasmz_table_t,
}

impl Table {
    pub fn new(
        elem_kind: ValKind,
        initial: u32,
        max: Option<u32>,
        init_externref: usize,
        init_func: Option<(&Instance, u32)>,
    ) -> Result<Self> {
        let mut out = ptr::null_mut();
        let (owner_ptr, func_idx) = match init_func {
            Some((inst, idx)) => (inst.ptr as *const _, idx),
            None => (ptr::null(), 0),
        };
        let err = unsafe {
            wasmz_table_new(
                elem_kind.to_c(),
                initial,
                max.unwrap_or(0),
                if max.is_some() { 1 } else { 0 },
                init_externref as u64,
                owner_ptr,
                func_idx,
                &mut out,
            )
        };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(Self { ptr: out })
    }

    pub fn len(&self) -> u32 {
        unsafe { wasmz_table_len(self.ptr) }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn max_len(&self) -> Option<u32> {
        let mut has_max = 0;
        let v = unsafe { wasmz_table_max(self.ptr, &mut has_max) };
        if has_max != 0 { Some(v) } else { None }
    }

    pub fn elem_kind(&self) -> ValKind {
        ValKind::from_c(unsafe { wasmz_table_elem_kind(self.ptr) }).unwrap_or(ValKind::FuncRef)
    }

    pub fn identity(&self) -> u64 {
        unsafe { wasmz_table_identity(self.ptr) }
    }

    pub fn get_entry(&self, index: u32) -> Option<TableEntry> {
        let mut is_null = 0;
        let mut owner_id = 0u64;
        let mut func_idx = 0u32;
        let mut raw = 0u64;
        let rc = unsafe {
            wasmz_table_get_entry(
                self.ptr,
                index,
                &mut is_null,
                &mut owner_id,
                &mut func_idx,
                &mut raw,
            )
        };
        if rc != 0 {
            return None;
        }
        if is_null != 0 {
            return Some(TableEntry::Null);
        }
        match self.elem_kind() {
            ValKind::ExternRef => Some(TableEntry::ExternRef(raw as usize)),
            _ => Some(TableEntry::Func {
                owner_id,
                func_idx,
                raw,
            }),
        }
    }

    pub fn set_null(&self, index: u32) -> bool {
        unsafe { wasmz_table_set_null(self.ptr, index) == 0 }
    }

    pub fn set_externref(&self, index: u32, raw_ref: usize) -> bool {
        unsafe { wasmz_table_set_externref(self.ptr, index, raw_ref as u64) == 0 }
    }

    pub fn set_instance_func(&self, index: u32, owner: &Instance, func_idx: u32) -> bool {
        unsafe { wasmz_table_set_instance_func(self.ptr, index, owner.ptr, func_idx) == 0 }
    }

    pub fn set_host_func(&self, index: u32, func: &TableHostFunc) -> bool {
        unsafe { wasmz_table_set_host_func(self.ptr, index, func.ptr) == 0 }
    }

    pub fn grow(&self, delta: u32, init_externref: usize) -> Option<u32> {
        let mut prev = 0u32;
        let rc = unsafe { wasmz_table_grow(self.ptr, delta, init_externref as u64, &mut prev) };
        if rc == 0 { Some(prev) } else { None }
    }

    pub fn grow_instance_func(
        &self,
        delta: u32,
        owner: Option<&Instance>,
        func_idx: u32,
    ) -> Option<u32> {
        let mut prev = 0u32;
        let rc = unsafe {
            wasmz_table_grow_instance_func(
                self.ptr,
                delta,
                owner.map_or(ptr::null(), |i| i.ptr),
                func_idx,
                &mut prev,
            )
        };
        if rc == 0 { Some(prev) } else { None }
    }

    pub fn grow_host_func(&self, delta: u32, func: Option<&TableHostFunc>) -> Option<u32> {
        let mut prev = 0u32;
        let rc = unsafe {
            wasmz_table_grow_host_func(
                self.ptr,
                delta,
                func.map_or(ptr::null(), |f| f.ptr),
                &mut prev,
            )
        };
        if rc == 0 { Some(prev) } else { None }
    }
}

impl Clone for Table {
    fn clone(&self) -> Self {
        let ptr = unsafe { wasmz_table_clone(self.ptr) };
        assert!(!ptr.is_null());
        Self { ptr }
    }
}

impl Drop for Table {
    fn drop(&mut self) {
        unsafe { wasmz_table_delete(self.ptr) };
    }
}

/// WASI Preview 1 host instance attached to a `Linker`.
pub struct WasiHost {
    ptr: *mut sys::wasmz_wasi_host_t,
}

impl WasiHost {
    pub fn new() -> Result<Self> {
        let ptr = unsafe { wasmz_wasi_host_new() };
        if ptr.is_null() {
            return Err(Error {
                kind: ErrorKind::Unknown,
                message: "wasmz_wasi_host_new returned null".into(),
            });
        }
        Ok(Self { ptr })
    }

    pub fn set_args(&mut self, args: &[&str]) -> Result<()> {
        let c_args: Vec<CString> = args
            .iter()
            .map(|s| {
                CString::new(*s).map_err(|e| Error {
                    kind: ErrorKind::Unknown,
                    message: e.to_string(),
                })
            })
            .collect::<Result<_>>()?;
        let ptrs: Vec<*const std::os::raw::c_char> = c_args.iter().map(|s| s.as_ptr()).collect();
        let err = unsafe { wasmz_wasi_host_set_args(self.ptr, ptrs.as_ptr(), ptrs.len()) };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(())
    }

    pub fn set_env(&mut self, env: &[(&str, &str)]) -> Result<()> {
        let c_keys: Vec<CString> = env
            .iter()
            .map(|(k, _)| {
                CString::new(*k).map_err(|e| Error {
                    kind: ErrorKind::Unknown,
                    message: e.to_string(),
                })
            })
            .collect::<Result<_>>()?;
        let c_vals: Vec<CString> = env
            .iter()
            .map(|(_, v)| {
                CString::new(*v).map_err(|e| Error {
                    kind: ErrorKind::Unknown,
                    message: e.to_string(),
                })
            })
            .collect::<Result<_>>()?;
        let k_ptrs: Vec<*const std::os::raw::c_char> = c_keys.iter().map(|s| s.as_ptr()).collect();
        let v_ptrs: Vec<*const std::os::raw::c_char> = c_vals.iter().map(|s| s.as_ptr()).collect();
        let err = unsafe {
            wasmz_wasi_host_set_env(self.ptr, k_ptrs.as_ptr(), v_ptrs.as_ptr(), k_ptrs.len())
        };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(())
    }

    pub fn add_preopen(&mut self, guest_path: &str, host_path: &str) -> Result<()> {
        let gp = CString::new(guest_path).map_err(|e| Error {
            kind: ErrorKind::Unknown,
            message: e.to_string(),
        })?;
        let hp = CString::new(host_path).map_err(|e| Error {
            kind: ErrorKind::Unknown,
            message: e.to_string(),
        })?;
        let err = unsafe { wasmz_wasi_host_add_preopen(self.ptr, gp.as_ptr(), hp.as_ptr()) };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(())
    }

    pub fn set_stdio_fds(&mut self, stdin_fd: i32, stdout_fd: i32, stderr_fd: i32) {
        unsafe { wasmz_wasi_host_set_stdio_fds(self.ptr, stdin_fd, stdout_fd, stderr_fd) };
    }

    pub fn set_return_on_exit(&mut self, return_on_exit: bool) {
        unsafe { wasmz_wasi_host_set_return_on_exit(self.ptr, if return_on_exit { 1 } else { 0 }) };
    }

    pub fn exit_code(&self) -> Option<u32> {
        let mut code = 0u32;
        if unsafe { wasmz_wasi_host_exit_code(self.ptr, &mut code) != 0 } {
            Some(code)
        } else {
            None
        }
    }
}

impl Drop for WasiHost {
    fn drop(&mut self) {
        unsafe { wasmz_wasi_host_delete(self.ptr) };
    }
}

/// Host function callback.
pub type HostFunc = Box<dyn Fn(&[Val], &mut [Val])>;

/// Caller context passed to trappable host functions.
pub struct HostCaller {
    ctx: *mut c_void,
}

impl HostCaller {
    pub fn memory(&self) -> Option<(*mut u8, usize)> {
        if self.ctx.is_null() {
            return None;
        }
        let ptr = unsafe { wasmz_context_memory(self.ctx) };
        if ptr.is_null() {
            return None;
        }
        let len = unsafe { wasmz_context_memory_size(self.ctx) };
        Some((ptr, len))
    }
}

/// Host function callback that can return a trap message.
pub type TrappableHostFunc =
    Box<dyn Fn(HostCaller, &[Val], &mut [Val]) -> std::result::Result<(), String>>;

struct HostFuncData {
    func: HostFunc,
    result_kinds: Vec<ValKind>,
}

struct TrappableHostFuncData {
    func: TrappableHostFunc,
    result_kinds: Vec<ValKind>,
}

extern "C" fn trappable_trampoline(
    host_data: *mut c_void,
    ctx: *mut c_void,
    params: *const wasmz_val_t,
    param_count: usize,
    results: *mut wasmz_val_t,
    result_count: usize,
) -> i32 {
    let data = unsafe { &*(host_data as *const TrappableHostFuncData) };
    let in_params: Vec<Val> = unsafe {
        slice::from_raw_parts(params, param_count)
            .iter()
            .map(|v| Val::from_c(*v))
            .collect()
    };
    let mut out: Vec<Val> = data
        .result_kinds
        .iter()
        .copied()
        .map(Val::default_for_kind)
        .collect();
    assert_eq!(out.len(), result_count);
    match (data.func)(HostCaller { ctx }, &in_params, &mut out) {
        Ok(()) => {
            for (dst, src) in unsafe { slice::from_raw_parts_mut(results, result_count) }
                .iter_mut()
                .zip(out)
            {
                *dst = src.to_c();
            }
            0
        }
        Err(msg) => {
            if !ctx.is_null() {
                if let Ok(cmsg) = CString::new(msg) {
                    unsafe { wasmz_context_trap(ctx, cmsg.as_ptr()) };
                }
            }
            -1
        }
    }
}

struct LinkerCallbacks {
    host_data: Vec<*mut HostFuncData>,
    trappable_data: Vec<*mut TrappableHostFuncData>,
}

impl Drop for LinkerCallbacks {
    fn drop(&mut self) {
        for data in self.host_data.drain(..) {
            unsafe { drop(Box::from_raw(data)) };
        }
        for data in self.trappable_data.drain(..) {
            unsafe { drop(Box::from_raw(data)) };
        }
    }
}

/// Linker for host imports.
pub struct Linker {
    ptr: *mut sys::wasmz_linker_t,
    callbacks: Rc<RefCell<LinkerCallbacks>>,
}

impl Linker {
    pub fn new() -> Result<Self> {
        let ptr = unsafe { wasmz_linker_new() };
        if ptr.is_null() {
            return Err(Error {
                kind: ErrorKind::Unknown,
                message: "wasmz_linker_new returned null".into(),
            });
        }
        Ok(Self {
            ptr,
            callbacks: Rc::new(RefCell::new(LinkerCallbacks {
                host_data: Vec::new(),
                trappable_data: Vec::new(),
            })),
        })
    }

    pub fn define_func(
        &mut self,
        module: &str,
        name: &str,
        params: &[ValKind],
        results: &[ValKind],
        func: HostFunc,
    ) -> Result<()> {
        let module = CString::new(module).map_err(|e| Error {
            kind: ErrorKind::Unknown,
            message: e.to_string(),
        })?;
        let name = CString::new(name).map_err(|e| Error {
            kind: ErrorKind::Unknown,
            message: e.to_string(),
        })?;
        let param_kinds: Vec<wasmz_val_kind_t> =
            params.iter().copied().map(ValKind::to_c).collect();
        let result_kinds: Vec<wasmz_val_kind_t> =
            results.iter().copied().map(ValKind::to_c).collect();

        let data = Box::new(HostFuncData {
            func,
            result_kinds: results.to_vec(),
        });
        let data_ptr = Box::into_raw(data);
        self.callbacks.borrow_mut().host_data.push(data_ptr);

        extern "C" fn trampoline(
            host_data: *mut c_void,
            _ctx: *mut c_void,
            params: *const wasmz_val_t,
            param_count: usize,
            results: *mut wasmz_val_t,
            result_count: usize,
        ) -> i32 {
            let data = unsafe { &*(host_data as *const HostFuncData) };
            let in_params: Vec<Val> = unsafe {
                slice::from_raw_parts(params, param_count)
                    .iter()
                    .map(|v| Val::from_c(*v))
                    .collect()
            };
            let mut out: Vec<Val> = data
                .result_kinds
                .iter()
                .copied()
                .map(Val::default_for_kind)
                .collect();
            assert_eq!(out.len(), result_count);
            (data.func)(&in_params, &mut out);
            for (dst, src) in unsafe { slice::from_raw_parts_mut(results, result_count) }
                .iter_mut()
                .zip(out)
            {
                *dst = src.to_c();
            }
            0
        }

        let err = unsafe {
            wasmz_linker_define_func(
                self.ptr,
                module.as_ptr(),
                name.as_ptr(),
                param_kinds.as_ptr(),
                param_kinds.len(),
                result_kinds.as_ptr(),
                result_kinds.len(),
                Some(trampoline),
                data_ptr as *mut c_void,
            )
        };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(())
    }

    pub fn define_trappable_func(
        &mut self,
        module: &str,
        name: &str,
        params: &[ValKind],
        results: &[ValKind],
        func: TrappableHostFunc,
    ) -> Result<()> {
        let module = CString::new(module).map_err(|e| Error {
            kind: ErrorKind::Unknown,
            message: e.to_string(),
        })?;
        let name = CString::new(name).map_err(|e| Error {
            kind: ErrorKind::Unknown,
            message: e.to_string(),
        })?;
        let param_kinds: Vec<wasmz_val_kind_t> =
            params.iter().copied().map(ValKind::to_c).collect();
        let result_kinds: Vec<wasmz_val_kind_t> =
            results.iter().copied().map(ValKind::to_c).collect();

        let data = Box::new(TrappableHostFuncData {
            func,
            result_kinds: results.to_vec(),
        });
        let data_ptr = Box::into_raw(data);
        self.callbacks.borrow_mut().trappable_data.push(data_ptr);

        let err = unsafe {
            wasmz_linker_define_func(
                self.ptr,
                module.as_ptr(),
                name.as_ptr(),
                param_kinds.as_ptr(),
                param_kinds.len(),
                result_kinds.as_ptr(),
                result_kinds.len(),
                Some(trappable_trampoline),
                data_ptr as *mut c_void,
            )
        };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(())
    }

    pub fn define_memory(&mut self, module: &str, name: &str, mem: &Memory) -> Result<()> {
        let module = CString::new(module).map_err(|e| Error {
            kind: ErrorKind::Unknown,
            message: e.to_string(),
        })?;
        let name = CString::new(name).map_err(|e| Error {
            kind: ErrorKind::Unknown,
            message: e.to_string(),
        })?;
        let err =
            unsafe { wasmz_linker_define_memory(self.ptr, module.as_ptr(), name.as_ptr(), mem.ptr) };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(())
    }

    pub fn define_global(&mut self, module: &str, name: &str, global: &Global) -> Result<()> {
        let module = CString::new(module).map_err(|e| Error {
            kind: ErrorKind::Unknown,
            message: e.to_string(),
        })?;
        let name = CString::new(name).map_err(|e| Error {
            kind: ErrorKind::Unknown,
            message: e.to_string(),
        })?;
        let err = unsafe {
            wasmz_linker_define_global_handle(self.ptr, module.as_ptr(), name.as_ptr(), global.ptr)
        };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(())
    }

    pub fn define_table(&mut self, module: &str, name: &str, table: &Table) -> Result<()> {
        let module = CString::new(module).map_err(|e| Error {
            kind: ErrorKind::Unknown,
            message: e.to_string(),
        })?;
        let name = CString::new(name).map_err(|e| Error {
            kind: ErrorKind::Unknown,
            message: e.to_string(),
        })?;
        let err = unsafe {
            wasmz_linker_define_table(self.ptr, module.as_ptr(), name.as_ptr(), table.ptr)
        };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(())
    }

    pub fn add_wasi(&mut self, wasi: &mut WasiHost) -> Result<()> {
        let err = unsafe { wasmz_linker_add_wasi(self.ptr, wasi.ptr) };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(())
    }
}

impl Drop for Linker {
    fn drop(&mut self) {
        unsafe { wasmz_linker_delete(self.ptr) };
    }
}

/// Instantiated module.
pub struct Instance {
    ptr: *mut sys::wasmz_instance_t,
    _callbacks: Option<Rc<RefCell<LinkerCallbacks>>>,
}

impl Instance {
    pub fn new(store: &Store, module: &Module, linker: Option<&Linker>) -> Result<Self> {
        let mut out = ptr::null_mut();
        let linker_ptr = linker.map_or(ptr::null_mut(), |l| l.ptr);
        let err =
            unsafe { wasmz_instance_new_with_linker(store.ptr, module.ptr, linker_ptr, &mut out) };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        if out.is_null() {
            return Err(Error {
                kind: ErrorKind::Runtime,
                message: "wasmz_instance_new_with_linker returned null instance".into(),
            });
        }
        Ok(Self {
            ptr: out,
            _callbacks: linker.map(|l| Rc::clone(&l.callbacks)),
        })
    }

    pub fn id(&self) -> u64 {
        unsafe { wasmz_instance_id(self.ptr) }
    }

    pub fn run_start(&self) -> Result<()> {
        let err = unsafe { wasmz_instance_run_start(self.ptr) };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(())
    }

    pub fn call_start(&self) -> Result<()> {
        let err = unsafe { wasmz_instance_call_start(self.ptr) };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(())
    }

    pub fn initialize(&self) -> Result<()> {
        let err = unsafe { wasmz_instance_initialize(self.ptr) };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(())
    }

    pub fn export_func_info(&self, name: &str) -> Option<(u32, usize, usize)> {
        let name = CString::new(name).ok()?;
        let mut func_idx = 0u32;
        let mut pcount = 0usize;
        let mut rcount = 0usize;
        let rc = unsafe {
            wasmz_instance_export_func_info(
                self.ptr,
                name.as_ptr(),
                &mut func_idx,
                &mut pcount,
                &mut rcount,
            )
        };
        if rc == 0 {
            Some((func_idx, pcount, rcount))
        } else {
            None
        }
    }

    pub fn func_sig(&self, func_index: u32) -> Option<(Vec<ValKind>, Vec<ValKind>)> {
        let mut pcount = 0usize;
        let mut rcount = 0usize;
        let rc = unsafe {
            wasmz_instance_func_sig(
                self.ptr,
                func_index,
                ptr::null_mut(),
                0,
                &mut pcount,
                ptr::null_mut(),
                0,
                &mut rcount,
            )
        };
        if rc != 0 {
            return None;
        }
        let mut raw_params = vec![wasmz_val_kind_t::WASMZ_VAL_I32; pcount];
        let mut raw_results = vec![wasmz_val_kind_t::WASMZ_VAL_I32; rcount];
        let rc2 = unsafe {
            wasmz_instance_func_sig(
                self.ptr,
                func_index,
                raw_params.as_mut_ptr(),
                raw_params.len(),
                &mut pcount,
                raw_results.as_mut_ptr(),
                raw_results.len(),
                &mut rcount,
            )
        };
        if rc2 != 0 {
            return None;
        }
        let params = raw_params
            .into_iter()
            .map(ValKind::from_c)
            .collect::<Option<Vec<_>>>()?;
        let results = raw_results
            .into_iter()
            .map(ValKind::from_c)
            .collect::<Option<Vec<_>>>()?;
        Some((params, results))
    }

    /// Calls the export `name`.
    pub fn call(&self, name: &str, args: &[Val], result_kinds: &[ValKind]) -> Result<Vec<Val>> {
        let name = CString::new(name).map_err(|e| Error {
            kind: ErrorKind::Unknown,
            message: e.to_string(),
        })?;
        let c_args: Vec<wasmz_val_t> = args.iter().copied().map(Val::to_c).collect();
        let mut c_results: Vec<wasmz_val_t> = result_kinds
            .iter()
            .copied()
            .map(|kind| Val::default_for_kind(kind).to_c())
            .collect();
        let err = unsafe {
            wasmz_instance_call(
                self.ptr,
                name.as_ptr(),
                c_args.as_ptr(),
                c_args.len(),
                c_results.as_mut_ptr(),
                c_results.len(),
            )
        };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(c_results.into_iter().map(Val::from_c).collect())
    }

    pub fn call_index(
        &self,
        func_index: u32,
        args: &[Val],
        result_kinds: &[ValKind],
    ) -> Result<Vec<Val>> {
        let c_args: Vec<wasmz_val_t> = args.iter().copied().map(Val::to_c).collect();
        let mut c_results: Vec<wasmz_val_t> = result_kinds
            .iter()
            .copied()
            .map(|kind| Val::default_for_kind(kind).to_c())
            .collect();
        let err = unsafe {
            wasmz_instance_call_index(
                self.ptr,
                func_index,
                c_args.as_ptr(),
                c_args.len(),
                c_results.as_mut_ptr(),
                c_results.len(),
            )
        };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(c_results.into_iter().map(Val::from_c).collect())
    }

    pub fn export_memory(&self, name: &str) -> Option<Memory> {
        let name = CString::new(name).ok()?;
        let ptr = unsafe { wasmz_instance_export_memory(self.ptr, name.as_ptr()) };
        if ptr.is_null() {
            None
        } else {
            Some(Memory { ptr })
        }
    }

    pub fn export_global(&self, name: &str) -> Option<Global> {
        let name = CString::new(name).ok()?;
        let ptr = unsafe { wasmz_instance_export_global(self.ptr, name.as_ptr()) };
        if ptr.is_null() {
            None
        } else {
            Some(Global { ptr })
        }
    }

    pub fn export_table(&self, name: &str) -> Option<Table> {
        let name = CString::new(name).ok()?;
        let ptr = unsafe { wasmz_instance_export_table(self.ptr, name.as_ptr()) };
        if ptr.is_null() {
            None
        } else {
            Some(Table { ptr })
        }
    }

    pub fn memory(&self) -> Option<(*mut u8, usize)> {
        let ptr = unsafe { wasmz_instance_memory(self.ptr) };
        if ptr.is_null() {
            return None;
        }
        let size = unsafe { wasmz_instance_memory_size(self.ptr) };
        Some((ptr, size))
    }

    pub fn memory_grow(&self, pages: u64) -> bool {
        unsafe { wasmz_instance_memory_grow(self.ptr, pages) == 0 }
    }

    pub fn is_memory64(&self) -> bool {
        unsafe { wasmz_instance_memory64(self.ptr) != 0 }
    }
}

impl Drop for Instance {
    fn drop(&mut self) {
        unsafe { wasmz_instance_delete(self.ptr) };
    }
}

//! Rust bindings for the wasmz C API.

use std::ffi::{CStr, CString};
use std::fmt;
use std::ptr;
use std::slice;

use wasmz_sys as sys;
use wasmz_sys::{
    wasmz_engine_new, wasmz_error_delete, wasmz_error_message, wasmz_instance_call,
    wasmz_instance_delete, wasmz_instance_memory, wasmz_instance_memory_size,
    wasmz_instance_new_with_linker, wasmz_linker_define_func, wasmz_linker_delete,
    wasmz_linker_new, wasmz_module_delete, wasmz_module_new, wasmz_store_delete, wasmz_store_new,
    wasmz_val_kind_t, wasmz_val_t,
};

/// Error returned by wasmz operations.
#[derive(Debug)]
pub struct Error {
    message: String,
}

impl Error {
    fn from_ptr(ptr: *mut sys::wasmz_error_t) -> Self {
        let message = if ptr.is_null() {
            "unknown wasmz error".to_string()
        } else {
            let msg = unsafe { CStr::from_ptr(wasmz_error_message(ptr)) };
            msg.to_string_lossy().into_owned()
        };
        if !ptr.is_null() {
            unsafe { wasmz_error_delete(ptr) };
        }
        Self { message }
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
}

impl ValKind {
    fn to_c(self) -> wasmz_val_kind_t {
        match self {
            Self::I32 => wasmz_val_kind_t::WASMZ_VAL_I32,
            Self::I64 => wasmz_val_kind_t::WASMZ_VAL_I64,
            Self::F32 => wasmz_val_kind_t::WASMZ_VAL_F32,
            Self::F64 => wasmz_val_kind_t::WASMZ_VAL_F64,
        }
    }
}

/// WebAssembly value.
#[derive(Debug, Copy, Clone)]
pub enum Val {
    I32(i32),
    I64(i64),
    F32(f32),
    F64(f64),
}

impl Val {
    pub fn i32(v: i32) -> Self {
        Self::I32(v)
    }

    /// Returns the zero value of `kind`.
    pub fn default_for_kind(kind: ValKind) -> Self {
        match kind {
            ValKind::I32 => Self::I32(0),
            ValKind::I64 => Self::I64(0),
            ValKind::F32 => Self::F32(0.0),
            ValKind::F64 => Self::F64(0.0),
        }
    }

    pub fn kind(&self) -> ValKind {
        match self {
            Self::I32(_) => ValKind::I32,
            Self::I64(_) => ValKind::I64,
            Self::F32(_) => ValKind::F32,
            Self::F64(_) => ValKind::F64,
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
        }
    }

    fn from_c(val: wasmz_val_t) -> Self {
        match val.kind {
            wasmz_val_kind_t::WASMZ_VAL_I32 => Self::I32(unsafe { val.of.i32 }),
            wasmz_val_kind_t::WASMZ_VAL_I64 => Self::I64(unsafe { val.of.i64 }),
            wasmz_val_kind_t::WASMZ_VAL_F32 => Self::F32(unsafe { val.of.f32 }),
            wasmz_val_kind_t::WASMZ_VAL_F64 => Self::F64(unsafe { val.of.f64 }),
            other => panic!("unsupported wasmz value kind: {:?}", other),
        }
    }
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
                message: "wasmz_engine_new returned null".into(),
            });
        }
        Ok(Self { ptr })
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

/// Host function callback.
pub type HostFunc = Box<dyn Fn(&[Val], &mut [Val])>;

struct HostFuncData {
    func: HostFunc,
    result_kinds: Vec<ValKind>,
}

/// Linker for host imports.
pub struct Linker {
    ptr: *mut sys::wasmz_linker_t,
    host_data: Vec<*mut HostFuncData>,
}

impl Linker {
    pub fn new() -> Result<Self> {
        let ptr = unsafe { wasmz_linker_new() };
        if ptr.is_null() {
            return Err(Error {
                message: "wasmz_linker_new returned null".into(),
            });
        }
        Ok(Self {
            ptr,
            host_data: Vec::new(),
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
            message: e.to_string(),
        })?;
        let name = CString::new(name).map_err(|e| Error {
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
        self.host_data.push(data_ptr);

        extern "C" fn trampoline(
            host_data: *mut std::ffi::c_void,
            _ctx: *mut std::ffi::c_void,
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
                .map(|kind| match kind {
                    ValKind::I32 => Val::I32(0),
                    ValKind::I64 => Val::I64(0),
                    ValKind::F32 => Val::F32(0.0),
                    ValKind::F64 => Val::F64(0.0),
                })
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
                data_ptr as *mut std::ffi::c_void,
            )
        };
        if !err.is_null() {
            return Err(Error::from_ptr(err));
        }
        Ok(())
    }
}

impl Drop for Linker {
    fn drop(&mut self) {
        for data in self.host_data.drain(..) {
            unsafe { drop(Box::from_raw(data)) };
        }
        unsafe { wasmz_linker_delete(self.ptr) };
    }
}

/// Instantiated module.
pub struct Instance {
    ptr: *mut sys::wasmz_instance_t,
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
                message: "wasmz_instance_new_with_linker returned null instance".into(),
            });
        }
        Ok(Self { ptr: out })
    }

    /// Calls the export `name`.
    ///
    /// `result_kinds` declares the expected return types: wasmz writes each
    /// result back into a slot tagged with the kind the caller asked for, so a
    /// wrong kind here silently reinterprets the bits (an `f32` score read as
    /// `i32`, for instance).
    pub fn call(&self, name: &str, args: &[Val], result_kinds: &[ValKind]) -> Result<Vec<Val>> {
        let name = CString::new(name).map_err(|e| Error {
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

    pub fn memory(&self) -> Option<(*mut u8, usize)> {
        let ptr = unsafe { wasmz_instance_memory(self.ptr) };
        if ptr.is_null() {
            return None;
        }
        let size = unsafe { wasmz_instance_memory_size(self.ptr) };
        Some((ptr, size))
    }
}

impl Drop for Instance {
    fn drop(&mut self) {
        unsafe { wasmz_instance_delete(self.ptr) };
    }
}

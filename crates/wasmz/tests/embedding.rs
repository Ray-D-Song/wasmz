use std::fs;
use std::sync::atomic::{AtomicI32, Ordering};
use wasmz::{
    Engine, ErrorKind, Global, Instance, Linker, Memory, Module, Store, Table, TableEntry,
    TableHostFunc, Val, ValKind, WasiHost, validate,
};

const ADD_MODULE: &[u8] = &[
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01,
    0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, b'a', b'd', b'd', 0x00, 0x00, 0x0a, 0x09,
    0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,
];

const MEMORY_MODULE: &[u8] = &[
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x0a, 0x01,
    0x06, b'm', b'e', b'm', b'o', b'r', b'y', 0x02, 0x00,
];

const HOST_MODULE: &[u8] = &[
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
    0x02, 0x0b, 0x01, 0x03, b'e', b'n', b'v', 0x03, b'i', b'n', b'c', 0x00, 0x00, 0x03, 0x02, 0x01,
    0x00, 0x07, 0x08, 0x01, 0x04, b'c', b'a', b'l', b'l', 0x00, 0x01, 0x0a, 0x08, 0x01, 0x06, 0x00,
    0x20, 0x00, 0x10, 0x00, 0x0b,
];

#[test]
fn compiles_instantiates_and_calls_an_export() {
    let engine = Engine::new().unwrap();
    let store = Store::new(&engine).unwrap();
    let module = Module::compile(&engine, ADD_MODULE).unwrap();
    let instance = Instance::new(&store, &module, None).unwrap();

    assert!(matches!(
        instance.call("add", &[Val::I32(20), Val::I32(22)], &[ValKind::I32]),
        Ok(values) if matches!(values.as_slice(), [Val::I32(42)])
    ));
}

#[test]
fn links_host_functions_and_exposes_memory() {
    let engine = Engine::new().unwrap();
    let store = Store::new(&engine).unwrap();
    let mut linker = Linker::new().unwrap();
    linker
        .define_func(
            "env",
            "inc",
            &[ValKind::I32],
            &[ValKind::I32],
            Box::new(|params, results| {
                results[0] = match params[0] {
                    Val::I32(value) => Val::I32(value + 1),
                    _ => unreachable!(),
                };
            }),
        )
        .unwrap();
    let host_module = Module::compile(&engine, HOST_MODULE).unwrap();
    let host_instance = Instance::new(&store, &host_module, Some(&linker)).unwrap();
    assert!(matches!(
        host_instance.call("call", &[Val::I32(41)], &[ValKind::I32]),
        Ok(values) if matches!(values.as_slice(), [Val::I32(42)])
    ));

    let memory_module = Module::compile(&engine, MEMORY_MODULE).unwrap();
    let memory_instance = Instance::new(&store, &memory_module, None).unwrap();
    let (memory, size) = memory_instance.memory().unwrap();
    assert_eq!(size, 64 * 1024);
    unsafe { memory.write(0xab) };
    assert_eq!(unsafe { memory.read() }, 0xab);
}

#[test]
fn validates_multi_value_and_typed_errors() {
    assert!(validate(ADD_MODULE).is_ok());
    let err = validate(b"not wasm").unwrap_err();
    assert_eq!(err.kind(), ErrorKind::Compile);

    let mv_fixed: &[u8] = &[
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f,
        0x02, 0x7f, 0x7e, 0x03, 0x02, 0x01, 0x00, 0x07, 0x08, 0x01, 0x04, b'p', b'a', b'i', b'r',
        0x00, 0x00, 0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x01, 0x20, 0x00, 0xad, 0x0b,
    ];
    let engine = Engine::new().unwrap();
    let store = Store::new(&engine).unwrap();
    let module = Module::compile(&engine, mv_fixed).unwrap();
    let instance = Instance::new(&store, &module, None).unwrap();

    let (idx, p, r) = instance.export_func_info("pair").unwrap();
    assert_eq!((p, r), (2, 2));
    let (pk, rk) = instance.func_sig(idx).unwrap();
    assert_eq!(pk, vec![ValKind::I32, ValKind::I32]);
    assert_eq!(rk, vec![ValKind::I32, ValKind::I64]);

    let out = instance
        .call(
            "pair",
            &[Val::I32(7), Val::I32(9)],
            &[ValKind::I32, ValKind::I64],
        )
        .unwrap();
    assert_eq!(out, vec![Val::I32(9), Val::I64(7)]);

    let link_err = Instance::new(
        &store,
        &Module::compile(&engine, HOST_MODULE).unwrap(),
        None,
    )
    .err()
    .unwrap();
    assert_eq!(link_err.kind(), ErrorKind::Link);
}

#[test]
fn trappable_host_func_and_reentrancy() {
    let engine = Engine::new().unwrap();
    let store = Store::new(&engine).unwrap();
    let module = Module::compile(&engine, HOST_MODULE).unwrap();

    let mut linker = Linker::new().unwrap();
    linker
        .define_trappable_func(
            "env",
            "inc",
            &[ValKind::I32],
            &[ValKind::I32],
            Box::new(|_caller, params, results| {
                if let Val::I32(v) = params[0] {
                    if v < 0 {
                        return Err("boom_js_sentinel".to_string());
                    }
                    results[0] = Val::I32(v + 5);
                }
                Ok(())
            }),
        )
        .unwrap();

    let inst = Instance::new(&store, &module, Some(&linker)).unwrap();
    let res = inst
        .call("call", &[Val::I32(10)], &[ValKind::I32])
        .unwrap();
    assert_eq!(res, vec![Val::I32(15)]);

    let trap_err = inst.call("call", &[Val::I32(-1)], &[ValKind::I32]).unwrap_err();
    assert_eq!(trap_err.kind(), ErrorKind::HostTrap);
    assert!(trap_err.message().contains("boom_js_sentinel"));
}

#[test]
fn shared_memory_global_table_and_host_table_func() {
    let engine = Engine::new().unwrap();
    let store = Store::new(&engine).unwrap();

    // Shared memory grow(0) bumps grow_seq
    let mut mem = Memory::new(1, Some(3), false, false).unwrap();
    let s0 = mem.grow_seq();
    assert_eq!(mem.grow(0), Some(1));
    assert_eq!(mem.grow_seq(), s0 + 1);
    assert_eq!(mem.grow(1), Some(1));
    assert_eq!(mem.pages(), 2);

    // Shared global (mutable & immutable)
    let g_mut = Global::new(ValKind::I32, true, Val::I32(100)).unwrap();
    let g_const = Global::new(ValKind::I32, false, Val::I32(7)).unwrap();
    assert!(g_const.set(Val::I32(8)).is_err());

    // Shared table (funcref) + TableHostFunc invoked via call_indirect
    let tbl = Table::new(ValKind::FuncRef, 2, Some(4), 0, None).unwrap();
    let called = std::sync::Arc::new(AtomicI32::new(0));
    let called2 = called.clone();
    let thf = TableHostFunc::new(
        &[ValKind::I32],
        &[ValKind::I32],
        99,
        Box::new(move |_caller, params, results| {
            if let Val::I32(x) = params[0] {
                called2.store(x, Ordering::SeqCst);
                results[0] = Val::I32(x * 10);
            }
            Ok(())
        }),
    )
    .unwrap();
    assert!(tbl.set_host_func(0, &thf));
    assert!(matches!(tbl.get_entry(0), Some(TableEntry::Func { raw: 99, .. })));

    // Guest imports env.m, env.g, env.t; exports call_tbl(idx, arg), get_g(), set_g(v)
    let wasm: &[u8] = &[
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x10, 0x03, 0x60, 0x01, 0x7f, 0x01,
        0x7f, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x7f, 0x02, 0x1f, 0x03, 0x03,
        b'e', b'n', b'v', 0x01, b'g', 0x03, 0x7f, 0x01, 0x03, b'e', b'n', b'v', 0x01, b't', 0x01,
        0x70, 0x01, 0x02, 0x04, 0x03, b'e', b'n', b'v', 0x01, b'm', 0x02, 0x01, 0x01, 0x03, 0x03,
        0x03, 0x02, 0x01, 0x02, 0x07, 0x14, 0x02, 0x08, b'c', b'a', b'l', b'l', b'_', b't', b'b',
        b'l', 0x00, 0x00, 0x05, b'g', b'e', b't', b'_', b'g', 0x00, 0x01, 0x0a, 0x10, 0x02, 0x09,
        0x00, 0x20, 0x01, 0x20, 0x00, 0x11, 0x00, 0x00, 0x0b, 0x04, 0x00, 0x23, 0x00, 0x0b,
    ];
    let module = Module::compile(&engine, wasm).unwrap();
    let mut linker = Linker::new().unwrap();
    linker.define_global("env", "g", &g_mut).unwrap();
    linker.define_table("env", "t", &tbl).unwrap();
    linker.define_memory("env", "m", &mem).unwrap();

    let inst = Instance::new(&store, &module, Some(&linker)).unwrap();
    assert_eq!(
        inst.call("get_g", &[], &[ValKind::I32]).unwrap(),
        vec![Val::I32(100)]
    );
    g_mut.set(Val::I32(250)).unwrap();
    assert_eq!(
        inst.call("get_g", &[], &[ValKind::I32]).unwrap(),
        vec![Val::I32(250)]
    );

    assert_eq!(
        inst.call("call_tbl", &[Val::I32(0), Val::I32(6)], &[ValKind::I32])
            .unwrap(),
        vec![Val::I32(60)]
    );
    assert_eq!(called.load(Ordering::SeqCst), 6);
}

#[test]
fn wasi_host_args_env_preopen_and_return_on_exit() {
    let dir = std::env::temp_dir().join("wasmz_rust_wasi_test");
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("hello.txt"), b"hello wasmz").unwrap();

    // WASI module: calls args_sizes_get (saves argc into mem[0]) & proc_exit(42)
    let wasm: &[u8] = &[
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0e, 0x03, 0x60, 0x02, 0x7f, 0x7f,
        0x01, 0x7f, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x00, 0x02, 0x4c, 0x02, 0x16, b'w', b'a',
        b's', b'i', b'_', b's', b'n', b'a', b'p', b's', b'h', b'o', b't', b'_', b'p', b'r', b'e',
        b'v', b'i', b'e', b'w', b'1', 0x0e, b'a', b'r', b'g', b's', b'_', b's', b'i', b'z', b'e',
        b's', b'_', b'g', b'e', b't', 0x00, 0x00, 0x16, b'w', b'a', b's', b'i', b'_', b's', b'n',
        b'a', b'p', b's', b'h', b'o', b't', b'_', b'p', b'r', b'e', b'v', b'i', b'e', b'w', b'1',
        0x09, b'p', b'r', b'o', b'c', b'_', b'e', b'x', b'i', b't', 0x00, 0x01, 0x03, 0x02, 0x01,
        0x02, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x13, 0x02, 0x06, b'm', b'e', b'm', b'o', b'r',
        b'y', 0x02, 0x00, 0x06, b'_', b's', b't', b'a', b'r', b't', 0x00, 0x02, 0x0a, 0x0f, 0x01,
        0x0d, 0x00, 0x41, 0x00, 0x41, 0x04, 0x10, 0x00, 0x1a, 0x41, 0x2a, 0x10, 0x01, 0x0b,
    ];

    let engine = Engine::new().unwrap();
    let store = Store::new(&engine).unwrap();
    let module = Module::compile(&engine, wasm).unwrap();

    let mut wasi = WasiHost::new().unwrap();
    wasi.set_args(&["prog", "--flag", "val"]).unwrap();
    wasi.set_env(&[("FOO", "BAR")]).unwrap();
    wasi.add_preopen("/sandbox", dir.to_str().unwrap()).unwrap();
    wasi.set_return_on_exit(true);

    let mut linker = Linker::new().unwrap();
    linker.add_wasi(&mut wasi).unwrap();

    let inst = Instance::new(&store, &module, Some(&linker)).unwrap();
    let err = inst.call_start().unwrap_err();
    assert_eq!(err.kind(), ErrorKind::HostTrap);
    assert_eq!(wasi.exit_code(), Some(42));

    let mem = inst.export_memory("memory").unwrap();
    let bytes = unsafe { mem.as_slice() };
    let argc = u32::from_le_bytes(bytes[0..4].try_into().unwrap());
    assert_eq!(argc, 3);

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn instance_outlives_dropped_linker_with_host_imports() {
    // Module: imports env.inc(i32)->i32, exports run(i32)->i32 calling import 0
    let wasm: &[u8] = &[
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01,
        0x7f, 0x02, 0x0b, 0x01, 0x03, b'e', b'n', b'v', 0x03, b'i', b'n', b'c', 0x00, 0x00, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, b'r', b'u', b'n', 0x00, 0x01, 0x0a, 0x08, 0x01,
        0x06, 0x00, 0x20, 0x00, 0x10, 0x00, 0x0b,
    ];

    let engine = Engine::new().unwrap();
    let store = Store::new(&engine).unwrap();
    let module = Module::compile(&engine, wasm).unwrap();

    let inst = {
        let mut linker = Linker::new().unwrap();
        linker
            .define_trappable_func(
                "env",
                "inc",
                &[ValKind::I32],
                &[ValKind::I32],
                Box::new(|_caller, params, results| {
                    let Val::I32(v) = params[0] else {
                        return Err("expected i32".into());
                    };
                    results[0] = Val::I32(v + 10);
                    Ok(())
                }),
            )
            .unwrap();
        Instance::new(&store, &module, Some(&linker)).unwrap()
    };

    assert_eq!(
        inst.call("run", &[Val::I32(7)], &[ValKind::I32]).unwrap(),
        vec![Val::I32(17)]
    );
}

#[test]
fn instance_outlives_dropped_module_and_source_bytes_and_reinstantiates_data() {
    // Module with active data segment writing 0x2a at memory[0], exporting memory & add(i32,i32)->i32
    let wasm_bytes = vec![
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f,
        0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x10, 0x02, 0x03,
        b'a', b'd', b'd', 0x00, 0x00, 0x06, b'm', b'e', b'm', b'o', b'r', b'y', 0x02, 0x00, 0x0a,
        0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b, 0x0b, 0x07, 0x01, 0x00, 0x41,
        0x00, 0x0b, 0x01, 0x2a,
    ];

    let engine = Engine::new().unwrap();
    let store = Store::new(&engine).unwrap();
    let inst1 = {
        let mut buf = wasm_bytes.clone();
        let module = Module::compile(&engine, &buf).unwrap();
        // Zero and drop input buffer immediately before calling or re-instantiating.
        buf.fill(0);
        drop(buf);
        let i1 = Instance::new(&store, &module, None).unwrap();
        let i2 = Instance::new(&store, &module, None).unwrap();
        let mem2 = i2.export_memory("memory").unwrap();
        assert_eq!(unsafe { mem2.as_slice()[0] }, 0x2a);
        assert_eq!(
            i2.call("add", &[Val::I32(10), Val::I32(20)], &[ValKind::I32])
                .unwrap(),
            vec![Val::I32(30)]
        );
        drop(module);
        i1
    };

    let mem1 = inst1.export_memory("memory").unwrap();
    assert_eq!(unsafe { mem1.as_slice()[0] }, 0x2a);
    assert_eq!(
        inst1
            .call("add", &[Val::I32(1), Val::I32(2)], &[ValKind::I32])
            .unwrap(),
        vec![Val::I32(3)]
    );
}

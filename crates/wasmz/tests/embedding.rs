use wasmz::{Engine, Instance, Linker, Module, Store, Val, ValKind};

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

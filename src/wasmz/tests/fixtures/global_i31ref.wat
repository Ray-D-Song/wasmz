(module
  (global $g i31ref (ref.i31 (i32.const 42)))
  (func (export "f") (result i32)
    (i31.get_u (global.get $g))))

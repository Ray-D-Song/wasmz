(module
  (func $f)
  (global $g (ref func) (ref.func $f))
  (func (export "is_null") (result i32)
    (ref.is_null (global.get $g))))

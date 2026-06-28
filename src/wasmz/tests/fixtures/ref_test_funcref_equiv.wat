(module
  (type $a (func (result i32)))
  (type $b (func (result i32)))
  (func $fa (type $a) (i32.const 42))
  (func (export "test_a_on_b") (result i32)
    (ref.func $fa)
    (ref.test (ref $b))))

(module
  (type $ft (func (result i32)))
  (func $fa (type $ft) (i32.const 42))
  (func (export "test_concrete") (result i32)
    (ref.func $fa)
    (ref.test (ref $ft)))
  (func (export "test_abstract") (result i32)
    (ref.func $fa)
    (ref.test (ref func))))

(module
  (type $a (sub (struct (field i32))))
  (type $b (sub (struct (field i32))))
  (func (export "test_a_on_b") (result i32)
    (struct.new $b (i32.const 1))
    (ref.test (ref $a)))
  (func (export "test_b_on_a") (result i32)
    (struct.new $a (i32.const 1))
    (ref.test (ref $b))))

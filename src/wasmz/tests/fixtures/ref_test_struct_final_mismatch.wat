;; Source for ref_test_struct_final_mismatch.wasm (hand-encoded: watc emits 0x50 not 0x4f for sub final).
(module
  (type $a (sub final (struct (field i32))))
  (type $b (sub (struct (field i32))))
  (func (export "f") (result i32)
    (struct.new $b (i32.const 1))
    (ref.test (ref $a))))

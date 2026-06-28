(module
  (type $ft (func (result i32)))
  (type $ft2 (func (result i32)))
  (func $fa (type $ft) (i32.const 42))
  (func (export "call_via_cast") (result i32)
    (call_ref $ft2 (ref.cast (ref $ft2) (ref.func $fa)))))

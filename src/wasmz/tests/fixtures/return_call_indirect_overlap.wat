(module
  (type $sig (func (param i32 i32) (result i32)))
  (table 1 funcref)
  (elem (i32.const 0) func $target)
  (func $target (type $sig) (param i32 i32) (result i32)
    local.get 1)
  (func (export "run") (result i32)
    (local i32 i32 i32 i32)
    i32.const 111
    local.set 3
    i32.const 222
    local.set 0
    local.get 3
    local.get 0
    i32.const 0
    return_call_indirect (type $sig)))

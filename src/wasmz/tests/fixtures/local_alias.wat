;; Regression fixtures for operand-stack values that alias a local which is
;; later overwritten by local.set / local.tee.
(module
  ;; Returns the value local 1 held *before* the local.tee, so a stale read of
  ;; local 1 (or a mis-fused local.set) yields param0 & 255 instead of param1.
  (func (export "alias_after_tee") (param i32 i32) (result i32)
    local.get 1
    local.get 0
    i32.const 255
    i32.and
    local.tee 1
    drop)

  ;; Two CRC16 rounds lifted from CoreMark's crc16 helper. Both rounds read
  ;; local 1 and local 2 across a local.tee that rewrites them.
  (func (export "crc16_two_rounds") (param i32 i32) (result i32)
    (local i32)
    local.get 1
    i32.const 1
    i32.shr_u
    local.tee 2
    i32.const -24575
    i32.xor
    local.get 2
    local.get 0
    local.get 1
    i32.xor
    i32.const 1
    i32.and
    select
    local.tee 1
    i32.const 1
    i32.shr_u
    i32.const 32767
    i32.and
    local.tee 2
    i32.const -24575
    i32.xor
    local.get 2
    local.get 1
    local.get 0
    i32.const 255
    i32.and
    local.tee 1
    i32.const 1
    i32.shr_u
    i32.xor
    i32.const 1
    i32.and
    select))

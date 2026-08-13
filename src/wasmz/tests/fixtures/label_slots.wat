;; Fixtures for block/loop label slot binding.
(module
  (memory (export "memory") 1)

  (func (export "store") (param $addr i32) (param $val i64)
    (i64.store (local.get $addr) (local.get $val)))

  (func (export "load") (param $addr i32) (result i64)
    (i64.load (local.get $addr)))

  ;; The insertion sort Rust emits for short slices, lifted out of a
  ;; `sort_unstable` build. Its `block (result i32)` receives the loop base
  ;; pointer (a local) from a `br_if` and a computed address from the
  ;; fall-through path.
  (func (export "isort") (param $base i32) (param $n i32)
    (local $cursor i32)
    (local $end i32)
    (local $off i32)
    (local $i0 i32)
    (local $hole i32)
    (local $v i64)
    (local $p i64)
    local.get $base
    i32.const 8
    i32.add
    local.set $cursor
    local.get $base
    local.get $n
    i32.const 3
    i32.shl
    i32.add
    local.set $end
    (loop $outer
      local.get $cursor
      i64.load
      local.tee $v
      local.get $cursor
      i32.const 8
      i32.sub
      i64.load
      local.tee $p
      i64.lt_u
      (if
        (then
          local.get $off
          local.set $i0
          (block $exit (result i32)
            (loop $inner
              local.get $i0
              local.get $base
              i32.add
              i32.const 8
              i32.add
              local.get $p
              i64.store
              local.get $base
              local.get $i0
              i32.eqz
              br_if $exit
              drop
              local.get $v
              local.get $i0
              i32.const 8
              i32.sub
              local.tee $i0
              local.get $base
              i32.add
              local.tee $hole
              i64.load
              local.tee $p
              i64.lt_u
              br_if $inner)
            local.get $hole
            i32.const 8
            i32.add)
          local.get $v
          i64.store))
      local.get $off
      i32.const 8
      i32.add
      local.set $off
      local.get $cursor
      i32.const 8
      i32.add
      local.tee $cursor
      local.get $end
      i32.ne
      br_if $outer))

  ;; Same shape, reduced: the `br_if` path delivers `$base` (a local's slot)
  ;; and the fall-through path delivers a computed value. Returns
  ;; `block_result + $base * 1000` so a clobbered `$base` is visible.
  (func (export "block_result_from_local") (param $base i32) (param $off i32) (result i32)
    (local $addr i32)
    (block $exit (result i32)
      (loop $l
        local.get $base
        local.get $off
        i32.eqz
        br_if $exit
        drop
        local.get $off
        i32.const 1
        i32.sub
        local.tee $off
        local.get $base
        i32.add
        local.tee $addr
        br_if $l)
      local.get $addr
      i32.const 100
      i32.add)
    local.get $base
    i32.const 1000
    i32.mul
    i32.add)

  ;; `br_table` hands the same operand to every target, so no target's label
  ;; slot may be renamed onto it.
  (func (export "br_table_shared_value") (param $sel i32) (param $v i32) (result i32)
    (block $a (result i32)
      (block $b (result i32)
        local.get $v
        i32.const 10
        i32.add
        local.get $sel
        br_table $a $b $b)
      i32.const 100
      i32.add)))

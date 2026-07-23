//! Scalar i32 workload for comptime-static handler benchmarking.
//!
//! Build to WASM:
//!   zig build-exe bench/simd_fixture.zig -target wasm32-freestanding -O ReleaseFast \
//!     -fno-entry --export=_start -femit-bin=bench/workloads/simd_ops.wasm

const iterations: i32 = 10_000_000;

fn benchScalarOps(n: i32) i32 {
    var acc: i32 = 0;
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        acc +%= 1;
        acc -%= 1;
        acc +%= i;
        if (acc == i) acc +%= 1;
    }
    return acc;
}

export fn _start() noreturn {
    _ = benchScalarOps(iterations);
    @trap();
}

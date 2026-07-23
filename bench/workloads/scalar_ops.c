#include <stdint.h>

static volatile int32_t sink;

static int32_t bench_scalar_ops(int32_t n) {
    int32_t acc = 0;
    for (int32_t i = 0; i < n; i++) {
        acc = acc + 1;
        acc = acc - 1;
        acc = acc + i;
        if (acc == i) {
            acc = acc + 1;
        }
    }
    return acc;
}

int main(void) {
    sink = bench_scalar_ops(10000000);
    return 0;
}

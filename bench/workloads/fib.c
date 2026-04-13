#include <stdio.h>

static long fib(int n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

int main(void) {
    printf("%ld\n", fib(40));
    return 0;
}

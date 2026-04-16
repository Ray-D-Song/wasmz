#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

QJS_WASM="$SCRIPT_DIR/quickjs/package/qjs-wasi.wasm"
WASMZ="$REPO_DIR/zig-out/bin/wasmz"

QJS_SCRIPT="function fib(n){return n<=1?n:fib(n-1)+fib(n-2)} print(fib(25))"

make -C "$REPO_DIR" build-debug

"$WASMZ" "$QJS_WASM" --mem-stats --mem-trace --args "-e '$QJS_SCRIPT'"

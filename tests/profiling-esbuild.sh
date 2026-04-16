#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

WASMZ="$REPO_DIR/zig-out/bin/wasmz"
ESBUILD_WASM="$SCRIPT_DIR/esbuild/package/esbuild.wasm"
ESBUILD_SOURCE="$SCRIPT_DIR/esbuild/source.js"

make -C "$REPO_DIR" build-debug

"$WASMZ" "$ESBUILD_WASM" --mem-stats --mem-trace --args "--bundle --platform=node --sourcefile=source.js" < "$ESBUILD_SOURCE" > /dev/null

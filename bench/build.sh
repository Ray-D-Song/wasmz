#!/usr/bin/env bash
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$BENCH_DIR")"
PROJECTS_DIR="$BENCH_DIR/projects"

WASMZ_BIN="$REPO_DIR/zig-out/bin/wasmz"
WASM3_DIR="$PROJECTS_DIR/wasm3"
WASM3_BIN="$WASM3_DIR/build/wasm3"
WASMI_DIR="$PROJECTS_DIR/wasmi"
WASMI_BIN="$WASMI_DIR/target/release/wasmi"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "» $*"; }

build_wasmz() {
    info "Building wasmz..."
    cd "$REPO_DIR"
    make release
    [[ -x "$WASMZ_BIN" ]] || die "wasmz build failed"
    info "wasmz built: $WASMZ_BIN"
}

build_wasm3() {
    info "Building wasm3..."
    mkdir -p "$WASM3_DIR/build"
    cd "$WASM3_DIR/build"
    cmake .. -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    make -j$(sysctl -n hw.ncpu)
    [[ -x "$WASM3_BIN" ]] || die "wasm3 build failed"
    info "wasm3 built: $WASM3_BIN"
}

build_wasmi() {
    info "Building wasmi_cli..."
    cd "$WASMI_DIR"
    cargo build --release -p wasmi_cli
    [[ -x "$WASMI_BIN" ]] || die "wasmi_cli build failed"
    info "wasmi_cli built: $WASMI_BIN"
}

build_all() {
    build_wasmz
    build_wasm3
    build_wasmi
}

case "${1:-all}" in
    wasmz)  build_wasmz ;;
    wasm3)  build_wasm3 ;;
    wasmi)  build_wasmi ;;
    all)    build_all ;;
    *)      die "Unknown target: $1. Use: wasmz, wasm3, wasmi, or all" ;;
esac

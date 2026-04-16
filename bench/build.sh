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
WAMR_DIR="$PROJECTS_DIR/wamr"

get_wamr_platform() {
    case "$(uname -s)" in
        Darwin*) echo "darwin" ;;
        *)       echo "linux" ;;
    esac
}

WAMR_BIN="$WAMR_DIR/product-mini/platforms/$(get_wamr_platform)/build/iwasm"

NCPU=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

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
    make -j$NCPU
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

build_wamr() {
    info "Building wamr..."

    local WAMR_TARGET=""
    local WAMR_PLATFORM="linux"
    case "$(uname -s)" in
        Darwin*)
            WAMR_PLATFORM="darwin"
            case "$(uname -m)" in
                arm64*)  WAMR_TARGET="AARCH64" ;;
                x86_64*) WAMR_TARGET="X86_64" ;;
            esac
            ;;
        Linux*)
            case "$(uname -m)" in
                aarch64*) WAMR_TARGET="AARCH64" ;;
                x86_64*)  WAMR_TARGET="X86_64" ;;
            esac
            ;;
    esac

    mkdir -p "$WAMR_DIR/product-mini/platforms/$WAMR_PLATFORM/build"
    cd "$WAMR_DIR/product-mini/platforms/$WAMR_PLATFORM/build"
    cmake .. \
        -DWAMR_BUILD_TARGET=$WAMR_TARGET \
        -DWAMR_BUILD_INTERP=1 \
        -DWAMR_BUILD_AOT=0 \
        -DWAMR_BUILD_FAST_JIT=0 \
        -DWAMR_BUILD_JIT=0 \
        -DWAMR_BUILD_SIMD=0
    make -j$NCPU
    [[ -x "$WAMR_BIN" ]] || die "wamr build failed"
    info "wamr built: $WAMR_BIN"
}

build_all() {
    build_wasmz
    build_wasm3
    build_wasmi
    build_wamr
}

case "${1:-all}" in
    wasmz)  build_wasmz ;;
    wasm3)  build_wasm3 ;;
    wasmi)  build_wasmi ;;
    wamr)   build_wamr ;;
    all)    build_all ;;
    *)      die "Unknown target: $1. Use: wasmz, wasm3, wasmi, wamr, or all" ;;
esac

#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH_DIR="$REPO_DIR/bench"
PROJECTS_DIR="$BENCH_DIR/projects"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "» $*"; }

require_cmd() {
    local cmd="$1"
    local hint="$2"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "  - $cmd ($hint)" >&2
        return 1
    fi
    return 0
}

info "Checking development tools..."

if command -v mise >/dev/null 2>&1 && [[ -f "$REPO_DIR/mise.toml" ]]; then
    info "Installing tool versions from mise.toml..."
    (cd "$REPO_DIR" && mise install)
fi

missing=0
require_cmd git "https://git-scm.com" || missing=1
require_cmd zig "https://ziglang.org/download/ or: mise install" || missing=1
require_cmd cmake "Fedora: sudo dnf install cmake" || missing=1
require_cmd make "Fedora: sudo dnf install make" || missing=1
require_cmd gcc "Fedora: sudo dnf install gcc" || missing=1
require_cmd g++ "Fedora: sudo dnf install gcc-c++" || missing=1
require_cmd cargo "Fedora: sudo dnf install rust cargo" || missing=1
require_cmd hyperfine "Fedora: sudo dnf install hyperfine" || missing=1

if [[ "$missing" -ne 0 ]]; then
    die "Install the missing tools above, then rerun: make deps"
fi

info "Initializing benchmark submodules..."
for mod_path in bench/projects/wasm3 bench/projects/wasmi bench/projects/wamr; do
    mod_dir="$REPO_DIR/$mod_path"
    if [[ -e "$mod_dir/.git" ]]; then
        continue
    fi
    if [[ -d "$mod_dir" ]] && [[ -n "$(ls -A "$mod_dir" 2>/dev/null)" ]]; then
        info "Removing stale $mod_path (submodule not initialized)..."
        rm -rf "$mod_dir"
    fi
done
(cd "$REPO_DIR" && git submodule update --init --recursive)

for mod in wasm3 wasmi wamr; do
    mod_dir="$PROJECTS_DIR/$mod"
    if [[ ! -d "$mod_dir" ]] || [[ -z "$(ls -A "$mod_dir" 2>/dev/null)" ]]; then
        die "Submodule bench/projects/$mod is empty. Try: git submodule update --init --recursive"
    fi
done

[[ -f "$PROJECTS_DIR/wasm3/CMakeLists.txt" ]] \
    || die "wasm3 submodule is missing CMakeLists.txt"
[[ -f "$PROJECTS_DIR/wasmi/Cargo.toml" ]] \
    || die "wasmi submodule is missing Cargo.toml"
[[ -f "$PROJECTS_DIR/wamr/product-mini/platforms/linux/CMakeLists.txt" ]] \
    || die "wamr submodule is missing product-mini/platforms/linux/CMakeLists.txt"

fixtures=(
    "$BENCH_DIR/workloads/fib30.wasm"
    "$REPO_DIR/tests/quickjs/package/qjs-wasi.wasm"
    "$REPO_DIR/tests/esbuild/package/esbuild.wasm"
    "$REPO_DIR/tests/esbuild/source.js"
)
for fixture in "${fixtures[@]}"; do
    [[ -f "$fixture" ]] || die "Missing benchmark fixture: $fixture"
done

info "All benchmark dependencies are ready."

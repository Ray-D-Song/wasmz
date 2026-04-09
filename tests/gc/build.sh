#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MODE="${1:-build}"

case "$MODE" in
  build)
    echo "==> Building Kotlin/Wasm WASI production executable..."
    gradle compileProductionExecutableKotlinWasmWasi

    echo
    echo "==> Build finished"

    echo
    echo "==> build/libs:"
    ls -lh build/libs || true

    JAR_FILE="$(find build/libs -maxdepth 1 -type f -name '*.jar' | head -n 1 || true)"

    if [ -n "$JAR_FILE" ]; then
      echo
      echo "==> Inspecting jar contents: $JAR_FILE"
      jar tf "$JAR_FILE" | grep -E 'wasm|mjs|js' || true
    fi
    ;;
  run)
    echo "==> Running Kotlin/Wasm WASI production executable..."
    gradle wasmWasiNodeProductionRun
    ;;
  dev)
    echo "==> Running Kotlin/Wasm WASI development executable..."
    gradle wasmWasiNodeDevelopmentRun
    ;;
  tasks)
    echo "==> wasm-related tasks:"
    gradle tasks --all | grep -i wasm || true
    ;;
  *)
    echo "Usage: $0 [build|run|dev|tasks]"
    exit 1
    ;;
esac
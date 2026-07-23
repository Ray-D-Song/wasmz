#!/usr/bin/env bash
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$BENCH_DIR")"
# shellcheck source=compare_cli.sh
source "$BENCH_DIR/compare_cli.sh"

DEFAULT_CLI="$REPO_DIR/zig-out/bin/wasmz"
BASELINE="$(resolve_baseline_cli "$DEFAULT_CLI")"
CANDIDATE="$(resolve_candidate_cli "$DEFAULT_CLI")"

WORKLOAD="${WORKLOAD:-$BENCH_DIR/workloads/simd_ops.wasm}"
FIXTURE_SRC="$BENCH_DIR/simd_fixture.zig"
RESULTS_DIR="$BENCH_DIR/results/comptime"
TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
HYPERFINE_JSON="$RESULTS_DIR/hyperfine-${TIMESTAMP}.json"
REPORT_JSON="$RESULTS_DIR/report-${TIMESTAMP}.json"

RUNS="${RUNS:-20}"
WARMUP="${WARMUP:-5}"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "» $*"; }

build_workload() {
  if [[ -f "$WORKLOAD" ]]; then
    return 0
  fi
  info "Building workload from simd_fixture.zig..."
  mkdir -p "$(dirname "$WORKLOAD")"
  zig build-exe "$FIXTURE_SRC" \
    -target wasm32-freestanding \
    -O ReleaseFast \
    -fno-entry \
    --export=_start \
    -femit-bin="$WORKLOAD"
  [[ -f "$WORKLOAD" ]] || die "failed to build $WORKLOAD"
}

# Rebuild fixture when source is newer than the emitted wasm.
refresh_workload() {
  if [[ ! -f "$WORKLOAD" || "$FIXTURE_SRC" -nt "$WORKLOAD" ]]; then
    info "Refreshing workload from simd_fixture.zig..."
    mkdir -p "$(dirname "$WORKLOAD")"
    zig build-exe "$FIXTURE_SRC" \
      -target wasm32-freestanding \
      -O ReleaseFast \
      -fno-entry \
      --export=_start \
      -femit-bin="$WORKLOAD"
    [[ -f "$WORKLOAD" ]] || die "failed to build $WORKLOAD"
  fi
}

preflight() {
  command -v hyperfine >/dev/null || die "hyperfine not found — run: brew install hyperfine"
  command -v zig >/dev/null || die "zig not found"
  require_executable "$BASELINE" "BASELINE_CLI" || die "baseline CLI missing: $BASELINE"
  require_executable "$CANDIDATE" "CANDIDATE_CLI" || die "candidate CLI missing: $CANDIDATE"
  refresh_workload
  [[ -f "$WORKLOAD" ]] || die "workload not found: $WORKLOAD"
  mkdir -p "$RESULTS_DIR"
}

info "Comptime static benchmark"
info "Baseline : $BASELINE"
info "Candidate: $CANDIDATE"
info "Workload : $WORKLOAD"
preflight

SZ_BASELINE="$(binary_size "$BASELINE")"
SZ_CANDIDATE="$(binary_size "$CANDIDATE")"

info "Running hyperfine (${RUNS} runs, warmup ${WARMUP})..."
run_dual_hyperfine "$WORKLOAD" "$BASELINE" "$CANDIDATE" "$HYPERFINE_JSON" "$RUNS" "$WARMUP"

emit_compare_json \
  "$REPO_DIR" \
  "$BASELINE" \
  "$CANDIDATE" \
  "$SZ_BASELINE" \
  "$SZ_CANDIDATE" \
  "$WORKLOAD" \
  "$HYPERFINE_JSON" \
  "$REPORT_JSON" \
  "$RUNS" \
  "$WARMUP"

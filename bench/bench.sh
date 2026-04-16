#!/usr/bin/env bash
set -euo pipefail

# ─── paths ────────────────────────────────────────────────────────────────────
BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$BENCH_DIR")"

PROJECTS_DIR="$BENCH_DIR/projects"
WASMZ="$REPO_DIR/zig-out/bin/wasmz"
WASM3="$PROJECTS_DIR/wasm3/build/wasm3"
WASMI="$PROJECTS_DIR/wasmi/target/release/wasmi"
WAMR="$PROJECTS_DIR/wamr/product-mini/platforms/linux/build/iwasm"
BUILD_SCRIPT="$BENCH_DIR/build.sh"

FIB_WASM="$BENCH_DIR/workloads/fib30.wasm"
QJS_WASM="$REPO_DIR/tests/quickjs/package/qjs-wasi.wasm"
ESBUILD_WASM="$REPO_DIR/tests/esbuild/package/esbuild.wasm"
ESBUILD_SOURCE="$REPO_DIR/tests/esbuild/source.js"

RESULTS_DIR="$BENCH_DIR/results"
TIMESTAMP="$(date '+%Y-%m-%d_%H-%M')"
REPORT="$RESULTS_DIR/report-${TIMESTAMP}.md"
HYPERFINE_DIR="$RESULTS_DIR/hyperfine"

RUNS=10
WARMUP=2

# ─── helpers ──────────────────────────────────────────────────────────────────
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "» $*"; }

# Returns peak RSS in bytes for a single run.
measure_rss() {
  case "$(uname -s)" in
    Darwin*)
      /usr/bin/time -l "$@" 2>&1 >/dev/null \
        | awk '/maximum resident set size/ { print $1 }'
      ;;
    *)
      python3 - "$@" << 'PYEOF'
import subprocess, sys, time, os, signal

cmd = sys.argv[1:]
proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

peak_rss = 0
while True:
    try:
        out = subprocess.check_output(
            ["ps", "-o", "rss=", "-p", str(proc.pid)],
            stderr=subprocess.DEVNULL, text=True
        ).strip()
        if out:
            rss = int(out) * 1024  # KB -> bytes
            if rss > peak_rss:
                peak_rss = rss
    except subprocess.CalledProcessError:
        pass

    ret = proc.poll()
    if ret is not None:
        break
    time.sleep(0.01)

proc.wait()
print(peak_rss)
PYEOF
      ;;
  esac
}

# Returns time-averaged RSS in bytes for a single run.
#
# Starts the target process in the background, then polls `ps -o rss=` every
# SAMPLE_INTERVAL_MS milliseconds until the process exits.  The arithmetic
# mean of all RSS samples is printed (in bytes).
#
# Accuracy notes:
#   - For processes that run < ~200 ms the sample count will be low (1–2);
#     the number shown is still correct for those samples, just noisier.
#   - ps RSS is in KB on macOS; we convert to bytes before averaging.
#
# Usage: measure_avg_rss cmd [args...]
SAMPLE_INTERVAL_MS=100
measure_avg_rss() {
  python3 - "$@" << 'PYEOF'
import subprocess, sys, time, os, signal

INTERVAL = int(os.environ.get("SAMPLE_INTERVAL_MS", "100")) / 1000.0

cmd = sys.argv[1:]
proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

samples = []
while True:
    # Sample RSS (KB) via ps; ps may return nothing if the process just exited.
    try:
        out = subprocess.check_output(
            ["ps", "-o", "rss=", "-p", str(proc.pid)],
            stderr=subprocess.DEVNULL, text=True
        ).strip()
        if out:
            samples.append(int(out) * 1024)   # KB → bytes
    except subprocess.CalledProcessError:
        pass   # process already gone

    ret = proc.poll()
    if ret is not None:
        break
    time.sleep(INTERVAL)

# Ensure process is gone
proc.wait()

if samples:
    print(sum(samples) // len(samples))
else:
    print(0)
PYEOF
}

# File size in bytes
binary_size() {
  case "$(uname -s)" in
    Darwin*) stat -f "%z" "$1" ;;
    *)       stat -c "%s" "$1" ;;
  esac
}

# Human-readable bytes
human_bytes() {
  python3 -c "
b = $1
if b >= 1048576: print('%.1f MB' % (b/1048576))
elif b >= 1024:  print('%.1f KB' % (b/1024))
else:            print('%d B' % b)
"
}

# Parse median from hyperfine JSON (in ms)
parse_median_ms() {
  local json_file="$1" name="$2"
  python3 -c "
import json
data = json.load(open('$json_file'))
for r in data['results']:
    if r['command'] == '$name':
        print('%.1f' % (r['median'] * 1000))
        break
"
}

# ─── preflight ────────────────────────────────────────────────────────────────
info "Checking prerequisites..."
command -v hyperfine >/dev/null || die "hyperfine not found — run: brew install hyperfine"
[[ -f "$FIB_WASM" ]]     || die "fib.wasm not found"
[[ -f "$QJS_WASM" ]]     || die "qjs-wasi.wasm not found"
[[ -f "$ESBUILD_WASM" ]] || die "esbuild.wasm not found"

need_build=""
[[ -x "$WASMZ" ]] || need_build="wasmz"
[[ -x "$WASM3" ]] || need_build="${need_build:+$need_build }wasm3"
[[ -x "$WASMI" ]] || need_build="${need_build:+$need_build }wasmi"
[[ -x "$WAMR" ]] || need_build="${need_build:+$need_build }wamr"

if [[ -n "$need_build" ]]; then
    info "Missing binaries: $need_build"
    info "Running build script..."
    "$BUILD_SCRIPT" all
fi

mkdir -p "$HYPERFINE_DIR"

WASMZ_VER="dev (ReleaseFast)"
WASM3_VER="$("$WASM3" --version 2>&1 | head -1)"
WASMI_VER="$("$WASMI" --version 2>&1)"
WAMR_VER="$("$WAMR" --version 2>&1 | head -1)"
OS_INFO="$(uname -srm)"
DATE="$(date '+%Y-%m-%d %H:%M')"

info "wasmz  : $WASMZ_VER ($(uname -m))"
info "wasm3  : $WASM3_VER"
info "wasmi  : $WASMI_VER"
info "wamr   : $WAMR_VER"
echo ""

# ─── 1. binary sizes ──────────────────────────────────────────────────────────
info "Collecting binary sizes..."
SZ_WASMZ=$(binary_size "$WASMZ")
SZ_WASM3=$(binary_size "$WASM3")
SZ_WASMI=$(binary_size "$WASMI")
SZ_WAMR=$(binary_size "$WAMR")

# ─── 2. fib(30) — pure C computation ─────────────────────────────────────────
info "Benchmarking fib(30) [pure C computation]..."
hyperfine --style none --shell none --warmup "$WARMUP" --runs "$RUNS" \
  --export-json "$HYPERFINE_DIR/fib.json" \
  --command-name "wasmz" "$WASMZ $FIB_WASM" \
  --command-name "wasm3"  "$WASM3 $FIB_WASM" \
  --command-name "wasmi"  "$WASMI $FIB_WASM" \
  --command-name "wamr"   "$WAMR $FIB_WASM"

# ─── 3. QuickJS: fib(25) via inline JS eval ──────────────────────────────────
QJS_SCRIPT="function fib(n){return n<=1?n:fib(n-1)+fib(n-2)} print(fib(25))"
info "Benchmarking QuickJS fib(25) [1.4MB WASM, JS engine]..."
hyperfine --style none --warmup "$WARMUP" --runs "$RUNS" \
  --export-json "$HYPERFINE_DIR/quickjs.json" \
  --command-name "wasmz" "$WASMZ $QJS_WASM --args \"-e '$QJS_SCRIPT'\"" \
  --command-name "wasm3"  "$WASM3 $QJS_WASM -e '$QJS_SCRIPT'" \
  --command-name "wasmi"  "$WASMI $QJS_WASM -e '$QJS_SCRIPT'" \
  --command-name "wamr"   "$WAMR $QJS_WASM -e '$QJS_SCRIPT'"

# ─── 4. esbuild bundling ──────────────────────────────────────────────────────
info "Benchmarking esbuild [19MB WASM, JS bundler]..."
hyperfine --style none --warmup "$WARMUP" --runs "$RUNS" \
  --export-json "$HYPERFINE_DIR/esbuild.json" \
  --command-name "wasmz" \
    "sh -c '$WASMZ $ESBUILD_WASM --args \"--bundle --platform=node --sourcefile=source.js\" < $ESBUILD_SOURCE > /dev/null'" \
  --command-name "wasm3" \
    "sh -c '$WASM3 $ESBUILD_WASM --bundle --platform=node --sourcefile=source.js < $ESBUILD_SOURCE > /dev/null'" \
  --command-name "wasmi" \
    "sh -c '$WASMI $ESBUILD_WASM --bundle --platform=node --sourcefile=source.js < $ESBUILD_SOURCE > /dev/null'" \
  --command-name "wamr" \
    "sh -c '$WAMR $ESBUILD_WASM --bundle --platform=node --sourcefile=source.js < $ESBUILD_SOURCE > /dev/null'"

# ─── 5. peak RSS ──────────────────────────────────────────────────────────────
info "Measuring peak RSS for fib(30)..."
RSS_FIB_WASMZ=$(measure_rss "$WASMZ" "$FIB_WASM")
RSS_FIB_WASM3=$(measure_rss "$WASM3" "$FIB_WASM")
RSS_FIB_WASMI=$(measure_rss "$WASMI" "$FIB_WASM")
RSS_FIB_WAMR=$(measure_rss "$WAMR" "$FIB_WASM")

QJS_SCRIPT="function fib(n){return n<=1?n:fib(n-1)+fib(n-2)} print(fib(25))"
info "Measuring peak RSS for QuickJS fib(25)..."
RSS_QJS_WASMZ=$(measure_rss sh -c "\"$WASMZ\" \"$QJS_WASM\" --args \"-e 'function fib(n){return n<=1?n:fib(n-1)+fib(n-2)} print(fib(25))'\"")
RSS_QJS_WASM3=$(measure_rss sh -c "\"$WASM3\" \"$QJS_WASM\" -e 'function fib(n){return n<=1?n:fib(n-1)+fib(n-2)} print(fib(25))'")
RSS_QJS_WASMI=$(measure_rss sh -c "\"$WASMI\" \"$QJS_WASM\" -e 'function fib(n){return n<=1?n:fib(n-1)+fib(n-2)} print(fib(25))'")
RSS_QJS_WAMR=$(measure_rss sh -c "\"$WAMR\" \"$QJS_WASM\" -e 'function fib(n){return n<=1?n:fib(n-1)+fib(n-2)} print(fib(25))'")

info "Measuring peak RSS for esbuild..."
RSS_ESBUILD_WASMZ=$(measure_rss sh -c \
  "\"$WASMZ\" \"$ESBUILD_WASM\" --args '--bundle --platform=node --sourcefile=source.js' < \"$ESBUILD_SOURCE\" > /dev/null")
RSS_ESBUILD_WASM3=$(measure_rss sh -c \
  "\"$WASM3\" \"$ESBUILD_WASM\" --bundle --platform=node --sourcefile=source.js < \"$ESBUILD_SOURCE\" > /dev/null")
RSS_ESBUILD_WASMI=$(measure_rss sh -c \
  "\"$WASMI\" \"$ESBUILD_WASM\" --bundle --platform=node --sourcefile=source.js < \"$ESBUILD_SOURCE\" > /dev/null")
RSS_ESBUILD_WAMR=$(measure_rss sh -c \
  "\"$WAMR\" \"$ESBUILD_WASM\" --bundle --platform=node --sourcefile=source.js < \"$ESBUILD_SOURCE\" > /dev/null")

# ─── 5b. time-averaged RSS (ps sampled every SAMPLE_INTERVAL_MS during one run) ─
info "Measuring time-averaged RSS for fib(30)..."
AVG_FIB_WASMZ=$(measure_avg_rss "$WASMZ" "$FIB_WASM")
AVG_FIB_WASM3=$(measure_avg_rss "$WASM3" "$FIB_WASM")
AVG_FIB_WASMI=$(measure_avg_rss "$WASMI" "$FIB_WASM")
AVG_FIB_WAMR=$(measure_avg_rss "$WAMR" "$FIB_WASM")

info "Measuring time-averaged RSS for QuickJS fib(25)..."
AVG_QJS_WASMZ=$(measure_avg_rss sh -c "\"$WASMZ\" \"$QJS_WASM\" --args \"-e 'function fib(n){return n<=1?n:fib(n-1)+fib(n-2)} print(fib(25))'\"")
AVG_QJS_WASM3=$(measure_avg_rss sh -c "\"$WASM3\" \"$QJS_WASM\" -e 'function fib(n){return n<=1?n:fib(n-1)+fib(n-2)} print(fib(25))'")
AVG_QJS_WASMI=$(measure_avg_rss sh -c "\"$WASMI\" \"$QJS_WASM\" -e 'function fib(n){return n<=1?n:fib(n-1)+fib(n-2)} print(fib(25))'")
AVG_QJS_WAMR=$(measure_avg_rss sh -c "\"$WAMR\" \"$QJS_WASM\" -e 'function fib(n){return n<=1?n:fib(n-1)+fib(n-2)} print(fib(25))'")

info "Measuring time-averaged RSS for esbuild..."
AVG_ESBUILD_WASMZ=$(measure_avg_rss sh -c \
  "\"$WASMZ\" \"$ESBUILD_WASM\" --args '--bundle --platform=node --sourcefile=source.js' < \"$ESBUILD_SOURCE\" > /dev/null")
AVG_ESBUILD_WASM3=$(measure_avg_rss sh -c \
  "\"$WASM3\" \"$ESBUILD_WASM\" --bundle --platform=node --sourcefile=source.js < \"$ESBUILD_SOURCE\" > /dev/null")
AVG_ESBUILD_WASMI=$(measure_avg_rss sh -c \
  "\"$WASMI\" \"$ESBUILD_WASM\" --bundle --platform=node --sourcefile=source.js < \"$ESBUILD_SOURCE\" > /dev/null")
AVG_ESBUILD_WAMR=$(measure_avg_rss sh -c \
  "\"$WAMR\" \"$ESBUILD_WASM\" --bundle --platform=node --sourcefile=source.js < \"$ESBUILD_SOURCE\" > /dev/null")

# ─── 6. parse medians ─────────────────────────────────────────────────────────
MED_FIB_WASMZ=$(parse_median_ms "$HYPERFINE_DIR/fib.json" "wasmz")
MED_FIB_WASM3=$(parse_median_ms "$HYPERFINE_DIR/fib.json" "wasm3")
MED_FIB_WASMI=$(parse_median_ms "$HYPERFINE_DIR/fib.json" "wasmi")
MED_FIB_WAMR=$(parse_median_ms "$HYPERFINE_DIR/fib.json" "wamr")

MED_QJS_WASMZ=$(parse_median_ms "$HYPERFINE_DIR/quickjs.json" "wasmz")
MED_QJS_WASM3=$(parse_median_ms "$HYPERFINE_DIR/quickjs.json" "wasm3")
MED_QJS_WASMI=$(parse_median_ms "$HYPERFINE_DIR/quickjs.json" "wasmi")
MED_QJS_WAMR=$(parse_median_ms "$HYPERFINE_DIR/quickjs.json" "wamr")

MED_ESBUILD_WASMZ=$(parse_median_ms "$HYPERFINE_DIR/esbuild.json" "wasmz")
MED_ESBUILD_WASM3=$(parse_median_ms "$HYPERFINE_DIR/esbuild.json" "wasm3")
MED_ESBUILD_WASMI=$(parse_median_ms "$HYPERFINE_DIR/esbuild.json" "wasmi")
MED_ESBUILD_WAMR=$(parse_median_ms "$HYPERFINE_DIR/esbuild.json" "wamr")

# ─── 7. generate report ───────────────────────────────────────────────────────
info "Generating report..."

{
cat << MDEOF
# Benchmark Report: wasmz vs wasmi vs wasm3 vs wamr

**Date:** ${DATE}
**OS:** ${OS_INFO}
**Runs per benchmark:** ${RUNS} (warmup: ${WARMUP})

## Versions

| Runtime | Version |
|---------|---------|
| wasmz   | ${WASMZ_VER} |
| wasmi   | ${WASMI_VER} |
| wasm3   | ${WASM3_VER} |
| wamr    | ${WAMR_VER} |

## Binary Size

| Runtime | Size |
|---------|------|
| wasmz   | $(human_bytes $SZ_WASMZ) |
| wasmi   | $(human_bytes $SZ_WASMI) |
| wasm3   | $(human_bytes $SZ_WASM3) |
| wamr    | $(human_bytes $SZ_WAMR) |

## Execution Time (median ms) — lower is better

### fib(30) — pure C compiled to WASM

| Runtime | Median (ms) |
|---------|-------------|
| wasmz   | ${MED_FIB_WASMZ} |
| wasmi   | ${MED_FIB_WASMI} |
| wasm3   | ${MED_FIB_WASM3} |
| wamr    | ${MED_FIB_WAMR} |

### QuickJS fib(25) — JS engine running inside WASM (1.4 MB module)

| Runtime | Median (ms) |
|---------|-------------|
| wasmz   | ${MED_QJS_WASMZ} |
| wasmi   | ${MED_QJS_WASMI} |
| wasm3   | ${MED_QJS_WASM3} |
| wamr    | ${MED_QJS_WAMR} |

### esbuild — JS bundler running inside WASM (19 MB module)

| Runtime | Median (ms) |
|---------|-------------|
| wasmz   | ${MED_ESBUILD_WASMZ} |
| wasmi   | ${MED_ESBUILD_WASMI} |
| wasm3   | ${MED_ESBUILD_WASM3} |
| wamr    | ${MED_ESBUILD_WAMR} |

## Peak RSS (memory) — lower is better

> Peak RSS = highest resident set size seen at any point during the run.
> Avg RSS  = time-weighted mean RSS sampled every ${SAMPLE_INTERVAL_MS} ms during one run
>            (reflects actual memory consumption over the process lifetime, not just the spike).

### fib(30)

| Runtime | Peak RSS | Avg RSS |
|---------|----------|---------|
| wasmz   | $(human_bytes ${RSS_FIB_WASMZ:-0}) | $(human_bytes ${AVG_FIB_WASMZ:-0}) |
| wasmi   | $(human_bytes ${RSS_FIB_WASMI:-0}) | $(human_bytes ${AVG_FIB_WASMI:-0}) |
| wasm3   | $(human_bytes ${RSS_FIB_WASM3:-0}) | $(human_bytes ${AVG_FIB_WASM3:-0}) |
| wamr    | $(human_bytes ${RSS_FIB_WAMR:-0}) | $(human_bytes ${AVG_FIB_WAMR:-0}) |

### QuickJS fib(25)

| Runtime | Peak RSS | Avg RSS |
|---------|----------|---------|
| wasmz   | $(human_bytes ${RSS_QJS_WASMZ:-0}) | $(human_bytes ${AVG_QJS_WASMZ:-0}) |
| wasmi   | $(human_bytes ${RSS_QJS_WASMI:-0}) | $(human_bytes ${AVG_QJS_WASMI:-0}) |
| wasm3   | $(human_bytes ${RSS_QJS_WASM3:-0}) | $(human_bytes ${AVG_QJS_WASM3:-0}) |
| wamr    | $(human_bytes ${RSS_QJS_WAMR:-0}) | $(human_bytes ${AVG_QJS_WAMR:-0}) |

### esbuild bundling

| Runtime | Peak RSS | Avg RSS |
|---------|----------|---------|
| wasmz   | $(human_bytes ${RSS_ESBUILD_WASMZ:-0}) | $(human_bytes ${AVG_ESBUILD_WASMZ:-0}) |
| wasmi   | $(human_bytes ${RSS_ESBUILD_WASMI:-0}) | $(human_bytes ${AVG_ESBUILD_WASMI:-0}) |
| wasm3   | $(human_bytes ${RSS_ESBUILD_WASM3:-0}) | $(human_bytes ${AVG_ESBUILD_WASM3:-0}) |
| wamr    | $(human_bytes ${RSS_ESBUILD_WAMR:-0}) | $(human_bytes ${AVG_ESBUILD_WAMR:-0}) |
MDEOF
} > "$REPORT"

echo ""
info "Done! Report written to: $REPORT"
echo ""
cat "$REPORT"

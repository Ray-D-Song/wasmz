#!/usr/bin/env bash
# Shared dual-CLI helpers for benchmark scripts.
set -euo pipefail

# resolve_baseline_cli [default_path]
resolve_baseline_cli() {
  if [[ -n "${BASELINE_CLI:-}" ]]; then
    echo "$BASELINE_CLI"
  elif [[ $# -ge 1 && -n "${1:-}" ]]; then
    echo "$1"
  else
    echo ""
  fi
}

# resolve_candidate_cli [default_path]
resolve_candidate_cli() {
  if [[ -n "${CANDIDATE_CLI:-}" ]]; then
    echo "$CANDIDATE_CLI"
  elif [[ $# -ge 1 && -n "${1:-}" ]]; then
    echo "$1"
  else
    resolve_baseline_cli "${1:-}"
  fi
}

binary_size() {
  local target
  target="$(readlink -f "$1" 2>/dev/null || echo "$1")"
  case "$(uname -s)" in
    Darwin*) stat -f "%z" "$target" ;;
    *)       stat -c "%s" "$target" ;;
  esac
}

human_bytes() {
  python3 -c "
b = $1
if b >= 1048576: print('%.1f MB' % (b/1048576))
elif b >= 1024:  print('%.1f KB' % (b/1024))
else:            print('%d B' % b)
"
}

git_commit_short() {
  local repo="${1:-.}"
  git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo "unknown"
}

git_commit_full() {
  local repo="${1:-.}"
  git -C "$repo" rev-parse HEAD 2>/dev/null || echo "unknown"
}

parse_median_ms() {
  local json_file="$1" name="$2"
  python3 -c "
import json
data = json.load(open('$json_file'))
for r in data['results']:
    if r['command'] == '$name':
        print('%.3f' % (r['median'] * 1000))
        break
"
}

parse_stddev_ms() {
  local json_file="$1" name="$2"
  python3 -c "
import json
data = json.load(open('$json_file'))
for r in data['results']:
    if r['command'] == '$name':
        print('%.3f' % (r['stddev'] * 1000))
        break
"
}

require_executable() {
  local cli="$1" label="$2"
  [[ -n "$cli" ]] || return 1
  [[ -x "$cli" ]] || { echo "ERROR: $label not executable: $cli" >&2; return 1; }
}

# run_dual_hyperfine workload_cmd baseline candidate json_out runs warmup
run_dual_hyperfine() {
  local workload_cmd="$1"
  local baseline="$2"
  local candidate="$3"
  local json_out="$4"
  local runs="${5:-20}"
  local warmup="${6:-5}"

  hyperfine --style none --shell none \
    --ignore-failure \
    --warmup "$warmup" --runs "$runs" \
    --export-json "$json_out" \
    --command-name "baseline" "$baseline $workload_cmd" \
    --command-name "candidate" "$candidate $workload_cmd"
}

# emit_compare_json repo_dir baseline candidate baseline_size candidate_size workload json_file output_file
emit_compare_json() {
  local repo_dir="$1"
  local baseline="$2"
  local candidate="$3"
  local baseline_size="$4"
  local candidate_size="$5"
  local workload="$6"
  local json_file="$7"
  local output_file="$8"
  local runs="${9:-20}"
  local warmup="${10:-5}"

  python3 - "$repo_dir" "$baseline" "$candidate" \
    "$baseline_size" "$candidate_size" "$workload" "$json_file" "$output_file" \
    "$runs" "$warmup" << 'PYEOF'
import json, os, platform, subprocess, sys
from datetime import datetime, timezone

repo_dir, baseline, candidate = sys.argv[1:4]
baseline_size, candidate_size = int(sys.argv[4]), int(sys.argv[5])
workload, hyperfine_json, output_file = sys.argv[6:9]
runs, warmup = int(sys.argv[9]), int(sys.argv[10])

def git_rev():
    try:
        return subprocess.check_output(["git", "-C", repo_dir, "rev-parse", "HEAD"], text=True).strip()
    except Exception:
        return "unknown"

def git_short():
    try:
        return subprocess.check_output(["git", "-C", repo_dir, "rev-parse", "--short", "HEAD"], text=True).strip()
    except Exception:
        return "unknown"

with open(hyperfine_json) as f:
    hf = json.load(f)

results = {}
for r in hf.get("results", []):
    results[r["command"]] = {
        "median_ms": r["median"] * 1000,
        "stddev_ms": r.get("stddev", 0) * 1000,
        "min_ms": r.get("min", r["median"]) * 1000,
        "max_ms": r.get("max", r["median"]) * 1000,
    }

base = results.get("baseline", {})
cand = results.get("candidate", {})
speedup = None
if base.get("median_ms") and cand.get("median_ms"):
    speedup = base["median_ms"] / cand["median_ms"]

report = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "git_commit": git_rev(),
    "git_commit_short": git_short(),
    "environment": {
        "os": platform.platform(),
        "machine": platform.machine(),
        "python": platform.python_version(),
    },
    "config": {
        "runs": runs,
        "warmup": warmup,
        "workload": workload,
    },
    "binaries": {
        "baseline": {"path": baseline, "size_bytes": baseline_size},
        "candidate": {"path": candidate, "size_bytes": candidate_size},
    },
    "results": results,
    "summary": {
        "baseline_median_ms": base.get("median_ms"),
        "candidate_median_ms": cand.get("median_ms"),
        "candidate_vs_baseline_speedup": speedup,
    },
}

with open(output_file, "w") as f:
    json.dump(report, f, indent=2)
    f.write("\n")

# Summary table to stdout
print("")
print("=== Comptime Static Benchmark Summary ===")
print(f"Git: {report['git_commit_short']}  Workload: {os.path.basename(workload)}")
print(f"OS: {report['environment']['os']}")
print("")
print(f"{'Variant':<12} {'Binary Size':<14} {'Median (ms)':<14} {'± stddev':<12} {'Speedup':<10}")
print("-" * 64)
for label, path, size in (
    ("baseline", baseline, baseline_size),
    ("candidate", candidate, candidate_size),
):
    r = results.get(label, {})
    med = r.get("median_ms")
    std = r.get("stddev_ms")
    med_s = f"{med:.3f}" if med is not None else "n/a"
    std_s = f"± {std:.3f}" if std is not None else "n/a"
    sz = size
    if sz >= 1048576:
        sz_s = f"{sz/1048576:.1f} MB"
    elif sz >= 1024:
        sz_s = f"{sz/1024:.1f} KB"
    else:
        sz_s = f"{sz} B"
    speed = ""
    if label == "candidate" and speedup is not None:
        speed = f"{speedup:.3f}x"
    print(f"{label:<12} {sz_s:<14} {med_s:<14} {std_s:<12} {speed:<10}")
print("")
print(f"JSON report: {output_file}")
PYEOF
}

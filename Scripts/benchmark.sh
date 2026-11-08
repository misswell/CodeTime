#!/bin/bash
# CT-094/095/115: real performance benchmarks with CONTENT verification.
#
# Runs CodeTimeCrashChild in a DEDICATED PROCESS so RUSAGE_SELF/CHILDREN measure
# exactly this benchmark (no XCTest history, no accumulated peak RSS).
#
# Usage:
#   benchmark.sh [small|medium|large|stress] [fileCount]
#   benchmark.sh --check [small|medium]     compare against perf-baseline.json
#
# Scale: small=300, medium=10,000, large=100,000, stress=1,000,000.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHILD="$ROOT/Packages/CodeTimeKit/.build/debug/CodeTimeCrashChild"
BASELINE="$ROOT/Docs/Engineering/perf-baseline.json"

CHECK=0
if [ "${1:-}" = "--check" ]; then
  CHECK=1
  shift
fi

case "${1:-small}" in
  small)  FILES="${2:-300}" ;;
  medium) FILES="${2:-10000}" ;;
  large)  FILES="${2:-100000}" ;;
  stress) FILES="${2:-1000000}" ;;
  *) FILES="${2:-300}" ;;
esac

if [ ! -x "$CHILD" ] || [ -n "$(find "$ROOT/Packages/CodeTimeKit/Sources" -newer "$CHILD" -name '*.swift' -print -quit 2>/dev/null)" ]; then
  echo "building CodeTimeCrashChild…" >&2
  swift build --package-path "$ROOT/Packages/CodeTimeKit" --product CodeTimeCrashChild >/dev/null
fi

if [ -z "${KOPIA_PATH:-}" ]; then
  export KOPIA_PATH="$ROOT/Resources/Kopia/kopia"
fi
[ -x "$KOPIA_PATH" ] || { echo "kopia binary missing at $KOPIA_PATH (run Scripts/fetch_kopia.sh)" >&2; exit 1; }

WORK="$(mktemp -d /tmp/codetime-bench-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "benchmark: $FILES files (scale ${1:-small}, content-verified)"
OUTPUT="$("$CHILD" bench "$WORK" "$FILES")"
echo "$OUTPUT"

if [ "$CHECK" -eq 1 ]; then
  [ -f "$BASELINE" ] || { echo "no baseline at $BASELINE" >&2; exit 1; }
  printf '%s\n' "$OUTPUT" > "$WORK/metrics.txt"
  python3 - "$BASELINE" "$FILES" "$WORK/metrics.txt" <<'PY' || exit 4
import json, re, sys
baseline_path, files, metrics_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
out = open(metrics_path).read()
metrics = {}
for line in out.splitlines():
    line = line.strip()
    m = re.match(r"^([A-Za-z][A-Za-z0-9]*):\s*(.+)$", line)
    if m and m.group(1) != "PERF_METRICS":
        metrics[m.group(1)] = m.group(2)
if metrics.get("contentCheck") != "PASS":
    print("PERF REGRESSION: content verification failed", file=sys.stderr)
    sys.exit(4)
baseline = json.load(open(baseline_path))
entry = baseline.get(str(files))
if not entry:
    print(f"no baseline for {files} files — recording is manual", file=sys.stderr)
    sys.exit(0)
failures = []
def ratio(name, limit):
    base = entry.get(name)
    if base in (None, 0):
        return
    actual = float(metrics.get(name, 0))
    if actual > base * limit:
        failures.append(f"{name}: {actual} > {base}*{limit}")
ratio("backupDurationMs", 2.5)
ratio("restoreDurationMs", 2.5)
ratio("peakMemoryMB", 1.5)
if failures:
    print("PERF REGRESSION: " + "; ".join(failures), file=sys.stderr)
    sys.exit(4)
print(f"performance within baseline for {files} files")
PY
fi

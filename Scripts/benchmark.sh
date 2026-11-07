#!/bin/bash
# CT-094/095: real performance benchmarks. Runs the CodeTimeCrashChild
# executable in a DEDICATED PROCESS so RUSAGE_SELF/CHILDREN measure exactly the
# benchmark (no XCTest process history, no accumulated peak RSS).
#
# Usage: benchmark.sh [small|medium|large|stress] [fileCount]
#   small  (300 files)   quick sanity, runs in CI via the test suite
#   medium (10,000)      regular performance
#   large  (100,000)     large-scale
#   stress (1,000,000)   manual / overnight runs only
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHILD="$ROOT/Packages/CodeTimeKit/.build/debug/CodeTimeCrashChild"

case "${1:-small}" in
  small)  FILES="${2:-300}" ;;
  medium) FILES="${2:-10000}" ;;
  large)  FILES="${2:-100000}" ;;
  stress) FILES="${2:-1000000}" ;;
  *) FILES="${2:-300}" ;;
esac

if [ ! -x "$CHILD" ]; then
  echo "building CodeTimeCrashChild…" >&2
  swift build --package-path "$ROOT/Packages/CodeTimeKit" >&2
fi

if [ -z "${KOPIA_PATH:-}" ]; then
  export KOPIA_PATH="$ROOT/Resources/Kopia/kopia"
fi
[ -x "$KOPIA_PATH" ] || { echo "kopia binary missing at $KOPIA_PATH (run Scripts/fetch_kopia.sh)" >&2; exit 1; }

WORK="$(mktemp -d /tmp/codetime-bench-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "benchmark: $FILES files (scale ${1:-small})"
"$CHILD" bench "$WORK" "$FILES"

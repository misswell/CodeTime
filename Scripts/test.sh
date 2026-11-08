#!/bin/bash
# Runs the CodeTimeKit test suite. Extra arguments are forwarded to `swift test`
# (for example --filter CloudMirrorRegressionTests). A filter that matches no
# test is treated as a failure so a CI stage can never pass vacuously.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export KOPIA_PATH="${KOPIA_PATH:-$ROOT/Resources/Kopia/kopia}"
if [ ! -x "$KOPIA_PATH" ]; then
  echo "未找到 Kopia: $KOPIA_PATH（可运行 Scripts/fetch_kopia.sh）" >&2
  exit 1
fi

# CT-114: the SIGKILL/crash-recovery tests run against a real child executable.
# Build it up front so a missing binary can never turn CT-098 into a skip.
swift build --package-path Packages/CodeTimeKit --product CodeTimeCrashChild >/dev/null

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

set +e
swift test --package-path Packages/CodeTimeKit "$@" 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e

[ "$STATUS" -eq 0 ] || exit "$STATUS"

if [ "$#" -gt 0 ] && grep -q "Executed 0 tests" "$LOG"; then
  echo "过滤器没有匹配任何测试：$*" >&2
  exit 1
fi

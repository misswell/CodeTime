#!/bin/bash
# Runs the whole package test suite and enforces that every permanent CT
# regression is present and that no test fails.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -n "${REGRESSION_OUTPUT_FILE:-}" ]; then
  # Test seam: validate the gate logic against a prepared transcript instead of
  # re-running the whole suite.
  OUTPUT="$REGRESSION_OUTPUT_FILE"
else
  OUTPUT="$(mktemp)"
  trap 'rm -f "$OUTPUT"' EXIT
  set +e
  "$ROOT/Scripts/test.sh" >"$OUTPUT" 2>&1
  STATUS=$?
  set -e
  tail -40 "$OUTPUT"
  if [ "$STATUS" -ne 0 ]; then
    echo "regression gate: FAIL (test command exited $STATUS)" >&2
    exit 1
  fi
fi

grep -q "with 0 failures" "$OUTPUT" \
  || { echo "regression gate: FAIL (test summary not clean)" >&2; exit 1; }

MISSING=()
for number in $(seq 1 69); do
  id="$(printf '%03d' "$number")"
  if ! grep -q "testCT${id}_" "$OUTPUT"; then
    MISSING+=("CT-${id}")
  fi
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "regression gate: FAIL (missing permanent tests: ${MISSING[*]})" >&2
  exit 1
fi

# XCTSkip keeps the test name visible, so a disabled test would otherwise pass
# the presence check. Only the documented environment-gated tests may skip.
SKIPPED="$(grep -E "Test Case .* skipped" "$OUTPUT" | grep -o "test[A-Za-z0-9_]*" | sort -u || true)"
for test in $SKIPPED; do
  case "$test" in
    testCT036_*|testCT037_*|testCT044_*|testSingleMacICloudRoundTrip) ;;
    *)
      echo "regression gate: FAIL (unexpected skipped test: $test)" >&2
      exit 1
      ;;
  esac
done

echo "regression gate: PASS (CT-001 … CT-069 present, 0 failures, only allowed skips)"

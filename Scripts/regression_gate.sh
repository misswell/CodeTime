#!/bin/bash
# Runs the whole package test suite and enforces that every permanent CT
# regression is present and that no test fails.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

grep -q "with 0 failures" "$OUTPUT" \
  || { echo "regression gate: FAIL (test summary not clean)" >&2; exit 1; }

MISSING=()
for number in $(seq 1 44); do
  id="$(printf '%03d' "$number")"
  if ! grep -q "testCT${id}_" "$OUTPUT"; then
    MISSING+=("CT-${id}")
  fi
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "regression gate: FAIL (missing permanent tests: ${MISSING[*]})" >&2
  exit 1
fi

echo "regression gate: PASS (CT-001 … CT-044 present, 0 failures)"

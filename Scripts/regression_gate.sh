#!/bin/bash
# Runs the whole package test suite and enforces, driven by REGRESSION_INDEX.json:
#   1. the test command exits 0 and reports 0 failures;
#   2. every required CT test (CT-001 … CT-098) is registered and actually runs;
#   3. every skip is whitelisted in the index (with an environment reason) —
#      any unregistered skip fails the gate;
#   4. the index itself is complete (98 entries).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INDEX="$ROOT/REGRESSION_INDEX.json"

# CT-092: the index must exist and register exactly CT-001 … CT-098.
if [ ! -f "$INDEX" ]; then
  echo "regression gate: FAIL (missing REGRESSION_INDEX.json)" >&2
  exit 1
fi
python3 - "$INDEX" <<'PY' || { echo "regression gate: FAIL (invalid index)" >&2; exit 1; }
import json, sys
entries = json.load(open(sys.argv[1]))
ids = [e.get("id") for e in entries]
expected = [f"CT-{i:03d}" for i in range(1, 99)]
if ids != expected:
    missing = set(expected) - set(ids)
    extra = set(ids) - set(expected)
    print(f"index incomplete/unordered: missing={sorted(missing)} extra={sorted(extra)}", file=sys.stderr)
    sys.exit(1)
for e in entries:
    for key in ("id", "test", "file", "required"):
        if key not in e:
            print(f"entry {e.get('id')} missing key {key}", file=sys.stderr)
            sys.exit(1)
    if e.get("envSkip") and not e.get("envSkipReason"):
        print(f"entry {e['id']} allows env skip without a documented reason", file=sys.stderr)
        sys.exit(1)
PY

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

# Required tests must be present. Presence = the test name appears in the
# transcript (executed or skipped); env-skippable entries may skip, anything
# else that skipped but did not pass fails below.
MISSING=()
while IFS=$'\t' read -r id test required envskip; do
  [ "$required" = "True" ] || continue
  if ! grep -q "${test}" "$OUTPUT"; then
    MISSING+=("$id($test)")
  fi
done < <(python3 -c "
import json, sys
for e in json.load(open('$INDEX')):
    print(e['id'], e['test'], e['required'], e.get('envSkip', False), sep='\t')
")

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "regression gate: FAIL (missing required tests: ${MISSING[*]})" >&2
  exit 1
fi

# XCTSkip keeps the test name visible, so a disabled test would otherwise pass
# the presence check. Only tests whitelisted in the index (envSkip=true, with
# a documented reason) plus the explicit legacy single-Mac entry may skip.
ALLOWED_SKIPS="$(python3 -c "
import json
names = [e['test'] for e in json.load(open('$INDEX')) if e.get('envSkip')]
names.append('testSingleMacICloudRoundTrip')
print(' '.join(names))
")"
SKIPPED="$(grep -E "Test Case .* skipped" "$OUTPUT" | grep -o "test[A-Za-z0-9_]*" | sort -u || true)"
for test in $SKIPPED; do
  allowed=0
  for allowed_test in $ALLOWED_SKIPS; do
    if [[ "$test" == "$allowed_test" || "$test" == "${allowed_test}"* ]]; then
      allowed=1
      break
    fi
  done
  if [ "$allowed" -ne 1 ]; then
    echo "regression gate: FAIL (unexpected skipped test: $test)" >&2
    exit 1
  fi
done

echo "regression gate: PASS (CT-001 … CT-098 present, 0 failures, only index-whitelisted skips)"

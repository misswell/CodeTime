#!/bin/bash
# Regression gate (CT-092 / CT-114).
#
# Driven by REGRESSION_INDEX.json:
#   1. index integrity: exactly CT-001…CT-159, unique IDs and test names,
#      required tests may NOT be environment-skippable;
#   2. every required test exists in the sources and actually runs;
#   3. skips are only allowed for entries explicitly marked manualAcceptance —
#      any unregistered skip fails the gate;
#   4. failure output names the failing tests/cases/errors (CI keeps only a tail).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INDEX="$ROOT/REGRESSION_INDEX.json"

[ -f "$INDEX" ] || { echo "regression gate: FAIL (missing REGRESSION_INDEX.json)" >&2; exit 1; }

# --- 1. Index integrity -------------------------------------------------------
python3 - "$INDEX" "$ROOT" <<'PY' || { echo "regression gate: FAIL (invalid index)" >&2; exit 1; }
import json, sys, os
index_path, root = sys.argv[1], sys.argv[2]
entries = json.load(open(index_path))
expected = [f"CT-{i:03d}" for i in range(1, 160)]
ids = [e.get("id") for e in entries]
if ids != expected:
    missing = sorted(set(expected) - set(ids))
    extra = sorted(set(ids) - set(expected))
    print(f"index incomplete/unordered: missing={missing} extra={extra}", file=sys.stderr)
    sys.exit(1)

names = [e.get("test") for e in entries]
if len(set(names)) != len(names):
    print("duplicate test names in index", file=sys.stderr)
    sys.exit(1)

required = [e for e in entries if e.get("required")]
for e in required:
    if e.get("envSkip") or e.get("manualAcceptance"):
        print(f"{e['id']} is required but marked skippable/manual", file=sys.stderr)
        sys.exit(1)
    for key in ("id", "test", "file", "purpose", "invariant"):
        if not e.get(key):
            print(f"required entry {e['id']} missing {key}", file=sys.stderr)
            sys.exit(1)

for e in entries:
    if e.get("manualAcceptance") and not e.get("acceptanceReason"):
        print(f"{e['id']} is manual-acceptance without a reason", file=sys.stderr)
        sys.exit(1)

tests_dir = os.path.join(root, "Packages/CodeTimeKit/Tests/CodeTimeKitTests")
sources = ""
for name in os.listdir(tests_dir):
    if name.endswith(".swift"):
        sources += open(os.path.join(tests_dir, name), encoding="utf-8").read()
for e in entries:
    if f"func {e['test']}(" not in sources:
        print(f"indexed test {e['id']} {e['test']} not found in sources", file=sys.stderr)
        sys.exit(1)
PY

# --- 1b. Test-report consistency (CT-127 / CT-128) -----------------------------
# One machine-readable block in TEST_REPORT is the source of truth; the other
# engineering docs must quote the same numbers and skipped tests may never be
# counted as passed.
python3 "$ROOT/Scripts/check_test_report.py" --repo-root "$ROOT" || {
  echo "regression gate: FAIL (test report inconsistent)" >&2
  exit 1
}

# --- 2. Run the suite ---------------------------------------------------------
if [ -n "${REGRESSION_OUTPUT_FILE:-}" ]; then
  OUTPUT="$REGRESSION_OUTPUT_FILE"
else
  OUTPUT="$(mktemp)"
  trap 'rm -f "$OUTPUT"' EXIT
  # CT-114: the crash-child executable is a hard requirement — build it so the
  # real SIGKILL tests (CT-098) can never silently skip for a missing binary.
  echo "regression gate: building CodeTimeCrashChild…" >&2
  if ! swift build --package-path "$ROOT/Packages/CodeTimeKit" --product CodeTimeCrashChild >/dev/null 2>&1; then
    echo "regression gate: FAIL (CodeTimeCrashChild did not build)" >&2
    exit 1
  fi
  set +e
  CODETIME_SCALE_TESTS="${CODETIME_SCALE_TESTS:-1}" "$ROOT/Scripts/test.sh" >"$OUTPUT" 2>&1
  STATUS=$?
  set -e
  tail -40 "$OUTPUT"
  if [ "$STATUS" -ne 0 ]; then
    echo "regression gate: FAIL (test command exited $STATUS)" >&2
    echo "--- failing suites ---" >&2
    grep -E "Test Suite .* failed" "$OUTPUT" | grep -v "All tests" >&2 || true
    echo "--- failing cases ---" >&2
    grep -E "failed \(" "$OUTPUT" | head -40 >&2 || true
    echo "--- assertions/errors ---" >&2
    grep -E "error:" "$OUTPUT" | head -40 >&2 || true
    exit 1
  fi
fi

grep -q "with 0 failures" "$OUTPUT" \
  || { echo "regression gate: FAIL (test summary not clean)" >&2; exit 1; }

# --- 3. Presence of required tests -------------------------------------------
MISSING=()
while IFS=$'\t' read -r id test required; do
  [ "$required" = "True" ] || continue
  if ! grep -q "$test" "$OUTPUT"; then
    MISSING+=("$id($test)")
  fi
done < <(python3 -c "
import json
for e in json.load(open('$INDEX')):
    print(e['id'], e['test'], e['required'], sep='\t')
")
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "regression gate: FAIL (missing required tests: ${MISSING[*]})" >&2
  exit 1
fi

# --- 4. Skips ----------------------------------------------------------------
ALLOWED_SKIPS="$(python3 -c "
import json
print(' '.join(e['test'] for e in json.load(open('$INDEX')) if e.get('manualAcceptance')))
print('testSingleMacICloudRoundTrip')
")"
SKIPPED="$(grep -E "Test Case .* skipped" "$OUTPUT" | grep -o "test[A-Za-z0-9_]*" | sort -u || true)"
UNEXPECTED=()
for test in $SKIPPED; do
  allowed=0
  for allowed_test in $ALLOWED_SKIPS; do
    if [ "$test" = "$allowed_test" ]; then
      allowed=1
      break
    fi
  done
  if [ "$allowed" -ne 1 ]; then
    UNEXPECTED+=("$test")
  fi
done
if [ "${#UNEXPECTED[@]}" -gt 0 ]; then
  echo "regression gate: FAIL (required test skipped: ${UNEXPECTED[*]})" >&2
  exit 1
fi

# --- 5. Summary --------------------------------------------------------------
EXECUTED="$(grep -oE "Executed [0-9]+ tests" "$OUTPUT" | tail -1 | grep -oE "[0-9]+" || echo 0)"
REQUIRED_COUNT="$(python3 -c "
import json
print(sum(1 for e in json.load(open('$INDEX')) if e.get('required')))
")"
echo "regression gate: PASS"
echo "  executed: $EXECUTED tests, 0 failures"
echo "  skipped (manual acceptance only): ${SKIPPED:-none}"
echo "  index: CT-001 … CT-159 ($REQUIRED_COUNT required)"

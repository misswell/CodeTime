#!/bin/bash
# CT-142: bounded "does this executable actually start and stay running?" check.
# Used by verify_release.sh on the packaged app, and directly testable.
# Usage: smoke_launch.sh <executable> [seconds-to-stay-alive=3] [-- <args>...]
set -uo pipefail
EXEC="${1:-}"
WINDOW="${2:-3}"
shift 2 2>/dev/null || shift 1 2>/dev/null || true
EXTRA=()
if [ "${1:-}" = "--" ]; then shift; EXTRA=("$@"); fi
[ -n "$EXEC" ] || { echo "usage: $0 <executable> [seconds] [-- args]" >&2; exit 2; }
[ -x "$EXEC" ] || { echo "FAIL: not executable: $EXEC" >&2; exit 2; }

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

"$EXEC" "${EXTRA[@]:+${EXTRA[@]}}" >"$LOG" 2>&1 &
PID=$!
ALIVE=0
END=$(( $(date +%s) + WINDOW ))
while [ "$(date +%s)" -lt "$END" ]; do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "FAIL: exited during the ${WINDOW}s launch window" >&2
    sed 's/^/  /' "$LOG" >&2 || true
    exit 1
  fi
  sleep 0.2
done
if kill -0 "$PID" 2>/dev/null; then ALIVE=1; fi
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
[ "$ALIVE" = "1" ] || { echo "FAIL: not running at the end of the window" >&2; exit 1; }
echo "launch smoke: PASS (${WINDOW}s)"

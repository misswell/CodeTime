#!/bin/bash
# Post-sign/notarize verification for a stable release artifact.
# Usage: verify_release.sh <CodeTime.app|CodeTime-*.zip>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INPUT="${1:-}"
[ -n "$INPUT" ] || { echo "usage: $0 <app|zip>" >&2; exit 2; }

fail() { echo "FAIL: $*" >&2; exit 1; }
note() { echo "  ok: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -d "$INPUT" ]; then
  APP="$INPUT"
elif [ -f "$INPUT" ]; then
  [ -f "$INPUT.sha256" ] || fail "missing checksum sidecar: $INPUT.sha256"
  (cd "$(dirname "$INPUT")" && shasum -a 256 -c "$(basename "$INPUT").sha256") \
    || fail "artifact checksum mismatch"
  note "artifact checksum verifies"
  unzip -q "$INPUT" -d "$WORK"
  APP="$WORK/CodeTime.app"
  [ -d "$APP" ] || APP="$(find "$WORK" -maxdepth 2 -name 'CodeTime.app' -type d -print -quit)"
  [ -d "$APP" ] || fail "zip does not contain CodeTime.app"
else
  fail "not found: $INPUT"
fi

"$ROOT/Scripts/validate_entitlements.sh" "$APP" || fail "entitlement validation failed"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "  version: $VERSION"

spctl --assess --type execute --verbose=4 "$APP" || fail "Gatekeeper assessment failed"
note "Gatekeeper accepts the app"

xcrun stapler validate "$APP" || fail "notarization ticket is not stapled"
note "notarization ticket is stapled"

KOPIA="$APP/Contents/Resources/Kopia/kopia"
"$KOPIA" --version >/dev/null || fail "embedded Kopia does not run"
ARCHS="$(/usr/bin/lipo -archs "$KOPIA" 2>/dev/null || true)"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || fail "embedded Kopia is not universal: $ARCHS"
note "embedded Kopia runs and is universal"

# CT-142: the distributed bundle must actually launch (a signed-but-crashing
# binary would pass every other check). Bounded: we start it, confirm it stays
# alive, then terminate it. Skippable for headless local runs.
if [ "${CODETIME_SKIP_LAUNCH_SMOKE:-0}" != "1" ]; then
  "$ROOT/Scripts/smoke_launch.sh" "$APP/Contents/MacOS/CodeTime" 3 \
    || fail "launch smoke test failed (the distributed app does not stay running)"
  note "app launches and stays running"
fi

echo "release verification: PASS"

#!/bin/bash
# Validates the static entitlement/LaunchAgent configuration, and optionally the
# signed app bundle passed as the first argument.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-}"

fail() { echo "FAIL: $*" >&2; exit 1; }
note() { echo "  ok: $*"; }

ENT="$ROOT/Apps/CodeTime/CodeTime.entitlements"
DEBUG_ENT="$ROOT/Apps/CodeTime/CodeTime-Debug.entitlements"
BETA_ENT="$ROOT/Apps/CodeTime/CodeTime-Beta.entitlements"
KOPIA_ENT="$ROOT/Resources/Kopia/kopia.entitlements"
AGENT="$ROOT/Resources/LaunchAgents/com.codetime.agent.plist"

[ -f "$ENT" ] || fail "missing $ENT"
for key in \
  com.apple.security.app-sandbox \
  com.apple.security.files.user-selected.read-write \
  com.apple.developer.icloud-services \
  com.apple.developer.icloud-container-identifiers \
  com.apple.developer.ubiquity-container-identifiers \
  com.apple.security.application-groups \
  keychain-access-groups; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$ENT" >/dev/null 2>&1 \
    || fail "Release entitlements missing $key"
done
note "Release entitlements contain sandbox, user-selected files, iCloud and keychain keys"

/usr/libexec/PlistBuddy -c "Print :com.apple.developer.icloud-container-identifiers" "$ENT" \
  | grep -q "iCloud.com.codetime.app" || fail "Release iCloud container identifier missing"
/usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" "$ENT" \
  | grep -q "U8U443D7ZL.com.codetime.app" || fail "Release application group missing"
note "iCloud container and application group identifiers are pinned"

/usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$KOPIA_ENT" >/dev/null 2>&1 \
  || fail "Kopia entitlements must enable App Sandbox inheritance"
/usr/libexec/PlistBuddy -c "Print :com.apple.security.inherit" "$KOPIA_ENT" >/dev/null 2>&1 \
  || fail "Kopia entitlements missing com.apple.security.inherit"
note "Kopia helper entitlements inherit the app sandbox"

[ -f "$AGENT" ] || fail "missing LaunchAgent plist $AGENT"
[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$AGENT")" = "com.codetime.agent" ] \
  || fail "LaunchAgent label must be com.codetime.agent"
[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$AGENT")" = "Contents/MacOS/CodeTime" ] \
  || fail "LaunchAgent BundleProgram must point at the app executable"
note "LaunchAgent plist is embedded and points at the app bundle"

grep -q "ENABLE_HARDENED_RUNTIME: YES" "$ROOT/project.yml" \
  || fail "Release configuration must enable Hardened Runtime"
grep -q "CODE_SIGN_ENTITLEMENTS: Apps/CodeTime/CodeTime.entitlements" "$ROOT/project.yml" \
  || fail "Release configuration must use CodeTime.entitlements"
note "project.yml Release configuration enables Hardened Runtime and sandbox entitlements"

# Beta is intentionally ad-hoc and must not claim iCloud; otherwise an unsigned
# build would look like it supports cloud sync when it cannot.
if /usr/libexec/PlistBuddy -c "Print :com.apple.developer.icloud-container-identifiers" "$BETA_ENT" >/dev/null 2>&1; then
  fail "Beta entitlements must not claim iCloud containers (unsigned build)"
fi
note "Beta entitlements remain ad-hoc and do not claim iCloud"

if [ -n "$APP" ]; then
  [ -d "$APP" ] || fail "app bundle not found: $APP"
  codesign --verify --deep --strict --verbose=2 "$APP" || fail "codesign verification failed"
  note "code signature verifies"

  DETAILS="$(codesign -d --verbose=4 "$APP" 2>&1 || true)"
  echo "$DETAILS" | grep -q "flags=.*runtime" || fail "app is not built with Hardened Runtime"
  echo "$DETAILS" | grep -q "Authority=Developer ID Application" \
    || fail "app is not signed with Developer ID Application"
  note "Developer ID signature and Hardened Runtime flags present"

  PLIST="$(mktemp)"
  codesign -d --entitlements :- "$APP" >"$PLIST" 2>/dev/null
  for key in \
    com.apple.security.app-sandbox \
    com.apple.developer.icloud-services \
    com.apple.developer.icloud-container-identifiers \
    com.apple.developer.ubiquity-container-identifiers \
    com.apple.security.application-groups \
    keychain-access-groups; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1 \
      || fail "signed app is missing $key"
  done
  # CT-137: the SIGNED product must carry the exact identifiers — a profile that
  # silently drops them would ship a build whose iCloud UI claims more than the
  # binary can do.
  for key in \
    com.apple.developer.icloud-container-identifiers \
    com.apple.developer.ubiquity-container-identifiers; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" \
      | grep -q "iCloud.com.codetime.app" \
      || fail "signed app $key does not contain iCloud.com.codetime.app"
  done
  /usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" "$PLIST" \
    | grep -q "U8U443D7ZL.com.codetime.app" \
    || fail "signed app application-groups does not contain U8U443D7ZL.com.codetime.app"
  rm -f "$PLIST"
  note "signed app embeds sandbox, iCloud container, app group and keychain entitlements"

  # CT-137: an embedded Developer ID profile must authorize the same container.
  PROFILE="$APP/Contents/embedded.provisionprofile"
  if [ -f "$PROFILE" ]; then
    DECODED="$(security cms -D -i "$PROFILE" 2>/dev/null || true)"
    [ -n "$DECODED" ] || fail "embedded provisioning profile cannot be decoded"
    printf '%s' "$DECODED" | plutil -extract Entitlements xml1 -o - - 2>/dev/null \
      | grep -q "iCloud.com.codetime.app" \
      || fail "provisioning profile does not authorize iCloud.com.codetime.app"
    printf '%s' "$DECODED" | plutil -extract Entitlements xml1 -o - - 2>/dev/null \
      | grep -q "U8U443D7ZL.com.codetime.app" \
      || fail "provisioning profile does not authorize the app group"
    note "embedded provisioning profile authorizes the iCloud container and app group"
  else
    note "no embedded provisioning profile (ad-hoc build)"
  fi

  [ -f "$APP/Contents/Library/LaunchAgents/com.codetime.agent.plist" ] \
    || fail "app bundle is missing the embedded LaunchAgent"
  [ -x "$APP/Contents/Resources/Kopia/kopia" ] || fail "app bundle is missing Kopia"
  codesign --verify --strict "$APP/Contents/Resources/Kopia/kopia" \
    || fail "embedded Kopia binary is not signed"
  note "embedded LaunchAgent and signed Kopia binary present"
fi

echo "entitlements: PASS"

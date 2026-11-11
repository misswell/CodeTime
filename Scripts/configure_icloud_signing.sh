#!/bin/bash
# Configure and verify the iCloud signing chain for CodeTime (macOS).
#
# Preconditions:
#   - Apple Developer Program License Agreement accepted by the Account Holder.
#   - An iCloud Container named iCloud.com.codetime.app exists AND is assigned to
#     the com.codetime.app App ID in the Developer Portal. The public App Store
#     Connect API cannot create/assign containers; this script fails closed until
#     that portal step is done.
#
# What it does once the container is assigned:
#   - finds/creates the App ID and ICLOUD capability
#   - creates a Mac Development provisioning profile for this Mac
#   - verifies the profile really contains the iCloud container entitlements
#   - installs the profile and builds BetaICloud with manual signing
#   - verifies the built app's entitlements and code signature
#
# Usage:
#   Scripts/configure_icloud_signing.sh
#   Scripts/configure_icloud_signing.sh --check-only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="com.codetime.app"
CONTAINER_ID="iCloud.com.codetime.app"
TEAM_ID="U8U443D7ZL"
PROFILE_NAME="CodeTime Mac Development iCloud"
CHECK_ONLY=0
if [ "${1:-}" = "--check-only" ]; then CHECK_ONLY=1; fi

fail() { echo "FAIL: $*" >&2; exit 1; }
blocked() { echo "ICLOUD_SIGNING_BLOCKED: $*" >&2; exit 3; }

command -v asc >/dev/null || fail "asc CLI not found"
command -v security >/dev/null || fail "security not found"

echo "ICLOUD_SIGNING_BEGIN $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 1. Bundle ID resource.
BUNDLE_JSON="$(asc bundle-ids list --paginate 2>/dev/null || true)"
BUNDLE_RESOURCE="$(printf '%s' "$BUNDLE_JSON" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
for x in d.get("data",[]):
    if x.get("attributes",{}).get("identifier")=="com.codetime.app":
        print(x["id"]); break
' || true)"
if [ -z "$BUNDLE_RESOURCE" ]; then
  [ "$CHECK_ONLY" -eq 1 ] && blocked "Bundle ID $BUNDLE_ID not found"
  echo "creating Bundle ID $BUNDLE_ID"
  BUNDLE_RESOURCE="$(asc bundle-ids create --identifier "$BUNDLE_ID" --name CodeTime --platform MAC_OS 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])')"
fi
echo "bundle_resource=$BUNDLE_RESOURCE"

# 2. ICLOUD capability.
CAPS="$(asc bundle-ids capabilities list --bundle "$BUNDLE_RESOURCE" 2>/dev/null || true)"
if ! printf '%s' "$CAPS" | grep -q 'ICLOUD'; then
  if [ "$CHECK_ONLY" -eq 1 ]; then blocked "ICLOUD capability not enabled on $BUNDLE_ID"; fi
  echo "enabling ICLOUD capability"
  asc bundle-ids capabilities add --bundle "$BUNDLE_RESOURCE" --capability ICLOUD \
    --settings '[{"key":"ICLOUD_VERSION","options":[{"key":"XCODE_6","enabled":true}]}]' >/dev/null
fi

# 3. This Mac must be a registered development device.
# Xcode identifies a Mac by the "Provisioning UDID", which differs from the
# hardware UUID. Prefer system_profiler and fall back to asc for older systems.
UDID="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Provisioning UDID/ {print $2; exit}')"
if [ -z "$UDID" ]; then
  UDID="$(asc devices local-udid 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["udid"])')"
fi
DEVICE_ID="$(asc devices list --paginate 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
for x in d.get("data",[]):
    if x.get("attributes",{}).get("udid")=="'"$UDID"'":
        print(x["id"]); break
' || true)"
if [ -z "$DEVICE_ID" ]; then
  if [ "$CHECK_ONLY" -eq 1 ]; then blocked "this Mac is not registered as a development device"; fi
  echo "registering this Mac as $UDID"
  DEVICE_ID="$(asc devices register --name "CodeTime Acceptance Mac" --udid "$UDID" --platform MAC_OS 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])')"
fi
echo "device_id=$DEVICE_ID"

# 4. Apple Development certificate ID.
CERT_ID="$(asc certificates list --paginate 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
for x in d.get("data",[]):
    t=x.get("attributes",{}).get("certificateType","")
    if t in ("DEVELOPMENT","APPLE_DEVELOPMENT"):
        print(x["id"]); break
' || true)"
[ -n "$CERT_ID" ] || fail "no Apple Development certificate found"
echo "certificate_id=$CERT_ID"

# 5. Recreate the profile so entitlement changes from the portal are picked up.
if [ "$CHECK_ONLY" -eq 0 ]; then
  for id in $(asc profiles list --profile-type MAC_APP_DEVELOPMENT 2>/dev/null \
      | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for x in d.get("data",[]):
    if x.get("attributes",{}).get("name")=="CodeTime Mac Development iCloud":
        print(x["id"])
' || true); do
    asc profiles delete --id "$id" --confirm >/dev/null 2>&1 || true
  done
fi
PROFILE_ID="$(asc profiles list --profile-type MAC_APP_DEVELOPMENT 2>/dev/null \
  | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for x in d.get("data",[]):
    if x.get("attributes",{}).get("name")=="CodeTime Mac Development iCloud":
        print(x["id"]); break
' || true)"
if [ -z "$PROFILE_ID" ]; then
  [ "$CHECK_ONLY" -eq 1 ] && blocked "provisioning profile not created yet"
  echo "creating provisioning profile $PROFILE_NAME"
  PROFILE_ID="$(asc profiles create --name "$PROFILE_NAME" --profile-type MAC_APP_DEVELOPMENT \
    --bundle "$BUNDLE_RESOURCE" --certificate "$CERT_ID" --device "$DEVICE_ID" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])')"
fi
echo "profile_id=$PROFILE_ID"

TMP="$(mktemp -d /tmp/codetime-signing-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
asc profiles download --id "$PROFILE_ID" --output "$TMP/profile.mobileprovision" >/dev/null 2>&1
security cms -D -i "$TMP/profile.mobileprovision" > "$TMP/profile.plist" 2>/dev/null
PLIST="$TMP/profile.plist"

# 6. The profile must actually carry the iCloud containers; enabling ICLOUD
# without assigning a container produces empty arrays and cannot work.
python3 - "$PLIST" "$CONTAINER_ID" <<'PY'
import plistlib, sys
path, expected = sys.argv[1], sys.argv[2]
with open(path, "rb") as fh:
    data = plistlib.load(fh)
entitlements = data.get("Entitlements", {})
containers = entitlements.get("com.apple.developer.icloud-container-identifiers", [])
ubiquity = entitlements.get("com.apple.developer.ubiquity-container-identifiers", [])
print("profile_containers=" + ",".join(containers))
print("profile_ubiquity=" + ",".join(ubiquity))
if expected not in containers or expected not in ubiquity:
    print(
        "ICLOUD_SIGNING_BLOCKED: profile does not contain "
        + expected
        + ". Create the iCloud Container and assign it to the App ID at "
        + "https://developer.apple.com/account/resources/identifiers/list/cloudContainer",
        file=sys.stderr,
    )
    sys.exit(3)
PY

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "ICLOUD_SIGNING_READY"
  exit 0
fi

# 7. Install the profile so codesign can find it by UUID.
PROFILE_UUID="$(plutil -extract UUID raw -o - "$PLIST")"
for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
           "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  mkdir -p "$dir"
  cp "$TMP/profile.mobileprovision" "$dir/$PROFILE_UUID.mobileprovision"
done
echo "installed_profile=$PROFILE_UUID"

# 8. Build BetaICloud with explicit manual signing and verify the result.
xcodebuild \
  -project "$ROOT/CodeTime.xcodeproj" \
  -scheme CodeTime \
  -configuration BetaICloud \
  -derivedDataPath "$ROOT/.build/DerivedData" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODETIME_PROVISIONING_PROFILE="$PROFILE_NAME" \
  build > "$TMP/build.log" 2>&1 || {
    tail -40 "$TMP/build.log" >&2
    fail "BetaICloud build failed"
  }

APP="$ROOT/.build/DerivedData/Build/Products/BetaICloud/CodeTime.app"
[ -d "$APP" ] || fail "built app not found: $APP"
codesign --verify --deep --strict "$APP" >/dev/null 2>&1 || fail "code signature verification failed"
codesign -d --entitlements :- "$APP" > "$TMP/app-entitlements.plist" 2>/dev/null || true
python3 - "$TMP/app-entitlements.plist" "$CONTAINER_ID" <<'PY'
import plistlib, sys
path, expected = sys.argv[1], sys.argv[2]
try:
    with open(path, "rb") as fh:
        data = plistlib.load(fh)
except Exception as error:
    print(f"ICLOUD_SIGNING_BLOCKED: cannot read app entitlements: {error}", file=sys.stderr)
    sys.exit(3)
containers = data.get("com.apple.developer.icloud-container-identifiers", [])
services = data.get("com.apple.developer.icloud-services", [])
print("app_containers=" + ",".join(containers))
print("app_services=" + ",".join(services))
if expected not in containers or "CloudDocuments" not in services:
    print("ICLOUD_SIGNING_BLOCKED: built app is missing iCloud entitlements", file=sys.stderr)
    sys.exit(3)
PY

echo "app=$APP"
echo "ICLOUD_SIGNING_READY"

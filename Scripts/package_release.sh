#!/bin/bash
# Stable release: Developer ID signature, Hardened Runtime, App Sandbox and
# mandatory notarization + stapling. Pre-releases use package_beta.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CHANNEL="${CODETIME_RELEASE_CHANNEL:-stable}"
if [ "$CHANNEL" != "stable" ]; then
  echo "package_release.sh 只用于 stable；$CHANNEL 请使用 package_beta.sh" >&2
  exit 1
fi

: "${DEVELOPMENT_TEAM:?请设置 DEVELOPMENT_TEAM}"

# Notarization credential, following the AgentSpace convention: a notarytool
# keychain profile is verified live before use; APPLE_ID/NOTARY_PASSWORD env is
# the explicit fallback. A profile *name* alone proves nothing.
NOTARY_ARGS=()
NOTARY_PROFILE="${NOTARY_PROFILE:-codetime-notary}"
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "notarization credential: keychain profile '$NOTARY_PROFILE' (live)"
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
  echo "notarization credential: APPLE_ID/NOTARY_PASSWORD env"
  NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$NOTARY_PASSWORD")
else
  echo "未找到可用的公证凭据。任选其一配置：" >&2
  echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id $DEVELOPMENT_TEAM" >&2
  echo "  或导出 APPLE_ID / NOTARY_PASSWORD 环境变量" >&2
  exit 1
fi
[ -n "${TEAM_ID:-}" ] && DEVELOPMENT_TEAM="$TEAM_ID"
NOTARY_ARGS+=(--team-id "$DEVELOPMENT_TEAM")

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "未找到 Developer ID Application 证书，stable 发布终止。" >&2
  exit 1
fi

VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)"
VERSION="${VERSION:-1.0.0}"
TAG="${TAG:-v${VERSION}}"
if [[ "$TAG" != "v${VERSION}" ]]; then
  echo "tag $TAG 不是稳定版本 v${VERSION}" >&2
  exit 1
fi
DIST="$ROOT/dist"
NAME="CodeTime-${VERSION}-macos-universal"
APP=".build/CodeTime.xcarchive/Products/Applications/CodeTime.app"

"$ROOT/Scripts/fetch_kopia.sh"
xcodegen generate
rm -rf "$DIST" .build/CodeTime.xcarchive .build/DerivedData
mkdir -p "$DIST"

# A Developer ID build with iCloud entitlements REQUIRES a Developer ID
# provisioning profile. Without it xcodebuild aborts with "requires a
# provisioning profile with the iCloud feature"; fail earlier and clearer.
if grep -q "com.apple.developer.icloud-services" Apps/CodeTime/CodeTime.entitlements \
   && [ -z "${PROVISIONING_PROFILE_SPECIFIER:-}" ]; then
  echo "CodeTime.entitlements 含 iCloud 能力，必须提供 Developer ID 描述文件。" >&2
  echo "  Developer ID 描述文件需要在 developer.apple.com 手动创建（含 iCloud 容器）。" >&2
  echo "  然后设置 PROVISIONING_PROFILE_SPECIFIER（描述文件名称）后重试。" >&2
  exit 1
fi

PROFILE_ARGS=()
if [ -n "${PROVISIONING_PROFILE_SPECIFIER:-}" ]; then
  PROFILE_ARGS=(PROVISIONING_PROFILE_SPECIFIER="$PROVISIONING_PROFILE_SPECIFIER")
fi

xcodebuild \
  -project CodeTime.xcodeproj \
  -scheme CodeTime \
  -configuration Release \
  -derivedDataPath .build/DerivedData \
  -archivePath .build/CodeTime.xcarchive \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  "${PROFILE_ARGS[@]:+${PROFILE_ARGS[@]}}" \
  archive

[ -d "$APP" ] || { echo "缺少构建产物: $APP" >&2; exit 1; }

"$ROOT/Scripts/validate_entitlements.sh" "$APP" \
  || { echo "签名或 entitlement 校验失败" >&2; exit 1; }

ZIP="$DIST/$NAME.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "提交公证…"
xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait

# Staple the app first, then rebuild the DMG from the stapled app so the copy a
# user drags out of the DMG carries its own ticket (AgentSpace pattern).
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

rm -f "$ZIP" "$DIST/$NAME.dmg"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")

DMG="$DIST/$NAME.dmg"
hdiutil create -quiet -volname "CodeTime ${VERSION}" \
  -srcfolder "$APP" -ov -format UDZO "$DMG"
hdiutil verify -quiet "$DMG"
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

"$ROOT/Scripts/verify_release.sh" "$ZIP"

echo
echo "artifact: $ZIP"
echo "artifact: $DMG"
echo "sha256:   $(cat "$ZIP.sha256")"
echo "tag:      $TAG"
unzip -l "$ZIP" | head -12

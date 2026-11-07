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
: "${APPLE_ID:?stable 发布必须设置 APPLE_ID 用于公证}"
: "${NOTARY_PASSWORD:?stable 发布必须设置 NOTARY_PASSWORD 用于公证}"

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
"$ROOT/Scripts/require_icloud_acceptance.sh" "$TAG"

DIST="$ROOT/dist"
NAME="CodeTime-${VERSION}-macos-universal"
APP=".build/CodeTime.xcarchive/Products/Applications/CodeTime.app"

"$ROOT/Scripts/fetch_kopia.sh"
xcodegen generate
rm -rf "$DIST" .build/CodeTime.xcarchive .build/DerivedData
mkdir -p "$DIST"

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
  archive

[ -d "$APP" ] || { echo "缺少构建产物: $APP" >&2; exit 1; }

"$ROOT/Scripts/validate_entitlements.sh" "$APP" \
  || { echo "签名或 entitlement 校验失败" >&2; exit 1; }

ZIP="$DIST/$NAME.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "提交公证…"
xcrun notarytool submit "$ZIP" \
  --apple-id "$APPLE_ID" \
  --team-id "$DEVELOPMENT_TEAM" \
  --password "$NOTARY_PASSWORD" \
  --wait

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")

"$ROOT/Scripts/verify_release.sh" "$ZIP"

echo
echo "artifact: $ZIP"
echo "sha256:   $(cat "$ZIP.sha256")"
echo "tag:      $TAG"
unzip -l "$ZIP" | head -12

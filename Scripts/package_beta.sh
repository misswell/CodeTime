#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)"
VERSION="${VERSION:-1.0.0}"
TAG="${TAG:-}"
if [ -n "$TAG" ] && [[ "$TAG" == "v${VERSION}-"* ]]; then
  PRERELEASE_ID="${TAG#v${VERSION}-}"
else
  PRERELEASE_ID="${PRERELEASE_ID:-beta.1}"
fi
TAG="${TAG:-v${VERSION}-${PRERELEASE_ID}}"
if [[ "$TAG" != *"-beta."* && "$TAG" != *"-rc."* ]]; then
  echo "package_beta.sh 只用于 beta/rc 预发布，收到 tag: $TAG" >&2
  exit 1
fi
DIST="$ROOT/dist"
STAGE="$DIST/CodeTime-beta"
NAME="CodeTime-${VERSION}-${PRERELEASE_ID}-macos-universal"

if [ ! -x "$ROOT/Resources/Kopia/kopia" ]; then
  "$ROOT/Scripts/fetch_kopia.sh"
fi

# Developer ID discovery (OrbSleepManager pattern): when the identity exists the
# beta is Developer ID signed, notarized and stapled; otherwise ad-hoc and
# clearly marked UNSIGNED.
DEVID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
SIGNED_NOTE="UNSIGNED（ad-hoc）"
SIGN_OVERRIDE=()
if [ -n "$DEVID" ]; then
  echo "==> Developer ID found: ${DEVID}（将签名并公证）"
  SIGN_OVERRIDE=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$DEVID"
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-U8U443D7ZL}"
    ENABLE_HARDENED_RUNTIME=YES
    OTHER_CODE_SIGN_FLAGS=--timestamp
  )
  SIGNED_NOTE="Developer ID: $DEVID"
else
  echo "==> no Developer ID identity; ad-hoc build（未公证）"
fi

xcodegen generate
rm -rf "$DIST" .build/Beta
xcodebuild \
  -project CodeTime.xcodeproj \
  -scheme CodeTime \
  -configuration Beta \
  -derivedDataPath .build/Beta \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  "${SIGN_OVERRIDE[@]}" \
  build

APP=".build/Beta/Build/Products/Beta/CodeTime.app"
[ -d "$APP" ] || { echo "missing built app: $APP" >&2; exit 1; }
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$PLIST_VERSION" = "$VERSION" ] || {
  echo "版本不一致：project.yml=$VERSION Info.plist=$PLIST_VERSION" >&2
  exit 1
}
"$ROOT/Scripts/validate_entitlements.sh"
codesign --verify --deep --strict "$APP"
xattr -cr "$APP" 2>/dev/null || true

mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/CodeTime.app"
cat > "$STAGE/README.txt" <<README
CodeTime ${VERSION} ${PRERELEASE_ID}
====================================

这是开发者预览版，不是稳定版。请勿把它作为唯一的代码备份。

安装
----
1. 把 CodeTime.app 拖到「应用程序」。
2. 首次打开如被 Gatekeeper 拦截：右键 → 打开，或执行
   xattr -dr com.apple.quarantine /Applications/CodeTime.app
3. 首次启动会生成恢复密钥，请立即离线保存。

本构建的限制
------------
- ${SIGNED_NOTE}
- 未启用 App Sandbox / iCloud entitlement，只能使用「本地镜像」，
  真实 iCloud 同步需要另行签名并注册容器。
- 云端清理、iCloud 逐出文件、上传确认等仍有已知问题，详见 Release Notes。
- 不要在没有其他备份的情况下备份唯一副本。
README

rm -f "$DIST/$NAME.zip" "$DIST/$NAME.zip.sha256" "$DIST/$NAME.dmg"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$STAGE/CodeTime.app" "$DIST/$NAME.zip"
(cd "$DIST" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")

# DMG for drag-and-drop install, verified by mount check (AgentSpace pattern).
hdiutil create -quiet -volname "CodeTime ${VERSION} ${PRERELEASE_ID}" \
  -srcfolder "$STAGE/CodeTime.app" -ov -format UDZO "$DIST/$NAME.dmg"
hdiutil verify -quiet "$DIST/$NAME.dmg"
MOUNT_CHECK="$(mktemp -d /tmp/codetime-dmg.XXXXXX)"
if diskutil image attach --readOnly --mountOptions nobrowse --mountPoint "$MOUNT_CHECK" "$DIST/$NAME.dmg" >/dev/null 2>&1; then
  [ -d "$MOUNT_CHECK/CodeTime.app" ] || { echo "DMG does not contain CodeTime.app" >&2; hdiutil detach "$MOUNT_CHECK" -quiet || true; exit 1; }
  codesign --verify --strict "$MOUNT_CHECK/CodeTime.app"
  hdiutil detach "$MOUNT_CHECK" -quiet
  echo "  ok  DMG contains a signature-valid CodeTime.app"
else
  echo "DMG mount verification failed" >&2
  exit 1
fi
rmdir "$MOUNT_CHECK" 2>/dev/null || true

# Notarize + staple when Developer ID signed; notarytool credential must be
# configured (keychain profile codetime-notary or APPLE_ID/NOTARY_PASSWORD).
if [ -n "$DEVID" ]; then
  NOTARY_ARGS=()
  NOTARY_PROFILE="${NOTARY_PROFILE:-codetime-notary}"
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  elif [ -n "${APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$NOTARY_PASSWORD")
  else
    echo "未找到公证凭据，跳过公证（产物为 Developer ID 签名但未公证）" >&2
  fi
  if [ ${#NOTARY_ARGS[@]} -gt 0 ]; then
    echo "==> notarizing app"
    NOTARY_TEAM="${DEVELOPMENT_TEAM:-U8U443D7ZL}"
    xcrun notarytool submit "$DIST/$NAME.zip" "${NOTARY_ARGS[@]}" --team-id "$NOTARY_TEAM" --wait
    xcrun stapler staple "$STAGE/CodeTime.app"
    xcrun stapler validate "$STAGE/CodeTime.app"
    echo "==> re-building DMG from stapled app and notarizing it"
    rm -f "$DIST/$NAME.dmg"
    hdiutil create -quiet -volname "CodeTime ${VERSION} ${PRERELEASE_ID}" \
      -srcfolder "$STAGE/CodeTime.app" -ov -format UDZO "$DIST/$NAME.dmg"
    hdiutil verify -quiet "$DIST/$NAME.dmg"
    xcrun notarytool submit "$DIST/$NAME.dmg" "${NOTARY_ARGS[@]}" --team-id "$NOTARY_TEAM" --wait
    xcrun stapler staple "$DIST/$NAME.dmg"
    xcrun stapler validate "$DIST/$NAME.dmg"
    echo "  ok  app 与 DMG 均已公证并 staple"
  fi
fi

echo
echo "artifact: $DIST/$NAME.zip"
echo "artifact: $DIST/$NAME.dmg"
echo "sha256:   $(cat "$DIST/$NAME.zip.sha256")"
echo "tag:      $TAG"
echo "verify:"
unzip -l "$DIST/$NAME.zip" | head -12

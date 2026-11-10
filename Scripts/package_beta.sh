#!/bin/bash
set -euo pipefail
# CI diagnostics: full command trace when requested (CODETIME_PKG_TRACE=1).
[ -n "${CODETIME_PKG_TRACE:-}" ] && set -x
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

# CT-140: a beta package that can actually exercise iCloud. The Beta config ships
# EMPTY entitlements on purpose (ad-hoc builds must not claim iCloud), so real
# two-Mac acceptance needs an explicitly opted-in build that signs the Beta
# configuration with the Release (iCloud) entitlements and a Developer ID profile.
if [ "${CODETIME_BETA_ICLOUD:-0}" = "1" ]; then
  if [ -z "$DEVID" ]; then
    echo "CODETIME_BETA_ICLOUD=1 需要 Developer ID 身份；当前构建没有，终止。" >&2
    exit 1
  fi
  if [ -z "${PROVISIONING_PROFILE_SPECIFIER:-}" ]; then
    echo "CODETIME_BETA_ICLOUD=1 需要 PROVISIONING_PROFILE_SPECIFIER（含 iCloud 容器的 Developer ID 描述文件）；终止。" >&2
    echo "  先运行 Scripts/setup_apple_provisioning.sh 并把描述文件安装到本机。" >&2
    exit 1
  fi
  SIGN_OVERRIDE+=(
    CODE_SIGN_ENTITLEMENTS=Apps/CodeTime/CodeTime.entitlements
    PROVISIONING_PROFILE_SPECIFIER="$PROVISIONING_PROFILE_SPECIFIER"
    ENABLE_HARDENED_RUNTIME=YES
  )
  SIGNED_NOTE="$SIGNED_NOTE · iCloud 已启用（验收构建）"
  echo "==> iCloud beta：使用 Release entitlements + 描述文件 $PROVISIONING_PROFILE_SPECIFIER"
fi

xcodegen generate
rm -rf "$DIST" .build/Beta
xcodebuild \
  -project CodeTime.xcodeproj \
  -scheme CodeTime \
  -configuration Beta \
  -derivedDataPath .build/Beta \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  "${SIGN_OVERRIDE[@]:+${SIGN_OVERRIDE[@]}}" \
  build

APP=".build/Beta/Build/Products/Beta/CodeTime.app"
[ -d "$APP" ] || { echo "missing built app: $APP" >&2; exit 1; }
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$PLIST_VERSION" = "$VERSION" ] || {
  echo "版本不一致：project.yml=$VERSION Info.plist=$PLIST_VERSION" >&2
  exit 1
}
"$ROOT/Scripts/validate_entitlements.sh"
# CT-127-era CI diagnostics: a silent codesign --verify failure on runners is
# undiagnosable from logs alone; print the bundle's signature state on failure.
if ! codesign --verify --deep --strict "$APP" 2>/tmp/codetime-codesign.err; then
  echo "==> codesign --verify --deep --strict FAILED:" >&2
  cat /tmp/codetime-codesign.err >&2 || true
  codesign -dv "$APP" 2>&1 | head -6 >&2 || true
  echo "==> nested binaries:" >&2
  codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | tail -20 >&2 || true
  exit 1
fi
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
# No -quiet here: a silent hdiutil failure is undiagnosable on CI.
hdiutil create -volname "CodeTime ${VERSION} ${PRERELEASE_ID}" \
  -srcfolder "$STAGE/CodeTime.app" -ov -format UDZO "$DIST/$NAME.dmg"
hdiutil verify "$DIST/$NAME.dmg"
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

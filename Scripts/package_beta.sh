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
DIST="$ROOT/dist"
STAGE="$DIST/CodeTime-beta"
NAME="CodeTime-${VERSION}-${PRERELEASE_ID}-macos-universal"

if [ ! -x "$ROOT/Resources/Kopia/kopia" ]; then
  "$ROOT/Scripts/fetch_kopia.sh"
fi

xcodegen generate
rm -rf "$DIST" .build/Beta
xcodebuild \
  -project CodeTime.xcodeproj \
  -scheme CodeTime \
  -configuration Beta \
  -derivedDataPath .build/Beta \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  build

APP=".build/Beta/Build/Products/Beta/CodeTime.app"
[ -d "$APP" ] || { echo "missing built app: $APP" >&2; exit 1; }
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
- 使用 ad-hoc 签名，未公证，也未使用 Developer ID。
- 未启用 App Sandbox / iCloud entitlement，只能使用「本地镜像」，
  真实 iCloud 同步需要另行签名并注册容器。
- 云端清理、iCloud 逐出文件、上传确认等仍有已知问题，详见 Release Notes。
- 不要在没有其他备份的情况下备份唯一副本。
README

rm -f "$DIST/$NAME.zip" "$DIST/$NAME.zip.sha256"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$STAGE/CodeTime.app" "$DIST/$NAME.zip"
shasum -a 256 "$DIST/$NAME.zip" > "$DIST/$NAME.zip.sha256"

echo
echo "artifact: $DIST/$NAME.zip"
echo "sha256:   $(cat "$DIST/$NAME.zip.sha256")"
echo "tag:      $TAG"
echo "verify:"
unzip -l "$DIST/$NAME.zip" | head -12

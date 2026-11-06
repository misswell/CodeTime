#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
  echo "请设置 DEVELOPMENT_TEAM，例如: export DEVELOPMENT_TEAM=U8U443D7ZL" >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "未找到 Developer ID Application 证书。直接分发与公证需要该证书。" >&2
  exit 1
fi

if [ ! -x "$ROOT/Resources/Kopia/kopia" ]; then
  "$ROOT/Scripts/fetch_kopia.sh"
fi
xcodegen generate
xcodebuild \
  -project CodeTime.xcodeproj \
  -scheme CodeTime \
  -configuration Release \
  -derivedDataPath .build/DerivedData \
  -archivePath .build/CodeTime.xcarchive \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  archive

APP=".build/CodeTime.xcarchive/Products/Applications/CodeTime.app"
ZIP=".build/CodeTime.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "归档完成: $ZIP"

if [ -n "${APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
  xcrun notarytool submit "$ZIP" \
    --apple-id "$APPLE_ID" \
    --team-id "$DEVELOPMENT_TEAM" \
    --password "$NOTARY_PASSWORD" \
    --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "公证与装订完成: $ZIP"
else
  echo "未设置 APPLE_ID / NOTARY_PASSWORD，跳过公证。"
fi

cat <<'MSG'

发布前确认：
- iCloud 容器 iCloud.com.codetime.app 已在开发者账号注册；
- Release 使用有效的 provisioning profile；
- 内置 Kopia 已以 com.apple.security.inherit 签名；
- 在另一台 Mac 完成一次真实云端恢复演练。
MSG

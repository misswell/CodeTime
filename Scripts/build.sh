#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${1:-Debug}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen 未安装，请先执行: brew install xcodegen" >&2
  exit 1
fi

if [ ! -x "$ROOT/Resources/Kopia/kopia" ]; then
  "$ROOT/Scripts/fetch_kopia.sh"
fi

# Local Debug/Beta builds are ad-hoc by default. Ad-hoc signatures change with
# EVERY rebuild, which invalidates the app's Keychain item ACL and makes macOS
# prompt for keychain access (bootstrap then blocks on that dialog). Prefer a
# stable local identity when one exists so the ACL survives rebuilds.
SIGN_ARGS=()
if [ "$CONFIGURATION" != "Release" ]; then
  if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
    SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY")
  else
    DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null \
      | grep -o '"Apple Development:[^"]*"' | head -1 | tr -d '"')"
    if [ -n "$DEV_ID" ]; then
      SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEV_ID")
      echo "本地构建签名身份: ${DEV_ID}  (稳定身份, 避免 Keychain 反复授权)"
    else
      echo "未找到 Apple Development 身份, 使用 ad-hoc (每次重建都会触发 Keychain 授权)"
    fi
  fi
fi

xcodegen generate
xcodebuild \
  -project CodeTime.xcodeproj \
  -scheme CodeTime \
  -configuration "$CONFIGURATION" \
  -derivedDataPath .build/DerivedData \
  "${SIGN_ARGS[@]:+${SIGN_ARGS[@]}}" \
  build

APP=".build/DerivedData/Build/Products/$CONFIGURATION/CodeTime.app"
echo
echo "构建完成: $APP"
echo "运行: open \"$APP\""

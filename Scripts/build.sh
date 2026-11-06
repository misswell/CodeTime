#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen 未安装，请先执行: brew install xcodegen" >&2
  exit 1
fi

CONFIGURATION="${1:-Debug}"
if [ ! -x "$ROOT/Resources/Kopia/kopia" ]; then
  "$ROOT/Scripts/fetch_kopia.sh"
fi
xcodegen generate
xcodebuild \
  -project CodeTime.xcodeproj \
  -scheme CodeTime \
  -configuration "$CONFIGURATION" \
  -derivedDataPath .build/DerivedData \
  build

APP=".build/DerivedData/Build/Products/$CONFIGURATION/CodeTime.app"
echo
echo "构建完成: $APP"
echo "运行: open \"$APP\""

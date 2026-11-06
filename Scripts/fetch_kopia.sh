#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="0.23.1"
SHA256="f67d9dd81a0f5169ad6579ba4c4a91fbaf4978f42defa52946a2f2277f7d55a8"
URL="https://github.com/kopia/kopia/releases/download/v${VERSION}/kopia-${VERSION}-macOS-universal.tar.gz"
DEST="$ROOT/Resources/Kopia"

if [ -x "$DEST/kopia" ] && [ "${1:-}" != "--force" ]; then
  echo "Kopia 已存在: $DEST/kopia"
  "$DEST/kopia" --version
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "下载 Kopia ${VERSION}…"
curl -fsSL -o "$WORK/kopia.tar.gz" "$URL"
echo "${SHA256}  $WORK/kopia.tar.gz" | shasum -a 256 -c -
mkdir -p "$WORK/extract" "$DEST"
tar -xzf "$WORK/kopia.tar.gz" -C "$WORK/extract"
cp "$WORK/extract/kopia-${VERSION}-macOS-universal/kopia" "$DEST/kopia"
cp "$WORK/extract/kopia-${VERSION}-macOS-universal/LICENSE" "$DEST/LICENSE"
cp "$WORK/extract/kopia-${VERSION}-macOS-universal/README.md" "$DEST/README.md"
chmod +x "$DEST/kopia"
echo "已安装: $DEST/kopia"
"$DEST/kopia" --version

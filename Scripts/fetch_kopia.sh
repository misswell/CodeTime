#!/bin/bash
# Fetches and verifies the pinned Kopia release.
#
# Upstream publishes a tarball with a fixed SHA-256 but no Apple code signature.
# Source authenticity is therefore established by HTTPS + the pinned digest;
# the binary is re-signed with the app identity during packaging. An existing
# binary is only reused after version, architecture, digest and (when present)
# code signature checks pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="0.23.1"
SHA256="f67d9dd81a0f5169ad6579ba4c4a91fbaf4978f42defa52946a2f2277f7d55a8"
URL="https://github.com/kopia/kopia/releases/download/v${VERSION}/kopia-${VERSION}-macOS-universal.tar.gz"
DEST="$ROOT/Resources/Kopia"
BINARY="$DEST/kopia"
SIDECAR="$DEST/kopia.sha256"

fail() { echo "Kopia 校验失败: $*" >&2; exit 1; }

verify_binary() {
  [ -x "$BINARY" ] || return 1
  local version arches
  version="$("$BINARY" --version 2>/dev/null || true)"
  [[ "$version" == *"$VERSION"* ]] || return 1

  arches="$(/usr/bin/lipo -archs "$BINARY" 2>/dev/null || true)"
  if [ -n "$arches" ] && { [[ "$arches" != *arm64* ]] || [[ "$arches" != *x86_64* ]]; }; then
    echo "  Kopia 架构不完整: $arches" >&2
    return 1
  fi

  [ -f "$SIDECAR" ] || return 1
  (cd "$DEST" && shasum -a 256 -c "$(basename "$SIDECAR")" >/dev/null) || return 1

  if codesign -dv "$BINARY" >/dev/null 2>&1; then
    codesign --verify --strict "$BINARY" >/dev/null 2>&1 || return 1
  fi
  return 0
}

if [ "${1:-}" != "--force" ] && verify_binary; then
  echo "Kopia 已存在且校验通过: $BINARY"
  "$BINARY" --version
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "下载 Kopia ${VERSION}…"
curl -fsSL --retry 3 -o "$WORK/kopia.tar.gz" "$URL"
echo "${SHA256}  $WORK/kopia.tar.gz" | shasum -a 256 -c - \
  || fail "下载包 SHA-256 与固定值不一致"

mkdir -p "$WORK/extract" "$DEST"
tar -xzf "$WORK/kopia.tar.gz" -C "$WORK/extract"
EXTRACTED="$WORK/extract/kopia-${VERSION}-macOS-universal/kopia"
[ -x "$EXTRACTED" ] || fail "压缩包中缺少 kopia 二进制"

ARCHS="$(/usr/bin/lipo -archs "$EXTRACTED")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || fail "架构不是通用二进制: $ARCHS"
[[ "$("$EXTRACTED" --version)" == *"$VERSION"* ]] || fail "版本与固定版本不一致"

cp "$EXTRACTED" "$BINARY"
cp "$WORK/extract/kopia-${VERSION}-macOS-universal/LICENSE" "$DEST/LICENSE"
cp "$WORK/extract/kopia-${VERSION}-macOS-universal/README.md" "$DEST/README.md"
chmod +x "$BINARY"
(cd "$DEST" && shasum -a 256 kopia > kopia.sha256)
echo "已安装: $BINARY ($ARCHS)"
"$BINARY" --version

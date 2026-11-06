#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export KOPIA_PATH="${KOPIA_PATH:-$ROOT/Resources/Kopia/kopia}"
if [ ! -x "$KOPIA_PATH" ]; then
  echo "未找到 Kopia: $KOPIA_PATH（可运行 Scripts/fetch_kopia.sh）" >&2
  exit 1
fi
swift test --package-path Packages/CodeTimeKit "$@"

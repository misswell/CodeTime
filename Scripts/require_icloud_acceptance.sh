#!/bin/bash
# Stable releases require a real two-Mac iCloud acceptance record. This is a
# manual gate by design: an XCTest cannot prove two physical Macs and a real
# iCloud container were used.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-${TAG:-}}"
[ -n "$TAG" ] || { echo "usage: $0 <tag>" >&2; exit 2; }

REPORT="${ICLOUD_ACCEPTANCE_REPORT:-$ROOT/Docs/releases/${TAG}-icloud-acceptance.md}"
if [ ! -f "$REPORT" ]; then
  echo "stable 发布缺少双 Mac iCloud 验收报告：$REPORT" >&2
  echo "请按 Docs/releases/ICLOUD_ACCEPTANCE_TEMPLATE.md 完成验收并提交报告。" >&2
  exit 1
fi

for phrase in "Mac A" "Mac B" "发布" "恢复" "结果"; do
  grep -q "$phrase" "$REPORT" || {
    echo "iCloud 验收报告缺少字段/章节：$phrase" >&2
    exit 1
  }
done
if ! grep -Eiq "PASS|通过" "$REPORT"; then
  echo "iCloud 验收报告未标记通过" >&2
  exit 1
fi
echo "iCloud acceptance report: PASS ($REPORT)"

#!/bin/bash
# Stable releases require a real two-Mac iCloud acceptance record. The report
# must be filled in, match the release tag/commit, and explicitly pass every
# required scenario. A copied template is rejected.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-${TAG:-}}"
[ -n "$TAG" ] || { echo "usage: $0 <tag>" >&2; exit 2; }

REPORT="${ICLOUD_ACCEPTANCE_REPORT:-$ROOT/Docs/releases/${TAG}-icloud-acceptance.md}"
fail() { echo "iCloud 验收报告不合格：$*" >&2; exit 1; }

[ -f "$REPORT" ] || fail "缺少 $REPORT"
grep -q "将本文件复制为" "$REPORT" && fail "报告仍是模板原件"
grep -Eq "PASS[[:space:]]*/[[:space:]]*FAIL|PLACEHOLDER" "$REPORT" && fail "报告含未填写占位符或 PASS / FAIL"
grep -Fx -e "- 发布 tag：$TAG" "$REPORT" || fail "发布 tag 不匹配（$TAG）"
if [ -n "${GITHUB_SHA:-}" ]; then
  grep -Fx -e "- 构建 commit：$GITHUB_SHA" "$REPORT" || fail "构建 commit 不匹配（$GITHUB_SHA）"
fi
grep -Eq "执行时间：[^[:space:]]+" "$REPORT" || fail "缺少执行时间"
grep -Eq "执行人：[^[:space:]]+" "$REPORT" || fail "缺少执行人"
grep -Eq "Mac A：.+macOS .+构建 .+" "$REPORT" || fail "缺少 Mac A 设备信息"
grep -Eq "Mac B：.+macOS .+构建 .+" "$REPORT" || fail "缺少 Mac B 设备信息"

for scenario in "首次上传" "第二台发现" "未下载读取" "上传中断" "恢复" "迁移" "密钥不匹配"; do
  line="$(grep -F "| $scenario |" "$REPORT" || true)"
  [ -n "$line" ] || fail "缺少场景：$scenario"
  echo "$line" | grep -Eq "\\|[[:space:]]*PASS[[:space:]]*\\|" \
    || fail "场景未明确 PASS：$scenario"
done
grep -Eq "^-[[:space:]]*结果：PASS$" "$REPORT" || fail "总结论不是 PASS"
# Only an explicit FAIL result cell blocks; prose such as “无 FAIL 项” must not.
grep -Eq "\|[^|]*\bFAIL\b[^|]*\|" "$REPORT" && fail "报告中存在 FAIL 项"

echo "iCloud acceptance report: PASS ($REPORT)"

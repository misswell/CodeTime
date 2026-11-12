#!/bin/bash
# Stable release gate for the revised scope: one Mac + iCloud Drive.
#
# Multi-device acceptance is intentionally NOT required and cannot be claimed by
# this gate. A report is accepted only when every single-Mac evidence file is
# present and bound to the immutable candidate artifact.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-${TAG:-}}"
[ -n "$TAG" ] || { echo "usage: $0 <tag>" >&2; exit 2; }

REPORT="${SINGLE_MAC_ACCEPTANCE_REPORT:-$ROOT/Docs/releases/${TAG}-single-mac-acceptance.md}"
EVIDENCE="${SINGLE_MAC_ACCEPTANCE_EVIDENCE_DIR:-}"
fail() { echo "单机 iCloud 验收不合格：$*" >&2; exit 1; }

[ -f "$REPORT" ] || fail "缺少 $REPORT"
grep -q "将本文件复制为" "$REPORT" && fail "报告仍是模板原件"
grep -Eq "PLACEHOLDER|RESULT_PLACEHOLDER" "$REPORT" && fail "报告含未填写占位符"
grep -Fx -e "- 发布 tag：$TAG" "$REPORT" || fail "发布 tag 不匹配（$TAG）"
if [ -n "${GITHUB_SHA:-}" ]; then
  grep -Fx -e "- 构建 commit：$GITHUB_SHA" "$REPORT" || fail "构建 commit 不匹配（$GITHUB_SHA）"
fi
REPORT_SHA="$( { grep -o 'Candidate Artifact SHA-256：[a-fA-F0-9]\{64\}' "$REPORT" || true; } | head -1 | sed 's/.*：//')"
[ -n "$REPORT_SHA" ] || fail "缺少 Candidate Artifact SHA-256"
if [ -n "${EXPECTED_ARTIFACT_SHA:-}" ]; then
  [ "$REPORT_SHA" = "$EXPECTED_ARTIFACT_SHA" ] \
    || fail "Candidate Artifact SHA-256 不一致"
fi
grep -Eq "^- Candidate Artifact：.+\.zip$" "$REPORT" || fail "缺少 Candidate Artifact 名称"
grep -Eq "执行时间：[^[:space:]]+" "$REPORT" || fail "缺少执行时间"
grep -Eq "执行人：[^[:space:]]+" "$REPORT" || fail "缺少执行人"
grep -Eq "^- Mac：.+ / 设备 .+ / App .+" "$REPORT" || fail "缺少单 Mac 设备信息"
grep -Eq "^- 场景证据目录：.+" "$REPORT" || fail "缺少场景证据目录"
grep -q "多设备能力不在本次发布范围内" "$REPORT" || fail "缺少单机范围声明"

for scenario in backup_created upload_confirmed app_restart cache_cleared \
                redownload_from_icloud restore_to_new_directory sha256_all_files \
                metadata_and_symlinks upload_interruption upload_crash_recovery \
                restore_interruption gc_safe_single_device space_management; do
  line="$(grep -F "| $scenario |" "$REPORT" || true)"
  [ -n "$line" ] || fail "缺少场景证据：$scenario"
  echo "$line" | grep -Eq "\|[[:space:]]*PASS[[:space:]]*\|" \
    || fail "场景未明确 PASS：$scenario"
done
grep -Eq "^-[[:space:]]*结果：PASS$" "$REPORT" || fail "总结论不是 PASS"

if [ -n "$EVIDENCE" ]; then
  python3 "$ROOT/Scripts/check_single_mac_evidence.py" "$EVIDENCE" "$REPORT_SHA" "${GITHUB_SHA:-}" \
    || fail "场景证据不一致"
fi

echo "single-Mac iCloud acceptance: PASS ($REPORT)"

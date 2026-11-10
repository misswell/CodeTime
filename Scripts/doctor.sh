#!/bin/bash
# CodeTime release/acceptance doctor (CT-144).
#
# Prints exactly what is missing for a signed iCloud build and the two-Mac
# acceptance, with the next command for each blocker. Nothing here changes
# state: it only reads identities, profiles, secrets (names), iCloud account
# presence and the session lock state.
#
# Usage: Scripts/doctor.sh [--json]
# Exit: 0 = release-ready, 1 = blocked, 2 = usage error.
set -uo pipefail

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="misswell/CodeTime"
BUNDLE="com.codetime.app"
CONTAINER="iCloud.com.codetime.app"
APP_GROUP="U8U443D7ZL.com.codetime.app"

CHECKS=()   # "status|id|detail|next"
add() { CHECKS+=("$1|$2|$3|$4"); }

# 1. Developer ID identity -----------------------------------------------------
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  add PASS signing "Developer ID Application 证书可用" ""
else
  add BLOCKED signing "未找到 Developer ID Application 证书" "导入开发者证书到登录钥匙串"
fi

# 2. App Store Connect auth + PLA --------------------------------------------
if ! command -v asc >/dev/null 2>&1; then
  add BLOCKED asc "缺少 asc CLI" "brew install asc && asc auth login"
elif ! asc auth status >/dev/null 2>&1; then
  add BLOCKED asc "asc 未认证" "asc auth login"
else
  PLA_ERR="$(asc profiles list 2>&1 >/dev/null)"
  if printf '%s' "$PLA_ERR" | grep -qi "Program License Agreement"; then
    add BLOCKED pla "开发者协议未同意（App Store Connect API 拒绝所有证书/描述文件请求）" \
      "Account Holder 打开 developer.apple.com → Account → Agreements 同意最新协议"
  elif printf '%s' "$PLA_ERR" | grep -qi "error"; then
    add WARN asc "asc 已认证但 profiles 接口返回异常：$(printf '%s' "$PLA_ERR" | head -1)" \
      "检查 API key 角色（Admin/App Manager）"
  else
    add PASS pla "App Store Connect 证书/描述文件接口可用" ""
  fi
fi

# 3. Provisioning profile installed for this bundle ---------------------------
PROFILE_OK=0
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
if [ -d "$PROFILE_DIR" ]; then
  for f in "$PROFILE_DIR"/*.mobileprovision; do
    [ -f "$f" ] || continue
    DECODED="$(security cms -D -i "$f" 2>/dev/null || true)"
    [ -n "$DECODED" ] || continue
    printf '%s' "$DECODED" | grep -q "$BUNDLE" || continue
    printf '%s' "$DECODED" | grep -q "$CONTAINER" || continue
    printf '%s' "$DECODED" | grep -q "$APP_GROUP" || continue
    PROFILE_NAME="$(printf '%s' "$DECODED" | plutil -extract Name raw - 2>/dev/null || echo "?")"
    PROFILE_OK=1
    break
  done
fi
if [ "$PROFILE_OK" = "1" ]; then
  add PASS profile "本机已安装含 iCloud 的描述文件：${PROFILE_NAME:-?}" ""
else
  add BLOCKED profile "本机没有 $BUNDLE 的 Developer ID 描述文件（含 $CONTAINER 与 App Group）" \
    "同意协议后运行 Scripts/setup_apple_provisioning.sh，并把描述文件安装到本机"
fi

# 4. GitHub secrets (names only; values are never read) ----------------------
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  SECRETS="$(gh secret list --repo "$REPO" 2>/dev/null | cut -f1 | tr '\n' ' ')"
  MISSING=""
  for name in APPLE_CERTIFICATE_P12 APPLE_CERTIFICATE_PASSWORD APPLE_DEVELOPER_ID \
              APPLE_TEAM_ID APPLE_ID APPLE_PROVISIONING_PROFILE APPLE_APP_SPECIFIC_PASSWORD; do
    printf '%s' " $SECRETS " | grep -q " $name " || MISSING="$MISSING $name"
  done
  if [ -z "$MISSING" ]; then
    add PASS secrets "仓库 secrets 齐全" ""
  else
    add BLOCKED secrets "缺少 secret：$MISSING" \
      "APPLE_PROVISIONING_PROFILE 由 setup 脚本写入；APPLE_APP_SPECIFIC_PASSWORD 需账号持有人填写"
  fi
else
  add WARN secrets "无法查询仓库 secrets（gh 未认证）" "gh auth login"
fi

# 5. iCloud account / Drive on this Mac --------------------------------------
# Authoritative-enough without entitlements: the CloudDocs container only exists
# when an Apple account is signed in AND iCloud Drive is on. If it is missing we
# deliberately do NOT claim to distinguish "not signed in" from "Drive off".
CLOUD_DOCS="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
if [ -d "$CLOUD_DOCS" ]; then
  add PASS icloud-account "本机 iCloud Drive 可用（已登录 Apple 账户）" ""
else
  add BLOCKED icloud-account "未检测到 iCloud Drive 目录（未登录 Apple 账户或 iCloud Drive 未开启）" \
    "系统设置 → Apple 账户 → iCloud → 打开 iCloud Drive 后重试"
fi

# 6. Session lock (blocks Keychain authorization dialogs) -------------------
LOCKED="$(ioreg -n Root -d1 -a 2>/dev/null | grep -A1 ScreenIsLocked | tail -1 | grep -c true || true)"
if [ "$LOCKED" = "1" ]; then
  add BLOCKED session "屏幕已锁定：Keychain 授权框无法点击，App 启动会阻塞" \
    "解锁 Mac，重新打开 CodeTime，点「始终允许」"
else
  add PASS session "屏幕已解锁（Keychain 授权可交互）" ""
fi

# 7. Saved window frame (CT-145) --------------------------------------------
# AppKit restores the last window frame. A frame saved on a now-disconnected
# external display puts the window — and the Keychain sheet it spawns —
# off-screen, which is indistinguishable from "the app never starts".
FRAME="$(defaults read com.codetime.app "NSWindow Frame main-AppWindow-1" 2>/dev/null || true)"
if [ -n "$FRAME" ]; then
  WX="$(printf '%s' "$FRAME" | awk '{printf "%d", $1+0}')"
  # Largest logical width across attached displays ("UI Looks like: 1920 x 1080").
  MAIN_W="$(system_profiler SPDisplaysDataType 2>/dev/null \
    | awk -F': ' '/UI Looks like/ {split($2,a," "); if (a[1]+0>m) m=a[1]+0} END {printf "%d", m+0}')"
  if [ "${MAIN_W:-0}" -gt 0 ] && { [ "$WX" -lt 0 ] || [ "$WX" -ge "$MAIN_W" ]; }; then
    add WARN window "CodeTime 窗口保存位置可能在屏幕外（x=${WX}，最宽屏幕 ${MAIN_W} pt）：启动会等到看门狗超时，钥匙串授权框也看不见" \
      "运行 Scripts/fix_window.sh 把窗口移回主屏（或删除偏好中的 NSWindow Frame main-AppWindow-1）"
  else
    add PASS window "CodeTime 窗口位置在屏幕可见范围内" ""
  fi
else
  add PASS window "没有保存的窗口位置（首次启动会居中显示）" ""
fi

# 8. Second Mac (cannot be probed locally) ----------------------------------
add MANUAL second-mac "第二台 Mac 无法自动探测" "在两台 Mac 上安装同一个签名包后运行 Scripts/icloud_acceptance.sh"

BLOCKED_COUNT=0
WARN_COUNT=0
for c in "${CHECKS[@]}"; do
  IFS='|' read -r status _ _ _ <<<"$c"
  [ "$status" = "BLOCKED" ] && BLOCKED_COUNT=$((BLOCKED_COUNT + 1))
  [ "$status" = "WARN" ] && WARN_COUNT=$((WARN_COUNT + 1))
done

if [ "$JSON" = "1" ]; then
  printf '{\n  "ready": %s,\n  "blocked": %d,\n  "warnings": %d,\n  "checks": [\n' \
    "$([ "$BLOCKED_COUNT" -eq 0 ] && echo true || echo false)" "$BLOCKED_COUNT" "$WARN_COUNT"
  first=1
  for c in "${CHECKS[@]}"; do
    IFS='|' read -r status id detail next <<<"$c"
    [ "$first" = "1" ] || printf ',\n'
    first=0
    python3 - "$status" "$id" "$detail" "$next" <<'PY'
import json, sys
status, cid, detail, nxt = sys.argv[1:5]
print("    " + json.dumps({"status": status, "id": cid, "detail": detail, "next": nxt}, ensure_ascii=False))
PY
  done
  printf '\n  ]\n}\n'
else
  echo "CodeTime doctor"
  echo "==============="
  for c in "${CHECKS[@]}"; do
    IFS='|' read -r status id detail next <<<"$c"
    case "$status" in
      PASS) mark="✓" ;;
      WARN) mark="!" ;;
      MANUAL) mark="·" ;;
      *) mark="✗" ;;
    esac
    printf '%s [%-8s] %s\n' "$mark" "$status" "$detail"
    [ -n "$next" ] && printf '            → %s\n' "$next"
  done
  echo
  if [ "$BLOCKED_COUNT" -eq 0 ]; then
    echo "结论：签名与发布前置已就绪（第二台 Mac 的验收仍需人工完成）。"
    exit 0
  fi
  echo "结论：$BLOCKED_COUNT 项阻塞（见上方 ✗）。按每条 → 的提示处理后重新运行本脚本。"
  exit 1
fi

[ "$BLOCKED_COUNT" -eq 0 ] && exit 0 || exit 1

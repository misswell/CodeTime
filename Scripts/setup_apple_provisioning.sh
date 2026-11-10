#!/bin/bash
# Creates (or reuses) the Developer ID provisioning profile CodeTime needs for
# iCloud, validates it, and stores it as the APPLE_PROVISIONING_PROFILE secret.
#
# Why this exists: a Developer ID build with iCloud entitlements REQUIRES a
# Developer ID provisioning profile. It is not something CI can invent, and
# `xcodebuild -allowProvisioningUpdates` cannot create it while the Apple
# Developer Program License Agreement is unaccepted.
#
# Prerequisites (human, one time):
#   1. The team's Account Holder accepts the current Program License Agreement
#      at https://developer.apple.com/account → Agreements.
#   2. `asc auth status` shows an authenticated App Store Connect key with
#      Admin/App Manager role, and `gh auth status` can write repo secrets.
#
# Usage:
#   Scripts/setup_apple_provisioning.sh [--repo misswell/CodeTime]
#                                       [--bundle com.codetime.app]
#                                       [--profile-type MAC_APP_DIRECT]
#                                       [--name "CodeTime Developer ID"]
#
# Exit codes: 0 = secret written, 1 = failed (message explains the next action).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

REPO="misswell/CodeTime"
BUNDLE="com.codetime.app"
NAME="CodeTime Developer ID"
# Apple's macOS direct-distribution type. Overridable because the API enum has
# been renamed between portal generations (MAC_APP_DIRECT / DEVELOPER_ID_APPLICATION).
PROFILE_TYPE="MAC_APP_DIRECT"
CONTAINER="iCloud.com.codetime.app"
APP_GROUP="U8U443D7ZL.com.codetime.app"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --bundle) BUNDLE="$2"; shift 2 ;;
    --profile-type) PROFILE_TYPE="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo "==> $*"; }

command -v asc >/dev/null || fail "缺少 asc CLI（brew install asc）"
command -v gh >/dev/null || fail "缺少 gh CLI"
command -v security >/dev/null || fail "缺少 security（macOS 自带）"

step "检查 App Store Connect 认证"
if ! asc auth status >/dev/null 2>&1; then
  fail "asc 未认证：先运行 asc auth login"
fi
if ! asc bundle-ids list >/dev/null 2>&1; then
  echo "无法读取 Bundle ID。最常见原因：账号持有人未同意新版开发者协议。" >&2
  echo "  请由 Account Holder 打开 https://developer.apple.com/account → Agreements 同意后重试。" >&2
  exit 1
fi

step "查找 Bundle ID $BUNDLE"
BUNDLE_ID="$(asc bundle-ids list --output json 2>/dev/null \
  | python3 -c "
import json,sys
data=json.load(sys.stdin)
items=data.get('data', data if isinstance(data,list) else [])
for item in items:
    attrs=item.get('attributes',{})
    if attrs.get('identifier')=='$BUNDLE':
        print(item.get('id','')); break
")"
[ -n "$BUNDLE_ID" ] || fail "App Store Connect 中没有 $BUNDLE（先在 portal 创建 App ID 并开启 iCloud）"
echo "    bundle id: $BUNDLE_ID"

step "查找 Developer ID Application 证书"
CERT_ID="$(asc certificates list --output json 2>/dev/null \
  | python3 -c "
import json,sys
data=json.load(sys.stdin)
items=data.get('data', data if isinstance(data,list) else [])
for item in items:
    attrs=item.get('attributes',{})
    if attrs.get('certificateType')=='DEVELOPER_ID_APPLICATION':
        print(item.get('id','')); break
")"
[ -n "$CERT_ID" ] || fail "没有可用的 Developer ID Application 证书（需先上传 CSR 并在 portal 创建）"
echo "    certificate id: $CERT_ID"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROFILE_PATH="$TMP/codetime.provisionprofile"

step "创建描述文件（类型 $PROFILE_TYPE）"
if asc profiles create \
     --name "$NAME" \
     --profile-type "$PROFILE_TYPE" \
     --bundle "$BUNDLE_ID" \
     --certificate "$CERT_ID" \
     --output json > "$TMP/create.json" 2>"$TMP/create.err"; then
  PROFILE_ID="$(python3 -c "
import json
data=json.load(open('$TMP/create.json'))
item=data.get('data', data)
print(item.get('id','') if isinstance(item,dict) else '')
")"
  [ -n "$PROFILE_ID" ] || fail "创建成功但未返回描述文件 ID"
  echo "    profile id: $PROFILE_ID"
else
  # Reuse an existing profile with the same name instead of failing outright.
  echo "    创建失败，尝试复用同名描述文件…" >&2
  sed 's/^/    /' "$TMP/create.err" >&2 || true
  PROFILE_ID="$(asc profiles list --output json 2>/dev/null \
    | python3 -c "
import json,sys
data=json.load(sys.stdin)
items=data.get('data', data if isinstance(data,list) else [])
for item in items:
    if item.get('attributes',{}).get('name')=='$NAME':
        print(item.get('id','')); break
")"
  [ -n "$PROFILE_ID" ] || fail "既无法创建也无法复用描述文件（若提示 PLA，请先同意开发者协议）"
  echo "    复用 profile id: $PROFILE_ID"
fi

step "下载描述文件"
asc profiles download --id "$PROFILE_ID" --output "$PROFILE_PATH" >/dev/null 2>&1 \
  || fail "下载描述文件失败（id $PROFILE_ID）"

step "校验描述文件包含 iCloud 容器与 App Group"
DECODED="$(security cms -D -i "$PROFILE_PATH" 2>/dev/null)" || fail "描述文件无法解码"
printf '%s' "$DECODED" | grep -q "$CONTAINER" \
  || fail "描述文件未包含 $CONTAINER（先在 App ID 上启用 iCloud 并勾选该容器，再重建描述文件）"
printf '%s' "$DECODED" | grep -q "$APP_GROUP" \
  || fail "描述文件未包含 App Group $APP_GROUP"
printf '%s' "$DECODED" | grep -q "$BUNDLE" \
  || fail "描述文件与 $BUNDLE 不匹配"
PROFILE_NAME="$(printf '%s' "$DECODED" | plutil -extract Name raw - 2>/dev/null || echo "$NAME")"
echo "    描述文件名称: $PROFILE_NAME"

step "写入 GitHub secret APPLE_PROVISIONING_PROFILE（$REPO）"
base64 -i "$PROFILE_PATH" | gh secret set APPLE_PROVISIONING_PROFILE --repo "$REPO" \
  || fail "写入 secret 失败（gh 权限？）"

echo
echo "完成：APPLE_PROVISIONING_PROFILE 已配置（描述文件 $PROFILE_NAME）。"
echo "下一步："
echo "  1) 确认 APPLE_APP_SPECIFIC_PASSWORD 已在仓库 Secrets 中填写（公证用，只有账号持有人能提供）"
echo "  2) 本地验收：Scripts/package_release.sh（需 TAG/DEVELOPMENT_TEAM 与描述文件已安装）"
echo "  3) 双 Mac 验收：打 beta tag 或手动触发 Release workflow，安装签名包后在两台 Mac 上完成上传/发现/恢复"

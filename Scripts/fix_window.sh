#!/bin/bash
# Moves CodeTime's main window (and any pending authorization dialog) back onto
# the main display (CT-145).
#
# Why this exists: AppKit restores the last window frame. If that frame came from
# an external display that is no longer connected, the window — and the Keychain
# authorization sheet it spawns — is drawn off-screen. From the user's side this
# looks exactly like "the app never finishes starting": the bootstrap watchdog
# eventually reports "启动被系统授权阻塞", but the dialog to click is invisible.
#
# Usage: Scripts/fix_window.sh [x] [y]
# Exit: 0 = window moved (or CodeTime not running), 1 = could not move it.
set -uo pipefail

X="${1:-80}"
Y="${2:-120}"

if ! pgrep -f "CodeTime.app/Contents/MacOS/CodeTime" >/dev/null 2>&1; then
  echo "CodeTime 未在运行；直接启动即可（没有保存的窗口位置时会居中）。"
  exit 0
fi

fail=0
if ! osascript -e "tell application \"System Events\" to tell process \"CodeTime\" to set position of window 1 to {$X, $Y}" >/dev/null 2>&1; then
  echo "无法移动 CodeTime 窗口：需要在 系统设置 → 隐私与安全性 → 辅助功能 中授权终端。" >&2
  fail=1
fi

# The authorization sheet belongs to SecurityAgent and is anchored wherever the
# app asked for it, so it has to be moved separately.
osascript <<'APPLESCRIPT' >/dev/null 2>&1 || true
tell application "System Events"
  if exists process "SecurityAgent" then
    tell process "SecurityAgent"
      try
        set position of window 1 to {600, 260}
      end try
    end tell
  end if
end tell
APPLESCRIPT

if [ "$fail" = "0" ]; then
  echo "已把 CodeTime 窗口移到 ($X, $Y)；若屏幕上有钥匙串授权框，它已移到 (600, 260)。"
fi
exit "$fail"

#!/bin/bash
# iCloud dual-Mac acceptance preflight (fails closed).
#
# This script does NOT accept any Apple agreement and does not create signing
# assets. It only reports whether this Mac can actually upload to iCloud and
# whether the requested peer evidence exists. A BLOCKED result must never be
# turned into a PASS report.
#
# Usage:
#   Scripts/icloud_preflight.sh
#   Scripts/icloud_preflight.sh --peer-evidence /path/to/macB-evidence.json
#
# Exit codes: 0 = READY, 3 = BLOCKED, 2 = usage/environment error.
set -euo pipefail

PEER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --peer-evidence) PEER="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

echo "ICLOUD_PRECHECK_BEGIN $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "host=$(hostname)"
echo "model=$(sysctl -n hw.model 2>/dev/null || echo unknown)"
echo "macos=$(sw_vers -productVersion 2>/dev/null || echo unknown)"

BLOCKED=0
note() { echo "$1"; }
block() { echo "BLOCKED: $1"; BLOCKED=1; }

# 1. Signing identities. Presence is necessary, not sufficient: iCloud also
# needs a provisioning profile with the iCloud feature.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if echo "$IDENTITIES" | grep -q 'Apple Development\|Apple Distribution'; then
  echo "signing_identity=present"
else
  block "no Apple Development/Distribution signing identity"
fi

# 2. App Store Connect access. The ASC API reports PLA state precisely; ignore
# failures when the tool is not installed, but do not treat "unknown" as ready.
if command -v asc >/dev/null 2>&1; then
  ASC_OUT="$(asc bundle-ids list 2>&1 || true)"
  if echo "$ASC_OUT" | grep -q 'PLA\|Program License Agreement'; then
    block "Apple Developer Program License Agreement not accepted (Account Holder must accept in App Store Connect)"
  elif echo "$ASC_OUT" | grep -qi 'bundle\|identifier'; then
    echo "asc_api=ready"
  else
    block "cannot confirm App Store Connect access: $(echo "$ASC_OUT" | head -1)"
  fi
else
  note "asc_api=unknown (asc not installed)"
fi

# 3. Real iCloud Drive upload state, independent of the app and its signing.
CLOUD_DOCS="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
if [ ! -d "$CLOUD_DOCS" ]; then
  block "iCloud Drive directory not found: $CLOUD_DOCS"
else
  PROBE="$(mktemp /tmp/codetime-icloud-probe-XXXXXX.swift)"
  trap 'rm -f "$PROBE"' EXIT
  cat >"$PROBE" <<'SWIFT'
import Foundation
let folder = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"
let url = URL(fileURLWithPath: folder).appendingPathComponent("codetime-preflight-\(UUID().uuidString).txt")
do {
    try Data("preflight".utf8).write(to: url)
} catch {
    print("probe_write_error=\(error)")
    exit(4)
}
defer { try? FileManager.default.removeItem(at: url) }
let keys: Set<URLResourceKey> = [
    .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
    .ubiquitousItemUploadingErrorKey,
]
var lastError: Error?
for _ in 0..<15 {
    do {
        let values = try url.resourceValues(forKeys: keys)
        if let error = values.ubiquitousItemUploadingError {
            lastError = error
            print("upload_error=\(error.localizedDescription)")
            print("upload_error_domain=\((error as NSError).domain)")
            print("upload_error_code=\((error as NSError).code)")
            exit(3)
        }
        if values.isUbiquitousItem == true, values.ubiquitousItemIsUploaded == true {
            print("ubiquitous=true")
            print("uploaded=true")
            exit(0)
        }
    } catch {
        lastError = error
        print("metadata_error=\(error.localizedDescription)")
    }
    Thread.sleep(forTimeInterval: 1)
}
print("upload_timeout=true")
if let lastError { print("last_error=\(lastError.localizedDescription)") }
exit(3)
SWIFT
  set +e
  PROBE_OUT="$(swift "$PROBE" 2>&1)"
  PROBE_STATUS=$?
  set -e
  echo "$PROBE_OUT"
  if [ "$PROBE_STATUS" -ne 0 ]; then
    block "iCloud Drive upload was not confirmed (exit $PROBE_STATUS)"
  fi
fi

# 4. The second Mac's evidence must exist and be from a different host. This is
# the only accepted proof that a real second Mac participated.
if [ -n "$PEER" ]; then
  if [ ! -f "$PEER" ]; then
    block "missing second-Mac evidence: $PEER"
  else
    if ! python3 - "$PEER" "$(hostname)" <<'PY'
import json, sys
path, host = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception as error:
    print(f"BLOCKED: second-Mac evidence is not valid JSON: {error}")
    sys.exit(1)
peer = data.get("host")
if not peer or peer == host:
    print(f"BLOCKED: evidence host={peer!r} equals current host={host!r}; not a second Mac")
    sys.exit(1)
if data.get("verified") is not True:
    print("BLOCKED: second-Mac restore verification did not pass (verified != true)")
    sys.exit(1)
print(f"peer_host={peer}")
print("peer_verified=true")
PY
    then
      BLOCKED=1
    fi
  fi
else
  note "peer_evidence=not-provided"
fi

if [ "$BLOCKED" -ne 0 ]; then
  echo "ICLOUD_PRECHECK_BLOCKED"
  exit 3
fi
echo "ICLOUD_PRECHECK_READY"

#!/bin/bash
# Interactive, user-run helper: create/associate the CodeTime iCloud Container.
#
# This script is intentionally NOT runnable unattended: fastlane asks for your
# Apple ID password and 2FA in this terminal. The password never passes through
# the agent, shell history, environment files, or the repository.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "CodeTime iCloud Container setup"
echo "  Bundle ID : com.codetime.app"
echo "  Container : iCloud.com.codetime.app"
echo
read -r -p "Apple ID email: " APPLE_ID
if [ -z "$APPLE_ID" ]; then
  echo "Apple ID is required." >&2
  exit 2
fi

echo
echo "== Creating/associating iCloud Container (fastlane will prompt for password/2FA) =="
fastlane produce associate_cloud_container \
  -a com.codetime.app \
  iCloud.com.codetime.app \
  -u "$APPLE_ID" \
  -b U8U443D7ZL

echo
echo "== Rebuilding profile and verifying iCloud entitlements =="
Scripts/configure_icloud_signing.sh

echo
echo "DONE. Press any key to close this window."
read -n 1 -s -r || true

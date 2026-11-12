#!/usr/bin/env python3
"""Validate structured dual-Mac iCloud acceptance evidence.

Usage:
    check_icloud_evidence.py <evidence-dir> <candidate-sha256> [commit]

Exit 0 only when every required scenario exists once, passed, is bound to the
candidate artifact and commit, and has the required assertions.
"""
import glob
import json
import os
import sys

REQUIRED = {
    "first_backup": {"upload_confirmed": True, "spool_empty": True},
    "cross_device_discovery": {"discovered": True},
    "metadata_only_read": {"object_body_downloaded": False},
    "repeat_backup": {"no_redownload": True},
    "interrupted_upload": {"snapshot_not_published": True, "spool_preserved": True},
    "upload_recovery": {"retry_completed": True},
    "full_restore": {"verified": True},
    "wrong_key": {"blocked": True},
    "gc_barrier": {"restore_blocked": True, "ack_durable": True},
    "gc_resume": {"resumed": True},
    "migration": {"legacy_readable": True},
}


def fail(message: str) -> None:
    print(f"icloud evidence: FAIL ({message})", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    if len(sys.argv) < 3:
        fail("usage: check_icloud_evidence.py <dir> <candidate-sha256> [commit]")
    directory, candidate, commit = sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else ""
    if not os.path.isdir(directory):
        fail(f"missing evidence directory: {directory}")
    seen = {}
    for path in sorted(glob.glob(os.path.join(directory, "*.json"))):
        try:
            entry = json.load(open(path, encoding="utf-8"))
        except Exception as error:
            fail(f"{path}: invalid JSON: {error}")
        scenario = entry.get("scenario")
        if scenario not in REQUIRED:
            fail(f"{path}: unknown scenario {scenario!r}")
        if scenario in seen:
            fail(f"duplicate scenario evidence: {scenario}")
        if entry.get("result") != "passed":
            fail(f"{scenario} result is {entry.get('result')!r}")
        if entry.get("candidate_sha256") != candidate:
            fail(f"{scenario} candidate hash mismatch")
        if commit and entry.get("commit") != commit:
            fail(f"{scenario} commit mismatch")
        if not entry.get("device_id") or not entry.get("host") or not entry.get("app_version"):
            fail(f"{scenario} lacks device/host/app version")
        assertions = entry.get("assertions")
        if not isinstance(assertions, dict):
            fail(f"{scenario} assertions missing")
        for key, expected in REQUIRED[scenario].items():
            if assertions.get(key) != expected:
                fail(f"{scenario} assertion {key} must be {expected!r}, got {assertions.get(key)!r}")
        if scenario == "full_restore":
            if assertions.get("checked_files") != assertions.get("expected_files"):
                fail("full_restore did not check every expected file")
        seen[scenario] = entry
    missing = sorted(set(REQUIRED) - set(seen))
    if missing:
        fail("missing scenarios: " + ", ".join(missing))
    hosts = {entry["host"] for entry in seen.values()}
    if len(hosts) < 2:
        fail("evidence does not prove two different Macs")
    print(f"icloud evidence: PASS ({len(seen)} scenarios, {len(hosts)} hosts)")


if __name__ == "__main__":
    main()

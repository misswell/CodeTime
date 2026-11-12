#!/usr/bin/env python3
"""Validate single-Mac iCloud acceptance evidence.

Usage:
    check_single_mac_evidence.py <evidence-dir> <candidate-sha256> [commit]

This is the release gate for the revised scope: one Mac + iCloud Drive. It does
not require a second Mac and never treats unverified multi-device features as a
release capability.
"""
import glob
import json
import os
import sys

REQUIRED = {
    "backup_created": {"commit_published": True},
    "upload_confirmed": {"upload_confirmed": True, "pending_tasks": 0},
    "app_restart": {"snapshot_readable_after_restart": True},
    "cache_cleared": {"cache_bytes": 0},
    "redownload_from_icloud": {"redownloaded": True},
    "restore_to_new_directory": {},
    "sha256_all_files": {"sha256_all": True},
    "metadata_and_symlinks": {"modes": True, "mtimes": True, "symlinks": True},
    "upload_interruption": {
        "snapshot_not_published": True,
        "spool_preserved": True,
        "retry_completed": True,
    },
    "upload_crash_recovery": {"journal_recovered": True, "no_duplicate_upload": True},
    "restore_interruption": {"partial_rejected": True, "resume_completed": True},
    "gc_safe_single_device": {
        "active_restore_blocks_delete": True,
        "referenced_objects_protected": True,
        "pack_protected": True,
        "incomplete_reference_aborts": True,
        "resume_idempotent": True,
    },
    "space_management": {
        "spool_within_budget": True,
        "cache_within_budget": True,
        "locks_bounded": True,
    },
}


def fail(message: str) -> None:
    print(f"single-mac evidence: FAIL ({message})", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    if len(sys.argv) < 3:
        fail("usage: check_single_mac_evidence.py <dir> <candidate-sha256> [commit]")
    directory, candidate = sys.argv[1], sys.argv[2]
    commit = sys.argv[3] if len(sys.argv) > 3 else ""
    if not os.path.isdir(directory):
        fail(f"missing evidence directory: {directory}")
    allow_fixture = os.environ.get("SINGLE_MAC_ACCEPTANCE_ALLOW_FIXTURE") == "1"
    seen = {}
    hosts = set()
    devices = set()
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
        evidence_kind = entry.get("evidence_kind")
        if evidence_kind not in ("real", "fixture"):
            fail(f"{scenario} lacks evidence_kind (real|fixture)")
        if evidence_kind != "real" and not allow_fixture:
            fail(f"{scenario} is fixture evidence and cannot pass the release gate")
        if entry.get("candidate_sha256") != candidate:
            fail(f"{scenario} candidate hash mismatch")
        if commit and entry.get("commit") != commit:
            fail(f"{scenario} commit mismatch")
        host = entry.get("host")
        device = entry.get("device_id")
        if not host or not device or not entry.get("app_version"):
            fail(f"{scenario} lacks host/device/app version")
        hosts.add(host)
        devices.add(device)
        assertions = entry.get("assertions")
        if not isinstance(assertions, dict):
            fail(f"{scenario} assertions missing")
        for key, expected in REQUIRED[scenario].items():
            if key not in assertions or assertions[key] != expected:
                fail(f"{scenario} assertion {key} must be {expected!r}, got {assertions.get(key)!r}")
        if scenario == "restore_to_new_directory":
            if assertions.get("restored_files") != assertions.get("expected_files"):
                fail("restored_files != expected_files")
        if scenario == "sha256_all_files":
            if assertions.get("checked_files") != assertions.get("expected_files"):
                fail("sha256_all_files did not check every file")
        seen[scenario] = entry
    missing = sorted(set(REQUIRED) - set(seen))
    if missing:
        fail("missing scenarios: " + ", ".join(missing))
    if len(hosts) != 1 or len(devices) != 1:
        fail("single-Mac evidence must come from exactly one host/device")
    print(f"single-mac evidence: PASS ({len(seen)} scenarios, host={next(iter(hosts))})")


if __name__ == "__main__":
    main()

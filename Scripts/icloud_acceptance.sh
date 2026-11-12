#!/bin/bash
# Two-Mac iCloud acceptance evidence tool (CT-141).
#
# The acceptance itself is performed by the SIGNED CodeTime app on two real Macs
# (that part cannot be automated from one machine). This tool makes the evidence
# reproducible and impossible to fabricate:
#
#   Mac A (source):
#     Scripts/icloud_acceptance.sh prepare --project ~/AcceptanceFixture --out A.json
#     → hashes every fixture file, records host/model/macOS
#     then use the app: add the project, run the backup, confirm "已上传到 iCloud"
#
#   Mac B (recovery):
#     Scripts/icloud_acceptance.sh prepare --project ~/AcceptanceFixture --out A-copy.json
#     (optional sanity: A.json and A-copy.json must be identical)
#     use the app: 从云端恢复 → 输入恢复密钥 → 恢复项目
#     Scripts/icloud_acceptance.sh verify --evidence A.json --restored ~/AcceptanceFixture --out B.json
#
#   Report (on either Mac, after verify passed):
#     Scripts/icloud_acceptance.sh report --a A.json --b B.json \
#        --tag v1.0.0 --commit <git sha> --candidate-sha <zip sha256> \
#        --candidate-name CodeTime-1.0.0-macos-universal.zip \
#        --run <workflow-run-id> --operator "<name>" \
#        --out Docs/releases/v1.0.0-icloud-acceptance.md
#
# `report` refuses to write PASS unless B.json says verified=true, so a missing or
# failed verification can never produce an acceptable report.
#
# Fixture rules: use files that are NOT matched by any exclusion rule (e.g.
# main.swift, README.md, src/*.txt). Excluded files (node_modules, .git, logs…)
# are legitimately absent from the restore and would otherwise look "missing".
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# Sorted "relative<TAB>sha256" lines for every regular file under a directory.
manifest_lines() {
  local root="$1"
  ( cd "$root" && find . -type f -not -path './.git/*' -print | LC_ALL=C sort | while IFS= read -r rel; do
      printf '%s\t%s\n' "${rel#./}" "$(sha256_of "$rel")"
    done )
}

hardware_model() {
  sysctl -n hw.model 2>/dev/null || echo "unknown"
}

os_version() {
  sw_vers -productVersion 2>/dev/null || echo "unknown"
}

cmd="${1:-}"; shift || true

case "$cmd" in
  preflight)
    exec "$(cd "$(dirname "$0")" && pwd)/icloud_preflight.sh" "$@"
    ;;

  prepare)
    PROJECT=""; OUT=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --project) PROJECT="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -d "$PROJECT" ] || fail "project not found: $PROJECT"
    [ -n "$OUT" ] || usage
    COUNT="$(manifest_lines "$PROJECT" | wc -l | tr -d ' ')"
    [ "$COUNT" -gt 0 ] || fail "project has no regular files"
    python3 - "$PROJECT" "$OUT" "$COUNT" <<'PY'
import hashlib, json, subprocess, sys, datetime, platform
project, out, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
def sh(cmd):
    try: return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()
    except Exception: return ""
files = {}
import os
for base, dirs, names in os.walk(project):
    dirs[:] = sorted(d for d in dirs if d != ".git")
    for name in sorted(names):
        path = os.path.join(base, name)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        rel = os.path.relpath(path, project)
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        files[rel] = h.hexdigest()
payload = {
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "host": platform.node(),
    "model": sh(["sysctl", "-n", "hw.model"]),
    "macOS": sh(["sw_vers", "-productVersion"]),
    "fileCount": len(files),
    "files": files,
}
with open(out, "w") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2, sort_keys=True)
print(f"prepared {len(files)} files -> {out}")
print(f"  model: {payload['model']} · macOS {payload['macOS']}")
PY
    ;;

  verify)
    EVIDENCE=""; RESTORED=""; OUT=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --evidence) EVIDENCE="$2"; shift 2 ;;
        --restored) RESTORED="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -f "$EVIDENCE" ] || fail "evidence not found: $EVIDENCE"
    [ -d "$RESTORED" ] || fail "restored tree not found: $RESTORED"
    [ -n "$OUT" ] || usage
    python3 - "$EVIDENCE" "$RESTORED" "$OUT" <<'PY'
import hashlib, json, os, sys, datetime, platform, subprocess
evidence_path, restored, out = sys.argv[1], sys.argv[2], sys.argv[3]
a = json.load(open(evidence_path))
files = a.get("files", {})
missing, mismatched, extra = [], [], []
checked = 0
for rel, expected in sorted(files.items()):
    path = os.path.join(restored, rel)
    if not os.path.isfile(path):
        missing.append(rel); continue
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    checked += 1
    if h.hexdigest() != expected:
        mismatched.append(rel)
expected_set = set(files)
for base, dirs, names in os.walk(restored):
    dirs[:] = sorted(d for d in dirs if d != ".git")
    for name in sorted(names):
        path = os.path.join(base, name)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        rel = os.path.relpath(path, restored)
        if rel not in expected_set:
            extra.append(rel)
def sh(cmd):
    try: return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()
    except Exception: return ""
verified = not missing and not mismatched and checked == len(files)
payload = {
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "host": platform.node(),
    "model": sh(["sysctl", "-n", "hw.model"]),
    "macOS": sh(["sw_vers", "-productVersion"]),
    "sourceEvidence": os.path.abspath(evidence_path),
    "sourceHost": a.get("host"),
    "sourceModel": a.get("model"),
    "expectedFiles": len(files),
    "checkedFiles": checked,
    "missing": missing,
    "mismatched": mismatched,
    "extra": extra,
    "verified": verified,
}
with open(out, "w") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2, sort_keys=True)
print(f"checked {checked}/{len(files)} files")
if missing:    print("  missing: " + ", ".join(missing[:5]) + ("…" if len(missing) > 5 else ""))
if mismatched: print("  mismatched: " + ", ".join(mismatched[:5]) + ("…" if len(mismatched) > 5 else ""))
if extra:      print(f"  extra files on restore: {len(extra)} (informational)")
print("RESULT: " + ("PASS" if verified else "FAIL"))
sys.exit(0 if verified else 1)
PY
    ;;

  record)
    SCENARIO=""; RESULT=""; DEVICE_ID=""; HOST="$(hostname)"
    MODEL="$(sysctl -n hw.model 2>/dev/null || echo unknown)"
    MACOS="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
    APP_VERSION="${CODETIME_APP_VERSION:-1.0.0}"
    CANDIDATE=""; COMMIT=""; STARTED=""; FINISHED=""; ASSERTIONS=""; OUT=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --scenario) SCENARIO="$2"; shift 2 ;;
        --result) RESULT="$2"; shift 2 ;;
        --device-id) DEVICE_ID="$2"; shift 2 ;;
        --host) HOST="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --macos) MACOS="$2"; shift 2 ;;
        --app-version) APP_VERSION="$2"; shift 2 ;;
        --candidate-sha) CANDIDATE="$2"; shift 2 ;;
        --commit) COMMIT="$2"; shift 2 ;;
        --started-at) STARTED="$2"; shift 2 ;;
        --finished-at) FINISHED="$2"; shift 2 ;;
        --assertions) ASSERTIONS="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    for required in SCENARIO RESULT DEVICE_ID CANDIDATE COMMIT ASSERTIONS OUT; do
      [ -n "${!required}" ] || fail "--${required,,} is required"
    done
    case "$RESULT" in passed|failed|blocked) ;; *) fail "result must be passed/failed/blocked" ;; esac
    python3 - "$SCENARIO" "$RESULT" "$DEVICE_ID" "$HOST" "$MODEL" "$MACOS" "$APP_VERSION" \
      "$CANDIDATE" "$COMMIT" "$STARTED" "$FINISHED" "$ASSERTIONS" "$OUT" <<'PY'
import json, sys, datetime
(scenario, result, device, host, model, macos, app_version,
 candidate, commit, started, finished, assertions_raw, out) = sys.argv[1:14]
try:
    assertions = json.loads(assertions_raw)
except json.JSONDecodeError as error:
    print(f"REFUSED: --assertions is not valid JSON: {error}", file=sys.stderr)
    sys.exit(1)
if not isinstance(assertions, dict) or not assertions:
    print("REFUSED: assertions must be a non-empty object", file=sys.stderr)
    sys.exit(1)
if not all(isinstance(k, str) and isinstance(v, (bool, int, float, str)) for k, v in assertions.items()):
    print("REFUSED: assertion keys must be strings and values scalar", file=sys.stderr)
    sys.exit(1)
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
payload = {
    "scenario": scenario,
    "result": result,
    "device_id": device,
    "host": host,
    "model": model,
    "macOS": macos,
    "app_version": app_version,
    "candidate_sha256": candidate,
    "commit": commit,
    "started_at": started or now,
    "finished_at": finished or now,
    "assertions": assertions,
}
with open(out, "w") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2, sort_keys=True)
print(f"wrote {out} ({scenario}: {result})")
PY
    ;;

  report)
    A=""; B=""; EVIDENCE_DIR=""; TAG=""; COMMIT=""; SHA=""; NAME=""; RUN=""; OPERATOR=""; OUT=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --a) A="$2"; shift 2 ;;
        --b) B="$2"; shift 2 ;;
        --evidence-dir) EVIDENCE_DIR="$2"; shift 2 ;;
        --tag) TAG="$2"; shift 2 ;;
        --commit) COMMIT="$2"; shift 2 ;;
        --candidate-sha) SHA="$2"; shift 2 ;;
        --candidate-name) NAME="$2"; shift 2 ;;
        --run) RUN="$2"; shift 2 ;;
        --operator) OPERATOR="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    for required in A B EVIDENCE_DIR TAG COMMIT SHA NAME RUN OPERATOR OUT; do
      [ -n "${!required}" ] || fail "--${required,,} is required"
    done
    [ -f "$A" ] || fail "missing evidence A: $A"
    [ -f "$B" ] || fail "missing evidence B: $B"
    [ -d "$EVIDENCE_DIR" ] || fail "missing scenario evidence dir: $EVIDENCE_DIR"
    python3 - "$A" "$B" "$EVIDENCE_DIR" "$TAG" "$COMMIT" "$SHA" "$NAME" "$RUN" "$OPERATOR" "$OUT" <<'PY'
import glob, json, os, sys, datetime
(a_path, b_path, evidence_dir, tag, commit, sha, name, run, operator,
 out) = sys.argv[1:11]
a, b = json.load(open(a_path)), json.load(open(b_path))
if not b.get("verified"):
    print("REFUSED: recovery verification did not pass (B.verified != true)", file=sys.stderr)
    sys.exit(1)
if a.get("fileCount") != b.get("expectedFiles") or b.get("checkedFiles") != b.get("expectedFiles"):
    print("REFUSED: evidence A/B file counts disagree", file=sys.stderr)
    sys.exit(1)
if not a.get("host") or not b.get("host") or a.get("host") == b.get("host"):
    print("REFUSED: A and B must be different hosts", file=sys.stderr)
    sys.exit(1)

# Every scenario must have its own real evidence file. The report generator never
# invents a PASS for a scenario it did not receive.
required = {
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
seen = {}
for path in sorted(glob.glob(os.path.join(evidence_dir, "*.json"))):
    try:
        entry = json.load(open(path))
    except Exception as error:
        print(f"REFUSED: {path}: invalid JSON: {error}", file=sys.stderr)
        sys.exit(1)
    scenario = entry.get("scenario")
    if scenario not in required:
        print(f"REFUSED: {path}: unknown scenario {scenario!r}", file=sys.stderr)
        sys.exit(1)
    if scenario in seen:
        print(f"REFUSED: duplicate scenario evidence {scenario}", file=sys.stderr)
        sys.exit(1)
    for key in ("result", "device_id", "host", "app_version", "candidate_sha256", "commit", "assertions"):
        if not entry.get(key):
            print(f"REFUSED: {path}: missing {key}", file=sys.stderr)
            sys.exit(1)
    if entry["result"] != "passed":
        print(f"REFUSED: {scenario} result is {entry['result']}", file=sys.stderr)
        sys.exit(1)
    if entry["commit"] != commit:
        print(f"REFUSED: {scenario} commit {entry['commit']} != {commit}", file=sys.stderr)
        sys.exit(1)
    if entry["candidate_sha256"] != sha:
        print(f"REFUSED: {scenario} candidate hash mismatch", file=sys.stderr)
        sys.exit(1)
    assertions = entry["assertions"]
    for key, expected in required[scenario].items():
        if key not in assertions or assertions[key] != expected:
            print(f"REFUSED: {scenario} assertion {key} must be {expected!r}, got {assertions.get(key)!r}", file=sys.stderr)
            sys.exit(1)
    if scenario == "full_restore":
        if assertions.get("checked_files") != assertions.get("expected_files"):
            print("REFUSED: full_restore did not check every expected file", file=sys.stderr)
            sys.exit(1)
    seen[scenario] = entry
missing = sorted(set(required) - set(seen))
if missing:
    print("REFUSED: missing scenario evidence: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
hosts = {entry["host"] for entry in seen.values()} | {a["host"], b["host"]}
if len(hosts) < 2:
    print("REFUSED: scenario evidence does not prove two different Macs", file=sys.stderr)
    sys.exit(1)

def device(entry):
    return f"{entry.get('model','unknown')} / macOS {entry.get('macOS','unknown')}"
when = datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
lines = [
 "# iCloud 双 Mac 验收记录",
 "",
 f"- 发布 tag：{tag}",
 f"- 构建 commit：{commit}",
 f"- Candidate Artifact：{name}",
 f"- Candidate Artifact SHA-256：{sha}",
 f"- Candidate Workflow Run：{run}",
 f"- 执行时间：{when}",
 f"- 执行人：{operator}",
 "",
 "## 设备",
 "",
 f"- Mac A：{device(a)}（host {a.get('host','?')}）",
 f"- Mac B：{device(b)}（host {b.get('host','?')}）",
 "",
 "## 场景与结果（由真实证据生成）",
 "",
 "| 场景 | 设备 | Host | 断言 | 结果 |",
 "|---|---|---|---|---|",
]
for scenario in required:
    entry = seen[scenario]
    assertion_text = ", ".join(f"{k}={v}" for k, v in sorted(entry["assertions"].items()))
    lines.append(f"| {scenario} | {entry['device_id']} | {entry['host']} | {assertion_text} | PASS |")
lines += [
 "",
 "## 证据",
 "",
 f"- A 证据：{a.get('fileCount')} 个文件，host {a.get('host')}，{a.get('generatedAt')}",
 f"- B 证据：校验 {b.get('checkedFiles')} 个文件，missing={len(b.get('missing',[]))}，"
 f"mismatched={len(b.get('mismatched',[]))}，verified={b.get('verified')}",
 f"- 场景证据目录：{os.path.abspath(evidence_dir)}",
 "",
 "- 结果：PASS",
 "- 未通过项与原因：无",
 "",
]
with open(out, "w") as fh:
    fh.write("\n".join(lines))
print(f"wrote {out}")
PY
    ;;

  *)
    usage
    ;;
esac

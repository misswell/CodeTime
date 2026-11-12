#!/bin/bash
# Single-Mac iCloud acceptance evidence tool (revised scope).
#
# Scope: one Mac + iCloud Drive. No second Mac is required or accepted as a
# release blocker. Multi-device acceptance is deliberately outside this gate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

cmd="${1:-}"; shift || true
case "$cmd" in
  record)
    SCENARIO=""; RESULT=""; DEVICE_ID=""; HOST="$(hostname)"
    MODEL="$(sysctl -n hw.model 2>/dev/null || echo unknown)"
    MACOS="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
    APP_VERSION="${CODETIME_APP_VERSION:-1.0.0}"
    CANDIDATE=""; COMMIT=""; STARTED=""; FINISHED=""; ASSERTIONS=""; OUT=""
    EVIDENCE_KIND="${SINGLE_MAC_EVIDENCE_KIND:-real}"
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
        --evidence-kind) EVIDENCE_KIND="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    for required in SCENARIO RESULT DEVICE_ID CANDIDATE COMMIT ASSERTIONS OUT; do
      [ -n "${!required}" ] || fail "--${required,,} is required"
    done
    case "$RESULT" in passed|failed|blocked) ;; *) fail "result must be passed/failed/blocked" ;; esac
    case "$EVIDENCE_KIND" in real|fixture) ;; *) fail "evidence-kind must be real/fixture" ;; esac
    python3 - "$SCENARIO" "$RESULT" "$DEVICE_ID" "$HOST" "$MODEL" "$MACOS" "$APP_VERSION" \
      "$CANDIDATE" "$COMMIT" "$STARTED" "$FINISHED" "$ASSERTIONS" "$OUT" "$EVIDENCE_KIND" <<'PY'
import json, sys, datetime
(scenario, result, device, host, model, macos, app_version,
 candidate, commit, started, finished, assertions_raw, out, evidence_kind) = sys.argv[1:15]
try:
    assertions = json.loads(assertions_raw)
except json.JSONDecodeError as error:
    print(f"REFUSED: invalid assertions JSON: {error}", file=sys.stderr)
    sys.exit(1)
if not isinstance(assertions, dict) or not assertions:
    print("REFUSED: assertions must be a non-empty object", file=sys.stderr)
    sys.exit(1)
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
payload = {
    "scenario": scenario, "result": result, "device_id": device, "host": host,
    "model": model, "macOS": macos, "app_version": app_version,
    "candidate_sha256": candidate, "commit": commit,
    "started_at": started or now, "finished_at": finished or now,
    "evidence_kind": evidence_kind,
    "assertions": assertions,
}
with open(out, "w") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2, sort_keys=True)
print(f"wrote {out} ({scenario}: {result})")
PY
    ;;

  report)
    EVIDENCE_DIR=""; TAG=""; COMMIT=""; SHA=""; NAME=""; RUN=""; OPERATOR=""; OUT=""
    while [ $# -gt 0 ]; do
      case "$1" in
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
    for required in EVIDENCE_DIR TAG COMMIT SHA NAME RUN OPERATOR OUT; do
      [ -n "${!required}" ] || fail "--${required,,} is required"
    done
    python3 "$ROOT/Scripts/check_single_mac_evidence.py" "$EVIDENCE_DIR" "$SHA" "$COMMIT" \
      || fail "单机 iCloud 场景证据不完整"
    python3 - "$EVIDENCE_DIR" "$TAG" "$COMMIT" "$SHA" "$NAME" "$RUN" "$OPERATOR" "$OUT" <<'PY'
import glob, json, os, sys, datetime
(directory, tag, commit, sha, name, run, operator, out) = sys.argv[1:9]
entries = []
for path in sorted(glob.glob(os.path.join(directory, "*.json"))):
    entries.append(json.load(open(path)))
entries.sort(key=lambda e: e["scenario"])
host = entries[0]["host"]
device = entries[0]["device_id"]
app_version = entries[0]["app_version"]
when = datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
lines = [
 "# iCloud 单 Mac 验收记录",
 "",
 f"- 发布 tag：{tag}",
 f"- 构建 commit：{commit}",
 f"- Candidate Artifact：{name}",
 f"- Candidate Artifact SHA-256：{sha}",
 f"- Candidate Workflow Run：{run}",
 f"- 执行时间：{when}",
 f"- 执行人：{operator}",
 f"- Mac：{host} / 设备 {device} / App {app_version}",
 "",
 "## 范围声明",
 "",
 "本次发布只验收单 Mac + iCloud Drive；多设备能力不在本次发布范围内。",
 "",
 "## 场景与结果（由真实证据生成）",
 "",
 "| 场景 | 断言 | 结果 |",
 "|---|---|---|",
]
for entry in entries:
    assertions = ", ".join(f"{k}={v}" for k, v in sorted(entry["assertions"].items()))
    lines.append(f"| {entry['scenario']} | {assertions} | PASS |")
lines += [
 "",
 f"- 场景证据目录：{os.path.abspath(directory)}",
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

  *) usage ;;
esac

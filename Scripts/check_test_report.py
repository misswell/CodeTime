#!/usr/bin/env python3
"""CT-127/CT-128: single consistency gate for the test reports.

The three engineering docs (TEST_REPORT, IMPLEMENTATION_STATUS,
KNOWN_LIMITATIONS) used to carry independently hand-edited test totals that
drifted apart (77 vs 154), and TEST_REPORT contradicted itself about CT-037.
This script makes one machine-readable block inside TEST_REPORT the source of
truth and verifies:

  1. TEST_REPORT carries a `<!-- test-report {…} -->` block bound to a commit
     that is an ancestor of HEAD, a CI run id, and a gate verdict;
  2. IMPLEMENTATION_STATUS and KNOWN_LIMITATIONS quote exactly the same
     executed / failures / skipped numbers;
  3. skipped tests are never counted as passed
     (passed must equal executed - failures - skipped);
  4. every NOT-RUN entry is still visibly marked NOT RUN in TEST_REPORT.

Usage:
  check_test_report.py [--repo-root DIR] [--docs-dir DIR] [--no-git]

Exit codes: 0 = consistent, 1 = inconsistent (must fail the release gate).
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(f"test-report check: FAIL ({message})")
    sys.exit(1)


def read(path: Path) -> str:
    if not path.exists():
        fail(f"missing file: {path}")
    return path.read_text(encoding="utf-8")


def extract_report_block(text: str) -> dict:
    match = re.search(r"<!--\s*test-report\s*(\{.*?\})\s*-->", text, re.DOTALL)
    if not match:
        fail("TEST_REPORT 缺少机器可读的 <!-- test-report {…} --> 统计块")
    try:
        block = json.loads(match.group(1))
    except json.JSONDecodeError as error:
        fail(f"test-report 统计块不是合法 JSON：{error}")
    for key in ("commit", "run", "executed", "failures", "skipped", "gate"):
        if key not in block:
            fail(f"test-report 统计块缺少字段 {key}")
    for key in ("executed", "failures", "skipped"):
        if not isinstance(block[key], int) or block[key] < 0:
            fail(f"test-report 统计块字段 {key} 必须是非负整数")
    if block["failures"] + block["skipped"] > block["executed"]:
        fail("failures + skipped 超过 executed")
    if "passed" in block and block["passed"] != block["executed"] - block["failures"] - block["skipped"]:
        fail(
            f"跳过项被计入通过：passed={block['passed']}，"
            f"应为 executed-failures-skipped="
            f"{block['executed'] - block['failures'] - block['skipped']}"
        )
    return block


def check_other_docs(docs_dir: Path, block: dict) -> None:
    status = read(docs_dir / "IMPLEMENTATION_STATUS.md")
    match = re.search(r"全量测试（本机）\s*\|\s*(\d+)\s*\|\s*(\d+)\s*失败，\s*(\d+)\s*跳过", status)
    if not match:
        fail("IMPLEMENTATION_STATUS 缺少『全量测试（本机）』统计行")
    if (int(match.group(1)), int(match.group(2)), int(match.group(3))) != (
        block["executed"], block["failures"], block["skipped"]
    ):
        fail(
            f"IMPLEMENTATION_STATUS 统计 ({match.group(1)}/{match.group(2)}/{match.group(3)}) "
            f"与 TEST_REPORT ({block['executed']}/{block['failures']}/{block['skipped']}) 不一致"
        )

    limitations = read(docs_dir / "KNOWN_LIMITATIONS.md")
    match = re.search(r"\*\*(\d+) 个测试，(\d+) 失败，(\d+) 跳过\*\*", limitations)
    if not match:
        fail("KNOWN_LIMITATIONS 缺少『N 个测试，F 失败，S 跳过』统计行")
    if (int(match.group(1)), int(match.group(2)), int(match.group(3))) != (
        block["executed"], block["failures"], block["skipped"]
    ):
        fail(
            f"KNOWN_LIMITATIONS 统计 ({match.group(1)}/{match.group(2)}/{match.group(3)}) "
            f"与 TEST_REPORT ({block['executed']}/{block['failures']}/{block['skipped']}) 不一致"
        )


def check_not_run_entries(report: str, block: dict) -> None:
    for entry in block.get("notRun", []):
        marked = any(
            entry in line and "NOT RUN" in line
            for line in report.splitlines()
        )
        if not marked:
            fail(f"未执行项『{entry}』未在 TEST_REPORT 中标记为 NOT RUN")


def check_commit_binding(block: dict, repo_root: Path, use_git: bool) -> None:
    commit = str(block["commit"])
    if not re.fullmatch(r"[0-9a-f]{7,40}", commit):
        fail(f"交付 Commit SHA 格式非法：{commit}")
    if not use_git:
        return
    result = subprocess.run(
        ["git", "-C", str(repo_root), "merge-base", "--is-ancestor", commit, "HEAD"],
        capture_output=True,
    )
    if result.returncode != 0:
        fail(f"交付 Commit {commit} 不是当前 HEAD 的祖先（报告绑定错误）")
    run = str(block["run"])
    if not run or not re.fullmatch(r"\d+", run):
        fail(f"CI Run ID 缺失或非法：{run!r}")
    if str(block.get("gate")) != "PASS":
        fail(f"门禁结果不是 PASS：{block.get('gate')!r}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parent.parent))
    parser.add_argument("--docs-dir", default=None)
    parser.add_argument("--no-git", action="store_true", help="跳过 commit 祖先校验（临时副本用）")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    docs_dir = Path(args.docs_dir).resolve() if args.docs_dir else repo_root / "Docs" / "Engineering"
    report = read(docs_dir / "TEST_REPORT.md")

    block = extract_report_block(report)
    check_other_docs(docs_dir, block)
    check_not_run_entries(report, block)
    check_commit_binding(block, repo_root, use_git=not args.no_git)

    print(
        "test-report check: PASS "
        f"(executed={block['executed']}, failures={block['failures']}, "
        f"skipped={block['skipped']}, commit={block['commit']}, run={block['run']})"
    )


if __name__ == "__main__":
    main()

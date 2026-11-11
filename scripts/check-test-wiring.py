#!/usr/bin/env python3
"""Fail when a test file is not run by any CI entry point (#1920).

24 Python modules and two gateway shell tests sat in the tree for months
without CI running them, and several had rotted. Python modules under
scripts/tests/test_*.py run through scripts/ci-python-test-shard.py, which
discovers them and splits them into PYTHON_TEST_SHARDS shards, so this checks
that the Makefile runs every shard. Every other test file (shell suites under
dist/test, scripts/test-*.sh, scripts/test-*.py, scripts/**/test-*.py,
scripts/ops/test-*.sh, ops/ suites, dist/test Python, and Node *.test.mjs /
test_*.mjs files) must be named by the Makefile, a workflow, or a test file
that is itself wired in, or be listed in UNWIRED with the reason it is not run.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHARD_RUNNER = "python3 scripts/ci-python-test-shard.py --shard {shard} --total $(PYTHON_TEST_SHARDS)"
SKIP_DIRS = {".git", "node_modules", ".build"}

# Test-shaped files that CI deliberately does not run. Each needs a reason; a
# listed file that disappears, or that becomes wired, fails the check so the
# list cannot go stale.
UNWIRED = {
    "phase4-coordinator/dist/test/canary_text_vnode_proof_test.py": (
        "obsolete: it extracts an inline proof from deploy-pearl-vps.sh that the "
        "script no longer contains (ValueError: substring not found)"
    ),
    "phase4-coordinator/internal/payout/testdata/eip712_js/test_digest.mjs": (
        "fixture generator: needs the ethers npm package; the Go payout tests "
        "check its committed output"
    ),
    "scripts/test-mlx-runtime-smoke.py": (
        "hardware smoke: starts a real macprovider-cli and loads models on a Mac"
    ),
    "scripts/test-phase3-tool-profiles.py": (
        "hardware probe: drives an isolated --no-join provider on the Studio"
    ),
    "scripts/tests/test-malibu-handoff-studio.py": (
        "Studio GUI acceptance: runs only on the designated Studio console user"
    ),
}


def _walk(pattern: str) -> set[pathlib.Path]:
    return {
        p for p in ROOT.glob(pattern)
        if p.is_file() and not SKIP_DIRS.intersection(p.relative_to(ROOT).parts)
    }


def candidates() -> list[str]:
    found: set[pathlib.Path] = set()
    found.update(_walk("scripts/test-*.sh"))
    found.update(_walk("scripts/test-*.py"))
    found.update(_walk("scripts/**/test-*.py"))
    found.update(_walk("scripts/ops/test-*.sh"))
    found.update(_walk("scripts/tests/*.sh"))
    found.update(_walk("*/dist/test/*.sh"))
    found.update(_walk("*/dist/test/*_test.py"))
    found.update(p for p in _walk("ops/**/test*") if p.suffix in {".sh", ".py"})
    found.update(_walk("ops/**/Scripts/test-*.sh"))
    found.update(_walk("**/*.test.mjs"))
    found.update(_walk("**/test_*.mjs"))
    found.update(_walk("**/test-*.mjs"))
    return sorted(str(p.relative_to(ROOT)) for p in found)


def code_lines(text: str) -> str:
    """Drop comment-only lines so a mention in prose does not count as a run."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def python_shard_errors(makefile: str) -> list[str]:
    match = re.search(r"^PYTHON_TEST_SHARDS\s*:=\s*(\d+)\s*$", makefile, re.MULTILINE)
    if not match or int(match.group(1)) < 1:
        return ["Makefile must set PYTHON_TEST_SHARDS to a positive shard count"]
    total = int(match.group(1))
    return [
        f"Makefile no longer runs `{SHARD_RUNNER.format(shard=shard)}`"
        for shard in range(1, total + 1)
        if SHARD_RUNNER.format(shard=shard) not in makefile
    ]


def main() -> int:
    makefile = code_lines((ROOT / "Makefile").read_text(encoding="utf-8"))
    roots = [makefile] + [
        code_lines(p.read_text(encoding="utf-8"))
        for p in sorted((ROOT / ".github" / "workflows").glob("*.yml"))
    ]
    errors = python_shard_errors(makefile)

    pending = candidates()
    wired: set[str] = set()
    sources = list(roots)
    # A test is wired when an entry point, or an already-wired test, names it.
    changed = True
    while changed:
        changed = False
        for path in pending:
            if path in wired:
                continue
            if any(path in text for text in sources):
                wired.add(path)
                sources.append(code_lines((ROOT / path).read_text(encoding="utf-8", errors="replace")))
                changed = True
    for path in pending:
        if path in wired and path in UNWIRED:
            errors.append(f"listed in UNWIRED but now wired, drop it from the list: {path}")
        elif path not in wired and path not in UNWIRED:
            errors.append(f"not run by any Makefile target or workflow: {path}")
    errors.extend(f"UNWIRED entry no longer exists: {p}" for p in sorted(set(UNWIRED) - set(pending)))

    for error in errors:
        print(f"[check-test-wiring] {error}", file=sys.stderr)
    if errors:
        return 1
    print(
        f"[check-test-wiring] ok: {len(wired)} test files wired, {len(UNWIRED)} listed unwired; "
        "scripts/tests Python via ci-python-test-shard.py"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

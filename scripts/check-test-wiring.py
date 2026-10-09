#!/usr/bin/env python3
"""Fail when a test file is not run by any CI entry point (#1920).

24 Python modules and two gateway shell tests sat in the tree for months
without CI running them, and several had rotted. Python modules under
scripts/tests/ run through `unittest discover` in `make test-dist-python`, so
this checks that the discover line is still there. Every other test file
(shell suites under dist/test, scripts/test-*.sh, scripts/ops/test-*.sh, and
ops/ Python suites) must be named by the Makefile, a workflow, or a test file
that is itself wired in.
"""

from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DISCOVER = "python3 -m unittest discover -s scripts/tests -t . -p 'test_*.py'"


def candidates() -> list[str]:
    found: set[pathlib.Path] = set()
    found.update(ROOT.glob("scripts/test-*.sh"))
    found.update(ROOT.glob("scripts/ops/test-*.sh"))
    found.update(ROOT.glob("scripts/tests/*.sh"))
    found.update(ROOT.glob("*/dist/test/*.sh"))
    found.update(p for p in ROOT.glob("ops/**/test*") if p.suffix in {".sh", ".py"})
    found.update(p for p in ROOT.glob("ops/**/Scripts/test-*.sh"))
    return sorted(str(p.relative_to(ROOT)) for p in found if p.is_file())


def code_lines(text: str) -> str:
    """Drop comment-only lines so a mention in prose does not count as a run."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def main() -> int:
    makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
    roots = [code_lines(makefile)] + [
        code_lines(p.read_text(encoding="utf-8"))
        for p in sorted((ROOT / ".github" / "workflows").glob("*.yml"))
    ]
    errors: list[str] = []
    if DISCOVER not in roots[0]:
        errors.append(f"Makefile no longer runs `{DISCOVER}`")

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
    errors.extend(f"not run by any Makefile target or workflow: {p}" for p in pending if p not in wired)

    for error in errors:
        print(f"[check-test-wiring] {error}", file=sys.stderr)
    if errors:
        return 1
    print(f"[check-test-wiring] ok: {len(wired)} test files wired; scripts/tests Python via discover")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

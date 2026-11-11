#!/usr/bin/env python3
"""Run one deterministic shard of the scripts/tests Python suite.

`unittest discover -s scripts/tests -t . -p 'test_*.py'` ran every module
serially in one CI job. This runs the same discovery, assigns each discovered
module to a shard by a stable hash of its dotted name, and runs only this
shard's modules. A new module lands in a shard with no wiring change; the
hash keeps existing assignments stable when modules are added or removed.

--list prints the assignment for every shard and checks that each discovered
module is in exactly one shard.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
START = "scripts/tests"
PATTERN = "test_*.py"


def leaf_tests(suite: unittest.TestSuite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from leaf_tests(item)
        else:
            yield item


def module_of(test: unittest.TestCase) -> str:
    # A module that fails to import becomes a _FailedTest whose method name is
    # the module; keep it so the failure is reported in that module's shard.
    if type(test).__module__ == "unittest.loader":
        return test._testMethodName
    return type(test).__module__


def module_suites(suite: unittest.TestSuite) -> dict[str, unittest.TestSuite]:
    """Group discovered tests by module, keeping discovery order."""
    groups: dict[str, unittest.TestSuite] = {}
    for test in leaf_tests(suite):
        groups.setdefault(module_of(test), unittest.TestSuite()).addTest(test)
    return groups


def shard_of(module: str, total: int) -> int:
    digest = hashlib.sha256(module.encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big") % total + 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shard", type=int, help="1-based shard to run")
    parser.add_argument("--total", type=int, required=True, help="number of shards")
    parser.add_argument("--list", action="store_true", help="print the assignment and exit")
    args = parser.parse_args(argv)
    if args.total < 1 or (not args.list and not (args.shard and 1 <= args.shard <= args.total)):
        parser.error("--shard must be between 1 and --total")

    sys.path.insert(0, str(ROOT))
    loader = unittest.TestLoader()
    groups = module_suites(loader.discover(str(ROOT / START), pattern=PATTERN, top_level_dir=str(ROOT)))
    if not groups:
        print(f"[python-shard] discovery under {START} found no tests", file=sys.stderr)
        return 1
    assignment = {module: shard_of(module, args.total) for module in sorted(groups)}

    if args.list:
        for shard in range(1, args.total + 1):
            modules = [m for m, s in assignment.items() if s == shard]
            tests = sum(groups[m].countTestCases() for m in modules)
            print(f"shard {shard}/{args.total}: {len(modules)} modules, {tests} tests")
            for module in modules:
                print(f"  {module}")
        return 0

    mine = [module for module, shard in assignment.items() if shard == args.shard]
    suite = unittest.TestSuite(groups[module] for module in mine)
    print(
        f"[python-shard] shard {args.shard}/{args.total}: {len(mine)} of {len(groups)} modules, "
        f"{suite.countTestCases()} tests",
        flush=True,
    )
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())

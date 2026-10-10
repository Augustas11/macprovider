#!/usr/bin/env python3
"""Run one deterministic shard of the phase3-binary XCTest suite in CI.

Usage (from phase3-binary/, after `swift build --build-tests`):
    python3 ../scripts/ci-swift-test-shard.py --shard 1 --total 4

Every shard lists the same tests from the same build, partitions whole test
classes across all shards (greedy by test count, ties broken by name), and
fails before running anything unless the partition assigns every listed test
to exactly one shard. After the run it fails unless the xUnit report contains
exactly this shard's tests, so a filter that silently matches too few (or
too many) tests cannot pass.
"""

import argparse
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


def list_tests():
    out = subprocess.run(
        ["swift", "test", "list", "--skip-build"],
        check=True, capture_output=True, text=True,
    ).stdout
    tests = [line.strip() for line in out.splitlines() if line.strip()]
    bad = [t for t in tests if "/" not in t or "." not in t.split("/", 1)[0]]
    if bad:
        sys.exit("unexpected `swift test list` lines: %r" % bad[:5])
    if len(set(tests)) != len(tests):
        sys.exit("`swift test list` returned duplicate test identifiers")
    return tests


def partition(tests, total):
    by_class = {}
    for t in tests:
        by_class.setdefault(t.split("/", 1)[0], []).append(t)
    shards = [[] for _ in range(total)]
    loads = [0] * total
    for cls in sorted(by_class, key=lambda c: (-len(by_class[c]), c)):
        i = min(range(total), key=lambda k: (loads[k], k))
        shards[i].append(cls)
        loads[i] += len(by_class[cls])
    return by_class, shards


def verify_partition(tests, by_class, shards):
    assigned = [c for shard in shards for c in shard]
    if len(assigned) != len(set(assigned)):
        sys.exit("partition assigns a test class to more than one shard")
    if set(assigned) != set(by_class):
        missing = sorted(set(by_class) - set(assigned))
        sys.exit("partition leaves test classes unassigned: %r" % missing)
    covered = sorted(t for c in assigned for t in by_class[c])
    if covered != sorted(tests):
        sys.exit("partition does not cover every listed test exactly once")
    if any(not shard for shard in shards):
        sys.exit("a shard has no test classes; lower --total")


def ran_tests(xunit_path):
    ran = []
    for case in ET.parse(xunit_path).getroot().iter("testcase"):
        ran.append("%s/%s" % (case.get("classname"), case.get("name")))
    return ran


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shard", type=int, required=True, help="1-based")
    ap.add_argument("--total", type=int, required=True)
    ap.add_argument("--xunit", default=".build/shard-xunit.xml")
    args = ap.parse_args()
    if not 1 <= args.shard <= args.total:
        sys.exit("--shard must be in 1..--total")

    tests = list_tests()
    by_class, shards = partition(tests, args.total)
    verify_partition(tests, by_class, shards)
    for n, shard in enumerate(shards, 1):
        print("shard %d/%d: %d classes, %d tests" % (
            n, args.total, len(shard), sum(len(by_class[c]) for c in shard)))

    mine = shards[args.shard - 1]
    expected = sorted(t for c in mine for t in by_class[c])
    print("running shard %d classes:\n  %s" % (args.shard, "\n  ".join(mine)))
    pattern = "^(?:%s)/" % "|".join(re.escape(c) for c in mine)

    if os.path.exists(args.xunit):
        os.remove(args.xunit)
    rc = subprocess.run([
        "swift", "test", "--skip-build", "--parallel",
        "--filter", pattern, "--xunit-output", args.xunit,
    ]).returncode
    if rc != 0:
        return rc

    ran = sorted(ran_tests(args.xunit))
    if ran != expected:
        extra = sorted(set(ran) - set(expected))
        missing = sorted(set(expected) - set(ran))
        sys.exit("shard %d ran %d tests, expected %d; missing=%r extra=%r" % (
            args.shard, len(ran), len(expected), missing[:10], extra[:10]))
    print("shard %d ran exactly its %d tests" % (args.shard, len(expected)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

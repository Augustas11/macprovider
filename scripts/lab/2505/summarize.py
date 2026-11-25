"""One-line summary of an msb-throughput JSON report for the #2505 job log.

Prints every scalar leaf whose key names a verdict, a throughput or a parity count
(pass, tps, tok/s, aggregate, serial, speedup, mismatch, identical, first divergence),
as `path=value`, so the window log shows the goal numbers without opening the files.
Usage: python3 -I summarize.py REPORT.json
"""

import json
import re
import sys

WANTED = re.compile(r"pass|match|tps|tokens_per_s|aggregate|serial|speedup|ratio|mismatch|identical|diverg|error", re.I)


def leaves(node, path=""):
    if isinstance(node, dict):
        for key, value in node.items():
            yield from leaves(value, f"{path}.{key}" if path else key)
    elif isinstance(node, list):
        if len(node) <= 8:
            for index, value in enumerate(node):
                yield from leaves(value, f"{path}[{index}]")
    elif isinstance(node, (int, float, str, bool)) or node is None:
        yield path, node


def main():
    try:
        report = json.load(open(sys.argv[1]))
    except (OSError, ValueError) as error:
        print(f"no report ({error.__class__.__name__})")
        return
    out = []
    for path, value in leaves(report):
        last = re.split(r"[.\[]", path)[-1]
        if WANTED.search(last) and not isinstance(value, str) or (isinstance(value, str) and WANTED.search(last) and len(value) < 80):
            out.append(f"{path}={round(value, 2) if isinstance(value, float) else value}")
    print(" ".join(out[:40]) or "no matching keys")


if __name__ == "__main__":
    main()

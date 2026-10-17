#!/usr/bin/env python3
"""Re-derive journey step-05 aligned pairs from a leg-6 cbtrace log, CPU only.

The state digests are not in the log, but the pairing is: a native row's
rounds (`native_round phase=finalize rows=<id>:...`) in commit order, each
round's committed token advance (its `sch_active` lines: 2 for an accepted
depth-1 round, 1 for a rejected one), and the ordinary run's decode-window
ends (`hop_decode rows=1 steps=N` after its prefill). A native round is
compared when its committed KV count equals a window end; it follows a
rejection (SPEC-048 0.1.46 MTP-6) when the immediately preceding round of
the same row advanced one token. The run's JSON says whether every compared
pair was equal; this script only recounts the pairs.

Usage: step05_following_rejection.py mtp-journey.log[.gz]
"""
from __future__ import annotations

import gzip
import re
import sys

ROWS = ["journey-reject-all-0", "journey-boundary-0", "journey-boundary-1"]


def read_lines(path: str) -> list[str]:
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8", errors="replace") as handle:
        return handle.read().splitlines()


def submissions(lines: list[str], rid: str) -> list[int]:
    return [i for i, line in enumerate(lines) if f"rid={rid} ev=sch_submit" in line]


def ordinary_window_ends(lines: list[str], rid: str) -> set[int]:
    first, second = submissions(lines, rid)[:2]
    kv, ends = None, set()
    for line in lines[first:second]:
        if kv is None and "ev=hop_prefill" in line:
            kv = int(re.search(r"tokens=(\d+)", line).group(1))
        match = re.search(r"ev=hop_decode rows=1 steps=(\d+)", line)
        if match and kv is not None:
            kv += int(match.group(1))
            ends.add(kv)
    return ends


def native_rounds(lines: list[str], rid: str) -> tuple[int, list[int]]:
    start = submissions(lines, rid)[1]
    prompt, rounds = None, []
    for line in lines[start:]:
        if prompt is None and "ev=hop_prefill" in line:
            prompt = int(re.search(r"tokens=(\d+)", line).group(1))
        if f"native_round phase=finalize rows={rid}:" in line:
            rounds.append(0)
        elif f"rid={rid} ev=sch_active" in line and rounds:
            rounds[-1] += 1
        if f"rid={rid} ev=sch_complete" in line:
            break
    return prompt, rounds


def main() -> int:
    lines = read_lines(sys.argv[1])
    for rid in ROWS:
        prompt, advances = native_rounds(lines, rid)
        ends = ordinary_window_ends(lines, rid)
        kv, counts = prompt, []
        for advance in advances:
            kv += advance
            counts.append(kv)
        comparable = [end for end in ends if counts[0] <= end <= counts[-1]]
        pairs = [i for i, tokens in enumerate(counts) if tokens in ends]
        own_rejected = sum(1 for i in pairs if advances[i] == 1)
        following = sum(1 for i in pairs if i > 0 and advances[i - 1] == 1)
        print(f"{rid} rounds={len(advances)} comparable={len(comparable)} pairs={len(pairs)} "
              f"own_round_rejected={own_rejected} following_rejection={following}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

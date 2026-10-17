#!/usr/bin/env python3
"""Re-derive journey step-05 aligned pairs from a leg-6 cbtrace log, CPU only.

The state digests are not in the log, but the pairing is: a native row's
rounds (`native_round phase=finalize rows=<id>:...`) in commit order, each
round's committed token advance (its `sch_active` lines: 2 for an accepted
depth-1 round, 1 for a rejected one), and the ordinary run's decode-window
ends (`hop_decode rows=1 steps=N` after its prefill). A native round is
compared when its committed KV count equals a window end; it follows a
rejection (SPEC-048 0.1.46 MTP-6) when the immediately preceding round of
the same row advanced one token. The rounds come from the complete
`native_round phase=finalize` trace sequence (every committing finalize logs
one line before it runs), not from observer records. The run's JSON says
whether every compared pair was equal; this script only recounts the pairs.
Truncated or unexpected input exits non-zero with an explicit reason.

Usage: step05_following_rejection.py mtp-journey.log[.gz]
"""
from __future__ import annotations

class TraceError(Exception):
    pass

import gzip
import re
import sys

ROWS = ["journey-reject-all-0", "journey-boundary-0", "journey-boundary-1"]


def read_lines(path: str) -> list[str]:
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8", errors="replace") as handle:
        return handle.read().splitlines()


def submissions(lines: list[str], rid: str) -> list[int]:
    found = [i for i, line in enumerate(lines) if f"rid={rid} ev=sch_submit" in line]
    if len(found) < 2:
        raise TraceError(f"{rid}: expected an ordinary and a native submission, found {len(found)}")
    return found


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
    if kv is None or not ends:
        raise TraceError(f"{rid}: ordinary run has no prefill or no decode window")
    return ends


def native_rounds(lines: list[str], rid: str) -> tuple[int, list[int]]:
    start = submissions(lines, rid)[1]
    prompt, rounds, completed = None, [], False
    for line in lines[start:]:
        if prompt is None and "ev=hop_prefill" in line:
            prompt = int(re.search(r"tokens=(\d+)", line).group(1))
        finalize = re.search(r"native_round phase=finalize rows=(\S+)", line)
        entries = dict(entry.rsplit(":", 1) for entry in finalize.group(1).split(",")) if finalize else {}
        if entries.get(rid) == "false":
            raise TraceError(f"{rid}: an aborted (non-committing) native round is not supported")
        if entries.get(rid) == "true":
            rounds.append(0)
        elif f"rid={rid} ev=sch_active" in line and rounds:
            rounds[-1] += 1
        if f"rid={rid} ev=sch_complete" in line:
            completed = True
            break
    if prompt is None or not rounds or not completed:
        raise TraceError(f"{rid}: native run truncated (prefill={prompt is not None}, rounds={len(rounds)}, completed={completed})")
    if any(advance not in (1, 2) for advance in rounds):
        raise TraceError(f"{rid}: a round advanced {sorted(set(rounds))} tokens; depth 1 commits 1 or 2")
    return prompt, rounds


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        return report(read_lines(sys.argv[1]))
    except (OSError, TraceError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


def report(lines: list[str]) -> int:
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

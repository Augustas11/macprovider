#!/usr/bin/env python3
"""#2467: tie-aware Swift-vs-mlx-vlm parity gate for the uncensored Inkling-2-Mini row.

A spliced row may differ from the oracle only where the oracle itself is nearly undecided.
Per row (prompt length) it passes when
  - every mismatching step is a near-tie: the port's token is within TIE logit of the
    oracle's top-1, measured in the oracle's own logits (oracle-<len>.safetensors);
  - at most MAX_MISMATCHES steps mismatch;
  - meanKL is at most KL_RATIO x the base control's meanKL at the same length.
The base control must stay exact (every step matches).

The parity JSON records the port's chosen token nowhere, so the port's token stream is read
from the XCTAssertEqual failure the exact-mode Swift test prints in its log ("greedy tokens at
prompt length N"). A mismatching row whose stream is not in the log cannot be checked and FAILs,
as does any test error other than that assertion. Stdlib only: logits are read by byte range
from the safetensors file, one row per mismatch.

Prints one `PARITY_GATE row=<len> mismatches=<n> worst_margin=<x> kl_ratio=<y> PASS|FAIL` per
row and exits 1 if any row fails.
"""
from __future__ import annotations

import argparse
import json
import re
import struct
import sys
from array import array
from pathlib import Path

TIE = 0.25
MAX_MISMATCHES = 2
KL_RATIO = 1.25
ASSERT_RE = re.compile(
    r'XCTAssertEqual failed: \("\[([0-9, ]*)\]"\) is not equal to \("\[([0-9, ]*)\]"\)'
    r" - greedy tokens at prompt length (\d+)")


def _header(path: Path):
    with open(path, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        return json.loads(f.read(n)), 8 + n


def oracle_greedy(path: Path) -> list[int]:
    header, base = _header(path)
    meta = header["greedy"]
    width = {"I32": 4, "I64": 8}[meta["dtype"]]
    lo, hi = meta["data_offsets"]
    with open(path, "rb") as f:
        f.seek(base + lo)
        raw = f.read(hi - lo)
    return [int.from_bytes(raw[i:i + width], "little", signed=True) for i in range(0, len(raw), width)]


def oracle_row(path: Path, step: int) -> array:
    header, base = _header(path)
    meta = header["logits"]
    if meta["dtype"] != "F32":
        raise ValueError(f"oracle logits dtype {meta['dtype']} is not F32")
    steps, vocab = meta["shape"]
    if not 0 <= step < steps:
        raise ValueError(f"step {step} outside the oracle's {steps} steps")
    with open(path, "rb") as f:
        f.seek(base + meta["data_offsets"][0] + step * vocab * 4)
        row = array("f")
        row.frombytes(f.read(vocab * 4))
    if sys.byteorder != "little":
        row.byteswap()
    return row


def log_streams(log_text: str) -> dict[int, tuple[list[int], list[int]]]:
    out = {}
    for port, ref, length in ASSERT_RE.findall(log_text):
        out[int(length)] = ([int(x) for x in port.split(",")], [int(x) for x in ref.split(",")])
    return out


def other_errors(log_text: str) -> list[str]:
    return [ln.strip()[:200] for ln in log_text.splitlines()
            if "error:" in ln and "greedy tokens at prompt length" not in ln]


def gate(report, base_report, streams, oracle_dir: Path, errors, tie=TIE, max_mismatches=MAX_MISMATCHES,
         kl_ratio=KL_RATIO):
    """Returns [(line, passed)] one per uncensored row."""
    base = {r["length"]: r for r in base_report}
    results = []
    for r in sorted(report, key=lambda r: r["length"]):
        length, steps, matching = r["length"], r["steps"], r["matchingTokens"]
        mismatches = steps - matching
        why = []
        margins = []
        ref = base.get(length)
        if ref is None or ref["meanKL"] <= 0:
            ratio = float("nan")
            why.append("no base control meanKL at this length")
        else:
            ratio = r["meanKL"] / ref["meanKL"]
            if ref["matchingTokens"] != ref["steps"]:
                why.append(f"base control not exact {ref['matchingTokens']}/{ref['steps']}")
        if ratio == ratio and ratio > kl_ratio:
            why.append(f"kl_ratio {ratio:.3f} > {kl_ratio}")
        if mismatches > max_mismatches or matching < steps - max_mismatches:
            why.append(f"{mismatches} mismatches > {max_mismatches}")
        if steps <= 0:
            why.append("no steps")
        if (r["path"], r["layout"]) != ("compiled", "oq"):
            why.append(f"path {r['path']} layout {r['layout']}")
        if errors:
            why.append(f"test errors: {errors[0]}")
        if mismatches > 0:
            try:
                greedy = oracle_greedy(oracle_dir / f"oracle-{length}.safetensors")
                if length not in streams:
                    raise ValueError("port token stream not in the log")
                port, expected = streams[length]
                if expected != greedy or len(port) != steps:
                    raise ValueError("log streams do not match the oracle's greedy tokens")
                bad = [i for i in range(steps) if port[i] != greedy[i]]
                if len(bad) != mismatches:
                    raise ValueError(f"log shows {len(bad)} mismatches, report {mismatches}")
                for i in bad:
                    row = oracle_row(oracle_dir / f"oracle-{length}.safetensors", i)
                    margins.append(max(row) - row[port[i]])
            except (OSError, ValueError, KeyError) as exc:
                why.append(f"margin unverifiable: {exc}")
            worst = max(margins) if margins else float("nan")
            if margins and worst > tie:
                why.append(f"worst_margin {worst:.4f} > {tie}")
        else:
            worst = 0.0
        ok = not why
        line = (f"PARITY_GATE row={length} mismatches={mismatches} worst_margin={worst:.4f} "
                f"kl_ratio={ratio:.3f} {'PASS' if ok else 'FAIL'}")
        if why:
            line += " (" + "; ".join(why) + ")"
        results.append((line, ok))
    return results


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--report", required=True, type=Path, help="uncensored parity JSON")
    ap.add_argument("--log", required=True, type=Path, help="uncensored swift test log")
    ap.add_argument("--base-report", required=True, type=Path, help="base control parity JSON")
    ap.add_argument("--oracle-dir", required=True, type=Path, help="holds oracle-<len>.safetensors")
    ap.add_argument("--lengths", help="comma list the report must hold exactly")
    a = ap.parse_args(argv)
    try:
        report = json.loads(a.report.read_text())
        base_report = json.loads(a.base_report.read_text())
        log_text = a.log.read_text(errors="replace")
    except (OSError, ValueError) as exc:
        print(f"BLOCKER: parity gate inputs unreadable: {exc}")
        return 1
    if a.lengths and sorted(r["length"] for r in report) != sorted(int(x) for x in a.lengths.split(",")):
        print(f"BLOCKER: report lengths {sorted(r['length'] for r in report)} are not {a.lengths}")
        return 1
    results = gate(report, base_report, log_streams(log_text), a.oracle_dir, other_errors(log_text))
    for line, _ in results:
        print(line)
    return 0 if results and all(ok for _, ok in results) else 1


if __name__ == "__main__":
    sys.exit(main())

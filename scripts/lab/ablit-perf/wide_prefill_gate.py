#!/usr/bin/env python3
"""#2451 gate for GLM-5.3-Flash wide prefill: candidate build vs unmodified main on the batching route.

Inputs are three parity-grid provider runs from one Studio session, in run order: main (control A),
the candidate, main again (control B), plus the oMLX reference rows of the candidate pass.

Gate (exit 1 when any fails, 2 on unreadable input):
  - identity: every (cell, trial, row) of the candidate and of control B equals control A's trial-0
    row of that cell and prompt row in text, reasoning_text, completion_tokens and prompt_tokens; no
    errors; all three runs cover the same cells;
  - coverage: the runs hold at least one 512-output cell (the gate the issue names).
Reported, never gated: per cell the median TTFT of each run, the candidate's change against each
control, whether it beats both (AGENTS.md swarm rule 3: keep only a candidate that beats both
neighbouring controls), the oMLX median TTFT and the candidate's and main's ratio to it. The verdict
line is KEEP when the candidate beats both controls in every cell, else REVERT. With --noise-pct P
(> 0), KEEP when it beats both controls in at least one cell and every other cell is no more than
P% slower than either control (a change that only reaches some prompt lengths, #2474).
"""
import argparse
import json
import statistics
import sys


def read_jsonl(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def is_row(r):
    return r.get("kind", "row") == "row" and r.get("turn", 1) != 2


def cells(lines):
    out = {}
    for r in lines:
        if is_row(r):
            out.setdefault((r["ctx_target"], r["max_tokens"], r["rows"]), []).append(r)
    return out


def ref_cells(lines):
    out = {}
    for r in lines:
        if is_row(r) and not r.get("error"):
            out.setdefault((r["ctx_target"], r["max_tokens"]), []).append(r)
    return out


def median(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def signature(r):
    return (r.get("text", ""), r.get("reasoning_text", ""), r.get("completion_tokens"), r.get("prompt_tokens"))


def identity(base_rows, rows, label):
    """Reasons `rows` differ from `base_rows`' trial-0 row of each prompt row."""
    want, reasons = {}, []
    for r in sorted(base_rows, key=lambda r: (r["trial"], r["row"])):
        if r.get("error"):
            reasons.append(f"control A trial {r['trial']} row {r['row']}: error {str(r['error'])[:120]}")
        else:
            want.setdefault(r["row"], signature(r))
    for r in sorted(rows, key=lambda r: (r["trial"], r["row"])):
        where = f"{label} trial {r['trial']} row {r['row']}"
        if r.get("error"):
            reasons.append(f"{where}: error {str(r['error'])[:120]}")
            continue
        ref = want.get(r["row"])
        if ref is None:
            reasons.append(f"{where}: no control A row {r['row']}")
            continue
        got = signature(r)
        for name, a, b in zip(("text", "reasoning_text", "completion_tokens", "prompt_tokens"), got, ref):
            if a != b:
                reasons.append(f"{where}: {name} differs from control A"
                               + (f" ({a} vs {b})" if name.endswith("tokens") else ""))
    if not rows:
        reasons.append(f"{label}: no rows")
    return reasons


def change(a, b):
    return round(a / b - 1, 4) if a is not None and b else None


def evaluate(control_a, candidate, control_b, reference=None, noise_pct=0.0):
    a, c, b = cells(control_a), cells(candidate), cells(control_b)
    ref = ref_cells(reference or [])
    failures, rows = [], []
    keys = sorted(set(a) | set(c) | set(b))
    for key in keys:
        ctx, out, nrows = key
        name = f"ctx{ctx}|out{out}|rows{nrows}"
        missing = [label for label, runs in (("control A", a), ("candidate", c), ("control B", b)) if key not in runs]
        if missing:
            failures.append(f"{name}: missing from {', '.join(missing)}")
            continue
        reasons = identity(a[key], c[key], "candidate") + identity(a[key], b[key], "control B")
        failures += [f"{name}: {r}" for r in reasons]
        ttft = {label: median(r.get("ttft_s") for r in runs[key] if not r.get("error"))
                for label, runs in (("a", a), ("cand", c), ("b", b))}
        ref_ttft = median(r.get("ttft_s") for r in ref.get((ctx, out), []))
        main_ttft = median([ttft["a"], ttft["b"]])
        beats = (ttft["cand"] is not None and ttft["a"] is not None and ttft["b"] is not None
                 and ttft["cand"] < ttft["a"] and ttft["cand"] < ttft["b"])
        rows.append({
            "cell": name, "ctx": ctx, "out": out, "rows": nrows, "identical": not reasons,
            "prompt_tokens": median(r.get("prompt_tokens") for r in c[key]),
            "control_a_ttft_s": ttft["a"], "candidate_ttft_s": ttft["cand"], "control_b_ttft_s": ttft["b"],
            "change_vs_a": change(ttft["cand"], ttft["a"]), "change_vs_b": change(ttft["cand"], ttft["b"]),
            "beats_both_controls": beats, "within_noise": within_noise(ttft, noise_pct), "omlx_ttft_s": ref_ttft,
            "candidate_vs_omlx": change(ttft["cand"], ref_ttft), "main_vs_omlx": change(main_ttft, ref_ttft),
        })
    if not any(k[1] == 512 for k in keys):
        failures.append("no 512-output cell")
    if noise_pct > 0:
        keep = (rows and any(r["beats_both_controls"] for r in rows)
                and all(r["beats_both_controls"] or r["within_noise"] for r in rows))
    else:
        keep = rows and all(r["beats_both_controls"] for r in rows)
    verdict = "KEEP" if keep else "REVERT"
    return {"pass": not failures, "failures": failures, "cells": rows, "verdict": verdict,
            "noise_pct": noise_pct}


def within_noise(ttft, noise_pct):
    """The candidate is at most noise_pct% slower than each control (False when noise_pct <= 0)."""
    if noise_pct <= 0 or any(ttft[k] is None for k in ("a", "cand", "b")):
        return False
    bound = 1 + noise_pct / 100
    return ttft["cand"] <= ttft["a"] * bound and ttft["cand"] <= ttft["b"] * bound


def pct(x):
    return "-" if x is None else f"{x * 100:+.1f}%"


def sec(x):
    return "-" if x is None else f"{x:.3f}"


def markdown(result):
    lines = [
        "| ctx | out | prompt tok | main A ttft s | wide ttft s | main B ttft s | vs A | vs B | beats both "
        "| oMLX ttft s | wide vs oMLX | main vs oMLX | tokens identical |",
        "|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|---|",
    ]
    for r in result["cells"]:
        lines.append(
            f"| {r['ctx']} | {r['out']} | {r['prompt_tokens'] if r['prompt_tokens'] is not None else '-'} | "
            f"{sec(r['control_a_ttft_s'])} | {sec(r['candidate_ttft_s'])} | {sec(r['control_b_ttft_s'])} | "
            f"{pct(r['change_vs_a'])} | {pct(r['change_vs_b'])} | {'yes' if r['beats_both_controls'] else 'no'} | "
            f"{sec(r['omlx_ttft_s'])} | {pct(r['candidate_vs_omlx'])} | {pct(r['main_vs_omlx'])} | "
            f"{'yes' if r['identical'] else 'NO'} |")
    lines += ["", f"Gate: {'PASS' if result['pass'] else 'FAIL'}. Verdict: {result['verdict']}."]
    if result["failures"]:
        lines += ["", "Failures:"] + [f"- {f}" for f in result["failures"]]
    return "\n".join(lines) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--control-a", required=True)
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--control-b", required=True)
    ap.add_argument("--reference")
    ap.add_argument("--out-md", required=True)
    ap.add_argument("--out-json", required=True)
    ap.add_argument("--noise-pct", type=float, default=0.0,
                    help="KEEP band: cells that do not beat both controls may be this many percent slower")
    args = ap.parse_args(argv)
    try:
        runs = [read_jsonl(p) for p in (args.control_a, args.candidate, args.control_b)]
        reference = read_jsonl(args.reference) if args.reference else None
        if not all(runs):
            raise ValueError("an empty provider run")
        result = evaluate(*runs, reference=reference, noise_pct=args.noise_pct)
    except (OSError, ValueError, KeyError) as e:
        print(f"gate input error: {e}", file=sys.stderr)
        return 2
    with open(args.out_md, "w") as f:
        f.write(markdown(result))
    with open(args.out_json, "w") as f:
        json.dump(result, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"WIDE_GATE {'PASS' if result['pass'] else 'FAIL'} verdict={result['verdict']} "
          f"cells={len(result['cells'])} failures={len(result['failures'])}")
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())

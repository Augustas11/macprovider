#!/usr/bin/env python3
"""Flash-Next continuous-batching determinism gate (#2448). Stdlib only.

usage: cb_determinism.py fences --provider provider.jsonl --serve-err serve.err
       cb_determinism.py check --pass NAME=DIR [--pass NAME=DIR ...] --rows 4,8,11
                               [--out-json F] [--out-md F]

fences: every fenced trial of one pass (row records carrying `lab_fence`, provider_client.py
--lab-fence) must have exactly one `event=lab_request_fence installed=true` line in the serve's
stderr naming its fence (row 0's id). Prints `PASS_FENCE fenced=<n>/<n>`; exit 1 when a trial
was not fenced (the scheduler was not idle, or the serve is not a lab-harness build).

check: the gate. Each DIR is one pass of job-qwen4-cb.sh with LAB_FENCE=1 (its own serve
process, same build, model, route and knobs). For every (rows, context, output length, row)
with rows in --rows, all of that row's outputs across every trial of every pass must have
identical text and identical completion token counts, every row must have finished without
error, and every trial must have been fenced (`fences` on each pass). One
`DETERMINISM_CELL ...` line per (rows, context, output length) and one `DETERMINISM PASS|FAIL`
line; exit 0 on PASS, 1 on FAIL, 2 on unusable input.

What a PASS proves: with the request set of a cell admitted as one fixed composition (same rows,
same order, so the same admission waves and forward widths), the batched served path gives the
same greedy tokens for every row on every trial and in two serve processes. That is the
token-identity control the lab job needs: a later change to the batched path can be checked
for output changes by diffing against these rows.

What it does not prove: (1) equality with a row decoded alone (on the stock_order route a
3-16-row forward takes the batch kernel, whose rows may differ from the lone row in low bits;
SPEC-038 FR-CB6 bounds that difference to near ties, which the FR-CB10 self-check verdict
recorded by the job checks, not this gate); (2) determinism of production admission, where
rows join in waves set by arrival time (the issue's control runs differ there by design);
(3) anything about rows outside --rows or about the reference side.
"""
import argparse
import json
import pathlib
import re
import sys

FENCE_LINE = re.compile(r"event=lab_request_fence installed=(true|false) rows=(\d+) fence=(\S+)")


def rows_of(path):
    """Turn-1 provider row records of one provider.jsonl."""
    out = []
    with open(path) as f:
        for line in f:
            r = json.loads(line)
            if r.get("kind") == "row" and r.get("turn", 1) == 1:
                out.append(r)
    return out


def fence_installs(serve_err_text):
    """{fence id (row 0's request id): [installed flags]} from serve stderr."""
    out = {}
    for m in FENCE_LINE.finditer(serve_err_text):
        out.setdefault(m.group(3), []).append(m.group(1) == "true")
    return out


def fence_check(records, serve_err_text):
    """(fenced, total, problems) for one pass."""
    installs = fence_installs(serve_err_text)
    trials = {}
    for r in records:
        trials.setdefault((r["ctx_target"], r["max_tokens"], r["rows"], r["trial"]), []).append(r)
    problems, fenced = [], 0
    for key, rows in sorted(trials.items(), key=lambda kv: tuple(map(str, kv[0]))):
        ids = {r.get("row"): r.get("lab_fence") for r in rows}
        if any(v is None for v in ids.values()):
            problems.append(f"{key}: rows sent without a fence id")
            continue
        fence = ids.get(0)
        got = installs.get(fence, [])
        if got == [True]:
            fenced += 1
        else:
            problems.append(f"{key}: fence {fence} install lines {got or 'none'}")
    return fenced, len(trials), problems


def first_char_diff(a, b):
    n = min(len(a), len(b))
    i = next((j for j in range(n) if a[j] != b[j]), n)
    return None if i == n and len(a) == len(b) else i


def check(passes, gated_rows):
    """(cells, problems) over {pass name: (records, fence problems)}; module docstring."""
    problems = []
    outputs = {}
    for name, (records, fence_problems) in passes.items():
        problems += [f"{name}: {p}" for p in fence_problems]
        for r in records:
            if r["rows"] not in gated_rows:
                continue
            outputs.setdefault((r["rows"], r["ctx_target"], r["max_tokens"]), {}).setdefault(r["row"], []).append(
                {"pass": name, "trial": r["trial"], "text": r.get("text") or "", "tokens": r.get("completion_tokens"),
                 "error": r.get("error"), "finish": r.get("finish")})
    missing = sorted(set(gated_rows) - {k[0] for k in outputs})
    if missing:
        problems.append(f"no cells at rows {missing}")
    cells = []
    for (rows, ctx, out), by_row in sorted(outputs.items(), key=lambda kv: tuple(map(str, kv[0]))):
        identical, diffs = 0, []
        for row in range(rows):
            got = by_row.get(row, [])
            seen = {p for p in passes}
            if {g["pass"] for g in got} != seen:
                diffs.append({"row": row, "reason": "missing in a pass"})
                continue
            errs = [g for g in got if g["error"]]
            base = got[0]
            bad = [g for g in got[1:] if g["text"] != base["text"] or g["tokens"] != base["tokens"]]
            if errs:
                diffs.append({"row": row, "reason": "error", "error": str(errs[0]["error"])[:200]})
            elif bad:
                g = bad[0]
                diffs.append({"row": row, "reason": "differs", "variants": len({(x["text"], x["tokens"]) for x in got}),
                              "first": f"{base['pass']}/t{base['trial']}", "other": f"{g['pass']}/t{g['trial']}",
                              "first_char_diff": first_char_diff(base["text"], g["text"]),
                              "tokens": [base["tokens"], g["tokens"]]})
            else:
                identical += 1
        outputs_per_row = sorted({len(v) for v in by_row.values()})
        cells.append({"rows": rows, "ctx_target": ctx, "max_tokens": out, "rows_identical": identical,
                      "outputs_per_row": outputs_per_row, "diffs": diffs, "pass": not diffs})
        if diffs:
            problems.append(f"rows={rows} ctx={ctx} out={out}: {len(diffs)} of {rows} rows not identical")
    return cells, problems


def parse_rows(text):
    return sorted({int(x) for x in text.split(",") if x.strip()})


def cmd_fences(args):
    fenced, total, problems = fence_check(rows_of(args.provider), pathlib.Path(args.serve_err).read_text(errors="replace"))
    print(f"PASS_FENCE fenced={fenced}/{total}" + (" problems=" + "; ".join(problems[:5]) if problems else ""))
    return 0 if total and not problems else 1


def cmd_check(args):
    passes = {}
    for spec in args.passes:
        name, _, d = spec.partition("=")
        d = pathlib.Path(d)
        if not name or not (d / "provider.jsonl").is_file() or not (d / "serve" / "serve.err").is_file():
            print(f"DETERMINISM FAIL unusable pass {spec}: needs provider.jsonl and serve/serve.err")
            return 2
        records = rows_of(d / "provider.jsonl")
        _, _, fence_problems = fence_check(records, (d / "serve" / "serve.err").read_text(errors="replace"))
        passes[name] = (records, fence_problems)
    if len(passes) < 2:
        print("DETERMINISM FAIL needs at least two passes (two serve processes)")
        return 2
    cells, problems = check(passes, parse_rows(args.rows))
    for c in cells:
        print(f"DETERMINISM_CELL rows={c['rows']} ctx={c['ctx_target']} out={c['max_tokens']} "
              f"rows_identical={c['rows_identical']}/{c['rows']} outputs_per_row={c['outputs_per_row']} "
              f"{'PASS' if c['pass'] else 'FAIL ' + json.dumps(c['diffs'][:4])}")
    verdict = "PASS" if not problems else "FAIL " + "; ".join(problems[:6])
    print(f"DETERMINISM {verdict} passes={','.join(passes)} rows={args.rows}")
    if args.out_json:
        pathlib.Path(args.out_json).write_text(json.dumps({"passes": list(passes), "rows": parse_rows(args.rows),
                                                           "cells": cells, "problems": problems}, indent=2) + "\n")
    if args.out_md:
        lines = ["| rows | ctx | out | rows identical | outputs per row | verdict |", "|---:|---:|---:|---:|---|---|"]
        lines += [f"| {c['rows']} | {c['ctx_target']} | {c['max_tokens']} | {c['rows_identical']}/{c['rows']} "
                  f"| {c['outputs_per_row']} | {'PASS' if c['pass'] else 'FAIL'} |" for c in cells]
        pathlib.Path(args.out_md).write_text("\n".join(lines) + "\n\nDETERMINISM " + verdict + "\n")
    return 0 if not problems else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fences")
    f.add_argument("--provider", required=True)
    f.add_argument("--serve-err", required=True)
    c = sub.add_parser("check")
    c.add_argument("--pass", dest="passes", action="append", required=True)
    c.add_argument("--rows", required=True)
    c.add_argument("--out-json")
    c.add_argument("--out-md")
    args = ap.parse_args(argv)
    return cmd_fences(args) if args.cmd == "fences" else cmd_check(args)


if __name__ == "__main__":
    sys.exit(main())

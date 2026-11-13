#!/usr/bin/env python3
"""Compare provider results against the stock mlx-lm reference for the parity grid.

usage: compare.py --ref ref.jsonl --ours ours.jsonl [--floor 0.03] [--json summary.json]
                  [--text-fallback-reason "why byte identity cannot hold"]

Prints a markdown grid table, writes a JSON summary (stdout when --json is not
given, after the table), and exits 1 when any cell fails, 2 on unusable input.

Rules (see README.md):
  noise(xs)  = (max(xs) - min(xs)) / median(xs) over the trials of one side
  band       = max(floor, noise(ours), noise(ref))
  ratio      : FAIL when median(ours) < median(ref) * (1 - band)
  gate 1     : every row's text byte-identical to the single-row reference text
               of the same prompt; a mismatch FAILS unless --text-fallback-reason
               is given, then it is recorded (with the first differing byte
               offset and the reason) and only gate 2 decides
  gate 2     : every row's completion_tokens equals the reference's
  prompt     : prompt_tokens must match the reference (same template, same prompt)
  slope      : per (model, ctx, rows), for consecutive output lengths a < b:
               FAIL when ours(b)/ours(a) < ref(b)/ref(a) * (1 - band(a, b))
Multi-row cells score aggregate tok/s against the single-row reference
(serial stock mlx-lm); per-row tok/s ratios are reported, not gated.
"""
import argparse
import json
import statistics
import sys
from collections import defaultdict

# A band this wide means the trials were too noisy to judge the cell; reported as a note.
NOISY_BAND = 0.10


def read_jsonl(path):
    out = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except ValueError as exc:
                raise SystemExit(f"{path}:{n}: bad json: {exc}")
    return out


def noise(xs):
    xs = [x for x in xs if x is not None]
    if len(xs) < 2:
        return 0.0
    med = statistics.median(xs)
    return (max(xs) - min(xs)) / med if med > 0 else 0.0


def median(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def first_diff(a, b):
    """First differing byte offset between two strings (UTF-8), or None if equal."""
    ab, bb = a.encode(), b.encode()
    if ab == bb:
        return None
    for i, (x, y) in enumerate(zip(ab, bb)):
        if x != y:
            return i
    return min(len(ab), len(bb))


def index_reference(lines):
    ref = defaultdict(list)
    for r in lines:
        if r.get("kind", "row") != "row":
            continue
        ref[(r["model"], r["ctx_target"], r["max_tokens"], r["row"])].append(r)
    return ref


def index_ours(lines):
    rows = defaultdict(list)
    aggs = defaultdict(list)
    meta = {}
    for r in lines:
        key = (r["model"], r["ctx_target"], r["max_tokens"], r["rows"])
        meta[key] = r["cell"]
        if r.get("kind") == "aggregate":
            aggs[key].append(r)
        else:
            rows[key].append(r)
    return rows, aggs, meta


def ours_scores(rows, aggs, nrows):
    """Aggregate tok/s per trial."""
    if aggs:
        return [a.get("aggregate_tps") for a in sorted(aggs, key=lambda a: a["trial"])]
    if nrows == 1:
        return [r.get("decode_tps") for r in sorted(rows, key=lambda r: r["trial"])]
    return []


def evaluate(ref_lines, our_lines, floor=0.03, text_fallback_reason=None):
    ref = index_reference(ref_lines)
    ours_rows, ours_aggs, cells_meta = index_ours(our_lines)
    cells = {}

    for key in sorted(set(ours_rows) | set(ours_aggs)):
        model, ctx, out, nrows = key
        rows = ours_rows.get(key, [])
        cell = {
            "cell": cells_meta[key], "model": model, "ctx": ctx, "out": out, "rows": nrows,
            "reasons": [], "notes": [],
        }
        cells[key] = cell
        base = [r for r in ref.get((model, ctx, out, 0), []) if not r.get("error")]
        scores = ours_scores(rows, ours_aggs.get(key, []), nrows)
        ref_scores = [r.get("decode_tps") for r in base]
        cell["ours_trials"] = scores
        cell["ref_trials"] = ref_scores
        cell["ours_tps"] = median(scores)
        cell["ref_tps"] = median(ref_scores)
        cell["band"] = round(max(floor, noise(scores), noise(ref_scores)), 4)
        cell["ratio"] = None
        cell["ratio_ok"] = False
        if not base:
            cell["reasons"].append("missing reference for prompt row 0")
        elif cell["ours_tps"] is None or cell["ref_tps"] is None:
            cell["reasons"].append("no tok/s measured")
        else:
            cell["ratio"] = round(cell["ours_tps"] / cell["ref_tps"], 4)
            cell["ratio_ok"] = cell["ours_tps"] >= cell["ref_tps"] * (1 - cell["band"])
            if not cell["ratio_ok"]:
                cell["reasons"].append(
                    f"slow: ours {cell['ours_tps']:.2f} vs ref {cell['ref_tps']:.2f} tok/s "
                    f"(ratio {cell['ratio']:.3f} < {1 - cell['band']:.3f})")
        if cell["band"] > NOISY_BAND:
            cell["notes"].append(f"noisy cell: band {cell['band']:.3f} > {NOISY_BAND}; rerun before trusting the ratio")
        if len(set(r.get("sha256") or r.get("text") for r in base)) > 1:
            cell["notes"].append("reference trials disagree on text")

        # Per-row tok/s vs the single-row reference for the same prompt (reported).
        per_row = {}
        for r in rows:
            per_row.setdefault(r["row"], []).append(r.get("decode_tps"))
        cell["per_row_ratio"] = {}
        for prow, xs in sorted(per_row.items()):
            rref = median(x.get("decode_tps") for x in ref.get((model, ctx, out, prow), []))
            m = median(xs)
            cell["per_row_ratio"][str(prow)] = round(m / rref, 4) if m and rref else None
        if nrows > 1:
            cell["per_row_tps_median"] = {str(k): median(v) for k, v in sorted(per_row.items())}

        # Gates, row by row and trial by trial.
        text_ok = tokens_ok = prompt_ok = True
        cell["first_text_diff"] = None
        for r in sorted(rows, key=lambda r: (r["trial"], r["row"])):
            where = f"trial {r['trial']} row {r['row']}"
            if r.get("error"):
                cell["reasons"].append(f"{where}: error {r['error']}")
                tokens_ok = False
                continue
            rref = [x for x in ref.get((model, ctx, out, r["row"]), []) if not x.get("error")]
            if not rref:
                cell["reasons"].append(f"{where}: missing single-row reference for prompt row {r['row']}")
                text_ok = tokens_ok = False
                continue
            want = rref[0]
            if r.get("completion_tokens") != want.get("completion_tokens"):
                tokens_ok = False
                kind = "fewer" if (r.get("completion_tokens") or 0) < (want.get("completion_tokens") or 0) else "more"
                cell["reasons"].append(
                    f"{where}: {kind} tokens: ours {r.get('completion_tokens')} vs ref {want.get('completion_tokens')}")
            if r.get("prompt_tokens") != want.get("prompt_tokens"):
                prompt_ok = False
                cell["reasons"].append(
                    f"{where}: prompt_tokens ours {r.get('prompt_tokens')} vs ref {want.get('prompt_tokens')}")
            off = first_diff(r.get("text", ""), want.get("text", ""))
            if off is not None:
                text_ok = False
                if cell["first_text_diff"] is None:
                    cell["first_text_diff"] = {"trial": r["trial"], "row": r["row"], "byte_offset": off}
                if text_fallback_reason is None:
                    cell["reasons"].append(f"{where}: text differs from reference at byte {off}")
        if not text_ok and text_fallback_reason is not None and cell["first_text_diff"]:
            cell["text_gate"] = "fallback_token_count"
            cell["notes"].append(
                f"text differs at byte {cell['first_text_diff']['byte_offset']}; "
                f"gate falls back to token count: {text_fallback_reason}")
        else:
            cell["text_gate"] = "byte_identical" if text_ok else "fail"
        cell["tokens_ok"] = tokens_ok
        cell["prompt_ok"] = prompt_ok
        cell["slope_ok"] = True

    # Reference rows=1 cells with no provider result.
    for (model, ctx, out, prow) in ref:
        if prow == 0 and (model, ctx, out, 1) not in cells:
            cells[(model, ctx, out, 1)] = {
                "cell": f"{model}|ctx{ctx}|out{out}|rows1", "model": model, "ctx": ctx, "out": out,
                "rows": 1, "reasons": ["missing provider result"], "notes": [], "ratio": None,
                "ratio_ok": False, "ours_tps": None, "ref_tps": median(x.get("decode_tps") for x in ref[(model, ctx, out, 0)]),
                "band": None, "text_gate": "fail", "tokens_ok": False, "prompt_ok": False, "slope_ok": True,
            }

    # Slope: tok/s must not fall with output length beyond the noise band,
    # measured against how the reference itself falls.
    slopes = []
    series = defaultdict(list)
    for key, cell in cells.items():
        if cell["ours_tps"] is not None:
            series[(key[0], key[1], key[3])].append(cell)
    for (model, ctx, nrows), group in sorted(series.items()):
        group.sort(key=lambda c: c["out"])
        for a, b in zip(group, group[1:]):
            ours_step = b["ours_tps"] / a["ours_tps"]
            ref_step = (b["ref_tps"] / a["ref_tps"]) if a.get("ref_tps") and b.get("ref_tps") else 1.0
            band = max(floor, noise(a.get("ours_trials", [])), noise(b.get("ours_trials", [])),
                       noise(a.get("ref_trials", [])), noise(b.get("ref_trials", [])))
            ok = ours_step >= ref_step * (1 - band)
            slopes.append({
                "model": model, "ctx": ctx, "rows": nrows, "from_out": a["out"], "to_out": b["out"],
                "ours_step": round(ours_step, 4), "ref_step": round(ref_step, 4),
                "band": round(band, 4), "ok": ok,
            })
            if not ok:
                b["slope_ok"] = False
                b["reasons"].append(
                    f"slope: tok/s {a['ours_tps']:.2f} -> {b['ours_tps']:.2f} from out {a['out']} to {b['out']} "
                    f"(step {ours_step:.3f} < ref step {ref_step:.3f} * {1 - band:.3f})")

    result_cells = []
    for key in sorted(cells):
        c = cells[key]
        c["pass"] = not c["reasons"]
        result_cells.append(c)
    failing = [c for c in result_cells if not c["pass"]]
    return {
        "floor": floor,
        "text_fallback_reason": text_fallback_reason,
        "cells": result_cells,
        "slopes": slopes,
        "failing": [{"cell": c["cell"], "reasons": c["reasons"]} for c in failing],
        "pass": not failing,
    }


def fmt(x, spec=".2f"):
    return "-" if x is None else format(x, spec)


def markdown(summary):
    lines = [
        "| model | ctx | out | rows | ref tok/s | ours tok/s | ratio | band | text | tokens | slope | status |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|---|",
    ]
    for c in summary["cells"]:
        lines.append(
            f"| {c['model']} | {c['ctx']} | {c['out']} | {c['rows']} | {fmt(c['ref_tps'])} | "
            f"{fmt(c['ours_tps'])} | {fmt(c['ratio'], '.3f')} | {fmt(c['band'], '.3f')} | "
            f"{c['text_gate']} | {'ok' if c['tokens_ok'] else 'FAIL'} | "
            f"{'ok' if c['slope_ok'] else 'FAIL'} | {'PASS' if c['pass'] else 'FAIL'} |")
    if summary["failing"]:
        lines.append("")
        lines.append("Failing cells:")
        for f in summary["failing"]:
            for reason in f["reasons"]:
                lines.append(f"- {f['cell']}: {reason}")
    notes = [(c["cell"], n) for c in summary["cells"] for n in c["notes"]]
    if notes:
        lines.append("")
        lines.append("Notes:")
        lines.extend(f"- {cell}: {n}" for cell, n in notes)
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ref", required=True)
    ap.add_argument("--ours", required=True)
    ap.add_argument("--floor", type=float, default=0.03)
    ap.add_argument("--json")
    ap.add_argument("--text-fallback-reason")
    args = ap.parse_args(argv)
    ref_lines = read_jsonl(args.ref)
    our_lines = read_jsonl(args.ours)
    if not ref_lines or not our_lines:
        print("empty input", file=sys.stderr)
        return 2
    summary = evaluate(ref_lines, our_lines, args.floor, args.text_fallback_reason)
    print(markdown(summary))
    payload = json.dumps(summary, indent=2, sort_keys=True)
    if args.json:
        with open(args.json, "w") as f:
            f.write(payload + "\n")
    else:
        print()
        print(payload)
    return 0 if summary["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())

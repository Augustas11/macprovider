#!/usr/bin/env python3
"""Compare provider results against the stock mlx-lm reference for the parity grid.

usage: compare.py --ref ref.jsonl --ours ours.jsonl [--floor 0.03] [--json summary.json]
                  [--text-fallback-reason "why byte identity cannot hold"]
                  [--margins margins.json] [--tie-steps 2]
       compare.py --baseline main-provider.jsonl --ours candidate-provider.jsonl
                  [--subset] [--floor 0.03] [--json summary.json]

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
  tie        : with --margins (margin.py --json), a differing row whose first
               differing byte falls in a margins record of the same ctx
               (record.common_prefix_bytes <= offset <= + diff_span_bytes) and
               whose margin_steps <= --tie-steps is status `tie`, not a failure;
               its token count may then differ too (the text branched at a
               rounding tie), so the token check is skipped for that row. Only
               prompt row 0 is covered; other rows and uncovered diffs FAIL.
  reasoning  : a row with reasoning_text and empty content has text status
               `not_comparable` (no gate); speed and token count still apply
  gate 2     : every row's completion_tokens equals the reference's
  prompt     : prompt_tokens must match the reference (same template, same prompt)
  slope      : per (model, ctx, rows), for consecutive output lengths a < b:
               FAIL when ours(b)/ours(a) < ref(b)/ref(a) * (1 - band(a, b))
Reference cells the provider run never produced are listed as "not run" and
excluded from pass/fail; provider cells without a reference still FAIL.
Multi-row cells score aggregate tok/s against the single-row reference
(serial stock mlx-lm); per-row tok/s ratios are reported, not gated.

Reported, never gated: request-level output tok/s (request_tps =
completion_tokens / (last token time - request start); a multi-row cell sums
it over its concurrent rows) with its ratio to the reference, and median TTFT
on both sides.

--baseline mode compares two provider runs (a candidate build against the
main build): every (cell, trial, row) of the candidate must equal the
baseline's trial-0 row of the same cell and prompt row in text,
reasoning_text and completion_tokens; any difference, error or missing cell
exits 1 (--subset: baseline cells the candidate did not run are listed, not
failed). It prints per cell the request tok/s, decode tok/s and TTFT
medians, the request tok/s delta against the baseline and both runs' trial
spread (noise), without gating on speed.
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


def ours_request_scores(rows, aggs, nrows):
    """Request-level output tok/s per trial: the row's, or the sum over concurrent rows."""
    if nrows == 1:
        return [r.get("request_tps") for r in sorted(rows, key=lambda r: r["trial"])]
    by_trial = defaultdict(list)
    for r in rows:
        by_trial[r["trial"]].append(r.get("request_tps"))
    sums = {a["trial"]: a.get("request_tps_sum") for a in aggs}
    out = []
    for trial in sorted(by_trial):
        xs = by_trial[trial]
        fallback = round(sum(xs), 3) if len(xs) == nrows and None not in xs else None
        out.append(sums.get(trial) if sums.get(trial) is not None else fallback)
    return out


def ours_scores(rows, aggs, nrows):
    """Aggregate tok/s per trial."""
    if aggs:
        return [a.get("aggregate_tps") for a in sorted(aggs, key=lambda a: a["trial"])]
    if nrows == 1:
        return [r.get("decode_tps") for r in sorted(rows, key=lambda r: r["trial"])]
    return []


def load_margins(path):
    """Records from a margin.py --json file ({"records": [...]})."""
    with open(path) as f:
        data = json.load(f)
    recs = data.get("records") if isinstance(data, dict) else data
    if not isinstance(recs, list):
        raise SystemExit(f"{path}: expected a records list")
    return recs


def match_margin(margins, ctx, offset):
    """Margins record covering a mismatch at byte `offset` of context `ctx`, or None.

    Rule: same ctx_target and common_prefix_bytes <= offset <=
    common_prefix_bytes + diff_span_bytes. The first differing byte of two
    texts lies inside the first differing token, so it falls in that window;
    longer outputs sharing the prefix therefore map to the same record. When
    windows overlap the record with the largest common_prefix_bytes wins.
    """
    best = None
    for rec in margins or []:
        if rec.get("ctx_target") != ctx:
            continue
        start = rec.get("common_prefix_bytes")
        if start is None or not (start <= offset <= start + rec.get("diff_span_bytes", 0)):
            continue
        if best is None or start > best["common_prefix_bytes"]:
            best = rec
    return best


def is_turn2(r):
    return r.get("turn") == 2


def evaluate_turn2(ref_lines, our_lines):
    """Turn-2 section: TTFT and cached prompt tokens of the turn-2 requests, ours vs reference.

    Per (model, ctx, out, rows) cell with turn-2 rows from the provider: median TTFT of its rows
    and trials, the median reference TTFT of the same prompt rows, their ratio (ours / ref), and
    the median and minimum cached_prompt_tokens on each side. The cell FAILS when ours reports
    no cached tokens (0 or missing) on any turn-2 row or a turn-2 request errored. A reference
    that reports no cached tokens (None: in-process mlx-lm keeps no prefix cache) is "unknown",
    never a failure. TTFT is reported, not gated.
    """
    ours = defaultdict(list)
    for r in our_lines:
        if r.get("kind", "row") == "row" and is_turn2(r):
            ours[(r["model"], r["ctx_target"], r["max_tokens"], r["rows"])].append(r)
    ref = defaultdict(list)
    for r in ref_lines:
        if r.get("kind", "row") == "row" and is_turn2(r) and not r.get("error"):
            ref[(r["model"], r["ctx_target"], r["max_tokens"])].append(r)
    cells = []
    for key in sorted(ours):
        model, ctx, out, nrows = key
        rows = ours[key]
        ref_rows = [r for r in ref.get((model, ctx, out), []) if r["row"] < nrows]
        ours_cached = [r.get("cached_prompt_tokens") for r in rows]
        ref_cached = [r.get("cached_prompt_tokens") for r in ref_rows if r.get("cached_prompt_tokens") is not None]
        errors = [r["error"] for r in rows if r.get("error")]
        reasons = []
        if errors:
            reasons.append(f"turn2: {len(errors)} request(s) failed: {str(errors[0])[:120]}")
        if any(not c for c in ours_cached):
            reasons.append("turn2: ours reports 0 cached prompt tokens "
                           f"(cached_prompt_tokens per row: {ours_cached})")
        ours_ttft = median([r.get("ttft_s") for r in rows if not r.get("error")])
        ref_ttft = median([r.get("ttft_s") for r in ref_rows])
        known = [c for c in ours_cached if c is not None]
        cells.append({
            "cell": f"{model}|ctx{ctx}|out{out}|rows{nrows}", "model": model, "ctx": ctx, "out": out,
            "rows": nrows, "ours_ttft_s": ours_ttft, "ref_ttft_s": ref_ttft,
            "ttft_ratio": round(ours_ttft / ref_ttft, 4) if ours_ttft is not None and ref_ttft else None,
            "ours_cached_median": median(known), "ours_cached_min": min(known) if known else None,
            "ref_cached": "known" if ref_cached else "unknown",
            "ref_cached_median": median(ref_cached), "ref_cached_min": min(ref_cached) if ref_cached else None,
            "reasons": reasons, "pass": not reasons,
        })
    return {"cells": cells, "pass": all(c["pass"] for c in cells)}


def evaluate(ref_lines, our_lines, floor=0.03, text_fallback_reason=None, margins=None, tie_steps=2.0):
    turn2 = evaluate_turn2(ref_lines, our_lines)
    ref_lines = [r for r in ref_lines if not is_turn2(r)]
    our_lines = [r for r in our_lines if not is_turn2(r)]
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
        # Reported only: request-level output tok/s and its two parts' TTFT.
        cell["ours_request_trials"] = ours_request_scores(rows, ours_aggs.get(key, []), nrows)
        cell["ref_request_trials"] = [r.get("request_tps") for r in base]
        cell["ours_request_tps"] = median(cell["ours_request_trials"])
        cell["ref_request_tps"] = median(cell["ref_request_trials"])
        cell["request_ratio"] = (round(cell["ours_request_tps"] / cell["ref_request_tps"], 4)
                                 if cell["ours_request_tps"] and cell["ref_request_tps"] else None)
        cell["ours_ttft_s"] = median(r.get("ttft_s") for r in rows)
        cell["ref_ttft_s"] = median(r.get("ttft_s") for r in base)
        cell["ours_noise"] = round(noise(scores), 4)
        cell["ref_noise"] = round(noise(ref_scores), 4)
        cell["ours_request_noise"] = round(noise(cell["ours_request_trials"]), 4)
        cell["ref_request_noise"] = round(noise(cell["ref_request_trials"]), 4)
        first = min(rows, key=lambda r: (r["trial"], r["row"])) if rows else {}
        cell["prompt_tokens"] = first.get("prompt_tokens")
        cell["completion_tokens"] = first.get("completion_tokens")
        cell["ref_prompt_tokens"] = base[0].get("prompt_tokens") if base else None
        cell["ref_completion_tokens"] = base[0].get("completion_tokens") if base else None
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
        ties, not_comparable = [], []
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
            off = None
            reasoning_only = bool(r.get("reasoning_text")) and not r.get("text")
            if reasoning_only:
                not_comparable.append(where)
            else:
                off = first_diff(r.get("text", ""), want.get("text", ""))
            tie_rec = None
            if off is not None and r["row"] == 0:
                rec = match_margin(margins, ctx, off)
                if rec is not None and rec.get("margin_steps") is not None:
                    if rec["margin_steps"] <= tie_steps:
                        tie_rec = rec
                    else:
                        cell["notes"].append(
                            f"{where}: margin {rec['margin_steps']:.2f} steps > tie-steps {tie_steps:g}")
            if r.get("completion_tokens") != want.get("completion_tokens"):
                if tie_rec is not None:
                    cell["notes"].append(
                        f"{where}: tokens ours {r.get('completion_tokens')} vs ref {want.get('completion_tokens')} "
                        "not gated: text branched at a covered tie")
                else:
                    tokens_ok = False
                    kind = "fewer" if (r.get("completion_tokens") or 0) < (want.get("completion_tokens") or 0) else "more"
                    cell["reasons"].append(
                        f"{where}: {kind} tokens: ours {r.get('completion_tokens')} vs ref {want.get('completion_tokens')}")
            if r.get("prompt_tokens") != want.get("prompt_tokens"):
                prompt_ok = False
                cell["reasons"].append(
                    f"{where}: prompt_tokens ours {r.get('prompt_tokens')} vs ref {want.get('prompt_tokens')}")
            if off is None:
                continue
            if tie_rec is not None:
                ties.append({"trial": r["trial"], "row": r["row"], "byte_offset": off,
                             "token_index": tie_rec.get("token_index"),
                             "margin": tie_rec.get("margin"), "margin_steps": tie_rec["margin_steps"]})
                continue
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
        elif not text_ok:
            cell["text_gate"] = "fail"
        elif ties:
            cell["text_gate"] = "tie"
        elif not_comparable:
            cell["text_gate"] = "not_comparable"
        else:
            cell["text_gate"] = "byte_identical"
        cell["ties"] = ties
        cell["tie_margin_steps"] = max((t["margin_steps"] for t in ties), default=None)
        if ties:
            cell["notes"].append(
                "text differs at a reference-logit tie (margin_steps "
                + ", ".join(f"{t['margin_steps']:g}" for t in ties) + f" <= {tie_steps:g}): not a failure")
        if not_comparable:
            cell["text_reason"] = ("provider streamed reasoning_content with empty content; "
                                   "reasoning text is not matched against the reference text")
            cell["notes"].append(f"text not_comparable: {cell['text_reason']}")
        cell["tokens_ok"] = tokens_ok
        cell["prompt_ok"] = prompt_ok
        cell["slope_ok"] = True

    # Reference rows=1 cells the provider run did not produce: "not run", not failures.
    not_run = []
    for (model, ctx, out, prow) in sorted(ref):
        if prow == 0 and (model, ctx, out, 1) not in cells:
            not_run.append({"cell": f"{model}|ctx{ctx}|out{out}|rows1", "model": model, "ctx": ctx, "out": out})

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
    failing_turn2 = [c for c in turn2["cells"] if not c["pass"]]
    extra = {"turn2": turn2} if turn2["cells"] else {}
    return {
        **extra,
        "floor": floor,
        "text_fallback_reason": text_fallback_reason,
        "tie_steps": tie_steps,
        "cells": result_cells,
        "not_run": not_run,
        "ties": [{"cell": c["cell"], "margin_steps": c["tie_margin_steps"]} for c in result_cells if c["text_gate"] == "tie"],
        "slopes": slopes,
        "failing": [{"cell": c["cell"], "reasons": c["reasons"]} for c in failing + failing_turn2],
        "pass": not failing and not failing_turn2,
    }


def fmt(x, spec=".2f"):
    return "-" if x is None else format(x, spec)


def text_label(c):
    if c["text_gate"] == "tie":
        return f"tie (margin {c['tie_margin_steps']:g} steps)"
    return c["text_gate"]


def markdown(summary):
    lines = [
        "| model | ctx | out | rows | ref tok/s | ours tok/s | ratio | band "
        "| ref req tok/s | ours req tok/s | req ratio | ref ttft s | ours ttft s "
        "| text | tokens | slope | status |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|---|",
    ]
    for c in summary["cells"]:
        lines.append(
            f"| {c['model']} | {c['ctx']} | {c['out']} | {c['rows']} | {fmt(c['ref_tps'])} | "
            f"{fmt(c['ours_tps'])} | {fmt(c['ratio'], '.3f')} | {fmt(c['band'], '.3f')} | "
            f"{fmt(c.get('ref_request_tps'))} | {fmt(c.get('ours_request_tps'))} | "
            f"{fmt(c.get('request_ratio'), '.3f')} | {fmt(c.get('ref_ttft_s'), '.3f')} | "
            f"{fmt(c.get('ours_ttft_s'), '.3f')} | "
            f"{text_label(c)} | {'ok' if c['tokens_ok'] else 'FAIL'} | "
            f"{'ok' if c['slope_ok'] else 'FAIL'} | {'PASS' if c['pass'] else 'FAIL'} |")
    if summary["not_run"]:
        lines.append("")
        lines.append(f"Not run ({len(summary['not_run'])}, excluded from pass/fail): "
                     + ", ".join(f"ctx{n['ctx']}/out{n['out']}" for n in summary["not_run"]))
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
    if summary.get("turn2"):
        lines += ["", "Turn 2 (turn-2 request only; TTFT reported, a cell FAILS when ours reports 0 cached "
                  "prompt tokens; a reference without cached tokens is unknown):", "",
                  "| model | ctx | out | rows | ref ttft s | ours ttft s | ratio ours/ref "
                  "| ours cached median | ours cached min | ref cached median | ref cached min | status |",
                  "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|"]
        for c in summary["turn2"]["cells"]:
            ref_med = fmt(c["ref_cached_median"], ".0f") if c["ref_cached"] == "known" else "unknown"
            ref_min = fmt(c["ref_cached_min"], ".0f") if c["ref_cached"] == "known" else "unknown"
            lines.append(
                f"| {c['model']} | {c['ctx']} | {c['out']} | {c['rows']} | {fmt(c['ref_ttft_s'], '.3f')} | "
                f"{fmt(c['ours_ttft_s'], '.3f')} | {fmt(c['ttft_ratio'], '.3f')} | "
                f"{fmt(c['ours_cached_median'], '.0f')} | {fmt(c['ours_cached_min'], '.0f')} | "
                f"{ref_med} | {ref_min} | {'PASS' if c['pass'] else 'FAIL'} |")
    return "\n".join(lines)


def evaluate_baseline(base_lines, cand_lines, floor=0.03, subset=False):
    """Candidate provider run vs a baseline provider run: identity gate, speed deltas reported."""
    def index(lines):
        rows, aggs, _ = index_ours(lines)
        out = {}
        for key in set(rows) | set(aggs):
            out[key[1:]] = (key[0], rows.get(key, []), aggs.get(key, []))
        return out

    base, cand = index(base_lines), index(cand_lines)
    cells, not_run = [], []
    for key in sorted(set(base) | set(cand)):
        ctx, out, nrows = key
        if key not in cand and subset:
            not_run.append({"ctx": ctx, "out": out, "rows": nrows})
            continue
        c = {"ctx": ctx, "out": out, "rows": nrows, "reasons": [], "notes": []}
        cells.append(c)
        if key not in base or key not in cand:
            c["reasons"].append("cell missing from " + ("baseline" if key not in base else "candidate"))
            c["identical"] = False
            c["pass"] = False
            continue
        bmodel, brows, baggs = base[key]
        cmodel, crows, caggs = cand[key]
        c["model"], c["baseline_model"] = cmodel, bmodel
        sides = {}
        for side, rows, aggs in (("base", brows, baggs), ("cand", crows, caggs)):
            req = ours_request_scores(rows, aggs, nrows)
            dec = ours_scores(rows, aggs, nrows)
            sides[side] = req
            c[f"{side}_request_tps"] = median(req)
            c[f"{side}_decode_tps"] = median(dec)
            c[f"{side}_ttft_s"] = median(r.get("ttft_s") for r in rows)
            c[f"{side}_noise"] = round(noise(req), 4)
            c[f"{side}_request_trials"] = req
        c["band"] = round(max(floor, c["base_noise"], c["cand_noise"]), 4)
        c["request_delta"] = (round(c["cand_request_tps"] / c["base_request_tps"] - 1, 4)
                              if c["cand_request_tps"] and c["base_request_tps"] else None)
        if c["request_delta"] is not None and abs(c["request_delta"]) <= c["band"]:
            c["notes"].append(f"request tok/s delta {c['request_delta']:+.3f} within noise band {c['band']:.3f}")
        want = {}
        for r in sorted(brows, key=lambda r: r["trial"]):
            if r.get("error"):
                continue
            sig = (r.get("text", ""), r.get("reasoning_text", ""), r.get("completion_tokens"))
            if r["row"] not in want:
                want[r["row"]] = sig
            elif want[r["row"]] != sig:
                c["notes"].append(f"baseline trial {r['trial']} row {r['row']} differs from its trial 0")
        identical = True
        for r in sorted(crows, key=lambda r: (r["trial"], r["row"])):
            where = f"trial {r['trial']} row {r['row']}"
            if r.get("error"):
                identical = False
                c["reasons"].append(f"{where}: error {r['error']}")
                continue
            ref = want.get(r["row"])
            if ref is None:
                identical = False
                c["reasons"].append(f"{where}: no baseline row {r['row']}")
                continue
            text, reasoning, tokens = ref
            if r.get("completion_tokens") != tokens:
                identical = False
                c["reasons"].append(f"{where}: completion_tokens {r.get('completion_tokens')} vs baseline {tokens}")
            off = first_diff(r.get("text", ""), text)
            if off is not None:
                identical = False
                c["reasons"].append(f"{where}: text differs from baseline at byte {off}")
            roff = first_diff(r.get("reasoning_text", ""), reasoning)
            if roff is not None:
                identical = False
                c["reasons"].append(f"{where}: reasoning_text differs from baseline at byte {roff}")
        if not crows:
            identical = False
            c["reasons"].append("candidate has no rows")
        c["identical"] = identical
        c["pass"] = not c["reasons"]
    failing = [c for c in cells if not c["pass"]]
    return {"mode": "baseline", "floor": floor, "cells": cells, "not_run": not_run,
            "failing": [{"cell": f"ctx{c['ctx']}|out{c['out']}|rows{c['rows']}", "reasons": c["reasons"]}
                        for c in failing],
            "pass": not failing}


def markdown_baseline(summary):
    lines = [
        "| ctx | out | rows | base req tok/s | cand req tok/s | delta | base noise | cand noise "
        "| base decode tok/s | cand decode tok/s | base ttft s | cand ttft s | identical |",
        "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    for c in summary["cells"]:
        delta = c.get("request_delta")
        lines.append(
            f"| {c['ctx']} | {c['out']} | {c['rows']} | {fmt(c.get('base_request_tps'))} | "
            f"{fmt(c.get('cand_request_tps'))} | {'-' if delta is None else format(delta, '+.3f')} | "
            f"{fmt(c.get('base_noise'), '.3f')} | {fmt(c.get('cand_noise'), '.3f')} | "
            f"{fmt(c.get('base_decode_tps'))} | {fmt(c.get('cand_decode_tps'))} | "
            f"{fmt(c.get('base_ttft_s'), '.3f')} | {fmt(c.get('cand_ttft_s'), '.3f')} | "
            f"{'yes' if c.get('identical') else 'NO'} |")
    if summary["not_run"]:
        lines.append("")
        lines.append(f"Not run ({len(summary['not_run'])}, --subset): "
                     + ", ".join(f"ctx{n['ctx']}/out{n['out']}/rows{n['rows']}" for n in summary["not_run"]))
    if summary["failing"]:
        lines.append("")
        lines.append("Differences:")
        for f in summary["failing"]:
            lines.extend(f"- {f['cell']}: {reason}" for reason in f["reasons"])
    notes = [(c, n) for c in summary["cells"] for n in c["notes"]]
    if notes:
        lines.append("")
        lines.append("Notes:")
        lines.extend(f"- ctx{c['ctx']}|out{c['out']}|rows{c['rows']}: {n}" for c, n in notes)
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ref")
    ap.add_argument("--baseline", help="baseline provider.jsonl: provider-vs-provider identity mode")
    ap.add_argument("--subset", action="store_true",
                    help="--baseline mode: baseline cells the candidate did not run are not failures")
    ap.add_argument("--ours", required=True)
    ap.add_argument("--floor", type=float, default=0.03)
    ap.add_argument("--json")
    ap.add_argument("--text-fallback-reason")
    ap.add_argument("--margins", help="margin.py --json output; covered ties are not failures")
    ap.add_argument("--tie-steps", type=float, default=2.0,
                    help="largest margin (in float steps) still counted as a tie (default 2)")
    args = ap.parse_args(argv)
    if bool(args.ref) == bool(args.baseline):
        ap.error("give exactly one of --ref and --baseline")
    if args.baseline:
        base_lines, cand_lines = read_jsonl(args.baseline), read_jsonl(args.ours)
        if not base_lines or not cand_lines:
            print("empty input", file=sys.stderr)
            return 2
        summary = evaluate_baseline(base_lines, cand_lines, args.floor, args.subset)
        print(markdown_baseline(summary))
        if args.json:
            with open(args.json, "w") as f:
                f.write(json.dumps(summary, indent=2, sort_keys=True) + "\n")
        return 0 if summary["pass"] else 1
    ref_lines = read_jsonl(args.ref)
    our_lines = read_jsonl(args.ours)
    if not ref_lines or not our_lines:
        print("empty input", file=sys.stderr)
        return 2
    margins = load_margins(args.margins) if args.margins else None
    summary = evaluate(ref_lines, our_lines, args.floor, args.text_fallback_reason, margins, args.tie_steps)
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

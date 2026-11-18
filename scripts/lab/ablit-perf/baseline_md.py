#!/usr/bin/env python3
"""Write MODEL_DIR/baseline.md from one model's ablit-perf results (stdlib only).

usage: baseline_md.py MODEL_DIR [--model NAME] [--build SHA] [--commit SHA]

Reads MODEL_DIR/main/summary.json (compare.py, reference vs ours), and when present
MODEL_DIR/noise/vs-main.json (compare.py --baseline: the short-context 1-row cells
rerun on a fresh serve), MODEL_DIR/base/vs-main.json (the unmodified base in our
runtime, 1 row) and MODEL_DIR/base/summary.json (base model: our provider vs the reference
on the same base weights, 1 row; written when <K>_BASE_REFERENCE=1). Exits 2 when main/summary.json is missing or has no cells.
A summary whose reference failed (compare.py --reference-failed) is still written, headed
by the failure; its reference columns are empty. The reference's meta line
(main/reference.jsonl, else main/reference.suspect.jsonl) names the reference under the table,
with its `table_note` when it has one (oMLX: how its decode tok/s relates to ours).

Columns: req tok/s is the goal metric: for one row, request tok/s = completion_tokens /
(last token - request start); for a multi-row cell, aggregate tok/s = total completion
tokens / (last token of the last row - first request start), against the single-row
reference's request tok/s. Per-request tok/s (median over rows and trials), decode tok/s,
TTFT, TTFT excluding the provider's queue wait and the largest queue wait
(usage.macprovider_queue_ms) are its parts. `service` is SERIAL (queued) for a multi-row
cell whose rows never decoded at the same instant: it measures queueing, not batching.
`text identical` is against the reference and is reported only. When main/grid.json
records the serve's route (run-grid.sh ROUTE lines), it is printed above the table.
"""
import argparse
import json
import os
import sys


def fmt(x, spec=".2f"):
    return "-" if x is None else format(x, spec)


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except OSError:
        return None


def text_identical(c):
    gate = c.get("text_gate")
    if gate == "byte_identical":
        return "yes"
    if gate == "not_comparable":
        return "n/a (reasoning only)"
    if gate == "no_reference":
        return "n/a (no reference)"
    return f"no ({gate})"


def median(xs):
    xs = sorted(x for x in xs if isinstance(x, (int, float)))
    if not xs:
        return None
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2


TABLE_HEAD = [
    "| cell | service | prompt_tokens | completion_tokens | ref req tok/s | ours req tok/s (rows>1: aggregate) "
    "| req ratio | ours per-request tok/s | ref decode tok/s | ours decode tok/s | decode ratio "
    "| ref TTFT s | ours TTFT s | ours TTFT excl queue s | ours queue max s | text identical "
    "| ours noise | ref noise |",
    "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|"]


def service(c):
    if c.get("rows", 1) == 1:
        return "-"
    if c.get("service") == "batched":
        return f"batched ({c.get('decode_overlap_rows')})"
    if c.get("service") in ("serial", "mixed"):
        return f"{c['service'].upper()} (queued)"
    return "unknown"


def ratio(a, b):
    return a / b if a and b else None


def reference_failed(summary, label):
    reason = summary.get("reference_failed")
    return [f"**{label} reference FAILED**: `{reason}`. Reference columns are empty; "
            "the provider columns are measured.", ""] if reason else []


def reference_meta(run_dir):
    """The `kind: meta` line of RUN_DIR's reference rows (kept or set aside as suspect), or None."""
    for name in ("reference.jsonl", "reference.suspect.jsonl"):
        try:
            with open(os.path.join(run_dir, name)) as f:
                for line in f:
                    try:
                        r = json.loads(line)
                    except ValueError:
                        continue
                    if r.get("kind") == "meta":
                        return r
        except OSError:
            continue
    return None


def reference_lines(meta):
    if not meta:
        return []
    v = meta.get("versions") or {}
    kind = meta.get("reference", "?")
    ident = (f"oMLX {meta.get('omlx_version')} commit `{meta.get('omlx_commit')}`" if kind == "omlx"
             else f"{kind} {v.get(kind)}")
    deps = ", ".join(f"{k} {v[k]}" for k in ("mlx", "mlx-lm", "mlx-vlm") if v.get(k) and k != kind)
    out = ["", f"Reference: {ident}" + (f" ({deps})" if deps else "") + "."]
    if meta.get("table_note"):
        out.append(meta["table_note"])
    return out


def cell_rows(cells):
    out = []
    for c in cells:
        goal = c.get("ours_goal_tps")
        ours_decode, ref_decode = c.get("ours_decode_tps"), c.get("ref_decode_tps")
        out.append(
            f"| ctx{c['ctx']}/out{c['out']}/rows{c['rows']} | {service(c)} | {c.get('prompt_tokens', '-')} | "
            f"{c.get('completion_tokens', '-')} | {fmt(c.get('ref_request_tps'))} | {fmt(goal)} | "
            f"{fmt(c.get('goal_ratio'), '.3f')} | {fmt(c.get('ours_request_tps'))} | "
            f"{fmt(ref_decode)} | {fmt(ours_decode)} | {fmt(ratio(ours_decode, ref_decode), '.3f')} | "
            f"{fmt(c.get('ref_ttft_s'), '.3f')} | {fmt(c.get('ours_ttft_s'), '.3f')} | "
            f"{fmt(c.get('ours_ttft_excl_queue_s'), '.3f')} | {fmt(c.get('ours_queue_s_max'), '.3f')} | "
            f"{text_identical(c)} | "
            f"{fmt(c.get('ours_goal_noise'), '.3f')} | {fmt(c.get('ref_request_noise'), '.3f')} |")
    return out


def route_lines(run_dir):
    """The serve's batching route at the grid start and end (run-grid.sh), from RUN_DIR/grid.json."""
    grid = load(os.path.join(run_dir, "grid.json")) or {}
    out = []
    for phase in ("start", "end"):
        r = (grid.get("route") or {}).get(phase)
        if r:
            out.append(f"Route at grid {phase}: batching **{r.get('batching')}**, {r.get('slots')} served slots, "
                       f"reason `{r.get('reason')}`, mode `{r.get('mode')}`, self-check `{r.get('self_check')}` "
                       f"(verified k {r.get('verified_k')}), max observed batch depth "
                       f"{r.get('max_observed_batch_depth')}.")
    return out + [""] if out else []


def mtp_section(model_dir):
    """Native MTP vs ordinary from MODEL_DIR/mtp/bench.jsonl (native-mtp-bench run records)."""
    path = os.path.join(model_dir, "mtp", "bench.jsonl")
    if not os.path.exists(path):
        return []
    runs = []
    with open(path) as f:
        for line in f:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("record_type") == "run" and not r.get("warmup"):
                runs.append(r)
    analysis = load(os.path.join(model_dir, "mtp", "analysis.json")) or {}
    out = ["", "## Native MTP vs ordinary (native-mtp-bench, 1 row)", "",
           "Exploratory policy, 5 paired blocks: below the SPEC-048 R015 gate (10 blocks), baseline only, "
           f"no verdict. Analyzer status: `{analysis.get('overall_status', 'unavailable')}`. "
           "Committed tok/s includes prefill; decode tok/s excludes it. Medians over the blocks.", "",
           "| cell | blocks | native committed tok/s | ordinary committed tok/s | native / ordinary "
           "| native decode tok/s | ordinary decode tok/s | native TTFT p50/p95 s | ordinary TTFT p50/p95 s "
           "| acceptance | parity mismatches |",
           "|---|---:|---:|---:|---:|---:|---:|---|---|---:|---:|"]
    for cell in sorted({r.get("cell_id") for r in runs}, key=str):
        by = {p: [r for r in runs if r.get("cell_id") == cell and r.get("path") == p]
              for p in ("native_mtp", "ordinary")}
        m = {p: {k: median(r.get(k) for r in rs) for k in
                 ("aggregate_committed_tps", "aggregate_decode_tps", "ttft_p50_seconds", "ttft_p95_seconds")}
             for p, rs in by.items()}
        nat, ordi = m["native_mtp"]["aggregate_committed_tps"], m["ordinary"]["aggregate_committed_tps"]
        proposed = sum(r.get("mtp_proposed_tokens") or 0 for r in by["native_mtp"])
        accepted = sum(r.get("mtp_accepted_tokens") or 0 for r in by["native_mtp"])
        mismatches = sum(1 for rs in by.values() for r in rs if r.get("parity_mismatch"))
        ttft = {p: f"{fmt(m[p]['ttft_p50_seconds'], '.3f')} / {fmt(m[p]['ttft_p95_seconds'], '.3f')}" for p in m}
        out.append(
            f"| {cell} | {min(len(by['native_mtp']), len(by['ordinary']))} | {fmt(nat)} | {fmt(ordi)} | "
            f"{fmt(nat / ordi if nat and ordi else None, '.3f')} | "
            f"{fmt(m['native_mtp']['aggregate_decode_tps'])} | {fmt(m['ordinary']['aggregate_decode_tps'])} | "
            f"{ttft['native_mtp']} | {ttft['ordinary']} | "
            f"{fmt(accepted / proposed if proposed else None, '.3f')} | {mismatches} |")
    if not runs:
        out.append("| (no run records) | | | | | | | | | | |")
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("model_dir")
    ap.add_argument("--model")
    ap.add_argument("--build", default="?")
    ap.add_argument("--commit", default="?")
    a = ap.parse_args(argv)
    main_summary = load(os.path.join(a.model_dir, "main", "summary.json"))
    if not main_summary or not main_summary.get("cells"):
        print(f"no cells in {a.model_dir}/main/summary.json", file=sys.stderr)
        return 2
    name = a.model or os.path.basename(os.path.normpath(a.model_dir))
    out = [f"# Baseline: {name}", "",
           f"Build `{a.build}` (commit `{a.commit}`), production route (no autotune flag, batching auto). "
           "Req tok/s: one row, completion_tokens / (last token - request start); several rows, aggregate "
           "tok/s = total completion tokens / (last token of the last row - first request start). "
           "Per-request tok/s is the median over rows and trials. Queue = usage.macprovider_queue_ms. "
           "SERIAL (queued) = the rows never decoded together: queueing, not batching. "
           "Noise = (max - min) / median over the trials of one side.", ""]
    out += route_lines(os.path.join(a.model_dir, "main"))
    out += reference_failed(main_summary, "Main")
    out += TABLE_HEAD + cell_rows(main_summary["cells"])
    out += reference_lines(reference_meta(os.path.join(a.model_dir, "main")))
    mismatched = [c for c in main_summary["cells"] if c.get("prompt_ok") is False]
    if mismatched:
        out += ["", "prompt_tokens differ from the reference in: "
                + ", ".join(f"ctx{c['ctx']}/out{c['out']}/rows{c['rows']}" for c in mismatched)]

    noise = load(os.path.join(a.model_dir, "noise", "vs-main.json"))
    out += ["", "## Noise: short-context 1-row cells rerun on a fresh serve", ""]
    if noise is None:
        out.append("not run")
    else:
        out += ["| cell | main req tok/s | rerun req tok/s | run-to-run delta | main noise | rerun noise "
                "| main TTFT s | rerun TTFT s | identical |",
                "|---|---:|---:|---:|---:|---:|---:|---:|---|"]
        for c in noise["cells"]:
            d = c.get("request_delta")
            out.append(
                f"| ctx{c['ctx']}/out{c['out']}/rows{c['rows']} | {fmt(c.get('base_request_tps'))} | "
                f"{fmt(c.get('cand_request_tps'))} | {'-' if d is None else format(d, '+.3f')} | "
                f"{fmt(c.get('base_noise'), '.3f')} | {fmt(c.get('cand_noise'), '.3f')} | "
                f"{fmt(c.get('base_ttft_s'), '.3f')} | {fmt(c.get('cand_ttft_s'), '.3f')} | "
                f"{'yes' if c.get('identical') else 'NO'} |")
        spread = [abs(c["request_delta"]) for c in noise["cells"] if c.get("request_delta") is not None]
        spread += [c[k] for c in noise["cells"] for k in ("base_noise", "cand_noise") if c.get(k) is not None]
        out += ["", f"Noise spread (largest of within-run trial spread and run-to-run delta): "
                f"{fmt(max(spread) if spread else None, '.3f')}. "
                + ("Run-to-run output identical." if noise.get("pass") else "Run-to-run OUTPUT DIFFERS: see noise/vs-main.md.")]

    base = load(os.path.join(a.model_dir, "base", "vs-main.json"))
    if base is not None:
        out += ["", "## Unmodified base vs this row in our runtime (1 row)", "",
                "| cell | base req tok/s | this row req tok/s | this row / base - 1 | base decode tok/s "
                "| this row decode tok/s |",
                "|---|---:|---:|---:|---:|---:|"]
        for c in base["cells"]:
            b, m = c.get("cand_request_tps"), c.get("base_request_tps")
            cost = (m / b - 1) if b and m else None
            out.append(f"| ctx{c['ctx']}/out{c['out']}/rows{c['rows']} | {fmt(b)} | {fmt(m)} | "
                       f"{'-' if cost is None else format(cost, '+.3f')} | {fmt(c.get('cand_decode_tps'))} | "
                       f"{fmt(c.get('base_decode_tps'))} |")
    base_ref = load(os.path.join(a.model_dir, "base", "summary.json"))
    if base_ref and base_ref.get("cells"):
        out += ["", "## Base model: our provider vs reference on the same base weights (1 row)", "",
                "The unmodified base checkpoint, served by our provider and run by the reference "
                "implementation in the same window; same columns as the main table.", ""]
        out += reference_failed(base_ref, "Base")
        out += TABLE_HEAD + cell_rows(base_ref["cells"])
    out += mtp_section(a.model_dir)
    path = os.path.join(a.model_dir, "baseline.md")
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")
    print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())

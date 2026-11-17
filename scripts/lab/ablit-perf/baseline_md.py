#!/usr/bin/env python3
"""Write MODEL_DIR/baseline.md from one model's ablit-perf results (stdlib only).

usage: baseline_md.py MODEL_DIR [--model NAME] [--build SHA] [--commit SHA]

Reads MODEL_DIR/main/summary.json (compare.py, reference vs ours), and when present
MODEL_DIR/noise/vs-main.json (compare.py --baseline: the short-context 1-row cells
rerun on a fresh serve) and MODEL_DIR/base/vs-main.json (the unmodified base in our
runtime, 1 row). Exits 2 when main/summary.json is missing or has no cells.

Columns: request tok/s = completion_tokens / (last token - request start), summed over
the rows of a multi-row cell (the goal metric); decode tok/s and TTFT are its parts.
Multi-row cells compare against the single-row reference. `text identical` is against
the reference and is reported only.
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
    return f"no ({gate})"


def median(xs):
    xs = sorted(x for x in xs if isinstance(x, (int, float)))
    if not xs:
        return None
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2


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
           "Request tok/s = completion_tokens / (last token - request start), summed over concurrent rows; "
           "noise = (max - min) / median over the trials of one side.", "",
           "| cell | prompt_tokens | completion_tokens | ref decode tok/s | ours decode tok/s | ratio "
           "| ref TTFT s | ours TTFT s | ref req tok/s | ours req tok/s | req ratio | text identical "
           "| ours noise | ref noise |",
           "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|"]
    for c in main_summary["cells"]:
        out.append(
            f"| ctx{c['ctx']}/out{c['out']}/rows{c['rows']} | {c.get('prompt_tokens', '-')} | "
            f"{c.get('completion_tokens', '-')} | {fmt(c.get('ref_tps'))} | {fmt(c.get('ours_tps'))} | "
            f"{fmt(c.get('ratio'), '.3f')} | {fmt(c.get('ref_ttft_s'), '.3f')} | {fmt(c.get('ours_ttft_s'), '.3f')} | "
            f"{fmt(c.get('ref_request_tps'))} | {fmt(c.get('ours_request_tps'))} | "
            f"{fmt(c.get('request_ratio'), '.3f')} | {text_identical(c)} | "
            f"{fmt(c.get('ours_request_noise'), '.3f')} | {fmt(c.get('ref_request_noise'), '.3f')} |")
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
    out += mtp_section(a.model_dir)
    path =os.path.join(a.model_dir, "baseline.md")
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")
    print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())

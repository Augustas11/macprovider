#!/usr/bin/env python3
"""Per-row decode cost by model section, from a serve run with MLX_LM_SECTION_TIMING=1 (#2409).

usage: section_timing_report.py --serve-err serve.err --out-md decode-profile.md
           --out-json decode-profile.json [--rows 1,4,8,11] [--goal-slope-ms 5.9] [--min-forwards 5]

Stdlib only. The fork's LabSectionTimer prints one stderr line per model forward:

  section_timing tag=rows=<B>,L=<L> wall_ms=<ms> <section>=<exclusive ms>/<calls> ...

Decode forwards are L=1; B is the rows in that forward. Every section evaluates its inputs
and outputs at its edges, so the times are shares of a synchronized forward (slower than the
pipelined serve), not its latency. Per B with at least --min-forwards forwards: the median
wall time and, per section, the median exclusive ms per forward (0 when absent) and the
median calls. Over the row counts: the least-squares ms per extra row of each section, its
share of the summed slope, that share applied to --goal-slope-ms (the unsynchronized
cost per extra row measured end to end: T(n) = 27.7 ms + 5.9 ms/row), and `scales` when
the slope covers at least a quarter of the section's time at the largest B. A section is
`per-row` when it runs once per row (a Swift loop over rows: attn.rows, attn.row.*,
fp_linear.*), else `batched`.

Exit 0; 2 when no decode forward meets --min-forwards at two or more row counts.
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from pathlib import Path

LINE = re.compile(r"section_timing tag=rows=(\d+),L=(\d+) wall_ms=([0-9.]+)(.*)$")
FIELD = re.compile(r"(\S+)=([0-9.]+)/(\d+)")
PER_ROW = ("attn.rows", "attn.row.", "fp_linear.")


def parse(lines) -> dict[int, list[dict]]:
    """Decode forwards by row count: [{wall, sections: {name: (ms, calls)}}]."""
    out: dict[int, list[dict]] = {}
    for line in lines:
        m = LINE.search(line)
        if not m or m.group(2) != "1":
            continue
        sections = {f.group(1): (float(f.group(2)), int(f.group(3))) for f in FIELD.finditer(m.group(4))}
        out.setdefault(int(m.group(1)), []).append({"wall": float(m.group(3)), "sections": sections})
    return out


def fit(xs: list[float], ys: list[float]) -> tuple[float, float]:
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    den = sum((x - mx) ** 2 for x in xs)
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den if den else 0.0
    return my - slope * mx, slope


def kind(name: str) -> str:
    return "per-row" if any(name == p or (p.endswith(".") and name.startswith(p)) for p in PER_ROW) else "batched"


def summarize(forwards: dict[int, list[dict]], rows: list[int] | None, goal_slope: float, min_forwards: int) -> dict:
    keep = sorted(b for b, fs in forwards.items() if len(fs) >= min_forwards and (not rows or b in rows))
    if len(keep) < 2:
        raise ValueError(f"decode forwards at {sorted((b, len(f)) for b, f in forwards.items())}; "
                         f"need {min_forwards}+ at two row counts")
    names = sorted({n for b in keep for f in forwards[b] for n in f["sections"]})
    per_b = {}
    for b in keep:
        fs = forwards[b]
        per_b[b] = {
            "forwards": len(fs),
            "wall_ms": statistics.median(f["wall"] for f in fs),
            "sections_ms": statistics.median(sum(ms for ms, _ in f["sections"].values()) for f in fs),
            "ms": {n: statistics.median(f["sections"].get(n, (0.0, 0))[0] for f in fs) for n in names},
            "calls": {n: statistics.median(f["sections"].get(n, (0.0, 0))[1] for f in fs) for n in names},
        }
    xs = [float(b) for b in keep]
    wall_a, wall_b = fit(xs, [per_b[b]["wall_ms"] for b in keep])
    slopes = {n: fit(xs, [per_b[b]["ms"][n] for b in keep]) for n in names}
    total_slope = sum(s for _, s in slopes.values())
    top = keep[-1]
    sections = []
    for n in names:
        a, s = slopes[n]
        at_top = per_b[top]["ms"][n]
        sections.append({
            "section": n, "kind": kind(n), "ms_by_rows": {str(b): per_b[b]["ms"][n] for b in keep},
            "calls_at_max_rows": per_b[top]["calls"][n], "intercept_ms": a, "ms_per_row": s,
            "slope_share": s / total_slope if total_slope else 0.0,
            "goal_ms_per_row": s / total_slope * goal_slope if total_slope else 0.0,
            "scales": s > 0 and at_top > 0 and s * (keep[-1] - keep[0]) >= 0.25 * at_top,
        })
    sections.sort(key=lambda r: -r["ms_per_row"])
    kinds = {}
    for k in ("per-row", "batched"):
        s = sum(r["ms_per_row"] for r in sections if r["kind"] == k)
        kinds[k] = {"ms_per_row": s, "slope_share": s / total_slope if total_slope else 0.0,
                    "ms_at_max_rows": sum(r["ms_by_rows"][str(top)] for r in sections if r["kind"] == k)}
    return {"rows": keep, "per_rows": {str(b): {k: v for k, v in per_b[b].items() if k in ("forwards", "wall_ms", "sections_ms")}
                                       for b in keep},
            "wall_intercept_ms": wall_a, "wall_ms_per_row": wall_b, "sections_ms_per_row": total_slope,
            "goal_ms_per_row": goal_slope, "kinds": kinds, "sections": sections}


def markdown(s: dict) -> str:
    rows = s["rows"]
    out = ["# Qwen3.8-Flash-Next CB decode: per-row cost by section", "",
           "Synchronized forwards (each section evaluated at its edges): shares, not pipelined latency.", "",
           "| rows | forwards | median wall ms | median sections ms |", "|---:|---:|---:|---:|"]
    for b in rows:
        p = s["per_rows"][str(b)]
        out.append(f"| {b} | {p['forwards']} | {p['wall_ms']:.2f} | {p['sections_ms']:.2f} |")
    out += ["", f"Synced forward: {s['wall_intercept_ms']:.2f} ms + {s['wall_ms_per_row']:.2f} ms/row "
            f"(sections sum {s['sections_ms_per_row']:.2f} ms/row); end-to-end goal slope {s['goal_ms_per_row']:.2f} ms/row.", "",
            "| kind | ms/row | share of slope | ms at max rows |", "|---|---:|---:|---:|"]
    for k, v in s["kinds"].items():
        out.append(f"| {k} | {v['ms_per_row']:.3f} | {100 * v['slope_share']:.1f}% | {v['ms_at_max_rows']:.2f} |")
    head = " | ".join(f"ms @{b}" for b in rows)
    out += ["", f"| section | kind | {head} | calls @{rows[-1]} | ms/row | share of slope | of goal ms/row | scales |",
            "|---|---|" + "---:|" * (len(rows) + 4) + "---|"]
    for r in s["sections"]:
        cells = " | ".join(f"{r['ms_by_rows'][str(b)]:.3f}" for b in rows)
        out.append(f"| {r['section']} | {r['kind']} | {cells} | {r['calls_at_max_rows']:g} | {r['ms_per_row']:.3f} | "
                   f"{100 * r['slope_share']:.1f}% | {r['goal_ms_per_row']:.3f} | {'yes' if r['scales'] else 'no'} |")
    return "\n".join(out) + "\n"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--serve-err", required=True)
    ap.add_argument("--out-md", required=True)
    ap.add_argument("--out-json", required=True)
    ap.add_argument("--rows", default="")
    ap.add_argument("--goal-slope-ms", type=float, default=5.9)
    ap.add_argument("--min-forwards", type=int, default=5)
    a = ap.parse_args(argv)
    rows = [int(r) for r in a.rows.split(",") if r] or None
    try:
        with open(a.serve_err, errors="replace") as f:
            summary = summarize(parse(f), rows, a.goal_slope_ms, a.min_forwards)
    except (OSError, ValueError) as e:
        print(f"section_timing_report: {e}", file=sys.stderr)
        return 2
    Path(a.out_json).write_text(json.dumps(summary, indent=2, sort_keys=True))
    md = markdown(summary)
    Path(a.out_md).write_text(md)
    print(md, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())

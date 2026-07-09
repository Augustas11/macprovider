#!/usr/bin/env python3
"""
Daily HTML report for the Phase 2 buyer harness.

Reads runs.sqlite, slices by date (UTC), and writes reports/YYYY-MM-DD.html.

Default behavior: emit a report for today (UTC). Pass --date YYYY-MM-DD for a
specific day, or --all to (re)build a report for every distinct date in the db.

The HTML is deliberately ugly-on-purpose: single-file, no JS, no external CSS.
The goal is something you can email to the M4 user or `open` from Finder
without an internet connection.
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sqlite3
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path

import yaml

import spec029

BETA_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG = BETA_DIR / "config.yaml"


def load_config(path: Path) -> dict:
    with path.open() as f:
        return yaml.safe_load(f)


def fetch_rows(conn: sqlite3.Connection, date_iso: str) -> list[sqlite3.Row]:
    cur = conn.cursor()
    cur.row_factory = sqlite3.Row
    cur.execute(
        "SELECT * FROM runs WHERE substr(ts_utc, 1, 10) = ? ORDER BY ts_utc, id",
        (date_iso,),
    )
    return cur.fetchall()


def distinct_dates(conn: sqlite3.Connection) -> list[str]:
    cur = conn.execute(
        "SELECT DISTINCT substr(ts_utc, 1, 10) AS d FROM runs ORDER BY d"
    )
    return [r[0] for r in cur.fetchall()]


def median_or_none(xs: list[float]) -> float | None:
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def row_get(row: sqlite3.Row, key: str, default=None):
    return row[key] if key in row.keys() else default


def summarize_per_workload(rows: list[sqlite3.Row]) -> list[dict]:
    by_name: dict[str, list[sqlite3.Row]] = {}
    for r in rows:
        by_name.setdefault(r["workload"], []).append(r)
    out = []
    for name, group in sorted(by_name.items()):
        oks = [r for r in group if r["http_status"] == 200 and not r["error"]]
        ttfts = [r["ttft_ms"] for r in oks if r["ttft_ms"] is not None]
        totals = [r["total_ms"] for r in oks if r["total_ms"] is not None]
        tps = [r["throughput_tps"] for r in oks if r["throughput_tps"] is not None]
        leaks = sum(1 for r in group if r["stop_token_leak"])
        corpus_classes = sorted({row_get(r, "corpus_class") for r in group if row_get(r, "corpus_class")})
        ram_tiers = sorted({row_get(r, "ram_tier_key") for r in group if row_get(r, "ram_tier_key")})
        out.append({
            "name": name,
            "corpus_class": ",".join(corpus_classes) if corpus_classes else None,
            "ram_tiers": ",".join(ram_tiers) if ram_tiers else None,
            "n": len(group),
            "ok": len(oks),
            "fail": len(group) - len(oks),
            "median_ttft_ms": median_or_none(ttfts),
            "median_total_ms": median_or_none(totals),
            "median_tps": median_or_none(tps),
            "leaks": leaks,
        })
    return out


def fmt(v, unit: str = "", digits: int = 0) -> str:
    if v is None:
        return "—"
    if isinstance(v, float):
        return f"{v:.{digits}f}{unit}"
    return f"{v}{unit}"


CSS = """
body { font: 14px/1.45 -apple-system, system-ui, sans-serif; margin: 2em; max-width: 980px; color: #222; }
h1 { font-size: 1.4em; margin-bottom: 0; }
h2 { font-size: 1.1em; margin-top: 2em; border-bottom: 1px solid #ccc; padding-bottom: 0.2em; }
.meta { color: #666; font-size: 0.9em; margin-top: 0.2em; }
table { border-collapse: collapse; width: 100%; margin-top: 0.6em; }
th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid #eee; }
th { background: #f6f6f6; font-weight: 600; }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
.bad { color: #b00020; font-weight: 600; }
.muted { color: #888; }
.preview { font-family: ui-monospace, Menlo, monospace; font-size: 12px; color: #444; white-space: pre-wrap; }
.errrow td { background: #fff5f5; }
.summary { display: flex; gap: 2em; margin: 1em 0; }
.summary div { background: #f6f6f6; padding: 0.6em 1em; border-radius: 6px; }
.summary .label { font-size: 0.8em; color: #666; text-transform: uppercase; letter-spacing: 0.05em; }
.summary .value { font-size: 1.4em; font-weight: 600; }
"""


def render(date_iso: str, rows: list[sqlite3.Row]) -> str:
    n_total = len(rows)
    n_ok = sum(1 for r in rows if r["http_status"] == 200 and not r["error"])
    n_fail = n_total - n_ok
    n_leaks = sum(1 for r in rows if r["stop_token_leak"])
    tunnel_url = rows[0]["tunnel_url"] if rows else "—"
    model = rows[0]["model"] if rows else "—"
    per_wl = summarize_per_workload(rows)
    spec029_cells = spec029.cells_from_rows(rows)
    spec029_summary = spec029.class_aware_report(spec029_cells, f"beta-report-{date_iso}") if spec029_cells else None

    parts: list[str] = []
    parts.append(f"<!doctype html><html><head><meta charset=utf-8><title>Phase 2 — {date_iso}</title><style>{CSS}</style></head><body>")
    parts.append(f"<h1>Phase 2 buyer harness — {date_iso}</h1>")
    parts.append(f"<div class=meta>model: <code>{html.escape(model)}</code> · tunnel: <code>{html.escape(tunnel_url)}</code></div>")

    parts.append("<div class=summary>")
    parts.append(f"<div><div class=label>Total</div><div class=value>{n_total}</div></div>")
    parts.append(f"<div><div class=label>OK</div><div class=value>{n_ok}</div></div>")
    fail_cls = " bad" if n_fail else ""
    leak_cls = " bad" if n_leaks else ""
    parts.append(f"<div><div class=label>Failures</div><div class='value{fail_cls}'>{n_fail}</div></div>")
    parts.append(f"<div><div class=label>Stop-token leaks</div><div class='value{leak_cls}'>{n_leaks}</div></div>")
    parts.append("</div>")

    parts.append("<h2>Per-workload medians</h2>")
    parts.append("<table><thead><tr>"
                 "<th>Workload</th>"
                 "<th>Corpus</th><th>RAM tier</th>"
                 "<th class=num>N</th><th class=num>OK</th><th class=num>Fail</th>"
                 "<th class=num>Median TTFT</th><th class=num>Median total</th>"
                 "<th class=num>Median tok/s</th><th class=num>Leaks</th>"
                 "</tr></thead><tbody>")
    for w in per_wl:
        parts.append("<tr>")
        parts.append(f"<td>{html.escape(w['name'])}</td>")
        parts.append(f"<td>{html.escape(w['corpus_class'] or '—')}</td>")
        parts.append(f"<td>{html.escape(w['ram_tiers'] or '—')}</td>")
        parts.append(f"<td class=num>{w['n']}</td>")
        parts.append(f"<td class=num>{w['ok']}</td>")
        fail_cls = "num bad" if w['fail'] else "num"
        parts.append(f"<td class='{fail_cls}'>{w['fail']}</td>")
        parts.append(f"<td class=num>{fmt(w['median_ttft_ms'], ' ms', 0)}</td>")
        parts.append(f"<td class=num>{fmt(w['median_total_ms'], ' ms', 0)}</td>")
        parts.append(f"<td class=num>{fmt(w['median_tps'], '', 1)}</td>")
        leak_cls = "num bad" if w['leaks'] else "num"
        parts.append(f"<td class='{leak_cls}'>{w['leaks']}</td>")
        parts.append("</tr>")
    parts.append("</tbody></table>")

    if spec029_summary:
        parts.append("<h2>SPEC-029 class-aware sweep</h2>")
        parts.append("<table><thead><tr>"
                     "<th>Model</th><th>Workload</th><th>Corpus</th><th>RAM tier</th>"
                     "<th>Status</th><th>No-winner reason</th>"
                     "<th class=num>Samples</th><th class=num>Cells</th>"
                     "<th>Metrics</th><th>Gate</th><th>Winner tuple</th><th>Tie-breaker reason</th><th>Tie-breakers</th><th>Candidate source</th><th>Source</th>"
                     "</tr></thead><tbody>")
        for p in spec029_summary["partitions"] + spec029_summary["streaming_probes"]:
            gate = p["gate_policy"]
            metrics = p.get("profile_metrics") or {}
            gate_text = (
                f"n>={gate['min_samples']}, "
                f"p95 TTFT<={gate['max_p95_ttft_ms']}ms, "
                f"leak<={gate['max_stop_token_leak_rate']}"
            )
            metrics_text = (
                f"median_tps={fmt(metrics.get('median_tps'), '', 1)}, "
                f"p95_ttft={fmt(metrics.get('p95_ttft_ms'), 'ms', 0)}, "
                f"leak={fmt(metrics.get('stop_token_leak_rate'), '', 3)}, "
                f"spec_accept={fmt(metrics.get('spec_decode_acceptance_rate'), '', 3)}"
            )
            winner = p["winner_tuple"]
            winner_text = html.escape(str(winner)) if winner else "—"
            tie_text = ", ".join(p.get("tie_breaker_order") or [])
            parts.append("<tr>")
            parts.append(f"<td>{html.escape(p.get('model') or '—')}</td>")
            parts.append(f"<td>{html.escape(p['workload'])}</td>")
            parts.append(f"<td>{html.escape(p.get('corpus_class') or '—')}</td>")
            parts.append(f"<td>{html.escape(p['ram_tier_key'])}</td>")
            parts.append(f"<td>{html.escape(p['status'])}</td>")
            parts.append(f"<td>{html.escape(p.get('no_winner_reason') or '—')}</td>")
            parts.append(f"<td class=num>{metrics.get('sample_count', '—')}</td>")
            parts.append(f"<td class=num>{p.get('evaluated_cell_count', '—')}</td>")
            parts.append(f"<td>{html.escape(metrics_text)}</td>")
            parts.append(f"<td>{html.escape(gate_text)}</td>")
            parts.append(f"<td><code>{winner_text}</code></td>")
            parts.append(f"<td>{html.escape(p.get('tie_breaker_reason') or '—')}</td>")
            parts.append(f"<td>{html.escape(tie_text or '—')}</td>")
            parts.append(f"<td>{html.escape(p.get('candidate_source') or '—')}</td>")
            parts.append(f"<td>{html.escape(p.get('source') or '—')}</td>")
            parts.append("</tr>")
        parts.append("</tbody></table>")

        parts.append("<h2>SPEC-029 evaluated cells</h2>")
        parts.append("<table><thead><tr>"
                     "<th>Model</th><th>Workload</th><th>RAM tier</th><th>Cell</th>"
                     "<th class=num>Samples</th><th class=num>Failures</th>"
                     "<th>Metrics</th><th>Draft</th><th>Source</th>"
                     "</tr></thead><tbody>")
        for cell in spec029_summary["evaluated_cells"]:
            cell_text = (
                f"kv_bits={cell['kv_bits']}, "
                f"context={cell['max_context_override']}, "
                f"concurrency={cell['max_concurrency_override']}"
            )
            metrics_text = (
                f"p95_ttft={fmt(cell['p95_ttft_ms'], 'ms', 0)}, "
                f"median_tps={fmt(cell['median_tps'], '', 1)}, "
                f"leak={fmt(cell['stop_token_leak_rate'], '', 3)}, "
                f"spec_accept={fmt(cell['spec_decode_acceptance_rate'], '', 3)}"
            )
            draft_text = "—"
            if cell.get("draft_model") or cell.get("draft_model_artifact_sha256") or cell.get("num_draft_tokens"):
                draft_text = (
                    f"model={cell.get('draft_model') or '—'}, "
                    f"sha256={cell.get('draft_model_artifact_sha256') or '—'}, "
                    f"tokens={cell.get('num_draft_tokens') or '—'}"
                )
                if cell.get("draft_validation_error"):
                    draft_text += f", validation={cell['draft_validation_error']}"
            parts.append("<tr>")
            parts.append(f"<td>{html.escape(cell.get('model') or '—')}</td>")
            parts.append(f"<td>{html.escape(cell['workload'])}</td>")
            parts.append(f"<td>{html.escape(cell['ram_tier_key'])}</td>")
            parts.append(f"<td>{html.escape(cell_text)}</td>")
            parts.append(f"<td class=num>{cell['successful_sample_count']}</td>")
            parts.append(f"<td class=num>{cell['hard_failure_count']}</td>")
            parts.append(f"<td>{html.escape(metrics_text)}</td>")
            parts.append(f"<td>{html.escape(draft_text)}</td>")
            parts.append(f"<td>{html.escape(cell.get('candidate_source') or '—')}</td>")
            parts.append("</tr>")
        parts.append("</tbody></table>")

    parts.append("<h2>All runs</h2>")
    parts.append("<table><thead><tr>"
                 "<th>Time (UTC)</th><th>Workload</th>"
                 "<th>Corpus</th><th>RAM tier</th><th>RAM source</th><th>Cell source</th><th>Host RAM</th><th>Cell</th>"
                 "<th class=num>Status</th><th class=num>TTFT</th><th class=num>Total</th>"
                 "<th class=num>In</th><th class=num>Out</th><th class=num>tok/s</th>"
                 "<th>Notes</th>"
                 "</tr></thead><tbody>")
    for r in rows:
        is_err = (r["http_status"] != 200) or bool(r["error"])
        row_cls = " class=errrow" if is_err else ""
        time_only = r["ts_utc"][11:19]
        notes_bits = []
        if r["error"]:
            notes_bits.append(f"<span class=bad>{html.escape(r['error'][:120])}</span>")
        if r["stop_token_leak"]:
            notes_bits.append("<span class=bad>stop-token leak</span>")
        metric_reason = row_get(r, "metric_unavailable_reason")
        if metric_reason:
            notes_bits.append(f"<span class=muted>{html.escape(metric_reason)}</span>")
        non_runnable_reason = row_get(r, "non_runnable_reason")
        if non_runnable_reason:
            notes_bits.append(f"<span class=bad>{html.escape(non_runnable_reason)}</span>")
        if r["response_preview"] and not r["error"]:
            notes_bits.append(f"<span class=preview>{html.escape(r['response_preview'][:120])}</span>")
        notes = " · ".join(notes_bits) if notes_bits else "<span class=muted>—</span>"
        parts.append(f"<tr{row_cls}>")
        parts.append(f"<td>{time_only}</td>")
        parts.append(f"<td>{html.escape(r['workload'])}</td>")
        parts.append(f"<td>{html.escape(row_get(r, 'corpus_class', '—') or '—')}</td>")
        parts.append(f"<td>{html.escape(row_get(r, 'ram_tier_key', '—') or '—')}</td>")
        parts.append(f"<td>{html.escape(row_get(r, 'provider_ram_source', '—') or '—')}</td>")
        parts.append(f"<td>{html.escape(row_get(r, 'cell_execution_source', '—') or '—')}</td>")
        host_ram = row_get(r, "host_ram_bytes")
        parts.append(f"<td>{html.escape(fmt(host_ram))}</td>")
        cell_bits = []
        if row_get(r, "kv_bits") is not None:
            cell_bits.append(f"kv_bits={row_get(r, 'kv_bits')}")
        if row_get(r, "max_context_override") is not None:
            cell_bits.append(f"context={row_get(r, 'max_context_override')}")
        if row_get(r, "max_concurrency_override") is not None:
            cell_bits.append(f"concurrency={row_get(r, 'max_concurrency_override')}")
        if row_get(r, "draft_model"):
            cell_bits.append(f"draft={row_get(r, 'draft_model')}")
        if row_get(r, "num_draft_tokens") is not None:
            cell_bits.append(f"draft_tokens={row_get(r, 'num_draft_tokens')}")
        if row_get(r, "candidate_source"):
            cell_bits.append(f"source={row_get(r, 'candidate_source')}")
        parts.append(f"<td>{html.escape(', '.join(cell_bits) if cell_bits else '—')}</td>")
        parts.append(f"<td class=num>{r['http_status'] if r['http_status'] is not None else '—'}</td>")
        parts.append(f"<td class=num>{fmt(r['ttft_ms'], ' ms', 0)}</td>")
        parts.append(f"<td class=num>{fmt(r['total_ms'], ' ms', 0)}</td>")
        parts.append(f"<td class=num>{r['prompt_tokens'] if r['prompt_tokens'] is not None else '—'}</td>")
        parts.append(f"<td class=num>{r['completion_tokens'] if r['completion_tokens'] is not None else '—'}</td>")
        parts.append(f"<td class=num>{fmt(r['throughput_tps'], '', 1)}</td>")
        parts.append(f"<td>{notes}</td>")
        parts.append("</tr>")
    parts.append("</tbody></table>")

    parts.append(f"<p class=muted>Generated for UTC date {html.escape(date_iso)}</p>")
    parts.append("</body></html>")
    return "".join(parts)


def write_report(date_iso: str, conn: sqlite3.Connection, out_dir: Path) -> Path:
    rows = fetch_rows(conn, date_iso)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{date_iso}.html"
    out_path.write_text(render(date_iso, rows))
    spec029_cells = spec029.cells_from_rows(rows)
    if spec029_cells:
        json_path = out_dir / f"{date_iso}.spec029.json"
        summary = spec029.class_aware_report(spec029_cells, f"beta-report-{date_iso}")
        summary["raw_trials"] = [spec029.trial_row_json(row) for row in rows]
        json_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    return out_path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=str(DEFAULT_CONFIG))
    ap.add_argument("--date", help="UTC date as YYYY-MM-DD (default: today)")
    ap.add_argument("--all", action="store_true", help="rebuild a report for every date with data")
    args = ap.parse_args()

    if args.date and not re.match(r'^\d{4}-\d{2}-\d{2}$', args.date):
        sys.exit(f"--date must be YYYY-MM-DD, got: {args.date!r}")

    cfg = load_config(Path(args.config))
    db_path = BETA_DIR / cfg.get("db_path", "runs.sqlite")
    if not db_path.exists():
        sys.exit(f"no db at {db_path}; run harness.py first")
    conn = sqlite3.connect(db_path)
    try:
        out_dir = BETA_DIR / cfg.get("reports_dir", "reports")

        if args.all:
            dates = distinct_dates(conn)
        elif args.date:
            dates = [args.date]
        else:
            dates = [datetime.now(timezone.utc).date().isoformat()]

        for d in dates:
            path = write_report(d, conn, out_dir)
            print(path)
        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())

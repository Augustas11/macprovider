#!/usr/bin/env python3
"""
Context × concurrency sweep heatmap report.

Reads sweep_runs for a given sweep_id (or the latest sweep) and renders a
single-file self-contained HTML heatmap. Matches report.py style.

Rows: concurrency level
Cols: context target (tokens)
Each cell: green (feasible) / red (failed), showing agg_throughput_tps and ttft_p95_ms.

Usage:
    python beta/sweep_report.py                        # latest sweep_id
    python beta/sweep_report.py --sweep-id <uuid>      # specific sweep
    python beta/sweep_report.py --config beta/config-m1.yaml
"""

from __future__ import annotations

import argparse
import html
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml

BETA_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG = BETA_DIR / "config-m1.yaml"


def load_config(path: Path) -> dict:
    with path.open() as f:
        return yaml.safe_load(f)


def fetch_sweep_rows(conn: sqlite3.Connection, sweep_id: str) -> list[sqlite3.Row]:
    cur = conn.cursor()
    cur.row_factory = sqlite3.Row
    cur.execute(
        "SELECT * FROM sweep_runs WHERE sweep_id = ? ORDER BY context_target, concurrency",
        (sweep_id,),
    )
    return cur.fetchall()


def latest_sweep_id(conn: sqlite3.Connection) -> str | None:
    cur = conn.execute(
        "SELECT sweep_id FROM sweep_runs ORDER BY ts_utc DESC LIMIT 1"
    )
    row = cur.fetchone()
    return row[0] if row else None


def fmt_val(v: Any, digits: int = 1, suffix: str = "") -> str:
    if v is None:
        return "—"
    if isinstance(v, float):
        return f"{v:.{digits}f}{suffix}"
    return f"{v}{suffix}"


CSS = """
body {
  font: 14px/1.45 -apple-system, system-ui, sans-serif;
  margin: 2em;
  max-width: 1100px;
  color: #222;
}
h1 { font-size: 1.4em; margin-bottom: 0; }
h2 { font-size: 1.1em; margin-top: 2em; border-bottom: 1px solid #ccc; padding-bottom: 0.2em; }
.meta { color: #666; font-size: 0.9em; margin-top: 0.2em; }
table { border-collapse: collapse; margin-top: 1em; }
th, td {
  border: 1px solid #ddd;
  padding: 8px 12px;
  text-align: center;
  font-variant-numeric: tabular-nums;
  min-width: 90px;
}
th { background: #f6f6f6; font-weight: 600; }
th.row-header { text-align: left; min-width: 110px; }
td.row-header { text-align: left; font-weight: 600; background: #f6f6f6; }
.cell-ok {
  background: #d4edda;
  color: #155724;
}
.cell-fail {
  background: #f8d7da;
  color: #721c24;
}
.cell-empty {
  background: #f9f9f9;
  color: #aaa;
}
.tps { font-size: 1.1em; font-weight: 700; }
.ttft { font-size: 0.85em; color: inherit; opacity: 0.85; }
.summary { display: flex; gap: 2em; margin: 1em 0; }
.summary div { background: #f6f6f6; padding: 0.6em 1em; border-radius: 6px; }
.summary .label { font-size: 0.8em; color: #666; text-transform: uppercase; letter-spacing: 0.05em; }
.summary .value { font-size: 1.4em; font-weight: 600; }
.muted { color: #888; }
.legend { display: flex; gap: 1.5em; margin-top: 0.8em; font-size: 0.9em; align-items: center; }
.swatch { width: 18px; height: 18px; display: inline-block; border-radius: 3px; vertical-align: middle; margin-right: 4px; }
.swatch-ok { background: #d4edda; border: 1px solid #c3e6cb; }
.swatch-fail { background: #f8d7da; border: 1px solid #f5c6cb; }
.raw-table table { font-size: 12px; }
.raw-table th, .raw-table td { padding: 4px 8px; min-width: 60px; }
"""


def render(rows: list[sqlite3.Row], sweep_id: str) -> str:
    if not rows:
        return f"<html><body><p>No data for sweep_id={html.escape(sweep_id)}</p></body></html>"

    model = rows[0]["model"]
    ts_first = rows[0]["ts_utc"]
    n_cells = len(rows)
    n_feasible = sum(1 for r in rows if r["feasible"])
    n_fail = n_cells - n_feasible

    context_targets = sorted(set(r["context_target"] for r in rows))
    concurrencies = sorted(set(r["concurrency"] for r in rows))
    max_tokens_vals = sorted(set(r["max_tokens"] for r in rows))

    # Index rows: (context_target, concurrency, max_tokens) -> row
    cell_map: dict[tuple, sqlite3.Row] = {}
    for r in rows:
        cell_map[(r["context_target"], r["concurrency"], r["max_tokens"])] = r

    parts: list[str] = []
    parts.append(
        f'<!doctype html><html><head><meta charset=utf-8>'
        f'<title>Sweep — {html.escape(sweep_id[:8])}</title>'
        f'<style>{CSS}</style></head><body>'
    )
    parts.append(f'<h1>Context &times; Concurrency Throughput Sweep</h1>')
    parts.append(
        f'<div class=meta>sweep_id: <code>{html.escape(sweep_id)}</code> &nbsp;|&nbsp; '
        f'model: <code>{html.escape(model)}</code> &nbsp;|&nbsp; '
        f'started: <code>{html.escape(ts_first)}</code></div>'
    )

    # Summary bar
    parts.append('<div class=summary>')
    parts.append(f'<div><div class=label>Total cells</div><div class=value>{n_cells}</div></div>')
    parts.append(f'<div><div class=label>Feasible</div><div class=value style="color:#155724">{n_feasible}</div></div>')
    fail_color = '#721c24' if n_fail else '#155724'
    parts.append(f'<div><div class=label>Failed</div><div class=value style="color:{fail_color}">{n_fail}</div></div>')
    parts.append('</div>')

    # Legend
    parts.append(
        '<div class=legend>'
        '<span><span class="swatch swatch-ok"></span>Feasible: n_err=0, ttft_p95 within gate, no stop-token leak</span>'
        '<span><span class="swatch swatch-fail"></span>Failed: at least one gate condition missed</span>'
        '</div>'
    )

    # One heatmap per max_tokens pass
    for mt in max_tokens_vals:
        parts.append(f'<h2>Heatmap &mdash; max_tokens={mt}</h2>')
        parts.append('<p class=meta>Rows: concurrency &nbsp;|&nbsp; Cols: context target (tokens) '
                     '&nbsp;|&nbsp; Cell: <strong>tok/s (aggregate)</strong> / ttft_p95</p>')
        parts.append('<table>')

        # Header row
        parts.append('<thead><tr>')
        parts.append('<th class=row-header>Concurrency \\ Context</th>')
        for ctx in context_targets:
            parts.append(f'<th>{ctx:,}</th>')
        parts.append('</tr></thead>')

        parts.append('<tbody>')
        for conc in concurrencies:
            parts.append('<tr>')
            parts.append(f'<td class=row-header>conc={conc}</td>')
            for ctx in context_targets:
                cell = cell_map.get((ctx, conc, mt))
                if cell is None:
                    parts.append('<td class=cell-empty>—</td>')
                    continue
                feasible = bool(cell["feasible"])
                cls = "cell-ok" if feasible else "cell-fail"
                tps_str = fmt_val(cell["agg_throughput_tps"], 1, " t/s")
                ttft_str = fmt_val(cell["ttft_p95_ms"], 0, " ms")
                ok_err = f'<div class=ttft>ok={cell["n_ok"]} err={cell["n_err"]}</div>'
                parts.append(
                    f'<td class={cls}>'
                    f'<div class=tps>{html.escape(tps_str)}</div>'
                    f'<div class=ttft>ttft_p95: {html.escape(ttft_str)}</div>'
                    f'{ok_err}'
                    f'</td>'
                )
            parts.append('</tr>')
        parts.append('</tbody></table>')

    # Raw data table
    parts.append('<h2>Raw sweep_runs rows</h2>')
    parts.append('<div class=raw-table>')
    parts.append(
        '<table><thead><tr>'
        '<th>context_target</th><th>concurrency</th><th>max_tokens</th>'
        '<th>prompt_tok</th><th>agg_tps</th><th>ttft_p95_ms</th>'
        '<th>n_ok</th><th>n_err</th><th>feasible</th><th>ts_utc</th>'
        '</tr></thead><tbody>'
    )
    for r in rows:
        feasible_str = '<span style="color:#155724">yes</span>' if r["feasible"] else '<span style="color:#721c24">no</span>'
        parts.append(
            f'<tr>'
            f'<td>{r["context_target"]:,}</td>'
            f'<td>{r["concurrency"]}</td>'
            f'<td>{r["max_tokens"]}</td>'
            f'<td>{r["measured_prompt_tokens"] or "—"}</td>'
            f'<td>{fmt_val(r["agg_throughput_tps"], 1)}</td>'
            f'<td>{fmt_val(r["ttft_p95_ms"], 0)}</td>'
            f'<td>{r["n_ok"]}</td>'
            f'<td>{r["n_err"]}</td>'
            f'<td>{feasible_str}</td>'
            f'<td style="font-size:11px">{html.escape(r["ts_utc"])}</td>'
            f'</tr>'
        )
    parts.append('</tbody></table></div>')

    parts.append(
        f'<p class=muted>Generated {datetime.now(timezone.utc).isoformat(timespec="seconds")}</p>'
    )
    parts.append('</body></html>')
    return "".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser(description="Render HTML heatmap from sweep_runs table")
    ap.add_argument("--config", default=str(DEFAULT_CONFIG))
    ap.add_argument("--sweep-id", default=None, help="Sweep ID to report on (default: latest)")
    ap.add_argument("--list", action="store_true", help="List all sweep_ids in the DB and exit")
    args = ap.parse_args()

    cfg = load_config(Path(args.config))
    db_path = BETA_DIR / cfg.get("db_path", "runs.sqlite")

    if not db_path.exists():
        sys.exit(f"no db at {db_path}; run sweep.py first")

    conn = sqlite3.connect(db_path)
    try:
        # Ensure sweep_runs table exists (idempotent)
        conn.executescript(
            "CREATE TABLE IF NOT EXISTS sweep_runs ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, ts_utc TEXT NOT NULL, sweep_id TEXT NOT NULL,"
            "model TEXT NOT NULL, context_target INTEGER NOT NULL, measured_prompt_tokens INTEGER,"
            "concurrency INTEGER NOT NULL, max_tokens INTEGER NOT NULL,"
            "agg_throughput_tps REAL, ttft_p95_ms REAL, n_ok INTEGER NOT NULL,"
            "n_err INTEGER NOT NULL, feasible INTEGER NOT NULL DEFAULT 0, notes TEXT);"
        )

        if args.list:
            cur = conn.execute(
                "SELECT sweep_id, COUNT(*) as n, MIN(ts_utc) as started "
                "FROM sweep_runs GROUP BY sweep_id ORDER BY started DESC"
            )
            rows = cur.fetchall()
            if not rows:
                print("No sweep runs in DB.")
                return 0
            for r in rows:
                print(f"{r[0]}  n={r[1]}  started={r[2]}")
            return 0

        sweep_id = args.sweep_id or latest_sweep_id(conn)
        if not sweep_id:
            sys.exit("No sweep_runs in DB. Run sweep.py first.")

        rows = fetch_sweep_rows(conn, sweep_id)
        if not rows:
            sys.exit(f"No rows for sweep_id={sweep_id}")

        out_dir = BETA_DIR / cfg.get("reports_dir", "reports")
        out_dir.mkdir(parents=True, exist_ok=True)
        out_path = out_dir / f"sweep-{sweep_id[:8]}.html"
        out_path.write_text(render(rows, sweep_id))
        print(f"Report written: {out_path}")
        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())

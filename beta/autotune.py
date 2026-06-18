#!/usr/bin/env python3
"""
Provider-side model autotune — a REAL keep/revert hill-climb that discovers the
optimal servable model for THIS Mac.

This is NOT a static benchmark. It is a genuine optimization loop:

    propose config  ->  measure metric  ->  keep-if-better  ->  log trial
                                              |
                                              +-> track best-so-far

The only PROVIDER-SIDE serving knob the binary exposes today is MODEL CHOICE
(size x quant). There are no KV-cache / batch / max-context flags yet (those are
a separate future Swift change). So this loop hill-climbs over the MODEL
dimension. The candidate space is the cross product of --models x --contexts;
each (model, context) pair is one candidate config the loop proposes, evaluates,
and keeps-or-reverts.

How the keep/revert loop works
------------------------------
1. Enumerate candidates (model x context). Optionally shuffle is NOT used — the
   order is deterministic so reruns are comparable.
2. For each candidate:
     a. Start the provider binary serving that model (one process, port 18080).
     b. Wait for readiness (GET /v1/models succeeds), up to --ready-timeout.
     c. Fire a fixed workload at the target context (concurrency=1,
        max_tokens small) and measure agg throughput_tps + ttft_p95.
     d. Feasibility gate: any request error / non-200 / load failure / OOM
        => fits=0 (INFEASIBLE). A model that OOMs at a context is a VALID
        recorded trial, not a tool failure.
     e. STOP the provider (pkill) and wait for :18080 to free BEFORE the next
        candidate. Never two providers at once.
3. Maintain `best` = the FEASIBLE candidate with the highest throughput_tps.
   - If this trial is feasible AND beats best  -> kept=1 (NEW BEST), best updated.
   - Otherwise                                 -> kept=0 (reverted; best held).
4. Persist one row per trial to the tune_trials table.
5. At the end, declare the WINNER (best feasible model+context) and render a
   self-contained HTML report mirroring sweep_report.py.

Reuse (does NOT modify these):
  - harness.fire_stream            : per-request SSE metrics (ttft, throughput).
  - sweep.build_padded_prompt      : padded prompt at a target context.
  - sweep.aggregate_cell           : same aggregation + feasibility shape.

Usage
-----
    # Dry-run: print the candidate plan, serve nothing
    python beta/autotune.py --dry-run

    # First hill-climb on this Mac (default 3 models x 2 contexts)
    python beta/autotune.py --contexts 2000,8000

    # Custom model list
    python beta/autotune.py --models mlx-community/Llama-3.2-1B-Instruct-4bit

    # Render the report for the latest run
    python beta/autotune.py --report-only
"""

from __future__ import annotations

import argparse
import html
import signal
import sqlite3
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import requests

# Resolve beta/ on sys.path so we can import sibling modules.
BETA_DIR = Path(__file__).resolve().parent
if str(BETA_DIR) not in sys.path:
    sys.path.insert(0, str(BETA_DIR))

# Reuse the SSE parser (all Phase 1 quirk handling) and the padded-prompt builder
# + the cell aggregator. We do NOT modify harness.py or sweep.py.
from harness import fire_stream  # noqa: E402
from sweep import build_padded_prompt, aggregate_cell  # noqa: E402

# ---------------------------------------------------------------------------
# Defaults — machine-agnostic. The only baked-in assumption is the default
# candidate set; everything is overridable via flags.
# ---------------------------------------------------------------------------

# Provider binary that serves an MLX model + joins the coordinator pool. Joining
# is a harmless side effect (it holds `ready`); we do not modify its config.
DEFAULT_PROVIDER_BIN = str(Path.home() / "macprovider" / "macprovider-cli")
DEFAULT_PORT = 18080

# Default candidate models: all small 4-bit instruct models. 3B + Phi-3.5-mini
# are already in the HF cache on most dev Macs; 1B downloads on first serve
# (~0.7GB). Keep downloads minimal — only what the candidate set requires.
DEFAULT_MODELS = [
    "mlx-community/Llama-3.2-1B-Instruct-4bit",
    "mlx-community/Llama-3.2-3B-Instruct-4bit",
    "mlx-community/Phi-3.5-mini-instruct-4bit",
]
DEFAULT_CONTEXTS = [2000, 8000]
DEFAULT_MAX_TOKENS = 48  # short decode: we measure SERVING (prefill), not generation
DEFAULT_READY_TIMEOUT = 150  # seconds to wait for model load on a constrained Mac

# Feasibility TTFT gate. Unlike the context sweep we are NOT trying to find a
# latency ceiling here — we want fits to reflect "does this model serve at all at
# this context", so the gate is generous. A request error / non-200 / OOM is the
# real INFEASIBLE signal. Override with --gate-ttft-ms if you want a stricter SLA.
DEFAULT_GATE_TTFT_MS = 60000.0

TUNE_SCHEMA = """
CREATE TABLE IF NOT EXISTS tune_trials (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc TEXT NOT NULL,
    run_id TEXT NOT NULL,
    model TEXT NOT NULL,
    target_context INTEGER NOT NULL,
    measured_prompt_tokens INTEGER,
    max_tokens INTEGER NOT NULL,
    agg_throughput_tps REAL,
    ttft_p95_ms REAL,
    fits INTEGER NOT NULL DEFAULT 0,
    n_err INTEGER NOT NULL DEFAULT 0,
    kept INTEGER NOT NULL DEFAULT 0,
    notes TEXT,
    kv_bits INTEGER,
    max_context_cap INTEGER,
    max_batch INTEGER
);
CREATE INDEX IF NOT EXISTS idx_tune_trials_run_id ON tune_trials(run_id);
CREATE INDEX IF NOT EXISTS idx_tune_trials_ts ON tune_trials(ts_utc);
"""

# Columns added after the initial spike for the richer per-hardware-recipe
# search (PR #105 exposed --kv-bits / --max-context / --max-batch as serve
# flags). On an existing DB the CREATE TABLE IF NOT EXISTS above is a no-op,
# so we additively ALTER each new column in; the try/except handles "duplicate
# column" without needing SQLite 3.35+'s IF NOT EXISTS clause.
_ADDITIVE_TUNE_COLUMNS = (
    ("kv_bits", "INTEGER"),
    ("max_context_cap", "INTEGER"),
    ("max_batch", "INTEGER"),
)


# ---------------------------------------------------------------------------
# DB helpers — additive only. Never touches runs / adversarial_runs / sweep_runs.
# ---------------------------------------------------------------------------

def open_db(db_path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    conn.executescript(TUNE_SCHEMA)
    for col, sql_type in _ADDITIVE_TUNE_COLUMNS:
        try:
            conn.execute(f"ALTER TABLE tune_trials ADD COLUMN {col} {sql_type}")
        except sqlite3.OperationalError:
            pass  # already added on a prior run
    conn.commit()
    return conn


def write_trial_row(conn: sqlite3.Connection, row: dict) -> None:
    conn.execute(
        """INSERT INTO tune_trials
               (ts_utc, run_id, model, target_context, measured_prompt_tokens,
                max_tokens, agg_throughput_tps, ttft_p95_ms, fits, n_err, kept, notes,
                kv_bits, max_context_cap, max_batch)
           VALUES
               (:ts_utc, :run_id, :model, :target_context, :measured_prompt_tokens,
                :max_tokens, :agg_throughput_tps, :ttft_p95_ms, :fits, :n_err, :kept, :notes,
                :kv_bits, :max_context_cap, :max_batch)""",
        row,
    )
    conn.commit()


# ---------------------------------------------------------------------------
# Provider lifecycle — start serving one model, wait until ready, stop cleanly.
# Invariant: NEVER two providers at once. Always stop before the next candidate.
# ---------------------------------------------------------------------------

def port_is_listening(port: int) -> bool:
    """True if something is accepting TCP on 127.0.0.1:<port>."""
    import socket

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


def stop_provider(port: int, settle_s: float = 30.0) -> None:
    """Kill any running provider and wait for the port to free.

    Uses pkill on the serve command so we catch the binary even if our own
    Popen handle is stale. Idempotent — safe to call when nothing is running.
    """
    subprocess.run(
        ["pkill", "-f", "macprovider-cli serve"],
        capture_output=True,
        check=False,
    )
    deadline = time.monotonic() + settle_s
    while time.monotonic() < deadline:
        if not port_is_listening(port):
            return
        time.sleep(0.5)
    # Escalate to SIGKILL if a process is wedged holding the port.
    subprocess.run(
        ["pkill", "-9", "-f", "macprovider-cli serve"],
        capture_output=True,
        check=False,
    )
    time.sleep(2.0)


def start_provider(
    provider_bin: str,
    model: str,
    port: int,
    log_path: Path,
    kv_bits: int | None = None,
    max_context_cap: int | None = None,
    max_batch: int | None = None,
) -> subprocess.Popen:
    """Launch `macprovider-cli serve --model <model> --port <port>` in background.

    stdout/stderr are teed to log_path so a load failure / OOM leaves evidence.
    The process is started in its own session so we can signal the whole group.
    Optional serving knobs (kv_bits, max_context_cap, max_batch) are passed to
    the binary only when set, so older binaries without those flags still work
    for the default search path.
    """
    log_fh = log_path.open("wb")
    cmd = [provider_bin, "serve", "--model", model, "--port", str(port)]
    # Optional serving knobs (PR #105). Each is appended only when set so an
    # older binary still works for the default-flag path.
    if kv_bits is not None:
        cmd += ["--kv-bits", str(kv_bits)]
    if max_context_cap is not None:
        cmd += ["--max-context", str(max_context_cap)]
    if max_batch is not None:
        cmd += ["--max-batch", str(max_batch)]
    proc = subprocess.Popen(
        cmd,
        stdout=log_fh,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    return proc


def wait_for_ready(
    base_url: str,
    proc: subprocess.Popen,
    timeout_s: float,
) -> tuple[bool, str]:
    """Poll GET /v1/models until 200, the process dies, or timeout.

    Returns (ready, note). note carries the failure reason when not ready
    (process exited / load error / timeout) so it can land in the trial row.
    """
    models_url = base_url.rstrip("/") + "/v1/models"
    deadline = time.monotonic() + timeout_s
    last_err = ""
    while time.monotonic() < deadline:
        # If the provider process already exited, the model failed to load
        # (OOM, missing weights, bad id). That's an INFEASIBLE trial.
        rc = proc.poll()
        if rc is not None:
            return False, f"provider exited rc={rc} during load (see log for cause)"
        try:
            r = requests.get(models_url, timeout=5)
            if r.status_code == 200:
                return True, "ready"
            last_err = f"/v1/models -> HTTP {r.status_code}"
        except requests.RequestException as e:
            last_err = f"{type(e).__name__}"
        time.sleep(2.0)
    return False, f"ready timeout after {timeout_s:.0f}s (last: {last_err or 'no response'})"


# ---------------------------------------------------------------------------
# Evaluate one candidate config (model, context). Returns a metrics dict.
# ---------------------------------------------------------------------------

def evaluate_candidate(
    provider_bin: str,
    model: str,
    context: int,
    port: int,
    max_tokens: int,
    ready_timeout: float,
    request_timeout: float,
    gate_ttft_ms: float,
    log_dir: Path,
    verbose: bool,
    kv_bits: int | None = None,
    max_context_cap: int | None = None,
    max_batch: int | None = None,
) -> dict[str, Any]:
    """Start provider for `model` (with the optional serving knobs applied),
    fire a workload at `context`, stop provider.

    Always stops the provider before returning (success or failure path), so the
    caller can move straight to the next candidate. Returns:
        fits, n_err, agg_throughput_tps, ttft_p95_ms, measured_prompt_tokens, notes
    """
    base_url = f"http://127.0.0.1:{port}"
    chat_url = base_url + "/v1/chat/completions"
    safe_model = model.replace("/", "_")
    knob_tag = _knob_tag(kv_bits, max_context_cap, max_batch)
    log_path = log_dir / f"provider-{safe_model}-ctx{context}{knob_tag}.log"

    # Defensive: ensure nothing is already bound before we start.
    if port_is_listening(port):
        stop_provider(port)

    proc = start_provider(
        provider_bin, model, port, log_path,
        kv_bits=kv_bits, max_context_cap=max_context_cap, max_batch=max_batch,
    )
    try:
        ready, note = wait_for_ready(base_url, proc, ready_timeout)
        if not ready:
            # Load failure / OOM / timeout => infeasible trial (valid record).
            tail = _tail_log(log_path)
            full_note = note + (f" | log: {tail}" if tail else "")
            return {
                "fits": 0,
                "n_err": 1,
                "agg_throughput_tps": None,
                "ttft_p95_ms": None,
                "measured_prompt_tokens": None,
                "notes": full_note[:480],
            }

        # Provider is up. Fire one streamed request at the target context.
        body = build_padded_prompt(context, max_tokens)
        wall_t0 = time.monotonic()
        result = fire_stream(chat_url, model, body, request_timeout)
        wall_seconds = time.monotonic() - wall_t0

        # Reuse sweep.aggregate_cell with a single-result "cell". It computes
        # agg_throughput_tps (completion tokens / wall), ttft_p95, n_err, and a
        # feasibility flag (n_err==0 AND ttft within gate AND no stop-token leak).
        cell = {"wall_seconds": wall_seconds, "results": [result]}
        agg = aggregate_cell(cell, gate_ttft_ms)

        notes = None
        if agg["n_err"]:
            err = result.get("error") or f"HTTP {result.get('http_status')}"
            notes = f"request error: {str(err)[:200]}"
        elif not agg["feasible"]:
            notes = f"missed gate: ttft_p95={agg['ttft_p95_ms']}ms > {gate_ttft_ms}ms"

        return {
            "fits": int(agg["feasible"]),
            "n_err": agg["n_err"],
            "agg_throughput_tps": agg["agg_throughput_tps"],
            "ttft_p95_ms": agg["ttft_p95_ms"],
            "measured_prompt_tokens": agg["measured_prompt_tokens"],
            "notes": notes,
        }
    finally:
        # INVARIANT: stop the provider before returning, always.
        stop_provider(port)


def _knob_tag(kv_bits: int | None, max_context_cap: int | None, max_batch: int | None) -> str:
    """Compact tag suffix for log filenames and printed trial lines when any
    optional serving knob is set. Returns "" if all are None (preserves the
    pre-PR-105 log filenames + line shape exactly)."""
    parts = []
    if kv_bits is not None:
        parts.append(f"kv{kv_bits}")
    if max_context_cap is not None:
        parts.append(f"mx{max_context_cap}")
    if max_batch is not None:
        parts.append(f"mb{max_batch}")
    return ("-" + "-".join(parts)) if parts else ""


def _tail_log(log_path: Path, n_chars: int = 240) -> str:
    """Pull the most informative line out of a provider launch log.

    The binary prints its fatal reason on an `Error:` / `error` line (e.g.
    "Offline mode error: Repository not available locally" for an
    un-downloaded model, or an MLX OOM message) and then echoes its config
    block. A naive last-N-chars tail would capture the config echo, not the
    cause — so prefer the first error-ish line, falling back to the tail.
    """
    try:
        text = log_path.read_text(errors="replace").strip()
    except OSError:
        return ""
    for line in text.splitlines():
        low = line.lower()
        if "error" in low or "oom" in low or "out of memory" in low or "traceback" in low:
            return " ".join(line.split())[:n_chars]
    # No explicit error line — fall back to the tail.
    return " ".join(text[-n_chars:].split())


# ---------------------------------------------------------------------------
# HTML report — mirrors sweep_report.py style (self-contained, Apple-system font).
# ---------------------------------------------------------------------------

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
table { border-collapse: collapse; margin-top: 1em; width: 100%; }
th, td {
  border: 1px solid #ddd;
  padding: 8px 12px;
  text-align: center;
  font-variant-numeric: tabular-nums;
}
th { background: #f6f6f6; font-weight: 600; }
td.left, th.left { text-align: left; }
.cell-ok { background: #d4edda; color: #155724; }
.cell-fail { background: #f8d7da; color: #721c24; }
.winner { background: #fff3cd; }
.winner td { font-weight: 700; }
.tps { font-weight: 700; }
.summary { display: flex; gap: 2em; margin: 1em 0; flex-wrap: wrap; }
.summary div { background: #f6f6f6; padding: 0.6em 1em; border-radius: 6px; }
.summary .label { font-size: 0.8em; color: #666; text-transform: uppercase; letter-spacing: 0.05em; }
.summary .value { font-size: 1.4em; font-weight: 600; }
.muted { color: #888; }
.legend { display: flex; gap: 1.5em; margin-top: 0.8em; font-size: 0.9em; align-items: center; }
.swatch { width: 18px; height: 18px; display: inline-block; border-radius: 3px; vertical-align: middle; margin-right: 4px; }
.swatch-ok { background: #d4edda; border: 1px solid #c3e6cb; }
.swatch-fail { background: #f8d7da; border: 1px solid #f5c6cb; }
.swatch-win { background: #fff3cd; border: 1px solid #ffeeba; }
.kept-yes { color: #155724; font-weight: 700; }
.kept-no { color: #888; }
code { background: #f0f0f0; padding: 0 3px; border-radius: 3px; }
"""


def fmt_val(v: Any, digits: int = 1, suffix: str = "") -> str:
    if v is None:
        return "—"
    if isinstance(v, float):
        return f"{v:.{digits}f}{suffix}"
    return f"{v}{suffix}"


def render_report(rows: list[sqlite3.Row], run_id: str) -> str:
    if not rows:
        return f"<html><body><p>No trials for run_id={html.escape(run_id)}</p></body></html>"

    ts_first = rows[0]["ts_utc"]
    n_trials = len(rows)
    feasible_rows = [r for r in rows if r["fits"]]
    n_feasible = len(feasible_rows)
    n_infeasible = n_trials - n_feasible

    # Winner = feasible trial with highest tps (the final `best`).
    winner = None
    for r in feasible_rows:
        if r["agg_throughput_tps"] is None:
            continue
        if winner is None or r["agg_throughput_tps"] > winner["agg_throughput_tps"]:
            winner = r

    p: list[str] = []
    p.append(
        f'<!doctype html><html><head><meta charset=utf-8>'
        f'<title>Autotune — {html.escape(run_id[:8])}</title>'
        f'<style>{CSS}</style></head><body>'
    )
    p.append('<h1>Provider Model Autotune &mdash; keep/revert hill-climb</h1>')
    p.append(
        f'<div class=meta>run_id: <code>{html.escape(run_id)}</code> &nbsp;|&nbsp; '
        f'started: <code>{html.escape(ts_first)}</code> &nbsp;|&nbsp; '
        f'metric: <strong>agg throughput (tok/s)</strong>, higher is better</div>'
    )

    # Summary bar
    p.append('<div class=summary>')
    p.append(f'<div><div class=label>Trials</div><div class=value>{n_trials}</div></div>')
    p.append(f'<div><div class=label>Feasible</div><div class=value style="color:#155724">{n_feasible}</div></div>')
    inf_color = '#721c24' if n_infeasible else '#155724'
    p.append(f'<div><div class=label>Infeasible</div><div class=value style="color:{inf_color}">{n_infeasible}</div></div>')
    if winner is not None:
        p.append(
            f'<div><div class=label>Winner</div>'
            f'<div class=value style="color:#856404">'
            f'{html.escape(winner["model"].split("/")[-1])} @ {winner["target_context"]:,}'
            f'</div></div>'
        )
    p.append('</div>')

    if winner is not None:
        p.append(
            f'<p>&#127942; <strong>WINNER:</strong> <code>{html.escape(winner["model"])}</code> '
            f'at target context <strong>{winner["target_context"]:,}</strong> tokens &mdash; '
            f'<strong>{fmt_val(winner["agg_throughput_tps"], 1, " tok/s")}</strong> '
            f'(ttft {fmt_val(winner["ttft_p95_ms"], 0, " ms")}, '
            f'measured prompt {winner["measured_prompt_tokens"] or "—"} tokens).</p>'
        )
    else:
        p.append('<p><strong>No feasible config found.</strong> Every candidate '
                 'errored / OOM&rsquo;d / missed the gate at the tested contexts.</p>')

    p.append(
        '<div class=legend>'
        '<span><span class="swatch swatch-win"></span>Winner (best feasible tps)</span>'
        '<span><span class="swatch swatch-ok"></span>Feasible (served, no error)</span>'
        '<span><span class="swatch swatch-fail"></span>Infeasible (error / OOM / gate miss)</span>'
        '</div>'
    )

    # Trial log with best-so-far progression. Recompute best-so-far in row order
    # to show how the optimum evolved across the climb.
    p.append('<h2>Trial log (best-so-far progression)</h2>')
    p.append('<table><thead><tr>'
             '<th class=left>#</th><th class=left>model</th><th>target ctx</th>'
             '<th>prompt tok</th><th>tok/s</th><th>ttft (ms)</th>'
             '<th>fits</th><th>n_err</th><th>kept</th><th>best-so-far tok/s</th>'
             '</tr></thead><tbody>')
    best_tps_so_far: float | None = None
    best_label_so_far = "—"
    for i, r in enumerate(rows, 1):
        is_winner = winner is not None and r["id"] == winner["id"]
        if r["fits"] and r["agg_throughput_tps"] is not None:
            if best_tps_so_far is None or r["agg_throughput_tps"] > best_tps_so_far:
                best_tps_so_far = r["agg_throughput_tps"]
                best_label_so_far = f'{r["model"].split("/")[-1]} @ {r["target_context"]:,}'
        row_cls = "winner" if is_winner else ("cell-ok" if r["fits"] else "cell-fail")
        kept_cls = "kept-yes" if r["kept"] else "kept-no"
        kept_txt = "NEW BEST" if r["kept"] else "reverted"
        bsf = (
            f'{fmt_val(best_tps_so_far, 1)} <span class=muted>({html.escape(best_label_so_far)})</span>'
            if best_tps_so_far is not None else '—'
        )
        p.append(
            f'<tr class={row_cls}>'
            f'<td class=left>{i}</td>'
            f'<td class=left><code>{html.escape(r["model"])}</code></td>'
            f'<td>{r["target_context"]:,}</td>'
            f'<td>{r["measured_prompt_tokens"] or "—"}</td>'
            f'<td class=tps>{fmt_val(r["agg_throughput_tps"], 1)}</td>'
            f'<td>{fmt_val(r["ttft_p95_ms"], 0)}</td>'
            f'<td>{"yes" if r["fits"] else "no"}</td>'
            f'<td>{r["n_err"]}</td>'
            f'<td class={kept_cls}>{kept_txt}</td>'
            f'<td>{bsf}</td>'
            f'</tr>'
        )
    p.append('</tbody></table>')

    # Notes column (failure reasons) for infeasible trials.
    infeasible_with_notes = [r for r in rows if not r["fits"] and r["notes"]]
    if infeasible_with_notes:
        p.append('<h2>Infeasible trial notes</h2>')
        p.append('<table><thead><tr><th class=left>model</th><th>ctx</th>'
                 '<th class=left>reason</th></tr></thead><tbody>')
        for r in infeasible_with_notes:
            p.append(
                f'<tr><td class=left><code>{html.escape(r["model"])}</code></td>'
                f'<td>{r["target_context"]:,}</td>'
                f'<td class=left>{html.escape(r["notes"] or "")}</td></tr>'
            )
        p.append('</tbody></table>')

    p.append(
        f'<p class=muted>Generated {datetime.now(timezone.utc).isoformat(timespec="seconds")} '
        f'&middot; one provider served at a time &middot; concurrency 1 &middot; '
        f'metric = completion tokens / wall seconds.</p>'
    )
    p.append('</body></html>')
    return "".join(p)


def fetch_trial_rows(conn: sqlite3.Connection, run_id: str) -> list[sqlite3.Row]:
    cur = conn.cursor()
    cur.row_factory = sqlite3.Row
    cur.execute(
        "SELECT * FROM tune_trials WHERE run_id = ? ORDER BY id",
        (run_id,),
    )
    return cur.fetchall()


def latest_run_id(conn: sqlite3.Connection) -> str | None:
    cur = conn.execute("SELECT run_id FROM tune_trials ORDER BY ts_utc DESC, id DESC LIMIT 1")
    row = cur.fetchone()
    return row[0] if row else None


def write_report(conn: sqlite3.Connection, run_id: str, reports_dir: Path) -> Path:
    rows = fetch_trial_rows(conn, run_id)
    reports_dir.mkdir(parents=True, exist_ok=True)
    out_path = reports_dir / f"autotune-{run_id}.html"
    out_path.write_text(render_report(rows, run_id))
    return out_path


# ---------------------------------------------------------------------------
# Main — the hill-climb driver.
# ---------------------------------------------------------------------------

def parse_str_list(s: str) -> list[str]:
    return [x.strip() for x in s.split(",") if x.strip()]


def parse_int_list(s: str) -> list[int]:
    return [int(x.strip()) for x in s.split(",") if x.strip()]


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Provider-side model autotune: keep/revert hill-climb over the model dimension.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument(
        "--models", default=None,
        help="Comma-separated HF model IDs to consider as candidates. "
             f"Default: the three small 4-bit instruct models "
             f"({', '.join(m.split('/')[-1] for m in DEFAULT_MODELS)}).",
    )
    ap.add_argument(
        "--contexts", default=None,
        help="Comma-separated target context token sizes. Each (model, context) "
             f"pair is one candidate. Default: {','.join(map(str, DEFAULT_CONTEXTS))}.",
    )
    ap.add_argument("--db-path", default=str(BETA_DIR / "runs.sqlite"),
                    help="SQLite DB path (default: beta/runs.sqlite).")
    ap.add_argument("--reports-dir", default=str(BETA_DIR / "reports"),
                    help="Directory for the HTML report (default: beta/reports).")
    ap.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS,
                    help=f"Decode length per request (default: {DEFAULT_MAX_TOKENS}). "
                         "Short on purpose — we measure serving (prefill), not generation.")
    ap.add_argument("--ready-timeout", type=float, default=DEFAULT_READY_TIMEOUT,
                    help=f"Seconds to wait for model load before declaring infeasible "
                         f"(default: {DEFAULT_READY_TIMEOUT}).")
    ap.add_argument("--gate-ttft-ms", type=float, default=DEFAULT_GATE_TTFT_MS,
                    help=f"Max p95 TTFT (ms) for the feasibility gate (default: "
                         f"{DEFAULT_GATE_TTFT_MS:.0f}). Generous by design — request "
                         "errors / OOM are the real infeasible signal.")
    ap.add_argument("--request-timeout", type=float, default=180.0,
                    help="Per-request HTTP timeout in seconds (default: 180).")
    ap.add_argument("--provider-bin", default=DEFAULT_PROVIDER_BIN,
                    help=f"Path to macprovider-cli (default: {DEFAULT_PROVIDER_BIN}).")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT,
                    help=f"Local port the provider binds (default: {DEFAULT_PORT}).")
    ap.add_argument("--dry-run", action="store_true",
                    help="Print the candidate plan and exit. Serves nothing.")
    ap.add_argument("--report-only", action="store_true",
                    help="Render the HTML report for the latest run_id and exit.")
    # Optional serving-knob axes (require a macprovider-cli binary built from
    # main with PR #105 — older binaries will fail load and the trial will be
    # recorded as INFEASIBLE, which is correct behavior). Each axis defaults
    # to a single null value so omitting all three preserves the original
    # model x context candidate space exactly.
    ap.add_argument(
        "--kv-bits-options", default=None,
        help="Comma-separated kv-bits values (e.g. '4,8') to hill-climb over. "
             "Forwarded to `macprovider-cli serve --kv-bits N`. Omit to leave "
             "KV-cache precision at the model default (single trial per axis).",
    )
    ap.add_argument(
        "--max-context-options", default=None,
        help="Comma-separated provider max-context caps (e.g. '4000,8000') to "
             "hill-climb over. Forwarded to `macprovider-cli serve --max-context N`. "
             "This is the SERVER-SIDE cap (bounds KV-cache size); distinct from "
             "--contexts which is the per-request prompt size axis.",
    )
    ap.add_argument(
        "--max-batch-options", default=None,
        help="Comma-separated max-batch values (e.g. '1,2') to hill-climb over. "
             "Forwarded to `macprovider-cli serve --max-batch N`. Default is 1.",
    )
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    db_path = Path(args.db_path)
    reports_dir = Path(args.reports_dir)

    # --report-only short-circuit (no serving).
    if args.report_only:
        if not db_path.exists():
            sys.exit(f"no db at {db_path}; run a tune first")
        conn = open_db(db_path)
        try:
            run_id = latest_run_id(conn)
            if not run_id:
                sys.exit("no tune_trials in DB yet")
            out_path = write_report(conn, run_id, reports_dir)
            print(f"Report written: {out_path}")
            return 0
        finally:
            conn.close()

    models = parse_str_list(args.models) if args.models else list(DEFAULT_MODELS)
    contexts = parse_int_list(args.contexts) if args.contexts else list(DEFAULT_CONTEXTS)
    # Optional serving-knob axes — each defaults to [None] (single "unset"
    # value, no flag passed), so omitting all three preserves the original
    # model x context candidate space exactly.
    kv_bits_axis: list[int | None] = (
        parse_int_list(args.kv_bits_options) if args.kv_bits_options else [None]
    )
    max_context_axis: list[int | None] = (
        parse_int_list(args.max_context_options) if args.max_context_options else [None]
    )
    max_batch_axis: list[int | None] = (
        parse_int_list(args.max_batch_options) if args.max_batch_options else [None]
    )

    # Candidate config space = model x context x kv_bits x max_context_cap x
    # max_batch, deterministic order. When all optional axes are unset this
    # collapses back to the original model x context shape (one row per pair).
    candidates = [
        (m, c, kv, mx, mb)
        for m in models
        for c in contexts
        for kv in kv_bits_axis
        for mx in max_context_axis
        for mb in max_batch_axis
    ]
    n = len(candidates)
    knobs_active = any(a != [None] for a in (kv_bits_axis, max_context_axis, max_batch_axis))

    print("autotune: provider-side model hill-climb (keep/revert)")
    print(f"autotune: provider_bin={args.provider_bin}")
    print(f"autotune: port={args.port}  max_tokens={args.max_tokens}  "
          f"ready_timeout={args.ready_timeout:.0f}s  gate_ttft={args.gate_ttft_ms:.0f}ms")
    print(f"autotune: models = {models}")
    print(f"autotune: contexts = {contexts}")
    if knobs_active:
        print(f"autotune: kv_bits axis = {kv_bits_axis}")
        print(f"autotune: max_context axis = {max_context_axis}")
        print(f"autotune: max_batch axis = {max_batch_axis}")
    print(f"autotune: candidate space = {n} configs")
    print()
    if knobs_active:
        print(f"{'#':>3}  {'model':<48}  {'ctx':>5}  {'kv':>3}  {'maxctx':>6}  {'mb':>3}")
        print("-" * 78)
        for i, (m, c, kv, mx, mb) in enumerate(candidates, 1):
            print(f"{i:>3}  {m:<48}  {c:>5}  {str(kv if kv is not None else '-'):>3}  "
                  f"{str(mx if mx is not None else '-'):>6}  {str(mb if mb is not None else '-'):>3}")
    else:
        print(f"{'#':>3}  {'model':<48}  {'target_ctx':>10}")
        print("-" * 68)
        for i, (m, c, _kv, _mx, _mb) in enumerate(candidates, 1):
            print(f"{i:>3}  {m:<48}  {c:>10}")

    if args.dry_run:
        print()
        print(f"[dry-run] would evaluate {n} candidate configs, one provider at a time. "
              "Nothing served.")
        return 0

    if not Path(args.provider_bin).exists():
        sys.exit(f"provider binary not found at {args.provider_bin} (pass --provider-bin)")

    # Logs for each provider launch (load failures / OOM land here).
    log_dir = BETA_DIR / ".cache" / "autotune-logs"
    log_dir.mkdir(parents=True, exist_ok=True)

    run_id = str(uuid.uuid4())
    print()
    print(f"autotune: run_id={run_id}")
    print(f"autotune: db={db_path}")
    print()

    conn = open_db(db_path)

    # best = the feasible candidate with the highest throughput_tps so far.
    best: dict[str, Any] | None = None

    # Ensure no provider is running before we begin (clean slate).
    stop_provider(args.port)

    def _cleanup_and_exit(signum, frame):  # pragma: no cover - signal path
        print("\nautotune: interrupted — stopping provider before exit.")
        stop_provider(args.port)
        conn.close()
        sys.exit(130)

    signal.signal(signal.SIGINT, _cleanup_and_exit)
    signal.signal(signal.SIGTERM, _cleanup_and_exit)

    try:
        for i, (model, context, kv_bits, max_context_cap, max_batch) in enumerate(candidates, 1):
            ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
            knob_str = _knob_tag(kv_bits, max_context_cap, max_batch)
            print(f"[{i}/{n}] model={model.split('/')[-1]} ctx={context}{knob_str} ... ",
                  end="", flush=True)

            metrics = evaluate_candidate(
                provider_bin=args.provider_bin,
                model=model,
                context=context,
                port=args.port,
                max_tokens=args.max_tokens,
                ready_timeout=args.ready_timeout,
                request_timeout=args.request_timeout,
                gate_ttft_ms=args.gate_ttft_ms,
                log_dir=log_dir,
                verbose=args.verbose,
                kv_bits=kv_bits,
                max_context_cap=max_context_cap,
                max_batch=max_batch,
            )

            fits = metrics["fits"]
            tps = metrics["agg_throughput_tps"]

            # --- keep / revert decision ---
            kept = 0
            verdict = ""
            if fits and tps is not None:
                if best is None or tps > best["tps"]:
                    kept = 1
                    best = {
                        "model": model, "context": context, "tps": tps,
                        "ttft": metrics["ttft_p95_ms"],
                        "kv_bits": kv_bits, "max_context_cap": max_context_cap,
                        "max_batch": max_batch,
                    }
                    verdict = "NEW BEST"
                else:
                    verdict = (f"kept best={best['model'].split('/')[-1]}@{best['context']} "
                               f"({best['tps']:.1f} t/s)")
            else:
                # Infeasible (or feasible-but-no-tokens) => revert, best unchanged.
                if best is not None:
                    verdict = (f"INFEASIBLE -> kept best={best['model'].split('/')[-1]}"
                               f"@{best['context']} ({best['tps']:.1f} t/s)")
                else:
                    verdict = "INFEASIBLE -> no best yet"

            row = {
                "ts_utc": ts,
                "run_id": run_id,
                "model": model,
                "target_context": context,
                "measured_prompt_tokens": metrics["measured_prompt_tokens"],
                "max_tokens": args.max_tokens,
                "agg_throughput_tps": tps,
                "ttft_p95_ms": metrics["ttft_p95_ms"],
                "fits": fits,
                "n_err": metrics["n_err"],
                "kept": kept,
                "notes": metrics["notes"],
                "kv_bits": kv_bits,
                "max_context_cap": max_context_cap,
                "max_batch": max_batch,
            }
            write_trial_row(conn, row)

            tps_str = f"{tps:.1f}" if tps is not None else "—"
            ttft_str = f"{metrics['ttft_p95_ms']:.0f}ms" if metrics["ttft_p95_ms"] is not None else "—"
            tag = "{NEW BEST}" if kept else f"{{{verdict}}}"
            print(f"-> tps={tps_str} ttft={ttft_str} fits={fits} {tag}")
            if metrics["notes"] and not fits:
                print(f"        note: {metrics['notes'][:160]}")

        print()
        # --- Declare the winner ---
        if best is not None:
            knob_suffix = _knob_tag(
                best.get("kv_bits"), best.get("max_context_cap"), best.get("max_batch")
            )
            print("=" * 68)
            print(f"WINNER: {best['model']} @ ctx={best['context']}{knob_suffix} "
                  f"-> {best['tps']:.1f} tok/s (ttft {fmt_val(best['ttft'], 0)} ms)")
            print("=" * 68)
        else:
            print("NO FEASIBLE CONFIG: every candidate errored / OOM'd / missed the gate.")

        # --- Summary table of all trials with best-so-far progression ---
        rows = fetch_trial_rows(conn, run_id)
        print()
        print("Trial log (best-so-far progression):")
        print(f"{'#':>2}  {'model':<34}  {'ctx':>5}  {'tps':>7}  {'ttft_ms':>8}  "
              f"{'fits':>4}  {'kept':>4}  {'best-so-far':>22}")
        print("-" * 100)
        bsf_tps: float | None = None
        bsf_label = "—"
        for i, r in enumerate(rows, 1):
            if r["fits"] and r["agg_throughput_tps"] is not None:
                if bsf_tps is None or r["agg_throughput_tps"] > bsf_tps:
                    bsf_tps = r["agg_throughput_tps"]
                    bsf_label = f"{r['model'].split('/')[-1][:14]}@{r['target_context']}"
            tps_s = f"{r['agg_throughput_tps']:.1f}" if r["agg_throughput_tps"] is not None else "—"
            ttft_s = f"{r['ttft_p95_ms']:.0f}" if r["ttft_p95_ms"] is not None else "—"
            bsf_s = f"{bsf_tps:.1f} ({bsf_label})" if bsf_tps is not None else "—"
            print(f"{i:>2}  {r['model'].split('/')[-1][:34]:<34}  {r['target_context']:>5}  "
                  f"{tps_s:>7}  {ttft_s:>8}  {r['fits']:>4}  {r['kept']:>4}  {bsf_s:>22}")

        # --- HTML report ---
        out_path = write_report(conn, run_id, reports_dir)
        print()
        print(f"autotune: report written -> {out_path}")
        print(f"autotune: run_id={run_id}")
        return 0 if best is not None else 1

    finally:
        # INVARIANT: never leave a provider alive at the very end.
        stop_provider(args.port)
        conn.close()
        # Final confirmation line.
        still = port_is_listening(args.port)
        print(f"autotune: provider stopped; :{args.port} listening={still}")


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
Context × concurrency throughput sweep for the MacProvider Phase 2 buyer harness.

Runs a deterministic grid of (context_length, concurrency) cells against a local
or remote LLM endpoint. Model is held FIXED (no weight reload between cells).

DO NOT default to a remote host. Pass --base-url explicitly. The live M1 node
(m1.streamvc.live) must NOT be targeted without human go-ahead.

Usage:
    # Dry-run: print grid plan without sending any requests
    python beta/sweep.py --dry-run --base-url http://127.0.0.1:18080

    # Small smoke sweep against local mock
    python beta/sweep.py --base-url http://127.0.0.1:18080 --contexts 1000,2000 --concurrency 1,2

    # Full sweep (28 cells) against local mock
    python beta/sweep.py --base-url http://127.0.0.1:18080

    # Full sweep with extended decode
    python beta/sweep.py --base-url http://127.0.0.1:18080 --decode-control 1024

    # Ready-for-live-fire (human must run after greenlighting with collaborator):
    # python beta/sweep.py --base-url https://m1.streamvc.live --config beta/config-m1.yaml

Results go to sweep_runs table in the configured db_path. Use sweep_report.py to render.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import statistics
import sys
import sqlite3
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml

# Resolve beta/ on sys.path so we can import sibling modules
BETA_DIR = Path(__file__).resolve().parent
if str(BETA_DIR) not in sys.path:
    sys.path.insert(0, str(BETA_DIR))

# Import fire_stream directly from harness — reuses its SSE parser with all
# Phase 1 quirk handling (keepalive comments, stop-token leak detection, etc.)
from harness import fire_stream

# _PROSE_BLOCK from workloads.py: ~2K tokens of realistic filler prose.
from workloads import _PROSE_BLOCK

DEFAULT_CONFIG = BETA_DIR / "config-m1.yaml"

# Default grid knobs
DEFAULT_CONTEXT_TARGETS = [1000, 2000, 4000, 8000, 16000, 24000, 32000]
DEFAULT_CONCURRENCIES = [1, 2, 4, 8]
DEFAULT_MAX_TOKENS = 256

SWEEP_SCHEMA = """
CREATE TABLE IF NOT EXISTS sweep_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc TEXT NOT NULL,
    sweep_id TEXT NOT NULL,
    model TEXT NOT NULL,
    context_target INTEGER NOT NULL,
    measured_prompt_tokens INTEGER,
    concurrency INTEGER NOT NULL,
    max_tokens INTEGER NOT NULL,
    agg_throughput_tps REAL,
    ttft_p95_ms REAL,
    n_ok INTEGER NOT NULL,
    n_err INTEGER NOT NULL,
    feasible INTEGER NOT NULL DEFAULT 0,
    notes TEXT
);
CREATE INDEX IF NOT EXISTS idx_sweep_runs_sweep_id ON sweep_runs(sweep_id);
CREATE INDEX IF NOT EXISTS idx_sweep_runs_ts ON sweep_runs(ts_utc);
"""


# ---------------------------------------------------------------------------
# Prompt building
# ---------------------------------------------------------------------------

# Approximate chars per token for padding estimation (rough heuristic; real
# prompt_tokens is recorded from usage in the response).
_CHARS_PER_TOKEN = 4
# Overhead for system/user message structure + question suffix (~50 tokens)
_TEMPLATE_OVERHEAD_TOKENS = 50

# Fixed question at end of every padded prompt
_QUESTION_SUFFIX = "\n\nIn one sentence, what is the main theme of the passage above?"


def build_padded_prompt(context_target_tokens: int, max_tokens: int) -> dict:
    """Build a chat body with messages padded to approximately context_target_tokens.

    The prompt is a user message containing repeated _PROSE_BLOCK text padded
    to fill the target token budget, followed by a fixed question. stream=True
    so we get TTFT via the SSE parser in harness.fire_stream.
    """
    # Tokens available for padding (subtract template overhead + decode budget)
    pad_tokens = max(0, context_target_tokens - _TEMPLATE_OVERHEAD_TOKENS)
    prose_len_tokens = len(_PROSE_BLOCK) // _CHARS_PER_TOKEN

    if prose_len_tokens == 0:
        context_text = "Hello."
    else:
        repeats = max(1, (pad_tokens + prose_len_tokens - 1) // prose_len_tokens)
        context_text = (_PROSE_BLOCK.strip() + "\n\n") * repeats

    content = context_text + _QUESTION_SUFFIX

    return {
        "messages": [
            {"role": "user", "content": content},
        ],
        "max_tokens": max_tokens,
        "stream": True,
    }


# ---------------------------------------------------------------------------
# DB helpers
# ---------------------------------------------------------------------------

def open_db(db_path: Path) -> sqlite3.Connection:
    """Open (or create) the SQLite DB and ensure sweep_runs table exists.
    Does NOT alter existing runs/adversarial_runs tables.
    """
    conn = sqlite3.connect(db_path)
    conn.executescript(SWEEP_SCHEMA)
    conn.commit()
    return conn


def write_cell_row(conn: sqlite3.Connection, row: dict) -> None:
    conn.execute(
        """INSERT INTO sweep_runs
               (ts_utc, sweep_id, model, context_target, measured_prompt_tokens,
                concurrency, max_tokens, agg_throughput_tps, ttft_p95_ms,
                n_ok, n_err, feasible, notes)
           VALUES
               (:ts_utc, :sweep_id, :model, :context_target, :measured_prompt_tokens,
                :concurrency, :max_tokens, :agg_throughput_tps, :ttft_p95_ms,
                :n_ok, :n_err, :feasible, :notes)""",
        row,
    )
    conn.commit()


# ---------------------------------------------------------------------------
# Cell execution
# ---------------------------------------------------------------------------

def run_cell(
    url: str,
    model: str,
    body: dict,
    concurrency: int,
    timeout_s: float,
    headers: dict | None = None,
) -> dict[str, Any]:
    """Fire `concurrency` parallel streamed requests for one grid cell.

    Returns aggregated metrics:
        wall_seconds, results (list of per-request dicts)
    """
    wall_t0 = time.monotonic()

    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [
            pool.submit(fire_stream, url, model, body, timeout_s, headers)
            for _ in range(concurrency)
        ]
        results = [f.result() for f in concurrent.futures.as_completed(futures)]

    wall_seconds = time.monotonic() - wall_t0
    return {"wall_seconds": wall_seconds, "results": results}


def aggregate_cell(
    cell_result: dict[str, Any],
    gate_ttft_ms: float,
) -> dict[str, Any]:
    """Compute cell-level aggregates and apply the feasibility gate.

    feasible = (n_err == 0) AND (ttft_p95_ms <= gate_ttft_ms) AND (no stop_token_leak)
    """
    results = cell_result["results"]
    wall_seconds = cell_result["wall_seconds"]

    n_ok = 0
    n_err = 0
    ttft_values: list[float] = []
    total_completion_tokens = 0
    prompt_tokens_list: list[int] = []
    any_leak = False

    for r in results:
        is_err = bool(r.get("error")) or (r.get("http_status") is not None and r["http_status"] != 200)
        if is_err:
            n_err += 1
        else:
            n_ok += 1
            if r.get("ttft_ms") is not None:
                ttft_values.append(r["ttft_ms"])
            if r.get("completion_tokens"):
                total_completion_tokens += r["completion_tokens"]
            if r.get("prompt_tokens"):
                prompt_tokens_list.append(r["prompt_tokens"])
            if r.get("stop_token_leak"):
                any_leak = True

    # Aggregate throughput: total completion tokens / wall clock (not sum of per-request)
    agg_throughput_tps = (
        total_completion_tokens / wall_seconds if wall_seconds > 0 and total_completion_tokens > 0 else None
    )

    ttft_p95_ms: float | None = None
    if ttft_values:
        ttft_values_sorted = sorted(ttft_values)
        p95_idx = max(0, int(len(ttft_values_sorted) * 0.95) - 1)
        # For small N: p95 = max (conservative)
        ttft_p95_ms = ttft_values_sorted[-1] if len(ttft_values_sorted) < 20 else ttft_values_sorted[p95_idx]

    measured_prompt_tokens: int | None = (
        int(statistics.median(prompt_tokens_list)) if prompt_tokens_list else None
    )

    feasible = (
        n_err == 0
        and (ttft_p95_ms is not None and ttft_p95_ms <= gate_ttft_ms)
        and not any_leak
    )

    return {
        "n_ok": n_ok,
        "n_err": n_err,
        "agg_throughput_tps": agg_throughput_tps,
        "ttft_p95_ms": ttft_p95_ms,
        "measured_prompt_tokens": measured_prompt_tokens,
        "feasible": int(feasible),
    }


# ---------------------------------------------------------------------------
# Config loading (relaxed — does not call harness.load_config because that
# sys.exit()s on localhost non-HTTPS URLs and CHANGE-ME values)
# ---------------------------------------------------------------------------

def load_config_relaxed(path: Path) -> dict:
    with path.open() as f:
        cfg = yaml.safe_load(f)
    return cfg


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_int_list(s: str) -> list[int]:
    return [int(x.strip()) for x in s.split(",") if x.strip()]


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Context × concurrency throughput sweep (local/remote LLM endpoint)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument(
        "--base-url", required=True,
        help="Base URL of the LLM endpoint (e.g. http://127.0.0.1:18080). "
             "NEVER default to a remote host.",
    )
    ap.add_argument(
        "--config", default=str(DEFAULT_CONFIG),
        help="Config YAML (model, db_path, reports_dir, timeout_s). "
             "Default: beta/config-m1.yaml",
    )
    ap.add_argument(
        "--gate-ttft-ms", type=float, default=8000.0,
        help="Max acceptable p95 TTFT in ms for feasibility gate (default: 8000)",
    )
    ap.add_argument(
        "--decode-control", type=int, default=None,
        help="If set, run an additional pass with this max_tokens value (e.g. 1024)",
    )
    ap.add_argument(
        "--max-tokens", type=int, default=None,
        help=f"Decode length (max_tokens) per request. Default {DEFAULT_MAX_TOKENS}. "
             "Lower it (e.g. 48) for fast runs on slow/constrained nodes — the context "
             "ceiling is driven by prefill, not decode length.",
    )
    ap.add_argument(
        "--contexts", default=None,
        help="Comma-separated context targets in tokens to override the default grid "
             "(e.g. '1000,2000,4000')",
    )
    ap.add_argument(
        "--concurrency", default=None,
        help="Comma-separated concurrency levels to override the default grid "
             "(e.g. '1,2')",
    )
    ap.add_argument(
        "--dry-run", action="store_true",
        help="Print the grid plan (cells, prompt sizes) without sending any requests",
    )
    ap.add_argument(
        "--stop-on-fail", action="store_true",
        help="Abort the sweep as soon as a cell returns request errors (n_err > 0), "
             "which on a memory-constrained node almost always means OOM. Protects a "
             "collaborator's box from being re-slammed by every heavier cell. A cell "
             "that merely misses the TTFT gate (slow but no errors) does NOT stop the "
             "sweep — only real request failures do.",
    )
    ap.add_argument(
        "--model", default=None,
        help="Override the model id sent in each request (default: the `model:` "
             "from --config). On the coordinator/gateway path this also pins the "
             "provider: only the provider serving this model can fulfill the request.",
    )
    ap.add_argument(
        "--api-key", default=None,
        help="Bearer key for the gateway path (e.g. mp_...). If omitted, falls back "
             "to --api-key-file when that file exists. Leave unset for a direct local "
             "provider endpoint (no auth).",
    )
    ap.add_argument(
        "--api-key-file", default=str(Path.home() / ".config/macprovider/buyer-api-key"),
        help="File to read the bearer key from when --api-key is not given. "
             "Default: ~/.config/macprovider/buyer-api-key. Ignored if absent "
             "(direct/local runs send no auth).",
    )
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    cfg = load_config_relaxed(Path(args.config))
    model = args.model or cfg.get("model", "mlx-community/Llama-3.2-3B-Instruct-4bit")
    timeout_s = float(cfg.get("timeout_s", 180))
    db_path = BETA_DIR / cfg.get("db_path", "runs.sqlite")
    reports_dir = BETA_DIR / cfg.get("reports_dir", "reports")

    url = args.base_url.rstrip("/") + "/v1/chat/completions"

    # Resolve bearer auth: explicit --api-key wins, else read --api-key-file if it
    # exists. No key -> headers=None -> direct/local provider path (Leg 1, no auth).
    api_key = args.api_key
    if not api_key:
        key_path = Path(args.api_key_file)
        if key_path.is_file():
            api_key = key_path.read_text().strip()
    headers = {"Authorization": f"Bearer {api_key}"} if api_key else None

    context_targets = parse_int_list(args.contexts) if args.contexts else DEFAULT_CONTEXT_TARGETS
    concurrencies = parse_int_list(args.concurrency) if args.concurrency else DEFAULT_CONCURRENCIES

    # Determine max_tokens passes
    base_max_tokens = args.max_tokens or DEFAULT_MAX_TOKENS
    max_tokens_list = [base_max_tokens]
    if args.decode_control and args.decode_control != base_max_tokens:
        max_tokens_list.append(args.decode_control)

    # Build the full grid
    cells = [
        (ctx, conc, mt)
        for mt in max_tokens_list
        for ctx in context_targets
        for conc in concurrencies
    ]

    n_cells = len(cells)

    print(f"sweep: model={model}")
    print(f"sweep: endpoint={url}")
    print(f"sweep: auth={'bearer ' + api_key[:6] + '…' if api_key else 'none (direct/local)'}")
    print(f"sweep: gate_ttft_ms={args.gate_ttft_ms}")
    print(f"sweep: grid = {len(context_targets)} contexts × {len(concurrencies)} concurrencies"
          f" × {len(max_tokens_list)} decode pass(es) = {n_cells} cells")
    print(f"sweep: contexts={context_targets}")
    print(f"sweep: concurrencies={concurrencies}")
    print(f"sweep: max_tokens={max_tokens_list}")
    print()
    print(f"{'#':>3}  {'context':>8}  {'conc':>4}  {'max_tok':>7}  {'est_chars':>10}")
    print("-" * 42)
    for i, (ctx, conc, mt) in enumerate(cells, 1):
        # Estimate padded content length (for planning only)
        pad_tokens = max(0, ctx - _TEMPLATE_OVERHEAD_TOKENS)
        prose_token_len = len(_PROSE_BLOCK) // _CHARS_PER_TOKEN
        repeats = max(1, (pad_tokens + prose_token_len - 1) // prose_token_len) if prose_token_len else 1
        est_chars = repeats * len(_PROSE_BLOCK) + len(_QUESTION_SUFFIX)
        print(f"{i:>3}  {ctx:>8}  {conc:>4}  {mt:>7}  {est_chars:>10}")

    if args.dry_run:
        print()
        print(f"[dry-run] would send {n_cells} cells × concurrency requests each. No HTTP sent.")
        return 0

    sweep_id = str(uuid.uuid4())
    print()
    print(f"sweep: sweep_id={sweep_id}")
    print(f"sweep: db={db_path}")
    print()

    conn = open_db(db_path)

    failures = 0
    attempted = 0
    try:
        for i, (ctx, conc, mt) in enumerate(cells, 1):
            attempted = i
            body = build_padded_prompt(ctx, mt)
            ts = datetime.now(timezone.utc).isoformat(timespec="seconds")

            print(f"[{i:>3}/{n_cells}] ctx={ctx:>6} conc={conc} max_tokens={mt} ... ", end="", flush=True)

            cell_result = run_cell(url, model, body, conc, timeout_s, headers)
            agg = aggregate_cell(cell_result, args.gate_ttft_ms)

            row: dict[str, Any] = {
                "ts_utc": ts,
                "sweep_id": sweep_id,
                "model": model,
                "context_target": ctx,
                "measured_prompt_tokens": agg["measured_prompt_tokens"],
                "concurrency": conc,
                "max_tokens": mt,
                "agg_throughput_tps": agg["agg_throughput_tps"],
                "ttft_p95_ms": agg["ttft_p95_ms"],
                "n_ok": agg["n_ok"],
                "n_err": agg["n_err"],
                "feasible": agg["feasible"],
                "notes": None,
            }
            write_cell_row(conn, row)

            feasible_str = "OK" if agg["feasible"] else "FAIL"
            tps_str = f"{agg['agg_throughput_tps']:.1f}" if agg["agg_throughput_tps"] is not None else "—"
            ttft_str = f"{agg['ttft_p95_ms']:.0f}ms" if agg["ttft_p95_ms"] is not None else "—"
            print(
                f"{feasible_str}  ok={agg['n_ok']} err={agg['n_err']} "
                f"tps={tps_str} ttft_p95={ttft_str} "
                f"prompt_tok={agg['measured_prompt_tokens'] or '—'}"
            )

            if not agg["feasible"]:
                failures += 1

            if args.stop_on_fail and agg["n_err"] > 0:
                print()
                print(
                    f"sweep: --stop-on-fail tripped at cell {i}/{n_cells} "
                    f"(ctx={ctx} conc={conc} max_tokens={mt}, n_err={agg['n_err']}). "
                    f"Aborting before heavier cells re-slam the node."
                )
                print(
                    f"sweep: {n_cells - i} cells skipped. Resume the remainder with "
                    f"narrowed --contexts/--concurrency once the node has recovered."
                )
                break

    finally:
        conn.close()

    print()
    skipped = n_cells - attempted
    skip_note = f" ({skipped} skipped via --stop-on-fail)" if skipped > 0 else ""
    print(f"sweep: done. {attempted - failures}/{attempted} attempted cells feasible{skip_note}.")
    print(f"sweep: sweep_id={sweep_id}")
    print(f"sweep: run `python beta/sweep_report.py --sweep-id {sweep_id}` to render the heatmap")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

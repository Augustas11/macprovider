#!/usr/bin/env python3
"""
Phase 2 buyer harness.

Fires workloads at an mlx_lm.server instance (exposed via cloudflared by the
M4 user), records per-request metrics to SQLite. Designed to be run hourly by
cron once the M4 tester is up.

Usage:
    python harness.py --once short_chat          # one workload, log to db
    python harness.py --batch                    # the batch list from config
    python harness.py --batch --dry-run          # build prompts but don't POST
    python harness.py --list                     # show registered workloads

Honors three SSE quirks identified in Phase 1 (results/REPORT.md):
  1. Skips ": keepalive" comment lines before json.loads.
  2. Strips model-specific stop tokens from accumulated streamed output and
     flags leakage in the `stop_token_leak` column.
  3. Tolerates extra response fields (system_fingerprint, tool_calls, etc.).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import requests
import yaml

import workloads
import workloads_adversarial
import stop_tokens

BETA_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG = BETA_DIR / "config.yaml"

# Stop tokens that mlx_lm.server has been observed to leak. If any of these
# strings appear in the assistant content, that's a Phase 3 binary bug surface
# — record it and move on. Order matters only for the regex; we OR them.
LEAKED_STOP_TOKENS = [
    "<|eot_id|>",
    "<|end_of_text|>",
    "<|endoftext|>",
    "<|im_end|>",
    "<|end|>",
    "<|start_header_id|>",
    "<|end_header_id|>",
]
_LEAK_RE = re.compile("|".join(re.escape(t) for t in LEAKED_STOP_TOKENS))

SCHEMA = """
CREATE TABLE IF NOT EXISTS runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc TEXT NOT NULL,
    workload TEXT NOT NULL,
    model TEXT,
    tunnel_url TEXT,
    streamed INTEGER NOT NULL,
    http_status INTEGER,
    ttft_ms REAL,
    total_ms REAL,
    prompt_tokens INTEGER,
    completion_tokens INTEGER,
    throughput_tps REAL,
    stop_token_leak INTEGER NOT NULL DEFAULT 0,
    error TEXT,
    response_preview TEXT
);
CREATE INDEX IF NOT EXISTS idx_runs_ts ON runs(ts_utc);
CREATE INDEX IF NOT EXISTS idx_runs_workload ON runs(workload);

-- Adversarial workloads have different semantics — each "run" is an aggregate
-- of many requests (burst, retry storm, etc.) and reports its own metrics. We
-- keep them in a separate table so the cooperative `runs` schema stays clean
-- and so the daily report can render them in their own section.
CREATE TABLE IF NOT EXISTS adversarial_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc TEXT NOT NULL,
    workload TEXT NOT NULL,
    model TEXT,
    tunnel_url TEXT,
    n_requests INTEGER,
    n_ok INTEGER,
    n_errors INTEGER,
    total_ms REAL,
    median_ms REAL,
    p95_ms REAL,
    error_summary TEXT,
    notes TEXT
);
CREATE INDEX IF NOT EXISTS idx_adv_runs_ts ON adversarial_runs(ts_utc);

-- Full untruncated responses for the last 500 cooperative runs.
-- Keyed by runs.id so you can JOIN for analysis. Adversarial workloads
-- are excluded (they fire many sub-requests and would explode storage).
CREATE TABLE IF NOT EXISTS full_responses (
    run_id INTEGER PRIMARY KEY,
    full_content TEXT
);
"""


def load_config(path: Path) -> dict:
    with path.open() as f:
        cfg = yaml.safe_load(f)
    if not cfg.get("tunnel_url") or "CHANGE-ME" in cfg["tunnel_url"]:
        sys.exit(f"config: set tunnel_url in {path} before running")
    return cfg


def resolve_model(cfg: dict, verbose: bool = False) -> str:
    """Pick a model from config. Supports legacy `model:` and new `models:` list.

    Selection strategies (model_select key):
      - "first"       — always models[0]
      - "rotate"      — round-robin, index persisted in beta/.cache/model_index
      - "day_of_week" — index = weekday % len(models)
    Falls back to legacy `model:` string if `models:` is absent/empty.
    """
    models_list = cfg.get("models") or []
    if not models_list:
        return cfg["model"]

    strategy = cfg.get("model_select", "first")

    if strategy == "first":
        idx = 0
    elif strategy == "rotate":
        cache_dir = BETA_DIR / ".cache"
        cache_dir.mkdir(parents=True, exist_ok=True)
        index_file = cache_dir / "model_index"
        try:
            idx = int(index_file.read_text().strip())
        except (FileNotFoundError, ValueError):
            idx = 0
        # Persist the next index
        next_idx = (idx + 1) % len(models_list)
        index_file.write_text(str(next_idx))
    elif strategy == "day_of_week":
        idx = datetime.now(timezone.utc).weekday() % len(models_list)
    else:
        if verbose:
            print(f"harness: unknown model_select={strategy!r}, falling back to first")
        idx = 0

    entry = models_list[idx % len(models_list)]
    model_id = entry["id"] if isinstance(entry, dict) else entry
    tier = entry.get("tier", "unknown") if isinstance(entry, dict) else "unknown"
    if verbose:
        print(f"harness: selected model={model_id} (tier={tier})")

    # Set cfg["model"] so downstream code just uses cfg["model"]
    cfg["model"] = model_id
    return model_id


def open_db(db_path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    conn.executescript(SCHEMA)
    conn.commit()
    return conn


def detect_leak(text: str) -> bool:
    return bool(_LEAK_RE.search(text or ""))


def strip_leaks(text: str) -> str:
    return _LEAK_RE.sub("", text or "")


def detect_leak_model(text: str, model_id: str) -> bool:
    """Per-model stop-token leak detection using tokenizer_config.json data."""
    regex = stop_tokens.get_leak_regex(model_id)
    return bool(regex.search(text or ""))


def strip_leaks_model(text: str, model_id: str) -> str:
    """Per-model stop-token stripping."""
    regex = stop_tokens.get_leak_regex(model_id)
    return regex.sub("", text or "")


def fire_nonstream(url: str, model: str, body: dict, timeout: float) -> dict:
    """POST a non-streaming request. Returns a metrics dict."""
    payload = {"model": model, "stream": False, **body}
    t0 = time.monotonic()
    try:
        r = requests.post(url, json=payload, timeout=timeout)
    except requests.RequestException as e:
        return {"error": f"{type(e).__name__}: {e}", "total_ms": (time.monotonic() - t0) * 1000}
    total_ms = (time.monotonic() - t0) * 1000

    out: dict[str, Any] = {"http_status": r.status_code, "total_ms": total_ms}
    if r.status_code != 200:
        out["error"] = f"HTTP {r.status_code}: {r.text[:200]}"
        return out

    try:
        data = r.json()
    except ValueError as e:
        out["error"] = f"non-JSON body: {e}"
        return out

    content = ""
    try:
        content = data["choices"][0]["message"]["content"] or ""
    except (KeyError, IndexError, TypeError):
        out["error"] = "missing choices[0].message.content"

    usage = data.get("usage") or {}
    out["prompt_tokens"] = usage.get("prompt_tokens")
    out["completion_tokens"] = usage.get("completion_tokens")
    if out["completion_tokens"] and total_ms > 0:
        out["throughput_tps"] = out["completion_tokens"] / (total_ms / 1000.0)

    out["stop_token_leak"] = detect_leak_model(content, model)
    out["response_preview"] = strip_leaks_model(content, model)[:300]
    out["_full_content"] = content
    return out


def fire_stream(url: str, model: str, body: dict, timeout: float) -> dict:
    """POST a streaming request, parse SSE. Returns a metrics dict with TTFT."""
    payload = {"model": model, **body, "stream": True}
    t0 = time.monotonic()
    ttft_ms: float | None = None
    pieces: list[str] = []
    usage: dict[str, Any] = {}
    http_status: int | None = None
    error: str | None = None

    try:
        with requests.post(url, json=payload, timeout=timeout, stream=True) as r:
            http_status = r.status_code
            if r.status_code != 200:
                return {
                    "http_status": r.status_code,
                    "error": f"HTTP {r.status_code}: {r.text[:200]}",
                    "total_ms": (time.monotonic() - t0) * 1000,
                }
            for raw in r.iter_lines(decode_unicode=True):
                if not raw:
                    continue
                # Phase 1 quirk #1: keepalive comments like ": keepalive 9/10".
                if raw.startswith(":"):
                    continue
                if not raw.startswith("data: "):
                    continue
                payload_str = raw[6:]
                if payload_str.strip() == "[DONE]":
                    break
                try:
                    chunk = json.loads(payload_str)
                except json.JSONDecodeError:
                    # Garbage line — Phase 1 saw none of these, but tolerate.
                    continue
                choices = chunk.get("choices") or []
                if choices:
                    delta = choices[0].get("delta") or {}
                    piece = delta.get("content")
                    if piece:
                        if ttft_ms is None:
                            ttft_ms = (time.monotonic() - t0) * 1000
                        pieces.append(piece)
                if chunk.get("usage"):
                    usage = chunk["usage"]
    except requests.RequestException as e:
        error = f"{type(e).__name__}: {e}"

    total_ms = (time.monotonic() - t0) * 1000
    content = "".join(pieces)
    out: dict[str, Any] = {
        "http_status": http_status,
        "total_ms": total_ms,
        "ttft_ms": ttft_ms,
        "prompt_tokens": usage.get("prompt_tokens"),
        "completion_tokens": usage.get("completion_tokens"),
        "stop_token_leak": detect_leak_model(content, model),
        "response_preview": strip_leaks_model(content, model)[:300],
    }
    out["_full_content"] = content
    if error:
        out["error"] = error
    if out["completion_tokens"] and total_ms > 0:
        out["throughput_tps"] = out["completion_tokens"] / (total_ms / 1000.0)
    return out


def run_one(cfg: dict, name: str, conn: sqlite3.Connection, verbose: bool, dry_run: bool) -> dict:
    builder = workloads.REGISTRY.get(name)
    if builder is None:
        raise SystemExit(f"unknown workload: {name} (try --list)")
    body = builder()
    streamed = bool(body.get("stream"))
    url = cfg["tunnel_url"].rstrip("/") + "/v1/chat/completions"

    if dry_run:
        if verbose:
            print(f"[dry-run] {name} stream={streamed} max_tokens={body.get('max_tokens')}")
        return {}

    if streamed:
        metrics = fire_stream(url, cfg["model"], body, cfg.get("timeout_s", 180))
    else:
        metrics = fire_nonstream(url, cfg["model"], body, cfg.get("timeout_s", 180))

    row = {
        "ts_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "workload": name,
        "model": cfg["model"],
        "tunnel_url": cfg["tunnel_url"],
        "streamed": int(streamed),
        "http_status": metrics.get("http_status"),
        "ttft_ms": metrics.get("ttft_ms"),
        "total_ms": metrics.get("total_ms"),
        "prompt_tokens": metrics.get("prompt_tokens"),
        "completion_tokens": metrics.get("completion_tokens"),
        "throughput_tps": metrics.get("throughput_tps"),
        "stop_token_leak": int(bool(metrics.get("stop_token_leak"))),
        "error": metrics.get("error"),
        "response_preview": metrics.get("response_preview"),
    }
    cur = conn.execute(
        """INSERT INTO runs (ts_utc, workload, model, tunnel_url, streamed,
                              http_status, ttft_ms, total_ms, prompt_tokens,
                              completion_tokens, throughput_tps, stop_token_leak,
                              error, response_preview)
           VALUES (:ts_utc, :workload, :model, :tunnel_url, :streamed,
                   :http_status, :ttft_ms, :total_ms, :prompt_tokens,
                   :completion_tokens, :throughput_tps, :stop_token_leak,
                   :error, :response_preview)""",
        row,
    )
    run_id = cur.lastrowid

    # Full-response ring buffer: store untruncated content, prune to last 500
    full_content = metrics.get("_full_content") or ""
    if full_content:
        conn.execute(
            "INSERT OR REPLACE INTO full_responses (run_id, full_content) VALUES (?, ?)",
            (run_id, full_content),
        )
        conn.execute(
            "DELETE FROM full_responses WHERE run_id <= (SELECT MAX(run_id) FROM full_responses) - 500"
        )

    conn.commit()

    if verbose:
        status = row["http_status"]
        err = row["error"]
        if err:
            print(f"  {name}: FAIL status={status} err={err[:100]}")
        else:
            tps = f"{row['throughput_tps']:.1f}" if row['throughput_tps'] else "—"
            ttft = f"{row['ttft_ms']:.0f}ms" if row['ttft_ms'] is not None else "—"
            print(
                f"  {name}: status={status} ttft={ttft} total={row['total_ms']:.0f}ms "
                f"in={row['prompt_tokens']} out={row['completion_tokens']} tps={tps} "
                f"leak={row['stop_token_leak']}"
            )
    return row


def run_one_adversarial(cfg: dict, name: str, conn: sqlite3.Connection, verbose: bool, dry_run: bool) -> dict:
    """
    Adversarial workloads fire many requests internally (bursts, storms, etc.)
    and return aggregate metrics — they do their own HTTP, unlike cooperative
    workloads which just build a request body.
    """
    builder = workloads_adversarial.REGISTRY.get(name)
    if builder is None:
        raise SystemExit(f"unknown adversarial workload: {name} (try --list)")
    url = cfg["tunnel_url"].rstrip("/") + "/v1/chat/completions"
    if dry_run:
        if verbose:
            print(f"[dry-run] adversarial/{name}")
        return {}
    metrics = builder(url, cfg["model"], cfg.get("timeout_s", 180))
    row = {
        "ts_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "workload": name,
        "model": cfg["model"],
        "tunnel_url": cfg["tunnel_url"],
        "n_requests": metrics.get("n_requests"),
        "n_ok": metrics.get("n_ok"),
        "n_errors": metrics.get("n_errors"),
        "total_ms": metrics.get("total_ms"),
        "median_ms": metrics.get("median_ms"),
        "p95_ms": metrics.get("p95_ms"),
        "error_summary": metrics.get("error_summary"),
        "notes": metrics.get("notes"),
    }
    conn.execute(
        """INSERT INTO adversarial_runs (ts_utc, workload, model, tunnel_url,
                                          n_requests, n_ok, n_errors, total_ms,
                                          median_ms, p95_ms, error_summary, notes)
           VALUES (:ts_utc, :workload, :model, :tunnel_url,
                   :n_requests, :n_ok, :n_errors, :total_ms,
                   :median_ms, :p95_ms, :error_summary, :notes)""",
        row,
    )
    conn.commit()
    if verbose:
        total = "{:.0f}ms".format(row['total_ms']) if row['total_ms'] is not None else "--"
        p50 = "{:.0f}ms".format(row['median_ms']) if row['median_ms'] is not None else "--"
        p95 = "{:.0f}ms".format(row['p95_ms']) if row['p95_ms'] is not None else "--"
        err_part = "· " + row['error_summary'] if row['error_summary'] else ""
        print(
            "  adversarial/{}: n={} ok={} err={} total={} p50={} p95={} {}".format(
                name, row['n_requests'], row['n_ok'], row['n_errors'], total, p50, p95, err_part
            )
        )
    return row


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=str(DEFAULT_CONFIG))
    ap.add_argument("--once", metavar="WORKLOAD", help="fire a single workload by name")
    ap.add_argument(
        "--batch",
        nargs="?",
        const="cooperative",
        default=None,
        metavar="PROFILE",
        help="fire a batch list from config. PROFILE is 'cooperative' (default) or 'adversarial'.",
    )
    ap.add_argument("--list", action="store_true", help="list registered workloads and exit")
    ap.add_argument("--dry-run", action="store_true", help="build prompts but skip HTTP")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    if args.list:
        print("# cooperative workloads (batch:)")
        for name in workloads.REGISTRY:
            print(f"  {name}")
        print("# adversarial workloads (batch_adversarial:)")
        for name in workloads_adversarial.REGISTRY:
            print(f"  {name}")
        return 0

    cfg = load_config(Path(args.config))
    resolve_model(cfg, verbose=args.verbose)
    db_path = BETA_DIR / cfg.get("db_path", "runs.sqlite")
    conn = open_db(db_path)

    try:
        # Resolve targets + which runner to use based on profile.
        profile = args.batch  # None | "cooperative" | "adversarial"
        targets: list[str]
        if args.once:
            # --once falls back to cooperative registry unless the name is in
            # adversarial registry (allows quick smoke tests of either).
            targets = [args.once]
            is_adversarial = args.once in workloads_adversarial.REGISTRY
        elif profile == "adversarial":
            targets = list(cfg.get("batch_adversarial") or [])
            if not targets:
                sys.exit("config: batch_adversarial is empty; add workloads or use --once")
            is_adversarial = True
        elif profile == "cooperative":
            targets = list(cfg.get("batch") or [])
            if not targets:
                sys.exit("config: batch is empty; add workloads or use --once")
            is_adversarial = False
        else:
            ap.error("pass --once <name> or --batch [cooperative|adversarial]")
            return 2

        if args.verbose:
            kind = "adversarial" if is_adversarial else "cooperative"
            print(f"harness: profile={kind} model={cfg['model']} url={cfg['tunnel_url']}")
            print(f"harness: running {len(targets)} workload(s) -> {db_path}")

        runner = run_one_adversarial if is_adversarial else run_one
        failures = 0
        for name in targets:
            row = runner(cfg, name, conn, args.verbose, args.dry_run)
            if is_adversarial:
                # Adversarial counts as a failure only if every request errored.
                if row.get("n_requests") and row.get("n_ok") == 0:
                    failures += 1
            else:
                if row.get("error") or (row.get("http_status") and row["http_status"] != 200):
                    failures += 1

        if args.verbose:
            print(f"harness: done, {failures} failure(s)")
        return 0 if failures == 0 else 1
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())

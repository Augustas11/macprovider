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

Honors three SSE quirks identified in Phase 1 (docs/legacy/phase1/PHASE1_REPORT.md):
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
import shlex
import sqlite3
import subprocess
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
import spec029

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
    host_ram_bytes INTEGER,
    ram_tier_key TEXT,
    provider_ram_source TEXT,
    cell_execution_source TEXT,
    non_runnable_reason TEXT,
    corpus_class TEXT,
    max_context_override INTEGER,
    max_concurrency_override INTEGER,
    kv_bits INTEGER,
    metric_unavailable_reason TEXT,
    draft_model TEXT,
    draft_model_artifact_sha256 TEXT,
    num_draft_tokens INTEGER,
    drafted_tokens INTEGER,
    accepted_tokens INTEGER,
    spec_decode_acceptance_rate REAL,
    candidate_source TEXT,
    winner_status TEXT,
    no_winner_reason TEXT,
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

RUNS_SPEC029_COLUMNS = {
    "host_ram_bytes": "INTEGER",
    "ram_tier_key": "TEXT",
    "provider_ram_source": "TEXT",
    "cell_execution_source": "TEXT",
    "non_runnable_reason": "TEXT",
    "corpus_class": "TEXT",
    "max_context_override": "INTEGER",
    "max_concurrency_override": "INTEGER",
    "kv_bits": "INTEGER",
    "metric_unavailable_reason": "TEXT",
    "draft_model": "TEXT",
    "draft_model_artifact_sha256": "TEXT",
    "num_draft_tokens": "INTEGER",
    "drafted_tokens": "INTEGER",
    "accepted_tokens": "INTEGER",
    "spec_decode_acceptance_rate": "REAL",
    "candidate_source": "TEXT",
    "winner_status": "TEXT",
    "no_winner_reason": "TEXT",
}


class Spec029CellApplyError(RuntimeError):
    """A configured SPEC-029 cell was attempted but could not be made runnable."""


def load_config(path: Path) -> dict:
    with path.open() as f:
        cfg = yaml.safe_load(f)
    url = cfg.get("tunnel_url") or ""
    if not url or "CHANGE-ME" in url:
        sys.exit(f"config: set tunnel_url in {path} before running")
    from urllib.parse import urlparse
    parsed = urlparse(url)
    if parsed.hostname not in ("127.0.0.1", "localhost") and parsed.scheme != "https":
        sys.exit(f"config: tunnel_url must use HTTPS for non-localhost targets (got {parsed.scheme}://)")
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
    cfg["_selected_model_entry"] = entry if isinstance(entry, dict) else {"id": model_id}
    return model_id


def open_db(db_path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    conn.executescript(SCHEMA)
    ensure_runs_spec029_columns(conn)
    conn.commit()
    return conn


def ensure_runs_spec029_columns(conn: sqlite3.Connection) -> None:
    existing = {row[1] for row in conn.execute("PRAGMA table_info(runs)")}
    for name, type_name in RUNS_SPEC029_COLUMNS.items():
        if name not in existing:
            conn.execute(f"ALTER TABLE runs ADD COLUMN {name} {type_name}")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_runs_spec029_partition ON runs(workload, ram_tier_key)")


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


def extract_spec_decode_metrics(data: dict[str, Any], usage: dict[str, Any] | None = None) -> dict[str, Any]:
    usage = usage or {}
    spec_decode = data.get("spec_decode") if isinstance(data.get("spec_decode"), dict) else {}

    def first(*keys):
        for source in (data, usage, spec_decode):
            for key in keys:
                value = source.get(key)
                if value is not None:
                    return value
        return None

    drafted = first("drafted_tokens", "spec_decode_drafted_tokens", "spec_decode_drafted_tokens_since_last")
    accepted = first("accepted_tokens", "spec_decode_accepted_tokens", "spec_decode_accepted_tokens_since_last")
    acceptance_rate = first("spec_decode_acceptance_rate", "acceptance_rate")
    if acceptance_rate is None and drafted not in (None, 0) and accepted is not None:
        acceptance_rate = accepted / drafted

    out: dict[str, Any] = {}
    if drafted is not None:
        out["drafted_tokens"] = drafted
    if accepted is not None:
        out["accepted_tokens"] = accepted
    if acceptance_rate is not None:
        out["spec_decode_acceptance_rate"] = acceptance_rate
    return out


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
    out.update(extract_spec_decode_metrics(data, usage))
    if out["completion_tokens"] and total_ms > 0:
        out["throughput_tps"] = out["completion_tokens"] / (total_ms / 1000.0)

    out["stop_token_leak"] = detect_leak_model(content, model)
    out["response_preview"] = strip_leaks_model(content, model)[:300]
    out["_full_content"] = content
    return out


def apply_spec029_cell(cfg: dict, cell: dict[str, Any], dry_run: bool, verbose: bool = False) -> str:
    """Apply or prove the configured SPEC-029 cell before collecting samples."""
    normalized = spec029.normalize_sweep_cell(cell, cfg)
    spec_cfg = cfg.get("spec029_sweep") or {}
    if dry_run:
        return "dry_run"

    control_url = spec_cfg.get("cell_control_url") or cfg.get("spec029_cell_control_url")
    if control_url:
        payload = {"model": cfg["model"], "cell": normalized}
        try:
            response = requests.post(control_url, json=payload, timeout=cfg.get("timeout_s", 180))
        except requests.RequestException as exc:
            raise Spec029CellApplyError(f"SPEC-029 cell control request failed: {exc}") from exc
        if response.status_code < 200 or response.status_code >= 300:
            raise Spec029CellApplyError(f"SPEC-029 cell control failed HTTP {response.status_code}: {response.text[:200]}")
        return "cell_control_url"

    command = spec_cfg.get("cell_apply_command") or cfg.get("spec029_cell_apply_command")
    if command:
        env = os.environ.copy()
        env.update({
            "SPEC029_MODEL": str(cfg["model"]),
            "SPEC029_KV_BITS": str(normalized["kv_bits"]),
            "SPEC029_MAX_CONTEXT_OVERRIDE": str(normalized["max_context_override"]),
            "SPEC029_MAX_CONCURRENCY_OVERRIDE": str(normalized["max_concurrency_override"]),
            "SPEC029_DRAFT_MODEL": str(normalized.get("draft_model") or ""),
            "SPEC029_DRAFT_MODEL_ARTIFACT_SHA256": str(normalized.get("draft_model_artifact_sha256") or ""),
            "SPEC029_NUM_DRAFT_TOKENS": str(normalized.get("num_draft_tokens") or ""),
        })
        args = command if isinstance(command, list) else shlex.split(str(command))
        try:
            subprocess.run(args, check=True, timeout=spec_cfg.get("cell_apply_timeout_s", 180), env=env)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as exc:
            raise Spec029CellApplyError(f"SPEC-029 cell apply command failed: {exc}") from exc
        return "cell_apply_command"

    raise RuntimeError(
        "SPEC-029 sweep requires spec029_sweep.cell_control_url, "
        "or spec029_sweep.cell_apply_command"
    )


def validate_spec029_cell_execution_config(cfg: dict, dry_run: bool) -> None:
    if dry_run:
        return
    spec_cfg = cfg.get("spec029_sweep") or {}
    mechanisms = [
        bool(spec_cfg.get("cell_control_url") or cfg.get("spec029_cell_control_url")),
        bool(spec_cfg.get("cell_apply_command") or cfg.get("spec029_cell_apply_command")),
    ]
    count = sum(1 for enabled in mechanisms if enabled)
    if count != 1:
        raise RuntimeError(
            "SPEC-029 sweep requires exactly one cell execution mechanism: "
            "cell_control_url or cell_apply_command"
        )


def fire_stream(url: str, model: str, body: dict, timeout: float) -> dict:
    """POST a streaming request, parse SSE. Returns a metrics dict with TTFT."""
    payload = {"model": model, **body, "stream": True}
    t0 = time.monotonic()
    ttft_ms: float | None = None
    pieces: list[str] = []
    usage: dict[str, Any] = {}
    last_chunk: dict[str, Any] = {}
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
                last_chunk = chunk
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
    out.update(extract_spec_decode_metrics(last_chunk, usage))
    out["_full_content"] = content
    if error:
        out["error"] = error
    if out["completion_tokens"] and total_ms > 0:
        out["throughput_tps"] = out["completion_tokens"] / (total_ms / 1000.0)
    return out


def run_one(
    cfg: dict,
    name: str,
    conn: sqlite3.Connection,
    verbose: bool,
    dry_run: bool,
    cell: dict[str, Any] | None = None,
    force_stream: bool = False,
    provider_ram: spec029.ProviderRAM | None = None,
    cell_execution_source: str | None = None,
    metrics_override: dict[str, Any] | None = None,
) -> dict:
    builder = workloads.REGISTRY.get(name)
    if builder is None:
        raise SystemExit(f"unknown workload: {name} (try --list)")
    body = builder()
    normalized_cell = spec029.normalize_sweep_cell(cell, cfg) if cell is not None else None
    if force_stream:
        body["stream"] = True
    streamed = bool(body.get("stream"))
    url = cfg["tunnel_url"].rstrip("/") + "/v1/chat/completions"

    if dry_run:
        if verbose:
            print(f"[dry-run] {name} stream={streamed} max_tokens={body.get('max_tokens')}")
        return {}

    if metrics_override is not None:
        metrics = metrics_override
    elif streamed:
        metrics = fire_stream(url, cfg["model"], body, cfg.get("timeout_s", 180))
    else:
        metrics = fire_nonstream(url, cfg["model"], body, cfg.get("timeout_s", 180))

    provider_ram = provider_ram or spec029.resolve_provider_ram(cfg)
    cell = normalized_cell if normalized_cell is not None else spec029.sweep_cell_from_config(cfg)
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
        "host_ram_bytes": provider_ram.host_ram_bytes,
        "ram_tier_key": provider_ram.ram_tier_key,
        "provider_ram_source": provider_ram.source,
        "cell_execution_source": cell_execution_source,
        "non_runnable_reason": metrics.get("non_runnable_reason"),
        "corpus_class": spec029.corpus_class_for_workload(name),
        "max_context_override": cell.get("max_context_override"),
        "max_concurrency_override": cell.get("max_concurrency_override"),
        "kv_bits": cell.get("kv_bits"),
        "metric_unavailable_reason": spec029.metric_unavailable_reason(
            metrics.get("prompt_tokens"),
            metrics.get("completion_tokens"),
            metrics.get("throughput_tps"),
        ),
        "draft_model": cell.get("draft_model"),
        "draft_model_artifact_sha256": cell.get("draft_model_artifact_sha256"),
        "num_draft_tokens": cell.get("num_draft_tokens"),
        "drafted_tokens": metrics.get("drafted_tokens"),
        "accepted_tokens": metrics.get("accepted_tokens"),
        "spec_decode_acceptance_rate": metrics.get("spec_decode_acceptance_rate"),
        "candidate_source": cell.get("candidate_source"),
        "winner_status": None,
        "no_winner_reason": None,
        "stop_token_leak": int(bool(metrics.get("stop_token_leak"))),
        "error": metrics.get("error"),
        "response_preview": metrics.get("response_preview"),
    }
    cur = conn.execute(
        """INSERT INTO runs (ts_utc, workload, model, tunnel_url, streamed,
                              http_status, ttft_ms, total_ms, prompt_tokens,
                              completion_tokens, throughput_tps, host_ram_bytes,
                              ram_tier_key, provider_ram_source, cell_execution_source,
                              non_runnable_reason, corpus_class, max_context_override,
                              max_concurrency_override, kv_bits,
                              metric_unavailable_reason, draft_model,
                              draft_model_artifact_sha256, num_draft_tokens,
                              drafted_tokens, accepted_tokens,
                              spec_decode_acceptance_rate, candidate_source,
                              winner_status, no_winner_reason, stop_token_leak,
                              error, response_preview)
           VALUES (:ts_utc, :workload, :model, :tunnel_url, :streamed,
                   :http_status, :ttft_ms, :total_ms, :prompt_tokens,
                   :completion_tokens, :throughput_tps, :host_ram_bytes,
                   :ram_tier_key, :provider_ram_source, :cell_execution_source,
                   :non_runnable_reason, :corpus_class, :max_context_override,
                   :max_concurrency_override, :kv_bits,
                   :metric_unavailable_reason, :draft_model,
                   :draft_model_artifact_sha256, :num_draft_tokens,
                   :drafted_tokens, :accepted_tokens,
                   :spec_decode_acceptance_rate, :candidate_source,
                   :winner_status, :no_winner_reason, :stop_token_leak,
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


def run_spec029_sweep(cfg: dict, conn: sqlite3.Connection, verbose: bool, dry_run: bool) -> list[dict]:
    provider_ram = spec029.resolve_provider_ram(cfg, require=True)
    if provider_ram.host_ram_bytes is None:
        raise RuntimeError("SPEC-029 sweep requires provider_host_ram_bytes or provider_ram_gib")
    targets = spec029.spec029_workloads_from_config(cfg)
    cells = spec029.sweep_cells_from_config(cfg, require_grid=True)
    samples_per_cell = spec029.spec029_samples_per_cell(cfg)
    validate_spec029_cell_execution_config(cfg, dry_run)
    rows: list[dict] = []

    if verbose:
        print(
            "harness: SPEC-029 sweep "
            f"model={cfg['model']} provider_ram_tier={provider_ram.ram_tier_key} "
            f"cells={len(cells)} workloads={len(targets)} samples_per_cell={samples_per_cell}"
        )

    for name in targets:
        for cell in cells:
            try:
                cell_execution_source = apply_spec029_cell(cfg, cell, dry_run, verbose=verbose)
            except Spec029CellApplyError as exc:
                rows.append(
                    run_one(
                        cfg,
                        name,
                        conn,
                        verbose,
                        dry_run,
                        cell=cell,
                        force_stream=True,
                        provider_ram=provider_ram,
                        cell_execution_source="cell_apply_failed",
                        metrics_override={
                            "error": str(exc),
                            "non_runnable_reason": "cell_apply_failed",
                            "response_preview": str(exc)[:300],
                        },
                    )
                )
                continue
            for _ in range(samples_per_cell):
                rows.append(
                    run_one(
                        cfg,
                        name,
                        conn,
                        verbose,
                        dry_run,
                        cell=cell,
                        force_stream=True,
                        provider_ram=provider_ram,
                        cell_execution_source=cell_execution_source,
                    )
                )
    return rows


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
        help="fire a batch list from config. PROFILE is 'cooperative' (default), 'adversarial', or 'spec029'.",
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
        profile = args.batch  # None | "cooperative" | "adversarial" | "spec029"
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
        elif profile == "spec029":
            rows = run_spec029_sweep(cfg, conn, args.verbose, args.dry_run)
            failures = sum(
                1 for row in rows
                if row.get("error") or (row.get("http_status") and row["http_status"] != 200)
            )
            if args.verbose:
                print(f"harness: done, {failures} failure(s)")
            return 0 if failures == 0 else 1
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

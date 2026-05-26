"""
Adversarial workloads for Phase 2.

These differ from cooperative workloads (workloads.py): instead of returning a
single request body for the harness to fire, each adversarial workload is a
function that takes (url, model, timeout) and runs its own HTTP storm or
edge-case probe, returning aggregate metrics.

Contract:
    def workload(url: str, model: str, timeout: float) -> dict
returning a dict with at least:
    n_requests:     total requests fired (int)
    n_ok:           HTTP 200 count (int)
    n_errors:       n_requests - n_ok (int)
    total_ms:       wall-clock for the whole workload (float)
    median_ms:      median per-request latency (float | None)
    p95_ms:         p95 per-request latency (float | None)
    error_summary:  short string describing dominant error class (str | None)
    notes:          arbitrary extra info (str | None)
"""

from __future__ import annotations

import statistics
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

import requests


def _percentile(xs: list[float], pct: float) -> float | None:
    """Naive percentile — fine for N up to a few thousand."""
    if not xs:
        return None
    s = sorted(xs)
    k = max(0, min(len(s) - 1, int(round((pct / 100.0) * (len(s) - 1)))))
    return s[k]


def _summarize_errors(errors: list[str]) -> str | None:
    if not errors:
        return None
    counts: dict[str, int] = {}
    for e in errors:
        key = e.split(":", 1)[0].strip() or "Unknown"
        counts[key] = counts.get(key, 0) + 1
    parts = sorted(counts.items(), key=lambda kv: -kv[1])
    return ", ".join(f"{n}x {k}" for k, n in parts[:4])


def _fire_one(url: str, model: str, body: dict, timeout: float) -> tuple[int | None, float, str | None]:
    """Fire one request, return (status, ms, error_str_or_None)."""
    t0 = time.monotonic()
    try:
        r = requests.post(url, json={"model": model, **body, "stream": False}, timeout=timeout)
        ms = (time.monotonic() - t0) * 1000
        if r.status_code != 200:
            return r.status_code, ms, f"HTTP{r.status_code}"
        return r.status_code, ms, None
    except requests.RequestException as e:
        ms = (time.monotonic() - t0) * 1000
        return None, ms, f"{type(e).__name__}"


def retry_storm(url: str, model: str, timeout: float) -> dict[str, Any]:
    """
    Fire 50 requests as fast as possible (target: <5s wall time) and measure
    survival. Tests overload behavior and queueing characteristics. Does not
    actually wait for failures and retry — the name is conventional; this is
    a flat burst.
    """
    n = 50
    body = {
        "messages": [{"role": "user", "content": "Reply with the single word: ok"}],
        "max_tokens": 8,
    }

    t0 = time.monotonic()
    latencies: list[float] = []
    errors: list[str] = []
    statuses: list[int | None] = []

    # 50 threads is overkill but safe — requests will block on the server's
    # ability to accept new connections, which is the data we want.
    with ThreadPoolExecutor(max_workers=50) as ex:
        futures = [ex.submit(_fire_one, url, model, body, timeout) for _ in range(n)]
        for f in as_completed(futures):
            status, ms, err = f.result()
            latencies.append(ms)
            statuses.append(status)
            if err:
                errors.append(err)

    total_ms = (time.monotonic() - t0) * 1000
    n_ok = sum(1 for s in statuses if s == 200)
    return {
        "n_requests": n,
        "n_ok": n_ok,
        "n_errors": n - n_ok,
        "total_ms": total_ms,
        "median_ms": statistics.median(latencies) if latencies else None,
        "p95_ms": _percentile(latencies, 95),
        "error_summary": _summarize_errors(errors),
        "notes": f"burst of {n} concurrent requests",
    }


# ── Colony-themed filler (same prose as scripts/long_context_test.py) ──
_FILLER_SENTENCES = [
    "The ant colony observed the unusual movement near the eastern boundary marker.",
    "Scouts returned with reports of an abandoned beetle carcass beside the river stones.",
    "Worker bees from a neighboring hive sometimes share pollen sources during dry seasons.",
    "The queen recorded each foraging route in her chemical memory for later retrieval.",
    "Soldiers patrolled the inner chambers throughout the night shift without incident.",
    "Younger ants learned trail-laying behavior from the experienced foragers they shadowed.",
    "Temperature gradients near the surface tunnels signaled approaching weather changes.",
    "Fungus gardens required precise humidity control maintained by specialized workers.",
    "The colony's defensive perimeter expanded gradually each summer as numbers grew.",
    "Aphid herding produced a steady honeydew supply during the dry midsummer weeks.",
    "Communication pheromones varied in volatility depending on the urgency of the message.",
    "Tunnel architecture evolved over generations to optimize airflow and traffic patterns.",
    "Some workers specialized in undertaking, removing fallen colony members to the midden.",
    "The boundary disputes with the rival colony rarely escalated beyond ritual posturing.",
    "Seed harvesting expeditions required coordination across multiple foraging columns.",
    "Repair crews mobilized within minutes of any structural damage to the main galleries.",
]


def long_context_oom_probe(url: str, model: str, timeout: float) -> dict[str, Any]:
    """
    Build a ~30,000-token prompt and fire once. Phase 1 found Llama-3.2-3B
    OOMs at ~26K on M1 8GB. Expected: success (M4 has more RAM), HTTP 500
    (server caught it), or ConnectionError (server crashed).
    """
    # ~12 tokens per sentence, need ~30K tokens => ~2500 sentences
    filler = " ".join(_FILLER_SENTENCES * 160)  # ~160*16 = 2560 sentences
    body = {
        "messages": [
            {"role": "system", "content": filler},
            {"role": "user", "content": "In one sentence, summarize the theme above."},
        ],
        "max_tokens": 30,
    }
    t0 = time.monotonic()
    status = None
    err = None
    try:
        r = requests.post(url, json={"model": model, **body, "stream": False}, timeout=timeout)
        status = r.status_code
        if r.status_code != 200:
            err = "HTTP{}".format(r.status_code)
    except requests.RequestException as e:
        err = "{}: {}".format(type(e).__name__, e)
    total_ms = (time.monotonic() - t0) * 1000
    n_ok = 1 if status == 200 else 0
    outcome = "success" if n_ok else ("crash/timeout" if status is None else "server_error_{}".format(status))
    return {
        "n_requests": 1,
        "n_ok": n_ok,
        "n_errors": 1 - n_ok,
        "total_ms": total_ms,
        "median_ms": total_ms,
        "p95_ms": total_ms,
        "error_summary": err,
        "notes": "~30K-token OOM probe; outcome={}".format(outcome),
    }


def concurrent_burst_8way(url: str, model: str, timeout: float) -> dict[str, Any]:
    """
    8 concurrent medium-sized requests (~500 input, ~200 output tokens).
    Tests inference contention (not connection contention like retry_storm).
    """
    n = 8
    context = " ".join(_FILLER_SENTENCES * 3)  # ~500 tokens
    body = {
        "messages": [
            {"role": "system", "content": context},
            {"role": "user", "content": "Explain the colony's defensive strategy in detail."},
        ],
        "max_tokens": 200,
    }
    t0 = time.monotonic()
    latencies: list[float] = []
    errors: list[str] = []
    statuses: list[int | None] = []

    with ThreadPoolExecutor(max_workers=n) as ex:
        futures = [ex.submit(_fire_one, url, model, body, timeout) for _ in range(n)]
        for f in as_completed(futures):
            status, ms, err = f.result()
            latencies.append(ms)
            statuses.append(status)
            if err:
                errors.append(err)

    total_ms = (time.monotonic() - t0) * 1000
    n_ok = sum(1 for s in statuses if s == 200)
    return {
        "n_requests": n,
        "n_ok": n_ok,
        "n_errors": n - n_ok,
        "total_ms": total_ms,
        "median_ms": statistics.median(latencies) if latencies else None,
        "p95_ms": _percentile(latencies, 95),
        "error_summary": _summarize_errors(errors),
        "notes": "8-way concurrent burst, ~500 in / ~200 out per request",
    }


def midstream_disconnect(url: str, model: str, timeout: float) -> dict[str, Any]:
    """
    Fire 10 sequential streaming requests, close the response after the
    first SSE chunk each time. Verifies the server doesn't leak request
    slots or stay stuck after client disconnects.
    """
    n = 10
    body = {
        "messages": [{"role": "user", "content": "Count from 1 to 100, one number per line."}],
        "max_tokens": 400,
    }
    t0 = time.monotonic()
    latencies: list[float] = []
    errors: list[str] = []
    started_streaming = 0

    for _ in range(n):
        req_t0 = time.monotonic()
        try:
            with requests.post(url, json={"model": model, **body, "stream": True},
                               timeout=timeout, stream=True) as r:
                if r.status_code != 200:
                    ms = (time.monotonic() - req_t0) * 1000
                    latencies.append(ms)
                    errors.append("HTTP{}".format(r.status_code))
                    continue
                # Read just the first chunk then close
                for line in r.iter_lines(decode_unicode=True):
                    if line and line.startswith("data: "):
                        started_streaming += 1
                        break
            ms = (time.monotonic() - req_t0) * 1000
            latencies.append(ms)
        except requests.RequestException as e:
            ms = (time.monotonic() - req_t0) * 1000
            latencies.append(ms)
            errors.append("{}".format(type(e).__name__))

    total_ms = (time.monotonic() - t0) * 1000
    n_ok = started_streaming
    return {
        "n_requests": n,
        "n_ok": n_ok,
        "n_errors": n - n_ok,
        "total_ms": total_ms,
        "median_ms": statistics.median(latencies) if latencies else None,
        "p95_ms": _percentile(latencies, 95),
        "error_summary": _summarize_errors(errors) if errors else None,
        "notes": "{}/{} started streaming before disconnect".format(started_streaming, n),
    }


def malformed_tool_call(url: str, model: str, timeout: float) -> dict[str, Any]:
    """
    Send 5 requests with deliberately broken tool-call JSON in the messages
    payload. Records HTTP status distribution to see whether the server
    gracefully rejects (4xx) or crashes (5xx / ConnectionError).
    """
    variants = [
        # 1) Unterminated string in tool_calls content
        {"role": "assistant", "content": None, "tool_calls": [
            {"id": "call_1", "type": "function", "function": {"name": "test", "arguments": '{"key": "unterminated'}}
        ]},
        # 2) Invalid JSON in function arguments
        {"role": "assistant", "content": None, "tool_calls": [
            {"id": "call_2", "type": "function", "function": {"name": "test", "arguments": "{not valid json at all}"}}
        ]},
        # 3) Missing function name
        {"role": "assistant", "content": None, "tool_calls": [
            {"id": "call_3", "type": "function", "function": {"arguments": '{"x": 1}'}}
        ]},
        # 4) Empty tool_calls array with tool role response
        {"role": "tool", "content": "result", "tool_call_id": "nonexistent_call"},
        # 5) Nested garbage in tool call
        {"role": "assistant", "content": None, "tool_calls": [
            {"id": "call_5", "type": "function", "function": {"name": "a" * 500, "arguments": "[" * 100}}
        ]},
    ]

    t0 = time.monotonic()
    latencies: list[float] = []
    errors: list[str] = []
    statuses: list[int | None] = []
    status_counts: dict[str, int] = {}

    for variant_msg in variants:
        messages = [
            {"role": "user", "content": "Hello"},
            variant_msg,
            {"role": "user", "content": "Continue"},
        ]
        body = {"messages": messages, "max_tokens": 20}
        status, ms, err = _fire_one(url, model, body, timeout)
        latencies.append(ms)
        statuses.append(status)
        if err:
            errors.append(err)
        key = str(status) if status else "ConnectionError"
        status_counts[key] = status_counts.get(key, 0) + 1

    total_ms = (time.monotonic() - t0) * 1000
    n_ok = sum(1 for s in statuses if s == 200)
    dist = ", ".join("{}x {}".format(v, k) for k, v in sorted(status_counts.items(), key=lambda kv: -kv[1]))
    return {
        "n_requests": len(variants),
        "n_ok": n_ok,
        "n_errors": len(variants) - n_ok,
        "total_ms": total_ms,
        "median_ms": statistics.median(latencies) if latencies else None,
        "p95_ms": _percentile(latencies, 95),
        "error_summary": _summarize_errors(errors) if errors else None,
        "notes": "status distribution: {}".format(dist),
    }


REGISTRY = {
    "retry_storm": retry_storm,
    "long_context_oom_probe": long_context_oom_probe,
    "concurrent_burst_8way": concurrent_burst_8way,
    "midstream_disconnect": midstream_disconnect,
    "malformed_tool_call": malformed_tool_call,
}

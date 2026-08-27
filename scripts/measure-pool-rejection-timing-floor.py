#!/usr/bin/env python3
"""Measure SPEC-043-R007 pool_unavailable rejection timing.

This script does not claim a production remeasure by default. Isolated-candidate
CONFORMANCE already recorded a harness floor; live announcement still needs an
operator-run production remeasure against the production gateway.

Do not point this at coordinator.malibu.tech / production hosts unless you pass
both --environment production and --allow-production.
"""

from __future__ import annotations

import argparse
import json
import math
import ssl
import sys
import urllib.error
import urllib.request
from typing import Any
from urllib.parse import urlparse


PRODUCTION_HOSTS = {
    "coordinator.malibu.tech",
    "api.malibu.tech",
    "get.malibu.tech",
    "malibu.tech",
    "www.malibu.tech",
}

REQUIRED_CLASSES = ("unknown", "unauthorized", "disabled")
MIN_SAMPLES = 8
MIN_FLOOR_MS = 50
MAX_P95_DELTA_MS = 15.0
MAX_P99_DELTA_MS = 25.0
MIN_MANN_WHITNEY_P = 0.01


def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    if p <= 0:
        return ordered[0]
    if p >= 1:
        return ordered[-1]
    # Inclusive nearest-rank so p99 on the default 16-sample run uses the last
    # observation. Floor-index ((n-1)*p) would ignore a slow tail and could
    # mark a production remeasure complete.
    rank = math.ceil(p * len(ordered))
    idx = min(max(int(rank) - 1, 0), len(ordered) - 1)
    return ordered[idx]


def mann_whitney_p_value(left: list[float], right: list[float]) -> float:
    n1 = float(len(left))
    n2 = float(len(right))
    if n1 == 0 or n2 == 0:
        return 1.0
    combined = list(left) + list(right)
    labels = [0] * len(left) + [1] * len(right)
    order = sorted(range(len(combined)), key=lambda i: combined[i])
    ranks = [0.0] * len(combined)
    i = 0
    while i < len(order):
        j = i + 1
        while j < len(order) and combined[order[j]] == combined[order[i]]:
            j += 1
        avg = float(i + 1 + j) / 2.0
        for k in range(i, j):
            ranks[order[k]] = avg
        i = j
    r1 = sum(ranks[i] for i, label in enumerate(labels) if label == 0)
    u1 = r1 - n1 * (n1 + 1) / 2
    u2 = n1 * n2 - u1
    u = min(u1, u2)
    mu = n1 * n2 / 2
    sorted_vals = sorted(combined)
    tie_term = 0.0
    i = 0
    while i < len(sorted_vals):
        j = i + 1
        while j < len(sorted_vals) and sorted_vals[j] == sorted_vals[i]:
            j += 1
        tie_count = float(j - i)
        if tie_count > 1:
            tie_term += tie_count * tie_count * tie_count - tie_count
        i = j
    n = n1 + n2
    sigma2 = n1 * n2 / 12 * ((n + 1) - (tie_term / (n * (n - 1)) if n > 1 else 0.0))
    if sigma2 <= 0:
        return 1.0
    z = (abs(u - mu) - 0.5) / math.sqrt(sigma2)
    p = math.erfc(z / math.sqrt(2.0))
    return min(max(p, 0.0), 1.0)


def evaluate_samples(
    samples: dict[str, list[float]],
    *,
    floor_ms: int,
    method: str,
) -> dict[str, Any]:
    missing = [name for name in REQUIRED_CLASSES if name not in samples]
    if missing:
        raise SystemExit(f"samples missing classes: {missing}")
    for name, values in samples.items():
        if len(values) < MIN_SAMPLES:
            raise SystemExit(f"{name} needs at least {MIN_SAMPLES} samples, got {len(values)}")
        for value in values:
            if value + 1e-9 < floor_ms:
                raise SystemExit(f"{name} sample {value} is below floor_ms={floor_ms}")
    pairs = (
        ("unknown", "unauthorized"),
        ("unknown", "disabled"),
        ("unauthorized", "disabled"),
    )
    max_p95 = 0.0
    max_p99 = 0.0
    min_p = 1.0
    for left_name, right_name in pairs:
        left = samples[left_name]
        right = samples[right_name]
        p95 = abs(percentile(left, 0.95) - percentile(right, 0.95))
        p99 = abs(percentile(left, 0.99) - percentile(right, 0.99))
        p_value = mann_whitney_p_value(left, right)
        max_p95 = max(max_p95, p95)
        max_p99 = max(max_p99, p99)
        min_p = min(min_p, p_value)
    within_bounds = (
        max_p95 <= MAX_P95_DELTA_MS
        and max_p99 <= MAX_P99_DELTA_MS
        and min_p >= MIN_MANN_WHITNEY_P
        and floor_ms >= MIN_FLOOR_MS
    )
    return {
        "floor_ms": floor_ms,
        "method": method,
        "sample_count_per_class": min(len(samples[name]) for name in REQUIRED_CLASSES),
        "classes_covered": list(REQUIRED_CLASSES),
        "unknown_p50_ms": percentile(samples["unknown"], 0.50),
        "unauthorized_p50_ms": percentile(samples["unauthorized"], 0.50),
        "disabled_p50_ms": percentile(samples["disabled"], 0.50),
        "p95_delta_ms": max_p95,
        "p99_delta_ms": max_p99,
        "mann_whitney_p_value": min_p,
        "statistical_test": "two-sided Mann-Whitney U with normal approximation; fail if p < 0.01",
        "within_r007_bounds": within_bounds,
    }


def hostname_of(url: str) -> str:
    host = (urlparse(url).hostname or "").lower().rstrip(".")
    if host.startswith("www."):
        return host[4:]
    return host


def is_production_host(url: str) -> bool:
    host = hostname_of(url)
    if host in PRODUCTION_HOSTS:
        return True
    return any(host.endswith("." + name) for name in PRODUCTION_HOSTS)


def load_samples_json(path: str) -> dict[str, list[float]]:
    with open(path, encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise SystemExit("samples JSON must be an object of class -> number list")
    out: dict[str, list[float]] = {}
    for name, values in payload.items():
        if not isinstance(values, list) or not values:
            raise SystemExit(f"samples[{name}] must be a non-empty list")
        out[str(name)] = [float(value) for value in values]
    return out


def measure_http(
    base_url: str,
    *,
    unknown_pool_id: str,
    pool_id: str,
    authorized_account: str,
    unauthorized_account: str,
    samples: int,
    timeout_s: float,
) -> dict[str, list[float]]:
    import time

    def one(account: str, select_pool: str) -> float:
        body = json.dumps(
            {
                "model": "probe",
                "messages": [{"role": "user", "content": "timing-floor-probe"}],
            }
        ).encode("utf-8")
        req = urllib.request.Request(
            base_url.rstrip("/") + "/v1/chat/completions",
            data=body,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "X-MacProvider-Account": account,
                "X-MacProvider-Pool-Select": select_pool,
            },
        )
        ctx = ssl.create_default_context()
        start = time.perf_counter()
        try:
            with urllib.request.urlopen(req, timeout=timeout_s, context=ctx) as resp:
                payload = resp.read()
                status = resp.status
        except urllib.error.HTTPError as exc:
            payload = exc.read()
            status = exc.code
        elapsed_ms = (time.perf_counter() - start) * 1000.0
        text = payload.decode("utf-8", errors="replace")
        if status not in (404, 503) or "pool_unavailable" not in text:
            raise SystemExit(f"unexpected rejection status={status} body={text[:300]}")
        return elapsed_ms

    measured = {"unknown": [], "unauthorized": [], "disabled": []}
    for _ in range(samples):
        measured["unknown"].append(one(authorized_account, unknown_pool_id))
        measured["unauthorized"].append(one(unauthorized_account, pool_id))
        measured["disabled"].append(one(authorized_account, pool_id))
    return measured


def build_result(
    timing: dict[str, Any],
    *,
    environment: str,
    source: str,
    production_host: bool,
    allow_production: bool,
) -> dict[str, Any]:
    production_remeasure_complete = bool(
        environment == "production"
        and allow_production
        and production_host
        and source == "http"
        and timing.get("within_r007_bounds") is True
    )
    return {
        "environment": environment,
        "source": source,
        "production_host": production_host,
        "production_remeasure_complete": production_remeasure_complete,
        "pool_rejection_timing": {k: v for k, v in timing.items() if k != "within_r007_bounds"},
        "within_r007_bounds": timing["within_r007_bounds"],
        "notes": [
            "Isolated-candidate CONFORMANCE is not a live Trusted Pool launch.",
            "This script does not fill CONFORMANCE evidence[].",
            "A production remeasure is complete only when environment=production, "
            "--allow-production is set, HTTP samples were taken from a production host, "
            "and R007 bounds pass.",
        ],
    }


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples-json", help="local class -> millisecond samples; does not hit the network")
    parser.add_argument("--base-url", help="OpenAI-compatible gateway base URL")
    parser.add_argument("--environment", default="local", help="local, staging, or production")
    parser.add_argument("--allow-production", action="store_true", help="required to target a production host")
    parser.add_argument("--floor-ms", type=int, default=MIN_FLOOR_MS)
    parser.add_argument("--samples", type=int, default=16)
    parser.add_argument("--method", default="operator_http_probe")
    parser.add_argument("--unknown-pool-id", default="zzzzzzzzzzzzzzzzzzzzzz")
    parser.add_argument("--pool-id", default="")
    parser.add_argument("--authorized-account", default="")
    parser.add_argument("--unauthorized-account", default="")
    parser.add_argument("--timeout-s", type=float, default=10.0)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.floor_ms < MIN_FLOOR_MS:
        raise SystemExit(f"--floor-ms must be >= {MIN_FLOOR_MS}")
    if args.samples < MIN_SAMPLES:
        raise SystemExit(f"--samples must be >= {MIN_SAMPLES}")
    production_host = False
    if args.samples_json:
        if args.base_url:
            raise SystemExit("pass either --samples-json or --base-url, not both")
        source = "samples-json"
        samples = load_samples_json(args.samples_json)
        method = "offline_samples_json"
    elif args.base_url:
        production_host = is_production_host(args.base_url)
        if production_host and (args.environment != "production" or not args.allow_production):
            raise SystemExit(
                "refusing production host without --environment production and --allow-production"
            )
        if args.environment == "production" and not args.allow_production:
            raise SystemExit("production environment requires --allow-production")
        if not args.pool_id or not args.authorized_account or not args.unauthorized_account:
            raise SystemExit("--pool-id, --authorized-account, and --unauthorized-account are required for HTTP measure")
        source = "http"
        samples = measure_http(
            args.base_url,
            unknown_pool_id=args.unknown_pool_id,
            pool_id=args.pool_id,
            authorized_account=args.authorized_account,
            unauthorized_account=args.unauthorized_account,
            samples=args.samples,
            timeout_s=args.timeout_s,
        )
        method = args.method
    else:
        raise SystemExit("provide --samples-json (offline) or --base-url (HTTP)")

    timing = evaluate_samples(samples, floor_ms=args.floor_ms, method=method)
    result = build_result(
        timing,
        environment=args.environment,
        source=source,
        production_host=production_host,
        allow_production=args.allow_production,
    )
    json.dump(result, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    if not timing["within_r007_bounds"]:
        return 2
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(0)

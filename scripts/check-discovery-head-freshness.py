#!/usr/bin/env python3
"""Alarm check for the signed release-discovery head freshness.

Reads a signed release-discovery head JSON on stdin and fails (exit 1) when the
head is already expired or within --min-hours of expiry, so a missed/late renewal
is caught BEFORE the coordinator-independent self-heal rail lapses fleet-wide.

Read-only: no secrets, no network, no signature trust decision (that is the
client's job) — this only reads the self-asserted validity window to alarm on
staleness. Intended to run on a schedule far more often than the renewal cadence.

Usage:
  gh release download <latest release-discovery-v1-*> --pattern macprovider-release-discovery.json -O - \
    | python3 scripts/check-discovery-head-freshness.py --min-hours 48
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys


def fail(message: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"[discovery-head-freshness] ALARM: {message}", file=sys.stderr)
    raise SystemExit(1)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--min-hours",
        type=float,
        default=48.0,
        help="alarm if the head expires within this many hours (default 48)",
    )
    args = parser.parse_args(argv)
    if args.min_hours < 0:
        fail("--min-hours must be non-negative")

    raw = sys.stdin.read()
    if not raw.strip():
        fail("no discovery head on stdin (could not resolve/download the latest head?)")
    try:
        head = json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(f"discovery head is not valid JSON: {exc}")
    if not isinstance(head, dict):
        fail("discovery head must be a JSON object")

    signed = head.get("signed")
    if not isinstance(signed, dict):
        fail("discovery head has no 'signed' object")
    expires_raw = signed.get("expires_at")
    if not isinstance(expires_raw, str) or not expires_raw:
        fail("discovery head 'signed.expires_at' is missing")
    try:
        expires = dt.datetime.strptime(expires_raw, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=dt.timezone.utc
        )
    except ValueError as exc:
        fail(f"unparseable expires_at {expires_raw!r}: {exc}")

    now = dt.datetime.now(dt.timezone.utc)
    remaining_hours = (expires - now).total_seconds() / 3600.0
    issued = signed.get("issued_at", "?")
    print(
        f"[discovery-head-freshness] issued={issued} expires={expires_raw} "
        f"remaining={remaining_hours:.1f}h threshold={args.min_hours:.1f}h"
    )
    if remaining_hours <= 0:
        fail(
            f"self-heal discovery head is EXPIRED ({-remaining_hours:.1f}h ago) — "
            f"the coordinator-independent recovery rail is DOWN; renew now."
        )
    if remaining_hours < args.min_hours:
        fail(
            f"self-heal discovery head expires in {remaining_hours:.1f}h "
            f"(< {args.min_hours:.1f}h) — dispatch/approve a renewal before it lapses."
        )
    print("[discovery-head-freshness] OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

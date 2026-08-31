#!/usr/bin/env python3
"""Alarm check for the live SPEC-023 autotune rate-card freshness.

Reads a rate-card JSON object on stdin and fails (exit 1) when `generated_at`
is missing, unparseable, more than 10 minutes in the future, or at least
`--max-age-days` old (default 20; inclusive). The client 30-day horizon
(`AutotuneRecommend.swift` `loadSignedStatic`) fails closed with
`rate_card_update_required` and strands any provider that restarts; this
check is the read-only backstop that fires *before* that happens.

Read-only: no secrets, no network, no signature trust decision (that is the
client's job) — this only reads the self-asserted `generated_at`. Intended
to run on a schedule far more often than the weekly operator-local renewal.

Usage:
  curl -fsS --proto '=https' --tlsv1.2 --max-time 20 \\
    https://coordinator.malibu.tech/v1/rate-card \\
    | python3 scripts/check-autotune-feed-freshness.py --max-age-days 20
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys


CLIENT_HORIZON_DAYS = 30.0
FUTURE_SKEW_MINUTES = 10.0


def fail(message: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"[autotune-feed-freshness] ALARM: {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_rfc3339_z(value: str, label: str) -> dt.datetime:
    try:
        parsed = dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=dt.timezone.utc
        )
    except ValueError as exc:
        fail(f"unparseable {label} {value!r}: {exc}")
    return parsed


def check_rate_card(
    payload: dict[str, object],
    *,
    now: dt.datetime,
    max_age_days: float,
) -> None:
    generated_raw = payload.get("generated_at")
    if not isinstance(generated_raw, str) or not generated_raw:
        fail("rate-card 'generated_at' is missing")
    generated = parse_rfc3339_z(generated_raw, "generated_at")

    skew_seconds = (generated - now).total_seconds()
    if skew_seconds > FUTURE_SKEW_MINUTES * 60.0:
        fail(
            f"rate-card generated_at is {skew_seconds / 60.0:.1f}min in the future "
            f"(> {FUTURE_SKEW_MINUTES:.0f}min) — clients reject future-dated feeds; "
            "do not publish until clocks agree."
        )

    age_days = (now - generated).total_seconds() / 86400.0
    remaining_days = CLIENT_HORIZON_DAYS - age_days
    print(
        f"[autotune-feed-freshness] generated_at={generated_raw} "
        f"age={age_days:.1f}d remaining_to_30d={remaining_days:.1f}d "
        f"threshold={max_age_days:.1f}d"
    )
    # Client accepts age == 30d (`timeIntervalSince <= 30 * 24 * 3600`) and
    # rejects only once age exceeds that. Reserve EXPIRED for the strict past.
    if remaining_days < 0:
        fail(
            f"live /v1/rate-card generated_at is EXPIRED "
            f"({-remaining_days:.1f}d past the client 30-day horizon) — "
            "providers that restart cannot rejoin; run "
            "scripts/renew-autotune-static-feed.sh --deploy on the signing host now."
        )
    if age_days >= max_age_days:
        fail(
            f"live /v1/rate-card generated_at is {age_days:.1f}d old "
            f"(>= {max_age_days:.1f}d) — {remaining_days:.1f}d remain before the "
            "client 30-day fail-closed. Run "
            "scripts/renew-autotune-static-feed.sh --deploy on the signing host."
        )
    print("[autotune-feed-freshness] OK")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--max-age-days",
        type=float,
        default=20.0,
        help="alarm if generated_at is this many days old (default 20; must be < 30)",
    )
    parser.add_argument(
        "--now",
        default=None,
        help="RFC3339 UTC timestamp ending in Z; override wall clock (tests only)",
    )
    args = parser.parse_args(argv)
    if args.max_age_days <= 0:
        fail("--max-age-days must be positive")
    if args.max_age_days >= CLIENT_HORIZON_DAYS:
        fail(
            "--max-age-days must be < 30 (the client fail-closed horizon); "
            "an alarm at or past 30d fires too late to protect the fleet"
        )

    if args.now is None:
        now = dt.datetime.now(dt.timezone.utc)
    else:
        now = parse_rfc3339_z(args.now, "--now")

    raw = sys.stdin.read()
    if not raw.strip():
        fail("no rate-card on stdin (could not fetch /v1/rate-card?)")
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(f"rate-card is not valid JSON: {exc}")
    if not isinstance(payload, dict):
        fail("rate-card must be a JSON object")

    check_rate_card(payload, now=now, max_age_days=args.max_age_days)
    return 0


if __name__ == "__main__":
    sys.exit(main())

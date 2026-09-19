#!/usr/bin/env python3
"""Fail-loud OpenRouter fetch-side health check.

The pricing engine and `propose` mode read OPENROUTER_API_KEY from the
environment and fail closed on HTTP errors, but nothing scheduled that
failure until this alarm. A dead key (HTTP 401/403) used to freeze the
catalog pipeline silently. This check:

1. Probes the documented OpenRouter key endpoint.
2. ALARMs on missing key, 401/403, or any non-2xx (never prints the key).
3. Optionally ALARMs when the local snapshot/proposal archive is older
   than the 48-hour pricing-staleness window in
   docs/runbooks/openrouter-pricing-engine.md.

Read-only against the market: no catalog write, no sign, no Pearl deploy.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable

KEY_URL = "https://openrouter.ai/api/v1/key"
ARCHIVE_GLOBS = (
    "openrouter-pricing-snapshot-*.json",
    "openrouter-catalog-proposal-*.json",
)
DEFAULT_MAX_SNAPSHOT_AGE_HOURS = 48.0
FUTURE_SKEW_MINUTES = 10.0


def fail(message: str) -> None:
    print(f"[openrouter-fetch-health] ALARM: {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_rfc3339_z(value: str, label: str) -> dt.datetime:
    try:
        return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=dt.timezone.utc
        )
    except ValueError as exc:
        fail(f"unparseable {label} {value!r}: {exc}")
        raise  # unreachable; keeps type-checkers honest


def check_key_status(status: int) -> None:
    if status in {401, 403}:
        fail(
            f"OPENROUTER_API_KEY rejected (HTTP {status}) at {KEY_URL}. "
            "The catalog proposer cannot fetch; rotate the key into "
            "GitHub secret OPENROUTER_API_KEY and the host-local operator "
            "path. Do not print the key."
        )
    if status < 200 or status >= 300:
        fail(
            f"OpenRouter key probe failed (HTTP {status}) at {KEY_URL}. "
            "Fetch is not healthy; inspect OpenRouter status before any "
            "pricing or propose run."
        )
    print(f"[openrouter-fetch-health] key probe HTTP {status} OK")


def artifact_generated_at(path: Path) -> dt.datetime | None:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict):
        return None
    raw = payload.get("generated_at")
    if not isinstance(raw, str) or not raw:
        return None
    try:
        return dt.datetime.strptime(raw, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=dt.timezone.utc
        )
    except ValueError:
        return None


def newest_archive_artifact(archive: Path) -> tuple[Path, dt.datetime] | None:
    newest: tuple[Path, dt.datetime] | None = None
    for pattern in ARCHIVE_GLOBS:
        for path in archive.glob(pattern):
            generated = artifact_generated_at(path)
            if generated is None:
                continue
            if newest is None or generated > newest[1]:
                newest = (path, generated)
    return newest


def check_snapshot_archive(
    archive: Path,
    *,
    now: dt.datetime,
    max_age_hours: float,
) -> None:
    if max_age_hours <= 0:
        fail("--max-snapshot-age-hours must be positive")
    if not archive.is_dir():
        fail(
            f"snapshot archive {archive} is missing — the fetch pipeline has "
            "never landed an artifact; run fetch/propose and archive it, or "
            "the catalog proposer is frozen."
        )
    newest = newest_archive_artifact(archive)
    if newest is None:
        fail(
            f"snapshot archive {archive} has no snapshot or catalog-proposal "
            f"JSON matching {ARCHIVE_GLOBS} with generated_at. Fetch/propose "
            "is frozen until a successful run is archived."
        )
    path, generated = newest
    skew_seconds = (generated - now).total_seconds()
    if skew_seconds > FUTURE_SKEW_MINUTES * 60.0:
        fail(
            f"{path.name} generated_at is {skew_seconds / 60.0:.1f}min in the "
            f"future (>{FUTURE_SKEW_MINUTES:.0f}min)"
        )
    age_hours = (now - generated).total_seconds() / 3600.0
    print(
        f"[openrouter-fetch-health] newest={path.name} "
        f"generated_at={generated.strftime('%Y-%m-%dT%H:%M:%SZ')} "
        f"age={age_hours:.1f}h threshold={max_age_hours:.1f}h"
    )
    if age_hours >= max_age_hours:
        fail(
            f"{path.name} is {age_hours:.1f}h old "
            f"(>= {max_age_hours:.1f}h). Artifacts older than 48h are stale "
            "for a pricing decision (openrouter-pricing-engine runbook). "
            "Inspect Actions workflow openrouter-catalog-propose.yml."
        )
    print("[openrouter-fetch-health] archive freshness OK")


def fetch_key_status(
    api_key: str,
    *,
    timeout_seconds: float = 15.0,
    urlopen: Callable[..., object] = urllib.request.urlopen,
) -> int:
    if not api_key or not api_key.strip():
        fail("OPENROUTER_API_KEY is missing or empty")
    request = urllib.request.Request(
        KEY_URL,
        headers={
            "Authorization": f"Bearer {api_key.strip()}",
            "Accept": "application/json",
            "User-Agent": "macprovider-openrouter-fetch-health/1",
        },
        method="GET",
    )
    context = ssl.create_default_context()
    try:
        with urlopen(request, timeout=timeout_seconds, context=context) as response:
            return int(getattr(response, "status", 0) or 0)
    except urllib.error.HTTPError as error:
        return int(error.code)
    except urllib.error.URLError as error:
        fail(f"transport error probing {KEY_URL}: {error.reason}")
        raise


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--skip-key-probe",
        action="store_true",
        help="offline: do not call OpenRouter (tests / archive-only)",
    )
    parser.add_argument(
        "--key-status",
        type=int,
        default=None,
        help="offline: pretend the key probe returned this HTTP status",
    )
    parser.add_argument(
        "--snapshot-archive",
        default=None,
        help="directory of archived snapshots/proposals; omit to skip freshness",
    )
    parser.add_argument(
        "--max-snapshot-age-hours",
        type=float,
        default=DEFAULT_MAX_SNAPSHOT_AGE_HOURS,
    )
    parser.add_argument(
        "--now",
        default=None,
        help="RFC3339 UTC timestamp ending in Z; override wall clock (tests)",
    )
    args = parser.parse_args(argv)

    if args.now is None:
        now = dt.datetime.now(dt.timezone.utc)
    else:
        now = parse_rfc3339_z(args.now, "--now")

    if args.key_status is not None:
        check_key_status(args.key_status)
    elif not args.skip_key_probe:
        check_key_status(fetch_key_status(os.environ.get("OPENROUTER_API_KEY", "")))

    if args.snapshot_archive:
        check_snapshot_archive(
            Path(args.snapshot_archive),
            now=now,
            max_age_hours=args.max_snapshot_age_hours,
        )
    print("[openrouter-fetch-health] OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

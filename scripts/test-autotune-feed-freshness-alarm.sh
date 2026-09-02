#!/usr/bin/env bash
# Fail-closed structural checks for autotune-feed cadence + freshness alarm.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
alarm="$root/.github/workflows/autotune-feed-freshness-alarm.yml"
renew="$root/.github/workflows/renew-autotune-static-feed.yml"
checker="$root/scripts/check-autotune-feed-freshness.py"

[[ -f "$alarm" ]] || {
  printf '[test-autotune-feed-freshness-alarm] ERROR: missing alarm workflow\n' >&2
  exit 1
}
[[ -f "$renew" ]] || {
  printf '[test-autotune-feed-freshness-alarm] ERROR: missing weekly cadence workflow\n' >&2
  exit 1
}
[[ -f "$checker" ]] || {
  printf '[test-autotune-feed-freshness-alarm] ERROR: missing freshness checker\n' >&2
  exit 1
}

python3 - "$alarm" "$renew" "$checker" <<'PY'
import pathlib
import sys

alarm = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
renew = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
checker = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
CHECKOUT = "uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
CHECKER = "python3 scripts/check-autotune-feed-freshness.py"

for name, workflow in (("alarm", alarm), ("renew", renew)):
    for requirement in (
        "workflow_dispatch:",
        "permissions:",
        "contents: read",
        CHECKOUT,
        "persist-credentials: false",
        "https://coordinator.malibu.tech/v1/rate-card",
        CHECKER,
        "--max-age-days",
        "--proto '=https'",
        "--tlsv1.2",
        "timeout-minutes: 5",
        "runs-on: ubuntu-latest",
    ):
        if requirement not in workflow:
            raise SystemExit(f"{name} workflow omits: {requirement}")
    for forbidden in (
        "MACPROVIDER_RELEASE_SIGNING_KEY_PEM",
        "AUTOTUNE_STATIC",
        "secrets.",
        "environment: production-release",
        "PEARL_SSH",
        "contents: write",
        "bash scripts/renew-autotune-static-feed.sh",
    ):
        if forbidden in workflow:
            raise SystemExit(f"{name} workflow must not contain {forbidden!r}")
    if workflow.count(CHECKER) != 1:
        raise SystemExit(f"{name} must invoke the checker exactly once")

if 'cron: "0 */6 * * *"' not in alarm:
    raise SystemExit("alarm must run every 6 hours")
if "group: autotune-feed-freshness-alarm" not in alarm:
    raise SystemExit("alarm must use its own concurrency group")
if "cancel-in-progress: true" not in alarm:
    raise SystemExit("alarm may cancel superseded runs")
if '--max-age-days "$MAX_AGE_DAYS"' not in alarm:
    raise SystemExit("alarm must pass the max-age input through to the checker")
if "|| '20'" not in alarm:
    raise SystemExit("alarm default max-age must be 20 days")

if 'cron: "0 16 * * 2"' not in renew:
    raise SystemExit("weekly cadence must run Tuesday 16:00 UTC (after Wednesday signed renewal)")
if 'cron: "0 16 * * 1"' in renew:
    raise SystemExit("weekly cadence must not share Monday 16:00 UTC with discovery-head")
if 'cron: "0 16 * * 3"' in renew:
    raise SystemExit("weekly cadence must not share Wednesday 16:00 UTC with the signed renewal")
if "RATE_CARD_URL" in alarm or "RATE_CARD_URL" in renew:
    raise SystemExit("workflows must pin coordinator.malibu.tech; no URL override")
if "group: renew-autotune-static-feed" not in renew:
    raise SystemExit("weekly cadence must use its own concurrency group")
if "cancel-in-progress: false" not in renew:
    raise SystemExit("weekly cadence must not cancel an in-flight Tuesday run")
if "|| '7'" not in renew:
    raise SystemExit("weekly cadence default max-age must be 7 days")

for requirement in (
    "CLIENT_HORIZON_DAYS = 30.0",
    "FUTURE_SKEW_MINUTES = 10.0",
    "rate_card_update_required",
    "scripts/renew-autotune-static-feed.sh --deploy",
    "--max-age-days must be < 30",
):
    if requirement not in checker:
        raise SystemExit(f"freshness checker omits: {requirement}")
if "requests." in checker or "urllib" in checker:
    raise SystemExit("freshness checker must not open a network connection")
PY

# Workflow YAML is not a shell script; do not bash -n it.
python3 -m py_compile "$checker"

printf '[test-autotune-feed-freshness-alarm] ok: cadence + alarm workflows fail closed\n'

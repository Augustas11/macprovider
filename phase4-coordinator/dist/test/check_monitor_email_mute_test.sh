#!/usr/bin/env bash
# Contract test for the monitor's per-kind email routing.
#
# Provider churn on a small fleet must stay journal-only by default while
# service-down alerts still page, every alert site must carry a known kind,
# and journald must keep receiving everything regardless of routing.
set -euo pipefail

DIST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONITOR="$DIST_DIR/monitor/macprovider-monitor.py"

python3 - "$MONITOR" <<'PY'
import runpy
import sys

m = runpy.run_path(sys.argv[1], run_name="monitor_email_mute_test")
muted_kinds = m["muted_kinds"]
send_email = m["send_email"]
KINDS = m["ALERT_KINDS"]

# --- default: provider churn muted, service/static-feed/diagnostics still emailed ---
default = muted_kinds({})
assert default == {"provider", "pool", "gateway_status"}, default
assert "service" not in default
assert "static_feed" not in default
assert "provider_diagnostics" not in default

# --- explicit overrides ---
assert muted_kinds({"EMAIL_MUTED_KINDS": "all"}) == set(KINDS)
assert muted_kinds({"EMAIL_MUTED_KINDS": "none"}) == set()
assert muted_kinds({"EMAIL_MUTED_KINDS": ""}) == set()
assert muted_kinds({"EMAIL_MUTED_KINDS": " Provider , POOL "}) == {"provider", "pool"}
# An unknown name is ignored, and must not drag the known ones down with it.
assert muted_kinds({"EMAIL_MUTED_KINDS": "provider,typo"}) == {"provider"}

# --- unconfigured email stays journal-only (returns None, not False) ---
assert send_email({}, [("CRITICAL", "service", "down")]) is None

# --- every alert kind referenced in the source is a declared kind ---
src = open(sys.argv[1]).read()
import re
used = set(re.findall(r'alerts\.append\(\("[A-Z]+", (KIND_[A-Z_]+),', src))
declared = {f"KIND_{k.upper()}" for k in KINDS}
assert used, "no tagged alert sites found — did the alert tuples change shape?"
assert used <= declared, used - declared
# Untagged 2-tuple alert sites would silently bypass routing.
assert not re.search(r'alerts\.append\(\("[A-Z]+", f?"', src), "untagged alert site"

print("PASS: monitor email routing mutes provider churn and pages on service loss")
PY

# --- #535 diagnostics: repeated failures alert once per newest event cursor ---
python3 - "$MONITOR" <<'PY'
import runpy
import sys
from datetime import datetime, timedelta, timezone

m = runpy.run_path(sys.argv[1], run_name="monitor_provider_diagnostics_test")
provider_diagnostic_alerts = m["provider_diagnostic_alerts"]

now = datetime(2026, 7, 26, 15, 0, tzinfo=timezone.utc)


def ts(minutes_ago):
    return (now - timedelta(minutes=minutes_ago)).isoformat().replace("+00:00", "Z")


def event(event_id, reason, minutes_ago=1, kind="auth_rejected", outcome="failure"):
    return {
        "id": event_id,
        "provider_id": "mp-a",
        "kind": kind,
        "outcome": outcome,
        "failure_reason": reason,
        "occurred_at": ts(minutes_ago),
    }


anon_admin = {"providers": []}
anon_events = [
    event(43, "invalid_auth_request", 1),
    event(42, "invalid_auth_request", 2),
    event(41, "invalid_auth_request", 3),
]
state = {}
alerts = provider_diagnostic_alerts({}, state, anon_admin, {"_anonymous": anon_events}, now=now)
assert alerts == [
    ("WARN", "provider_diagnostics", "pre-identity provider attempts have 3 invalid_auth_request failures in the last 15m")
], alerts
assert provider_diagnostic_alerts(
    {},
    state,
    anon_admin,
    {"_anonymous": [event(44, "invalid_auth_request", 0)] + anon_events},
    now=now,
) == []

admin = {"providers": [{"provider_id": "mp-a", "presence": "offline"}]}
events = [
    event(3, "invalid_token", 1),
    event(2, "invalid_token", 3),
    event(1, "invalid_token", 5),
]
state = {}
alerts = provider_diagnostic_alerts({}, state, admin, {"mp-a": events}, now=now)
assert alerts == [
    ("WARN", "provider_diagnostics", "provider mp-a has 3 invalid_token failures in the last 15m")
], alerts

# Same newest event id is deduped across polls.
assert provider_diagnostic_alerts({}, state, admin, {"mp-a": events}, now=now) == []

# A newer success/recovery event does not re-alert the same old failure burst.
events_with_success = [event(4, "", 0, kind="auth_accepted", outcome="success")] + events
assert provider_diagnostic_alerts({}, state, admin, {"mp-a": events_with_success}, now=now) == []

# A new contributing failure advances the per-alert cursor and emits again.
events = [event(5, "invalid_token", 0)] + events_with_success
alerts = provider_diagnostic_alerts({}, state, admin, {"mp-a": events}, now=now)
assert alerts == [
    ("WARN", "provider_diagnostics", "provider mp-a has 4 invalid_token failures in the last 15m")
], alerts

# Version drift is immediately actionable; no burst threshold required.
state = {}
alerts = provider_diagnostic_alerts({}, state, admin, {"mp-a": [event(10, "version_unsupported")]}, now=now)
assert alerts == [
    ("WARN", "provider_diagnostics", "provider mp-a has version_unsupported in the last 15m")
], alerts

# A single reconnect reason uses the specific reason alert; mixed liveness
# failures that only cross the aggregate threshold use reconnect_loop.
state = {}
events = [
    event(22, "heartbeat_stale", 1, kind="heartbeat_stale"),
    event(21, "heartbeat_stale", 2, kind="heartbeat_stale"),
    event(20, "heartbeat_stale", 3, kind="heartbeat_stale"),
]
alerts = provider_diagnostic_alerts({}, state, admin, {"mp-a": events}, now=now)
assert alerts == [
    ("WARN", "provider_diagnostics", "provider mp-a has 3 heartbeat_stale failures in the last 15m")
], alerts
state = {}
events = [
    event(32, "heartbeat_stale", 1, kind="heartbeat_stale"),
    event(31, "provider_websocket_disconnected", 2, kind="disconnect"),
    event(30, "provider_websocket_disconnected", 3, kind="disconnect"),
]
alerts = provider_diagnostic_alerts({}, state, admin, {"mp-a": events}, now=now)
assert alerts == [
    ("WARN", "provider_diagnostics", "provider mp-a has 3 reconnect/liveness failures in the last 15m")
], alerts

# Expected providers are optional; when configured, no recent auth/session is a warning.
state = {}
alerts = provider_diagnostic_alerts(
    {"EXPECTED_PROVIDER_IDS": "mp-b"},
    state,
    {"providers": []},
    {"mp-b": []},
    now=now,
)
assert alerts == [
    ("WARN", "provider_diagnostics", "expected provider mp-b has no successful auth/session in the last 30m")
], alerts
assert provider_diagnostic_alerts(
    {"EXPECTED_PROVIDER_IDS": "mp-b"},
    state,
    {"providers": []},
    {"mp-b": []},
    now=now,
) == []

state = {
    "provider_diagnostics": {
        "mp-b": {
            "newest_event": "99",
            "expected_provider_missing_auth": "expected_provider_missing_auth:99",
        },
    },
}
assert provider_diagnostic_alerts(
    {"EXPECTED_PROVIDER_IDS": "mp-b"},
    state,
    {"providers": []},
    {},
    now=now,
    failed_provider_ids={"mp-b"},
) == []
assert state["provider_diagnostics"]["mp-b"]["newest_event"] == "99", state

print("PASS: #535 provider diagnostics alert rules are bounded and deduped")
PY

# --- end-to-end: a provider drop must not reach SMTP, a coordinator outage must ---
STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT
STATE_DIRECTORY="$STATE_DIR" python3 - "$MONITOR" <<'PY'
import runpy
import os
import sys
import urllib.parse
from datetime import datetime, timedelta, timezone

path = sys.argv[1]


def run(pool_state, env, coord_up=True, admin_provider_list=None, provider_events=None):
    """Run main() once against a stubbed coordinator; return emailed alerts."""
    m = runpy.run_path(path, run_name="monitor_email_mute_e2e")
    sent = []
    provider_events = provider_events or {}

    def fake_get_json(url, bearer=None):
        if not coord_up:
            raise OSError("connection refused")
        if url == m["HEALTHZ"]:
            return {"pool_ready": len(pool_state)}
        if url == m["POOLZ"]:
            return {
                "pool": [{"provider_id": p, "state": s} for p, s in pool_state.items()],
                "summary": {"ready": sum(1 for s in pool_state.values() if s == "ready")},
            }
        if url == m["ADMIN_PROVIDERS"]:
            return admin_provider_list or {"providers": []}
        admin_prefix = m["ADMIN_PROVIDERS"] + "/"
        if url.startswith(admin_prefix) and "/events?" in url:
            provider_id = urllib.parse.unquote(url[len(admin_prefix):].split("/events?", 1)[0])
            events = provider_events.get(provider_id, [])
            return {"provider_id": provider_id, "events": events, "count": len(events)}
        return {"status": "ready" if pool_state else "idle"}

    m["get_json"] = fake_get_json
    m["probe_static_feed"] = lambda url: b"ok"
    m["load_env"] = lambda path: env
    m["operator_key"] = lambda: env.get("OPERATOR_KEY", os.environ.get("OPERATOR_KEY", ""))
    m["send_email"] = lambda env, alerts: sent.extend(alerts) or True
    # Rebind the module globals main() actually resolves against.
    main = m["main"]
    main.__globals__.update(m)
    main()
    return sent


# Seed: one ready provider, nothing to alert on yet.
run({"mp-a": "ready"}, {})

# The provider drops out of the pool entirely -> churn + pool-idle, no email.
sent = run({}, {})
assert sent == [], f"provider churn must not be emailed by default: {sent}"

# Same transition with muting turned off -> it does email (opt-out works).
run({"mp-a": "ready"}, {"EMAIL_MUTED_KINDS": "none"})
sent = run({}, {"EMAIL_MUTED_KINDS": "none"})
assert [k for _, k, _ in sent] and "provider" in [k for _, k, _ in sent], sent

# Coordinator itself unreachable -> still pages.
sent = run({}, {}, coord_up=False)
assert sent, "coordinator outage must still email"
assert {k for _, k, _ in sent} == {"service"}, sent
assert all(sev == "CRITICAL" for sev, _, _ in sent), sent


def e2e_ts(minutes_ago):
    return (datetime.now(timezone.utc) - timedelta(minutes=minutes_ago)).isoformat()


anon_events = [
    {
        "id": 53,
        "provider_id": "_anonymous",
        "kind": "auth_rejected",
        "outcome": "failure",
        "failure_reason": "invalid_token",
        "occurred_at": e2e_ts(1),
    },
    {
        "id": 52,
        "provider_id": "_anonymous",
        "kind": "auth_rejected",
        "outcome": "failure",
        "failure_reason": "invalid_token",
        "occurred_at": e2e_ts(2),
    },
    {
        "id": 51,
        "provider_id": "_anonymous",
        "kind": "auth_rejected",
        "outcome": "failure",
        "failure_reason": "invalid_token",
        "occurred_at": e2e_ts(3),
    },
]
sent = run(
    {},
    {
        "OPERATOR_KEY": "test-operator",
        "PROVIDER_DIAGNOSTICS_WINDOW_MINUTES": "1440",
    },
    admin_provider_list={"providers": []},
    provider_events={"_anonymous": anon_events},
)
diagnostic_sent = [alert for alert in sent if alert[1] == "provider_diagnostics"]
assert diagnostic_sent == [
    ("WARN", "provider_diagnostics", "pre-identity provider attempts have 3 invalid_token failures in the last 1440m")
], diagnostic_sent

anon_events = [
    {
        "id": 54,
        "provider_id": "_anonymous",
        "kind": "auth_rejected",
        "outcome": "failure",
        "failure_reason": "invalid_token",
        "occurred_at": e2e_ts(0),
    },
] + anon_events
sent = run(
    {},
    {
        "OPERATOR_KEY": "test-operator",
        "PROVIDER_DIAGNOSTICS_WINDOW_MINUTES": "1440",
    },
    admin_provider_list={"providers": []},
    provider_events={"_anonymous": anon_events},
)
diagnostic_sent = [alert for alert in sent if alert[1] == "provider_diagnostics"]
assert diagnostic_sent == [], diagnostic_sent

print("PASS: end-to-end — provider drop is journal-only, coordinator outage still emails")
PY

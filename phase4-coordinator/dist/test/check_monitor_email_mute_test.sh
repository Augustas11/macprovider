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

# --- default: provider churn muted, service/static-feed still emailed ---
default = muted_kinds({})
assert default == {"provider", "pool", "gateway_status"}, default
assert "service" not in default
assert "static_feed" not in default

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

# --- end-to-end: a provider drop must not reach SMTP, a coordinator outage must ---
STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT
STATE_DIRECTORY="$STATE_DIR" python3 - "$MONITOR" <<'PY'
import runpy
import sys

path = sys.argv[1]


def run(pool_state, env, coord_up=True):
    """Run main() once against a stubbed coordinator; return emailed alerts."""
    m = runpy.run_path(path, run_name="monitor_email_mute_e2e")
    sent = []

    def fake_get_json(url, bearer=None):
        if not coord_up:
            raise OSError("connection refused")
        if url.endswith("/healthz"):
            return {"pool_ready": len(pool_state)}
        if url.endswith("/poolz"):
            return {
                "pool": [{"provider_id": p, "state": s} for p, s in pool_state.items()],
                "summary": {"ready": sum(1 for s in pool_state.values() if s == "ready")},
            }
        return {"status": "ready" if pool_state else "idle"}

    m["get_json"] = fake_get_json
    m["probe_static_feed"] = lambda url: b"ok"
    m["load_env"] = lambda path: env
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

print("PASS: end-to-end — provider drop is journal-only, coordinator outage still emails")
PY

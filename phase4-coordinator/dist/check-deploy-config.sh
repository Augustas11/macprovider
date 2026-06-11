#!/usr/bin/env bash
# check-deploy-config.sh — pre-deploy config-drift + sanity assertions.
#
# Catches the config hazards this project has actually hit:
#   - a sanitized/placeholder operator_key that would break /poolz + /admin auth
#   - a heartbeat-miss threshold below the heartbeat interval (reaps live providers)
#   - missing Phase 7 keys (silent fallback to defaults the operator didn't choose)
#   - the FR-P11a "C2" cross-component timer relation: coordinator
#     routing.request_timeout_s should be strictly BELOW the gateway
#     timeouts.coordinator_request_seconds, else a gateway-timeout cancel races
#     the coordinator relay-timeout and a slow non-streaming provider can escape
#     breaker attribution.
#
# Usage: check-deploy-config.sh <coordinator.yaml> [gateway.yaml]
# Exit 1 on HARD failure; 0 otherwise (WARN/note lines are non-blocking).

set -uo pipefail
COORD="${1:?usage: check-deploy-config.sh <coordinator.yaml> [gateway.yaml]}"
GW="${2:-}"

python3 - "$COORD" "$GW" <<'PY'
import re, sys

coord = open(sys.argv[1]).read()
gw = open(sys.argv[2]).read() if len(sys.argv) > 2 and sys.argv[2] else ""

def g(src, key):
    m = re.search(rf'(?m)^\s*{key}:\s*"?([^"\n#]+)', src)
    return m.group(1).strip() if m else None

fail = 0
def hard(m):
    global fail; print(f"  FAIL: {m}"); fail = 1
def warn(m): print(f"  WARN: {m}")
def ok(m):   print(f"  ok:   {m}")

# --- operator_key ---
key = g(coord, "operator_key")
if not key:
    hard("coordinator operator_key missing")
elif re.search(r"REPLACE|change-me|<required>|placeholder|xxx", key, re.I):
    hard(f"coordinator operator_key is a PLACEHOLDER -> would break /poolz + /admin auth")
elif not re.fullmatch(r"[0-9a-fA-F]{64}", key):
    hard(f"operator_key is not 64-hex (len {len(key)}); expected `openssl rand -hex 32`")
else:
    ok("operator_key present (64-hex, non-placeholder)")

# --- require_provider_tokens ---
# Security-sensitive: the binary default is `true` (fail-closed), but a
# pre-existing fleet without issued provider tokens needs `false` to keep
# connecting. Silent-defaulting on this field caused the 2026-06-11 outage
# (deployed a config without the field; new binary defaulted true; air5/air8gb
# rejected with close_code:4005 reason:invalid_token). Force an explicit choice.
rpt = g(coord, "require_provider_tokens")
if rpt is None:
    hard("auth.require_provider_tokens is ABSENT — binary default (true) "
         "will reject any provider not presenting a token. "
         "Set explicitly to true (production / tokens issued) or false (legacy fleet).")
elif rpt.lower() == "false":
    warn("auth.require_provider_tokens=false — provider WS is unauthenticated; "
         "intended only for legacy providers without issued tokens. Plan token migration.")
elif rpt.lower() == "true":
    ok("auth.require_provider_tokens=true (fail-closed)")
else:
    hard(f"auth.require_provider_tokens must be true or false, got: {rpt!r}")

# --- threshold sanity ---
hi = g(coord, "heartbeat_interval_s")
hm = g(coord, "heartbeat_miss_threshold_s")
rt = g(coord, "request_timeout_s")
if hm is None:
    warn("heartbeat_miss_threshold_s absent -> coordinator default (90s) applies")
elif hi and int(hm) <= int(hi):
    hard(f"heartbeat_miss_threshold_s ({hm}) <= heartbeat_interval_s ({hi}); providers reaped before one missed beat")
elif hi:
    ok(f"heartbeat_miss_threshold_s={hm} > heartbeat_interval_s={hi}")
for k in ("warmup_gate_enabled", "breaker_failure_threshold", "breaker_window_s"):
    if g(coord, k) is None:
        warn(f"{k} absent -> coordinator default applies (operator did not choose it)")

# --- C2 cross-component timer relation (needs gateway config) ---
if gw:
    gwt = g(gw, "coordinator_request_seconds")
    if rt and gwt:
        if int(rt) >= int(gwt):
            warn(f"C2: coordinator request_timeout_s ({rt}) is NOT strictly below gateway "
                 f"coordinator_request_seconds ({gwt}). A gateway-timeout cancel can race the "
                 f"coordinator relay-timeout; a slow non-streaming provider may escape breaker "
                 f"attribution (SPEC-002 FR-P11a C2). Recommend coordinator < gateway.")
        else:
            ok(f"C2 timer ordering: coordinator {rt}s < gateway {gwt}s")
else:
    print("  note: gateway.yaml not provided -> skipped C2 timer cross-check")

sys.exit(1 if fail else 0)
PY
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "config-drift check FAILED — fix the above before deploying" >&2
  exit 1
fi
echo "config-drift check passed"

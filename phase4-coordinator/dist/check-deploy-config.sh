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
# Usage: check-deploy-config.sh <coordinator.yaml> <gateway.yaml>
# Exit 1 on HARD failure; 0 otherwise (WARN/note lines are non-blocking).
#
# M1-6 / DEVE-4: the gateway config is REQUIRED by default. The C2
# cross-component timer relation is the single most important safety check
# this script performs — it caught a real past production incident. Silently
# skipping it (the previous behavior when the gateway arg was omitted) made
# every standard coordinator deploy run a no-op C2 gate. To opt out
# deliberately (e.g. checking a coordinator-only config in isolation), set
# SKIP_C2_CHECK=1.

set -uo pipefail
COORD="${1:?usage: check-deploy-config.sh <coordinator.yaml> <gateway.yaml>}"
GW="${2:-}"

if [ -z "$GW" ] && [ "${SKIP_C2_CHECK:-0}" != "1" ]; then
  echo "FAIL: gateway.yaml argument missing." >&2
  echo "  The C2 cross-component timer check requires both coordinator.yaml" >&2
  echo "  AND gateway.yaml. To intentionally check the coordinator config" >&2
  echo "  alone (skipping C2), set SKIP_C2_CHECK=1." >&2
  echo "  Usage: check-deploy-config.sh <coordinator.yaml> <gateway.yaml>" >&2
  exit 1
fi

# M1-6 follow-up (codex architect re-audit 2026-06-11): the wrapper deploy
# scripts already refuse the *.example fallback, but the reusable C2 gate
# itself should reject sample config too. Belt-and-suspenders against a
# future caller passing the example path explicitly.
case "$COORD" in
  *.example) echo "FAIL: sample coordinator config ($COORD) is not deploy input" >&2; exit 1;;
esac
case "$GW" in
  *.example) echo "FAIL: sample gateway config ($GW) is not deploy input" >&2; exit 1;;
esac

python3 - "$COORD" "$GW" <<'PY'
import os, re, sys

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

# Secrets may be inlined as a literal value OR indirected to a runtime
# environment variable as `env:NAME` (M3-2 / DEVE-7). The systemd units inject
# NAME from /etc/macprovider/{coordinator,gateway}.env at start. This gate runs
# LOCALLY before the config is shipped to Pearl, where those env files do not
# exist and secrets are deliberately never pulled to local disk (see
# normalize_yaml masking in deploy-pearl-vps.sh). So an `env:NAME` value is
# "deferred to runtime": validate the reference is well-formed, and only if
# NAME happens to be present in THIS process's environment (e.g. the gate is
# run on Pearl with the env file sourced) do we also validate the resolved
# secret. A bare unresolved `env:NAME` is NOT a failure — hex-validating the
# literal string "env:NAME" was a false fail-closed gate that pressured
# operators into SKIP_C2_CHECK=1, which also skipped the genuinely load-bearing
# C2 timer check (observed 2026-06-17 on a gateway deploy to Pearl).
ENV_REF = re.compile(r"^env:([A-Za-z_][A-Za-z0-9_]*)$")
PLACEHOLDER = re.compile(r"REPLACE|change-me|<required>|placeholder|xxx", re.I)

def check_hex_secret(label, raw):
    """Validate a 64-hex secret that may be inline or `env:NAME`-indirected.

    Reusable across every secret-shaped field this gate hex/placeholder-checks
    (currently operator_key; add a field by calling this). Behavior:
      - missing                 -> HARD fail
      - "env:NAME", NAME unset   -> ok (deferred to runtime; cannot resolve here)
      - "env:NAME", NAME set     -> validate the resolved value (placeholder/hex)
      - "env:" / "env:1bad"      -> HARD fail (malformed reference)
      - inline literal           -> validate as before (placeholder/hex)
    """
    if not raw:
        hard(f"{label} missing")
        return
    src = ""
    if raw.startswith("env:"):
        m = ENV_REF.match(raw)
        if not m:
            hard(f"{label} malformed env indirection {raw!r}; expected env:NAME")
            return
        name = m.group(1)
        resolved = os.environ.get(name)
        if not resolved:
            ok(f"{label} deferred to runtime via env:{name} "
               f"(injected from /etc/macprovider/*.env at start; not resolvable in this gate)")
            return
        raw = resolved
        src = f" (resolved from env:{name})"
    if PLACEHOLDER.search(raw):
        hard(f"{label} is a PLACEHOLDER{src} -> would break /poolz + /admin auth")
    elif not re.fullmatch(r"[0-9a-fA-F]{64}", raw):
        hard(f"{label} is not 64-hex (len {len(raw)}){src}; expected `openssl rand -hex 32`")
    else:
        ok(f"{label} present (64-hex, non-placeholder){src}")

# --- operator_key (inline literal or env:NAME deferred to runtime) ---
check_hex_secret("coordinator operator_key", g(coord, "operator_key"))

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

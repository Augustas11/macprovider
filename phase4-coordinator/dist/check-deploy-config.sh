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

KEY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):(?:\s+.*)?$")

def parse_scalar(raw):
    raw = raw.strip()
    if not raw:
        return ""
    if raw[0] in ("'", '"'):
        quote = raw[0]
        end = raw.find(quote, 1)
        return raw[1:end] if end >= 0 else raw[1:]
    return raw.split("#", 1)[0].strip()

def section_body(src, section):
    lines = src.splitlines()
    for i, line in enumerate(lines):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith(" ") or line.startswith("\t"):
            continue
        m = KEY_RE.match(line.strip())
        if not m or m.group(1) != section:
            continue
        body = []
        for child in lines[i+1:]:
            if child.strip() and not child.lstrip().startswith("#") and not child.startswith((" ", "\t")):
                break
            body.append(child)
        return body
    return None

def g_section(src, section, key):
    body = section_body(src, section)
    if body is None:
        return None
    child_indent = None
    for line in body:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        child_indent = re.match(r"^[ \t]*", line).group(0)
        break
    if child_indent is None:
        return None
    pattern = re.compile(rf"^{re.escape(child_indent)}{re.escape(key)}:\s*(.*)$")
    for line in body:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = pattern.match(line)
        if m:
            return parse_scalar(m.group(1))
    return None

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
check_hex_secret("coordinator operator_key", g_section(coord, "auth", "operator_key"))

# --- gateway credentials (same hazard class as the coordinator key) ---
# Only checkable when the gateway config is present (not coordinator-only
# SKIP_C2_CHECK mode). operator_key is REQUIRED by the gateway (config.go
# Validate); service_token is OPTIONAL — preferred over operator_key for
# upstream calls when set — so it is validated only when present. The gateway
# runtime already fails closed on an unset/empty env:NAME or an empty
# operator_key (config.go resolveEnvValue + Validate); the residual gap is an
# INLINE placeholder, which is non-empty and so boots with a junk credential
# that silently fails gateway->coordinator auth. That is what this catches,
# symmetric to the coordinator operator_key check above.
if gw:
    check_hex_secret("gateway operator_key", g_section(gw, "coordinator", "operator_key"))
    gw_service_token = g_section(gw, "coordinator", "service_token")
    if gw_service_token is not None:
        check_hex_secret("gateway service_token", gw_service_token)

# --- require_provider_tokens ---
# Security-sensitive: the binary default is `true` (fail-closed), but a
# pre-existing fleet without issued provider tokens needs `false` to keep
# connecting. Silent-defaulting on this field caused the 2026-06-11 outage
# (deployed a config without the field; new binary defaulted true; air5/air8gb
# rejected with close_code:4005 reason:invalid_token). Force an explicit choice.
rpt = g_section(coord, "auth", "require_provider_tokens")
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

# --- allow_tokenless_provisional_bootstrap ---
# Public provider onboarding needs one narrowly-scoped tokenless path: the
# first provisional connect can mint and persist its own provider_token, while
# used-token provider IDs still fail closed via the coordinator TOFU gate. Force
# an explicit deploy choice so public onboarding is not accidentally bricked by
# the closed default, and invite-only deployments do not unknowingly open
# first-claim bootstrap.
aptb = g_section(coord, "auth", "allow_tokenless_provisional_bootstrap")
if aptb is None:
    hard("auth.allow_tokenless_provisional_bootstrap is ABSENT — set explicitly to "
         "true for public curl-install onboarding or false for invite-only / "
         "operator-preprovisioned providers.")
elif aptb.lower() == "true":
    ok("auth.allow_tokenless_provisional_bootstrap=true (first-install provider token self-bootstrap enabled)")
elif aptb.lower() == "false":
    warn("auth.allow_tokenless_provisional_bootstrap=false — clean public installs need a pre-provisioned provider_token.")
else:
    hard(f"auth.allow_tokenless_provisional_bootstrap must be true or false, got: {aptb!r}")

# --- threshold sanity ---
hi = g_section(coord, "pool", "heartbeat_interval_s")
hm = g_section(coord, "pool", "heartbeat_miss_threshold_s")
rt = g_section(coord, "routing", "request_timeout_s")
if hm is None:
    warn("heartbeat_miss_threshold_s absent -> coordinator default (90s) applies")
elif hi and int(hm) <= int(hi):
    hard(f"heartbeat_miss_threshold_s ({hm}) <= heartbeat_interval_s ({hi}); providers reaped before one missed beat")
elif hi:
    ok(f"heartbeat_miss_threshold_s={hm} > heartbeat_interval_s={hi}")
for k in ("warmup_gate_enabled", "breaker_failure_threshold", "breaker_window_s"):
    if g_section(coord, "pool", k) is None:
        warn(f"{k} absent -> coordinator default applies (operator did not choose it)")

# --- C2 cross-component timer relation (needs gateway config) ---
if gw:
    gwt = g_section(gw, "timeouts", "coordinator_request_seconds")
    if gwt is None:
        hard("C2: gateway timeouts.coordinator_request_seconds is ABSENT — "
             "cannot verify coordinator routing.request_timeout_s is below the gateway timeout.")
    elif rt is None:
        hard("C2: coordinator routing.request_timeout_s is ABSENT — "
             "cannot verify it is below the gateway timeout.")
    else:
        if int(rt) >= int(gwt):
            hard(f"C2: coordinator request_timeout_s ({rt}) is NOT strictly below gateway "
                 f"coordinator_request_seconds ({gwt}). A gateway-timeout cancel can race the "
                 f"coordinator relay-timeout; a slow non-streaming provider may escape breaker "
                 f"attribution (SPEC-002 FR-P11a C2). Set coordinator < gateway.")
        else:
            ok(f"C2 timer ordering: coordinator {rt}s < gateway {gwt}s")
else:
    print("  note: gateway.yaml not provided -> skipped C2 timer cross-check")

# --- payout block (SPEC-016 v0.1.21 §6.5 — Step 4 deploy gate) ---
# The payout.* block has a hard schema split: payout.security.* is
# runtime-immutable; payout.tuning.* is SIGHUP-reloadable with bound
# re-enforcement. The gate validates every required key is either
# present-with-value or env:NAME-indirected, and rejects placeholder
# strings (per c2-gate-resolves-env-indirected-secrets). Skipped when
# payout.enabled != true so existing pre-Step-4 deploys still pass.
#
# coord is the raw YAML text (not a dict) — see section_body /
# g_section above. We compose a 2-level helper for payout.security.*
# and payout.tuning.* without pulling in a full YAML parser.
def g_payout(sub, key):
    """Read payout.<sub>.<key> from the raw YAML text. Returns None when absent."""
    payout_body = section_body(coord, "payout")
    if payout_body is None:
        return None
    sub_body_lines = []
    sub_indent = None
    in_sub = False
    for line in payout_body:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        # detect "<sub>:" at indent 2 (the payout block's child).
        if in_sub:
            # leave on dedent
            cur_indent = len(line) - len(line.lstrip())
            if sub_indent is None:
                sub_indent = cur_indent
            if cur_indent < sub_indent:
                in_sub = False
                continue
            sub_body_lines.append(line)
            continue
        m = KEY_RE.match(stripped)
        if m and m.group(1) == sub:
            in_sub = True
            continue
    if not sub_body_lines:
        return None
    for line in sub_body_lines:
        m = KEY_RE.match(line.strip())
        if not m:
            continue
        if m.group(1) == key:
            # split off the value
            rest = line.split(":", 1)[1] if ":" in line else ""
            return parse_scalar(rest)
    return None

payout_enabled_raw = g_section(coord, "payout", "enabled")
payout_enabled = (payout_enabled_raw or "").strip().lower() == "true"
if not payout_enabled:
    print("  note: payout.enabled is false -> SPEC-016 payout gate SKIPPED")
else:
    def get_sec(k): return g_payout("security", k)
    def get_tun(k): return g_payout("tuning", k)

    def check_payout_field(label, raw, *, hex_64=False, allow_empty=False):
        """Validate a payout config field: present-with-value or env:NAME.

        - missing                              -> HARD fail
        - "env:NAME", NAME unset               -> ok (deferred to runtime)
        - "env:NAME", NAME set to placeholder  -> HARD fail
        - "env:" / "env:1bad"                  -> HARD fail (malformed)
        - inline literal placeholder           -> HARD fail
        - inline literal value                 -> ok (hex-validated if hex_64)
        """
        if raw is None or raw == "":
            if allow_empty:
                ok(f"{label} empty -> default applies")
                return
            hard(f"{label} is MISSING — payout.enabled=true requires every payout.* key")
            return
        raw_s = str(raw)
        src = ""
        if raw_s.startswith("env:"):
            m = ENV_REF.match(raw_s)
            if not m:
                hard(f"{label} malformed env indirection {raw_s!r}")
                return
            name = m.group(1)
            resolved = os.environ.get(name)
            if not resolved:
                ok(f"{label} deferred to runtime via env:{name}")
                return
            raw_s = resolved
            src = f" (resolved from env:{name})"
        if PLACEHOLDER.search(raw_s) or raw_s.startswith("<"):
            hard(f"{label} is a PLACEHOLDER{src} -> payout pipeline would fail at startup")
            return
        if hex_64 and not re.fullmatch(r"[0-9a-fA-F]{64}", raw_s):
            hard(f"{label} is not 64-hex (len {len(raw_s)}){src}; expected SHA-256 SPKI pin")
            return
        ok(f"{label} present{src}")

    # security namespace (required when enabled=true)
    check_payout_field("payout.security.hot_wallet_address", get_sec("hot_wallet_address"))
    check_payout_field("payout.security.rpc_url_primary",   get_sec("rpc_url_primary"))
    check_payout_field("payout.security.rpc_url_secondary", get_sec("rpc_url_secondary"))
    check_payout_field("payout.security.encrypted_wallet_path", get_sec("encrypted_wallet_path"))
    # caps + cancel + abandon (no env: indirection expected; integers)
    for key in (
        "per_payout_cap_usdc_base_units",
        "per_day_cap_usdc_base_units",
        "cancel_max_tip_multiplier",
        "cancel_max_gas_native_wei",
        "cancel_max_gas_native_wei_per_24h",
        "abandon_rate_per_hour",
        "chain_recon_interval",
        "chain_recon_tolerance_usdc_base_units",
        "pause_resume_min_interval",
    ):
        val = get_sec(key)
        if val is None or val == "":
            hard(f"payout.security.{key} is MISSING — required when payout.enabled=true")
        else:
            ok(f"payout.security.{key} present")

    # tuning namespace
    for key in (
        "address_cooling_off_period",
        "run_interval",
        "run_now_min_interval",
        "confirmation_blocks",
        "max_rows_per_run",
        "reorg_poll_window",
    ):
        val = get_tun(key)
        if val is None or val == "":
            hard(f"payout.tuning.{key} is MISSING — required when payout.enabled=true")
        else:
            ok(f"payout.tuning.{key} present")

    # SPKI pins are optional (empty allowed); when set, must be 64-hex.
    check_payout_field("payout.tuning.rpc_url_primary_pin_spki",
                       get_tun("rpc_url_primary_pin_spki"),
                       hex_64=True, allow_empty=True)
    check_payout_field("payout.tuning.rpc_url_secondary_pin_spki",
                       get_tun("rpc_url_secondary_pin_spki"),
                       hex_64=True, allow_empty=True)

sys.exit(1 if fail else 0)
PY
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "config-drift check FAILED — fix the above before deploying" >&2
  exit 1
fi
echo "config-drift check passed"

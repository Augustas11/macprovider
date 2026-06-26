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
import datetime, os, re, sys

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
warns = 0
def hard(m):
    global fail; print(f"  FAIL: {m}"); fail = 1
def warn(m):
    global warns; print(f"  WARN: {m}"); warns += 1
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

# --- gateway_service_token (coordinator side) — REQUIRED post-2026-07-12 cutover ---
# PR #172 (issue #87 item 3) removed the legacy operator_key fallback on
# /internal/*; the coordinator now accepts ONLY gateway_service_token there.
# A coordinator deployed without auth.gateway_service_token boots but rejects
# every gateway call to /internal/routing + /internal/sticky, taking the
# buyer path offline.
check_hex_secret("coordinator gateway_service_token",
                 g_section(coord, "auth", "gateway_service_token"))

# --- gateway credentials (same hazard class as the coordinator key) ---
# Only checkable when the gateway config is present (not coordinator-only
# SKIP_C2_CHECK mode). Both operator_key (for /poolz proxying) and
# service_token (for /internal/* upstream calls) are REQUIRED by gateway
# config.go Validate() post-2026-07-12 cutover. The gateway runtime fails
# closed on an unset/empty env:NAME or an empty token; the residual gap
# this gate catches is an INLINE placeholder, which is non-empty and so
# boots with a junk credential that silently fails gateway->coordinator
# auth, symmetric to the coordinator operator_key check above.
if gw:
    check_hex_secret("gateway operator_key", g_section(gw, "coordinator", "operator_key"))
    check_hex_secret("gateway service_token", g_section(gw, "coordinator", "service_token"))

# --- C2c: operator/service token distinctness (rotation discipline) ---
# Post-cutover, the operator_key and gateway_service_token are the only two
# bearer classes on the coordinator: operator_key on /poolz + /admin/*,
# service_token on /internal/*. If they collapse to the same value, the
# operator credential still authenticates /internal/* by value, defeating
# the operator-vs-service split this PR is meant to finish. Check on each
# side (coordinator self, gateway self) AND cross-file (gateway operator_key
# vs coordinator gateway_service_token, when both resolvable).
def _env_name(raw):
    """If raw is a well-formed env:NAME ref, return NAME. Else None."""
    if not raw or not raw.startswith("env:"):
        return None
    m = ENV_REF.match(raw)
    return m.group(1) if m else None

def _safe_describe(raw):
    """Classify a secret-bearing field WITHOUT printing its value.
    Audit-r5 (3-of-3 lanes) found that printing raw_a/raw_b in WARN
    messages can leak a live bearer token into deploy/wrapper logs.
    Categories: absent | inline-redacted | env:NAME (resolved|unresolved)
    | env malformed."""
    if not raw:
        return "absent"
    if raw.startswith("env:"):
        m = ENV_REF.match(raw)
        if not m:
            return "env malformed"
        name = m.group(1)
        return f"env:{name} ({'resolved' if os.environ.get(name) else 'unresolved'})"
    return "inline-redacted"

def _resolved_value(raw):
    """Return the resolved value (whitespace-trimmed) or None if deferred/
    malformed/missing. TrimSpace mirrors auth.BearerTokenMatchesHeader so a
    config with `service_token: "X "` is judged the same way the runtime
    will judge it on the wire."""
    if not raw:
        return None
    if raw.startswith("env:"):
        m = ENV_REF.match(raw)
        if not m:
            return None
        v = os.environ.get(m.group(1))
        return v.strip() if v else None
    return raw.strip()

def _check_distinct(label_a, raw_a, label_b, raw_b, same_file=True):
    """C2c distinctness: assert two secret-bearing fields are NOT equal.

    same_file=True (default): both fields live in the SAME yaml file (and
        therefore the SAME systemd env file at runtime). Same env:NAME on
        both sides is a static-catch hard fail — resolution would collapse
        them to the same value.

    same_file=False: fields live in different yaml files (coordinator.yaml
        vs gateway.yaml), which the coordinator and gateway units source
        from SEPARATE env files (/etc/macprovider/coordinator.env and
        /etc/macprovider/gateway.env per the dist .service units). Same
        env:NAME on both sides does NOT prove same value at runtime — the
        two env files can define the variable differently. Don't false-fail
        a safe deploy: skip as 'unverified' when either side is unresolved,
        leaving runtime Validate() as the backstop on each side. Cross-file
        same-env-name same-value is still a runtime hazard, but no single
        deploy-gate process can read both env files unambiguously.
    """
    na = _env_name(raw_a)
    nb = _env_name(raw_b)
    if same_file and na is not None and na == nb:
        hard(f"C2c: {label_a} and {label_b} both reference env:{na} "
             f"(same file -> same env at runtime); "
             f"resolution collapses to one value, rotation discipline violated")
        return
    a = _resolved_value(raw_a)
    b = _resolved_value(raw_b)
    if a is None or b is None:
        if same_file:
            # Same yaml -> same Validate() — its runtime distinctness check
            # is the backstop.
            ok(f"C2c {label_a} vs {label_b}: skipped, deferred to runtime "
               f"(same file; module Validate enforces distinctness)")
        else:
            # Cross-file: NO runtime backstop. Each module's Validate
            # only checks the two fields on its own side. WARN loudly so
            # the operator knows the gate cannot prove this invariant.
            warn(f"C2c {label_a} vs {label_b}: UNVERIFIED — cross-file "
                 f"distinctness has NO runtime backstop (each module's "
                 f"Validate only sees its own file). One or both env:NAME "
                 f"refs are unresolved at gate time. To verify: source "
                 f"/etc/macprovider/coordinator.env and gateway.env into "
                 f"the gate process, or inline at least one side.")
        return
    if a == b:
        hard(f"C2c: {label_a} == {label_b} — rotation discipline violated; "
             f"operator credential would still authenticate /internal/* by value")
    else:
        ok(f"C2c {label_a} vs {label_b}: distinct")

def _check_pair_equal(label_a, raw_a, label_b, raw_b, same_file=False):
    """C2c pairing: assert two fields hold the SAME secret (gateway sends
    coordinator.service_token on the wire; coordinator accepts only its
    own auth.gateway_service_token). A mismatch boots green and 401s every
    /internal/* call.

    same_file defaults to False since the canonical pairing crosses files.
    For same-file pairings the same-env-NAME shortcut proves equality;
    cross-file does NOT (see _check_distinct's docstring on separate env
    files). For cross-file unresolved env, mark unverified and warn — the
    operator must verify by reading both env files (the gate cannot)."""
    na = _env_name(raw_a)
    nb = _env_name(raw_b)
    if same_file and na is not None and na == nb:
        ok(f"C2c pairing {label_a} == {label_b}: both reference env:{na} "
           f"(same file -> same value at runtime)")
        return
    a = _resolved_value(raw_a)
    b = _resolved_value(raw_b)
    if a is None or b is None:
        if same_file:
            ok(f"C2c pairing {label_a} == {label_b}: skipped, deferred to runtime "
               f"(same file; module Validate enforces equality on resolution)")
            return
        # Cross-file: NO runtime backstop — neither module's Validate
        # can see the other's token. Audit-r4 finding (3-of-3 lanes):
        # any unresolved side here must WARN loudly, not skip silently.
        # Pairing is the load-bearing /internal/* invariant — an
        # operator typo in one env file is exactly the failure mode
        # this gate exists to catch.
        if na is not None and na == nb:
            detail = (f"both reference env:{na} but coord and gateway "
                      f"systemd units source SEPARATE env files (coordinator.env "
                      f"vs gateway.env); they may resolve to different values")
        else:
            # Safe classification only — NEVER print the raw value
            # (audit-r5 caught the live bearer leak via raw!r format).
            detail = (f"{label_a}={_safe_describe(raw_a)}, "
                      f"{label_b}={_safe_describe(raw_b)}; one or both "
                      f"env:NAME refs unresolved at gate time")
        warn(f"C2c pairing {label_a} == {label_b}: UNVERIFIED — "
             f"cross-file pairing has NO runtime backstop. {detail}. "
             f"To verify: source both /etc/macprovider/coordinator.env and "
             f"gateway.env into the gate process, inline both sides for "
             f"the gate to compare, or perform a manual smoke check after "
             f"deploy (curl /internal/routing with the gateway service "
             f"token: 401 = mismatch).")
        return
    if a != b:
        hard(f"C2c: {label_a} != {label_b} — gateway sends a credential the "
             f"coordinator rejects; every /internal/* call would 401")
    else:
        ok(f"C2c pairing {label_a} == {label_b}: match")

coord_op = g_section(coord, "auth", "operator_key")
coord_svc = g_section(coord, "auth", "gateway_service_token")
# Same-file: both fields are in coordinator.yaml and resolve from
# coordinator.env, so same env:NAME -> same value at runtime (static fail).
_check_distinct("coordinator auth.operator_key", coord_op,
                "coordinator auth.gateway_service_token", coord_svc,
                same_file=True)

if gw:
    gw_op = g_section(gw, "coordinator", "operator_key")
    gw_svc = g_section(gw, "coordinator", "service_token")
    # Same-file: both fields are in gateway.yaml and resolve from
    # gateway.env, so same env:NAME -> same value at runtime (static fail).
    _check_distinct("gateway coordinator.operator_key", gw_op,
                    "gateway coordinator.service_token", gw_svc,
                    same_file=True)
    # Cross-file: gateway operator_key (proxied to coordinator for /poolz)
    # vs coordinator gateway_service_token. Same env:NAME does NOT prove
    # same value because coord and gw units source separate env files.
    # Skip unresolved with an explicit message; runtime backstop on each
    # side prevents an unsafe boot for the equal-values-in-one-file case.
    _check_distinct("gateway coordinator.operator_key", gw_op,
                    "coordinator auth.gateway_service_token", coord_svc,
                    same_file=False)
    # C2c pairing: gateway sends coordinator.service_token on /internal/*;
    # coordinator accepts ONLY its own auth.gateway_service_token. Cross-file
    # by definition. Same env:NAME on both sides DOES NOT prove pairing
    # (separate env files). Mismatches are detectable only when both
    # values are resolvable at gate time; otherwise WARN, do not pass
    # silently — pairing is the load-bearing /internal/* invariant.
    _check_pair_equal("gateway coordinator.service_token", gw_svc,
                      "coordinator auth.gateway_service_token", coord_svc,
                      same_file=False)

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

# --- bounded model-identity migration bridge ---
# Absence means a canonical-only fleet and preserves the code's fail-closed
# default. Presence means the operator is explicitly declaring a mixed fleet;
# the deadline must resolve now and be a future RFC3339 instant. Production
# uses env:MODEL_HASH_LEGACY_UNTIL so no soon-stale date is committed.
legacy_until = g_section(coord, "tier2", "model_hash_legacy_until")
if legacy_until is None or not legacy_until.strip():
    ok("tier2.model_hash_legacy_until absent (canonical-only; missing algorithms fail closed)")
else:
    resolved_legacy_until = legacy_until
    if legacy_until.startswith("env:"):
        m = ENV_REF.match(legacy_until)
        if not m:
            hard("tier2.model_hash_legacy_until has malformed env indirection; expected env:NAME")
            resolved_legacy_until = ""
        else:
            name = m.group(1)
            resolved_legacy_until = os.environ.get(name, "").strip()
            if not resolved_legacy_until:
                hard(f"tier2.model_hash_legacy_until references env:{name}, but it is unset or empty; "
                     "a mixed-version rollout requires an explicit future RFC3339 deadline")
    if resolved_legacy_until:
        rfc3339 = re.fullmatch(
            r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})",
            resolved_legacy_until,
        )
        if not rfc3339:
            hard("tier2.model_hash_legacy_until must resolve to RFC3339")
        else:
            try:
                deadline = datetime.datetime.fromisoformat(
                    resolved_legacy_until[:-1] + "+00:00"
                    if resolved_legacy_until.endswith("Z")
                    else resolved_legacy_until
                )
            except ValueError:
                hard("tier2.model_hash_legacy_until must resolve to a valid RFC3339 instant")
            else:
                now = datetime.datetime.now(datetime.timezone.utc)
                if deadline <= now:
                    hard("tier2.model_hash_legacy_until is expired; remove the bridge for a canonical-only "
                         "fleet or set a reviewed future deadline for the counted legacy cohort")
                else:
                    ok("tier2.model_hash_legacy_until is an explicit future migration deadline; "
                       "observe legacy count, update providers, then remove the field")

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

    # C2b cross-component check (added post-#92):
    # gateway coordinator_header_timeout_seconds bounds how long the gateway
    # waits for response headers from the coordinator. Post-#92, the
    # coordinator commits streaming headers only after the first valid SSE
    # event arrives; combined with non-streaming headers always arriving at
    # completion, this header timeout must be >= the gateway request budget
    # OR a class of slow-but-valid first-event scenarios will false-fail as
    # coordinator_unavailable before the coordinator's own request_timeout_s
    # has elapsed. (See issue #92 architect-lane audit + follow-up #171.)
    #
    # Skip when gwt is None: the C2 absent-request hard() above already
    # emitted the diagnostic, and evaluating int(gwt) here would Traceback.
    # Absent header treated as effective 300 (the gateway runtime default at
    # phase5-gateway/internal/config/config.go:183). The compare-against-effective
    # logic catches the edge case where coordinator_request_seconds is raised
    # above 300 without also setting coordinator_header_timeout_seconds.
    if gwt is not None:
        ght = g_section(gw, "timeouts", "coordinator_header_timeout_seconds")
        effective_ght = int(ght) if ght is not None else 300
        if int(gwt) > effective_ght:
            if ght is None:
                hard(f"C2b: gateway timeouts.coordinator_header_timeout_seconds is ABSENT — "
                     f"runtime default 300 < coordinator_request_seconds ({gwt}). Set "
                     f"coordinator_header_timeout_seconds >= {gwt} explicitly.")
            else:
                hard(f"C2b: gateway coordinator_header_timeout_seconds ({ght}) is BELOW gateway "
                     f"coordinator_request_seconds ({gwt}). Slow-but-valid streaming/non-streaming "
                     f"providers will false-fail with coordinator_unavailable before the request "
                     f"budget is exhausted. Set coordinator_header_timeout_seconds >= "
                     f"coordinator_request_seconds (typically equal).")
        else:
            if ght is None:
                ok(f"C2b header timeout: absent -> default 300 >= gateway request {gwt}s")
            else:
                ok(f"C2b header timeout: gateway header {ght}s >= gateway request {gwt}s")
else:
    print("  note: gateway.yaml not provided -> skipped C2 timer cross-check")

# Surface WARN count so a final "passed" line cannot hide an UNVERIFIED
# cross-file C2c (audit-r5 MINOR): operators scanning wrapper output
# would otherwise miss the manual-verification prompt.
if warns:
    print(f"\nconfig-drift summary: {warns} WARN(s) — review above; some C2c "
          f"invariants may require manual verification (see UNVERIFIED lines)")
else:
    print("\nconfig-drift summary: 0 WARN(s)")

sys.exit(1 if fail else 0)
PY
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "config-drift check FAILED — fix the above before deploying" >&2
  exit 1
fi
echo "config-drift check passed"

# #615 production exception register gate (default-safe).
# Hard-fails malformed/ownerless/scope-mismatched/clock-expired-active rows and
# tombstone resurrection. status=expired and unbounded active rows warn unless
# MACPROVIDER_EXCEPTION_ENFORCEMENT=1. See ops/runbooks/production-exception-register.md.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd -P)"
EXCEPTION_CHECK="$REPO_ROOT/scripts/check-production-exceptions.py"
if [ ! -f "$EXCEPTION_CHECK" ]; then
  echo "FAIL: production exception checker missing: $EXCEPTION_CHECK" >&2
  exit 1
fi
echo "production exception register gate (deploy, default-safe unless ENFORCEMENT=1)"
python3 "$EXCEPTION_CHECK" gate --mode=deploy || {
  echo "production exception gate FAILED — fix ops/exceptions/ or set a reviewed enforcement override" >&2
  exit 1
}

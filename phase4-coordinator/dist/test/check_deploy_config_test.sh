#!/usr/bin/env bash
# check_deploy_config_test.sh — tests for check-deploy-config.sh, the
# fail-closed C2 pre-deploy gate. Plain-bash assertions (no bats dependency),
# matching the house style of ../../../phase5-gateway/dist/test/archive_rotate_test.sh.
#
# Regression focus (observed 2026-06-17 on a gateway deploy to Pearl): the gate
# read operator_key literally and hex-validated the string "env:OPERATOR_KEY"
# (len 16) of an env-indirected config, FAILed, and pressured the operator into
# SKIP_C2_CHECK=1 — which silently skipped the genuinely load-bearing C2 timer
# check too. An `env:NAME` secret is "deferred to runtime" and must NOT fail the
# gate just for being indirected.
#
# Scenarios:
#   T1 — inline literal 64-hex operator_key            -> pass (exit 0)
#   T2 — env:NAME, var UNSET (the false-fail)          -> pass, "deferred to runtime"
#   T3 — env:NAME, var SET to valid 64-hex             -> pass, "resolved from env"
#   T4 — env:NAME, var SET to a too-short value        -> FAIL (resolution still validates)
#   T5 — env:NAME, var SET to a placeholder            -> FAIL (resolution still validates)
#   T6 — inline placeholder (REPLACE_ME...)            -> FAIL (original guard preserved)
#   T7a/b — malformed env ref ("env:" / "env:1bad")    -> FAIL (clear message)
#   T7c — env:<hex-secret> typo                         -> FAIL, secret value redacted (audit-r6)
#   T8 — operator_key absent                           -> FAIL
#   T9 — env-indirected key does NOT mask a real C2 timer inversion -> FAIL on C2
#   T10 — gateway operator_key inline placeholder      -> FAIL (symmetric guard)
#   T11 — gateway operator_key env:NAME unset          -> pass, "deferred to runtime"
#   T12 — gateway operator_key absent                  -> FAIL (gateway requires it)
#   T13 — gateway service_token present + placeholder  -> FAIL
#   T14 — gateway service_token absent                 -> FAIL (REQUIRED post-cutover)
#   T15 — bootstrap flag absent                        -> FAIL (explicit onboarding choice required)
#   T16 — bootstrap flag false                         -> pass with clean-install warning
#   T17 — bootstrap flag invalid                       -> FAIL
#   T18 — bootstrap flag outside auth                  -> FAIL (must match runtime config path)
#   T19 — bootstrap flag nested under auth child       -> FAIL (direct child only)
#   T20 — gateway C2 timeout absent                    -> FAIL (runtime default may violate C2)
#   T21 — coordinator C2 timeout absent                -> FAIL (runtime default may violate C2)
#   T22 — C2b header timeout absent, request_seconds=300 (= effective default) -> pass
#   T23 — C2b header timeout absent, request_seconds=400 (> effective 300)     -> FAIL
#   T24 — C2b header timeout=120 < request_seconds=300                         -> FAIL
#   T25 — C2b header timeout=300 = request_seconds=300                         -> pass
#   T26 — mixed-fleet deadline env missing                                      -> FAIL
#   T27 — mixed-fleet deadline malformed                                        -> FAIL
#   T28 — mixed-fleet deadline expired                                          -> FAIL
#   T29 — mixed-fleet deadline future                                           -> pass
#   T30 — C2c coordinator auth.gateway_service_token absent                     -> FAIL
#   T31 — C2c coord operator_key == gateway_service_token (inline same)         -> FAIL
#   T32 — C2c gateway operator_key == service_token (inline same)               -> FAIL
#   T33 — C2c cross-file gw operator_key == coord gateway_service_token         -> FAIL
#   T34 — C2c all tokens env-deferred                                           -> skipped (pass)
#   T35 — C2c same env:NAME within same yaml file (static catch)                -> FAIL
#   T36 — C2c pairing gw service_token != coord service_token (inline)          -> FAIL
#   T37 — C2c pairing mismatch via different env vars resolving differently     -> FAIL
#   T38 — C2c pairing match via different env vars resolving to same value      -> pass
#   T39 — C2c pairing cross-file same env:NAME unresolved (separate env files)  -> pass with explicit WARN
#   T40 — C2c cross-file distinctness unresolved (no runtime backstop)          -> pass with WARN
#   T41 — C2c pairing inline+env-unresolved (no runtime backstop)               -> pass with WARN
#   T42 — C2c pairing both env-unresolved different names                       -> pass with WARN
#   T43 — WARN-bearing run surfaces "config-drift summary: N WARN(s)"           -> pass
#
# Run from repo root or any cwd: SCRIPT_DIR is derived from $0.
# Skips with a noisy message if python3 is unavailable (the gate needs it).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_SH="$DIST_DIR/check-deploy-config.sh"

[ -f "$CHECK_SH" ] || { echo "missing $CHECK_SH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed" >&2; exit 0; }

HEX64=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
PAST_RFC3339="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
FUTURE_RFC3339="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
# Second 64-hex constant, distinct from HEX64, for tests that exercise the
# C2c operator-vs-service-token distinctness invariant added in PR #172.
HEX64B=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210

PASS=0
FAIL=0
FAIL_NAMES=()

OUT=""   # last gate stdout+stderr
RC=0     # last gate exit code

# ---- helpers ---------------------------------------------------------------

mk_workdir() { mktemp -d -t check-deploy-config-test.XXXXXX; }

# Write a coordinator.yaml whose operator_key is $1 (verbatim, already
# quoted/unquoted by the caller) plus the fields the gate needs to otherwise
# pass: an explicit require_provider_tokens, a C2-clean request_timeout_s,
# and a distinct gateway_service_token (REQUIRED post-2026-07-12 cutover).
# $4 overrides the gateway_service_token line (defaults to inline HEX64B,
# distinct from HEX64 so C2c passes). Pass "" to omit it entirely (for
# tests that exercise the missing-token failure path).
write_coord() {
  local wd="$1" opkey="$2" rt="${3:-280}"
  local svcline="gateway_service_token: \"$HEX64B\""
  if [ "$#" -ge 4 ]; then svcline="$4"; fi
  {
    echo "auth:"
    echo "  operator_key: $opkey"
    [ -n "$svcline" ] && echo "  $svcline"
    echo "  require_provider_tokens: true"
    echo "  allow_tokenless_provisional_bootstrap: true"
    echo "routing:"
    echo "  request_timeout_s: $rt"
  } > "$wd/coordinator.yaml"
}

write_coord_bootstrap() {
  local wd="$1" bootstrap_line="$2"
  cat > "$wd/coordinator.yaml" <<EOF
auth:
  operator_key: "$HEX64"
  gateway_service_token: "$HEX64B"
  require_provider_tokens: true
  $bootstrap_line
routing:
  request_timeout_s: 280
EOF
}

# Write a minimal gateway.yaml carrying the key the C2 cross-check reads plus
# the coordinator.operator_key the gateway-credential check now validates.
# $2 = coordinator_request_seconds, $3 = operator_key value (verbatim),
# $4 = service_token line (verbatim, including key); default seeds an
# inline HEX64B service_token line so existing tests pass the post-cutover
# REQUIRED check. Pass "" to omit it (exercises missing-token failure).
write_gw() {
  local wd="$1" gwt="${2:-300}" opkey="${3:-env:COORDINATOR_OPERATOR_KEY}"
  local svc="service_token: \"$HEX64B\""
  if [ "$#" -ge 4 ]; then svc="$4"; fi
  {
    echo "coordinator:"
    echo "  operator_key: $opkey"
    [ -n "$svc" ] && echo "  $svc"
    echo "timeouts:"
    echo "  coordinator_request_seconds: $gwt"
  } > "$wd/gateway.yaml"
}

# Run the gate; capture combined output in OUT and exit code in RC. Any extra
# args (e.g. NAME=value) are passed through as environment for the gate, so a
# test can exercise the env:NAME resolution path.
run_check() {
  local wd="$1"; shift
  OUT="$(env "$@" bash "$CHECK_SH" "$wd/coordinator.yaml" "$wd/gateway.yaml" 2>&1)"
  RC=$?
}

assert_exit() { # $1 expected rc, $2 test name
  if [ "$RC" -eq "$1" ]; then
    PASS=$((PASS+1)); echo "  ok: $2 (exit $RC)"
  else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("$2"); echo "  FAIL: $2 — expected exit $1, got $RC"
    printf '%s\n' "$OUT" | sed 's/^/      | /'
  fi
}

assert_contains() { # $1 substring, $2 test name
  if grep -qF -- "$1" <<<"$OUT"; then
    PASS=$((PASS+1)); echo "  ok: $2 (found: $1)"
  else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("$2"); echo "  FAIL: $2 — output missing: $1"
    printf '%s\n' "$OUT" | sed 's/^/      | /'
  fi
}

assert_absent() { # $1 substring that must NOT appear, $2 test name
  if grep -qF -- "$1" <<<"$OUT"; then
    FAIL=$((FAIL+1)); FAIL_NAMES+=("$2"); echo "  FAIL: $2 — output should not contain: $1"
    printf '%s\n' "$OUT" | sed 's/^/      | /'
  else
    PASS=$((PASS+1)); echo "  ok: $2 (absent: $1)"
  fi
}

# ---- scenarios -------------------------------------------------------------

test_inline_hex_passes() {
  local wd; wd="$(mk_workdir)"
  write_gw "$wd"; write_coord "$wd" "\"$HEX64\""
  run_check "$wd"
  assert_exit 0 "T1 inline 64-hex passes"
  assert_contains "operator_key present (64-hex" "T1 inline 64-hex message"
  rm -rf "$wd"
}

test_env_ref_unset_is_deferred() {
  # The exact false-fail from 2026-06-17. Must NOT abort the deploy.
  local wd; wd="$(mk_workdir)"
  write_gw "$wd"; write_coord "$wd" "env:OPERATOR_KEY"
  # Explicitly clear the var so the host's environment can't mask the case.
  run_check "$wd" OPERATOR_KEY=
  assert_exit 0 "T2 env:NAME (unset) does not false-fail"
  assert_contains "deferred to runtime via env:OPERATOR_KEY" "T2 deferred message"
  rm -rf "$wd"
}

test_env_ref_set_valid_resolves() {
  local wd; wd="$(mk_workdir)"
  write_gw "$wd"; write_coord "$wd" "env:OPERATOR_KEY"
  run_check "$wd" "OPERATOR_KEY=$HEX64"
  assert_exit 0 "T3 env:NAME resolves to valid hex"
  assert_contains "resolved from env:OPERATOR_KEY" "T3 resolved message"
  rm -rf "$wd"
}

test_env_ref_set_short_fails() {
  local wd; wd="$(mk_workdir)"
  write_gw "$wd"; write_coord "$wd" "env:OPERATOR_KEY"
  run_check "$wd" "OPERATOR_KEY=deadbeef"
  assert_exit 1 "T4 env:NAME resolves to short value -> FAIL"
  assert_contains "is not 64-hex" "T4 short-value message"
  rm -rf "$wd"
}

test_env_ref_set_placeholder_fails() {
  local wd; wd="$(mk_workdir)"
  write_gw "$wd"; write_coord "$wd" "env:OPERATOR_KEY"
  run_check "$wd" "OPERATOR_KEY=REPLACE_ME_WITH_RANDOM_HEX_64"
  assert_exit 1 "T5 env:NAME resolves to placeholder -> FAIL"
  assert_contains "PLACEHOLDER" "T5 placeholder message"
  rm -rf "$wd"
}

test_inline_placeholder_fails() {
  local wd; wd="$(mk_workdir)"
  write_gw "$wd"; write_coord "$wd" "\"REPLACE_ME_WITH_RANDOM_HEX_64\""
  run_check "$wd"
  assert_exit 1 "T6 inline placeholder still rejected"
  assert_contains "PLACEHOLDER" "T6 placeholder message"
  rm -rf "$wd"
}

test_malformed_env_ref_fails() {
  local wd; wd="$(mk_workdir)"
  write_gw "$wd"
  # Empty NAME.
  write_coord "$wd" "env:"
  run_check "$wd"
  assert_exit 1 "T7a env: (empty NAME) -> FAIL"
  assert_contains "malformed env indirection" "T7a malformed message"
  assert_contains "value redacted" "T7a redaction note present"
  # Leading digit is not a valid env var identifier.
  write_coord "$wd" "env:1bad"
  run_check "$wd"
  assert_exit 1 "T7b env:1bad -> FAIL"
  assert_contains "malformed env indirection" "T7b malformed message"
  assert_absent "1bad" "T7b raw indirection value not leaked"
  rm -rf "$wd"
}

test_malformed_env_does_not_leak_hex_secret() {
  # Audit-r6 (security + code lanes -> HIGH): a typoed env:<hex-secret>
  # would otherwise reach the deploy log. Two leak paths:
  #   (a) hex starting with a digit (e.g. HEX64 "0123...") — fails the
  #       ENV_REF regex (NAME starts with [A-Za-z_]) -> malformed branch.
  #   (b) hex starting with a letter (e.g. HEX64B "fedcba...") — passes
  #       ENV_REF as a "valid env name", reaches the deferred-OK line
  #       which previously echoed `env:fedcba...` to deploy logs.
  # r6 fixes both: malformed redacts via `value redacted`; deferred-OK
  # path adds a secret-shape sniff on the NAME and hard-fails with a
  # redacted typo-suspect message when len>=32 and pure-hex.
  local wd; wd="$(mk_workdir)"

  # Path (a) — hex starts with digit -> malformed.
  write_gw "$wd"
  write_coord "$wd" "env:$HEX64"
  run_check "$wd"
  assert_exit 1 "T7c-a env:<digit-leading-hex> typo -> FAIL"
  assert_contains "malformed env indirection" "T7c-a malformed message"
  assert_absent "$HEX64" "T7c-a HEX64 not leaked into output"

  # Path (b) — hex starts with letter -> deferred-OK secret-shape sniff.
  write_coord "$wd" "env:$HEX64B"
  run_check "$wd"
  assert_exit 1 "T7c-b env:<letter-leading-hex> typo -> FAIL"
  assert_contains "suspected secret-value typo" "T7c-b typo-suspect message"
  assert_absent "$HEX64B" "T7c-b HEX64B not leaked into output"

  rm -rf "$wd"
}

test_missing_key_fails() {
  local wd; wd="$(mk_workdir)"
  write_gw "$wd"
  cat > "$wd/coordinator.yaml" <<EOF
auth:
  require_provider_tokens: true
routing:
  request_timeout_s: 280
EOF
  run_check "$wd"
  assert_exit 1 "T8 absent operator_key -> FAIL"
  assert_contains "operator_key missing" "T8 missing message"
  rm -rf "$wd"
}

test_env_ref_does_not_mask_c2_inversion() {
  # An env-indirected (deferred) operator_key must not turn the gate into a
  # no-op: a real C2 timer inversion still has to be caught.
  local wd; wd="$(mk_workdir)"
  write_gw "$wd" 200                       # gateway 200s
  write_coord "$wd" "env:OPERATOR_KEY" 280  # coordinator 280s >= gateway -> inversion
  run_check "$wd" OPERATOR_KEY=
  assert_exit 1 "T9 C2 inversion -> FAIL"
  assert_contains "C2: coordinator request_timeout_s" "T9 C2 inversion still surfaced"
  rm -rf "$wd"
}

test_gateway_operator_key_inline_placeholder_fails() {
  # The residual gap the runtime can't catch: an inline placeholder is
  # non-empty so the gateway boots and silently fails upstream auth.
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\""                      # coordinator side clean
  write_gw "$wd" 300 "\"REPLACE_ME_WITH_RANDOM_HEX_64\""
  run_check "$wd"
  assert_exit 1 "T10 gateway operator_key placeholder -> FAIL"
  assert_contains "gateway operator_key is a PLACEHOLDER" "T10 message"
  rm -rf "$wd"
}

test_gateway_operator_key_env_unset_deferred() {
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\""
  write_gw "$wd" 300 "env:COORDINATOR_OPERATOR_KEY"
  run_check "$wd" COORDINATOR_OPERATOR_KEY=
  assert_exit 0 "T11 gateway operator_key env:NAME (unset) does not false-fail"
  assert_contains "gateway operator_key deferred to runtime" "T11 deferred message"
  rm -rf "$wd"
}

test_gateway_operator_key_absent_fails() {
  # gateway operator_key is required by config.go Validate.
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\""
  cat > "$wd/gateway.yaml" <<EOF
coordinator:
  operator_url: http://127.0.0.1:8444
timeouts:
  coordinator_request_seconds: 300
EOF
  run_check "$wd"
  assert_exit 1 "T12 gateway operator_key absent -> FAIL"
  assert_contains "gateway operator_key missing" "T12 missing message"
  rm -rf "$wd"
}

test_gateway_service_token_placeholder_fails() {
  # service_token, when set, is preferred over operator_key for upstream
  # calls — a placeholder there silently breaks auth too.
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\""
  write_gw "$wd" 300 "env:COORDINATOR_OPERATOR_KEY" 'service_token: "REPLACE_ME"'
  run_check "$wd" COORDINATOR_OPERATOR_KEY=
  assert_exit 1 "T13 gateway service_token placeholder -> FAIL"
  assert_contains "gateway service_token is a PLACEHOLDER" "T13 message"
  rm -rf "$wd"
}

test_gateway_service_token_absent_fails_post_cutover() {
  # Post-PR #172 (issue #87 item 3, 2026-07-12 cutover): service_token is
  # REQUIRED on the gateway side. Absence must hard-fail; without it the
  # gateway can't reach any /internal/* coordinator endpoint.
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\""
  write_gw "$wd" 300 "\"$HEX64\"" ""   # explicit "": omit service_token line
  run_check "$wd"
  assert_exit 1 "T14 gateway service_token absent -> FAIL (post-cutover REQUIRED)"
  assert_contains "gateway service_token missing" "T14 missing-service-token message"
  rm -rf "$wd"
}

test_bootstrap_flag_absent_fails() {
  local wd; wd="$(mk_workdir)"
  write_gw "$wd"
  cat > "$wd/coordinator.yaml" <<EOF
auth:
  operator_key: "$HEX64"
  require_provider_tokens: true
routing:
  request_timeout_s: 280
EOF
  run_check "$wd"
  assert_exit 1 "T15 bootstrap flag absent -> FAIL"
  assert_contains "allow_tokenless_provisional_bootstrap is ABSENT" "T15 missing bootstrap message"
  rm -rf "$wd"
}

test_bootstrap_flag_false_warns_but_passes() {
  local wd; wd="$(mk_workdir)"
  write_gw "$wd"
  write_coord_bootstrap "$wd" "allow_tokenless_provisional_bootstrap: false"
  run_check "$wd"
  assert_exit 0 "T16 bootstrap flag false -> pass"
  assert_contains "clean public installs need a pre-provisioned provider_token" "T16 bootstrap false warning"
  rm -rf "$wd"
}

test_bootstrap_flag_invalid_fails() {
  local wd; wd="$(mk_workdir)"
  write_gw "$wd"
  write_coord_bootstrap "$wd" "allow_tokenless_provisional_bootstrap: maybe"
  run_check "$wd"
  assert_exit 1 "T17 bootstrap flag invalid -> FAIL"
  assert_contains "allow_tokenless_provisional_bootstrap must be true or false" "T17 invalid bootstrap message"
  rm -rf "$wd"
}

test_bootstrap_flag_misplaced_fails() {
  local wd; wd="$(mk_workdir)"
  write_gw "$wd"
  cat > "$wd/coordinator.yaml" <<EOF
auth:
  operator_key: "$HEX64"
  require_provider_tokens: true
logging:
  allow_tokenless_provisional_bootstrap: true
routing:
  request_timeout_s: 280
EOF
  run_check "$wd"
  assert_exit 1 "T18 bootstrap flag outside auth -> FAIL"
  assert_contains "allow_tokenless_provisional_bootstrap is ABSENT" "T18 misplaced bootstrap message"
  rm -rf "$wd"
}

test_bootstrap_flag_nested_under_auth_child_fails() {
  local wd; wd="$(mk_workdir)"
  write_gw "$wd"
  cat > "$wd/coordinator.yaml" <<EOF
auth:
  operator_key: "$HEX64"
  require_provider_tokens: true
  github_oauth:
    allow_tokenless_provisional_bootstrap: true
routing:
  request_timeout_s: 280
EOF
  run_check "$wd"
  assert_exit 1 "T19 bootstrap flag nested under auth child -> FAIL"
  assert_contains "allow_tokenless_provisional_bootstrap is ABSENT" "T19 nested bootstrap message"
  rm -rf "$wd"
}

test_gateway_c2_timeout_absent_fails() {
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\"" 400
  cat > "$wd/gateway.yaml" <<EOF
coordinator:
  operator_key: "$HEX64"
timeouts:
  coordinator_header_timeout_seconds: 10
EOF
  run_check "$wd"
  assert_exit 1 "T20 gateway C2 timeout absent -> FAIL"
  assert_contains "timeouts.coordinator_request_seconds is ABSENT" "T20 missing gateway C2 message"
  assert_absent "Traceback" "T20 output stays clean (no python traceback from C2b)"
  rm -rf "$wd"
}

test_coordinator_c2_timeout_absent_fails() {
  local wd; wd="$(mk_workdir)"
  write_gw "$wd" 200
  cat > "$wd/coordinator.yaml" <<EOF
auth:
  operator_key: "$HEX64"
  require_provider_tokens: true
  allow_tokenless_provisional_bootstrap: true
routing:
  preflight_timeout_s: 5
EOF
  run_check "$wd"
  assert_exit 1 "T21 coordinator C2 timeout absent -> FAIL"
  assert_contains "routing.request_timeout_s is ABSENT" "T21 missing coordinator C2 message"
  rm -rf "$wd"
}

# C2b regression tests (post-#92 / PR #167): the gateway response-header
# timeout MUST be >= the coordinator request budget; otherwise slow-but-valid
# streaming/non-streaming first-event scenarios false-fail. The check honors
# the runtime default (300s) when the header field is absent.

test_c2b_absent_header_default_matches_request_passes() {
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\"" 280
  # gateway: explicit request=300, no header timeout (effective default 300).
  cat > "$wd/gateway.yaml" <<EOF
coordinator:
  operator_key: "$HEX64"
  service_token: "$HEX64B"
timeouts:
  coordinator_request_seconds: 300
EOF
  run_check "$wd"
  assert_exit 0 "T22 C2b absent header + request=300 -> pass"
  assert_contains "C2b header timeout: absent -> default 300 >= gateway request 300s" "T22 expected ok line"
  rm -rf "$wd"
}

test_c2b_absent_header_with_raised_request_fails() {
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\"" 380
  # gateway: explicit request=400 but no header timeout (effective default 300 < 400).
  cat > "$wd/gateway.yaml" <<EOF
coordinator:
  operator_key: "$HEX64"
timeouts:
  coordinator_request_seconds: 400
EOF
  run_check "$wd"
  assert_exit 1 "T23 C2b absent header + request=400 -> FAIL"
  assert_contains "coordinator_header_timeout_seconds is ABSENT" "T23 expected absent-header hard message"
  rm -rf "$wd"
}

test_c2b_explicit_header_below_request_fails() {
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\"" 280
  cat > "$wd/gateway.yaml" <<EOF
coordinator:
  operator_key: "$HEX64"
timeouts:
  coordinator_request_seconds: 300
  coordinator_header_timeout_seconds: 120
EOF
  run_check "$wd"
  assert_exit 1 "T24 C2b explicit header 120 < request 300 -> FAIL"
  assert_contains "is BELOW gateway coordinator_request_seconds" "T24 expected below-request hard message"
  rm -rf "$wd"
}

test_c2b_explicit_header_equals_request_passes() {
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\"" 280
  cat > "$wd/gateway.yaml" <<EOF
coordinator:
  operator_key: "$HEX64"
  service_token: "$HEX64B"
timeouts:
  coordinator_request_seconds: 300
  coordinator_header_timeout_seconds: 300
EOF
  run_check "$wd"
  assert_exit 0 "T25 C2b explicit header 300 = request 300 -> pass"
  assert_contains "C2b header timeout: gateway header 300s >= gateway request 300s" "T25 expected ok line"
  rm -rf "$wd"
}

test_model_hash_legacy_deadline_env_missing_fails() {
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\"" 280
  cat >> "$wd/coordinator.yaml" <<'EOF'
tier2:
  model_hash_legacy_until: env:MODEL_HASH_LEGACY_UNTIL_TEST
EOF
  write_gw "$wd"
  run_check "$wd"
  assert_exit 1 "T26 mixed-fleet deadline env missing -> FAIL"
  assert_contains "mixed-version rollout requires an explicit future RFC3339 deadline" "T26 expected missing deadline message"
  rm -rf "$wd"
}

test_model_hash_legacy_deadline_malformed_fails() {
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\"" 280
  cat >> "$wd/coordinator.yaml" <<'EOF'
tier2:
  model_hash_legacy_until: tomorrow
EOF
  write_gw "$wd"
  run_check "$wd"
  assert_exit 1 "T27 mixed-fleet deadline malformed -> FAIL"
  assert_contains "must resolve to RFC3339" "T27 expected malformed deadline message"
  rm -rf "$wd"
}

test_model_hash_legacy_deadline_expired_fails() {
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\"" 280
  cat >> "$wd/coordinator.yaml" <<EOF
tier2:
  model_hash_legacy_until: "$PAST_RFC3339"
EOF
  write_gw "$wd"
  run_check "$wd"
  assert_exit 1 "T28 mixed-fleet deadline expired -> FAIL"
  assert_contains "model_hash_legacy_until is expired" "T28 expected expired deadline message"
  rm -rf "$wd"
}

test_model_hash_legacy_deadline_future_passes() {
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\"" 280
  cat >> "$wd/coordinator.yaml" <<'EOF'
tier2:
  model_hash_legacy_until: env:MODEL_HASH_LEGACY_UNTIL_TEST
EOF
  write_gw "$wd"
  run_check "$wd" "MODEL_HASH_LEGACY_UNTIL_TEST=$FUTURE_RFC3339"
  assert_exit 0 "T29 mixed-fleet deadline future -> pass"
  assert_contains "explicit future migration deadline" "T29 expected future deadline message"
  rm -rf "$wd"
}

# --- C2c regression tests (PR #172 / issue #87 item 3) ---
# C2c covers two invariants:
#   (1) coordinator auth.gateway_service_token is REQUIRED post-cutover.
#   (2) operator_key and service_token must be DISTINCT — equal values would
#       let the operator credential authenticate /internal/* by value,
#       collapsing the operator-vs-service credential split.

test_c2c_coord_service_token_absent_fails() {
  local wd; wd="$(mk_workdir)"
  write_gw "$wd"
  # write_coord with explicit "" 4th arg = omit gateway_service_token line.
  write_coord "$wd" "\"$HEX64\"" 280 ""
  run_check "$wd"
  assert_exit 1 "T30 coordinator gateway_service_token absent -> FAIL"
  assert_contains "coordinator gateway_service_token missing" "T30 missing-token message"
  rm -rf "$wd"
}

test_c2c_coord_operator_equals_service_fails() {
  local wd; wd="$(mk_workdir)"
  write_gw "$wd"
  # Both coordinator tokens inline = same HEX64 value -> distinctness violated.
  write_coord "$wd" "\"$HEX64\"" 280 "gateway_service_token: \"$HEX64\""
  run_check "$wd"
  assert_exit 1 "T31 coord operator_key == gateway_service_token -> FAIL"
  assert_contains "C2c: coordinator auth.operator_key == coordinator auth.gateway_service_token" "T31 C2c distinctness message"
  rm -rf "$wd"
}

test_c2c_gateway_operator_equals_service_fails() {
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\""
  # Both gateway tokens inline = same HEX64 value -> distinctness violated.
  write_gw "$wd" 300 "\"$HEX64\"" "service_token: \"$HEX64\""
  run_check "$wd"
  assert_exit 1 "T32 gateway operator_key == service_token -> FAIL"
  assert_contains "C2c: gateway coordinator.operator_key == gateway coordinator.service_token" "T32 C2c gateway distinctness message"
  rm -rf "$wd"
}

test_c2c_cross_file_gw_operator_equals_coord_service_fails() {
  local wd; wd="$(mk_workdir)"
  # gateway operator_key = HEX64; coordinator gateway_service_token = HEX64 (same).
  # Cross-file equality means the operator credential the gateway uses for /poolz
  # is also accepted by the coordinator as the /internal/* credential.
  write_coord "$wd" "\"$HEX64B\"" 280 "gateway_service_token: \"$HEX64\""
  write_gw "$wd" 300 "\"$HEX64\"" "service_token: \"$HEX64B\""
  run_check "$wd"
  assert_exit 1 "T33 cross-file gw operator_key == coord gateway_service_token -> FAIL"
  assert_contains "C2c: gateway coordinator.operator_key == coordinator auth.gateway_service_token" "T33 cross-file distinctness message"
  rm -rf "$wd"
}

test_c2c_deferred_env_skipped() {
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "env:OPERATOR_KEY" 280 "gateway_service_token: env:COORD_SVC_TOKEN"
  write_gw "$wd" 300 "env:COORDINATOR_OPERATOR_KEY" "service_token: env:GW_SVC_TOKEN"
  # All env vars unset -> all tokens deferred -> C2c skipped (cannot judge).
  run_check "$wd" OPERATOR_KEY= COORD_SVC_TOKEN= COORDINATOR_OPERATOR_KEY= GW_SVC_TOKEN=
  assert_exit 0 "T34 all env tokens deferred -> C2c skipped + pass overall"
  assert_contains "skipped, deferred to runtime" "T34 deferred skip message"
  rm -rf "$wd"
}

test_c2c_same_env_name_same_file_static_fail() {
  # Audit-r2 finding (refined audit-r3): same env:NAME on both sides of a
  # SAME-file distinctness check is a static-catch hard fail because both
  # fields resolve from the same systemd env file at runtime. (Cross-file
  # same-env-NAME is unsafe to assume — see T36 — because coordinator and
  # gateway units source separate env files.)
  local wd; wd="$(mk_workdir)"
  write_gw "$wd"
  # Both coordinator-side tokens reference the SAME env var name within
  # coordinator.yaml -> same coordinator.env at runtime -> collapse to one
  # value -> hard fail before resolution.
  write_coord "$wd" "env:SHARED_TOKEN" 280 "gateway_service_token: env:SHARED_TOKEN"
  run_check "$wd" SHARED_TOKEN=
  assert_exit 1 "T35 same env:NAME within coordinator.yaml -> FAIL (same-file static catch)"
  assert_contains "both reference env:SHARED_TOKEN" "T35 same-env-name same-file message"
  assert_contains "same file -> same env at runtime" "T35 same-file scope message"
  rm -rf "$wd"
}

test_c2c_pairing_inline_mismatch_fails() {
  # Audit-r2 convergent (3/3 lanes): gateway sends Coordinator.ServiceToken
  # on /internal/*; coordinator accepts ONLY its auth.gateway_service_token.
  # Mismatched-but-individually-valid 64-hex passes both module Validate()s
  # and earlier deploy gate -> instant /internal/* outage. The pairing gate
  # catches it.
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\"" 280 "gateway_service_token: \"$HEX64B\""
  # gateway service_token = a third distinct value (HEX64C) — passes
  # individual hex checks and distinctness, but mismatches coordinator.
  local HEX64C=11112222333344445555666677778888999900001111222233334444aaaabbbb
  write_gw "$wd" 300 "\"$HEX64\"" "service_token: \"$HEX64C\""
  run_check "$wd"
  assert_exit 1 "T36 gateway/coord service_token mismatch (inline) -> FAIL"
  assert_contains "gateway coordinator.service_token != coordinator auth.gateway_service_token" "T36 pairing-mismatch message"
  rm -rf "$wd"
}

test_c2c_pairing_env_resolved_mismatch_fails() {
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\"" 280 "gateway_service_token: env:COORD_SVC"
  write_gw "$wd" 300 "\"$HEX64\"" "service_token: env:GW_SVC"
  # Both env vars set but to different values.
  run_check "$wd" COORD_SVC="$HEX64B" GW_SVC=11112222333344445555666677778888999900001111222233334444aaaabbbb
  assert_exit 1 "T37 gateway/coord service_token mismatch (env-resolved) -> FAIL"
  assert_contains "gateway coordinator.service_token != coordinator auth.gateway_service_token" "T37 env-mismatch message"
  rm -rf "$wd"
}

test_c2c_pairing_env_resolved_match_passes() {
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\"" 280 "gateway_service_token: env:COORD_SVC"
  write_gw "$wd" 300 "\"$HEX64\"" "service_token: env:GW_SVC"
  # Both env vars set to the SAME value via different names — pairing ok.
  run_check "$wd" COORD_SVC="$HEX64B" GW_SVC="$HEX64B"
  assert_exit 0 "T38 gateway/coord service_token match (env-resolved, diff names) -> pass"
  assert_contains "C2c pairing gateway coordinator.service_token == coordinator auth.gateway_service_token: match" "T38 pairing-match message"
  rm -rf "$wd"
}

test_c2c_pairing_cross_file_same_env_name_unverified_warn() {
  # Audit-r3 finding (3/3 lanes): coord and gw systemd units source
  # SEPARATE env files (/etc/macprovider/coordinator.env vs gateway.env).
  # Same env:NAME on both sides does NOT prove same value — the env files
  # can disagree. r2 wrongly treated this as a proven pass; r3 fix: WARN
  # (loud, not silent) so the operator knows the gate cannot verify and
  # must check both env files manually.
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\"" 280 "gateway_service_token: env:SHARED_SVC"
  write_gw "$wd" 300 "\"$HEX64\"" "service_token: env:SHARED_SVC"
  run_check "$wd" SHARED_SVC=
  # Exit 0 — WARN is not a hard fail, but the message is loud.
  assert_exit 0 "T39 pairing cross-file same env:NAME unresolved -> pass with explicit WARN"
  assert_contains "UNVERIFIED" "T39 unverified-warn message"
  assert_contains "SEPARATE env files" "T39 separate-env-files explanation"
  rm -rf "$wd"
}

test_c2c_cross_file_distinctness_unresolved_warns() {
  # Audit-r4 finding (3-of-3 lanes): cross-file _check_distinct unresolved
  # has NO runtime backstop (each module's Validate only sees its own
  # file). r3 emitted ok-skip; r4 fix: WARN loudly, name the gap.
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\"" 280 "gateway_service_token: env:SHARED_NAME"
  write_gw "$wd" 300 "env:SHARED_NAME" "service_token: \"$HEX64B\""
  run_check "$wd" SHARED_NAME=
  assert_exit 0 "T40 cross-file distinctness unresolved -> pass with WARN"
  assert_contains "WARN: C2c gateway coordinator.operator_key vs coordinator auth.gateway_service_token: UNVERIFIED" "T40 cross-file warn message"
  assert_contains "NO runtime backstop" "T40 backstop-gap explanation"
  rm -rf "$wd"
}

test_c2c_pairing_inline_plus_env_unresolved_warns() {
  # Audit-r4 (3-of-3): inline on one side + unresolved env on the other
  # — pairing cannot be verified. r3 silently skipped; r4 must WARN.
  # Audit-r5 (3-of-3): the WARN must NOT print the inline raw value —
  # earlier `raw_a={raw!r}` leaked a live bearer into deploy output.
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\"" 280 "gateway_service_token: env:COORD_SVC"
  write_gw "$wd" 300 "\"$HEX64\"" "service_token: \"$HEX64B\""
  run_check "$wd" COORD_SVC=
  assert_exit 0 "T41 pairing inline+env-unresolved -> pass with WARN"
  assert_contains "C2c pairing gateway coordinator.service_token == coordinator auth.gateway_service_token: UNVERIFIED" "T41 pairing-warn message"
  assert_contains "NO runtime backstop" "T41 backstop-gap explanation"
  # Regression guards (audit-r5): the WARN must redact the inline value
  # and classify safely. HEX64B must NEVER appear in WARN/OK output.
  assert_absent "$HEX64B" "T41 redacted: HEX64B inline value not leaked"
  assert_contains "inline-redacted" "T41 inline side classified as inline-redacted"
  assert_contains "env:COORD_SVC (unresolved)" "T41 env side classified safely"
  rm -rf "$wd"
}

test_c2c_pairing_different_env_unresolved_warns() {
  # Audit-r4 (3-of-3): both sides env-deferred via DIFFERENT names —
  # cannot prove pairing without resolving. WARN.
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\"" 280 "gateway_service_token: env:COORD_SVC"
  write_gw "$wd" 300 "\"$HEX64\"" "service_token: env:GW_SVC"
  run_check "$wd" COORD_SVC= GW_SVC=
  assert_exit 0 "T42 pairing both-env-unresolved (diff names) -> pass with WARN"
  assert_contains "C2c pairing gateway coordinator.service_token == coordinator auth.gateway_service_token: UNVERIFIED" "T42 pairing-warn message"
  rm -rf "$wd"
}

test_warn_count_surfaced_in_summary() {
  # Audit-r5 MINOR (3-of-3): final pass line was bare "config-drift
  # check passed" even when WARNs had fired — easy to miss in a wall
  # of OKs. Summary line now reports the WARN count (exact number
  # depends on which optional fields are unset; here we assert the
  # line shape and the manual-verification prompt).
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\"" 280 "gateway_service_token: env:COORD_SVC"
  write_gw "$wd" 300 "\"$HEX64\"" "service_token: \"$HEX64B\""
  run_check "$wd" COORD_SVC=
  assert_exit 0 "T43 WARN-bearing run still passes overall"
  assert_contains "config-drift summary:" "T43 summary line present"
  assert_contains "WARN(s)" "T43 WARN count surfaced in summary"
  assert_contains "manual verification" "T43 summary prompts manual verification (UNVERIFIED prompt active)"
  rm -rf "$wd"
}

# ---- run -------------------------------------------------------------------

echo "== check-deploy-config.sh tests =="
echo "gate: $CHECK_SH"
echo

test_inline_hex_passes
test_env_ref_unset_is_deferred
test_env_ref_set_valid_resolves
test_env_ref_set_short_fails
test_env_ref_set_placeholder_fails
test_inline_placeholder_fails
test_malformed_env_ref_fails
test_malformed_env_does_not_leak_hex_secret
test_missing_key_fails
test_env_ref_does_not_mask_c2_inversion
test_gateway_operator_key_inline_placeholder_fails
test_gateway_operator_key_env_unset_deferred
test_gateway_operator_key_absent_fails
test_gateway_service_token_placeholder_fails
test_gateway_service_token_absent_fails_post_cutover
test_bootstrap_flag_absent_fails
test_bootstrap_flag_false_warns_but_passes
test_bootstrap_flag_invalid_fails
test_bootstrap_flag_misplaced_fails
test_bootstrap_flag_nested_under_auth_child_fails
test_gateway_c2_timeout_absent_fails
test_coordinator_c2_timeout_absent_fails
test_c2b_absent_header_default_matches_request_passes
test_c2b_absent_header_with_raised_request_fails
test_c2b_explicit_header_below_request_fails
test_c2b_explicit_header_equals_request_passes
test_model_hash_legacy_deadline_env_missing_fails
test_model_hash_legacy_deadline_malformed_fails
test_model_hash_legacy_deadline_expired_fails
test_model_hash_legacy_deadline_future_passes
test_c2c_coord_service_token_absent_fails
test_c2c_coord_operator_equals_service_fails
test_c2c_gateway_operator_equals_service_fails
test_c2c_cross_file_gw_operator_equals_coord_service_fails
test_c2c_deferred_env_skipped
test_c2c_same_env_name_same_file_static_fail
test_c2c_pairing_inline_mismatch_fails
test_c2c_pairing_env_resolved_mismatch_fails
test_c2c_pairing_env_resolved_match_passes
test_c2c_pairing_cross_file_same_env_name_unverified_warn
test_c2c_cross_file_distinctness_unresolved_warns
test_c2c_pairing_inline_plus_env_unresolved_warns
test_c2c_pairing_different_env_unresolved_warns
test_warn_count_surfaced_in_summary

echo
echo "== summary =="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "failed tests:"
  for n in "${FAIL_NAMES[@]}"; do echo "  - $n"; done
  exit 1
fi
exit 0

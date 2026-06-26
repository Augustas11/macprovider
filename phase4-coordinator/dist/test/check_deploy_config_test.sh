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
#   T7 — malformed env ref ("env:" / "env:1bad")       -> FAIL (clear message)
#   T8 — operator_key absent                           -> FAIL
#   T9 — env-indirected key does NOT mask a real C2 timer inversion -> FAIL on C2
#   T10 — gateway operator_key inline placeholder      -> FAIL (symmetric guard)
#   T11 — gateway operator_key env:NAME unset          -> pass, "deferred to runtime"
#   T12 — gateway operator_key absent                  -> FAIL (gateway requires it)
#   T13 — gateway service_token present + placeholder  -> FAIL
#   T14 — gateway service_token absent                 -> silent (optional field)
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

PASS=0
FAIL=0
FAIL_NAMES=()

OUT=""   # last gate stdout+stderr
RC=0     # last gate exit code

# ---- helpers ---------------------------------------------------------------

mk_workdir() { mktemp -d -t check-deploy-config-test.XXXXXX; }

# Write a coordinator.yaml whose operator_key is $1 (verbatim, already
# quoted/unquoted by the caller) plus the fields the gate needs to otherwise
# pass: an explicit require_provider_tokens and a C2-clean request_timeout_s.
write_coord() {
  local wd="$1" opkey="$2" rt="${3:-280}"
  cat > "$wd/coordinator.yaml" <<EOF
auth:
  operator_key: $opkey
  require_provider_tokens: true
  allow_tokenless_provisional_bootstrap: true
routing:
  request_timeout_s: $rt
EOF
}

write_coord_bootstrap() {
  local wd="$1" bootstrap_line="$2"
  cat > "$wd/coordinator.yaml" <<EOF
auth:
  operator_key: "$HEX64"
  require_provider_tokens: true
  $bootstrap_line
routing:
  request_timeout_s: 280
EOF
}

# Write a minimal gateway.yaml carrying the key the C2 cross-check reads plus
# the coordinator.operator_key the gateway-credential check now validates.
# $2 = coordinator_request_seconds, $3 = operator_key value (verbatim),
# $4 = service_token line (verbatim, including key) or "" to omit it entirely.
write_gw() {
  local wd="$1" gwt="${2:-300}" opkey="${3:-env:COORDINATOR_OPERATOR_KEY}" svc="${4:-}"
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
  if printf '%s' "$OUT" | grep -qF "$1"; then
    PASS=$((PASS+1)); echo "  ok: $2 (found: $1)"
  else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("$2"); echo "  FAIL: $2 — output missing: $1"
    printf '%s\n' "$OUT" | sed 's/^/      | /'
  fi
}

assert_absent() { # $1 substring that must NOT appear, $2 test name
  if printf '%s' "$OUT" | grep -qF "$1"; then
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
  # Leading digit is not a valid env var identifier.
  write_coord "$wd" "env:1bad"
  run_check "$wd"
  assert_exit 1 "T7b env:1bad -> FAIL"
  assert_contains "malformed env indirection" "T7b malformed message"
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

test_gateway_service_token_absent_is_silent() {
  # Optional field: absence must not emit a missing/FAIL line for it.
  local wd; wd="$(mk_workdir)"
  write_coord "$wd" "\"$HEX64\""
  write_gw "$wd" 300 "\"$HEX64\""   # no service_token line at all
  run_check "$wd"
  assert_exit 0 "T14 gateway service_token absent -> pass"
  assert_absent "service_token" "T14 optional service_token stays silent"
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
timeouts:
  coordinator_request_seconds: 300
  coordinator_header_timeout_seconds: 300
EOF
  run_check "$wd"
  assert_exit 0 "T25 C2b explicit header 300 = request 300 -> pass"
  assert_contains "C2b header timeout: gateway header 300s >= gateway request 300s" "T25 expected ok line"
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
test_missing_key_fails
test_env_ref_does_not_mask_c2_inversion
test_gateway_operator_key_inline_placeholder_fails
test_gateway_operator_key_env_unset_deferred
test_gateway_operator_key_absent_fails
test_gateway_service_token_placeholder_fails
test_gateway_service_token_absent_is_silent
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

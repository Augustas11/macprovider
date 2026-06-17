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
routing:
  request_timeout_s: $rt
EOF
}

# Write a minimal gateway.yaml carrying the one key the C2 cross-check reads.
write_gw() {
  local wd="$1" gwt="${2:-300}"
  cat > "$wd/gateway.yaml" <<EOF
timeouts:
  coordinator_request_seconds: $gwt
EOF
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
  assert_contains "C2: coordinator request_timeout_s" "T9 C2 inversion still surfaced"
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

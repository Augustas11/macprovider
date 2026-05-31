#!/usr/bin/env bash
# Hermetic safety checks for scripts/activate-tier2-behavioral-safety.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_ROOT="${TMPDIR:-/tmp}/tier2-behavioral-test.$$"
mkdir -p "$TMP_ROOT"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf '[tier2-behavioral-test] ERROR: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq -- "$needle" "$file"; then
    printf '%s\n' "--- $file ---" >&2
    cat "$file" >&2 || true
    fail "expected '$needle' in $file"
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -Fq -- "$needle" "$file"; then
    printf '%s\n' "--- $file ---" >&2
    cat "$file" >&2 || true
    fail "did not expect '$needle' in $file"
  fi
}

write_fake_verify() {
  cat >"$TMP_ROOT/verify" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"$FAKE_VERIFY_LOG"
case "$1" in
  --enforced)
    [ "${FAIL_ENFORCED_PREFLIGHT:-0}" != "1" ] || exit 10
    ;;
  *)
    exit 2
    ;;
esac
printf '{"mode":"%s","require_verified":true,"model_hash_state":"all"}\n' "${1#--}"
SH
  chmod +x "$TMP_ROOT/verify"
}

write_fake_ssh() {
  cat >"$TMP_ROOT/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${*: -1}"
printf '%s\n' "$cmd" >>"$FAKE_SSH_LOG"
case "$cmd" in
  *"python3 - <<'PY'"*)
    [ "${FAIL_PATCH:-0}" != "1" ] || exit 11
    printf 'config_backup=/remote/coordinator.yaml.bak-c3-test\n'
    printf 'updated tier2 behavioral safety\n'
    ;;
  *"journalctl"*)
    [ "${FAIL_JOURNAL:-0}" != "1" ] || exit 12
    printf 'May 31 tier2 config reloaded behavioral_safety_enabled=true\n'
    ;;
  *"systemctl kill -s HUP"*)
    printf 'active\n'
    ;;
  *"cp -a /remote/coordinator.yaml.bak-c3-test"*)
    printf 'rollback ok\n'
    ;;
  *)
    printf 'ok\n'
    ;;
esac
SH
  chmod +x "$TMP_ROOT/ssh"
}

write_fake_curl() {
  cat >"$TMP_ROOT/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
printf '%s\n' "$url" >>"$FAKE_CURL_LOG"
if [ "${FAIL_DISCLOSURE:-0}" = "1" ]; then
  cat <<'JSON'
{
  "data": [],
  "tier1_disclosure": {"untrusted_provider_safety": "none"},
  "tier2": {
    "phase": "mixed",
    "behavioral_safety": {
      "state": "none",
      "size_cap": false,
      "encoding_validation": false,
      "ttft_anomaly_logging": false
    }
  }
}
JSON
  exit 0
fi
cat <<'JSON'
{
  "data": [{"id": "mlx-community/test"}],
  "tier1_disclosure": {"untrusted_provider_safety": "enforced"},
  "tier2": {
    "phase": "mixed",
    "behavioral_safety": {
      "state": "enforced",
      "size_cap": true,
      "encoding_validation": true,
      "ttft_anomaly_logging": true
    }
  }
}
JSON
SH
  chmod +x "$TMP_ROOT/curl"
}

run_apply() {
  PATH="$TMP_ROOT:$PATH" \
    FAKE_VERIFY_LOG="$TMP_ROOT/verify.log" \
    FAKE_SSH_LOG="$TMP_ROOT/ssh.log" \
    FAKE_CURL_LOG="$TMP_ROOT/curl.log" \
    VERIFY_SCRIPT="$TMP_ROOT/verify" \
    SSH_BIN="$TMP_ROOT/ssh" \
    SSH_KEY="$TMP_ROOT/key" \
    REMOTE_CONFIG=/remote/coordinator.yaml \
    DEMO_TOKEN=demo \
    OPERATOR_KEY=operator \
    "$REPO_ROOT/scripts/activate-tier2-behavioral-safety.sh" --apply
}

touch "$TMP_ROOT/key"
write_fake_verify
write_fake_ssh
write_fake_curl

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
: >"$TMP_ROOT/curl.log"
run_apply >/tmp/tier2-behavioral-success.out
assert_contains "$TMP_ROOT/verify.log" "--enforced"
assert_contains "$TMP_ROOT/ssh.log" "python3 - <<'PY'"
assert_contains "$TMP_ROOT/ssh.log" "behavioral_safety_enabled"
assert_contains "$TMP_ROOT/ssh.log" "output_size_cap_bytes"
assert_contains "$TMP_ROOT/ssh.log" "response_time_anomaly_enabled"
assert_contains "$TMP_ROOT/ssh.log" "require_hash_verified"
assert_not_contains "$TMP_ROOT/ssh.log" "require_hash_verified: true"
assert_contains "$TMP_ROOT/ssh.log" "systemctl kill -s HUP"
assert_contains "$TMP_ROOT/ssh.log" "journalctl"
assert_contains "$TMP_ROOT/curl.log" "/v1/models"
assert_not_contains "$TMP_ROOT/ssh.log" "cp -a /remote/coordinator.yaml.bak-c3-test"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
: >"$TMP_ROOT/curl.log"
if FAIL_ENFORCED_PREFLIGHT=1 run_apply >/tmp/tier2-behavioral-preflight-fail.out 2>/tmp/tier2-behavioral-preflight-fail.err; then
  fail "expected enforced preflight failure"
fi
assert_contains "$TMP_ROOT/verify.log" "--enforced"
assert_not_contains "$TMP_ROOT/ssh.log" "python3 - <<'PY'"
assert_not_contains "$TMP_ROOT/curl.log" "/v1/models"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
: >"$TMP_ROOT/curl.log"
if FAIL_JOURNAL=1 run_apply >/tmp/tier2-behavioral-journal-fail.out 2>/tmp/tier2-behavioral-journal-fail.err; then
  fail "expected journal verification failure"
fi
assert_contains "$TMP_ROOT/ssh.log" "journalctl"
assert_contains "$TMP_ROOT/ssh.log" "cp -a /remote/coordinator.yaml.bak-c3-test"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
: >"$TMP_ROOT/curl.log"
if FAIL_DISCLOSURE=1 run_apply >/tmp/tier2-behavioral-disclosure-fail.out 2>/tmp/tier2-behavioral-disclosure-fail.err; then
  fail "expected disclosure verification failure"
fi
assert_contains "$TMP_ROOT/curl.log" "/v1/models"
assert_contains "$TMP_ROOT/ssh.log" "cp -a /remote/coordinator.yaml.bak-c3-test"

"$REPO_ROOT/scripts/activate-tier2-behavioral-safety.sh" --plan >/tmp/tier2-behavioral-plan.out
assert_contains /tmp/tier2-behavioral-plan.out "Plan only. No production state was changed."
assert_contains /tmp/tier2-behavioral-plan.out "tier2.require_hash_verified"
assert_contains /tmp/tier2-behavioral-plan.out "tier2.behavioral_safety.state: enforced"

printf '[tier2-behavioral-test] ok\n'

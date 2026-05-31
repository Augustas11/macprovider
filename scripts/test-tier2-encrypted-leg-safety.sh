#!/usr/bin/env bash
# Hermetic safety checks for scripts/activate-tier2-encrypted-leg.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_ROOT="${TMPDIR:-/tmp}/tier2-encrypted-leg-test.$$"
mkdir -p "$TMP_ROOT"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf '[tier2-encrypted-leg-test] ERROR: %s\n' "$*" >&2
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
  --b6-ready)
    [ "${FAIL_B6_PREFLIGHT:-0}" != "1" ] || exit 10
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
    printf 'config_backup=/remote/coordinator.yaml.bak-c4a-test\n'
    printf 'updated require_encrypted_leg=true\n'
    ;;
  *"journalctl"*)
    [ "${FAIL_JOURNAL:-0}" != "1" ] || exit 12
    printf 'May 31 tier2 config reloaded require_encrypted_leg=true\n'
    ;;
  *"systemctl kill -s HUP"*)
    printf 'active\n'
    ;;
  *"cp -a /remote/coordinator.yaml.bak-c4a-test"*)
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
if [[ "$url" == */v1/models ]]; then
  models_count="$(grep -c '/v1/models' "$FAKE_CURL_LOG" || true)"
  if [ "${FAIL_READINESS:-0}" = "1" ] || { [ "${FAIL_DISCLOSURE:-0}" = "1" ] && [ "$models_count" -gt 1 ]; }; then
    cat <<'JSON'
{
  "data": [],
  "tier1_disclosure": {
    "provider_leg_encryption": "partial",
    "tier2": {
      "encrypted_leg": {
        "state": "partial",
        "encrypted_provider_count": 1,
        "unencrypted_provider_count": 1,
        "mixed": true,
        "scope": "coordinator_to_provider_only"
      }
    }
  },
  "tier2": {
    "encrypted_leg": {
      "state": "partial",
      "encrypted_provider_count": 1,
      "unencrypted_provider_count": 1,
      "mixed": true,
      "scope": "coordinator_to_provider_only"
    }
  }
}
JSON
    exit 0
  fi
  cat <<'JSON'
{
  "data": [{"id": "mlx-community/test"}],
  "tier1_disclosure": {
    "provider_leg_encryption": "all",
    "tier2": {
      "encrypted_leg": {
        "state": "all",
        "encrypted_provider_count": 1,
        "unencrypted_provider_count": 0,
        "mixed": false,
        "scope": "coordinator_to_provider_only"
      }
    }
  },
  "tier2": {
    "encrypted_leg": {
      "state": "all",
      "encrypted_provider_count": 1,
      "unencrypted_provider_count": 0,
      "mixed": false,
      "scope": "coordinator_to_provider_only"
    }
  }
}
JSON
  exit 0
fi

if [[ "$url" == */poolz ]]; then
  if [ "${FAIL_READINESS:-0}" = "1" ]; then
    cat <<'JSON'
{
  "pool": [
    {
      "provider_id": "plain",
      "model_id": "mlx-community/test",
      "binary_version": "1.2.5",
      "state": "ready",
      "slots_free": 1,
      "encrypted_leg": false
    }
  ]
}
JSON
    exit 0
  fi
  if [ "${FAIL_OLD_ENCRYPTED:-0}" = "1" ]; then
    cat <<'JSON'
{
  "pool": [
    {
      "provider_id": "old-encrypted",
      "model_id": "mlx-community/test",
      "binary_version": "1.2.5",
      "state": "ready",
      "slots_free": 1,
      "encrypted_leg": true
    }
  ]
}
JSON
    exit 0
  fi
  cat <<'JSON'
{
  "pool": [
    {
      "provider_id": "encrypted",
      "model_id": "mlx-community/test",
      "binary_version": "1.2.6",
      "state": "ready",
      "slots_free": 1,
      "encrypted_leg": true
    }
  ]
}
JSON
  exit 0
fi

printf '{}\n'
SH
  chmod +x "$TMP_ROOT/curl"
}

run_apply() {
  PATH="$TMP_ROOT:$PATH" \
    FAIL_B6_PREFLIGHT="${FAIL_B6_PREFLIGHT:-0}" \
    FAIL_READINESS="${FAIL_READINESS:-0}" \
    FAIL_OLD_ENCRYPTED="${FAIL_OLD_ENCRYPTED:-0}" \
    FAIL_JOURNAL="${FAIL_JOURNAL:-0}" \
    FAIL_DISCLOSURE="${FAIL_DISCLOSURE:-0}" \
    FAKE_VERIFY_LOG="$TMP_ROOT/verify.log" \
    FAKE_SSH_LOG="$TMP_ROOT/ssh.log" \
    FAKE_CURL_LOG="$TMP_ROOT/curl.log" \
    VERIFY_SCRIPT="$TMP_ROOT/verify" \
    SSH_BIN="$TMP_ROOT/ssh" \
    SSH_KEY="$TMP_ROOT/key" \
    REMOTE_CONFIG=/remote/coordinator.yaml \
    DEMO_TOKEN=demo \
    OPERATOR_KEY=operator \
    "$REPO_ROOT/scripts/activate-tier2-encrypted-leg.sh" --apply
}

touch "$TMP_ROOT/key"
write_fake_verify
write_fake_ssh
write_fake_curl

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
: >"$TMP_ROOT/curl.log"
run_apply >/tmp/tier2-encrypted-leg-success.out
assert_contains "$TMP_ROOT/verify.log" "--b6-ready"
assert_contains "$TMP_ROOT/curl.log" "/v1/models"
assert_contains "$TMP_ROOT/curl.log" "/poolz"
assert_contains "$TMP_ROOT/ssh.log" "python3 - <<'PY'"
assert_contains "$TMP_ROOT/ssh.log" "require_encrypted_leg"
assert_contains "$TMP_ROOT/ssh.log" "require_hash_verified"
assert_contains "$TMP_ROOT/ssh.log" "systemctl kill -s HUP"
assert_contains "$TMP_ROOT/ssh.log" "journalctl"
assert_not_contains "$TMP_ROOT/ssh.log" "require_attestation: true"
assert_not_contains "$TMP_ROOT/ssh.log" "cp -a /remote/coordinator.yaml.bak-c4a-test"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
: >"$TMP_ROOT/curl.log"
if FAIL_B6_PREFLIGHT=1 run_apply >/tmp/tier2-encrypted-leg-preflight-fail.out 2>/tmp/tier2-encrypted-leg-preflight-fail.err; then
  fail "expected B6 readiness preflight failure"
fi
assert_contains "$TMP_ROOT/verify.log" "--b6-ready"
assert_not_contains "$TMP_ROOT/ssh.log" "python3 - <<'PY'"
assert_not_contains "$TMP_ROOT/curl.log" "/v1/models"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
: >"$TMP_ROOT/curl.log"
if FAIL_READINESS=1 run_apply >/tmp/tier2-encrypted-leg-readiness-fail.out 2>/tmp/tier2-encrypted-leg-readiness-fail.err; then
  fail "expected encrypted-leg readiness failure"
fi
assert_contains "$TMP_ROOT/verify.log" "--b6-ready"
assert_contains "$TMP_ROOT/curl.log" "/v1/models"
assert_not_contains "$TMP_ROOT/ssh.log" "python3 - <<'PY'"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
: >"$TMP_ROOT/curl.log"
if FAIL_OLD_ENCRYPTED=1 run_apply >/tmp/tier2-encrypted-leg-old-provider-fail.out 2>/tmp/tier2-encrypted-leg-old-provider-fail.err; then
  fail "expected old encrypted-provider readiness failure"
fi
assert_contains "$TMP_ROOT/verify.log" "--b6-ready"
assert_contains "$TMP_ROOT/curl.log" "/poolz"
assert_not_contains "$TMP_ROOT/ssh.log" "python3 - <<'PY'"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
: >"$TMP_ROOT/curl.log"
if FAIL_JOURNAL=1 run_apply >/tmp/tier2-encrypted-leg-journal-fail.out 2>/tmp/tier2-encrypted-leg-journal-fail.err; then
  fail "expected journal verification failure"
fi
assert_contains "$TMP_ROOT/ssh.log" "journalctl"
assert_contains "$TMP_ROOT/ssh.log" "cp -a /remote/coordinator.yaml.bak-c4a-test"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
: >"$TMP_ROOT/curl.log"
if FAIL_DISCLOSURE=1 run_apply >/tmp/tier2-encrypted-leg-disclosure-fail.out 2>/tmp/tier2-encrypted-leg-disclosure-fail.err; then
  fail "expected disclosure verification failure"
fi
assert_contains "$TMP_ROOT/curl.log" "/v1/models"
assert_contains "$TMP_ROOT/ssh.log" "cp -a /remote/coordinator.yaml.bak-c4a-test"

"$REPO_ROOT/scripts/activate-tier2-encrypted-leg.sh" --plan >/tmp/tier2-encrypted-leg-plan.out
assert_contains /tmp/tier2-encrypted-leg-plan.out "Plan only. No production state was changed."
assert_contains /tmp/tier2-encrypted-leg-plan.out "--b6-ready"
assert_contains /tmp/tier2-encrypted-leg-plan.out "provider_leg_encryption: all"
assert_contains /tmp/tier2-encrypted-leg-plan.out "require_encrypted_leg: true"
assert_contains /tmp/tier2-encrypted-leg-plan.out "does not enable require_attestation"

printf '[tier2-encrypted-leg-test] ok\n'

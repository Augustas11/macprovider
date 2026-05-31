#!/usr/bin/env bash
# Hermetic safety checks for scripts/enforce-tier2-hash.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_ROOT="${TMPDIR:-/tmp}/tier2-enforce-test.$$"
mkdir -p "$TMP_ROOT"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf '[tier2-enforce-test] ERROR: %s\n' "$*" >&2
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
printf '%s\n' "$1" >>"$FAKE_LOG"
case "$1" in
  --full)
    [ "${FAIL_FULL:-0}" != "1" ] || exit 9
    ;;
  --enforced)
    [ "${FAIL_ENFORCED:-0}" != "1" ] || exit 10
    ;;
  *)
    exit 2
    ;;
esac
printf '{"mode":"%s"}\n' "${1#--}"
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
    printf 'config_backup=/remote/coordinator.yaml.bak-c2-test\n'
    printf 'updated require_hash_verified=true\n'
    ;;
  *"journalctl"*)
    printf 'May 31 tier2 config reloaded provider_hash_statuses_updated=2\n'
    ;;
  *"systemctl kill -s HUP"*)
    printf 'active\n'
    ;;
  *"cp -a /remote/coordinator.yaml.bak-c2-test"*)
    printf 'rollback ok\n'
    ;;
  *)
    printf 'ok\n'
    ;;
esac
SH
  chmod +x "$TMP_ROOT/ssh"
}

run_apply() {
  FAKE_LOG="$TMP_ROOT/verify.log" \
    FAKE_SSH_LOG="$TMP_ROOT/ssh.log" \
    VERIFY_SCRIPT="$TMP_ROOT/verify" \
    SSH_BIN="$TMP_ROOT/ssh" \
    SSH_KEY="$TMP_ROOT/key" \
    DEMO_TOKEN=demo \
    OPERATOR_KEY=operator \
    "$REPO_ROOT/scripts/enforce-tier2-hash.sh" --apply
}

touch "$TMP_ROOT/key"
write_fake_verify
write_fake_ssh

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
run_apply >/tmp/tier2-enforce-success.out
assert_contains "$TMP_ROOT/verify.log" "--full"
assert_contains "$TMP_ROOT/verify.log" "--enforced"
assert_contains "$TMP_ROOT/ssh.log" "python3 - <<'PY'"
assert_contains "$TMP_ROOT/ssh.log" "systemctl kill -s HUP"
assert_contains "$TMP_ROOT/ssh.log" "journalctl"
assert_not_contains "$TMP_ROOT/ssh.log" "cp -a /remote/coordinator.yaml.bak-c2-test"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
if FAIL_FULL=1 run_apply >/tmp/tier2-enforce-full-fail.out 2>/tmp/tier2-enforce-full-fail.err; then
  fail "expected full preflight failure"
fi
assert_contains "$TMP_ROOT/verify.log" "--full"
assert_not_contains "$TMP_ROOT/ssh.log" "python3 - <<'PY'"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
if FAIL_ENFORCED=1 run_apply >/tmp/tier2-enforce-enforced-fail.out 2>/tmp/tier2-enforce-enforced-fail.err; then
  fail "expected enforced verification failure"
fi
assert_contains "$TMP_ROOT/verify.log" "--full"
assert_contains "$TMP_ROOT/verify.log" "--enforced"
assert_contains "$TMP_ROOT/ssh.log" "cp -a /remote/coordinator.yaml.bak-c2-test"

printf '[tier2-enforce-test] ok\n'

#!/usr/bin/env bash
# #1690 codex R1: the VM e2e harness must not expand a credential into a
# process argv (visible in the process list): bearer tokens go through
# `curl -H @file` (curl_bearer) and coordinator.env is loaded inside the
# child (with_coordinator_env), never `env $(grep ... | xargs)`.
set -euo pipefail
HARNESS="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Static: no bearer token interpolated into an argv, no env-file expansion.
if grep -rnE -- '-H "Authorization: Bearer \$' "$HARNESS/vm" "$HARNESS"/*.sh; then
  fail "a bearer token is expanded into curl argv"
fi
if grep -rnE 'env \$\(grep' "$HARNESS/vm" "$HARNESS"/*.sh; then
  fail "coordinator.env is expanded into an env argv"
fi

# Behavioural: curl_bearer hands curl a header file, not the token.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
eval "$(awk '/^curl_bearer\(\) [({]/{f=1} f{print} f&&/^[})]$/{exit}' "$HARNESS/vm/lib.sh")"
declare -F curl_bearer >/dev/null || fail "vm/lib.sh has no curl_bearer"
CURL_STUB_MODE=ok
curl() {
  printf '%s\n' "$@" >"$work/argv"
  local f="${1#@}"
  [ "$1" = "-H" ] && f="${2#@}"
  printf '%s\n' "$f" >"$work/header-path"
  cat "$f" >"$work/header"
  stat -f %Lp "$f" 2>/dev/null >"$work/mode" || stat -c %a "$f" >"$work/mode"
  case "$CURL_STUB_MODE" in
    fail) return 7 ;;
    term) sh -c "kill -TERM \$PPID"; sleep 5 ;;
  esac
}
token="tok-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
curl_bearer "$token" -s http://127.0.0.1:1/x
grep -q -- "$token" "$work/argv" && fail "curl_bearer put the token in curl argv"
grep -qx "Authorization: Bearer $token" "$work/header" || fail "curl_bearer header file does not carry the token"
[ "$(cat "$work/mode")" = 600 ] || fail "curl_bearer header file mode $(cat "$work/mode"), want 600"
[ ! -e "$(cat "$work/header-path")" ] || fail "curl_bearer left its header file after success"

# The header file is removed on a curl failure and on a signal too, and the
# curl status is kept.
for mode in fail term; do
  CURL_STUB_MODE=$mode
  rc=0; curl_bearer "$token" -s http://127.0.0.1:1/x || rc=$?
  [ "$rc" != 0 ] || fail "curl_bearer hid the $mode status"
  [ ! -e "$(cat "$work/header-path")" ] || fail "curl_bearer left its header file after $mode"
done
echo "PASS: VM e2e harness keeps credentials out of process argv"

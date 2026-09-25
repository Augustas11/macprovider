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
eval "$(awk '/^curl_bearer\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$HARNESS/vm/lib.sh")"
declare -F curl_bearer >/dev/null || fail "vm/lib.sh has no curl_bearer"
curl() {
  printf '%s\n' "$@" >"$work/argv"
  local f="${1#@}"
  [ "$1" = "-H" ] && f="${2#@}"
  cat "$f" >"$work/header"
  stat -f %Lp "$f" 2>/dev/null >"$work/mode" || stat -c %a "$f" >"$work/mode"
}
token="tok-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
curl_bearer "$token" -s http://127.0.0.1:1/x
grep -q -- "$token" "$work/argv" && fail "curl_bearer put the token in curl argv"
grep -qx "Authorization: Bearer $token" "$work/header" || fail "curl_bearer header file does not carry the token"
[ "$(cat "$work/mode")" = 600 ] || fail "curl_bearer header file mode $(cat "$work/mode"), want 600"
echo "PASS: VM e2e harness keeps credentials out of process argv"

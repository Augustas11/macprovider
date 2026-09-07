#!/usr/bin/env bash
# Issue #1401: MACPROVIDER_COORDINATOR_HOST is ignored by the public installer.
#
# choose_coordinator_url honors only MACPROVIDER_COORDINATOR_URL (or the
# production default / prompt). HOST is a watchdog knob. When HOST is set and
# disagrees with the chosen URL, the installer must warn and still use the URL.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$INSTALL_SH" ] || fail "missing installer: $INSTALL_SH"

python3 - "$INSTALL_SH" > "$TMP/fn.sh" <<'PY'
import sys

names = {
    "die",
    "reject_newlines",
    "choose_coordinator_url",
    "coordinator_host_from_url",
    "warn_if_coordinator_host_ignored",
    "coordinator_http_base",
    "validate_inputs",
    "usage",
}
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
i = 0
extracted = set()
while i < len(lines):
    name = lines[i].split("()", 1)[0].strip() if "()" in lines[i] else ""
    if name not in names or name in extracted:
        i += 1
        continue
    depth = 0
    while i < len(lines):
        line = lines[i]
        print(line)
        depth += line.count("{") - line.count("}")
        i += 1
        if depth == 0:
            extracted.add(name)
            break
missing = names - extracted
if missing:
    raise SystemExit(f"could not extract: {sorted(missing)}")
PY

cat > "$TMP/harness.sh" <<'HARNESS'
set -euo pipefail
COORDINATOR_URL_DEFAULT="wss://coordinator.malibu.tech/ws/provider"
COORDINATOR_BASE_DEFAULT="https://coordinator.malibu.tech"
NO_PROMPT=0
log() { printf "[macprovider-install] %s\n" "$*"; }
HARNESS
cat "$TMP/fn.sh" >> "$TMP/harness.sh"

# shellcheck disable=SC1090
source "$TMP/harness.sh"

PROD_URL="$COORDINATOR_URL_DEFAULT"
STAGING_URL="wss://127.0.0.1:18445/ws/provider"
STAGING_HOST="127.0.0.1:18445"

# 1) NO_PROMPT with no URL uses production.
NO_PROMPT=1
unset MACPROVIDER_COORDINATOR_URL || true
got="$(choose_coordinator_url)"
[ "$got" = "$PROD_URL" ] || fail "NO_PROMPT default: got [$got]"

# 2) MACPROVIDER_COORDINATOR_URL wins, including host:port.
MACPROVIDER_COORDINATOR_URL="$STAGING_URL"
got="$(choose_coordinator_url)"
[ "$got" = "$STAGING_URL" ] || fail "URL override: got [$got]"
unset MACPROVIDER_COORDINATOR_URL

# 3) Interactive empty Enter uses the production default and still shows it.
NO_PROMPT=0
read_line() { REPLY=""; }
got="$(choose_coordinator_url 2>"$TMP/prompt.err")"
[ "$got" = "$PROD_URL" ] || fail "empty prompt default: got [$got]"
grep -Fq "Coordinator URL [default: $PROD_URL]" "$TMP/prompt.err" \
  || fail "prompt must show production default"
unset -f read_line

# 4) choose_coordinator_url does not read HOST.
NO_PROMPT=1
MACPROVIDER_COORDINATOR_HOST="staging.example.test"
got="$(choose_coordinator_url)"
[ "$got" = "$PROD_URL" ] || fail "HOST must not change URL: got [$got]"

# 5) HOST mismatch warns; URL is unchanged.
warn="$(warn_if_coordinator_host_ignored "$PROD_URL")"
printf "%s\n" "$warn" | grep -Fq "WARNING: MACPROVIDER_COORDINATOR_HOST=staging.example.test is ignored by this installer" \
  || fail "missing HOST-ignored warning: [$warn]"
printf "%s\n" "$warn" | grep -Fq "Set MACPROVIDER_COORDINATOR_URL" \
  || fail "warning must name MACPROVIDER_COORDINATOR_URL: [$warn]"

# 6) Matching HOST is silent (derived watchdog host agrees).
MACPROVIDER_COORDINATOR_HOST="coordinator.malibu.tech"
warn="$(warn_if_coordinator_host_ignored "$PROD_URL")"
[ -z "$warn" ] || fail "matching HOST should be silent: [$warn]"

# 7) Empty HOST is silent.
unset MACPROVIDER_COORDINATOR_HOST
warn="$(warn_if_coordinator_host_ignored "$PROD_URL")"
[ -z "$warn" ] || fail "empty HOST should be silent: [$warn]"

# 7b) Newline in HOST cannot forge a second log line.
MACPROVIDER_COORDINATOR_HOST="$(printf 'staging.example.test\nCoordinator: wss://evil.example/ws/provider')"
warn="$(warn_if_coordinator_host_ignored "$PROD_URL")"
line_count="$(printf "%s\n" "$warn" | wc -l | tr -d ' ')"
[ "$line_count" = "1" ] || fail "newline HOST forged extra log lines: [$warn]"
printf "%s\n" "$warn" | grep -Fq "WARNING: MACPROVIDER_COORDINATOR_HOST=staging.example.test Coordinator: wss://evil.example/ws/provider is ignored" \
  || fail "newline HOST was not collapsed into one warning: [$warn]"
unset MACPROVIDER_COORDINATOR_HOST

# 8) host:port derivation matches watchdog plist grammar.
[ "$(coordinator_host_from_url "$STAGING_URL")" = "$STAGING_HOST" ] \
  || fail "host:port derivation"
[ "$(coordinator_host_from_url "$PROD_URL")" = "coordinator.malibu.tech" ] \
  || fail "production host derivation"
MACPROVIDER_COORDINATOR_HOST="$STAGING_HOST"
warn="$(warn_if_coordinator_host_ignored "$STAGING_URL")"
[ -z "$warn" ] || fail "matching staging HOST should be silent: [$warn]"
unset MACPROVIDER_COORDINATOR_HOST

# 9) HTTPS base follows a non-prod wss URL rather than falling back to prod.
[ "$(coordinator_http_base "$PROD_URL")" = "$COORDINATOR_BASE_DEFAULT" ] \
  || fail "prod http base"
[ "$(coordinator_http_base "$STAGING_URL")" = "https://127.0.0.1:18445" ] \
  || fail "staging http base"

# 10) Non-wss URL fails closed. die() calls exit, so this must be a subshell.
set +e
(
  validate_inputs "mlx-community/Qwen3-8B-4bit" "mp-test" "https://coordinator.malibu.tech"
) >"$TMP/validate.out" 2>"$TMP/validate.err"
validate_rc=$?
set -e
[ "$validate_rc" -ne 0 ] || fail "non-wss URL should die"
grep -Fq "coordinator URL must start with wss://" "$TMP/validate.err" \
  || fail "non-wss die message"

# 11) usage() names the URL override and scopes HOST as watchdog-only.
help="$(usage)"
printf "%s\n" "$help" | grep -Fq "MACPROVIDER_COORDINATOR_URL" \
  || fail "usage missing COORDINATOR_URL"
printf "%s\n" "$help" | grep -Fq "watchdog-only; ignored by this installer" \
  || fail "usage missing HOST ignored note"

echo "PASS: installer coordinator URL selection ignores MACPROVIDER_COORDINATOR_HOST"

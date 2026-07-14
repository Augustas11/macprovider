#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/node-controlled" <<'EOF'
#!/usr/bin/env bash
printf 'attempt %s\n' "$*" >>"$CANARY_TEST_ATTEMPTS"
if [[ -n "${CANARY_OPERATOR_TOKEN:-}" ]]; then
  printf 'operator-loaded\n' >>"$CANARY_TEST_OPERATOR"
fi
if [[ -r "${CANARY_EXPECTED_FLEET_FILE:-/nonexistent}" ]]; then
  printf 'fleet-loaded\n' >>"$CANARY_TEST_OPERATOR"
fi
if [[ -n "${CANARY_HEARTBEAT_URL:-}" ]]; then
  echo 'heartbeat URL leaked into probe environment' >&2
  exit 91
fi
if [[ -z "${CANARY_DISABLE_FILE:-}" ]]; then
  echo 'disable sentinel path missing from probe environment' >&2
  exit 92
fi
exit "${CANARY_TEST_NODE_EXIT:-0}"
EOF
cat >"$TMP/curl-ok" <<'EOF'
#!/usr/bin/env bash
printf 'pinged\n' >>"$CANARY_TEST_PINGS"
printf '%s\n' "$*" >>"$CANARY_TEST_CURL_ARGS"
cat >>"$CANARY_TEST_CURL_STDIN"
printf '204'
EOF
cat >"$TMP/curl-fail" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
cat >"$TMP/curl-redirect" <<'EOF'
#!/usr/bin/env bash
printf '302'
EOF
cat >"$TMP/timeout-fail" <<'EOF'
#!/usr/bin/env bash
exit 124
EOF
cat >"$TMP/timeout-pass" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CANARY_TEST_TIMEOUTS"
shift 3
exec "$@"
EOF
cat >"$TMP/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CANARY_TEST_SYSTEMCTL"
case "${1:-}" in
  is-active|is-enabled) exit 1 ;;
esac
EOF
cat >"$TMP/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CANARY_TEST_LAUNCHCTL"
[[ "${1:-}" == "print" ]] && exit 1
exit 0
EOF
cat >"$TMP/launchctl-stuck" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CANARY_TEST_LAUNCHCTL"
exit 0
EOF
chmod +x "$TMP"/*

export MACPROVIDER_BUYER_TOKEN=mp_test_token_not_secret
export CANARY_METRICS_OUT="$TMP/canary.prom"
export CANARY_JSON_OUT="$TMP/artifacts"
export CANARY_TEST_ATTEMPTS="$TMP/attempts"
export CANARY_TEST_PINGS="$TMP/pings"
export CANARY_TEST_OPERATOR="$TMP/operator"
export CANARY_TEST_SYSTEMCTL="$TMP/systemctl.log"
export CANARY_TEST_LAUNCHCTL="$TMP/launchctl.log"
export CANARY_TEST_CURL_ARGS="$TMP/curl.args"
export CANARY_TEST_CURL_STDIN="$TMP/curl.stdin"
export CANARY_TEST_TIMEOUTS="$TMP/timeouts"
export CANARY_DISABLE_FILE="$TMP/DISABLED"
export CANARY_TIMEOUT_BIN="$TMP/timeout-pass"

# Scheduled gates fail closed before credential resolution or process launch.
if env -u MACPROVIDER_BUYER_TOKEN CANARY_ENABLE_FILE="$TMP/missing-enable" \
    CANARY_NODE_BIN="$TMP/node-controlled" CANARY_CURL_BIN="$TMP/curl-ok" \
    "$HERE/run-canary.sh" >/dev/null 2>"$TMP/not-enabled.err"; then
  :
else
  echo "missing enable gate should skip safely" >&2
  exit 1
fi
grep -q 'class=not_enabled' "$TMP/not-enabled.err"
test ! -e "$CANARY_TEST_ATTEMPTS"

: >"$CANARY_DISABLE_FILE"
CANARY_NODE_BIN="$TMP/node-controlled" CANARY_CURL_BIN="$TMP/curl-ok" \
  "$HERE/run-canary.sh" >/dev/null 2>"$TMP/disabled.err"
grep -q 'class=emergency_disabled' "$TMP/disabled.err"
test ! -e "$CANARY_TEST_ATTEMPTS"
rm "$CANARY_DISABLE_FILE"

if CANARY_REQUIRE_HEARTBEAT=1 CANARY_NODE_BIN="$TMP/node-controlled" CANARY_CURL_BIN="$TMP/curl-ok" \
    "$HERE/run-canary.sh" >/dev/null 2>"$TMP/missing-heartbeat.err"; then
  echo "expected missing required heartbeat to fail" >&2
  exit 1
else
  test "$?" = 2
fi
grep -q 'CANARY_REQUIRE_HEARTBEAT=1' "$TMP/missing-heartbeat.err"

CANARY_REQUIRE_HEARTBEAT=1 CANARY_HEARTBEAT_URL=https://heartbeat.invalid/token \
  CANARY_NODE_BIN="$TMP/node-controlled" CANARY_CURL_BIN="$TMP/curl-ok" \
  "$HERE/run-canary.sh" --mode liveness >/dev/null
test "$(wc -l <"$CANARY_TEST_ATTEMPTS" | tr -d ' ')" = 1
test "$(wc -l <"$CANARY_TEST_PINGS" | tr -d ' ')" = 1
grep -q -- '--mode liveness' "$CANARY_TEST_ATTEMPTS"
grep -q -- '--signal=TERM --kill-after=5 120s' "$CANARY_TEST_TIMEOUTS"
if grep -q 'heartbeat.invalid/token' "$CANARY_TEST_CURL_ARGS"; then
  echo "heartbeat secret leaked into curl argv" >&2
  exit 1
fi
grep -q 'url = "https://heartbeat.invalid/token"' "$CANARY_TEST_CURL_STDIN"

# A degraded/failed probe is invoked exactly once and is never amplified.
if CANARY_HEARTBEAT_URL=https://heartbeat.invalid/token CANARY_TEST_NODE_EXIT=7 \
    CANARY_NODE_BIN="$TMP/node-controlled" CANARY_CURL_BIN="$TMP/curl-ok" \
    "$HERE/run-canary.sh" >/dev/null 2>"$TMP/probe-fail.err"; then
  echo "expected probe failure" >&2
  exit 1
else
  test "$?" = 7
fi
grep -q 'no retry' "$TMP/probe-fail.err"
test "$(wc -l <"$CANARY_TEST_ATTEMPTS" | tr -d ' ')" = 2
test "$(wc -l <"$CANARY_TEST_PINGS" | tr -d ' ')" = 1

# Stale retry configuration is rejected before any load is generated.
if CANARY_DEGRADED_RETRIES=1 CANARY_NODE_BIN="$TMP/node-controlled" CANARY_CURL_BIN="$TMP/curl-ok" \
    "$HERE/run-canary.sh" >/dev/null 2>"$TMP/retry-rejected.err"; then
  echo "expected automatic retry configuration to be rejected" >&2
  exit 1
else
  test "$?" = 2
fi
grep -q 'must not amplify load' "$TMP/retry-rejected.err"
test "$(wc -l <"$CANARY_TEST_ATTEMPTS" | tr -d ' ')" = 2

if CANARY_HEARTBEAT_URL=https://heartbeat.invalid/token CANARY_PROBE_TIMEOUT_SECONDS=60 \
    CANARY_TIMEOUT_BIN="$TMP/timeout-fail" CANARY_NODE_BIN="$TMP/node-controlled" CANARY_CURL_BIN="$TMP/curl-ok" \
    "$HERE/run-canary.sh" >/dev/null 2>"$TMP/timeout.err"; then
  echo "expected timeout to propagate without retry" >&2
  exit 1
else
  test "$?" = 124
fi
grep -q 'no retry' "$TMP/timeout.err"
test "$(wc -l <"$CANARY_TEST_ATTEMPTS" | tr -d ' ')" = 2

if CANARY_HEARTBEAT_URL=https://heartbeat.invalid/token CANARY_NODE_BIN="$TMP/node-controlled" \
    CANARY_CURL_BIN="$TMP/curl-fail" "$HERE/run-canary.sh" >/dev/null 2>"$TMP/ping-fail.err"; then
  echo "expected heartbeat delivery failure" >&2
  exit 1
else
  test "$?" = 3
fi
grep -q 'class=heartbeat_delivery_failed' "$TMP/ping-fail.err"

if CANARY_HEARTBEAT_URL=https://heartbeat.invalid/token CANARY_NODE_BIN="$TMP/node-controlled" \
    CANARY_CURL_BIN="$TMP/curl-redirect" "$HERE/run-canary.sh" >/dev/null 2>"$TMP/redirect.err"; then
  echo "expected heartbeat redirect failure" >&2
  exit 1
else
  test "$?" = 3
fi
grep -q 'HTTP 302' "$TMP/redirect.err"

mkdir "$TMP/credentials"
printf '%s\n' 'mp_credential_token' >"$TMP/credentials/buyer_token"
printf '%s\n' 'https://heartbeat.invalid/token' >"$TMP/credentials/heartbeat_url"
printf '%s\n' 'operator-secret-token' >"$TMP/credentials/operator_token"
printf '%s\n' '{"schema_version":1,"providers":[{"provider_id":"provider-a","model_id":"model-a"}]}' >"$TMP/credentials/expected_fleet"
env -u HOME -u MACPROVIDER_BUYER_TOKEN -u MALIBU_API_KEY -u CANARY_HEARTBEAT_URL -u CANARY_OPERATOR_TOKEN \
  CREDENTIALS_DIRECTORY="$TMP/credentials" CANARY_REQUIRE_HEARTBEAT=1 \
  CANARY_DISABLE_FILE="$TMP/credential-disabled" CANARY_NODE_BIN="$TMP/node-controlled" CANARY_CURL_BIN="$TMP/curl-ok" \
  "$HERE/run-canary.sh" >/dev/null
grep -q 'operator-loaded' "$CANARY_TEST_OPERATOR"
grep -q 'fleet-loaded' "$CANARY_TEST_OPERATOR"

# The documented installed layout is complete: probe.mjs can resolve its
# sibling safety module and emergency command when only service-installed files exist.
mkdir "$TMP/installed-layout"
cp "$HERE/probe.mjs" "$HERE/safety.mjs" "$HERE/run-canary.sh" "$HERE/emergency-disable.sh" "$TMP/installed-layout/"
if node "$TMP/installed-layout/probe.mjs" >/dev/null 2>"$TMP/layout.err"; then
  echo "layout smoke unexpectedly passed without required configuration" >&2
  exit 1
else
  test "$?" = 2
fi
grep -q 'liveness requires' "$TMP/layout.err"
if grep -q 'ERR_MODULE_NOT_FOUND' "$TMP/layout.err"; then
  echo "installed layout omitted a runtime module" >&2
  exit 1
fi
test -x "$TMP/installed-layout/emergency-disable.sh"

# Per-user fallback credentials fail closed on symlinks or broad permissions.
mkdir "$TMP/user-files"
printf '%s\n' 'operator-secret-token' >"$TMP/user-files/operator"
chmod 0644 "$TMP/user-files/operator"
if CANARY_OPERATOR_TOKEN='' CANARY_OPERATOR_TOKEN_FILE="$TMP/user-files/operator" \
    CANARY_NODE_BIN="$TMP/node-controlled" CANARY_CURL_BIN="$TMP/curl-ok" \
    "$HERE/run-canary.sh" >/dev/null 2>"$TMP/broad-mode.err"; then
  echo "broad-mode credential should be rejected" >&2
  exit 1
fi
grep -q 'mode 0400 or 0600' "$TMP/broad-mode.err"
chmod 0600 "$TMP/user-files/operator"
ln -s "$TMP/user-files/operator" "$TMP/user-files/operator-link"
if CANARY_OPERATOR_TOKEN='' CANARY_OPERATOR_TOKEN_FILE="$TMP/user-files/operator-link" \
    CANARY_NODE_BIN="$TMP/node-controlled" CANARY_CURL_BIN="$TMP/curl-ok" \
    "$HERE/run-canary.sh" >/dev/null 2>"$TMP/symlink.err"; then
  echo "symlinked credential should be rejected" >&2
  exit 1
fi
grep -q 'not a symlink' "$TMP/symlink.err"

# The emergency command removes the enable gate, creates the pre-network
# sentinel, and stops the systemd timer in one invocation.
: >"$TMP/enabled"
CANARY_DISABLE_FILE="$TMP/emergency/DISABLED" CANARY_ENABLE_FILE="$TMP/enabled" \
  CANARY_SYSTEMCTL_BIN="$TMP/systemctl" CANARY_LAUNCHCTL_BIN="$TMP/launchctl" \
  CANARY_TARGET_USER="$(id -un)" CANARY_TARGET_UID="$(id -u)" CANARY_TARGET_HOME="$TMP" \
  "$HERE/emergency-disable.sh" >/dev/null
test -e "$TMP/emergency/DISABLED"
test ! -e "$TMP/enabled"
grep -q '^disable --now canary-buyer.timer$' "$CANARY_TEST_SYSTEMCTL"
grep -q '^stop canary-buyer.service$' "$CANARY_TEST_SYSTEMCTL"
grep -q '^is-active --quiet canary-buyer.service$' "$CANARY_TEST_SYSTEMCTL"

# The macOS emergency path unloads the exact per-user LaunchAgent label and
# verifies that launchd no longer reports it. This runs on Linux with only the
# platform probe injected; the production command path stays unchanged.
: >"$TMP/darwin-enabled"
: >"$CANARY_TEST_LAUNCHCTL"
CANARY_TEST_PLATFORM=Darwin \
  CANARY_DISABLE_FILE="$TMP/darwin-emergency/DISABLED" CANARY_ENABLE_FILE="$TMP/darwin-enabled" \
  CANARY_SYSTEMCTL_BIN="$TMP/systemctl" CANARY_LAUNCHCTL_BIN="$TMP/launchctl" \
  CANARY_TARGET_USER="$(id -un)" CANARY_TARGET_UID="$(id -u)" CANARY_TARGET_HOME="$TMP" \
  bash -c 'source "$1"' _ "$HERE/emergency-disable.sh" >/dev/null
test -e "$TMP/darwin-emergency/DISABLED"
test ! -e "$TMP/darwin-enabled"
grep -q "^bootout gui/$(id -u)/com.streamvc.canary-buyer$" "$CANARY_TEST_LAUNCHCTL"
grep -q "^print gui/$(id -u)/com.streamvc.canary-buyer$" "$CANARY_TEST_LAUNCHCTL"

# A scheduler that remains loaded makes the command fail, but the fail-closed
# sentinel must already be present so no subsequent invocation can add load.
: >"$TMP/darwin-stuck-enabled"
: >"$CANARY_TEST_LAUNCHCTL"
if CANARY_TEST_PLATFORM=Darwin \
    CANARY_DISABLE_FILE="$TMP/darwin-stuck/DISABLED" CANARY_ENABLE_FILE="$TMP/darwin-stuck-enabled" \
    CANARY_SYSTEMCTL_BIN="$TMP/systemctl" CANARY_LAUNCHCTL_BIN="$TMP/launchctl-stuck" \
    CANARY_TARGET_USER="$(id -un)" CANARY_TARGET_UID="$(id -u)" CANARY_TARGET_HOME="$TMP" \
    bash -c 'source "$1"' _ "$HERE/emergency-disable.sh" >/dev/null 2>"$TMP/darwin-stuck.err"; then
  echo "launchd verification should fail while the agent remains loaded" >&2
  exit 1
else
  test "$?" = 1
fi
test -e "$TMP/darwin-stuck/DISABLED"
test ! -e "$TMP/darwin-stuck-enabled"
grep -q 'class=emergency_disable_failed launchd agent remains loaded' "$TMP/darwin-stuck.err"

echo 'PASS: canary wrapper issues one bounded attempt, honors kill switches, and never amplifies degradation'

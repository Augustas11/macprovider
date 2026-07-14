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
exit "${CANARY_TEST_NODE_EXIT:-0}"
EOF
cat >"$TMP/curl-ok" <<'EOF'
#!/usr/bin/env bash
printf 'pinged\n' >>"$CANARY_TEST_PINGS"
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
cat >"$TMP/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CANARY_TEST_SYSTEMCTL"
EOF
chmod +x "$TMP"/*

export MACPROVIDER_BUYER_TOKEN=mp_test_token_not_secret
export CANARY_METRICS_OUT="$TMP/canary.prom"
export CANARY_JSON_OUT="$TMP/artifacts"
export CANARY_TEST_ATTEMPTS="$TMP/attempts"
export CANARY_TEST_PINGS="$TMP/pings"
export CANARY_TEST_OPERATOR="$TMP/operator"
export CANARY_TEST_SYSTEMCTL="$TMP/systemctl.log"
export CANARY_DISABLE_FILE="$TMP/DISABLED"

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
env -u HOME -u MACPROVIDER_BUYER_TOKEN -u MALIBU_API_KEY -u CANARY_HEARTBEAT_URL -u CANARY_OPERATOR_TOKEN \
  CREDENTIALS_DIRECTORY="$TMP/credentials" CANARY_REQUIRE_HEARTBEAT=1 \
  CANARY_DISABLE_FILE="$TMP/credential-disabled" CANARY_NODE_BIN="$TMP/node-controlled" CANARY_CURL_BIN="$TMP/curl-ok" \
  "$HERE/run-canary.sh" >/dev/null
grep -q 'operator-loaded' "$CANARY_TEST_OPERATOR"

# The emergency command removes the enable gate, creates the pre-network
# sentinel, and stops the systemd timer in one invocation.
: >"$TMP/enabled"
CANARY_DISABLE_FILE="$TMP/emergency/DISABLED" CANARY_ENABLE_FILE="$TMP/enabled" \
  CANARY_SYSTEMCTL_BIN="$TMP/systemctl" "$HERE/emergency-disable.sh" >/dev/null
test -e "$TMP/emergency/DISABLED"
test ! -e "$TMP/enabled"
grep -q '^disable --now canary-buyer.timer$' "$CANARY_TEST_SYSTEMCTL"

echo 'PASS: canary wrapper issues one bounded attempt, honors kill switches, and never amplifies degradation'

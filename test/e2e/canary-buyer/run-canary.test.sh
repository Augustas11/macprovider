#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/node-ok" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$TMP/node-fail" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
cat >"$TMP/node-flaky" <<'EOF'
#!/usr/bin/env bash
if [[ ! -e "$CANARY_TEST_FLAKY_MARKER" ]]; then
  : >"$CANARY_TEST_FLAKY_MARKER"
  exit 7
fi
exit 0
EOF
cat >"$TMP/node-count-fail" <<'EOF'
#!/usr/bin/env bash
printf 'attempt\n' >>"$CANARY_TEST_ATTEMPT_MARKER"
exit 7
EOF
cat >"$TMP/timeout-flaky" <<'EOF'
#!/usr/bin/env bash
shift 3
if [[ ! -e "$CANARY_TEST_TIMEOUT_MARKER" ]]; then
  : >"$CANARY_TEST_TIMEOUT_MARKER"
  exit 124
fi
exec "$@"
EOF
cat >"$TMP/curl-ok" <<'EOF'
#!/usr/bin/env bash
printf 'pinged\n' >>"$CANARY_TEST_MARKER"
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
chmod +x "$TMP"/*

export MACPROVIDER_BUYER_TOKEN=mp_test_token_not_secret
export CANARY_METRICS_OUT="$TMP/canary.prom"
export CANARY_JSON_OUT="$TMP/artifacts"
export CANARY_TEST_MARKER="$TMP/pings"
export CANARY_TEST_FLAKY_MARKER="$TMP/flaky"
export CANARY_TEST_ATTEMPT_MARKER="$TMP/attempts"
export CANARY_TEST_TIMEOUT_MARKER="$TMP/timeout"

if CANARY_REQUIRE_HEARTBEAT=1 CANARY_NODE_BIN="$TMP/node-ok" CANARY_CURL_BIN="$TMP/curl-ok" \
    "$HERE/run-canary.sh" >/dev/null 2>"$TMP/missing.err"; then
  echo "expected missing required heartbeat to fail" >&2
  exit 1
fi
grep -q 'CANARY_REQUIRE_HEARTBEAT=1' "$TMP/missing.err"

CANARY_REQUIRE_HEARTBEAT=1 CANARY_HEARTBEAT_URL=https://heartbeat.invalid/token \
  CANARY_NODE_BIN="$TMP/node-ok" CANARY_CURL_BIN="$TMP/curl-ok" \
  "$HERE/run-canary.sh" >/dev/null
test "$(wc -l <"$TMP/pings" | tr -d ' ')" = 1

if CANARY_HEARTBEAT_URL=https://heartbeat.invalid/token CANARY_NODE_BIN="$TMP/node-ok" \
    CANARY_CURL_BIN="$TMP/curl-fail" "$HERE/run-canary.sh" >/dev/null 2>"$TMP/ping-fail.err"; then
  echo "expected heartbeat delivery failure to fail" >&2
  exit 1
else
  test "$?" = 3
fi
grep -q 'heartbeat ping failed' "$TMP/ping-fail.err"

if CANARY_HEARTBEAT_URL=https://heartbeat.invalid/token CANARY_NODE_BIN="$TMP/node-ok" \
    CANARY_CURL_BIN="$TMP/curl-redirect" "$HERE/run-canary.sh" >/dev/null 2>"$TMP/redirect.err"; then
  echo "expected heartbeat redirect to fail" >&2
  exit 1
else
  test "$?" = 3
fi
grep -q 'heartbeat returned HTTP 302' "$TMP/redirect.err"

if CANARY_HEARTBEAT_URL=https://heartbeat.invalid/token CANARY_NODE_BIN="$TMP/node-fail" \
    CANARY_CURL_BIN="$TMP/curl-ok" "$HERE/run-canary.sh" >/dev/null 2>"$TMP/probe-fail.err"; then
  echo "expected degraded probe to fail" >&2
  exit 1
else
  test "$?" = 7
fi
test "$(wc -l <"$TMP/pings" | tr -d ' ')" = 1

CANARY_REQUIRE_HEARTBEAT=1 CANARY_HEARTBEAT_URL=https://heartbeat.invalid/token \
  CANARY_DEGRADED_RETRIES=1 CANARY_RETRY_DELAY_SECONDS=0 \
  CANARY_NODE_BIN="$TMP/node-flaky" CANARY_CURL_BIN="$TMP/curl-ok" \
  "$HERE/run-canary.sh" >/dev/null 2>"$TMP/retry.err"
grep -q 'retrying full probe' "$TMP/retry.err"
test "$(wc -l <"$TMP/pings" | tr -d ' ')" = 2

if CANARY_REQUIRE_HEARTBEAT=1 CANARY_HEARTBEAT_URL=https://heartbeat.invalid/token \
    CANARY_DEGRADED_RETRIES=1 CANARY_RETRY_DELAY_SECONDS=0 \
    CANARY_NODE_BIN="$TMP/node-count-fail" CANARY_CURL_BIN="$TMP/curl-ok" \
    "$HERE/run-canary.sh" >/dev/null 2>"$TMP/retry-fail.err"; then
  echo "expected both strict probe attempts to fail" >&2
  exit 1
else
  test "$?" = 7
fi
test "$(wc -l <"$TMP/attempts" | tr -d ' ')" = 2

CANARY_REQUIRE_HEARTBEAT=1 CANARY_HEARTBEAT_URL=https://heartbeat.invalid/token \
  CANARY_DEGRADED_RETRIES=1 CANARY_RETRY_DELAY_SECONDS=0 \
  CANARY_PROBE_TIMEOUT_SECONDS=60 CANARY_TIMEOUT_BIN="$TMP/timeout-flaky" \
  CANARY_NODE_BIN="$TMP/node-ok" CANARY_CURL_BIN="$TMP/curl-ok" \
  "$HERE/run-canary.sh" >/dev/null 2>"$TMP/timeout-retry.err"
grep -q 'probe exited 124; retrying full probe' "$TMP/timeout-retry.err"
test "$(wc -l <"$TMP/pings" | tr -d ' ')" = 3

rm -f "$CANARY_TEST_TIMEOUT_MARKER"
if env -u CANARY_HEARTBEAT_URL CANARY_PROBE_TIMEOUT_SECONDS=60 \
    CANARY_TIMEOUT_BIN="$TMP/timeout-flaky" CANARY_NODE_BIN="$TMP/node-ok" \
    CANARY_CURL_BIN="$TMP/curl-ok" "$HERE/run-canary.sh" >/dev/null 2>"$TMP/no-heartbeat-timeout.err"; then
  echo "expected measurement-only probe timeout to propagate" >&2
  exit 1
else
  test "$?" = 124
fi
test "$(wc -l <"$TMP/pings" | tr -d ' ')" = 3

if CANARY_REQUIRE_HEARTBEAT=1 CANARY_HEARTBEAT_URL=https://heartbeat.invalid/token \
    CANARY_DEGRADED_RETRIES=08 CANARY_RETRY_DELAY_SECONDS=0 \
    CANARY_NODE_BIN="$TMP/node-count-fail" CANARY_CURL_BIN="$TMP/curl-ok" \
    "$HERE/run-canary.sh" >/dev/null 2>"$TMP/invalid-retries.err"; then
  echo "expected leading-zero retry count to fail validation" >&2
  exit 1
else
  test "$?" = 2
fi
grep -q 'without leading zeros' "$TMP/invalid-retries.err"
test "$(wc -l <"$TMP/attempts" | tr -d ' ')" = 2

for bad_retries in 9223372036854775808 18446744073709551616; do
  if CANARY_REQUIRE_HEARTBEAT=1 CANARY_HEARTBEAT_URL=https://heartbeat.invalid/token \
      CANARY_DEGRADED_RETRIES="$bad_retries" CANARY_RETRY_DELAY_SECONDS=0 \
      CANARY_NODE_BIN="$TMP/node-count-fail" CANARY_CURL_BIN="$TMP/curl-ok" \
      "$HERE/run-canary.sh" >/dev/null 2>"$TMP/huge-retries.err"; then
    echo "expected huge retry count to fail validation" >&2
    exit 1
  else
    test "$?" = 2
  fi
done
if CANARY_REQUIRE_HEARTBEAT=1 CANARY_HEARTBEAT_URL=https://heartbeat.invalid/token \
    CANARY_DEGRADED_RETRIES=0 CANARY_RETRY_DELAY_SECONDS=18446744073709551616 \
    CANARY_NODE_BIN="$TMP/node-count-fail" CANARY_CURL_BIN="$TMP/curl-ok" \
    "$HERE/run-canary.sh" >/dev/null 2>"$TMP/huge-delay.err"; then
  echo "expected huge retry delay to fail validation" >&2
  exit 1
else
  test "$?" = 2
fi
test "$(wc -l <"$TMP/attempts" | tr -d ' ')" = 2

mkdir "$TMP/credentials"
printf '%s\n' 'mp_credential_token' >"$TMP/credentials/buyer_token"
printf '%s\n' 'https://heartbeat.invalid/token' >"$TMP/credentials/heartbeat_url"
env -u HOME -u MACPROVIDER_BUYER_TOKEN -u MALIBU_API_KEY -u CANARY_HEARTBEAT_URL \
  CREDENTIALS_DIRECTORY="$TMP/credentials" CANARY_REQUIRE_HEARTBEAT=1 \
  CANARY_NODE_BIN="$TMP/node-ok" CANARY_CURL_BIN="$TMP/curl-ok" \
  "$HERE/run-canary.sh" >/dev/null
test "$(wc -l <"$TMP/pings" | tr -d ' ')" = 4

echo 'PASS: canary wrapper requires and delivers heartbeat only after a healthy probe'

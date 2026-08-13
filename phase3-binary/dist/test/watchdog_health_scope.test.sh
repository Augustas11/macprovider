#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WATCHDOG="$REPO_ROOT/ops/macprovider-watchdog/watchdog.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_fake_common() {
  mkdir -p "$TMP/bin" "$TMP/home/.config/macprovider" "$TMP/logs"
  cat > "$TMP/home/.config/macprovider/config.yaml" <<'EOF'
provider_id: provider-test
port: 18080
EOF
  cat > "$TMP/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$WATCHDOG_TEST_LAUNCHCTL_LOG"
case "$*" in
  print*)
    if [ -n "${WATCHDOG_TEST_SERVICE_OUTPUT:-}" ]; then
      printf '%b' "$WATCHDOG_TEST_SERVICE_OUTPUT"
      exit 0
    fi
    if [ -n "${WATCHDOG_TEST_SERVICE_PID:-}" ]; then
      printf 'pid = %s\n' "$WATCHDOG_TEST_SERVICE_PID"
      exit 0
    fi
    exit 113
    ;;
  kickstart*)
    exit "${WATCHDOG_TEST_KICKSTART_STATUS:-0}"
    ;;
esac
EOF
  cat > "$TMP/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
echo boot-a
EOF
  chmod +x "$TMP/bin/launchctl"
  chmod +x "$TMP/bin/sysctl"
}

run_watchdog() {
  HOME="$TMP/home" \
  PATH="$TMP/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  MACPROVIDER_LOG_DIR="$TMP/logs" \
  MACPROVIDER_BINARY_PATH="$TMP/home/macprovider/macprovider-cli" \
  MACPROVIDER_CURL="$TMP/bin/curl" \
  WATCHDOG_TEST_LAUNCHCTL_LOG="$TMP/launchctl.log" \
  WATCHDOG_TEST_SERVICE_PID="${WATCHDOG_TEST_SERVICE_PID:-}" \
  WATCHDOG_TEST_SERVICE_OUTPUT="${WATCHDOG_TEST_SERVICE_OUTPUT:-}" \
  WATCHDOG_TEST_KICKSTART_STATUS="${WATCHDOG_TEST_KICKSTART_STATUS:-0}" \
  WATCHDOG_TEST_HEALTH_STATUS="${WATCHDOG_TEST_HEALTH_STATUS:-0}" \
  WATCHDOG_TEST_STATUS_BODY="${WATCHDOG_TEST_STATUS_BODY:-}" \
  WATCHDOG_TEST_STATUS_EXIT="${WATCHDOG_TEST_STATUS_EXIT:-0}" \
  WATCHDOG_TEST_LEASE_MODE="${WATCHDOG_TEST_LEASE_MODE:-}" \
  WATCHDOG_TEST_LEASE_LOG="${WATCHDOG_TEST_LEASE_LOG:-$TMP/lease.log}" \
  MACPROVIDER_WATCHDOG_KICK_GRACE_SECONDS="${MACPROVIDER_WATCHDOG_KICK_GRACE_SECONDS:-}" \
  bash "$WATCHDOG"
}

make_fake_common
: > "$TMP/launchctl.log"
run_watchdog
grep -F 'kickstart -k gui/' "$TMP/launchctl.log" >/dev/null
grep -F 'provider restart requested for live.streamvc.macprovider via launchctl kickstart -k reason=missing_validated_pid' "$TMP/logs/watchdog.log" >/dev/null

rm -rf "$TMP/bin" "$TMP/logs" "$TMP/launchctl.log" "$TMP/home/.local/share/macprovider-watchdog/state"
make_fake_common
WATCHDOG_TEST_KICKSTART_STATUS=73
export WATCHDOG_TEST_KICKSTART_STATUS
: > "$TMP/launchctl.log"
run_watchdog
grep -F 'provider restart request failed for live.streamvc.macprovider via launchctl kickstart -k reason=missing_validated_pid exit_status=73' "$TMP/logs/watchdog.log" >/dev/null
if [ -f "$TMP/home/.local/share/macprovider-watchdog/state/last_kick" ]; then
  echo "failed kickstart must not consume restart cooldown" >&2
  exit 1
fi
unset WATCHDOG_TEST_KICKSTART_STATUS

rm -rf "$TMP/bin" "$TMP/logs" "$TMP/launchctl.log" "$TMP/home/.local/share/macprovider-watchdog/state"
make_fake_common
MACPROVIDER_WATCHDOG_KICK_GRACE_SECONDS=nonnumeric
export MACPROVIDER_WATCHDOG_KICK_GRACE_SECONDS
: > "$TMP/launchctl.log"
run_watchdog
run_watchdog
if [ "$(grep -c -F 'kickstart -k gui/' "$TMP/launchctl.log")" -ne 1 ]; then
  echo "invalid cooldown override must fall back to bounded default" >&2
  exit 1
fi
unset MACPROVIDER_WATCHDOG_KICK_GRACE_SECONDS

rm -rf "$TMP/bin" "$TMP/logs" "$TMP/launchctl.log" "$TMP/home/.local/share/macprovider-watchdog/state"
make_fake_common
mkdir -p "$TMP/home/macprovider"
cat > "$TMP/home/macprovider/macprovider-cli" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$WATCHDOG_TEST_LEASE_LOG"
case "$WATCHDOG_TEST_LEASE_MODE:$*" in
  'startup:lifecycle-lease status --expected-kind startup') exit 0 ;;
  'maintenance:lifecycle-lease status --expected-kind maintenance') exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/home/macprovider/macprovider-cli"
WATCHDOG_TEST_LEASE_LOG="$TMP/lease.log"
export WATCHDOG_TEST_LEASE_LOG
for lease_mode in startup maintenance; do
  : > "$TMP/logs/watchdog.log"
  : > "$TMP/launchctl.log"
  : > "$TMP/lease.log"
  WATCHDOG_TEST_LEASE_MODE="$lease_mode"
  export WATCHDOG_TEST_LEASE_MODE
  run_watchdog
  grep -F 'has no validated PID but is inside a validated startup/maintenance lease; watchdog grants bounded grace' "$TMP/logs/watchdog.log" >/dev/null
  grep -Fx "lifecycle-lease status --expected-kind $lease_mode" "$TMP/lease.log" >/dev/null
  if grep -F 'kickstart -k' "$TMP/launchctl.log" >/dev/null; then
    echo "valid $lease_mode lease must suppress missing-PID kickstart" >&2
    exit 1
  fi
done
unset WATCHDOG_TEST_LEASE_LOG WATCHDOG_TEST_LEASE_MODE

rm -rf "$TMP/bin" "$TMP/logs" "$TMP/launchctl.log" "$TMP/home/.local/share/macprovider-watchdog/state"
make_fake_common
mkdir -p "$TMP/home/macprovider"
cat > "$TMP/home/macprovider/macprovider-cli" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  'lifecycle-lease status --expected-kind startup --expected-pid 4242') exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/home/macprovider/macprovider-cli"
cat > "$TMP/bin/ps" <<EOF
#!/usr/bin/env bash
echo "$TMP/home/macprovider/macprovider-cli --port 18080"
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *127.0.0.1:18080/v1/health*) exit "$WATCHDOG_TEST_HEALTH_STATUS" ;;
  *127.0.0.1:18080/v1/status*)
    if [ "$WATCHDOG_TEST_STATUS_EXIT" -ne 0 ]; then
      exit "$WATCHDOG_TEST_STATUS_EXIT"
    fi
    printf '%s\n' "$WATCHDOG_TEST_STATUS_BODY"
    ;;
  *) exit 7 ;;
esac
EOF
cat > "$TMP/bin/lsof" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'-d txt -Fn'*)
    printf 'n%s\n' "/usr/lib/dyld"
    printf 'n%s\n' "$HOME/macprovider/macprovider-cli"
    printf 'n%s\n' "$HOME/Library/Application Support/macprovider/provider.sqlite-shm"
    ;;
  *) echo 4242 ;;
esac
EOF
cat > "$TMP/bin/dscacheutil" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$TMP/bin/host" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/bin/"*
: > "$TMP/launchctl.log"
WATCHDOG_TEST_SERVICE_PID=4242
export WATCHDOG_TEST_SERVICE_PID
run_watchdog
if grep -F 'kickstart -k' "$TMP/launchctl.log" >/dev/null; then
  echo "coordinator reachability warning must not kick a locally healthy provider" >&2
  exit 1
fi
grep -F 'boot-a' "$TMP/home/.local/share/macprovider-watchdog/state/armed" >/dev/null

# A read-only diagnostic from the same executable must not change the exact
# launchd PID verdict.
cat > "$TMP/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
printf '4242\n7777\n'
EOF
chmod +x "$TMP/bin/pgrep"
run_watchdog
grep -F 'boot-a' "$TMP/home/.local/share/macprovider-watchdog/state/armed" >/dev/null

# Ambiguous launchd output must fail closed instead of choosing the first PID.
WATCHDOG_TEST_SERVICE_OUTPUT=$'pid = 4242\npid = 7777\n'
export WATCHDOG_TEST_SERVICE_OUTPUT
run_watchdog
grep -F 'has no validated PID' "$TMP/logs/watchdog.log" >/dev/null
unset WATCHDOG_TEST_SERVICE_OUTPUT

cat > "$TMP/home/macprovider/macprovider-cli" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/home/macprovider/macprovider-cli"
rm -f "$TMP/home/.local/share/macprovider-watchdog/state/last_kick"
WATCHDOG_TEST_HEALTH_STATUS=22
export WATCHDOG_TEST_HEALTH_STATUS
for status_body in \
  '{"status":"unavailable","lifecycle":{"operator_paused":true,"state":"paused_by_operator"}}' \
  '{"status":"draining","lifecycle":{"operator_paused":false,"state":"serving_buyers"}}' \
  '{"status":"degraded","lifecycle":{"operator_paused":false,"state":"serving_buyers"}}'
do
  : > "$TMP/logs/watchdog.log"
  : > "$TMP/launchctl.log"
  WATCHDOG_TEST_STATUS_BODY="$status_body"
  export WATCHDOG_TEST_STATUS_BODY
  run_watchdog
  grep -F 'failed local /v1/health after arming, but /v1/status does not recommend watchdog restart' "$TMP/logs/watchdog.log" >/dev/null
  if grep -F 'kickstart -k' "$TMP/launchctl.log" >/dev/null; then
    echo "paused, draining, and degraded states must not trigger watchdog kickstart" >&2
    exit 1
  fi
done

for status_body in \
  'not-json' \
  '{"status":"unavailable"}' \
  '{"status":"unavailable","lifecycle":null}' \
  '{"status":"unavailable","lifecycle":"bad"}' \
  '{"status":"unavailable","lifecycle":{"state":"serving_buyers"}}'
do
  : > "$TMP/logs/watchdog.log"
  : > "$TMP/launchctl.log"
  WATCHDOG_TEST_STATUS_BODY="$status_body"
  WATCHDOG_TEST_STATUS_EXIT=0
  export WATCHDOG_TEST_STATUS_BODY WATCHDOG_TEST_STATUS_EXIT
  run_watchdog
  grep -F 'failed local /v1/health after arming, but /v1/status does not recommend watchdog restart' "$TMP/logs/watchdog.log" >/dev/null
  if grep -F 'kickstart -k' "$TMP/launchctl.log" >/dev/null; then
    echo "malformed or incomplete /v1/status must not trigger watchdog kickstart" >&2
    exit 1
  fi
done

: > "$TMP/logs/watchdog.log"
: > "$TMP/launchctl.log"
WATCHDOG_TEST_STATUS_BODY='{"status":"unavailable","lifecycle":{"operator_paused":false,"state":"serving_buyers"}}'
WATCHDOG_TEST_STATUS_EXIT=71
export WATCHDOG_TEST_STATUS_BODY WATCHDOG_TEST_STATUS_EXIT
run_watchdog
grep -F 'failed local /v1/health after arming, but /v1/status does not recommend watchdog restart' "$TMP/logs/watchdog.log" >/dev/null
if grep -F 'kickstart -k' "$TMP/launchctl.log" >/dev/null; then
  echo "failed /v1/status fetch must not trigger watchdog kickstart" >&2
  exit 1
fi
unset WATCHDOG_TEST_STATUS_EXIT

: > "$TMP/logs/watchdog.log"
: > "$TMP/launchctl.log"
WATCHDOG_TEST_STATUS_BODY='{"status":"unavailable","lifecycle":{"operator_paused":false,"state":"serving_buyers"}}'
export WATCHDOG_TEST_STATUS_BODY
run_watchdog
grep -F 'provider process 4242 failed local /v1/health after arming; requesting launchd restart' "$TMP/logs/watchdog.log" >/dev/null
grep -F 'provider restart requested for live.streamvc.macprovider via launchctl kickstart -k reason=local_health_failed_after_arming' "$TMP/logs/watchdog.log" >/dev/null
unset WATCHDOG_TEST_HEALTH_STATUS WATCHDOG_TEST_STATUS_BODY

rm -rf "$TMP/bin" "$TMP/logs" "$TMP/launchctl.log" "$TMP/home/.local/share/macprovider-watchdog/state"
make_fake_common
mkdir -p "$TMP/home/macprovider"
cat > "$TMP/home/macprovider/macprovider-cli" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$WATCHDOG_TEST_LEASE_LOG"
case "$WATCHDOG_TEST_LEASE_MODE:$*" in
  'startup:lifecycle-lease status --expected-kind startup --expected-pid 4242') exit 0 ;;
  'maintenance:lifecycle-lease status --expected-kind maintenance') exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/home/macprovider/macprovider-cli"
cat > "$TMP/bin/ps" <<EOF
#!/usr/bin/env bash
echo "$TMP/home/macprovider/macprovider-cli --port 18080"
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP/bin/lsof" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'-d txt -Fn'*)
    printf 'n%s\n' "/usr/lib/dyld"
    printf 'n%s\n' "$HOME/macprovider/macprovider-cli"
    ;;
  *) echo 9999 ;;
esac
EOF
chmod +x "$TMP/bin/"*
mkdir -p "$TMP/home/.local/share/macprovider-watchdog/state"
printf "boot-a" > "$TMP/home/.local/share/macprovider-watchdog/state/armed"
: > "$TMP/launchctl.log"
: > "$TMP/lease.log"
WATCHDOG_TEST_LEASE_LOG="$TMP/lease.log"
WATCHDOG_TEST_LEASE_MODE=startup
export WATCHDOG_TEST_LEASE_LOG WATCHDOG_TEST_LEASE_MODE
run_watchdog
grep -F 'inside a validated startup/maintenance lease; watchdog grants bounded grace' "$TMP/logs/watchdog.log" >/dev/null
grep -Fx 'lifecycle-lease status --expected-kind startup --expected-pid 4242' "$TMP/lease.log" >/dev/null
if grep -F -- '--expected-kind maintenance' "$TMP/lease.log" >/dev/null; then
  echo "exact startup lease must not fall through to maintenance validation" >&2
  exit 1
fi
if grep -F 'provider process 4242 failed local /v1/health after arming' "$TMP/logs/watchdog.log" >/dev/null; then
  echo "valid lifecycle lease must suppress the unhealthy action path" >&2
  exit 1
fi

for lease_mode in maintenance stale forged; do
  : > "$TMP/logs/watchdog.log"
  : > "$TMP/lease.log"
  rm -f "$TMP/home/.local/share/macprovider-watchdog/state/last_kick"
  WATCHDOG_TEST_LEASE_MODE="$lease_mode"
  export WATCHDOG_TEST_LEASE_MODE
  run_watchdog

  grep -Fx 'lifecycle-lease status --expected-kind startup --expected-pid 4242' "$TMP/lease.log" >/dev/null
  grep -Fx 'lifecycle-lease status --expected-kind maintenance' "$TMP/lease.log" >/dev/null
  if grep -F -- '--expected-kind maintenance' "$TMP/lease.log" | grep -F -- '--expected-pid' >/dev/null; then
    echo "maintenance validation must trust the CLI lease store owner tuple instead of forcing provider PID" >&2
    exit 1
  fi

  if [ "$lease_mode" = maintenance ]; then
    grep -F 'inside a validated startup/maintenance lease; watchdog grants bounded grace' "$TMP/logs/watchdog.log" >/dev/null
    if grep -F 'provider process 4242 failed local /v1/health after arming' "$TMP/logs/watchdog.log" >/dev/null; then
      echo "valid maintenance lease must suppress the unhealthy action path" >&2
      exit 1
    fi
  else
    if grep -F 'inside a validated startup/maintenance lease; watchdog grants bounded grace' "$TMP/logs/watchdog.log" >/dev/null; then
      echo "$lease_mode lifecycle lease must fail closed" >&2
      exit 1
    fi
    grep -F 'provider process 4242 failed local /v1/health after arming; requesting launchd restart' "$TMP/logs/watchdog.log" >/dev/null
    grep -F 'provider restart requested for live.streamvc.macprovider via launchctl kickstart -k reason=local_health_failed_after_arming' "$TMP/logs/watchdog.log" >/dev/null
  fi
done

if [ "$(grep -c -F 'kickstart -k gui/' "$TMP/launchctl.log")" -ne 2 ]; then
  echo "watchdog must kick exactly the stale and forged unhealthy providers" >&2
  exit 1
fi

echo "watchdog health scope ok"

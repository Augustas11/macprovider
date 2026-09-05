#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WATCHDOG="$REPO_ROOT/ops/macprovider-watchdog/watchdog.sh"
TMP="$(mktemp -d)"
provider_owner_pid=""
forged_owner_pid=""
cleanup() {
  if [ -n "$provider_owner_pid" ]; then
    kill "$provider_owner_pid" >/dev/null 2>&1 || true
    wait "$provider_owner_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "$forged_owner_pid" ]; then
    kill "$forged_owner_pid" >/dev/null 2>&1 || true
    wait "$forged_owner_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

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
  MACPROVIDER_BINARY_PATH="${WATCHDOG_TEST_BINARY_PATH:-$TMP/home/macprovider/macprovider-cli}" \
  MACPROVIDER_LIFECYCLE_LEASE_PATH="$TMP/home/Library/Application Support/macprovider/lifecycle/lease.json" \
  MACPROVIDER_LIFECYCLE_LEASE_OWNER_UID="$(id -u)" \
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
  MACPROVIDER_HEADLESS="${MACPROVIDER_HEADLESS:-0}" \
  MACPROVIDER_WATCHDOG_KICK_GRACE_SECONDS="${MACPROVIDER_WATCHDOG_KICK_GRACE_SECONDS:-}" \
  bash "$WATCHDOG"
}

write_watchdog_lease() {
  kind="$1"
  owner_pid="$2"
  window="${3:-valid}"
  owner_start_override="${4:-}"
  mkdir -p "$TMP/home/Library/Application Support/macprovider/lifecycle"
  chmod 700 "$TMP/home/Library/Application Support/macprovider/lifecycle"
  /usr/bin/python3 - "$TMP/home/Library/Application Support/macprovider/lifecycle/lease.json" "$kind" "$owner_pid" "$window" "$owner_start_override" <<'PY'
import ctypes
import json
import sys
import time
import uuid

def current_monotonic_ns():
    if hasattr(time, "clock_gettime_ns") and hasattr(time, "CLOCK_MONOTONIC_RAW"):
        return time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW)
    raise SystemExit("CLOCK_MONOTONIC_RAW unavailable")

class ProcBsdInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("pbi_e_tdev", ctypes.c_uint32),
        ("pbi_e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]

def live_process_start_us(pid):
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    proc_pidinfo = libproc.proc_pidinfo
    proc_pidinfo.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    proc_pidinfo.restype = ctypes.c_int
    info = ProcBsdInfo()
    count = proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    if count != ctypes.sizeof(info):
        raise SystemExit("could not read process start")
    value = int(info.pbi_start_tvsec) * 1_000_000 + int(info.pbi_start_tvusec)
    if value <= 0:
        raise SystemExit("invalid process start")
    return value

path, kind, owner_pid_text, window, owner_start_override = sys.argv[1:]
owner_pid = int(owner_pid_text)
owner_start_us = int(owner_start_override) if owner_start_override else live_process_start_us(owner_pid)
duration_ms = 30 * 60 * 1000 if kind == "startup" else 20 * 60 * 1000
issued_wall_ms = int(time.time() * 1000)
issued_monotonic_ns = current_monotonic_ns()
if window == "expired":
    issued_wall_ms -= duration_ms * 2
    issued_monotonic_ns -= duration_ms * 2 * 1_000_000
record = {
    "version": 1,
    "lease_id": str(uuid.uuid4()),
    "operation_id": "watchdog-test",
    "kind": kind,
    "owner": {
        "pid": owner_pid,
        "process_start_us": owner_start_us,
        "boot_session": "boot-a",
    },
    "issued_wall_ms": issued_wall_ms,
    "expires_wall_ms": issued_wall_ms + duration_ms,
    "issued_monotonic_ns": issued_monotonic_ns,
    "expires_monotonic_ns": issued_monotonic_ns + duration_ms * 1_000_000,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
  chmod 600 "$TMP/home/Library/Application Support/macprovider/lifecycle/lease.json"
}

# F1 (RFC-001 #1382, SPEC-020 R-4.14): with no validated launchd PID the
# watchdog MUST only observe — launchd KeepAlive is the single exit-restart
# owner, so the watchdog no longer kickstarts a missing provider (this removes
# the second, mutable exit-restart authority behind #1189).
make_fake_common
: > "$TMP/launchctl.log"
run_watchdog
grep -F 'has no validated PID' "$TMP/logs/watchdog.log" >/dev/null
grep -F 'watchdog does not kick' "$TMP/logs/watchdog.log" >/dev/null
if grep -F 'kickstart' "$TMP/launchctl.log" >/dev/null; then
  echo "missing validated PID must not trigger any watchdog kickstart (launchd KeepAlive owns exit-restart)" >&2
  exit 1
fi

# The kickstart failure status is now irrelevant on the missing-PID path: the
# watchdog never issues a kickstart there, so no restart is attempted.
rm -rf "$TMP/bin" "$TMP/logs" "$TMP/launchctl.log" "$TMP/home/.local/share/macprovider-watchdog/state"
make_fake_common
WATCHDOG_TEST_KICKSTART_STATUS=73
export WATCHDOG_TEST_KICKSTART_STATUS
: > "$TMP/launchctl.log"
run_watchdog
if grep -F 'kickstart' "$TMP/launchctl.log" >/dev/null; then
  echo "missing validated PID must not kick regardless of kickstart status" >&2
  exit 1
fi
unset WATCHDOG_TEST_KICKSTART_STATUS

rm -rf "$TMP/bin" "$TMP/logs" "$TMP/launchctl.log" "$TMP/home/.local/share/macprovider-watchdog/state"
make_fake_common
mkdir -p "$TMP/home/macprovider"
cat > "$TMP/home/macprovider/macprovider-cli" <<'EOF'
#!/usr/bin/env bash
echo "unexpected watchdog binary execution: $*" >> "$WATCHDOG_TEST_LEASE_LOG"
exit 99
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
grep -F 'provider restart requested for live.malibu.provider via launchctl kickstart -k reason=local_health_failed_after_arming' "$TMP/logs/watchdog.log" >/dev/null
unset WATCHDOG_TEST_HEALTH_STATUS WATCHDOG_TEST_STATUS_BODY

# Darwin-only below: the lifecycle-lease process-identity cases use
# /usr/lib/libproc.dylib (proc_pidinfo) via write_watchdog_lease, which is absent
# on Linux CI runners. Everything above — observe-only missing-PID (J2 removed)
# and the J1 health-wedge kick / pause / drain / malformed-status cases — is
# platform-independent and has already run. (This guard was previously higher in
# the file; the F1 rewrite of the missing-PID scenarios must keep it before the
# libproc-dependent lease block.)
if [ "$(uname -s)" != "Darwin" ]; then
  echo "SKIP: Darwin-only lifecycle-lease process-identity cases require libproc.dylib"
  echo "watchdog health scope ok"
  exit 0
fi

rm -rf "$TMP/bin" "$TMP/logs" "$TMP/launchctl.log" "$TMP/home/.local/share/macprovider-watchdog/state"
make_fake_common
/bin/sleep 300 &
provider_owner_pid=$!
/usr/bin/tail -f /dev/null &
forged_owner_pid=$!
mkdir -p "$TMP/home/macprovider"
cat > "$TMP/home/macprovider/macprovider-cli" <<'EOF'
#!/usr/bin/env bash
echo "unexpected watchdog binary execution: $*" >> "$WATCHDOG_TEST_LEASE_LOG"
exit 99
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
    printf 'n%s\n' "$WATCHDOG_TEST_BINARY_PATH"
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
WATCHDOG_TEST_SERVICE_PID="$provider_owner_pid"
WATCHDOG_TEST_BINARY_PATH="/bin/sleep"
export WATCHDOG_TEST_LEASE_LOG WATCHDOG_TEST_LEASE_MODE
export WATCHDOG_TEST_SERVICE_PID WATCHDOG_TEST_BINARY_PATH
MACPROVIDER_HEADLESS=1
export MACPROVIDER_HEADLESS
write_watchdog_lease startup "$provider_owner_pid"
run_watchdog
grep -F 'inside a validated startup/maintenance lease; watchdog grants bounded grace' "$TMP/logs/watchdog.log" >/dev/null
if [ -s "$TMP/lease.log" ]; then
  echo "watchdog must not execute the provider binary to validate startup lease grace" >&2
  exit 1
fi
if grep -F "provider process $provider_owner_pid failed local /v1/health after arming" "$TMP/logs/watchdog.log" >/dev/null; then
  echo "valid lifecycle lease must suppress the unhealthy action path" >&2
  exit 1
fi

for lease_mode in maintenance stale forged; do
  : > "$TMP/logs/watchdog.log"
  : > "$TMP/lease.log"
  rm -f "$TMP/home/.local/share/macprovider-watchdog/state/last_kick"
  WATCHDOG_TEST_LEASE_MODE="$lease_mode"
  export WATCHDOG_TEST_LEASE_MODE
  case "$lease_mode" in
    maintenance) write_watchdog_lease maintenance "$provider_owner_pid" ;;
    stale) write_watchdog_lease startup "$provider_owner_pid" expired ;;
    forged) write_watchdog_lease startup "$forged_owner_pid" ;;
  esac
  run_watchdog

  if [ -s "$TMP/lease.log" ]; then
    echo "watchdog must not execute the provider binary to validate $lease_mode lease state" >&2
    exit 1
  fi

  if [ "$lease_mode" = maintenance ]; then
    grep -F 'inside a validated startup/maintenance lease; watchdog grants bounded grace' "$TMP/logs/watchdog.log" >/dev/null
    if grep -F "provider process $provider_owner_pid failed local /v1/health after arming" "$TMP/logs/watchdog.log" >/dev/null; then
      echo "valid maintenance lease must suppress the unhealthy action path" >&2
      exit 1
    fi
  else
    if grep -F 'inside a validated startup/maintenance lease; watchdog grants bounded grace' "$TMP/logs/watchdog.log" >/dev/null; then
      echo "$lease_mode lifecycle lease must fail closed" >&2
      exit 1
    fi
    grep -F "provider process $provider_owner_pid failed local /v1/health after arming; requesting launchd restart" "$TMP/logs/watchdog.log" >/dev/null
    grep -F 'provider restart requested for live.malibu.provider via launchctl kickstart -k reason=local_health_failed_after_arming' "$TMP/logs/watchdog.log" >/dev/null
  fi
done

if [ "$(grep -c -F 'kickstart -k gui/' "$TMP/launchctl.log")" -ne 2 ]; then
  echo "watchdog must kick exactly the stale and forged unhealthy providers" >&2
  exit 1
fi

kill "$provider_owner_pid"
wait "$provider_owner_pid" >/dev/null 2>&1 || true
provider_owner_pid=""
kill "$forged_owner_pid"
wait "$forged_owner_pid" >/dev/null 2>&1 || true
forged_owner_pid=""
unset MACPROVIDER_HEADLESS WATCHDOG_TEST_BINARY_PATH WATCHDOG_TEST_LEASE_LOG WATCHDOG_TEST_LEASE_MODE WATCHDOG_TEST_SERVICE_PID

echo "watchdog health scope ok"

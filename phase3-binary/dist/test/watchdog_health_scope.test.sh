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
  MACPROVIDER_OPERATOR_RESUME_LEASE_PATH="$TMP/home/Library/Application Support/macprovider/lifecycle/operator-resume-lease.json" \
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
  lease_path="${5:-$TMP/home/Library/Application Support/macprovider/lifecycle/lease.json}"
  lease_duration_ms="${6:-}"
  mkdir -p "$TMP/home/Library/Application Support/macprovider/lifecycle"
  chmod 700 "$TMP/home/Library/Application Support/macprovider/lifecycle"
  /usr/bin/python3 - "$TMP/home/Library/Application Support/macprovider/lifecycle/lease.json" "$kind" "$owner_pid" "$window" "$owner_start_override" "$lease_path" "$lease_duration_ms" <<'PY'
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

_, kind, owner_pid_text, window, owner_start_override, path, duration_override = sys.argv[1:]
owner_pid = int(owner_pid_text)
owner_start_us = int(owner_start_override) if owner_start_override else live_process_start_us(owner_pid)
duration_ms = int(duration_override) if duration_override else (30 * 60 * 1000 if kind == "startup" else 20 * 60 * 1000)
issued_wall_ms = int(time.time() * 1000)
issued_monotonic_ns = current_monotonic_ns()
if window == "expired":
    issued_wall_ms -= duration_ms * 2
    issued_monotonic_ns -= duration_ms * 2 * 1_000_000
elif window == "few_seconds":
    issued_wall_ms -= 3_000
    issued_monotonic_ns -= 3_000_000_000
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
  chmod 600 "$lease_path"
  lease_lock="$(dirname "$lease_path")/.$(basename "$lease_path").lock"
  if [ ! -e "$lease_lock" ]; then
    : > "$lease_lock"
    chmod 600 "$lease_lock"
  fi
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

# Create intentionally makes /v1/health unavailable while the process owns
# the listener. Every creative phase, including warm and restoration, must
# preserve the request and its in-memory error/progress state.
for creative_state in holding_customers downloading generating warm restoring; do
  : > "$TMP/logs/watchdog.log"
  : > "$TMP/launchctl.log"
  WATCHDOG_TEST_STATUS_BODY="{\"status\":\"unavailable\",\"lifecycle\":{\"operator_paused\":false,\"state\":\"serving_buyers\"},\"local_image_generation\":{\"state\":\"$creative_state\"}}"
  export WATCHDOG_TEST_STATUS_BODY
  run_watchdog
  grep -F 'failed local /v1/health after arming, but /v1/status does not recommend watchdog restart' "$TMP/logs/watchdog.log" >/dev/null
  if grep -F 'kickstart -k' "$TMP/launchctl.log" >/dev/null; then
    echo "creative state $creative_state must not trigger watchdog kickstart" >&2
    exit 1
  fi
done

# A failed restoration and malformed/unknown creative state cannot mask a
# genuinely unavailable process. Clear cooldown between expected restarts.
for creative_json in '{"state":"recovery_required"}' '{"state":"idle"}' '{"state":"unknown"}' 'null' '"bad"'; do
  rm -f "$TMP/home/.local/share/macprovider-watchdog/state/last_kick"
  : > "$TMP/launchctl.log"
  WATCHDOG_TEST_STATUS_BODY="{\"status\":\"unavailable\",\"lifecycle\":{\"operator_paused\":false,\"state\":\"serving_buyers\"},\"local_image_generation\":$creative_json}"
  export WATCHDOG_TEST_STATUS_BODY
  run_watchdog
  grep -F 'kickstart -k' "$TMP/launchctl.log" >/dev/null
done
rm -f "$TMP/home/.local/share/macprovider-watchdog/state/last_kick"

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
# A successful answer resets the streak, even when health still fails.
WATCHDOG_TEST_STATUS_EXIT=0
WATCHDOG_TEST_STATUS_BODY='{"status":"ready","lifecycle":{"operator_paused":false}}'
export WATCHDOG_TEST_STATUS_EXIT WATCHDOG_TEST_STATUS_BODY
run_watchdog
[ ! -e "$TMP/home/.local/share/macprovider-watchdog/state/status_no_answer" ]
# Connection failure and timeout share the bounded no-answer path. Two ticks
# defer; the third requests restart. Each run is a fresh watchdog process.
WATCHDOG_TEST_STATUS_EXIT=28
export WATCHDOG_TEST_STATUS_EXIT
: > "$TMP/launchctl.log"
for tick in 1 2; do
  run_watchdog
  if grep -F 'kickstart -k' "$TMP/launchctl.log" >/dev/null; then
    echo "status timeout tick $tick must not restart before the bound" >&2
    exit 1
  fi
done
run_watchdog
grep -F 'kickstart -k' "$TMP/launchctl.log" >/dev/null
rm -f "$TMP/home/.local/share/macprovider-watchdog/state/last_kick"
# A creative hold answer clears even a saturated no-answer streak and vetoes.
WATCHDOG_TEST_STATUS_EXIT=0
WATCHDOG_TEST_STATUS_BODY='{"status":"unavailable","lifecycle":{"operator_paused":false},"local_image_generation":{"state":"generating"}}'
export WATCHDOG_TEST_STATUS_EXIT WATCHDOG_TEST_STATUS_BODY
: > "$TMP/launchctl.log"
run_watchdog
[ ! -e "$TMP/home/.local/share/macprovider-watchdog/state/status_no_answer" ]
! grep -F 'kickstart -k' "$TMP/launchctl.log" >/dev/null
WATCHDOG_TEST_STATUS_EXIT=28
export WATCHDOG_TEST_STATUS_EXIT
run_watchdog
! grep -F 'kickstart -k' "$TMP/launchctl.log" >/dev/null
rm -f "$TMP/home/.local/share/macprovider-watchdog/state/status_no_answer"
unset WATCHDOG_TEST_STATUS_EXIT

: > "$TMP/logs/watchdog.log"
: > "$TMP/launchctl.log"
WATCHDOG_TEST_STATUS_BODY='{"status":"unavailable","lifecycle":{"operator_paused":false,"state":"serving_buyers"}}'
export WATCHDOG_TEST_STATUS_BODY
run_watchdog
grep -F 'provider process 4242 failed local /v1/health after arming; requesting launchd restart' "$TMP/logs/watchdog.log" >/dev/null
grep -F 'provider restart requested for live.malibu.provider via launchctl kickstart -k reason=local_health_failed_after_arming' "$TMP/logs/watchdog.log" >/dev/null

# SPEC-020 R-4.14: an operator-paused provider is never kicked for health
# reasons, including when its listener is lost or cannot be proven. The pause
# is read from the persisted lifecycle record, not only from /v1/status.
# Listener probes that fail or time out are indeterminate, not "lost", and a
# clean not-owned answer must repeat before it can recommend a restart.
cat > "$TMP/bin/lsof" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'-d txt -Fn'*)
    printf 'n%s\n' "/usr/lib/dyld"
    printf 'n%s\n' "$HOME/macprovider/macprovider-cli"
    ;;
  *)
    echo call >> "$WATCHDOG_TEST_LISTENER_CALLS"
    case "${WATCHDOG_TEST_LISTENER_MODE:-owned}" in
      owned) echo 4242 ;;
      foreign) echo 9999 ;;
      none) exit 1 ;;
      noise) echo "lsof: WARNING: can't stat() file system" >&2; exit 1 ;;
      pid_noise) echo 4242; echo "lsof: status error on /dev/fd" >&2 ;;
      fail) exit 2 ;;
      hang) exec sleep 30 ;;
      flap)
        if [ "$(wc -l < "$WATCHDOG_TEST_LISTENER_CALLS")" -le 2 ]; then echo 9999; else echo 4242; fi
        ;;
    esac
    ;;
esac
EOF
chmod +x "$TMP/bin/lsof"
lifecycle_dir="$TMP/home/Library/Application Support/macprovider/lifecycle"
state_record="$lifecycle_dir/state-v1.json"
mkdir -p "$lifecycle_dir"
chmod 700 "$lifecycle_dir"
for lock_name in .state-v1.json.lock .lease.json.lock .operator-resume-lease.json.lock; do
  : > "$lifecycle_dir/$lock_name"
  chmod 600 "$lifecycle_dir/$lock_name"
done
WATCHDOG_TEST_LISTENER_CALLS="$TMP/listener-calls"
MACPROVIDER_WATCHDOG_LISTENER_RETRY_DELAY_SECONDS=0
MACPROVIDER_WATCHDOG_LISTENER_PROBE_TIMEOUT_SECONDS=1
export WATCHDOG_TEST_LISTENER_CALLS MACPROVIDER_WATCHDOG_LISTENER_RETRY_DELAY_SECONDS MACPROVIDER_WATCHDOG_LISTENER_PROBE_TIMEOUT_SECONDS
unpaused_unavailable='{"status":"unavailable","lifecycle":{"operator_paused":false,"state":"serving_buyers"}}'

record_json() {
  printf '{"version":1,"sequence":7,"transition_id":"t","transition_at":"x","reason_code":"r","writer":"serve","authority":"macprovider_cli","state":"%s","operator_paused":%s}\n' "$1" "$2"
}

# Usage: listener_case <listener-mode> <record> <expect: kick|no-kick> [status-exit]
# record: paused | paused_state | unpaused | symlink | mode644 | hardlink |
#         no_authority | bad_version | float_version | int_paused |
#         null_paused | no_sequence | bad_paused_type | oversized | none
listener_case() {
  mode="$1"; record="$2"; expect="$3"; status_exit="${4:-0}"
  : > "$TMP/logs/watchdog.log"
  : > "$TMP/launchctl.log"
  : > "$WATCHDOG_TEST_LISTENER_CALLS"
  rm -f "$TMP/home/.local/share/macprovider-watchdog/state/last_kick" "$state_record" "$TMP/state-target.json"
  case "$record" in
    paused) record_json paused_by_operator true > "$state_record" ;;
    paused_state) record_json paused_by_operator false > "$state_record" ;;
    unpaused) record_json serving_buyers false > "$state_record" ;;
    symlink)
      record_json paused_by_operator true > "$TMP/state-target.json"
      chmod 600 "$TMP/state-target.json"
      ln -s "$TMP/state-target.json" "$state_record"
      ;;
    mode644) record_json paused_by_operator true > "$state_record" ;;
    hardlink)
      record_json paused_by_operator true > "$state_record"
      ln "$state_record" "$TMP/state-target.json"
      ;;
    no_authority) printf '%s\n' '{"sequence":7,"transition_id":"t","transition_at":"x","reason_code":"r","writer":"serve","version":1,"state":"paused_by_operator","operator_paused":true}' > "$state_record" ;;
    bad_version) printf '%s\n' '{"sequence":7,"transition_id":"t","transition_at":"x","reason_code":"r","writer":"serve","version":2,"authority":"macprovider_cli","state":"paused_by_operator","operator_paused":true}' > "$state_record" ;;
    float_version) printf '%s\n' '{"sequence":7,"transition_id":"t","transition_at":"x","reason_code":"r","writer":"serve","version":1.0,"authority":"macprovider_cli","state":"paused_by_operator","operator_paused":true}' > "$state_record" ;;
    null_paused) printf '%s\n' '{"version":1,"sequence":7,"transition_id":"t","transition_at":"x","reason_code":"r","writer":"serve","authority":"macprovider_cli","state":"paused_by_operator","operator_paused":null}' > "$state_record" ;;
    no_sequence) printf '%s\n' '{"version":1,"transition_id":"t","transition_at":"x","reason_code":"r","writer":"serve","authority":"macprovider_cli","state":"paused_by_operator","operator_paused":true}' > "$state_record" ;;
    int_paused) printf '%s\n' '{"sequence":7,"transition_id":"t","transition_at":"x","reason_code":"r","writer":"serve","version":1,"authority":"macprovider_cli","state":"paused_by_operator","operator_paused":1}' > "$state_record" ;;
    bad_paused_type) printf '%s\n' '{"sequence":7,"transition_id":"t","transition_at":"x","reason_code":"r","writer":"serve","version":1,"authority":"macprovider_cli","state":"paused_by_operator","operator_paused":"yes"}' > "$state_record" ;;
    oversized)
      /usr/bin/python3 -c 'import json,sys; print(json.dumps({"version":1,"sequence":7,"transition_id":"t","transition_at":"x","reason_code":"r","writer":"serve","authority":"macprovider_cli","state":"paused_by_operator","operator_paused":True,"pad":"x"*70000}))' > "$state_record"
      ;;
    none) : ;;
  esac
  if [ -f "$state_record" ] && [ ! -L "$state_record" ]; then
    if [ "$record" = mode644 ]; then chmod 644 "$state_record"; else chmod 600 "$state_record"; fi
  fi
  WATCHDOG_TEST_LISTENER_MODE="$mode"
  WATCHDOG_TEST_STATUS_BODY="$unpaused_unavailable"
  WATCHDOG_TEST_STATUS_EXIT="$status_exit"
  export WATCHDOG_TEST_LISTENER_MODE WATCHDOG_TEST_STATUS_BODY WATCHDOG_TEST_STATUS_EXIT
  run_watchdog
  if [ "$expect" = kick ]; then
    grep -F 'kickstart -k' "$TMP/launchctl.log" >/dev/null || {
      echo "listener=$mode record=$record must keep unpaused wedge recovery" >&2
      exit 1
    }
  elif grep -F 'kickstart -k' "$TMP/launchctl.log" >/dev/null; then
    echo "listener=$mode record=$record must not kick the provider" >&2
    exit 1
  fi
}

for mode in foreign none noise owned; do
  listener_case "$mode" paused no-kick
  grep -F 'operator-paused per the persisted lifecycle record; watchdog never restarts a paused provider' "$TMP/logs/watchdog.log" >/dev/null
done
# The pause is the operator_paused boolean the serve process honors at
# startup; a paused_by_operator state without it is not a pause.
# A persisted pause vetoes all three timeout ticks before status is consulted.
for tick in 1 2 3; do
  listener_case owned paused no-kick 28
  [ ! -e "$TMP/home/.local/share/macprovider-watchdog/state/status_no_answer" ]
done
listener_case foreign paused_state kick
# A record that fails the Swift store's file or schema invariants is not a pause.
for record in symlink mode644 hardlink no_authority bad_version float_version int_paused null_paused no_sequence bad_paused_type oversized; do
  listener_case foreign "$record" kick
done
for mode in noise pid_noise fail hang; do
  listener_case "$mode" unpaused no-kick
  grep -F 'is indeterminate (probe failed or timed out); not treating it as lost' "$TMP/logs/watchdog.log" >/dev/null
done
listener_case flap unpaused no-kick 71
if [ "$(wc -l < "$WATCHDOG_TEST_LISTENER_CALLS")" -lt 3 ]; then
  echo "a not-owned listener verdict must be re-probed once before it counts" >&2
  exit 1
fi
for mode in foreign none; do
  listener_case "$mode" unpaused kick
  if [ "$(wc -l < "$WATCHDOG_TEST_LISTENER_CALLS")" -lt 3 ]; then
    echo "listener=$mode restart must follow two not-owned probes" >&2
    exit 1
  fi
done
listener_case foreign none kick

# Restart gate: the final vetoes and the kickstart request run while the
# watchdog holds the lifecycle stores' own flocks; a busy store defers.
cat > "$TMP/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$WATCHDOG_TEST_LAUNCHCTL_LOG"
case "$*" in
  print*) printf 'pid = %s\n' "$WATCHDOG_TEST_SERVICE_PID" ;;
  kickstart*)
    /usr/bin/python3 -c '
import fcntl, sys
handle = open(sys.argv[1], "rb")
try:
    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    print("gate=free")
except BlockingIOError:
    print("gate=held")
' "$WATCHDOG_TEST_GATE_LOCK" >> "$WATCHDOG_TEST_GATE_LOG"
    if [ -n "${WATCHDOG_TEST_KICKSTART_HANG:-}" ]; then
      exec sleep 30
    fi
    ;;
esac
EOF
chmod +x "$TMP/bin/launchctl"
WATCHDOG_TEST_GATE_LOCK="$lifecycle_dir/.state-v1.json.lock"
WATCHDOG_TEST_GATE_LOG="$TMP/gate.log"
export WATCHDOG_TEST_GATE_LOCK WATCHDOG_TEST_GATE_LOG
: > "$WATCHDOG_TEST_GATE_LOG"
listener_case foreign unpaused kick
if [ "$(cat "$WATCHDOG_TEST_GATE_LOG")" != "gate=held" ]; then
  echo "kickstart must be requested while the restart gate holds the lifecycle lock" >&2
  exit 1
fi
/usr/bin/python3 -c '
import fcntl, sys, time
handle = open(sys.argv[1], "rb")
fcntl.flock(handle, fcntl.LOCK_EX)
time.sleep(6)
' "$lifecycle_dir/.lease.json.lock" </dev/null >/dev/null 2>&1 &
gate_holder_pid=$!
sleep 0.5
MACPROVIDER_WATCHDOG_RESTART_GATE_SECONDS=1
export MACPROVIDER_WATCHDOG_RESTART_GATE_SECONDS
listener_case foreign unpaused no-kick
grep -F 'restart deferred: lifecycle store busy' "$TMP/logs/watchdog.log" >/dev/null
kill "$gate_holder_pid" >/dev/null 2>&1 || true
wait "$gate_holder_pid" >/dev/null 2>&1 || true

# A launchctl that does not return is aborted while the gate is still held,
# and the tick finishes instead of waiting on it.
: > "$WATCHDOG_TEST_GATE_LOG"
WATCHDOG_TEST_KICKSTART_HANG=1
export WATCHDOG_TEST_KICKSTART_HANG
gate_started="$(date +%s)"
listener_case foreign unpaused kick
if [ "$(( $(date +%s) - gate_started ))" -ge 20 ]; then
  echo "a hung kickstart must not hold the watchdog tick" >&2
  exit 1
fi
grep -F 'did not complete within 1s; aborted under the restart gate' "$TMP/logs/watchdog.log" >/dev/null
[ "$(cat "$WATCHDOG_TEST_GATE_LOG")" = "gate=held" ]
if [ -e "$TMP/home/.local/share/macprovider-watchdog/state/last_kick" ]; then
  echo "an aborted kickstart must not start the restart cooldown" >&2
  exit 1
fi
unset WATCHDOG_TEST_KICKSTART_HANG

# A store whose lock is missing cannot be synchronized with: defer.
rm -f "$lifecycle_dir/.state-v1.json.lock"
listener_case foreign unpaused no-kick
grep -F 'restart deferred: lifecycle store busy' "$TMP/logs/watchdog.log" >/dev/null
: > "$lifecycle_dir/.state-v1.json.lock"
chmod 600 "$lifecycle_dir/.state-v1.json.lock"
unset MACPROVIDER_WATCHDOG_RESTART_GATE_SECONDS WATCHDOG_TEST_GATE_LOCK WATCHDOG_TEST_GATE_LOG
rm -f "$lifecycle_dir/.state-v1.json.lock" "$lifecycle_dir/.lease.json.lock" "$lifecycle_dir/.operator-resume-lease.json.lock"
rm -f "$state_record" "$TMP/state-target.json" "$WATCHDOG_TEST_LISTENER_CALLS"
unset WATCHDOG_TEST_LISTENER_MODE WATCHDOG_TEST_STATUS_EXIT
echo "paused provider listener veto ok"
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

# Resume grace must protect an armed process even before its listener returns.
# No startup/maintenance lease is present. The clock-shifted records avoid sleeps.
rm -f "$TMP/home/Library/Application Support/macprovider/lifecycle/lease.json"
resume_lease_path="$TMP/home/Library/Application Support/macprovider/lifecycle/operator-resume-lease.json"
for resume_case in valid expired oversized wrong_pid wrong_kind; do
  : > "$TMP/logs/watchdog.log"
  : > "$TMP/launchctl.log"
  rm -f "$TMP/home/.local/share/macprovider-watchdog/state/last_kick"
  case "$resume_case" in
    valid) write_watchdog_lease startup "$provider_owner_pid" few_seconds "" "$resume_lease_path" 60000 ;;
    expired) write_watchdog_lease startup "$provider_owner_pid" expired "" "$resume_lease_path" 60000 ;;
    oversized) write_watchdog_lease startup "$provider_owner_pid" valid "" "$resume_lease_path" 60001 ;;
    wrong_pid) write_watchdog_lease startup "$forged_owner_pid" valid "" "$resume_lease_path" 60000 ;;
    wrong_kind) write_watchdog_lease maintenance "$provider_owner_pid" valid "" "$resume_lease_path" 60000 ;;
  esac
  run_watchdog
  if [ "$resume_case" = valid ]; then
    grep -F 'inside a validated operator-resume lease; watchdog grants bounded grace' "$TMP/logs/watchdog.log" >/dev/null
    if grep -F 'kickstart -k' "$TMP/launchctl.log" >/dev/null; then
      echo "resumed provider must not restart before its grace window expires" >&2
      exit 1
    fi
  else
    grep -F 'kickstart -k' "$TMP/launchctl.log" >/dev/null || {
      echo "invalid/expired resume lease ($resume_case) must not defer wedge recovery" >&2
      exit 1
    }
  fi
done
rm -f "$resume_lease_path"
echo "operator resume grace and expiry ok"

# 2026-10-17 incident: the operator resume landed after the watchdog's first
# lease check but before its /v1/status read, which then saw "unavailable,
# not paused" and kicked the resuming provider. Resume publishes its grace
# lease before clearing the pause, so the veto re-check after the status
# verdict must see it and grant grace.
staged_resume_lease="$TMP/staged-operator-resume-lease.json"
write_watchdog_lease startup "$provider_owner_pid" few_seconds "" "$staged_resume_lease" 60000
cat > "$TMP/bin/lsof" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'-d txt -Fn'*)
    printf 'n%s\n' "/usr/lib/dyld"
    printf 'n%s\n' "$WATCHDOG_TEST_BINARY_PATH"
    ;;
  *) echo "$WATCHDOG_TEST_SERVICE_PID" ;;
esac
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  */v1/health*) exit 22 ;;
  */v1/status*)
    echo call >> "$WATCHDOG_TEST_STATUS_CALLS"
    if [ "$(wc -l < "$WATCHDOG_TEST_STATUS_CALLS")" -eq "$WATCHDOG_TEST_ACT_ON_STATUS_CALL" ]; then
      case "$WATCHDOG_TEST_ACTION" in
        resume)
          cp "$WATCHDOG_TEST_STAGED_RESUME_LEASE" "$WATCHDOG_TEST_RESUME_LEASE_PATH"
          chmod 600 "$WATCHDOG_TEST_RESUME_LEASE_PATH"
          ;;
        pause)
          printf '%s\n' '{"version":1,"sequence":7,"transition_id":"t","transition_at":"x","reason_code":"r","writer":"operator_command","authority":"macprovider_cli","state":"paused_by_operator","operator_paused":true}' > "$WATCHDOG_TEST_STATE_RECORD"
          chmod 600 "$WATCHDOG_TEST_STATE_RECORD"
          ;;
      esac
    fi
    printf '%s\n' '{"status":"unavailable","lifecycle":{"operator_paused":false,"state":"locally_ready_connecting"}}'
    ;;
  *) exit 7 ;;
esac
EOF
chmod +x "$TMP/bin/lsof" "$TMP/bin/curl"
WATCHDOG_TEST_STAGED_RESUME_LEASE="$staged_resume_lease"
WATCHDOG_TEST_RESUME_LEASE_PATH="$resume_lease_path"
WATCHDOG_TEST_STATE_RECORD="$TMP/home/Library/Application Support/macprovider/lifecycle/state-v1.json"
WATCHDOG_TEST_STATUS_CALLS="$TMP/status-calls"
for lock_name in .state-v1.json.lock .operator-resume-lease.json.lock; do
  : > "$TMP/home/Library/Application Support/macprovider/lifecycle/$lock_name"
  chmod 600 "$TMP/home/Library/Application Support/macprovider/lifecycle/$lock_name"
done
export WATCHDOG_TEST_STAGED_RESUME_LEASE WATCHDOG_TEST_RESUME_LEASE_PATH WATCHDOG_TEST_STATE_RECORD WATCHDOG_TEST_STATUS_CALLS
# Status call 1 is the restart verdict; call 2 is the pre-kick telemetry capture.
for race in resume:1 resume:2 pause:2; do
  WATCHDOG_TEST_ACTION="${race%%:*}"
  WATCHDOG_TEST_ACT_ON_STATUS_CALL="${race##*:}"
  export WATCHDOG_TEST_ACTION WATCHDOG_TEST_ACT_ON_STATUS_CALL
  : > "$TMP/logs/watchdog.log"
  : > "$TMP/launchctl.log"
  : > "$WATCHDOG_TEST_STATUS_CALLS"
  rm -f "$resume_lease_path" "$WATCHDOG_TEST_STATE_RECORD" "$TMP/home/.local/share/macprovider-watchdog/state/last_kick"
  run_watchdog
  if grep -F 'kickstart -k' "$TMP/launchctl.log" >/dev/null; then
    echo "a $WATCHDOG_TEST_ACTION landing at status call $WATCHDOG_TEST_ACT_ON_STATUS_CALL must not be kicked" >&2
    exit 1
  fi
  case "$WATCHDOG_TEST_ACTION" in
    resume) grep -F 'gained a validated operator-resume lease during restart evaluation; watchdog grants bounded grace' "$TMP/logs/watchdog.log" >/dev/null ;;
    pause) grep -F 'operator-paused per the persisted lifecycle record' "$TMP/logs/watchdog.log" >/dev/null ;;
  esac
done
rm -f "$resume_lease_path" "$staged_resume_lease" "$WATCHDOG_TEST_STATE_RECORD" "$WATCHDOG_TEST_STATUS_CALLS"
unset WATCHDOG_TEST_STAGED_RESUME_LEASE WATCHDOG_TEST_RESUME_LEASE_PATH WATCHDOG_TEST_STATE_RECORD WATCHDOG_TEST_STATUS_CALLS WATCHDOG_TEST_ACTION WATCHDOG_TEST_ACT_ON_STATUS_CALL
echo "operator resume during restart evaluation ok"

kill "$provider_owner_pid"
wait "$provider_owner_pid" >/dev/null 2>&1 || true
provider_owner_pid=""
kill "$forged_owner_pid"
wait "$forged_owner_pid" >/dev/null 2>&1 || true
forged_owner_pid=""
unset MACPROVIDER_HEADLESS WATCHDOG_TEST_BINARY_PATH WATCHDOG_TEST_LEASE_LOG WATCHDOG_TEST_LEASE_MODE WATCHDOG_TEST_SERVICE_PID

echo "watchdog health scope ok"

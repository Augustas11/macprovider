#!/usr/bin/env bash
# macprovider-watchdog: local provider liveness monitor.
#
# Health verdict: the exact launchd service PID must own the configured local
# listener and its /v1/health endpoint must answer. /v1/health returns non-2xx
# for degraded/draining/unavailable states, so a provider stuck reporting
# unavailable after the watchdog is armed is restartable. Coordinator TCP
# reachability is advisory logging only; a missing ESTABLISHED coordinator
# connection no longer causes a kick by itself. Update and rollback
# transactions are resolved by their installer/CLI owner, not by this watchdog.

set -euo pipefail

LABEL="${MACPROVIDER_WATCHDOG_LABEL:-live.malibu.provider}"
CONFIG_PATH="${MACPROVIDER_CONFIG_PATH:-$HOME/.config/macprovider/config.yaml}"
BINARY_PATH="${MACPROVIDER_BINARY_PATH:-$HOME/macprovider/malibu-cli}"
LIFECYCLE_LEASE_PATH="${MACPROVIDER_LIFECYCLE_LEASE_PATH:-$HOME/Library/Application Support/macprovider/lifecycle/lease.json}"
LIFECYCLE_LEASE_OWNER_UID="${MACPROVIDER_LIFECYCLE_LEASE_OWNER_UID:-$(id -u)}"
COORDINATOR_HOST="${MACPROVIDER_COORDINATOR_HOST:-coordinator.malibu.tech}"
COORDINATOR_PORT="${MACPROVIDER_COORDINATOR_PORT:-443}"
LOG_DIR="${MACPROVIDER_LOG_DIR:-$HOME/Library/Logs/macprovider}"
LOG_PATH="$LOG_DIR/watchdog.log"
# Issue #191 R1 architect HIGH: arming + grace state. Without
# these, a first-time install can spin in a restart loop — the
# Swift CLI loads the model BEFORE connecting to the coordinator
# (cold-cache model load is 10-20 minutes), and a watchdog that
# kicks on "no ESTABLISHED connection" would Darwin.exit the
# process every 60s before it ever opens its socket.
#
# Arming rule: the watchdog stays disarmed (no kicks) until it
# observes at least ONE successful local health response IN THE
# CURRENT BOOT. The armed marker stores the boot id so a reboot —
# which restarts the provider into a fresh cold-cache model load —
# re-disarms the watchdog and prevents stale-arming restart loops.
#
# Grace rule: after we observe a restart-worthy failure, we wait at least KICK_GRACE_SECONDS
# before logging another restart request. This covers the post-restart model-reload
# window without re-triggering on the gap between launchd respawn
# and re-establishing the coordinator socket.
STATE_DIR="${MACPROVIDER_WATCHDOG_STATE_DIR:-$HOME/.local/share/macprovider-watchdog/state}"
ARMED_FILE="$STATE_DIR/armed"
LAST_KICK_FILE="$STATE_DIR/last_kick"
KICK_GRACE_SECONDS="${MACPROVIDER_WATCHDOG_KICK_GRACE_SECONDS:-300}"
case "$KICK_GRACE_SECONDS" in
  ''|*[!0-9]*) KICK_GRACE_SECONDS=300 ;;
esac
if [ "$KICK_GRACE_SECONDS" -lt 60 ] || [ "$KICK_GRACE_SECONDS" -gt 3600 ]; then
  KICK_GRACE_SECONDS=300
fi

mkdir -p "$LOG_DIR" "$STATE_DIR"

# Boot id: per-boot identifier sourced from kern.bootsessionuuid.
# Apple-provided UUID is immutable for the lifetime of a single
# boot (verified against XNU sysctl: read-only). Unlike
# kern.boottime, this value is NOT affected by NTP / manual
# wall-clock time correction (R3 architect MEDIUM #1), so a
# clock-set event during a wedge cannot silently re-disarm the
# watchdog and let the wedge persist.
current_boot_id() {
  sysctl -n kern.bootsessionuuid 2>/dev/null
}

# Acceptable formats in config.yaml are: `provider_id: ID` (yaml
# key) or `provider-id: ID` (alternate hyphenated form some operator
# tools have written historically). Either matches and surfaces the
# value with surrounding whitespace stripped.
read_provider_id() {
  if [ ! -f "$CONFIG_PATH" ]; then
    return 1
  fi
  awk '
    /^[[:space:]]*provider[_-]id[[:space:]]*:/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      sub(/[[:space:]]+$/, "")
      gsub(/^["'\'']|["'\'']$/, "")
      print
      exit
    }
  ' "$CONFIG_PATH"
}

read_config_port() {
  if [ ! -f "$CONFIG_PATH" ]; then
    return 1
  fi
  awk '
    /^[[:space:]]*port[[:space:]]*:/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$CONFIG_PATH"
}

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf "[%s] %s\n" "$(ts)" "$*" >> "$LOG_PATH"; }

resolve_coordinator_ip() {
  # First try dscacheutil (no network call if already cached);
  # fall back to host(1) which most macs have via bind-utils.
  ip="$(dscacheutil -q host -a name "$COORDINATOR_HOST" 2>/dev/null \
        | awk '/^ip_address:/ { print $2; exit }')"
  if [ -z "$ip" ] && command -v host >/dev/null 2>&1; then
    ip="$(host -t A "$COORDINATOR_HOST" 2>/dev/null \
          | awk '/has address/ { print $4; exit }')"
  fi
  printf "%s" "${ip:-}"
}

has_established_conn() {
  ip="$1"
  if [ -z "$ip" ]; then
    return 1
  fi
  # BSD netstat on macOS: print ESTABLISHED TCP rows; awk matches
  # the foreign-address column against our coordinator IP:port.
  # Format: Proto Recv-Q Send-Q Local-Address Foreign-Address (state)
  netstat -an -p tcp 2>/dev/null \
    | awk -v target="${ip}.${COORDINATOR_PORT}" '
        $0 ~ /ESTABLISHED/ && $5 == target { found = 1; exit }
        END { exit found ? 0 : 1 }
      '
}

provider_process_pid() {
  launchctl_bin="${MACPROVIDER_LAUNCHCTL:-launchctl}"
  service_target="gui/$(id -u)/$LABEL"
  if ! service_output="$("$launchctl_bin" print "$service_target" 2>/dev/null)"; then
    return 1
  fi
  candidates="$(printf "%s\n" "$service_output" | awk 'NF == 3 && $1 == "pid" && $2 == "=" && $3 ~ /^[0-9]+$/ { print $3 }')"
  [ "$(printf "%s\n" "$candidates" | awk 'NF { count++ } END { print count + 0 }')" -eq 1 ] || return 1
  candidate="$candidates"
  expected="$BINARY_PATH"
  if command -v realpath >/dev/null 2>&1 && [ -e "$expected" ]; then
    expected="$(realpath "$expected" 2>/dev/null || printf "%s" "$expected")"
  fi
  command -v lsof >/dev/null 2>&1 || return 1
  executable_output="$(lsof -a -p "$candidate" -d txt -Fn 2>/dev/null)" || return 1
  command_paths="$(printf "%s\n" "$executable_output" | awk 'substr($0, 1, 1) == "n" && length($0) > 1 { print substr($0, 2) }')"
  found_expected=""
  while IFS= read -r command_path; do
    [ -n "$command_path" ] || continue
    if command -v realpath >/dev/null 2>&1 && [ -e "$command_path" ]; then
      command_path="$(realpath "$command_path" 2>/dev/null || printf "%s" "$command_path")"
    fi
    if [ "$command_path" = "$expected" ]; then
      found_expected=1
      break
    fi
  done <<EOF
$command_paths
EOF
  [ "$found_expected" = 1 ] || return 1
  printf "%s" "$candidate"
}

local_health_listener_owned_by_provider() {
  provider_pid="$1"
  port="$2"
  if ! command -v lsof >/dev/null 2>&1; then
    return 1
  fi
  lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | awk -v pid="$provider_pid" '$1 == pid { found = 1 } END { exit found ? 0 : 1 }'
}

local_provider_health_ok() {
  provider_pid="$1"
  port="$(read_config_port || true)"
  case "$port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  local_health_listener_owned_by_provider "$provider_pid" "$port" || return 1
  curl_bin="${MACPROVIDER_CURL:-/usr/bin/curl}"
  "$curl_bin" -fsS --max-time 2 "http://127.0.0.1:${port}/v1/health" >/dev/null 2>&1
}

local_status_restart_recommended() {
  provider_pid="$1"
  port="$(read_config_port || true)"
  case "$port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if ! local_health_listener_owned_by_provider "$provider_pid" "$port"; then
    return 0
  fi
  curl_bin="${MACPROVIDER_CURL:-/usr/bin/curl}"
  status_body="$("$curl_bin" -fsS --max-time 2 "http://127.0.0.1:${port}/v1/status" 2>/dev/null)" || return 1
  STATUS_BODY="$status_body" python3 <<'PY'
import json
import os
import sys

try:
    body = json.loads(os.environ.get("STATUS_BODY", ""))
except Exception:
    sys.exit(1)

lifecycle = body.get("lifecycle")
if not isinstance(lifecycle, dict):
    sys.exit(1)

operator_paused = lifecycle.get("operator_paused")
if not isinstance(operator_paused, bool):
    sys.exit(1)

if operator_paused or lifecycle.get("state") == "paused_by_operator":
    sys.exit(1)

sys.exit(0 if body.get("status") == "unavailable" else 1)
PY
}

valid_lifecycle_lease() {
  provider_pid="$1"
  if valid_lifecycle_lease_record startup "$provider_pid"; then
    return 0
  fi
  valid_lifecycle_lease_record maintenance ""
}

valid_unbound_lifecycle_lease() {
  if valid_lifecycle_lease_record startup ""; then
    return 0
  fi
  valid_lifecycle_lease_record maintenance ""
}

valid_lifecycle_lease_record() {
  expected_kind="$1"
  expected_pid="${2:-}"
  boot_id="$(current_boot_id || true)"
  [ -n "$boot_id" ] || return 1
  /usr/bin/python3 - \
    "$LIFECYCLE_LEASE_PATH" \
    "$LIFECYCLE_LEASE_OWNER_UID" \
    "$boot_id" \
    "$expected_kind" \
    "$expected_pid" \
    "$BINARY_PATH" <<'PY'
import ctypes
import json
import os
import stat
import sys
import time

def current_monotonic_ns():
    if hasattr(time, "clock_gettime_ns") and hasattr(time, "CLOCK_MONOTONIC_RAW"):
        return time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW)
    sys.exit(1)

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

def live_process_identity(pid):
    try:
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
        path_buffer = ctypes.create_string_buffer(4096)
        proc_pidpath = libproc.proc_pidpath
        proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        proc_pidpath.restype = ctypes.c_int
        path_count = proc_pidpath(pid, path_buffer, ctypes.sizeof(path_buffer))
    except Exception:
        return None
    if count != ctypes.sizeof(info) or path_count <= 0:
        return None
    start = int(info.pbi_start_tvsec) * 1_000_000 + int(info.pbi_start_tvusec)
    if start <= 0:
        return None
    executable_path = path_buffer.value.decode("utf-8", "surrogateescape")
    if not executable_path.startswith("/"):
        return None
    return {
        "start_us": start,
        "uid": int(info.pbi_uid),
        "ruid": int(info.pbi_ruid),
        "executable_path": os.path.realpath(executable_path),
    }

path, owner_uid_text, boot_id, expected_kind, expected_pid_text, binary_path = sys.argv[1:]
try:
    owner_uid = int(owner_uid_text)
except ValueError:
    sys.exit(1)
try:
    expected_pid = int(expected_pid_text) if expected_pid_text else None
except ValueError:
    sys.exit(1)

try:
    st = os.lstat(path)
    if (
        not stat.S_ISREG(st.st_mode)
        or stat.S_ISLNK(st.st_mode)
        or st.st_uid != owner_uid
        or st.st_nlink != 1
        or stat.S_IMODE(st.st_mode) != 0o600
        or st.st_size <= 0
        or st.st_size > 16 * 1024
    ):
        sys.exit(1)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
except OSError:
    sys.exit(1)

try:
    opened = os.fstat(fd)
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_uid != owner_uid
        or opened.st_nlink != 1
        or stat.S_IMODE(opened.st_mode) != 0o600
        or (opened.st_dev, opened.st_ino) != (st.st_dev, st.st_ino)
        or opened.st_size != st.st_size
    ):
        sys.exit(1)
    data = os.read(fd, 16 * 1024 + 1)
finally:
    os.close(fd)

if len(data) != st.st_size or len(data) > 16 * 1024:
    sys.exit(1)
try:
    record = json.loads(data.decode("utf-8"))
except Exception:
    sys.exit(1)
if not isinstance(record, dict):
    sys.exit(1)

kind = record.get("kind")
if kind != expected_kind or kind not in {"startup", "maintenance"}:
    sys.exit(1)
owner = record.get("owner")
if not isinstance(owner, dict):
    sys.exit(1)
owner_pid = owner.get("pid")
owner_start = owner.get("process_start_us")
owner_boot = owner.get("boot_session")
if (
    record.get("version") != 1
    or not isinstance(owner_pid, int)
    or isinstance(owner_pid, bool)
    or owner_pid <= 0
    or not isinstance(owner_start, int)
    or isinstance(owner_start, bool)
    or owner_start <= 0
    or not isinstance(owner_boot, str)
    or not owner_boot
    or len(owner_boot.encode("utf-8")) > 256
    or owner_boot != boot_id
):
    sys.exit(1)
if expected_pid is not None and owner_pid != expected_pid:
    sys.exit(1)
try:
    os.kill(owner_pid, 0)
except OSError:
    sys.exit(1)
identity = live_process_identity(owner_pid)
if (
    identity is None
    or identity.get("start_us") != owner_start
    or identity.get("uid") != owner_uid
    or identity.get("ruid") != owner_uid
    or identity.get("executable_path") != os.path.realpath(binary_path)
):
    sys.exit(1)

maximum_ms = 30 * 60 * 1000 if kind == "startup" else 20 * 60 * 1000
fields = (
    "issued_wall_ms",
    "expires_wall_ms",
    "issued_monotonic_ns",
    "expires_monotonic_ns",
)
values = {}
for field in fields:
    value = record.get(field)
    if not isinstance(value, int) or isinstance(value, bool):
        sys.exit(1)
    values[field] = value
wall_duration = values["expires_wall_ms"] - values["issued_wall_ms"]
monotonic_duration = values["expires_monotonic_ns"] - values["issued_monotonic_ns"]
if (
    values["issued_wall_ms"] <= 0
    or values["issued_monotonic_ns"] < 0
    or wall_duration <= 0
    or wall_duration > maximum_ms
    or monotonic_duration != wall_duration * 1_000_000
):
    sys.exit(1)
now_wall_ms = int(time.time() * 1000)
now_monotonic_ns = current_monotonic_ns()
if (
    now_wall_ms < values["issued_wall_ms"]
    or now_monotonic_ns < values["issued_monotonic_ns"]
    or now_wall_ms >= values["expires_wall_ms"]
    or now_monotonic_ns >= values["expires_monotonic_ns"]
):
    sys.exit(1)
sys.exit(0)
PY
}

provider_restart_cooldown_active() {
  if [ ! -f "$LAST_KICK_FILE" ]; then
    return 1
  fi
  last_kick="$(cat "$LAST_KICK_FILE" 2>/dev/null || printf 0)"
  case "$last_kick" in
    ''|*[!0-9]*) return 1 ;;
  esac
  elapsed=$(( $(now_epoch) - last_kick ))
  [ "$elapsed" -lt "$KICK_GRACE_SECONDS" ]
}

kickstart_provider() {
  reason="$1"
  launchctl_bin="${MACPROVIDER_LAUNCHCTL:-launchctl}"
  service_target="gui/$(id -u)/$LABEL"
  if "$launchctl_bin" kickstart -k "$service_target" >/dev/null 2>&1; then
    if ! now_epoch > "$LAST_KICK_FILE"; then
      log "provider restart cooldown write failed for $LABEL reason=${reason}"
    fi
    log "provider restart requested for $LABEL via launchctl kickstart -k reason=${reason}"
    return 0
  else
    status="$?"
    log "provider restart request failed for $LABEL via launchctl kickstart -k reason=${reason} exit_status=${status}"
    return 1
  fi
}

now_epoch() { date -u +%s; }

autoupdate_recovery_tick() {
  state_root="${MACPROVIDER_AUTOUPDATE_STATE_ROOT:-$HOME/.local/share/macprovider/autoupdate}"
  pending_path="$state_root/pending.json"
  if [ ! -e "$pending_path" ] && [ ! -L "$pending_path" ]; then
    return 0
  fi
  log "autoupdate recovery deferred: pending marker exists; transaction owner must resolve update/rollback state"
}

autoupdate_recovery_supported() {
  [ "${MACPROVIDER_HEADLESS:-0}" != "1" ] || return 1
  [ "${MACPROVIDER_LAUNCHD_DOMAIN:-}" != "system" ] || return 1
  return 0
}

main() {
  if autoupdate_recovery_supported; then
    autoupdate_recovery_tick
  else
    log "autoupdate recovery skipped: unsupported_install_topology profile=headless_fleet"
  fi
  pid="$(read_provider_id || true)"
  if [ -z "$pid" ]; then
    # Provider not yet installed / configured. Stay silent; if the
    # operator installs later we'll start working on the next tick.
    exit 0
  fi
  provider_pid="$(provider_process_pid || true)"
  if [ -z "$provider_pid" ]; then
    log "provider process unhealthy: launchd service $LABEL has no validated PID at $BINARY_PATH"
    if valid_unbound_lifecycle_lease; then
      log "launchd service $LABEL has no validated PID but is inside a validated startup/maintenance lease; watchdog grants bounded grace"
      exit 0
    fi
    if ! provider_restart_cooldown_active; then
      kickstart_provider "missing_validated_pid" || true
    fi
    exit 0
  fi
  boot_id="$(current_boot_id)"
  if ! local_provider_health_ok "$provider_pid"; then
    if valid_lifecycle_lease "$provider_pid"; then
      log "provider process $provider_pid is inside a validated startup/maintenance lease; watchdog grants bounded grace"
      exit 0
    fi
    armed_boot=""
    if [ -f "$ARMED_FILE" ]; then
      armed_boot="$(cat "$ARMED_FILE" 2>/dev/null || true)"
    fi
    if [ "$armed_boot" != "$boot_id" ]; then
      log "provider process $provider_pid not locally healthy yet; watchdog remains disarmed for boot=${boot_id}"
      exit 0
    fi
    if provider_restart_cooldown_active; then
      exit 0
    fi
    if ! local_status_restart_recommended "$provider_pid"; then
      log "provider process $provider_pid failed local /v1/health after arming, but /v1/status does not recommend watchdog restart; leaving process untouched"
      exit 0
    fi
    log "provider process $provider_pid failed local /v1/health after arming; requesting launchd restart for $LABEL"
    kickstart_provider "local_health_failed_after_arming" || true
    exit 0
  fi
  armed_boot=""
  if [ -f "$ARMED_FILE" ]; then
    armed_boot="$(cat "$ARMED_FILE" 2>/dev/null || true)"
  fi
  if [ "$armed_boot" != "$boot_id" ]; then
    log "arming watchdog (boot=${boot_id}): first observed local provider health"
    printf "%s" "$boot_id" > "$ARMED_FILE"
  fi
  coord_ip="$(resolve_coordinator_ip)"
  if [ -z "$coord_ip" ]; then
    log "warning: DNS resolution for $COORDINATOR_HOST failed; provider process $provider_pid is locally healthy"
    exit 0
  fi
  if has_established_conn "$coord_ip"; then
    # Healthy. Stay silent so the log file does not bloat.
    exit 0
  fi
  log "warning: provider process $provider_pid is locally healthy, but no ESTABLISHED TCP to ${coord_ip}:${COORDINATOR_PORT}"
  # No ESTABLISHED connection. Coordinator TCP state is advisory only:
  # the health verdict is the installed provider process plus local
  # /v1/health. Do not kick solely because another process can or
  # cannot reach the coordinator.
  exit 0
}

main "$@"

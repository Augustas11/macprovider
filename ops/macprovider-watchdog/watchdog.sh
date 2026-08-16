#!/usr/bin/env bash
# macprovider-watchdog: local provider liveness monitor plus
# auto-update rollback observer.
#
# Health verdict: the exact launchd service PID must own the configured local
# listener and its /v1/health endpoint must answer. /v1/health returns non-2xx
# for degraded/draining/unavailable states, so a provider stuck reporting
# unavailable after the watchdog is armed is restartable. Coordinator TCP
# reachability is advisory logging only; a missing ESTABLISHED coordinator
# connection no longer causes a kick by itself.

set -euo pipefail

LABEL="${MACPROVIDER_WATCHDOG_LABEL:-live.malibu.provider}"
CONFIG_PATH="${MACPROVIDER_CONFIG_PATH:-$HOME/.config/macprovider/config.yaml}"
BINARY_PATH="${MACPROVIDER_BINARY_PATH:-$HOME/macprovider/macprovider-cli}"
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
  [ -x "$BINARY_PATH" ] || return 1
  if "$BINARY_PATH" lifecycle-lease status --expected-kind startup --expected-pid "$provider_pid" >/dev/null 2>&1; then
    return 0
  fi
  "$BINARY_PATH" lifecycle-lease status --expected-kind maintenance >/dev/null 2>&1
}

valid_unbound_lifecycle_lease() {
  [ -x "$BINARY_PATH" ] || return 1
  if "$BINARY_PATH" lifecycle-lease status --expected-kind startup >/dev/null 2>&1; then
    return 0
  fi
  "$BINARY_PATH" lifecycle-lease status --expected-kind maintenance >/dev/null 2>&1
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
  AUTUPDATE_STATE_ROOT="${MACPROVIDER_AUTOUPDATE_STATE_ROOT:-$HOME/.local/share/macprovider/autoupdate}" \
  MACPROVIDER_BINARY_PATH="$BINARY_PATH" \
  MACPROVIDER_LABEL="$LABEL" \
  LOG_PATH="$LOG_PATH" \
  python3 <<'PY'
import datetime
import fcntl
import hashlib
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import time
import uuid

root = os.environ["AUTUPDATE_STATE_ROOT"]
binary_path = os.environ["MACPROVIDER_BINARY_PATH"]
label = os.environ["MACPROVIDER_LABEL"]
log_path = os.environ["LOG_PATH"]
pending = os.path.join(root, "pending.json")
lock_path = os.path.join(root, "update.lock")
install_lock_path = os.path.expanduser("~/.config/macprovider/install.lock")
lifecycle_root = os.path.expanduser("~/Library/Application Support/macprovider/lifecycle")
lifecycle_lock_path = os.path.join(lifecycle_root, ".lease.json.lock")
uid = os.getuid()
provider_user = pwd.getpwuid(uid).pw_name
reload_helper_label = "live.malibu.provider-compatibility-reload"
legacy_reload_helper_label = re.compile(
    rf"^{re.escape(reload_helper_label)}\."
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
)
reload_helper_removal_max_checks = 100

class ReloadHelperFenceError(RuntimeError):
    pass

def ts():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def log(message):
    with open(log_path, "a", encoding="utf-8") as fh:
        fh.write(f"[{ts()}] autoupdate {message}\n")

def event(outcome, phase, failure_class, reason, marker=None):
    payload = {
        "event": "provider_autoupdate_watchdog",
        "source": "coordinator",
        "outcome": outcome,
        "phase": phase,
        "reason": reason,
        "timestamp": ts(),
    }
    if failure_class:
        payload["failure_class"] = failure_class
    if marker:
        payload["update_id"] = marker.get("update_id", "")
        payload["target_version"] = marker.get("target_version", "")
    log(json.dumps(payload, sort_keys=True, separators=(",", ":")))

def fence_reload_helpers():
    try:
        listed = subprocess.run(
            ["launchctl", "list"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
        )
    except Exception as exc:
        raise ReloadHelperFenceError(f"reload_helper_list_failed:{type(exc).__name__}") from exc
    if listed.returncode != 0:
        raise ReloadHelperFenceError(f"reload_helper_list_failed:{listed.returncode}")
    labels = set()
    for line in listed.stdout.splitlines():
        fields = line.split(None, 2)
        if len(fields) != 3:
            continue
        candidate = fields[2]
        if candidate == reload_helper_label or legacy_reload_helper_label.fullmatch(candidate):
            labels.add(candidate)
    labels.add(reload_helper_label)
    ordered_labels = [reload_helper_label] + sorted(labels - {reload_helper_label})
    domain = f"gui/{uid}"
    for helper_label in ordered_labels:
        try:
            subprocess.run(
                ["launchctl", "bootout", f"{domain}/{helper_label}"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
            )
        except Exception as exc:
            raise ReloadHelperFenceError(
                f"reload_helper_bootout_failed:{helper_label}:{type(exc).__name__}"
            ) from exc
        absent = False
        for attempt in range(reload_helper_removal_max_checks):
            try:
                inspected = subprocess.run(
                    ["launchctl", "print", f"{domain}/{helper_label}"],
                    check=False,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    timeout=5,
                )
            except Exception as exc:
                raise ReloadHelperFenceError(
                    f"reload_helper_inspection_failed:{helper_label}:{type(exc).__name__}"
                ) from exc
            if (
                inspected.returncode == 113
                and "Could not find service" in inspected.stdout
            ):
                absent = True
                break
            if inspected.returncode != 0:
                raise ReloadHelperFenceError(
                    f"reload_helper_inspection_failed:{helper_label}:{inspected.returncode}"
                )
            if attempt + 1 < reload_helper_removal_max_checks:
                time.sleep(0.1)
        if not absent:
            raise ReloadHelperFenceError(f"reload_helper_removal_timeout:{helper_label}")
    launch_agents = os.path.expanduser("~/Library/LaunchAgents")
    for helper_label in ordered_labels:
        helper_plist = os.path.join(launch_agents, f"{helper_label}.plist")
        if not os.path.lexists(helper_plist):
            continue
        if os.path.isdir(helper_plist) and not os.path.islink(helper_plist):
            raise ReloadHelperFenceError(f"reload_helper_plist_not_file:{helper_label}")
        try:
            os.unlink(helper_plist)
        except Exception as exc:
            raise ReloadHelperFenceError(
                f"reload_helper_plist_remove_failed:{helper_label}:{type(exc).__name__}"
            ) from exc

def record_watchdog_recovery(marker, failure_class):
    target = marker["target_path"]
    reason_code = f"watchdog_rollback_{failure_class}"
    operation_id = f"watchdog-recovery:{marker['update_id']}"
    command = [
        target,
        "lifecycle-state",
        "transition",
        "--state",
        "watchdog_recovery",
        "--reason-code",
        reason_code,
        "--writer",
        "watchdog",
        "--operation-id",
        operation_id,
    ]
    compatibility_id = marker.get("previous_compatibility_set_id") or marker.get("target_compatibility_set_id")
    if compatibility_id:
        command.extend(["--compatibility-set-id", compatibility_id])
    try:
        result = subprocess.run(
            command,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
        if result.returncode == 0:
            log(f"lifecycle_transition=watchdog_recovery reason_code={reason_code} operation_id={operation_id}")
        else:
            log(f"lifecycle_transition_failed=watchdog_recovery exit_status={result.returncode}")
    except Exception as exc:
        log(f"lifecycle_transition_failed=watchdog_recovery error={type(exc).__name__}")

def reject_path(path, must_exist=True):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        if must_exist:
            raise
        return None
    if stat.S_ISLNK(st.st_mode):
        raise RuntimeError(f"symlink_rejected:{path}")
    if st.st_uid != uid:
        raise RuntimeError(f"owner_rejected:{path}")
    if st.st_nlink != 1 and not stat.S_ISDIR(st.st_mode):
        raise RuntimeError(f"hardlink_rejected:{path}")
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise RuntimeError(f"writable_rejected:{path}")
    try:
        acl = subprocess.run(["/bin/ls", "-le", path], check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        for line in acl.stdout.splitlines():
            stripped = line.strip().lower()
            if not re.match(r"^[0-9]+:", stripped):
                continue
            if ("write" in stripped or "append" in stripped or "add_file" in stripped) and f"user:{provider_user.lower()}" not in stripped:
                raise RuntimeError(f"acl_write_rejected:{path}")
    except FileNotFoundError:
        pass
    return st

def verify_root():
    current = root
    parts = []
    while True:
        parts.append(current)
        parent = os.path.dirname(current)
        if parent == current or current == os.path.expanduser("~"):
            break
        current = parent
    for path in reversed(parts):
        if os.path.exists(path):
            st = reject_path(path)
            if not stat.S_ISDIR(st.st_mode):
                raise RuntimeError(f"not_directory:{path}")

def read_marker():
    fd = os.open(pending, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        raw = os.read(fd, 65536)
    finally:
        os.close(fd)
    marker = json.loads(raw.decode("utf-8"))
    validate_marker_strict(marker)
    return marker

def validate_marker_strict(marker):
    required = {"update_id", "target_version", "target_path", "backup_path", "size", "mode", "sha256", "marker_deadline"}
    if not required.issubset(marker.keys()):
        raise RuntimeError("marker_missing_required_fields")
    if not re.match(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", str(marker["update_id"])):
        raise RuntimeError("marker_update_id_invalid")
    if not re.match(r"^[0-9]+\.[0-9]+\.[0-9]+$", str(marker["target_version"])):
        raise RuntimeError("marker_target_version_invalid")
    for key in ("target_path", "backup_path"):
        value = str(marker[key])
        if not os.path.isabs(value) or value.endswith("/") or "/../" in value or "/./" in value:
            raise RuntimeError(f"marker_{key}_invalid")
    size = int(marker["size"])
    mode = int(marker["mode"])
    if size < 0 or size > 1024 * 1024 * 1024:
        raise RuntimeError("marker_size_invalid")
    if mode < 0 or mode > 0o7777:
        raise RuntimeError("marker_mode_invalid")
    if not re.match(r"^[0-9a-f]{64}$", str(marker["sha256"])):
        raise RuntimeError("marker_sha256_invalid")
    release_backup = marker.get("release_backup_path")
    release_sha = marker.get("release_backup_sha256")
    if (release_backup is None) != (release_sha is None):
        raise RuntimeError("marker_release_backup_incomplete")
    if release_backup is not None:
        value = str(release_backup)
        if not os.path.isabs(value) or value.endswith("/") or "/../" in value or "/./" in value:
            raise RuntimeError("marker_release_backup_path_invalid")
        if not re.match(r"^[0-9a-f]{64}$", str(release_sha)):
            raise RuntimeError("marker_release_backup_sha256_invalid")
    compatibility_id = marker.get("target_compatibility_set_id")
    compatibility_sha = marker.get("target_compatibility_set_sha256")
    if (compatibility_id is None) != (compatibility_sha is None):
        raise RuntimeError("marker_compatibility_set_incomplete")
    if compatibility_id is not None:
        if not isinstance(compatibility_id, str) or not compatibility_id or compatibility_id.strip() != compatibility_id or len(compatibility_id.encode("utf-8")) > 512:
            raise RuntimeError("marker_compatibility_set_id_invalid")
        if not re.match(r"^[0-9a-f]{64}$", str(compatibility_sha)):
            raise RuntimeError("marker_compatibility_set_sha256_invalid")
    previous_fields = (
        marker.get("previous_version"),
        marker.get("previous_compatibility_set_id"),
        marker.get("previous_compatibility_set_sha256"),
        marker.get("transaction_state"),
    )
    if any(value is not None for value in previous_fields):
        if any(value is None for value in previous_fields):
            raise RuntimeError("marker_previous_compatibility_set_incomplete")
        previous_version, previous_id, previous_sha, transaction_state = previous_fields
        if compatibility_id is None or release_backup is None:
            raise RuntimeError("marker_previous_compatibility_set_unbound")
        if not re.match(r"^[0-9]+\.[0-9]+\.[0-9]+$", str(previous_version)):
            raise RuntimeError("marker_previous_version_invalid")
        if not re.match(
            r"^[A-Za-z0-9_.-]{1,64}/[A-Za-z0-9_.-]{1,100}:v[0-9]+\.[0-9]+\.[0-9]+@[0-9a-f]{40}$",
            str(previous_id),
        ):
            raise RuntimeError("marker_previous_compatibility_set_id_invalid")
        if not re.match(r"^[0-9a-f]{64}$", str(previous_sha)):
            raise RuntimeError("marker_previous_compatibility_set_sha256_invalid")
        if transaction_state not in {
            "activating_target",
            "restoring_previous",
            "awaiting_previous_readiness",
        }:
            raise RuntimeError("marker_transaction_state_invalid")
    raw_deadline = str(marker["marker_deadline"])
    if not raw_deadline.endswith("Z"):
        raise RuntimeError("marker_deadline_invalid")
    try:
        deadline = datetime.datetime.strptime(raw_deadline, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        raise RuntimeError("marker_deadline_invalid")
    now = datetime.datetime.now(datetime.timezone.utc)
    post_start_window = 60
    future_tolerance = post_start_window + 30 * 60
    if deadline > now + datetime.timedelta(seconds=future_tolerance):
        raise RuntimeError("marker_deadline_out_of_bounds")

def current_binary_version(path):
    try:
        result = subprocess.run([path, "--version"], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
    except Exception:
        return ""
    output = f"{result.stdout}\n{result.stderr}"
    match = re.search(r"([0-9]+(?:\.[0-9]+){2}(?:[-+][0-9A-Za-z.-]+)?)", output)
    return match.group(1) if match else ""

def read_success_sentinel(path):
    reject_path(path)
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        payload = json.loads(os.read(fd, 65536).decode("utf-8"))
    finally:
        os.close(fd)
    update_id = str(payload.get("update_id", ""))
    if not re.match(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", update_id):
        raise RuntimeError("sentinel_update_id_invalid")
    return {
        "update_id": update_id,
        "binary_version": str(payload.get("binary_version", "")),
    }

def process_success_sentinel(marker):
    if marker.get("transaction_state") in {
        "restoring_previous",
        "awaiting_previous_readiness",
    }:
        return False
    binary_dir = os.path.dirname(marker["target_path"])
    for name in os.listdir(binary_dir):
        if not name.startswith(".macprovider-cli.success-"):
            continue
        sentinel = os.path.join(binary_dir, name)
        try:
            validate_restore_inputs(marker)
            payload = read_success_sentinel(sentinel)
            sentinel_version = payload["binary_version"]
            current_version = current_binary_version(marker["target_path"])
            if not sentinel_version or sentinel_version != current_version:
                event("failure", "post_start", "orphaned_success_sentinel", "binary_version_mismatch", {"update_id": payload["update_id"], "target_version": sentinel_version})
                os.unlink(sentinel)
                continue
            if payload["update_id"] != str(marker["update_id"]):
                event("failure", "post_start", "orphaned_success_sentinel", "update_id_mismatch", {"update_id": payload["update_id"], "target_version": sentinel_version})
                os.unlink(sentinel)
                continue
            try:
                os.unlink(pending)
            except FileNotFoundError:
                pass
            try:
                os.unlink(marker["backup_path"])
            except FileNotFoundError:
                pass
            release_backup = marker.get("release_backup_path")
            if release_backup:
                shutil.rmtree(release_backup, ignore_errors=True)
            os.unlink(sentinel)
            event("success", "post_start", None, "success_sentinel_cleanup_completed", marker)
            return True
        except Exception as exc:
            event("failure", "post_start", "orphaned_success_sentinel", str(exc), marker)
            try:
                os.unlink(sentinel)
            except FileNotFoundError:
                pass
    return False

def sha256(path):
    h = hashlib.sha256()
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    finally:
        os.close(fd)
    return h.hexdigest()

def binary_path_without_pending():
    candidate = os.environ.get("MACPROVIDER_BINARY_PATH", "")
    if candidate:
        return candidate
    return shutil.which("macprovider-cli") or ""

def known_binary_dir():
    configured = os.environ.get("MACPROVIDER_BINARY_DIR", "")
    if configured:
        return os.path.realpath(configured)
    plist_path = os.path.expanduser("~/Library/LaunchAgents/live.malibu.provider.plist")
    try:
        result = subprocess.run(
            ["/usr/libexec/PlistBuddy", "-c", "Print ProgramArguments:0", plist_path],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip():
            return os.path.realpath(os.path.dirname(result.stdout.strip()))
    except Exception:
        pass
    binary = binary_path_without_pending()
    if binary:
        return os.path.realpath(os.path.dirname(binary))
    return ""

def scan_without_pending():
    binary = binary_path_without_pending()
    if not binary:
        return
    binary_dir = os.path.dirname(binary)
    for name in os.listdir(binary_dir):
        path = os.path.join(binary_dir, name)
        if name.startswith(".macprovider-cli.success-"):
            try:
                payload = read_success_sentinel(path)
                sentinel_version = payload["binary_version"]
                current_version = current_binary_version(binary)
                if sentinel_version and sentinel_version == current_version:
                    os.unlink(path)
                    event("failure", "post_start", "orphaned_success_sentinel", "no_matching_pending", {"update_id": payload["update_id"], "target_version": current_version})
                else:
                    os.unlink(path)
                    event("failure", "post_start", "orphaned_success_sentinel", "binary_version_mismatch", {"update_id": payload["update_id"], "target_version": sentinel_version})
            except Exception as exc:
                log(f"success_sentinel_scan_error={exc}")
        elif name.startswith(".macprovider-cli.rollback-"):
            try:
                os.unlink(path)
                log(f"deleted_stale_backup={path}")
            except FileNotFoundError:
                pass
        elif name.startswith(".macprovider-cli.release-rollback-"):
            shutil.rmtree(path, ignore_errors=True)

def quarantine(reason, marker=None):
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    dest = os.path.join(root, f"pending-quarantined-{stamp}.json")
    try:
        os.replace(pending, dest)
        log(f"pending_marker_quarantined={dest} reason={reason}")
    except FileNotFoundError:
        pass

def marker_deadline_expired(marker):
    raw_deadline = str(marker["marker_deadline"])
    deadline = datetime.datetime.strptime(raw_deadline, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    return datetime.datetime.now(datetime.timezone.utc) >= deadline

def write_marker(marker):
    validate_marker_strict(marker)
    payload = json.dumps(marker, sort_keys=True, separators=(",", ":")).encode("utf-8")
    temporary = os.path.join(root, f".pending-{uuid.uuid4()}.json")
    fd = os.open(
        temporary,
        os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(fd, payload[offset:])
            if written <= 0:
                raise RuntimeError("marker_write_failed")
            offset += written
        os.fchmod(fd, 0o600)
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        os.replace(temporary, pending)
        directory_fd = os.open(root, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise

def transition_marker(marker, state, readiness_seconds=None):
    updated = dict(marker)
    updated["transaction_state"] = state
    if readiness_seconds is not None:
        updated["marker_deadline"] = (
            datetime.datetime.now(datetime.timezone.utc)
            + datetime.timedelta(seconds=readiness_seconds)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
    write_marker(updated)
    return updated

def process_start(pid):
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return ""
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "lstart="],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else ""

def boot_session():
    try:
        result = subprocess.run(
            ["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        value = result.stdout.strip()
        if value:
            return value
    except FileNotFoundError:
        pass
    try:
        with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as handle:
            return handle.read().strip()
    except OSError:
        return ""

def normalize_lock_fd(fd, path):
    info = os.fstat(fd)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != uid
        or info.st_nlink != 1
        or stat.S_IMODE(info.st_mode) & 0o077
    ):
        raise RuntimeError(f"mutation_lock_invalid:{path}")
    os.fchmod(fd, 0o600)
    if stat.S_IMODE(os.fstat(fd).st_mode) != 0o600:
        raise RuntimeError(f"mutation_lock_mode_invalid:{path}")

def acquire_lifecycle_lock():
    os.makedirs(lifecycle_root, mode=0o700, exist_ok=True)
    directory_st = reject_path(lifecycle_root)
    if not stat.S_ISDIR(directory_st.st_mode) or stat.S_IMODE(directory_st.st_mode) != 0o700:
        raise RuntimeError("lifecycle_lease_directory_invalid")
    fd = os.open(
        lifecycle_lock_path,
        os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        path_st = reject_path(lifecycle_lock_path)
        descriptor_st = os.fstat(fd)
        if (
            not stat.S_ISREG(descriptor_st.st_mode)
            or descriptor_st.st_uid != uid
            or descriptor_st.st_nlink != 1
            or stat.S_IMODE(descriptor_st.st_mode) != 0o600
            or (descriptor_st.st_dev, descriptor_st.st_ino) != (path_st.st_dev, path_st.st_ino)
        ):
            raise RuntimeError("lifecycle_lease_lock_invalid")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            return None
        return fd
    except Exception:
        os.close(fd)
        raise

def inspect_lifecycle_lease():
    if not os.path.isfile(binary_path) or not os.access(binary_path, os.X_OK):
        return None
    try:
        result = subprocess.run(
            [binary_path, "lifecycle-lease", "status"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    kind = payload.get("kind")
    owner_pid = payload.get("owner_pid")
    if (
        payload.get("state") != "valid"
        or kind not in {"startup", "maintenance"}
        or not isinstance(owner_pid, int)
        or isinstance(owner_pid, bool)
        or owner_pid <= 0
    ):
        return None
    return {"kind": kind, "owner_pid": owner_pid}

def launchd_provider_pid():
    launchctl = os.environ.get("MACPROVIDER_LAUNCHCTL", "launchctl")
    try:
        result = subprocess.run(
            [launchctl, "print", f"gui/{uid}/{label}"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )
    except Exception:
        return None
    if result.returncode != 0:
        return None
    candidates = re.findall(r"^\s*pid\s*=\s*([0-9]+)\s*$", result.stdout, re.MULTILINE)
    if len(candidates) != 1:
        return None
    return int(candidates[0])

def installer_owner_is_live(lock_fd):
    os.lseek(lock_fd, 0, os.SEEK_SET)
    payload = os.read(lock_fd, 4097)
    if len(payload) > 4096:
        raise RuntimeError("installer_owner_record_oversized")
    if not payload.strip():
        return False
    try:
        record = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError("installer_owner_record_invalid") from exc
    if not isinstance(record, dict):
        raise RuntimeError("installer_owner_record_invalid")
    owner_pid = record.get("pid")
    owner_start = record.get("process_start")
    owner_boot = record.get("boot_session")
    if (
        not isinstance(owner_pid, int)
        or isinstance(owner_pid, bool)
        or owner_pid <= 0
        or not isinstance(owner_start, str)
        or not owner_start
        or not isinstance(owner_boot, str)
        or not owner_boot
    ):
        raise RuntimeError("installer_owner_record_invalid")
    current_boot = boot_session()
    if not current_boot:
        raise RuntimeError("installer_owner_boot_identity_unavailable")
    return owner_boot == current_boot and process_start(owner_pid) == owner_start

def release_transaction_locks(descriptors):
    for descriptor in reversed(descriptors):
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)

def acquire_transaction_locks():
    os.makedirs(root, mode=0o700, exist_ok=True)
    os.makedirs(os.path.dirname(install_lock_path), mode=0o700, exist_ok=True)
    descriptors = []
    for path in (install_lock_path, lock_path):
        fd = os.open(path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            normalize_lock_fd(fd, path)
        except Exception:
            os.close(fd)
            release_transaction_locks(descriptors)
            raise
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            release_transaction_locks(descriptors)
            return None
        descriptors.append(fd)
        try:
            owner_live = installer_owner_is_live(descriptors[0])
        except Exception:
            release_transaction_locks(descriptors)
            raise
        if owner_live:
            release_transaction_locks(descriptors)
            return None
    return descriptors

def validate_restore_inputs(marker):
    backup = marker["backup_path"]
    target = marker["target_path"]
    update_id = marker["update_id"]
    expected_backup = os.path.join(os.path.dirname(target), f".macprovider-cli.rollback-{update_id}")
    if backup != expected_backup:
        raise RuntimeError("backup_path_derivation_mismatch")
    trusted_dir = known_binary_dir()
    if not trusted_dir:
        raise RuntimeError("unsupported_install_topology:binary_dir_unknown")
    target_parent = os.path.realpath(os.path.dirname(target))
    backup_parent = os.path.realpath(os.path.dirname(backup))
    if target_parent != trusted_dir or backup_parent != trusted_dir:
        raise RuntimeError("unsupported_install_topology:path_outside_binary_dir")
    for checked in (target, backup):
        cursor = checked
        while os.path.realpath(os.path.dirname(cursor)) == trusted_dir and cursor != trusted_dir:
            reject_path(cursor, must_exist=os.path.exists(cursor))
            break
    backup_st = reject_path(backup)
    reject_path(os.path.dirname(target))
    if not os.path.isabs(target) or target.endswith("/"):
        raise RuntimeError("target_path_invalid")
    if backup_st.st_size != int(marker["size"]):
        raise RuntimeError("backup_size_mismatch")
    if sha256(backup) != str(marker["sha256"]):
        raise RuntimeError("backup_sha256_mismatch")
    release_backup = marker.get("release_backup_path")
    if release_backup:
        expected_release_backup = os.path.join(os.path.dirname(target), f".macprovider-cli.release-rollback-{update_id}")
        if release_backup != expected_release_backup:
            raise RuntimeError("release_backup_path_derivation_mismatch")
        if os.path.realpath(os.path.dirname(release_backup)) != trusted_dir:
            raise RuntimeError("unsupported_install_topology:release_backup_outside_binary_dir")
        release_st = reject_path(release_backup)
        if not stat.S_ISDIR(release_st.st_mode):
            raise RuntimeError("release_backup_not_directory")
        allowed = lambda name: name in {"mlx.metallib", "THIRD-PARTY-NOTICES.txt", "compatibility-set.json", "compatibility-set-local", "catalog-release", "external-local-members", "Malibu.app.zip", "malibu-app-state.json"} or name.endswith(".bundle")
        if any(not allowed(name) for name in os.listdir(release_backup)):
            raise RuntimeError("release_backup_unexpected_entry")
        if release_tree_sha256(release_backup) != str(marker["release_backup_sha256"]):
            raise RuntimeError("release_backup_sha256_mismatch")
        external_backup = os.path.join(release_backup, "external-local-members")
        if os.path.exists(external_backup):
            validate_external_local_backup(external_backup)
        validate_malibu_app_backup(release_backup)
    return backup, target, release_backup

def release_tree_sha256(root_path):
    records = []
    for current, directory_names, file_names in os.walk(root_path, topdown=True, followlinks=False):
        directory_names.sort()
        file_names.sort()
        for name in directory_names + file_names:
            path = os.path.join(current, name)
            item_st = reject_path(path)
            relative = os.path.relpath(path, root_path)
            if "\x00" in relative or "\n" in relative or relative == ".." or relative.startswith("../"):
                raise RuntimeError("release_tree_path_invalid")
            mode = stat.S_IMODE(item_st.st_mode)
            if stat.S_ISDIR(item_st.st_mode):
                record = f"d\0{relative}\0{mode}\0"
            elif stat.S_ISREG(item_st.st_mode):
                record = f"f\0{relative}\0{mode}\0{item_st.st_size}\0{sha256(path)}\0"
            else:
                raise RuntimeError("release_tree_entry_invalid")
            records.append((relative, record.encode("utf-8")))
    digest = hashlib.sha256()
    for _, record in sorted(records, key=lambda item: item[0]):
        digest.update(record)
    return digest.hexdigest()

def owned_release_resource(name):
    return name in {"mlx.metallib", "THIRD-PARTY-NOTICES.txt", "compatibility-set.json", "compatibility-set-local", "catalog-release"} or name.endswith(".bundle")

def external_local_members():
    home = os.path.expanduser("~")
    return [
        ("launchd", os.path.join(home, "Library/LaunchAgents/live.malibu.provider.plist"), "provider.plist"),
        ("watchdog_script", os.path.join(home, ".local/share/macprovider-watchdog/macprovider-health-monitor"), "watchdog.sh"),
        ("watchdog_plist", os.path.join(home, "Library/LaunchAgents/live.malibu.provider-watchdog.plist"), "watchdog.plist"),
    ]

def validate_external_local_backup(backup_directory):
    reject_path(backup_directory)
    state_path = os.path.join(backup_directory, "state.json")
    reject_path(state_path)
    with open(state_path, "r", encoding="utf-8") as handle:
        state = json.load(handle)
    if set(state) != {"schema_version", "members"} or state["schema_version"] != 1 or not isinstance(state["members"], list):
        raise RuntimeError("external_backup_state_invalid")
    expected = external_local_members()
    if [record.get("member") for record in state["members"]] != [member[0] for member in expected]:
        raise RuntimeError("external_backup_members_invalid")
    expected_names = {"state.json"}
    for record, (_, _, backup_name) in zip(state["members"], expected):
        present = record.get("was_present")
        if not isinstance(present, bool):
            raise RuntimeError("external_backup_presence_invalid")
        backup_path = os.path.join(backup_directory, backup_name)
        if present:
            if set(record) != {"member", "mode", "sha256", "was_present"}:
                raise RuntimeError("external_backup_record_invalid")
            mode = record.get("mode")
            digest = record.get("sha256")
            if not isinstance(mode, int) or isinstance(mode, bool) or mode < 0 or mode > 0o7777:
                raise RuntimeError("external_backup_mode_invalid")
            if not isinstance(digest, str) or not re.match(r"^[0-9a-f]{64}$", digest):
                raise RuntimeError("external_backup_sha256_invalid")
            backup_st = reject_path(backup_path)
            if not stat.S_ISREG(backup_st.st_mode) or stat.S_IMODE(backup_st.st_mode) != mode or sha256(backup_path) != digest:
                raise RuntimeError("external_backup_file_invalid")
            expected_names.add(backup_name)
        elif set(record) != {"member", "was_present"} or os.path.exists(backup_path):
            raise RuntimeError("external_backup_absence_invalid")
    if set(os.listdir(backup_directory)) != expected_names:
        raise RuntimeError("external_backup_unexpected_entry")
    return state

def restore_external_local_members(release_backup):
    backup_directory = os.path.join(release_backup, "external-local-members")
    if not os.path.exists(backup_directory):
        return
    state = validate_external_local_backup(backup_directory)
    for record, (_, target, backup_name) in zip(state["members"], external_local_members()):
        os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
        reject_path(os.path.dirname(target))
        if record["was_present"]:
            atomic_copy_binary(os.path.join(backup_directory, backup_name), target, int(record["mode"]))
        elif os.path.exists(target):
            target_st = reject_path(target)
            if not stat.S_ISREG(target_st.st_mode):
                raise RuntimeError("external_restore_target_invalid")
            os.unlink(target)

def validate_malibu_app_backup(release_backup):
    archive = os.path.join(release_backup, "Malibu.app.zip")
    state_path = os.path.join(release_backup, "malibu-app-state.json")
    archive_exists = os.path.exists(archive)
    state_exists = os.path.exists(state_path)
    if archive_exists != state_exists:
        raise RuntimeError("malibu_backup_incomplete")
    if not state_exists:
        return None
    archive_st = reject_path(archive)
    state_st = reject_path(state_path)
    if not stat.S_ISREG(archive_st.st_mode) or not stat.S_ISREG(state_st.st_mode):
        raise RuntimeError("malibu_backup_not_regular")
    fd = os.open(state_path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        raw = os.read(fd, 65537)
    finally:
        os.close(fd)
    if len(raw) > 65536:
        raise RuntimeError("malibu_backup_state_oversized")
    try:
        record = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError("malibu_backup_state_invalid") from exc
    if set(record) != {"archive_sha256", "schema_version", "target_path"} or record["schema_version"] != 1:
        raise RuntimeError("malibu_backup_state_invalid")
    target = record.get("target_path")
    candidates = {
        "/Applications/Malibu.app",
        os.path.normpath(os.path.join(os.path.expanduser("~"), "Applications/Malibu.app")),
    }
    if target not in candidates or os.path.normpath(target) != target:
        raise RuntimeError("malibu_backup_target_invalid")
    digest = record.get("archive_sha256")
    if not isinstance(digest, str) or not re.match(r"^[0-9a-f]{64}$", digest) or sha256(archive) != digest:
        raise RuntimeError("malibu_backup_sha256_mismatch")
    return record

def validate_extracted_malibu_app(app):
    app_st = reject_path(app)
    if not stat.S_ISDIR(app_st.st_mode) or os.path.basename(app) != "Malibu.app":
        raise RuntimeError("malibu_restored_bundle_invalid")
    for current, directory_names, file_names in os.walk(app, topdown=True, followlinks=False):
        reject_path(current)
        for name in directory_names + file_names:
            reject_path(os.path.join(current, name))
    info_plist = os.path.join(app, "Contents", "Info.plist")
    info_st = reject_path(info_plist)
    if not stat.S_ISREG(info_st.st_mode):
        raise RuntimeError("malibu_restored_bundle_invalid")

def restore_malibu_app_if_present(release_backup):
    record = validate_malibu_app_backup(release_backup)
    if record is None:
        return
    target = record["target_path"]
    parent = os.path.dirname(target)
    parent_st = reject_path(parent)
    if not stat.S_ISDIR(parent_st.st_mode) or not os.access(parent, os.W_OK):
        raise RuntimeError("malibu_restore_parent_unwritable")
    extraction = os.path.join(parent, f".malibu-rollback-extract-{uuid.uuid4()}")
    displaced = os.path.join(parent, f".Malibu.app.rollback-displaced-{uuid.uuid4()}")
    os.mkdir(extraction, 0o700)
    target_displaced = False
    try:
        ditto = os.environ.get("MACPROVIDER_DITTO", "/usr/bin/ditto")
        result = subprocess.run(
            [ditto, "-x", "-k", os.path.join(release_backup, "Malibu.app.zip"), extraction],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=120,
        )
        if result.returncode != 0:
            raise RuntimeError("malibu_backup_extract_failed")
        entries = os.listdir(extraction)
        if entries != ["Malibu.app"]:
            raise RuntimeError("malibu_backup_archive_shape_invalid")
        restored = os.path.join(extraction, "Malibu.app")
        validate_extracted_malibu_app(restored)
        if os.path.exists(target):
            reject_path(target)
            os.replace(target, displaced)
            target_displaced = True
        try:
            os.replace(restored, target)
        except Exception:
            if target_displaced and not os.path.exists(target):
                os.replace(displaced, target)
                target_displaced = False
            raise
        parent_fd = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
        if target_displaced:
            shutil.rmtree(displaced)
            target_displaced = False
    finally:
        shutil.rmtree(extraction, ignore_errors=True)
        if target_displaced and not os.path.exists(target) and os.path.exists(displaced):
            os.replace(displaced, target)
        elif os.path.exists(displaced):
            shutil.rmtree(displaced, ignore_errors=True)

def copy_release_resources(source, destination):
    for name in os.listdir(source):
        if name in {"external-local-members", "Malibu.app.zip", "malibu-app-state.json"}:
            continue
        if not owned_release_resource(name):
            raise RuntimeError("release_backup_unexpected_entry")
        source_path = os.path.join(source, name)
        destination_path = os.path.join(destination, name)
        if os.path.isdir(source_path):
            shutil.copytree(source_path, destination_path, symlinks=False, copy_function=shutil.copy2)
        else:
            shutil.copy2(source_path, destination_path, follow_symlinks=False)

def fsync_release_tree(root_path):
    directories = []
    for current, directory_names, file_names in os.walk(root_path, topdown=True, followlinks=False):
        directories.append(current)
        for name in file_names:
            path = os.path.join(current, name)
            fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
    for path in reversed(directories):
        fd = os.open(path, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

def atomic_copy_binary(source, target, mode):
    temporary = os.path.join(os.path.dirname(target), f".macprovider-cli.rollback-restore-{uuid.uuid4()}")
    try:
        source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
        try:
            destination_fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0), mode)
            try:
                while True:
                    chunk = os.read(source_fd, 1024 * 1024)
                    if not chunk:
                        break
                    offset = 0
                    while offset < len(chunk):
                        written = os.write(destination_fd, chunk[offset:])
                        if written <= 0:
                            raise RuntimeError("rollback_binary_write_failed")
                        offset += written
                os.fchmod(destination_fd, mode)
                os.fsync(destination_fd)
            finally:
                os.close(destination_fd)
        finally:
            os.close(source_fd)
        os.replace(temporary, target)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise

def restore(marker, failure_class):
    backup, target, release_backup = validate_restore_inputs(marker)
    fence_reload_helpers()
    exact_compatibility_transaction = marker.get("transaction_state") is not None
    if exact_compatibility_transaction and marker.get("transaction_state") != "restoring_previous":
        marker = transition_marker(marker, "restoring_previous")
    target_directory = os.path.dirname(target)
    if release_backup:
        staging = os.path.join(target_directory, f".macprovider-cli.release-restore-{uuid.uuid4()}")
        os.mkdir(staging, 0o700)
        try:
            copy_release_resources(release_backup, staging)
            fsync_release_tree(staging)
            for name in os.listdir(target_directory):
                if not owned_release_resource(name):
                    continue
                live_path = os.path.join(target_directory, name)
                if os.path.isdir(live_path):
                    shutil.rmtree(live_path)
                else:
                    os.unlink(live_path)
            for name in os.listdir(staging):
                os.replace(os.path.join(staging, name), os.path.join(target_directory, name))
        finally:
            shutil.rmtree(staging, ignore_errors=True)
        restore_external_local_members(release_backup)
        restore_malibu_app_if_present(release_backup)
    atomic_copy_binary(backup, target, int(marker["mode"]))
    dir_fd = os.open(os.path.dirname(target), os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
    # The newly restored prior release is the only executable trusted to
    # author the watchdog transition. This is best effort for legacy rollback
    # binaries that predate lifecycle-state; recovery itself must still run.
    record_watchdog_recovery(marker, failure_class)
    try:
        bootstrap = subprocess.run(
            ["launchctl", "bootstrap", f"gui/{uid}", os.path.expanduser("~/Library/LaunchAgents/live.malibu.provider.plist")],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
        if bootstrap.returncode != 0:
            loaded = subprocess.run(
                ["launchctl", "print", f"gui/{uid}/{label}"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
            )
            if loaded.returncode != 0:
                raise RuntimeError(f"bootstrap_failed:{bootstrap.returncode}")
        kickstart = subprocess.run(
            ["launchctl", "kickstart", "-k", f"gui/{uid}/{label}"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
        if kickstart.returncode != 0:
            raise RuntimeError(f"kickstart_failed:{kickstart.returncode}")
    except Exception as exc:
        log(f"launchctl_restore_warning={exc}")
        event(
            "failure",
            "rollback",
            failure_class,
            "restored_release_restart_deferred",
            marker,
        )
        return
    reason = "restored_prior_release" if release_backup else "restored_prior_binary"
    if exact_compatibility_transaction:
        marker = transition_marker(marker, "awaiting_previous_readiness", readiness_seconds=300)
        event(
            "in_progress",
            "rollback",
            failure_class,
            f"{reason}_awaiting_buyer_serving",
            marker,
        )
        return
    try:
        os.unlink(pending)
    except FileNotFoundError:
        pass
    try:
        os.unlink(backup)
    except FileNotFoundError:
        pass
    if release_backup:
        shutil.rmtree(release_backup, ignore_errors=True)
    event("failure", "rollback", failure_class, reason, marker)

def keep_previous_readiness_recovery_live(marker):
    validate_restore_inputs(marker)
    current_version = current_binary_version(marker["target_path"])
    if current_version != str(marker["previous_version"]):
        restore(marker, "previous_release_version_mismatch")
        return
    try:
        subprocess.run(
            ["launchctl", "kickstart", "-k", f"gui/{uid}/{label}"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
    except Exception as exc:
        log(f"launchctl_previous_readiness_warning={exc}")
    marker = transition_marker(marker, "awaiting_previous_readiness", readiness_seconds=300)
    event(
        "in_progress",
        "rollback",
        "previous_set_readiness_pending",
        "previous_release_still_awaiting_buyer_serving",
        marker,
    )

def classify_post_start_failure(marker):
    try:
        printed = subprocess.run(["launchctl", "print", f"gui/{uid}/{label}"], check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=5).stdout.lower()
        if "last exit status" in printed and not re.search(r"last exit status\s*=\s*0", printed):
            return "post_start_crash"
        if "pid =" not in printed:
            return "post_start_crash"
    except Exception:
        return "post_start_crash"
    health_url = os.environ.get("MACPROVIDER_HEALTHCHECK_URL", "")
    if health_url:
        try:
            curl = os.environ.get("MACPROVIDER_CURL", "/usr/bin/curl")
            probe = subprocess.run([curl, "-fsS", "--max-time", "2", health_url], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if probe.returncode != 0:
                return "post_start_health_failed"
        except Exception:
            return "post_start_health_failed"
    current_version = current_binary_version(marker["target_path"])
    if current_version and current_version != str(marker["target_version"]):
        return "post_start_rejoin_timeout"
    return "post_start_rejoin_timeout"

transaction_locks = []
lifecycle_lock = None
try:
    verify_root()
    lifecycle_lock = acquire_lifecycle_lock()
    if lifecycle_lock is None:
        log("recovery_deferred=lifecycle_lease_lock_contended")
        sys.exit(0)
    acquired = acquire_transaction_locks()
    if acquired is None:
        sys.exit(0)
    transaction_locks = acquired
    lease = inspect_lifecycle_lease()
    prevalidated_marker = None
    if lease is not None:
        if lease["kind"] == "maintenance":
            log(f"recovery_deferred=validated_maintenance_lease owner_pid={lease['owner_pid']}")
            sys.exit(0)
        if not os.path.exists(pending):
            log(f"recovery_deferred=validated_startup_lease owner_pid={lease['owner_pid']}")
            sys.exit(0)
        try:
            reject_path(pending)
            prevalidated_marker = read_marker()
        except Exception:
            log(f"recovery_deferred=validated_startup_lease owner_pid={lease['owner_pid']}")
            sys.exit(0)
        provider_pid = launchd_provider_pid()
        if not marker_deadline_expired(prevalidated_marker) or provider_pid != lease["owner_pid"]:
            log(f"recovery_deferred=validated_unrelated_startup_lease owner_pid={lease['owner_pid']}")
            sys.exit(0)
        log(f"recovery_continuing=expired_autoupdate_startup owner_pid={lease['owner_pid']}")
    if not os.path.exists(pending):
        scan_without_pending()
        sys.exit(0)
    reject_path(pending)
    marker = prevalidated_marker
    if marker is None:
        try:
            marker = read_marker()
        except Exception as exc:
            event("failure", "rollback", "orphaned_pending_marker", "marker_invalid", None)
            quarantine(f"marker_invalid:{exc}", None)
            sys.exit(0)
    if process_success_sentinel(marker):
        sys.exit(0)
    if not marker_deadline_expired(marker):
        log("pending_marker_still_inside_post_start_window")
        sys.exit(0)
    try:
        if marker.get("transaction_state") == "awaiting_previous_readiness":
            keep_previous_readiness_recovery_live(marker)
            sys.exit(0)
        failure_class = classify_post_start_failure(marker)
        restore(marker, failure_class)
    except ReloadHelperFenceError as exc:
        event("failure", "rollback", "other", str(exc), marker)
        log(f"recovery_deferred={exc}")
    except Exception as exc:
        unsupported_topology = str(exc).startswith("unsupported_install_topology")
        failure_class = "other" if unsupported_topology else "rollback_backup_corrupt"
        reason = "unsupported_install_topology" if unsupported_topology else str(exc)
        event("failure", "rollback", failure_class, reason, marker)
        quarantine(str(exc), marker)
except Exception as exc:
    log(f"recovery_error={exc}")
finally:
    for descriptor in reversed(transaction_locks):
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)
    if lifecycle_lock is not None:
        try:
            fcntl.flock(lifecycle_lock, fcntl.LOCK_UN)
        finally:
            os.close(lifecycle_lock)
PY
}

main() {
  autoupdate_recovery_tick
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
    log "arming watchdog (boot=${boot_id}): first observed local provider health for provider_id=${pid}"
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
  log "warning: provider process $provider_pid is locally healthy, but no ESTABLISHED TCP to ${coord_ip}:${COORDINATOR_PORT} for provider_id=${pid}"
  # No ESTABLISHED connection. Coordinator TCP state is advisory only:
  # the health verdict is the installed provider process plus local
  # /v1/health. Do not kick solely because another process can or
  # cannot reach the coordinator.
  exit 0
}

main "$@"

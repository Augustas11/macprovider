#!/usr/bin/env bash
# macprovider-watchdog: operator-visibility insurance against silent WS
# disconnection of the local provider, the symptom described in
# GitHub issue #189.
#
# Failure mode it catches: process up, listening on its local
# inference port, but the outbound TCP socket to the coordinator
# has gone half-open and the Swift reconnect loop never re-establishes.
# We detect this via `netstat -an` (BSD form on macOS) — if no
# ESTABLISHED outbound connection exists to coordinator.streamvc.live
# on tcp/443 for `provider_id`'s service, kick the launchd job so
# launchctl restarts the binary.
#
# Companion to the in-process bounded-send + watchdog landed in
# #189 (PR #204). That fix prevents the wedge from happening; this
# script catches it if it happens anyway, until every operator is on
# a binary that includes the Swift fix.

set -euo pipefail

LABEL="${MACPROVIDER_WATCHDOG_LABEL:-live.streamvc.macprovider}"
CONFIG_PATH="${MACPROVIDER_CONFIG_PATH:-$HOME/.config/macprovider/config.yaml}"
COORDINATOR_HOST="${MACPROVIDER_COORDINATOR_HOST:-coordinator.streamvc.live}"
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
# observes at least ONE successful ESTABLISHED connection IN THE
# CURRENT BOOT. The armed marker stores the boot id (kern.boottime
# sec) so a reboot — which restarts the provider into a fresh
# cold-cache model load — re-disarms the watchdog and prevents the
# stale-arming restart loop the R1 fix did not cover (R2 ARCH HIGH).
#
# Grace rule: after we DO kick, we wait at least KICK_GRACE_SECONDS
# before kicking again. This covers the post-kick model-reload
# window without re-triggering on the gap between launchd respawn
# and re-establishing the coordinator socket.
STATE_DIR="${MACPROVIDER_WATCHDOG_STATE_DIR:-$HOME/.local/share/macprovider-watchdog/state}"
ARMED_FILE="$STATE_DIR/armed"
LAST_KICK_FILE="$STATE_DIR/last_kick"
KICK_GRACE_SECONDS="${MACPROVIDER_WATCHDOG_KICK_GRACE_SECONDS:-300}"

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

kick_provider() {
  log "kicking $LABEL via launchctl kickstart -k gui/$UID/$LABEL"
  launchctl kickstart -k "gui/$UID/$LABEL" >> "$LOG_PATH" 2>&1 || \
    log "launchctl kickstart returned non-zero (likely benign — process may already be restarting)"
}

now_epoch() { date -u +%s; }

autoupdate_recovery_tick() {
  AUTUPDATE_STATE_ROOT="${MACPROVIDER_AUTOUPDATE_STATE_ROOT:-$HOME/.local/share/macprovider/autoupdate}" \
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

root = os.environ["AUTUPDATE_STATE_ROOT"]
label = os.environ["MACPROVIDER_LABEL"]
log_path = os.environ["LOG_PATH"]
pending = os.path.join(root, "pending.json")
lock_path = os.path.join(root, "update.lock")
uid = os.getuid()
provider_user = pwd.getpwuid(uid).pw_name

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
    fd = os.open(pending, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
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
    if deadline < now - datetime.timedelta(seconds=300) or deadline > now + datetime.timedelta(seconds=future_tolerance):
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
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
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
    binary_dir = os.path.dirname(marker["target_path"])
    for name in os.listdir(binary_dir):
        if not name.startswith(".macprovider-cli.success-"):
            continue
        sentinel = os.path.join(binary_dir, name)
        try:
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
            try:
                os.unlink(lock_path)
            except FileNotFoundError:
                pass
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
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
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
    plist_path = os.path.expanduser("~/Library/LaunchAgents/live.streamvc.macprovider.plist")
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

def lock_is_held_by_other_process():
    os.makedirs(root, mode=0o700, exist_ok=True)
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        return False
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(fd)

def restore(marker):
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
    os.chmod(backup, int(marker["mode"]))
    os.replace(backup, target)
    dir_fd = os.open(os.path.dirname(target), os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
    try:
        subprocess.run(["launchctl", "bootstrap", f"gui/{uid}", os.path.expanduser("~/Library/LaunchAgents/live.streamvc.macprovider.plist")], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["launchctl", "kickstart", "-k", f"gui/{uid}/{label}"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as exc:
        log(f"launchctl_restore_warning={exc}")
    try:
        os.unlink(pending)
    except FileNotFoundError:
        pass
    try:
        os.unlink(lock_path)
    except FileNotFoundError:
        pass
    event("failure", "rollback", classify_post_start_failure(marker), "restored_prior_binary", marker)

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

try:
    if not os.path.exists(pending):
        scan_without_pending()
        sys.exit(0)
    verify_root()
    reject_path(pending)
    if lock_is_held_by_other_process():
        sys.exit(0)
    try:
        marker = read_marker()
    except Exception as exc:
        event("failure", "rollback", "orphaned_pending_marker", "marker_invalid", None)
        quarantine(f"marker_invalid:{exc}", None)
        try:
            os.unlink(lock_path)
        except FileNotFoundError:
            pass
        sys.exit(0)
    if process_success_sentinel(marker):
        sys.exit(0)
    if not marker_deadline_expired(marker):
        log("pending_marker_still_inside_post_start_window")
        sys.exit(0)
    try:
        restore(marker)
    except Exception as exc:
        unsupported_topology = str(exc).startswith("unsupported_install_topology")
        failure_class = "other" if unsupported_topology else "rollback_backup_corrupt"
        reason = "unsupported_install_topology" if unsupported_topology else str(exc)
        event("failure", "rollback", failure_class, reason, marker)
        quarantine(str(exc), marker)
except Exception as exc:
    log(f"recovery_error={exc}")
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
  coord_ip="$(resolve_coordinator_ip)"
  if [ -z "$coord_ip" ]; then
    log "DNS resolution for $COORDINATOR_HOST failed; skipping this tick"
    exit 0
  fi
  boot_id="$(current_boot_id)"
  if has_established_conn "$coord_ip"; then
    # First time in THIS BOOT we see a healthy ESTABLISHED
    # connection, arm the watchdog. Subsequent absences will then
    # trigger a kick.
    armed_boot=""
    if [ -f "$ARMED_FILE" ]; then
      armed_boot="$(cat "$ARMED_FILE" 2>/dev/null || true)"
    fi
    if [ "$armed_boot" != "$boot_id" ]; then
      log "arming watchdog (boot=${boot_id}): first observed ESTABLISHED TCP to ${coord_ip}:${COORDINATOR_PORT} for provider_id=${pid}"
      printf "%s" "$boot_id" > "$ARMED_FILE"
    fi
    # Healthy. Stay silent so the log file does not bloat.
    exit 0
  fi
  # No ESTABLISHED connection. If we have not armed THIS BOOT (first
  # install / post-reboot still loading model / provider never
  # configured / provider never connected), stay silent — kicking
  # would break the cold-start flow.
  armed_boot=""
  if [ -f "$ARMED_FILE" ]; then
    armed_boot="$(cat "$ARMED_FILE" 2>/dev/null || true)"
  fi
  if [ "$armed_boot" != "$boot_id" ]; then
    exit 0
  fi
  # Post-kick grace: do not kick again until KICK_GRACE_SECONDS has
  # passed. Covers the launchd-respawn + model-reload + reconnect
  # window after our prior kick.
  if [ -f "$LAST_KICK_FILE" ]; then
    last_kick="$(cat "$LAST_KICK_FILE" 2>/dev/null || printf 0)"
    elapsed=$(( $(now_epoch) - last_kick ))
    if [ "$elapsed" -lt "$KICK_GRACE_SECONDS" ]; then
      # Inside the grace window; silent — operator can spot this in
      # the previous kick log line if they want.
      exit 0
    fi
  fi
  log "no ESTABLISHED TCP to ${coord_ip}:${COORDINATOR_PORT} for provider_id=${pid}; kicking $LABEL"
  now_epoch > "$LAST_KICK_FILE"
  kick_provider
}

main "$@"

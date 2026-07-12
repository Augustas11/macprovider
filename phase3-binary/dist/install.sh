#!/usr/bin/env bash
# Public Mac Provider installer for https://get.streamvc.live/install.sh.
#
# Launchd template substitutions performed by this script:
#   __USER_HOME__       -> absolute installing user's HOME
#   __BINARY_PATH__     -> absolute ~/.local/bin/macprovider-cli path
#   __LOG_DIR__         -> absolute ~/Library/Logs/macprovider path
#   __CONFIG_PATH__     -> absolute provider config path

set -euo pipefail

GITHUB_REPO="${MACPROVIDER_GITHUB_REPO:-Augustas11/macprovider}"
MACPROVIDER_MIN_SUPPORTED_VERSION="v1.7.11"
MACPROVIDER_MIN_EMERGENCY_VERSION="v1.8.30"
COORDINATOR_URL_DEFAULT="wss://coordinator.streamvc.live/ws/provider"
COORDINATOR_BASE_DEFAULT="https://coordinator.streamvc.live"
INSTALL_DIR="${MACPROVIDER_INSTALL_DIR:-$HOME/macprovider}"
BIN_DIR="$HOME/.local/bin"
BINARY_PATH="$BIN_DIR/macprovider-cli"
CONFIG_DIR="$HOME/.config/macprovider"
CONFIG_PATH="$CONFIG_DIR/config.yaml"
PROVIDER_ID_PATH="$CONFIG_DIR/provider_id"
RECOMMENDATION_PATH="$CONFIG_DIR/last-recommendation.json"
INSTALL_LOCK_PATH="$CONFIG_DIR/install.lock"
PROVIDER_MUTATION_ROOT="$HOME/.local/share/macprovider/autoupdate"
PROVIDER_MUTATION_LOCK_PATH="$PROVIDER_MUTATION_ROOT/update.lock"
PROVIDER_MUTATION_PENDING_PATH="$PROVIDER_MUTATION_ROOT/pending.json"
INSTALL_RECOVERY_LABEL="live.streamvc.macprovider-install-recovery"
INSTALL_RECOVERY_PLIST_PATH="$HOME/Library/LaunchAgents/${INSTALL_RECOVERY_LABEL}.plist"
LIVE_CONFIG_PATH="$CONFIG_PATH"
LIVE_PROVIDER_ID_PATH="$PROVIDER_ID_PATH"
MANIFEST_DIR="$HOME/Library/Application Support/macprovider"
MANIFEST_PATH="$MANIFEST_DIR/install_manifest.json"
APP_MARKER_PATH="$HOME/Library/Application Support/Malibu/.installed-by-app"
EXISTING_INSTALL_WAS_PRESENT=0
PLIST_PATH="$HOME/Library/LaunchAgents/live.streamvc.macprovider.plist"
LOG_DIR="$HOME/Library/Logs/macprovider"
# Issue #191: ship the macprovider-watchdog LaunchAgent alongside
# the main provider so every operator gets the silent-disconnect
# safety net. Source lives in ops/macprovider-watchdog/; we inline
# the scripts here so the public installer remains a single curl-able
# artifact.
WATCHDOG_DIR="$HOME/.local/share/macprovider-watchdog"
# Installed without a .sh suffix so macOS Login Items shows a readable
# background-item name instead of "watchdog.sh".
WATCHDOG_PATH="$WATCHDOG_DIR/macprovider-health-monitor"
WATCHDOG_PLIST_PATH="$HOME/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist"
WATCHDOG_LABEL="live.streamvc.macprovider-watchdog"
NO_WATCHDOG="${MACPROVIDER_NO_WATCHDOG:-0}"
DRY_RUN=0
REFERRAL_CODE="${MACPROVIDER_REFERRAL_CODE:-}"
# PROD-H1: reservation id claimed at preflight so a cap-limited invite reserves
# capacity BEFORE the 10-30 min install, not only at final credential mint.
REFERRAL_RESERVATION_ID="${MACPROVIDER_REFERRAL_RESERVATION_ID:-}"
NO_PROMPT="${MACPROVIDER_NO_PROMPT:-0}"
NO_LAUNCHD="${MACPROVIDER_NO_LAUNCHD:-0}"
EMERGENCY_ROLLBACK="${MACPROVIDER_EMERGENCY_ROLLBACK:-0}"
APP_MANAGED_REPAIR="${MACPROVIDER_APP_MANAGED_REPAIR:-0}"
EMERGENCY_CONFIG_BACKUP="${MACPROVIDER_EMERGENCY_CONFIG_BACKUP:-}"
EMERGENCY_CONFIG_SHA256="${MACPROVIDER_EMERGENCY_CONFIG_SHA256:-}"
EMERGENCY_STAGED_CONFIG_SHA256=""
EMERGENCY_MODEL=""
TMPDIR_PATH=""
staging_dir=""
STAGED_CONFIG_PATH=""
STAGED_PROVIDER_ID_PATH=""
AUTOTUNE_BENCHMARK_PORT=""
MACPROVIDER_CLI_EXECUTABLE="$INSTALL_DIR/macprovider-cli"
LAUNCHD_INSTALLED=0
WATCHDOG_INSTALLED=0
MANUAL_PID=""
SKIP_PROVIDER_START=0
INSTALL_TX_ACTIVE=0
INSTALL_TX_COMMITTED=0
INSTALL_TX_BACKUP=""
INSTALL_TX_SERVICE_WAS_ACTIVE=0
INSTALL_TX_HAD_INSTALL_DIR=0
INSTALL_TX_HAD_BINARY_PATH=0
INSTALL_TX_HAD_CONFIG=0
INSTALL_TX_HAD_PROVIDER_ID=0
INSTALL_TX_HAD_RECOMMENDATION=0
INSTALL_TX_HAD_PLIST=0
INSTALL_TX_HAD_WATCHDOG_DIR=0
INSTALL_TX_HAD_WATCHDOG_PLIST=0
INSTALL_TX_HAD_MANIFEST=0
INSTALL_TX_SERVICE_WAS_DISABLED=0
INSTALL_TX_WATCHDOG_WAS_ACTIVE=0
INSTALL_TX_WATCHDOG_WAS_DISABLED=0
INSTALL_TX_ROLLING_BACK=0
INSTALL_TX_BINARY_KIND="symlink"
INSTALL_LOCK_HELD=0
INSTALL_LOCK_TOKEN=""
INSTALL_LOCK_HOLDER_PID=""
CUTOVER_STARTED=0
AUTOTUNE_RECOMMENDATION_REQUIRED=0

log() { printf "[macprovider-install] %s\n" "$*"; }
die() {
  code="$1"
  shift
  printf "[macprovider-install] ERROR: %s\n" "$*" >&2
  exit "$code"
}

validate_install_dir() {
  validated="$({ python3 - "$INSTALL_DIR" "$HOME" <<'PY'
import os
import stat
import sys

raw, raw_home = sys.argv[1:]
if not raw.startswith("/"):
    raise SystemExit("install directory must be absolute")
if any(part in {".", ".."} for part in raw.split("/")):
    raise SystemExit("install directory must not contain traversal components")

home = os.path.normpath(raw_home)
target = os.path.normpath(raw)
if target == home:
    raise SystemExit("install directory must not be HOME itself")
try:
    if os.path.commonpath([home, target]) != home:
        raise SystemExit("install directory must be inside HOME")
except ValueError:
    raise SystemExit("install directory must be inside HOME")

uid = os.getuid()
current = home
relative = os.path.relpath(target, home)
for component in ["."] + relative.split(os.sep):
    if component != ".":
        current = os.path.join(current, component)
    if not os.path.lexists(current):
        continue
    info = os.lstat(current)
    if stat.S_ISLNK(info.st_mode):
        raise SystemExit(f"install path contains symlink component: {current}")
    if not stat.S_ISDIR(info.st_mode):
        raise SystemExit(f"install path component is not a directory: {current}")
    if info.st_uid != uid:
        raise SystemExit(f"install path component is not owned by the installing user: {current}")
    if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise SystemExit(f"install path component is group/world-writable: {current}")

print(target)
PY
  } 2>&1)" || die 7 "unsafe MACPROVIDER_INSTALL_DIR: $validated"
  INSTALL_DIR="$validated"
}

validate_port_value() {
  value="$1"
  case "$value" in
    ''|*[!0-9]*) die 7 "port must be numeric in [1024, 65535] (got: $value)" ;;
  esac
  if [ "$value" -lt 1024 ] || [ "$value" -gt 65535 ]; then
    die 7 "port must be in [1024, 65535] (got: $value)"
  fi
}

# Retry macprovider-cli up to two additional times if the first
# post-install invocation is SIGKILL'd by the kernel with a CODESIGNING
# "Invalid Page" / "Taskgated Invalid Signature" verdict. Two failure
# flavors have been observed:
#
#   FLAVOR 1 — Transient AMFI race. Observed 2026-07-03 on Apple M5
#     macOS 26.5 with a freshly-installed v1.7.9 pkg: `autotune
#     --recommend --freshness-check` was reported "Killed: 9" (bash
#     exit 137) on the FIRST invocation right after `installer -pkg`,
#     and the immediately-repeated invocation of the SAME command by
#     the SAME shell succeeded. This is a race between the pkg
#     installer's post-install AMFI signature revalidation and our
#     first execve; the 2s sleep is sufficient to let AMFI settle.
#
#   FLAVOR 2 — AMFI cache pinned to the pkg-installer inode. Observed
#     2026-07-03 on the same M5 during the v1.7.10 install: BOTH the
#     first invocation AND the 2s-later retry were SIGKILL'd, but the
#     binary's `codesign --verify --deep --strict` passed cleanly and
#     the SAME binary content ran fine when copied to a different
#     path. The AMFI kernel cache had a stuck rejection tied to the
#     specific inode that `installer -pkg` created. The fix is to
#     `rm` the file (releasing the inode) and `cp` the binary back
#     in from a tempfile, which gives it a new inode and forces AMFI
#     to re-evaluate. See PR #339 for the reproduction and root cause.
#
# The helper's escalation ladder for bash rc 137:
#   attempt 1: run
#     └── 137 → log + sleep 2 + attempt 2 (FLAVOR 1 fix)
#         └── 137 → log + inode-refresh via cp/rm/cp + attempt 3
#             │           (FLAVOR 2 fix)
#             └── 137 → log "genuine signature failure" + return 137
# Any non-137 rc anywhere in the ladder returns immediately.
#
# Only SIGKILL / bash rc 137 is retried — other non-zero exits
# (including autotune's exit-10 "stale recommendation" signal, and
# other signal-terminated codes such as 134 SIGABRT / 138 SIGBUS /
# 139 SIGSEGV) pass through unchanged so we do not mask real crashes.
#
# This helper MUST be called from `if run_..._retry ...; then` or
# `run_..._retry ... || ...` so that `set -e` (enabled at the top of
# this script) does not fire on the pass-through non-zero return.
#
# Diagnostic lines are written to stderr so they remain visible even
# when callers redirect the helper's stdout to `/dev/null` (as the
# freshness-check call site does).
run_macprovider_cli_with_amfi_retry() {
  local rc=0
  local cli_path="$MACPROVIDER_CLI_EXECUTABLE"
  "$cli_path" "$@" || rc=$?
  if [ "$rc" -ne 137 ]; then
    return "$rc"
  fi
  log "macprovider-cli was SIGKILL'd on first invocation (rc=$rc); likely a transient AMFI code-signature race after pkg install. Retrying once after 2s." >&2
  sleep 2
  rc=0
  "$cli_path" "$@" || rc=$?
  if [ "$rc" -ne 137 ]; then
    return "$rc"
  fi
  log "macprovider-cli was SIGKILL'd again on the 2s retry; the AMFI cache may be pinned to the pkg-installer inode. Refreshing the binary inode via cp/rm/cp and retrying once more." >&2
  local tmp
  tmp="$(mktemp -t macprovider-cli-inode-refresh 2>/dev/null || mktemp)"
  if [ -z "$tmp" ]; then
    log "inode refresh: mktemp failed; leaving the original binary in place." >&2
    return "$rc"
  fi
  if ! cp "$cli_path" "$tmp" 2>/dev/null; then
    log "inode refresh: cp to $tmp failed; leaving the original binary in place." >&2
    rm -f "$tmp"
    return "$rc"
  fi
  if ! rm -f "$cli_path"; then
    log "inode refresh: rm of $cli_path failed; the binary is still there but the inode was not refreshed." >&2
    rm -f "$tmp"
    return "$rc"
  fi
  if ! cp "$tmp" "$cli_path"; then
    log "inode refresh: cp-back of $tmp -> $cli_path failed; the binary at $cli_path is now missing. Restore from $tmp and chmod it executable." >&2
    return "$rc"
  fi
  if ! chmod +x "$cli_path"; then
    log "inode refresh: chmod +x on $cli_path failed; the binary is present but may not be executable." >&2
    return "$rc"
  fi
  rm -f "$tmp"
  rc=0
  "$cli_path" "$@" || rc=$?
  if [ "$rc" -eq 137 ]; then
    log "macprovider-cli was SIGKILL'd after the inode refresh; this is likely a genuine signature failure rather than the AMFI cache." >&2
  fi
  return "$rc"
}

detect_existing_port() {
  if [ -f "$CONFIG_PATH" ]; then
    awk -F: '/^port:/ {gsub(/ /, "", $2); print $2; exit}' "$CONFIG_PATH" 2>/dev/null
  fi
}

# F-603-V7-1: upgrade-in-place must preserve the prior configured port
# unless the operator explicitly overrides it. Otherwise existing installs
# on 18080 regress to the default 8080 and collide with unrelated services.
if [ -n "${MACPROVIDER_PORT:-}" ]; then
  PORT="$MACPROVIDER_PORT"
elif EXISTING_PORT="$(detect_existing_port)" && [ -n "$EXISTING_PORT" ]; then
  PORT="$EXISTING_PORT"
  log "Detected existing config port: $PORT (override with MACPROVIDER_PORT=N)"
else
  PORT="8080"
fi

usage() {
  cat <<'USAGE'
Usage: bash install.sh [--dry-run] [--ref CODE]

Referral invite:
  curl -fsSL https://get.streamvc.live/install.sh | bash -s -- --ref CODE

Environment overrides:
  MACPROVIDER_GITHUB_REPO        owner/repo for GitHub Releases
  MACPROVIDER_VERSION            pin installer to vMAJOR.MINOR.PATCH
                                 (pipe-side form: curl ... | MACPROVIDER_VERSION=v1.7.11 bash)
  MACPROVIDER_COORDINATOR_URL    coordinator WebSocket URL
  MACPROVIDER_REFERRAL_CODE      pre-beta referral code (same as --ref)
  MACPROVIDER_PORT               local HTTP port
  MACPROVIDER_INSTALL_DIR        support dir for binary + bundles
  MACPROVIDER_RELEASE_FORMAT     auto, pkg, or tar (default: auto)
  MACPROVIDER_NO_PROMPT=1        use defaults without interactive prompts
  MACPROVIDER_NO_LAUNCHD=1       expert/debug only: skip BOTH the provider
                                 launchd service and its companion watchdog
  MACPROVIDER_NO_WATCHDOG=1      expert/debug only: install the provider
                                 launchd service but skip the watchdog
  MACPROVIDER_APP_MANAGED_REPAIR=1
                                 Malibu.app only: update an existing app-owned
                                 install without starting credential-less launchd
  MACPROVIDER_EMERGENCY_ROLLBACK=1
                                 operator-only signed rollback to an explicit
                                 MACPROVIDER_VERSION; commits only through an
                                 active legacy_bridge admission
  MACPROVIDER_SKIP_HF_CHECK=1    skip HuggingFace lookup on custom model id
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --ref|--referral-code)
      [ "$#" -ge 2 ] || die 7 "$1 requires a referral code"
      REFERRAL_CODE="$2"
      shift
      ;;
    --ref=*|--referral-code=*) REFERRAL_CODE="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) die 7 "unknown argument: $1" ;;
  esac
  shift
done

if [ -n "$REFERRAL_CODE" ] && [[ ! "$REFERRAL_CODE" =~ ^MAL1-[SP]-[A-Za-z0-9_]{1,32}-[A-Za-z0-9_]{1,32}-[A-Z2-7]{26}$ ]]; then
  die 7 "referral code has an invalid format"
fi

release_install_lock() {
  [ "$INSTALL_LOCK_HELD" -eq 1 ] || return 0
  case "$INSTALL_LOCK_HOLDER_PID" in
    ''|*[!0-9]*) return 70 ;;
  esac
  kill -TERM "$INSTALL_LOCK_HOLDER_PID" >/dev/null 2>&1 || true
  wait "$INSTALL_LOCK_HOLDER_PID" >/dev/null 2>&1 || true
  INSTALL_LOCK_HELD=0
  INSTALL_LOCK_TOKEN=""
  INSTALL_LOCK_HOLDER_PID=""
}

assert_install_lock_ownership() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  [ "$INSTALL_LOCK_HELD" -eq 1 ] \
    || die 70 "installer lock is not held; refusing protected install mutation"
  case "$INSTALL_LOCK_HOLDER_PID" in
    ''|*[!0-9]*) die 70 "installer lock helper identity is invalid; refusing protected install mutation" ;;
  esac
  [ -n "$INSTALL_LOCK_TOKEN" ] \
    || die 70 "installer lock token is missing; refusing protected install mutation"
  python3 - "$HOME" "$CONFIG_DIR" "$INSTALL_LOCK_PATH" "$PROVIDER_MUTATION_ROOT" \
    "$PROVIDER_MUTATION_LOCK_PATH" "$$" "$INSTALL_LOCK_TOKEN" "$INSTALL_LOCK_HOLDER_PID" <<'PY' \
    || die 70 "installer lock ownership was lost; refusing protected install mutation"
import fcntl
import json
import os
import stat
import subprocess
import sys

home, config_dir, lock_path, mutation_root, mutation_lock_path, owner_pid_text, token, holder_pid_text = sys.argv[1:]
owner_pid = int(owner_pid_text)
holder_pid = int(holder_pid_text)
uid = os.getuid()

def process_start(pid):
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "lstart="],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else ""

def boot_session():
    result = subprocess.run(
        ["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"],
        check=False,
        capture_output=True,
        text=True,
    )
    value = result.stdout.strip()
    if value:
        return value
    try:
        with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as handle:
            return handle.read().strip()
    except OSError:
        return ""

home = os.path.normpath(home)
config_dir = os.path.normpath(config_dir)
mutation_root = os.path.normpath(mutation_root)
if os.path.commonpath([home, config_dir]) != home:
    raise SystemExit("config directory escaped HOME")
if os.path.commonpath([home, mutation_root]) != home:
    raise SystemExit("provider mutation directory escaped HOME")
directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
directory_fd = os.open(config_dir, directory_flags)
lock_fd = None
mutation_directory_fd = None
mutation_lock_fd = None
try:
    lock_fd = os.open(
        os.path.basename(lock_path),
        os.O_RDWR | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_fd,
    )
    info = os.fstat(lock_fd)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != uid
        or info.st_nlink != 1
        or stat.S_IMODE(info.st_mode) != 0o600
    ):
        raise RuntimeError("installer lock is not an owned private regular file")
    payload = os.read(lock_fd, 4097)
    if len(payload) > 4096:
        raise RuntimeError("installer lock record is oversized")
    record = json.loads(payload.decode("utf-8"))
    current_boot = boot_session()
    if not current_boot:
        raise RuntimeError("could not identify the current boot session")
    expected = {
        "pid": owner_pid,
        "process_start": process_start(owner_pid),
        "boot_session": current_boot,
        "token": token,
        "holder_pid": holder_pid,
        "holder_process_start": process_start(holder_pid),
    }
    if not expected["process_start"] or not expected["holder_process_start"]:
        raise RuntimeError("installer owner or lock helper is no longer live")
    if record != expected:
        raise RuntimeError("installer lock record no longer matches this process")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        raise RuntimeError("installer lock helper no longer owns the kernel lock")
    mutation_directory_fd = os.open(mutation_root, directory_flags)
    mutation_lock_fd = os.open(
        os.path.basename(mutation_lock_path),
        os.O_RDWR | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=mutation_directory_fd,
    )
    mutation_info = os.fstat(mutation_lock_fd)
    if not stat.S_ISREG(mutation_info.st_mode) or mutation_info.st_uid != uid or mutation_info.st_nlink != 1 or mutation_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise RuntimeError("provider mutation inner lock is not an owned private regular file")
    try:
        fcntl.flock(mutation_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        fcntl.flock(mutation_lock_fd, fcntl.LOCK_UN)
        raise RuntimeError("installer helper no longer owns the provider mutation inner lock")
finally:
    if mutation_lock_fd is not None:
        os.close(mutation_lock_fd)
    if mutation_directory_fd is not None:
        os.close(mutation_directory_fd)
    if lock_fd is not None:
        os.close(lock_fd)
    os.close(directory_fd)
PY
}

acquire_install_lock() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  lock_status_path="$(mktemp "${TMPDIR:-/tmp}/macprovider-install-lock.XXXXXX")" \
    || die 70 "could not allocate installer lock handshake"
  python3 - "$HOME" "$CONFIG_DIR" "$INSTALL_LOCK_PATH" "$PROVIDER_MUTATION_ROOT" \
    "$PROVIDER_MUTATION_LOCK_PATH" "$PROVIDER_MUTATION_PENDING_PATH" "$$" "$lock_status_path" <<'PY' &
import fcntl
import json
import os
import secrets
import signal
import stat
import subprocess
import sys
import time

home, config_dir, lock_path, mutation_root, mutation_lock_path, mutation_pending_path, owner_pid_text, status_path = sys.argv[1:]
owner_pid = int(owner_pid_text)
uid = os.getuid()

def write_status(value):
    flags = os.O_WRONLY | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(status_path, flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != uid:
            raise RuntimeError("unsafe installer lock handshake")
        os.write(fd, (value + "\n").encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)

def process_start(pid):
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "lstart="],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else ""

def boot_session():
    result = subprocess.run(
        ["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"],
        check=False,
        capture_output=True,
        text=True,
    )
    value = result.stdout.strip()
    if value:
        return value
    try:
        with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as handle:
            return handle.read().strip()
    except OSError:
        return ""

home = os.path.normpath(home)
config_dir = os.path.normpath(config_dir)
mutation_root = os.path.normpath(mutation_root)
if os.path.commonpath([home, config_dir]) != home:
    raise SystemExit("config directory must remain inside HOME")
if os.path.commonpath([home, mutation_root]) != home:
    raise SystemExit("provider mutation directory must remain inside HOME")
current = home
for component in os.path.relpath(config_dir, home).split(os.sep):
    current = os.path.join(current, component)
    try:
        info = os.lstat(current)
    except FileNotFoundError:
        os.mkdir(current, 0o700)
        info = os.lstat(current)
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise SystemExit(f"config path is not a no-follow directory: {current}")
    if info.st_uid != uid or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise SystemExit(f"config path is not private to the installing user: {current}")

directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
directory_fd = os.open(config_dir, directory_flags)
lock_fd = None
mutation_directory_fd = None
mutation_lock_fd = None
try:
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    lock_fd = os.open(os.path.basename(lock_path), flags, 0o600, dir_fd=directory_fd)
    info = os.fstat(lock_fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != uid or info.st_nlink != 1:
        raise RuntimeError("installer lock is not an owned private regular file")
    os.fchmod(lock_fd, 0o600)
    if stat.S_IMODE(os.fstat(lock_fd).st_mode) != 0o600:
        raise RuntimeError("installer lock mode could not be normalized to 0600")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        write_status("busy")
        raise SystemExit(73)
    current_boot = boot_session()
    if not current_boot:
        raise RuntimeError("could not identify the current boot session")
    existing_payload = os.read(lock_fd, 4097)
    if len(existing_payload) > 4096:
        raise RuntimeError("installer lock record is oversized")
    if existing_payload.strip():
        try:
            existing = json.loads(existing_payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise RuntimeError("installer lock record is invalid") from error
        existing_pid = existing.get("pid")
        existing_start = existing.get("process_start")
        existing_boot = existing.get("boot_session")
        if (
            isinstance(existing_pid, int)
            and isinstance(existing_start, str)
            and existing_start
            and existing_boot == current_boot
            and process_start(existing_pid) == existing_start
        ):
            # The kernel-lock helper may have crashed or been killed while its
            # installer owner remained active. The durable owner record fences
            # out a replacement claimant until that exact owner identity dies.
            write_status("busy")
            raise SystemExit(73)
    current = home
    for component in os.path.relpath(mutation_root, home).split(os.sep):
        current = os.path.join(current, component)
        try:
            info = os.lstat(current)
        except FileNotFoundError:
            os.mkdir(current, 0o700)
            info = os.lstat(current)
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
            raise RuntimeError(f"provider mutation path is not a no-follow directory: {current}")
        if info.st_uid != uid or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise RuntimeError(f"provider mutation path is not private to the installing user: {current}")
    mutation_directory_fd = os.open(mutation_root, directory_flags)
    mutation_lock_fd = os.open(
        os.path.basename(mutation_lock_path),
        os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0),
        0o600,
        dir_fd=mutation_directory_fd,
    )
    mutation_info = os.fstat(mutation_lock_fd)
    if not stat.S_ISREG(mutation_info.st_mode) or mutation_info.st_uid != uid or mutation_info.st_nlink != 1 or mutation_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise RuntimeError("provider mutation inner lock is not an owned private regular file")
    try:
        fcntl.flock(mutation_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        write_status("mutation-busy")
        raise SystemExit(73)
    try:
        pending_info = os.lstat(mutation_pending_path)
    except FileNotFoundError:
        pending_info = None
    if pending_info is not None:
        if not stat.S_ISREG(pending_info.st_mode) or stat.S_ISLNK(pending_info.st_mode) or pending_info.st_uid != uid or pending_info.st_nlink != 1 or pending_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise RuntimeError("pending provider mutation marker is unsafe")
        write_status("mutation-pending")
        raise SystemExit(73)
    token = secrets.token_hex(32)
    parent_start = process_start(owner_pid)
    if not parent_start:
        raise RuntimeError("installer parent process disappeared before lock acquisition")
    record = {
        "pid": owner_pid,
        "process_start": parent_start,
        "boot_session": current_boot,
        "token": token,
        "holder_pid": os.getpid(),
        "holder_process_start": process_start(os.getpid()),
    }
    payload = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    os.lseek(lock_fd, 0, os.SEEK_SET)
    os.ftruncate(lock_fd, 0)
    os.write(lock_fd, payload)
    os.fsync(lock_fd)
    os.fsync(directory_fd)
    write_status(f"ok:{token}")
    stopping = False
    def stop(_signum, _frame):
        nonlocal_stopping[0] = True
    nonlocal_stopping = [False]
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while not nonlocal_stopping[0]:
        if process_start(owner_pid) != parent_start:
            break
        time.sleep(0.25)
except SystemExit:
    raise
except BaseException as error:
    try:
        write_status(f"error:{error}")
    except BaseException:
        pass
    raise
finally:
    if mutation_lock_fd is not None:
        os.close(mutation_lock_fd)
    if mutation_directory_fd is not None:
        os.close(mutation_directory_fd)
    if lock_fd is not None:
        os.close(lock_fd)
    os.close(directory_fd)
PY
  INSTALL_LOCK_HOLDER_PID=$!
  lock_wait=0
  while [ "$lock_wait" -lt 100 ] && [ ! -s "$lock_status_path" ]; do
    if ! kill -0 "$INSTALL_LOCK_HOLDER_PID" >/dev/null 2>&1; then
      break
    fi
    sleep 0.05
    lock_wait=$((lock_wait + 1))
  done
  lock_result="$(cat "$lock_status_path" 2>/dev/null || true)"
  rm -f "$lock_status_path"
  case "$lock_result" in
    ok:*) INSTALL_LOCK_TOKEN="${lock_result#ok:}" ;;
    busy)
      wait "$INSTALL_LOCK_HOLDER_PID" >/dev/null 2>&1 || true
      INSTALL_LOCK_HOLDER_PID=""
      die 73 "another macprovider installer is active; wait for it to finish"
      ;;
    mutation-busy)
      wait "$INSTALL_LOCK_HOLDER_PID" >/dev/null 2>&1 || true
      INSTALL_LOCK_HOLDER_PID=""
      die 73 "another provider update is active; wait for it to finish"
      ;;
    mutation-pending)
      wait "$INSTALL_LOCK_HOLDER_PID" >/dev/null 2>&1 || true
      INSTALL_LOCK_HOLDER_PID=""
      die 73 "a provider update is awaiting coordinator admission or recovery; wait for it to finish"
      ;;
    *)
      kill -TERM "$INSTALL_LOCK_HOLDER_PID" >/dev/null 2>&1 || true
      wait "$INSTALL_LOCK_HOLDER_PID" >/dev/null 2>&1 || true
      INSTALL_LOCK_HOLDER_PID=""
      die 70 "could not acquire the no-follow installer lock: ${lock_result#error:}"
      ;;
  esac
  INSTALL_LOCK_HELD=1
}

recover_orphaned_install_transactions() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  assert_install_lock_ownership
  orphan_list="$(python3 - "$CONFIG_DIR" <<'PY'
import os
import stat
import sys

root = sys.argv[1]
uid = os.getuid()
for name in sorted(os.listdir(root)):
    if not name.startswith("install-recovery-") or name.endswith(".staging") or ".committed." in name:
        continue
    path = os.path.join(root, name)
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode) or info.st_uid != uid:
        raise SystemExit(f"unsafe orphan recovery bundle: {path}")
    for required in ("state.sh", "recover.sh"):
        child = os.path.join(path, required)
        child_info = os.lstat(child)
        if not stat.S_ISREG(child_info.st_mode) or stat.S_ISLNK(child_info.st_mode) or child_info.st_uid != uid:
            raise SystemExit(f"unsafe orphan recovery artifact: {child}")
    print(path)
PY
  )" || die 70 "could not safely enumerate orphan install transactions"
  [ -n "$orphan_list" ] || return 0
  while IFS= read -r orphan; do
    [ -n "$orphan" ] || continue
    log "Recovering interrupted install transaction before starting a new install: $orphan"
    recovery_rc=0
    bash "$orphan/recover.sh" || recovery_rc=$?
    if [ "$recovery_rc" -eq 75 ]; then
      wait_attempt=0
      while [ "$wait_attempt" -lt 30 ] && [ -d "$orphan" ]; do
        sleep 1
        wait_attempt=$((wait_attempt + 1))
      done
      [ ! -d "$orphan" ] || die 75 "interrupted install recovery is still active: $orphan"
      continue
    fi
    [ "$recovery_rc" -eq 0 ] || die 70 "interrupted install recovery failed; run exactly: bash '$orphan/recover.sh'"
    rm -rf "$orphan" || die 70 "recovered orphan transaction could not be retired: $orphan"
  done <<EOF
$orphan_list
EOF
}

restore_existing_provider_if_start_skipped() {
  [ "$SKIP_PROVIDER_START" -eq 1 ] || return 1
  [ "$EXISTING_INSTALL_WAS_PRESENT" -eq 1 ] || return 1
  if [ "$CUTOVER_STARTED" -eq 0 ]; then
    log "No replacement provider will be started; discarding staged files without touching the active provider."
    if [ "${INSTALL_TX_WATCHDOG_WAS_ACTIVE:-0}" -eq 1 ]; then
      launchctl bootstrap "gui/$UID" "$WATCHDOG_PLIST_PATH" >/dev/null 2>&1 || return 1
      launchctl kickstart -k "gui/$UID/$WATCHDOG_LABEL" >/dev/null 2>&1 || return 1
    fi
    commit_install_transaction || return 1
    log "The active provider release remained online and unchanged."
    return 0
  fi
  log "No replacement provider will be started; restoring the previous ready provider release."
  rollback_install_transaction || return 1
  log "Previous provider release restored. The requested update was not activated."
  return 0
}

cleanup() {
  cleanup_rc=$?
  trap - EXIT
  if [ "$INSTALL_TX_ACTIVE" -eq 1 ] && [ "$INSTALL_TX_COMMITTED" -ne 1 ]; then
    if ! rollback_install_transaction; then
      cleanup_rc=70
    fi
  fi
  if [ -n "$TMPDIR_PATH" ] && [ -d "$TMPDIR_PATH" ]; then
    if ! rm -rf "$TMPDIR_PATH"; then
      log "ERROR: failed to remove temporary installer directory: $TMPDIR_PATH"
      if [ "$cleanup_rc" -eq 0 ]; then
        cleanup_rc=70
      fi
    fi
  fi
  if ! release_install_lock; then
    log "ERROR: installer lock ownership could not be released safely: $INSTALL_LOCK_PATH"
    if [ "$cleanup_rc" -eq 0 ]; then
      cleanup_rc=70
    fi
  fi
  exit "$cleanup_rc"
}
trap cleanup EXIT

install_tx_path_matches() {
  source_path="$1"
  copied_path="$2"
  path_kind="$3"
  case "$path_kind" in
    directory) diff -qr "$source_path" "$copied_path" >/dev/null 2>&1 ;;
    symlink) [ -L "$copied_path" ] && [ "$(readlink "$source_path")" = "$(readlink "$copied_path")" ] ;;
    file) cmp -s "$source_path" "$copied_path" ;;
    *) return 1 ;;
  esac
}

stage_install_tx_path() {
  source_path="$1"
  copied_path="$2"
  path_kind="$3"
  case "$path_kind" in
    directory) cp -R "$source_path" "$copied_path" ;;
    symlink) cp -P "$source_path" "$copied_path" ;;
    file) cp -p "$source_path" "$copied_path" ;;
    *) return 1 ;;
  esac
  install_tx_path_matches "$source_path" "$copied_path" "$path_kind"
}

write_install_recovery_artifacts() {
  recovery_dir="$1"
  state_path="$recovery_dir/state.sh"
  recovery_script="$recovery_dir/recover.sh"

  {
    printf 'REC_INSTALL_DIR=%q\n' "$INSTALL_DIR"
    printf 'REC_BINARY_PATH=%q\n' "$BINARY_PATH"
    printf 'REC_CONFIG_PATH=%q\n' "$CONFIG_PATH"
    printf 'REC_PROVIDER_ID_PATH=%q\n' "$PROVIDER_ID_PATH"
    printf 'REC_RECOMMENDATION_PATH=%q\n' "$RECOMMENDATION_PATH"
    printf 'REC_PLIST_PATH=%q\n' "$PLIST_PATH"
    printf 'REC_WATCHDOG_DIR=%q\n' "$WATCHDOG_DIR"
    printf 'REC_WATCHDOG_PLIST_PATH=%q\n' "$WATCHDOG_PLIST_PATH"
    printf 'REC_WATCHDOG_LABEL=%q\n' "$WATCHDOG_LABEL"
    printf 'REC_MANIFEST_PATH=%q\n' "$MANIFEST_PATH"
    printf 'REC_LOG_DIR=%q\n' "$LOG_DIR"
    printf 'REC_INSTALL_RECOVERY_LABEL=%q\n' "$INSTALL_RECOVERY_LABEL"
    printf 'REC_INSTALL_RECOVERY_PLIST_PATH=%q\n' "$INSTALL_RECOVERY_PLIST_PATH"
    printf 'REC_INSTALL_LOCK_PATH=%q\n' "$INSTALL_LOCK_PATH"
    printf 'REC_INSTALL_LOCK_TOKEN=%q\n' "$INSTALL_LOCK_TOKEN"
    printf 'REC_INSTALLER_PID=%q\n' "$$"
    printf 'REC_INSTALLER_PROCESS_START=%q\n' "$(ps -p $$ -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    printf 'REC_INSTALLER_BOOT_SESSION=%q\n' "$(sysctl -n kern.bootsessionuuid 2>/dev/null || true)"
    printf 'REC_MANUAL_READY_TIMEOUT_SECONDS=%q\n' "15"
    printf 'REC_UID=%q\n' "$UID"
    printf 'REC_HAD_INSTALL_DIR=%q\n' "$INSTALL_TX_HAD_INSTALL_DIR"
    printf 'REC_HAD_BINARY_PATH=%q\n' "$INSTALL_TX_HAD_BINARY_PATH"
    printf 'REC_HAD_CONFIG=%q\n' "$INSTALL_TX_HAD_CONFIG"
    printf 'REC_HAD_PROVIDER_ID=%q\n' "$INSTALL_TX_HAD_PROVIDER_ID"
    printf 'REC_HAD_RECOMMENDATION=%q\n' "$INSTALL_TX_HAD_RECOMMENDATION"
    printf 'REC_HAD_PLIST=%q\n' "$INSTALL_TX_HAD_PLIST"
    printf 'REC_HAD_WATCHDOG_DIR=%q\n' "$INSTALL_TX_HAD_WATCHDOG_DIR"
    printf 'REC_HAD_WATCHDOG_PLIST=%q\n' "$INSTALL_TX_HAD_WATCHDOG_PLIST"
    printf 'REC_HAD_MANIFEST=%q\n' "$INSTALL_TX_HAD_MANIFEST"
    printf 'REC_SERVICE_WAS_ACTIVE=%q\n' "$INSTALL_TX_SERVICE_WAS_ACTIVE"
    printf 'REC_SERVICE_WAS_DISABLED=%q\n' "$INSTALL_TX_SERVICE_WAS_DISABLED"
    printf 'REC_WATCHDOG_WAS_ACTIVE=%q\n' "$INSTALL_TX_WATCHDOG_WAS_ACTIVE"
    printf 'REC_WATCHDOG_WAS_DISABLED=%q\n' "$INSTALL_TX_WATCHDOG_WAS_DISABLED"
    printf 'REC_BINARY_KIND=%q\n' "$INSTALL_TX_BINARY_KIND"
  } > "$state_path" || return 1

  cat > "$recovery_script" <<'RECOVERY_SCRIPT'
#!/usr/bin/env bash
set -u

RECOVERY_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 70
# shellcheck disable=SC1091
. "$RECOVERY_DIR/state.sh" || exit 70

recovery_log() { printf '[macprovider-recovery] %s\n' "$*" >&2; }
acquire_recovery_claim() {
  claim_status="$(mktemp "${TMPDIR:-/tmp}/macprovider-recovery-claim.XXXXXX")" || return 70
  python3 - "$RECOVERY_DIR/recovery.lock" "$$" "$claim_status" <<'PY' &
import fcntl
import json
import os
import signal
import stat
import subprocess
import sys
import time

path, parent_pid_text, status_path = sys.argv[1:]
parent_pid = int(parent_pid_text)
uid = os.getuid()
def process_start(pid):
    return subprocess.run(
        ["ps", "-p", str(pid), "-o", "lstart="], check=False,
        capture_output=True, text=True,
    ).stdout.strip()
def boot_session():
    value = subprocess.run(
        ["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"], check=False,
        capture_output=True, text=True,
    ).stdout.strip()
    if value:
        return value
    try:
        with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as handle:
            return handle.read().strip()
    except OSError:
        return ""
def write_status(value):
    fd = os.open(status_path, os.O_WRONLY | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0))
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != uid:
            raise RuntimeError("unsafe recovery lock handshake")
        os.write(fd, (value + "\n").encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
fd = os.open(path, flags, 0o600)
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise RuntimeError("unsafe recovery lock")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        write_status("busy")
        raise SystemExit(75)
    current_boot = boot_session()
    if not current_boot:
        raise RuntimeError("could not identify recovery boot session")
    existing_payload = os.read(fd, 4097)
    if len(existing_payload) > 4096:
        raise RuntimeError("recovery lock record is oversized")
    if existing_payload.strip():
        try:
            existing = json.loads(existing_payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise RuntimeError("recovery lock record is invalid") from error
        existing_pid = existing.get("pid")
        existing_start = existing.get("process_start")
        if (
            isinstance(existing_pid, int)
            and isinstance(existing_start, str)
            and existing_start
            and existing.get("boot_session") == current_boot
            and process_start(existing_pid) == existing_start
        ):
            write_status("busy")
            raise SystemExit(75)
    parent_start = process_start(parent_pid)
    if not parent_start:
        raise RuntimeError("recovery parent disappeared")
    record = {
        "pid": parent_pid,
        "process_start": parent_start,
        "boot_session": current_boot,
        "holder_pid": os.getpid(),
        "holder_process_start": process_start(os.getpid()),
    }
    payload = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    os.lseek(fd, 0, os.SEEK_SET)
    os.ftruncate(fd, 0)
    os.write(fd, payload)
    os.fsync(fd)
    write_status("ok")
    stopping = [False]
    signal.signal(signal.SIGTERM, lambda _signal, _frame: stopping.__setitem__(0, True))
    while not stopping[0]:
        current = process_start(parent_pid)
        if current != parent_start:
            break
        time.sleep(0.25)
except SystemExit:
    raise
except BaseException as error:
    try:
        write_status(f"error:{error}")
    except BaseException:
        pass
    raise
finally:
    os.close(fd)
PY
  RECOVERY_CLAIM_HOLDER_PID=$!
  claim_wait=0
  while [ "$claim_wait" -lt 100 ] && [ ! -s "$claim_status" ]; do
    kill -0 "$RECOVERY_CLAIM_HOLDER_PID" >/dev/null 2>&1 || break
    sleep 0.05
    claim_wait=$((claim_wait + 1))
  done
  claim_result="$(cat "$claim_status" 2>/dev/null || true)"
  rm -f "$claim_status"
  case "$claim_result" in
    ok) return 0 ;;
    busy)
      wait "$RECOVERY_CLAIM_HOLDER_PID" >/dev/null 2>&1 || true
      RECOVERY_CLAIM_HOLDER_PID=""
      recovery_log "Recovery is already active for this transaction."
      return 75
      ;;
    *)
      kill -TERM "$RECOVERY_CLAIM_HOLDER_PID" >/dev/null 2>&1 || true
      wait "$RECOVERY_CLAIM_HOLDER_PID" >/dev/null 2>&1 || true
      RECOVERY_CLAIM_HOLDER_PID=""
      recovery_log "Could not acquire recovery claim: ${claim_result#error:}"
      return 70
      ;;
  esac
}
release_recovery_claim() {
  if [ -n "${RECOVERY_CLAIM_HOLDER_PID:-}" ]; then
    kill -TERM "$RECOVERY_CLAIM_HOLDER_PID" >/dev/null 2>&1 || true
    wait "$RECOVERY_CLAIM_HOLDER_PID" >/dev/null 2>&1 || true
  fi
}
acquire_recovery_claim || exit $?
trap release_recovery_claim EXIT
path_exists() { [ -e "$1" ] || [ -L "$1" ]; }
paths_match() {
  source_path="$1"
  copied_path="$2"
  path_kind="$3"
  case "$path_kind" in
    directory) diff -qr "$source_path" "$copied_path" >/dev/null 2>&1 ;;
    symlink) [ -L "$copied_path" ] && [ "$(readlink "$source_path")" = "$(readlink "$copied_path")" ] ;;
    file) cmp -s "$source_path" "$copied_path" ;;
    *) return 1 ;;
  esac
}
stage_restore() {
  source_path="$1"
  candidate_path="$2"
  path_kind="$3"
  parent_path="$(dirname "$candidate_path")" || return 1
  mkdir -p "$parent_path" || return 1
  case "$path_kind" in
    directory) cp -R "$source_path" "$candidate_path" || return 1 ;;
    symlink) cp -P "$source_path" "$candidate_path" || return 1 ;;
    file) cp -p "$source_path" "$candidate_path" || return 1 ;;
    *) return 1 ;;
  esac
  paths_match "$source_path" "$candidate_path" "$path_kind"
}
swap_restore() {
  item_name="$1"
  destination_path="$2"
  candidate_path="$3"
  had_previous="$4"
  if path_exists "$destination_path"; then
    mv "$destination_path" "$FAILED_CURRENT_DIR/$item_name" || return 1
  fi
  if [ "$had_previous" -eq 1 ]; then
    mv "$candidate_path" "$destination_path" || return 1
  fi
}
recovery_failed() {
  recovery_log "$1"
  recovery_log "Recovery data was preserved. Retry exactly: bash '$RECOVERY_DIR/recover.sh'"
  exit 70
}
pid_is_live_non_zombie() {
  candidate_pid="$1"
  kill -0 "$candidate_pid" >/dev/null 2>&1 || return 1
  candidate_state="$(ps -p "$candidate_pid" -o stat= 2>/dev/null | awk '{print $1}')"
  case "$candidate_state" in
    Z*|'') return 1 ;;
    *) return 0 ;;
  esac
}
stop_owned_manual_provider() {
  candidate_pid="$1"
  expected_executable="$2"
  alternate_executable="${3:-}"
  expected_port="${4:-}"
  if [ -n "$expected_port" ]; then
    observed_port_pids="$(lsof -nP -iTCP:"$expected_port" -sTCP:LISTEN -t 2>/dev/null || true)"
    printf '%s\n' "$observed_port_pids" | grep -Fxq "$candidate_pid" || return 1
  fi
  observed_executable="$(lsof -nP -a -p "$candidate_pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
  if [ "$observed_executable" != "$expected_executable" ] && { [ -z "$alternate_executable" ] || [ "$observed_executable" != "$alternate_executable" ]; }; then
    return 1
  fi
  kill -TERM "$candidate_pid" >/dev/null 2>&1 || return 1
  stop_attempt=0
  while [ "$stop_attempt" -lt 20 ] && pid_is_live_non_zombie "$candidate_pid"; do
    sleep 0.1
    stop_attempt=$((stop_attempt + 1))
  done
  if pid_is_live_non_zombie "$candidate_pid"; then
    observed_executable="$(lsof -nP -a -p "$candidate_pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
    if [ "$observed_executable" != "$expected_executable" ] && { [ -z "$alternate_executable" ] || [ "$observed_executable" != "$alternate_executable" ]; }; then
      return 1
    fi
    kill -KILL "$candidate_pid" >/dev/null 2>&1 || return 1
    stop_attempt=0
    while [ "$stop_attempt" -lt 20 ] && pid_is_live_non_zombie "$candidate_pid"; do
      sleep 0.1
      stop_attempt=$((stop_attempt + 1))
    done
  fi
  ! pid_is_live_non_zombie "$candidate_pid"
}
preserve_failed_bootstrap_credential() {
  failed_config="$1"
  restored_config="$2"
  restored_provider_id="$3"
  [ -f "$failed_config" ] || return 0
  python3 - "$failed_config" "$restored_config" "$restored_provider_id" <<'PY'
import json
import os
import re
import sys

failed_path, restored_path, provider_id_path = sys.argv[1:]

def scalar(text, key):
    prefix = key + ":"
    values = [line[len(prefix):].strip() for line in text.splitlines() if line.startswith(prefix)]
    if not values:
        return None
    raw = values[-1]
    if raw.startswith('"'):
        try:
            return json.loads(raw)
        except Exception as error:
            raise SystemExit(f"invalid {key} scalar") from error
    return raw

with open(failed_path, "r", encoding="utf-8") as handle:
    failed_text = handle.read()
provider_id = scalar(failed_text, "provider_id")
token = scalar(failed_text, "provider_token")
if token is None:
    raise SystemExit(0)
if not isinstance(provider_id, str) or re.fullmatch(r"mp-[0-9a-f]{32}", provider_id) is None:
    # Ordinary operator-issued identities are restored from the transaction
    # backup unchanged. Only installer-bootstrap identities participate in
    # durable same-key recovery and therefore need cross-rollback preservation.
    raise SystemExit(0)
if not isinstance(token, str) or re.fullmatch(r"[0-9a-f]{64}", token) is None:
    raise SystemExit(0)

if os.path.exists(restored_path):
    with open(restored_path, "r", encoding="utf-8") as handle:
        restored_text = handle.read()
    lines = [
        line for line in restored_text.splitlines()
        if not line.startswith("provider_id:") and not line.startswith("provider_token:")
    ]
    lines.append("provider_id: " + json.dumps(provider_id))
    lines.append("provider_token: " + token)
    updated = "\n".join(lines) + "\n"
else:
    updated = failed_text if failed_text.endswith("\n") else failed_text + "\n"

parent = os.path.dirname(restored_path)
os.makedirs(parent, mode=0o700, exist_ok=True)
temporary = restored_path + ".credential.tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    handle.write(updated)
    handle.flush()
    os.fsync(handle.fileno())
os.chmod(temporary, 0o600)
os.replace(temporary, restored_path)

provider_id_parent = os.path.dirname(provider_id_path)
os.makedirs(provider_id_parent, mode=0o700, exist_ok=True)
provider_id_temporary = provider_id_path + ".credential.tmp"
with open(provider_id_temporary, "w", encoding="utf-8") as handle:
    handle.write(provider_id + "\n")
    handle.flush()
    os.fsync(handle.fileno())
os.chmod(provider_id_temporary, 0o600)
os.replace(provider_id_temporary, provider_id_path)

for directory in {parent, provider_id_parent}:
    directory_fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
PY
}

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$" || recovery_failed "could not create recovery run id"
INSTALL_CANDIDATE="${REC_INSTALL_DIR}.macprovider-restore.$$"
BINARY_CANDIDATE="${REC_BINARY_PATH}.macprovider-restore.$$"
CONFIG_CANDIDATE="${REC_CONFIG_PATH}.macprovider-restore.$$"
PROVIDER_ID_CANDIDATE="${REC_PROVIDER_ID_PATH}.macprovider-restore.$$"
RECOMMENDATION_CANDIDATE="${REC_RECOMMENDATION_PATH}.macprovider-restore.$$"
PLIST_CANDIDATE="${REC_PLIST_PATH}.macprovider-restore.$$"
WATCHDOG_DIR_CANDIDATE="${REC_WATCHDOG_DIR}.macprovider-restore.$$"
WATCHDOG_PLIST_CANDIDATE="${REC_WATCHDOG_PLIST_PATH}.macprovider-restore.$$"
MANIFEST_CANDIDATE="${REC_MANIFEST_PATH}.macprovider-restore.$$"
FAILED_CURRENT_DIR="$RECOVERY_DIR/failed-current/$RUN_ID"

# Prove every requested restore can be copied byte-for-byte before touching the
# currently installed paths. A failure here leaves both old and new installs as-is.
if [ "$REC_HAD_INSTALL_DIR" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/install-dir" "$INSTALL_CANDIDATE" directory || recovery_failed "could not stage and verify the previous install directory"
fi
if [ "$REC_HAD_BINARY_PATH" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/binary-path" "$BINARY_CANDIDATE" "$REC_BINARY_KIND" || recovery_failed "could not stage and verify the previous CLI path"
fi
if [ "$REC_HAD_CONFIG" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/config.yaml" "$CONFIG_CANDIDATE" file || recovery_failed "could not stage and verify the previous config"
fi
if [ "$REC_HAD_PROVIDER_ID" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/provider_id" "$PROVIDER_ID_CANDIDATE" file || recovery_failed "could not stage and verify the previous provider id"
fi
if [ "$REC_HAD_RECOMMENDATION" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/last-recommendation.json" "$RECOMMENDATION_CANDIDATE" file || recovery_failed "could not stage and verify the previous recommendation"
fi
if [ "$REC_HAD_PLIST" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/provider.plist" "$PLIST_CANDIDATE" file || recovery_failed "could not stage and verify the previous launchd plist"
fi
if [ "$REC_HAD_WATCHDOG_DIR" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/watchdog-dir" "$WATCHDOG_DIR_CANDIDATE" directory || recovery_failed "could not stage and verify the previous watchdog directory"
fi
if [ "$REC_HAD_WATCHDOG_PLIST" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/watchdog.plist" "$WATCHDOG_PLIST_CANDIDATE" file || recovery_failed "could not stage and verify the previous watchdog plist"
fi
if [ "$REC_HAD_MANIFEST" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/install-manifest.json" "$MANIFEST_CANDIDATE" file || recovery_failed "could not stage and verify the previous install manifest"
fi

mkdir -p "$FAILED_CURRENT_DIR" || recovery_failed "could not create durable failed-install storage"
chmod 700 "$RECOVERY_DIR/failed-current" "$FAILED_CURRENT_DIR" || recovery_failed "could not secure durable failed-install storage"
if launchctl print "gui/$REC_UID/live.streamvc.macprovider" >/dev/null 2>&1; then
  launchctl bootout "gui/$REC_UID" "$REC_PLIST_PATH" >/dev/null 2>&1 || recovery_failed "could not stop the current provider service"
fi
if launchctl print "gui/$REC_UID/$REC_WATCHDOG_LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$REC_UID" "$REC_WATCHDOG_PLIST_PATH" >/dev/null 2>&1 || recovery_failed "could not stop the current watchdog service"
fi
if [ -s "$RECOVERY_DIR/new-manual.pid" ]; then
  NEW_MANUAL_PID="$(cat "$RECOVERY_DIR/new-manual.pid")"
  case "$NEW_MANUAL_PID" in
    ''|*[!0-9]*) recovery_failed "recorded manual provider pid is invalid" ;;
  esac
  if pid_is_live_non_zombie "$NEW_MANUAL_PID"; then
    stop_owned_manual_provider "$NEW_MANUAL_PID" "$REC_INSTALL_DIR/macprovider-cli" \
      || recovery_failed "could not stop and prove death of the failed manual provider process"
  fi
fi

swap_restore install-dir "$REC_INSTALL_DIR" "$INSTALL_CANDIDATE" "$REC_HAD_INSTALL_DIR" || recovery_failed "could not restore the previous install directory"
swap_restore binary-path "$REC_BINARY_PATH" "$BINARY_CANDIDATE" "$REC_HAD_BINARY_PATH" || recovery_failed "could not restore the previous CLI path"
swap_restore config.yaml "$REC_CONFIG_PATH" "$CONFIG_CANDIDATE" "$REC_HAD_CONFIG" || recovery_failed "could not restore the previous config"
swap_restore provider_id "$REC_PROVIDER_ID_PATH" "$PROVIDER_ID_CANDIDATE" "$REC_HAD_PROVIDER_ID" || recovery_failed "could not restore the previous provider id"
swap_restore last-recommendation.json "$REC_RECOMMENDATION_PATH" "$RECOMMENDATION_CANDIDATE" "$REC_HAD_RECOMMENDATION" || recovery_failed "could not restore the previous recommendation"
preserve_failed_bootstrap_credential "$FAILED_CURRENT_DIR/config.yaml" "$REC_CONFIG_PATH" "$REC_PROVIDER_ID_PATH" \
  || recovery_failed "could not preserve the installer bootstrap credential through rollback"
swap_restore provider.plist "$REC_PLIST_PATH" "$PLIST_CANDIDATE" "$REC_HAD_PLIST" || recovery_failed "could not restore the previous launchd plist"
swap_restore watchdog-dir "$REC_WATCHDOG_DIR" "$WATCHDOG_DIR_CANDIDATE" "$REC_HAD_WATCHDOG_DIR" || recovery_failed "could not restore the previous watchdog directory"
swap_restore watchdog.plist "$REC_WATCHDOG_PLIST_PATH" "$WATCHDOG_PLIST_CANDIDATE" "$REC_HAD_WATCHDOG_PLIST" || recovery_failed "could not restore the previous watchdog plist"
swap_restore install-manifest.json "$REC_MANIFEST_PATH" "$MANIFEST_CANDIDATE" "$REC_HAD_MANIFEST" || recovery_failed "could not restore the previous install manifest"

if [ "$REC_SERVICE_WAS_DISABLED" -eq 1 ]; then
  launchctl disable "gui/$REC_UID/live.streamvc.macprovider" >/dev/null 2>&1 || recovery_failed "could not restore the disabled provider service state"
else
  launchctl enable "gui/$REC_UID/live.streamvc.macprovider" >/dev/null 2>&1 || recovery_failed "could not restore the enabled provider service state"
fi
if [ "$REC_SERVICE_WAS_ACTIVE" -eq 1 ]; then
  [ "$REC_HAD_PLIST" -eq 1 ] || recovery_failed "previous service was active but no previous plist was preserved"
  launchctl bootstrap "gui/$REC_UID" "$REC_PLIST_PATH" >/dev/null 2>&1 || recovery_failed "could not bootstrap the previous provider service"
  launchctl kickstart -k "gui/$REC_UID/live.streamvc.macprovider" >/dev/null 2>&1 || recovery_failed "could not kickstart the previous provider service"
  launchctl print "gui/$REC_UID/live.streamvc.macprovider" >/dev/null 2>&1 || recovery_failed "previous provider service did not become active"
else
  if launchctl print "gui/$REC_UID/live.streamvc.macprovider" >/dev/null 2>&1; then
    recovery_failed "provider service is active even though it was inactive before the failed install"
  fi
fi

if [ "$REC_WATCHDOG_WAS_DISABLED" -eq 1 ]; then
  launchctl disable "gui/$REC_UID/$REC_WATCHDOG_LABEL" >/dev/null 2>&1 || recovery_failed "could not restore the disabled watchdog service state"
else
  launchctl enable "gui/$REC_UID/$REC_WATCHDOG_LABEL" >/dev/null 2>&1 || recovery_failed "could not restore the enabled watchdog service state"
fi
if [ "$REC_WATCHDOG_WAS_ACTIVE" -eq 1 ]; then
  [ "$REC_HAD_WATCHDOG_PLIST" -eq 1 ] || recovery_failed "previous watchdog was active but no previous plist was preserved"
  launchctl bootstrap "gui/$REC_UID" "$REC_WATCHDOG_PLIST_PATH" >/dev/null 2>&1 || recovery_failed "could not bootstrap the previous watchdog service"
  launchctl kickstart -k "gui/$REC_UID/$REC_WATCHDOG_LABEL" >/dev/null 2>&1 || recovery_failed "could not kickstart the previous watchdog service"
  launchctl print "gui/$REC_UID/$REC_WATCHDOG_LABEL" >/dev/null 2>&1 || recovery_failed "previous watchdog service did not become active"
else
  if launchctl print "gui/$REC_UID/$REC_WATCHDOG_LABEL" >/dev/null 2>&1; then
    recovery_failed "watchdog service is active even though it was inactive before the failed install"
  fi
fi

if [ -s "$RECOVERY_DIR/manual-provider.json" ]; then
  [ "$REC_SERVICE_WAS_ACTIVE" -eq 0 ] || recovery_failed "manual provider record conflicts with an active prior launchd service"
  mkdir -p "$REC_LOG_DIR" || recovery_failed "could not recreate the previous manual provider log directory"
  python3 - "$RECOVERY_DIR/manual-provider.json" "$REC_INSTALL_DIR/macprovider-cli" \
    "$REC_LOG_DIR/macprovider.out.log" "$REC_LOG_DIR/macprovider.err.log" \
    "$RECOVERY_DIR/manual-restored.pid" "$REC_MANUAL_READY_TIMEOUT_SECONDS" <<'PY' \
    || recovery_failed "could not restart the previous manual provider safely"
import base64
import hashlib
import json
import os
import subprocess
import sys
import time

record_path, executable, stdout_path, stderr_path, pid_path, timeout_text = sys.argv[1:]
with open(record_path, "r", encoding="utf-8") as handle:
    record = json.load(handle)
if set(record) != {"version", "arguments_b64", "environment_b64", "working_directory_b64", "binary_sha256", "port"} or record["version"] != 3:
    raise SystemExit("invalid manual provider recovery schema")
encoded_arguments = record["arguments_b64"]
if not isinstance(encoded_arguments, list) or len(encoded_arguments) > 128:
    raise SystemExit("invalid manual provider arguments")
arguments = []
for encoded in encoded_arguments:
    if not isinstance(encoded, str) or len(encoded) > 8192:
        raise SystemExit("invalid manual provider argument encoding")
    try:
        argument = base64.b64decode(encoded, validate=True)
    except Exception as error:
        raise SystemExit("invalid manual provider argument encoding") from error
    if base64.b64encode(argument).decode("ascii") != encoded or b"\x00" in argument or len(argument) > 4096:
        raise SystemExit("invalid manual provider argument encoding")
    arguments.append(argument)
if sum(map(len, arguments)) > 65536:
    raise SystemExit("manual provider argument bounds exceeded")
try:
    working_directory = base64.b64decode(record["working_directory_b64"], validate=True)
except Exception as error:
    raise SystemExit("invalid manual provider working directory") from error
if (base64.b64encode(working_directory).decode("ascii") != record["working_directory_b64"]
        or b"\x00" in working_directory or not working_directory.startswith(b"/")
        or len(working_directory) > 4096 or not os.path.isdir(working_directory)):
    raise SystemExit("invalid manual provider working directory")
encoded_environment = record["environment_b64"]
if not isinstance(encoded_environment, list) or len(encoded_environment) > 512:
    raise SystemExit("invalid manual provider environment")
environment = {}
environment_bytes = 0
for encoded in encoded_environment:
    if not isinstance(encoded, str) or len(encoded) > 16384:
        raise SystemExit("invalid manual provider environment encoding")
    try:
        entry = base64.b64decode(encoded, validate=True)
    except Exception as error:
        raise SystemExit("invalid manual provider environment encoding") from error
    if base64.b64encode(entry).decode("ascii") != encoded or b"\x00" in entry or len(entry) > 8192 or b"=" not in entry:
        raise SystemExit("invalid manual provider environment encoding")
    key, value = entry.split(b"=", 1)
    if not key or b"=" in key or key in environment:
        raise SystemExit("invalid manual provider environment key")
    environment[key] = value
    environment_bytes += len(entry)
if environment_bytes > 262144:
    raise SystemExit("manual provider environment bounds exceeded")
port = record["port"]
if isinstance(port, bool) or not isinstance(port, int) or not 1024 <= port <= 65535:
    raise SystemExit("invalid manual provider port")
expected_port = str(port).encode("ascii")
if not any(
    (argument == b"--port" and index + 1 < len(arguments) and arguments[index + 1] == expected_port)
    or argument == b"--port=" + expected_port
    for index, argument in enumerate(arguments)
):
    raise SystemExit("manual provider port binding missing")
with open(executable, "rb") as handle:
    digest = hashlib.sha256(handle.read()).hexdigest()
if digest != record["binary_sha256"]:
    raise SystemExit("restored manual provider binary does not match captured last-known-good binary")
try:
    ready_timeout = int(timeout_text)
except ValueError as error:
    raise SystemExit("invalid manual provider readiness timeout") from error
if not 1 <= ready_timeout <= 60:
    raise SystemExit("invalid manual provider readiness timeout")

process = None
cleanup_armed = False
temporary = pid_path + ".tmp"
try:
    with open(stdout_path, "ab", buffering=0) as stdout, open(stderr_path, "ab", buffering=0) as stderr:
        process = subprocess.Popen(
            [os.fsencode(executable), *arguments], cwd=working_directory, env=environment,
            stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
            start_new_session=True, close_fds=True,
        )
        cleanup_armed = True
    deadline = time.monotonic() + ready_timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("restored manual provider exited before binding its previous port")
        probe = subprocess.run(
            ["lsof", "-nP", "-a", "-p", str(process.pid), f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
            check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=2,
        )
        owners = [line.strip() for line in probe.stdout.splitlines() if line.strip()]
        if probe.returncode == 0 and owners and all(owner == str(process.pid).encode("ascii") for owner in owners):
            with open(temporary, "w", encoding="ascii") as handle:
                handle.write(f"{process.pid}\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, pid_path)
            directory_fd = os.open(os.path.dirname(pid_path), os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
            cleanup_armed = False
            break
        time.sleep(0.1)
    else:
        raise RuntimeError("restored manual provider did not bind its previous port")
except BaseException as original_error:
    cleanup_error = None
    if cleanup_armed and process is not None:
        try:
            if process.poll() is None:
                terminate_error = None
                try:
                    process.terminate()
                except ProcessLookupError:
                    pass
                except BaseException as error:
                    terminate_error = error
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    try:
                        process.kill()
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=2)
            if process.poll() is None:
                detail = f" after TERM error {terminate_error}" if terminate_error is not None else ""
                raise RuntimeError(f"restored manual provider pid {process.pid} survived TERM/KILL cleanup{detail}")
        except BaseException as error:
            cleanup_error = error
    for path in (temporary, pid_path):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
    if cleanup_error is not None:
        raise RuntimeError(f"manual provider recovery failed and cleanup could not prove death: {cleanup_error}") from original_error
    raise
PY
  RESTORED_MANUAL_PID="$(cat "$RECOVERY_DIR/manual-restored.pid")"
  case "$RESTORED_MANUAL_PID" in
    ''|*[!0-9]*) recovery_failed "restored manual provider pid is invalid" ;;
  esac
  recovery_log "Restored prior manual provider pid=$RESTORED_MANUAL_PID with exact prior argv and port ownership."
fi

recovery_log "Previous provider, recommendation, watchdog, manifest, service, and manual-process states were restored and verified."
exit 0
RECOVERY_SCRIPT
  chmod 700 "$recovery_script" || return 1
  bash -n "$recovery_script" || return 1
  observer_script="$recovery_dir/observe.sh"
  cat > "$observer_script" <<'OBSERVER_SCRIPT'
#!/usr/bin/env bash
set -u

RECOVERY_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 70
# shellcheck disable=SC1091
. "$RECOVERY_DIR/state.sh" || exit 70

process_start() {
  ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

while [ -d "$RECOVERY_DIR" ] \
  && [ "$(sysctl -n kern.bootsessionuuid 2>/dev/null || true)" = "$REC_INSTALLER_BOOT_SESSION" ] \
  && [ "$(process_start "$REC_INSTALLER_PID")" = "$REC_INSTALLER_PROCESS_START" ]; do
  sleep 1
done

[ -d "$RECOVERY_DIR" ] || exit 0
exec python3 - "$RECOVERY_DIR" "$REC_INSTALL_LOCK_PATH" \
  "$REC_INSTALL_RECOVERY_PLIST_PATH" "$REC_UID" "$REC_INSTALL_RECOVERY_LABEL" <<'PY'
import fcntl
import os
import shutil
import stat
import subprocess
import sys

recovery_dir, lock_path, plist_path, uid, label = sys.argv[1:]
lock_fd = os.open(lock_path, os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
try:
    info = os.fstat(lock_fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise SystemExit("unsafe installer lock; automatic recovery refused")
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    if not os.path.isdir(recovery_dir):
        raise SystemExit(0)
    result = subprocess.run(["bash", os.path.join(recovery_dir, "recover.sh")], check=False)
    if result.returncode == 75:
        raise SystemExit(0)
    if result.returncode != 0:
        print(
            f"[macprovider-recovery] Automatic interrupted-install recovery failed. "
            f"Run exactly: bash {os.path.join(recovery_dir, 'recover.sh')!r}",
            file=sys.stderr,
        )
        raise SystemExit(result.returncode)
    shutil.rmtree(recovery_dir)
    try:
        os.unlink(plist_path)
    except FileNotFoundError:
        pass
    subprocess.run(
        ["launchctl", "bootout", f"gui/{uid}/{label}"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
finally:
    os.close(lock_fd)
PY
OBSERVER_SCRIPT
  chmod 700 "$observer_script" || return 1
  bash -n "$observer_script" || return 1
  [ -s "$state_path" ] && [ -s "$recovery_script" ] && [ -s "$observer_script" ]
}

disarm_install_recovery_agent() {
  launchctl bootout "gui/$UID/$INSTALL_RECOVERY_LABEL" >/dev/null 2>&1 || true
  rm -f "$INSTALL_RECOVERY_PLIST_PATH"
}

arm_install_recovery_agent() {
  [ -n "$INSTALL_TX_BACKUP" ] && [ -x "$INSTALL_TX_BACKUP/observe.sh" ] || return 70
  mkdir -p "$(dirname "$INSTALL_RECOVERY_PLIST_PATH")" || return 70
  disarm_install_recovery_agent || return 70
  plist_temp="${INSTALL_RECOVERY_PLIST_PATH}.tmp.$$"
  python3 - "$plist_temp" "$INSTALL_RECOVERY_LABEL" "$INSTALL_TX_BACKUP/observe.sh" \
    "$INSTALL_TX_BACKUP/recovery-observer.out.log" "$INSTALL_TX_BACKUP/recovery-observer.err.log" <<'PY'
import os
import plistlib
import sys

path, label, observer, stdout_path, stderr_path = sys.argv[1:]
payload = {
    "Label": label,
    "ProgramArguments": ["/bin/bash", observer],
    "RunAtLoad": True,
    "KeepAlive": False,
    "StandardOutPath": stdout_path,
    "StandardErrorPath": stderr_path,
}
with open(path, "wb") as handle:
    plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=True)
    handle.flush()
    os.fsync(handle.fileno())
os.chmod(path, 0o600)
PY
  mv "$plist_temp" "$INSTALL_RECOVERY_PLIST_PATH" || return 70
  launchctl bootstrap "gui/$UID" "$INSTALL_RECOVERY_PLIST_PATH" >/dev/null 2>&1 || return 70
  launchctl kickstart -k "gui/$UID/$INSTALL_RECOVERY_LABEL" >/dev/null 2>&1 || return 70
}

launchd_label_is_disabled() {
  label="$1"
  disabled_state="$(launchctl print-disabled "gui/$UID" 2>/dev/null || true)"
  case "$disabled_state" in
    *'"'"$label"'" => true'*) return 0 ;;
    *) return 1 ;;
  esac
}

capture_manual_provider_for_recovery() {
  manual_pid="$1"
  [ "$INSTALL_TX_ACTIVE" -eq 1 ] || die 70 "manual provider capture requires an active install transaction"
  [ "$INSTALL_TX_SERVICE_WAS_ACTIVE" -eq 0 ] || return 0
  case "$manual_pid" in
    ''|*[!0-9]*) die 70 "manual provider pid is invalid" ;;
  esac
  manual_executable="$(lsof -nP -a -p "$manual_pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
  [ -n "$manual_executable" ] \
    || die 70 "could not capture the existing manual provider invocation before stopping it"
  manual_cwd="$(lsof -nP -a -p "$manual_pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
  [ -n "$manual_cwd" ] \
    || die 70 "could not capture the existing manual provider working directory before stopping it"
  python3 - "$manual_pid" "$manual_executable" "$INSTALL_DIR/macprovider-cli" "$BINARY_PATH" \
    "$manual_cwd" "$PORT" "$INSTALL_TX_BACKUP/manual-provider.json" <<'PY' \
    || die 70 "existing manual provider invocation was not safe to preserve; current provider was left running"
import base64
import ctypes
import hashlib
import json
import os
import struct
import sys

pid_text, observed_executable, install_executable, path_executable, observed_cwd, port, output = sys.argv[1:]
if sys.platform != "darwin":
    raise SystemExit("exact process argv capture requires macOS KERN_PROCARGS2")
try:
    pid = int(pid_text)
except ValueError as error:
    raise SystemExit("invalid manual provider pid") from error
observed = os.path.realpath(observed_executable)
trusted = {os.path.realpath(path) for path in (install_executable, path_executable) if os.path.exists(path)}
if observed not in trusted:
    raise SystemExit("manual provider executable is not a trusted installed macprovider-cli")

libc = ctypes.CDLL(None, use_errno=True)
libc.sysctlbyname.argtypes = [
    ctypes.c_char_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t,
]
libc.sysctlbyname.restype = ctypes.c_int
libc.sysctl.argtypes = [
    ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t,
]
libc.sysctl.restype = ctypes.c_int
argmax = ctypes.c_int()
argmax_size = ctypes.c_size_t(ctypes.sizeof(argmax))
if libc.sysctlbyname(b"kern.argmax", ctypes.byref(argmax), ctypes.byref(argmax_size), None, 0) != 0:
    raise OSError(ctypes.get_errno(), "sysctl kern.argmax failed")
if argmax.value <= ctypes.sizeof(ctypes.c_int) or argmax.value > 16 * 1024 * 1024:
    raise SystemExit("invalid kern.argmax value")
mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2, pid
buffer = ctypes.create_string_buffer(argmax.value)
buffer_size = ctypes.c_size_t(argmax.value)
if libc.sysctl(mib, 3, buffer, ctypes.byref(buffer_size), None, 0) != 0:
    raise OSError(ctypes.get_errno(), "sysctl KERN_PROCARGS2 failed")
data = buffer.raw[:buffer_size.value]
if len(data) < ctypes.sizeof(ctypes.c_int):
    raise SystemExit("truncated KERN_PROCARGS2 result")
argc = struct.unpack_from("=i", data)[0]
if not 1 <= argc <= 129:
    raise SystemExit("invalid KERN_PROCARGS2 argc")
offset = ctypes.sizeof(ctypes.c_int)
executable_end = data.find(b"\x00", offset)
if executable_end <= offset:
    raise SystemExit("missing KERN_PROCARGS2 executable")
kernel_executable = data[offset:executable_end]
offset = executable_end
while offset < len(data) and data[offset] == 0:
    offset += 1
argv = []
for _ in range(argc):
    argument_end = data.find(b"\x00", offset)
    if argument_end < offset:
        raise SystemExit("truncated KERN_PROCARGS2 argv")
    argv.append(data[offset:argument_end])
    offset = argument_end + 1
if os.path.realpath(os.fsdecode(kernel_executable)) != observed:
    raise SystemExit("kernel process executable does not match the observed executable")
if not argv or os.path.realpath(os.fsdecode(argv[0])) != observed:
    raise SystemExit("kernel argv executable does not match the observed executable")
arguments = argv[1:]
if len(arguments) > 128 or any(b"\x00" in argument or len(argument) > 4096 for argument in arguments):
    raise SystemExit("manual provider argument bounds exceeded")
if sum(map(len, arguments)) > 65536:
    raise SystemExit("manual provider argument bounds exceeded")
environment = []
while offset < len(data):
    entry_end = data.find(b"\x00", offset)
    if entry_end < offset:
        raise SystemExit("truncated KERN_PROCARGS2 environment")
    if entry_end == offset:
        break
    entry = data[offset:entry_end]
    if b"=" not in entry:
        break
    environment.append(entry)
    offset = entry_end + 1
if len(environment) > 512 or any(len(entry) > 8192 for entry in environment) or sum(map(len, environment)) > 262144:
    raise SystemExit("manual provider environment bounds exceeded")
environment_keys = [entry.split(b"=", 1)[0] for entry in environment]
if any(not key or b"=" in key for key in environment_keys) or len(set(environment_keys)) != len(environment_keys):
    raise SystemExit("manual provider environment is invalid")
# ADV-C1: never serialize a secret to disk. Drop the provider bearer and any
# token/secret/key/password/bearer-shaped env entry from the recovery snapshot.
# The restored serving child obtains its bearer from Keychain (app-managed) or
# its 0600 config/token-file (CLI track), not from this recovered environment.
def _is_secret_env_key(key):
    upper = key.upper()
    if upper == b"MACPROVIDER_PROVIDER_TOKEN":
        return True
    for needle in (b"TOKEN", b"SECRET", b"PASSWORD", b"PASSWD", b"BEARER", b"APIKEY"):
        if needle in upper:
            return True
    return upper.endswith(b"_KEY") or upper == b"KEY"
environment = [
    entry for entry in environment if not _is_secret_env_key(entry.split(b"=", 1)[0])
]
working_directory = os.path.realpath(observed_cwd)
if not os.path.isabs(working_directory) or not os.path.isdir(working_directory):
    raise SystemExit("manual provider working directory is invalid")
port_bytes = port.encode("ascii")
if not any(
    (argument == b"--port" and index + 1 < len(arguments) and arguments[index + 1] == port_bytes)
    or argument == b"--port=" + port_bytes
    for index, argument in enumerate(arguments)
):
    raise SystemExit("manual provider does not bind the installer target port")
with open(observed, "rb") as handle:
    digest = hashlib.sha256(handle.read()).hexdigest()
record = {
    "version": 3,
    "arguments_b64": [base64.b64encode(argument).decode("ascii") for argument in arguments],
    "environment_b64": [base64.b64encode(entry).decode("ascii") for entry in environment],
    "working_directory_b64": base64.b64encode(os.fsencode(working_directory)).decode("ascii"),
    "binary_sha256": digest,
    "port": int(port),
}
temporary = output + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(record, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.chmod(temporary, 0o600)
os.replace(temporary, output)
directory_fd = os.open(os.path.dirname(output), os.O_RDONLY)
try:
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
PY
}

pid_is_live_non_zombie() {
  candidate_pid="$1"
  kill -0 "$candidate_pid" >/dev/null 2>&1 || return 1
  candidate_state="$(ps -p "$candidate_pid" -o stat= 2>/dev/null | awk '{print $1}')"
  case "$candidate_state" in
    Z*|'') return 1 ;;
    *) return 0 ;;
  esac
}

stop_owned_manual_provider() {
  candidate_pid="$1"
  expected_executable="$2"
  alternate_executable="${3:-}"
  expected_port="${4:-}"
  if [ -n "$expected_port" ]; then
    observed_port_pids="$(lsof -nP -iTCP:"$expected_port" -sTCP:LISTEN -t 2>/dev/null || true)"
    printf '%s\n' "$observed_port_pids" | grep -Fxq "$candidate_pid" || return 1
  fi
  observed_executable="$(lsof -nP -a -p "$candidate_pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
  if [ "$observed_executable" != "$expected_executable" ] && { [ -z "$alternate_executable" ] || [ "$observed_executable" != "$alternate_executable" ]; }; then
    return 1
  fi
  kill -TERM "$candidate_pid" >/dev/null 2>&1 || return 1
  stop_attempt=0
  while [ "$stop_attempt" -lt 20 ] && pid_is_live_non_zombie "$candidate_pid"; do
    sleep 0.1
    stop_attempt=$((stop_attempt + 1))
  done
  if pid_is_live_non_zombie "$candidate_pid"; then
    observed_executable="$(lsof -nP -a -p "$candidate_pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
    if [ "$observed_executable" != "$expected_executable" ] && { [ -z "$alternate_executable" ] || [ "$observed_executable" != "$alternate_executable" ]; }; then
      return 1
    fi
    kill -KILL "$candidate_pid" >/dev/null 2>&1 || return 1
    stop_attempt=0
    while [ "$stop_attempt" -lt 20 ] && pid_is_live_non_zombie "$candidate_pid"; do
      sleep 0.1
      stop_attempt=$((stop_attempt + 1))
    done
  fi
  if ! pid_is_live_non_zombie "$candidate_pid"; then
    wait "$candidate_pid" >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

begin_install_transaction() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  assert_install_lock_ownership
  recovery_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  recovery_staging="$CONFIG_DIR/install-recovery-$recovery_id.staging"
  INSTALL_TX_BACKUP="$CONFIG_DIR/install-recovery-$recovery_id"
  mkdir -p "$CONFIG_DIR" || die 70 "could not create config directory for durable install recovery"
  mkdir "$recovery_staging" || die 70 "could not create durable install recovery staging directory: $recovery_staging"
  chmod 700 "$recovery_staging" \
    || die 70 "could not secure durable install recovery staging directory: $recovery_staging"
  if [ -d "$INSTALL_DIR" ]; then
    stage_install_tx_path "$INSTALL_DIR" "$recovery_staging/install-dir" directory \
      || die 70 "could not stage and verify the previous install directory; current install was not changed (partial recovery data: $recovery_staging)"
    INSTALL_TX_HAD_INSTALL_DIR=1
  fi
  if [ -e "$BINARY_PATH" ] || [ -L "$BINARY_PATH" ]; then
    if [ -L "$BINARY_PATH" ]; then
      INSTALL_TX_BINARY_KIND="symlink"
      stage_install_tx_path "$BINARY_PATH" "$recovery_staging/binary-path" symlink \
        || die 70 "could not stage and verify the previous CLI path; current install was not changed (partial recovery data: $recovery_staging)"
    else
      INSTALL_TX_BINARY_KIND="file"
      stage_install_tx_path "$BINARY_PATH" "$recovery_staging/binary-path" file \
        || die 70 "could not stage and verify the previous CLI path; current install was not changed (partial recovery data: $recovery_staging)"
    fi
    INSTALL_TX_HAD_BINARY_PATH=1
  fi
  if [ -f "$CONFIG_PATH" ]; then
    stage_install_tx_path "$CONFIG_PATH" "$recovery_staging/config.yaml" file \
      || die 70 "could not stage and verify the previous config; current install was not changed (partial recovery data: $recovery_staging)"
    INSTALL_TX_HAD_CONFIG=1
  fi
  if [ -f "$PROVIDER_ID_PATH" ]; then
    stage_install_tx_path "$PROVIDER_ID_PATH" "$recovery_staging/provider_id" file \
      || die 70 "could not stage and verify the previous provider id; current install was not changed (partial recovery data: $recovery_staging)"
    INSTALL_TX_HAD_PROVIDER_ID=1
  fi
  if [ -f "$RECOMMENDATION_PATH" ]; then
    stage_install_tx_path "$RECOMMENDATION_PATH" "$recovery_staging/last-recommendation.json" file \
      || die 70 "could not stage and verify the previous recommendation; current install was not changed (partial recovery data: $recovery_staging)"
    INSTALL_TX_HAD_RECOMMENDATION=1
  fi
  if [ -f "$PLIST_PATH" ]; then
    stage_install_tx_path "$PLIST_PATH" "$recovery_staging/provider.plist" file \
      || die 70 "could not stage and verify the previous launchd plist; current install was not changed (partial recovery data: $recovery_staging)"
    INSTALL_TX_HAD_PLIST=1
  fi
  if [ -d "$WATCHDOG_DIR" ]; then
    stage_install_tx_path "$WATCHDOG_DIR" "$recovery_staging/watchdog-dir" directory \
      || die 70 "could not stage and verify the previous watchdog directory; current install was not changed (partial recovery data: $recovery_staging)"
    INSTALL_TX_HAD_WATCHDOG_DIR=1
  fi
  if [ -f "$WATCHDOG_PLIST_PATH" ]; then
    stage_install_tx_path "$WATCHDOG_PLIST_PATH" "$recovery_staging/watchdog.plist" file \
      || die 70 "could not stage and verify the previous watchdog plist; current install was not changed (partial recovery data: $recovery_staging)"
    INSTALL_TX_HAD_WATCHDOG_PLIST=1
  fi
  if [ -f "$MANIFEST_PATH" ]; then
    stage_install_tx_path "$MANIFEST_PATH" "$recovery_staging/install-manifest.json" file \
      || die 70 "could not stage and verify the previous install manifest; current install was not changed (partial recovery data: $recovery_staging)"
    INSTALL_TX_HAD_MANIFEST=1
  fi
  if [ "$INSTALL_TX_HAD_INSTALL_DIR" -eq 1 ] || [ "$INSTALL_TX_HAD_BINARY_PATH" -eq 1 ] || [ "$INSTALL_TX_HAD_MANIFEST" -eq 1 ]; then
    EXISTING_INSTALL_WAS_PRESENT=1
  fi
  if launchctl print "gui/$UID/live.streamvc.macprovider" >/dev/null 2>&1; then
    INSTALL_TX_SERVICE_WAS_ACTIVE=1
  fi
  if launchd_label_is_disabled "live.streamvc.macprovider"; then
    INSTALL_TX_SERVICE_WAS_DISABLED=1
  fi
  if launchctl print "gui/$UID/$WATCHDOG_LABEL" >/dev/null 2>&1; then
    INSTALL_TX_WATCHDOG_WAS_ACTIVE=1
  fi
  if launchd_label_is_disabled "$WATCHDOG_LABEL"; then
    INSTALL_TX_WATCHDOG_WAS_DISABLED=1
  fi
  write_install_recovery_artifacts "$recovery_staging" \
    || die 70 "could not create verified recovery instructions; current install was not changed (partial recovery data: $recovery_staging)"
  mv "$recovery_staging" "$INSTALL_TX_BACKUP" \
    || die 70 "could not publish durable recovery data; current install was not changed (partial recovery data: $recovery_staging)"
  INSTALL_TX_ACTIVE=1
  assert_install_lock_ownership
  arm_install_recovery_agent \
    || die 70 "could not arm independent interrupted-install recovery before live mutation"
  if [ "$INSTALL_TX_WATCHDOG_WAS_ACTIVE" -eq 1 ]; then
    launchctl bootout "gui/$UID" "$WATCHDOG_PLIST_PATH" >/dev/null 2>&1 \
      || die 70 "could not suspend the existing watchdog for the protected install transaction"
  fi
}

rollback_install_transaction() {
  if [ "$INSTALL_TX_ROLLING_BACK" -eq 1 ]; then
    return 70
  fi
  INSTALL_TX_ROLLING_BACK=1
  log "Install did not pass admission; restoring the previous provider installation."
  if [ -n "$MANUAL_PID" ] && pid_is_live_non_zombie "$MANUAL_PID"; then
    if ! stop_owned_manual_provider "$MANUAL_PID" "$INSTALL_DIR/macprovider-cli"; then
      log "ERROR: could not stop and prove death of the failed manual provider process; recovery data was preserved at $INSTALL_TX_BACKUP"
      INSTALL_TX_ROLLING_BACK=0
      return 70
    fi
  fi
  if ! bash "$INSTALL_TX_BACKUP/recover.sh"; then
    log "ERROR: automatic rollback failed; recovery data was preserved at $INSTALL_TX_BACKUP"
    log "Run exactly: bash '$INSTALL_TX_BACKUP/recover.sh'"
    INSTALL_TX_ROLLING_BACK=0
    return 70
  fi
  if ! disarm_install_recovery_agent; then
    log "ERROR: rollback succeeded but the interrupted-install recovery agent could not be disarmed"
    INSTALL_TX_ROLLING_BACK=0
    return 70
  fi
  if ! rm -rf "$INSTALL_TX_BACKUP"; then
    log "ERROR: rollback succeeded but verified recovery data could not be removed: $INSTALL_TX_BACKUP"
    log "Run exactly if recovery is needed again: bash '$INSTALL_TX_BACKUP/recover.sh'"
    INSTALL_TX_ROLLING_BACK=0
    return 70
  fi
  log "Previous provider files and service state were restored and verified."
  INSTALL_TX_ACTIVE=0
  INSTALL_TX_ROLLING_BACK=0
}

commit_install_transaction() {
  assert_install_lock_ownership
  if [ -n "$INSTALL_TX_BACKUP" ] && [ -d "$INSTALL_TX_BACKUP" ]; then
    retired_recovery="${INSTALL_TX_BACKUP}.committed.$$"
    mv "$INSTALL_TX_BACKUP" "$retired_recovery" \
      || die 70 "new install passed admission but durable recovery data could not be retired: $INSTALL_TX_BACKUP"
    # Crossing this rename is the no-rollback boundary. From here onward the
    # recovery bundle cannot be mistaken for an active transaction even if
    # best-effort cleanup fails partway through.
    INSTALL_TX_COMMITTED=1
    INSTALL_TX_ACTIVE=0
    disarm_install_recovery_agent \
      || die 70 "new install committed but interrupted-install recovery could not be disarmed"
    if ! rm -rf "$retired_recovery"; then
      log "WARNING: install committed but retired recovery data could not be removed: $retired_recovery"
    fi
    return 0
  fi
  INSTALL_TX_COMMITTED=1
  INSTALL_TX_ACTIVE=0
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf "[dry-run] "
    printf "%q " "$@"
    printf "\n"
  else
    "$@"
  fi
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die 2 "missing required tool: $1"
}

read_line() {
  REPLY=""
  # In curl-pipe-bash invocations, /dev/tty often exists as a character
  # device but `read < /dev/tty` fails with "Device not configured" and
  # prints noise to stderr. Suppress that noise + fall through to empty
  # REPLY (callers use defaults via $NO_PROMPT or prompt_yes_no's default
  # arg). v1.2.1 install.sh's `[ -r /dev/tty ]` check passed when the
  # device existed but the read still failed; v1.2.2 silences the
  # failure path.
  # Try to open /dev/tty via fd 4; the { exec ...; } 2>/dev/null pattern
  # is necessary because bash's input-redirection failure on `< /dev/tty`
  # prints to stderr BEFORE the `2>/dev/null` on the read line takes
  # effect. By opening explicitly here and silencing stderr on the exec,
  # we cleanly detect "is /dev/tty actually usable" without noise.
  if [ -c /dev/tty ] && { exec 4</dev/tty; } 2>/dev/null; then
    IFS= read -r REPLY <&4 2>/dev/null || REPLY=""
    exec 4<&-
  else
    IFS= read -r REPLY 2>/dev/null || REPLY=""
  fi
}

# v1.2.2: pre-flight port collision detection. Without this, install
# proceeds, launchd loads, the binary crashes on bind, and the timeout
# path hides the real cause. Surface the collision early with a clear fix.
ensure_port_free() {
  stop_own_provider="${1:-0}"
  if [ "$DRY_RUN" -eq 1 ]; then
    return
  fi
  if [ "$stop_own_provider" -eq 1 ]; then
    assert_install_lock_ownership
  fi
  validate_port_value "$PORT"
  if ! command -v lsof >/dev/null 2>&1; then
    die 2 "missing required tool: lsof"
  fi
  holding_pids="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
  if [ -z "$holding_pids" ]; then
    return
  fi
  holding_cmd="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1 " (pid " $2 ")"}')"

  # F-603-V7-2: an existing macprovider-cli on this port is the normal
  # upgrade-in-place case. Stop that service and continue; only foreign
  # holders should block the install.
  own_provider_holds_port=0
  for holding_pid in $holding_pids; do
    holding_executable="$(lsof -a -p "$holding_pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
    if [ "$holding_executable" = "$INSTALL_DIR/macprovider-cli" ]; then
      own_provider_holds_port=1
      break
    fi
  done
  if [ "$own_provider_holds_port" -eq 1 ]; then
    if [ "$stop_own_provider" != "1" ]; then
      log "Existing macprovider-cli holding port $PORT; will stop it after release verification."
      return
    fi
    log "Existing macprovider-cli holding port $PORT; stopping it for upgrade-in-place."
    if [ "$INSTALL_TX_SERVICE_WAS_ACTIVE" -eq 0 ]; then
      case "$holding_pids" in
        *$'\n'*) die 70 "multiple manual macprovider-cli processes hold port $PORT; refusing ambiguous recovery capture" ;;
      esac
      capture_manual_provider_for_recovery "$holding_pids"
    fi
    launchctl bootout "gui/$UID" "$PLIST_PATH" 2>/dev/null || true
    sleep 2
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | grep -q .; then
      log "Port $PORT still held after launchctl bootout; stopping each revalidated macprovider-cli PID."
      for holding_pid in $holding_pids; do
        if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | grep -Fxq "$holding_pid"; then
          stop_owned_manual_provider "$holding_pid" "$INSTALL_DIR/macprovider-cli" "$BINARY_PATH" "$PORT" \
            || die 70 "could not safely stop macprovider-cli pid $holding_pid after revalidating executable and port ownership"
        fi
      done
    fi
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | grep -q .; then
      die 6 "could not stop existing macprovider-cli on port $PORT; please stop manually and retry"
    fi
    log "Port $PORT freed; proceeding with upgrade."
    return
  fi

  log "ERROR: port $PORT is already in use by ${holding_cmd:-another process}."
  log "Either stop that process, or set MACPROVIDER_PORT to a free port and re-run."
  log "Note: env var must be on the bash side of the pipe, not the curl side:"
  log "  curl -fsSL https://get.streamvc.live/install.sh | MACPROVIDER_PORT=18080 bash"
  die 6 "port $PORT busy; macprovider-cli cannot bind"
}

prompt_yes_no() {
  prompt="$1"
  default="$2"
  if [ "$NO_PROMPT" = "1" ]; then
    log "$prompt $default (non-interactive default)"
    [ "$default" = "Y" ]
    return
  fi

  printf "%s " "$prompt"
  read_line
  answer="$REPLY"
  answer="${answer:-$default}"
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    n|N|no|NO) return 1 ;;
    *) return 1 ;;
  esac
}

reject_newlines() {
  name="$1"
  value="$2"
  case "$value" in
    *$'\n'*|*$'\r'*) die 7 "$name must not contain newlines" ;;
  esac
}

xml_escape() {
  printf "%s" "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

yaml_escape() {
  printf "%s" "$1" | sed \
    -e 's/\\/\\\\/g' \
    -e 's/"/\\"/g'
}

json_escape() {
  printf "%s" "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

urlencode() {
  local input="$1"
  local output=""
  local i char hex
  for ((i = 0; i < ${#input}; i++)); do
    char="${input:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-]) output="${output}${char}" ;;
      *) printf -v hex '%%%02X' "'$char"; output="${output}${hex}" ;;
    esac
  done
  printf "%s" "$output"
}

coordinator_http_base() {
  coordinator_url="$1"
  case "$coordinator_url" in
    wss://coordinator.streamvc.live/ws/provider) printf "%s" "$COORDINATOR_BASE_DEFAULT" ;;
    wss://*) printf "https://%s" "${coordinator_url#wss://}" | sed -E 's#/ws/provider/?$##' ;;
    *) die 7 "coordinator URL must start with wss://" ;;
  esac
}

advisory_validate_referral() {
  local coordinator_base="$1"
  local payload response result
  payload="$(MACPROVIDER_CONFIG_REFERRAL_CODE="$REFERRAL_CODE" python3 -c 'import json,os; print(json.dumps({"code": os.environ.pop("MACPROVIDER_CONFIG_REFERRAL_CODE", "")}))')" \
    || return 0
  if ! response="$(printf "%s" "$payload" | curl -fsS --max-time 8 \
      -H 'Content-Type: application/json' -H 'Accept: application/json' \
      --data-binary @- "$coordinator_base/v1/referrals/validate" 2>/dev/null)"; then
    log "Invite pre-check unavailable; authoritative validation will run during credential registration."
    return 0
  fi
  result="$(printf "%s" "$response" | python3 -c 'import json,sys
try:
 d=json.load(sys.stdin); print(("valid" if d.get("valid") else "invalid") + ":" + str(d.get("reason", "invalid")))
except Exception: print("unavailable:invalid")')"
  case "$result" in
    valid:*) return 0 ;;
    invalid:expired) die 7 "referral code has expired; use a different invite" ;;
    invalid:revoked) die 7 "referral code is no longer available; use a different invite" ;;
    invalid:exhausted) die 7 "referral code has already been used; use a different invite" ;;
    invalid:*) die 7 "referral code is not valid; check it or use a different invite" ;;
    *) log "Invite pre-check response was unavailable; authoritative validation will run during credential registration." ;;
  esac
}

# PROD-H1: claim referral capacity at preflight and carry the reservation id into
# the owned config so the credential mint consumes the SAME reservation instead
# of racing a fresh one at the end of a long install. Reservation is idempotent
# per (campaign, provider_id); the register path reuses it. Network-unavailable
# is non-fatal (authoritative validation + inline reservation still run at mint).
reserve_referral_capacity() {
  local coordinator_base="$1"
  local provider_id_value="$2"
  local payload response result
  [ -n "$REFERRAL_CODE" ] || return 0
  payload="$(MACPROVIDER_CONFIG_REFERRAL_CODE="$REFERRAL_CODE" \
    MACPROVIDER_CONFIG_PROVIDER_ID="$provider_id_value" \
    python3 -c 'import json,os; print(json.dumps({"code": os.environ.pop("MACPROVIDER_CONFIG_REFERRAL_CODE", ""), "provider_id": os.environ.pop("MACPROVIDER_CONFIG_PROVIDER_ID", "")}))')" \
    || return 0
  if ! response="$(printf "%s" "$payload" | curl -fsS --max-time 8 \
      -H 'Content-Type: application/json' -H 'Accept: application/json' \
      --data-binary @- "$coordinator_base/v1/referrals/reserve" 2>/dev/null)"; then
    log "Invite reservation unavailable; authoritative validation and capacity claim will run during credential registration."
    return 0
  fi
  result="$(printf "%s" "$response" | python3 -c 'import json,sys
try:
 d=json.load(sys.stdin)
 if d.get("reserved"): print("reserved:"+str(d.get("reservation_id","")))
 elif not d.get("required", True): print("disabled:")
 else: print("invalid:"+str(d.get("reason","invalid")))
except Exception: print("unavailable:")')"
  case "$result" in
    reserved:*)
      REFERRAL_RESERVATION_ID="${result#reserved:}"
      [ -n "$REFERRAL_RESERVATION_ID" ] && log "Invite reserved for this install (holds your spot for ~30 minutes)."
      return 0 ;;
    disabled:*) return 0 ;;
    invalid:expired) die 7 "referral code has expired; use a different invite" ;;
    invalid:revoked) die 7 "referral code is no longer available; use a different invite" ;;
    invalid:exhausted) die 7 "referral code has already been used; use a different invite" ;;
    invalid:conflict) die 7 "this invite is already reserved for a different install; use a different invite" ;;
    invalid:*) die 7 "referral code is not valid; check it or use a different invite" ;;
    *) log "Invite reservation response was unavailable; authoritative validation will run during credential registration." ;;
  esac
}

detect_platform() {
  os="$(uname -s)"
  arch="$(uname -m)"
  [ "$os" = "Darwin" ] || die 1 "macOS is required; found $os"
  [ "$arch" = "arm64" ] || die 1 "Apple Silicon arm64 is required; found $arch"
  require_tool sw_vers
  macos_version="$(sw_vers -productVersion)"
  macos_major="${macos_version%%.*}"
  case "$macos_major" in
    ''|*[!0-9]*) die 1 "could not determine macOS version from '$macos_version'" ;;
  esac
  [ "$macos_major" -ge 14 ] || die 1 "macOS 14 Sonoma or newer is required; found $macos_version"
}

detect_ram_gb() {
  bytes="$(sysctl -n hw.memsize 2>/dev/null || true)"
  if [ -z "$bytes" ]; then
    printf "[macprovider-install] Could not read hw.memsize; defaulting to 8 GB model tier.\n" >&2
    bytes=8589934592
  fi
  awk "BEGIN { printf \"%d\", ($bytes + 1073741823) / 1073741824 }"
}

model_default_for_ram() {
  ram_gb="$1"
  if [ "$ram_gb" -lt 12 ]; then
    printf "mlx-community/Llama-3.2-3B-Instruct-4bit"
  elif [ "$ram_gb" -lt 16 ]; then
    printf "mlx-community/Qwen3-4B-Instruct-2507-4bit"
  elif [ "$ram_gb" -lt 24 ]; then
    printf "mlx-community/Qwen2.5-7B-Instruct-4bit"
  elif [ "$ram_gb" -lt 32 ]; then
    printf "mlx-community/Qwen2.5-14B-Instruct-4bit"
  elif [ "$ram_gb" -lt 48 ]; then
    printf "mlx-community/Qwen3-32B-4bit"
  elif [ "$ram_gb" -lt 64 ]; then
    printf "mlx-community/Llama-3.3-70B-Instruct-4bit"
  else
    printf "mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit"
  fi
}

known_min_ram_gb_for_model() {
  case "$1" in
    mlx-community/Llama-3.2-3B-Instruct-4bit) printf "8" ;;
    mlx-community/Qwen3-4B-Instruct-2507-4bit) printf "12" ;;
    mlx-community/Qwen2.5-7B-Instruct-4bit) printf "16" ;;
    mlx-community/DeepSeek-R1-0528-Qwen3-8B-4bit) printf "16" ;;
    mlx-community/Qwen2.5-14B-Instruct-4bit) printf "24" ;;
    mlx-community/Qwen3-32B-4bit) printf "32" ;;
    mlx-community/Qwen2.5-Coder-32B-Instruct-4bit) printf "32" ;;
    mlx-community/Llama-3.3-70B-Instruct-4bit) printf "48" ;;
    mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit) printf "64" ;;
  esac
}

known_weight_gb_for_model() {
  case "$1" in
    mlx-community/Llama-3.2-3B-Instruct-4bit) printf "2" ;;
    mlx-community/Qwen3-4B-Instruct-2507-4bit) printf "2" ;;
    mlx-community/Qwen2.5-7B-Instruct-4bit) printf "4" ;;
    mlx-community/DeepSeek-R1-0528-Qwen3-8B-4bit) printf "4" ;;
    mlx-community/Qwen2.5-14B-Instruct-4bit) printf "8" ;;
    mlx-community/Qwen3-32B-4bit) printf "18" ;;
    mlx-community/Qwen2.5-Coder-32B-Instruct-4bit) printf "17" ;;
    mlx-community/Llama-3.3-70B-Instruct-4bit) printf "35" ;;
    mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit) printf "40" ;;
  esac
}

# SPEC-003 v0.9 FR-D2: enforce safe HuggingFace repo id format.
# Path-component charset (A-Za-z0-9._-) plus a single "/" separator. Any
# deviation from "org/name" is rejected — this id is interpolated into a URL
# and a YAML field, so traversal/newlines/whitespace must not slip through.
validate_hf_id() {
  id="$1"
  reject_newlines "model id" "$id"
  case "$id" in
    */*/*|*/) die 7 "model id must be in the form org/name (got: $id)" ;;
    */*) ;;
    *) die 7 "model id must be in the form org/name (got: $id)" ;;
  esac
  case "$id" in
    *[!A-Za-z0-9._/-]*) die 7 "model id contains invalid characters; allowed: A-Z a-z 0-9 . _ - /" ;;
  esac
  case "$id" in
    /*|*/) die 7 "model id must be in the form org/name (got: $id)" ;;
  esac
  # Round-2 hardening (codex code/security MAJOR): reject "." / ".." path
  # components even though the charset filter allows them. Otherwise an id
  # like "org/.." or "../name" passes the format check and could be
  # path-normalized into the HF URL or later treated as a relative local
  # model path by the binary.
  hf_org="${id%/*}"
  hf_name="${id##*/}"
  case "$hf_org" in
    .|..) die 7 "model id org segment cannot be \".\" or \"..\"" ;;
  esac
  case "$hf_name" in
    .|..) die 7 "model id name segment cannot be \".\" or \"..\"" ;;
  esac
}

# SPEC-003 v0.9 FR-D2: estimate weight size in GB from HF repo name.
# Parses N params from "...3B...", "...7B...", "...1.7B..." patterns and a
# quantization hint (4bit/8bit/bf16/fp16/q4/q8). Returns an integer GB to
# stdout or empty if the name can't be parsed — callers treat empty as
# "skip fit check, warn user".
estimate_weights_gb_from_name() {
  id="$1"
  # Round-2 (codex code MAJOR): match "NxMB" Mixture-of-Experts shape FIRST
  # (e.g. "Mixtral-8x7B" — 8 experts of 7B each, total ~56B params). The
  # single-N pattern below would otherwise capture only the "7B" half and
  # under-count memory by ~N×, letting the fit check pass a model that
  # would OOM the host.
  moe_match="$(printf "%s" "$id" | grep -oE '[0-9]+x[0-9]+(\.[0-9]+)?[Bb]' | head -n1)"
  if [ -n "$moe_match" ]; then
    experts="${moe_match%%x*}"
    per_rest="${moe_match#*x}"
    per_b="${per_rest%[Bb]}"
    params_b="$(awk -v e="$experts" -v p="$per_b" 'BEGIN { printf "%g", e * p }')"
  else
    params_b="$(printf "%s" "$id" | grep -oE '[0-9]+(\.[0-9]+)?[Bb]' | head -n1 | tr -d 'Bb')"
  fi
  [ -n "$params_b" ] || return 0
  quant_lc="$(printf "%s" "$id" | tr '[:upper:]' '[:lower:]')"
  case "$quant_lc" in
    *4bit*|*-q4*|*_q4*) bytes_per_param=0.5 ;;
    *8bit*|*-q8*|*_q8*) bytes_per_param=1.0 ;;
    *bf16*|*fp16*|*-f16*) bytes_per_param=2.0 ;;
    *) bytes_per_param=2.0 ;;
  esac
  awk -v p="$params_b" -v b="$bytes_per_param" \
    'BEGIN { gb = p * b; if (gb < 1) gb = 1; printf "%d", gb + 0.5 }'
}

hf_safetensors_gb_from_api_body() {
  body="$1"
  printf "%s" "$body" | tr '\n\r' '  ' | awk '
    {
      data = $0
      while (match(data, /"rfilename"[[:space:]]*:[[:space:]]*"[^"]*\.safetensors"/)) {
        data = substr(data, RSTART + RLENGTH)
        window = substr(data, 1, 700)
        if (match(window, /"size"[[:space:]]*:[[:space:]]*[0-9]+/)) {
          value = substr(window, RSTART, RLENGTH)
          gsub(/[^0-9]/, "", value)
          total += value + 0
        }
      }
    }
    END {
      if (total > 0) {
        printf "%d", int((total + 1073741824 - 1) / 1073741824)
      }
    }
  '
}

ram_floor_for_weight_gb() {
  weight_gb="$1"
  awk -v w="$weight_gb" '
    BEGIN {
      if (w <= 2) print 8;
      else if (w <= 3) print 12;
      else if (w <= 5) print 16;
      else if (w <= 9) print 24;
      else if (w <= 20) print 32;
      else if (w <= 38) print 48;
      else print 64;
    }
  '
}

confirm_model_fit_override() {
  reason="$1"
  if [ "$NO_PROMPT" = "1" ]; then
    die 7 "$reason; refusing non-interactive install"
  fi
  log "WARNING: $reason"
  prompt_yes_no "Proceed anyway? [y/N]" "N" || die 7 "aborted by user"
}

enforce_model_min_ram_floor() {
  id="$1"
  ram_gb="$2"
  min_ram_gb="$3"
  source="$4"
  if [ "$ram_gb" -lt "$min_ram_gb" ]; then
    confirm_model_fit_override "$source requires ${min_ram_gb} GB RAM for $id, but this Mac has ${ram_gb} GB"
  else
    log "Model fits: $id requires ${min_ram_gb} GB RAM by $source; this Mac has ${ram_gb} GB."
  fi
}

enforce_model_ram_fit_from_weight_gb() {
  id="$1"
  ram_gb="$2"
  weight_gb="$3"
  source="$4"
  min_ram_gb="$(ram_floor_for_weight_gb "$weight_gb")"
  if [ "$ram_gb" -lt "$min_ram_gb" ]; then
    confirm_model_fit_override "$source reports ~${weight_gb} GB safetensors; recommended RAM floor is ${min_ram_gb} GB for $id, but this Mac has ${ram_gb} GB"
  else
    log "Model fits: $source reports ~${weight_gb} GB safetensors; recommended RAM floor is ${min_ram_gb} GB and this Mac has ${ram_gb} GB."
  fi
}

enforce_model_ram_fit() {
  id="$1"
  ram_gb="$2"
  min_ram_gb="$(known_min_ram_gb_for_model "$id")"
  if [ -n "$min_ram_gb" ]; then
    enforce_model_min_ram_floor "$id" "$ram_gb" "$min_ram_gb" "model table"
    return 0
  fi

  est_gb="$(estimate_weights_gb_from_name "$id")"
  if [ -z "$est_gb" ]; then
    log "WARNING: could not estimate weight size from model name; skipping fit check."
    return 0
  fi
  # Headroom: ~6 GB for macOS (3-4 GB) + Metal + mlx runtime + binary +
  # KV cache. This matches the existing RAM-tier policy where the 7B (~4 GB)
  # default targets 16 GB Macs, not 8 GB Macs.
  comfortable_gb=$((est_gb + 6))
  if [ "$ram_gb" -ge "$comfortable_gb" ]; then
    log "Model fits: ~${est_gb} GB weights on ${ram_gb} GB Mac (working set ~${comfortable_gb} GB)."
    return 0
  fi
  if [ "$ram_gb" -ge "$((est_gb + 2))" ]; then
    confirm_model_fit_override "tight fit — ~${est_gb} GB weights on ${ram_gb} GB Mac; may swap or OOM under load"
    return 0
  fi
  confirm_model_fit_override "~${est_gb} GB weights will not fit on ${ram_gb} GB Mac"
}

catalog_min_ram_from_body() {
  catalog_body="$1"
  model_id="$2"
  printf "%s" "$catalog_body" | tr '\n\r' '  ' | awk -v id="$model_id" '
    BEGIN { RS = "}"; }
    index($0, "\"model_id\"") && index($0, "\"" id "\"") {
      if (match($0, /"min_ram_gb"[[:space:]]*:[[:space:]]*[1-9][0-9]*/)) {
        value = substr($0, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", value)
        print value
      }
      exit
    }
  '
}

check_catalog_ram_metadata() {
  coordinator_base="$1"
  model_id="$2"
  ram_gb="$3"
  if [ "${MACPROVIDER_SKIP_CATALOG_CHECK:-0}" = "1" ]; then
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log "WARNING: curl not found; using built-in model RAM estimates."
    return 1
  fi

  catalog_url="$coordinator_base/catalog/current"
  body_and_code="$(curl -sSL -m 5 -o - -w '\n__HTTP_STATUS__%{http_code}' "$catalog_url" 2>/dev/null || printf '\n__HTTP_STATUS__network_error')"
  http_code="${body_and_code##*__HTTP_STATUS__}"
  catalog_body="${body_and_code%__HTTP_STATUS__*}"
  if [ "$http_code" != "200" ]; then
    log "WARNING: could not read signed catalog $catalog_url (status $http_code); using built-in model RAM estimates."
    return 1
  fi

  catalog_id="$(printf "%s" "$catalog_body" | sed -n 's/.*"catalog_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  if [ -z "$catalog_id" ]; then
    log "WARNING: signed catalog did not include catalog_id; using built-in model RAM estimates."
    return 1
  fi

  min_ram_gb="$(catalog_min_ram_from_body "$catalog_body" "$model_id")"
  if [ -n "$min_ram_gb" ]; then
    if [ "$ram_gb" -lt "$min_ram_gb" ]; then
      confirm_model_fit_override "catalog $catalog_id requires ${min_ram_gb} GB RAM for $model_id, but this Mac has ${ram_gb} GB"
    else
      log "Catalog fit: $model_id requires ${min_ram_gb} GB RAM; this Mac has ${ram_gb} GB."
    fi
    return 0
  fi
  log "WARNING: catalog $catalog_id has no min_ram_gb metadata; using built-in model RAM estimates."
  return 1
}

# SPEC-003 v0.9 FR-D2: pre-install validation of a user-supplied HuggingFace
# model id. Hard-blocks on inaccessible (401/403/404 — HF returns 401 for both
# gated and nonexistent repos) and on non-MLX repos. Warns and prompts on
# tight/over-RAM fit; user may override. Network errors downgrade to a
# "skipped" warning so a flaky HF doesn't brick installs, but the local
# name-based RAM-fit guard still runs. All output goes to stderr — caller's
# stdout is reserved for the chosen id.
hf_check_model() {
  id="$1"
  ram_gb="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Dry run: would check model $id on HuggingFace."
    enforce_model_ram_fit "$id" "$ram_gb"
    return 0
  fi
  if [ "${MACPROVIDER_SKIP_HF_CHECK:-0}" = "1" ]; then
    log "Skipping HuggingFace check (MACPROVIDER_SKIP_HF_CHECK=1)."
    enforce_model_ram_fit "$id" "$ram_gb"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log "curl not found; skipping HuggingFace check."
    enforce_model_ram_fit "$id" "$ram_gb"
    return 0
  fi
  log "Checking model $id on HuggingFace…"
  api_url="https://huggingface.co/api/models/$id?blobs=true"
  # -f omitted so 4xx bodies still reach us; status is routed explicitly below.
  body_and_code="$(curl -sSL -m 10 -o - -w '\n__HTTP_STATUS__%{http_code}' "$api_url" 2>/dev/null || printf '\n__HTTP_STATUS__network_error')"
  http_code="${body_and_code##*__HTTP_STATUS__}"
  body="${body_and_code%__HTTP_STATUS__*}"
  case "$http_code" in
    200) ;;
    401|403|404)
      die 7 "model $id is not accessible on HuggingFace (private, gated, or doesn't exist). For a gated repo, use 'macprovider-cli models switch' post-install with HF_TOKEN set."
      ;;
    network_error)
      log "WARNING: could not reach HuggingFace API; using local RAM-fit estimate only."
      enforce_model_ram_fit "$id" "$ram_gb"
      return 0
      ;;
    *)
      log "WARNING: unexpected HuggingFace API status $http_code; using local RAM-fit estimate only."
      enforce_model_ram_fit "$id" "$ram_gb"
      return 0
      ;;
  esac

  # MLX detection: mlx-community/* repos are mlx by convention, plus any repo
  # that declares mlx as library_name or carries an "mlx" tag.
  is_mlx=0
  case "$id" in
    mlx-community/*) is_mlx=1 ;;
  esac
  if [ "$is_mlx" -eq 0 ]; then
    # Round-2 (codex code MINOR): flatten the body to one line before the
    # tags regex. HF currently returns minified JSON, but a future format
    # change to pretty-printed bodies would defeat the bracketed-class
    # match because grep -E reads line-by-line.
    flat_body="$(printf "%s" "$body" | tr -d '\n\r')"
    if printf "%s" "$flat_body" | grep -qE '"library_name"[[:space:]]*:[[:space:]]*"mlx"|"tags"[[:space:]]*:[[:space:]]*\[[^]]*"mlx"'; then
      is_mlx=1
    fi
  fi
  if [ "$is_mlx" -eq 0 ]; then
    die 7 "model $id is not an MLX repo. macprovider runs MLX-format models only. Pick an mlx-community/* variant or convert with mlx_lm.convert."
  fi

  hf_weight_gb="$(hf_safetensors_gb_from_api_body "$body")"
  if [ -n "$hf_weight_gb" ]; then
    enforce_model_ram_fit_from_weight_gb "$id" "$ram_gb" "$hf_weight_gb" "HuggingFace"
  else
    enforce_model_ram_fit "$id" "$ram_gb"
  fi
}

choose_model() {
  ram_gb="$1"
  if [ -n "${MACPROVIDER_MODEL:-}" ]; then
    # Env-var override is an explicit power-user path, but it must still pass
    # the local RAM-fit guard. Keep the previous reachability behavior for
    # private/gated repos; NO_PROMPT oversized models fail loud with exit 7
    # instead of silently downloading multi-GB weights that cannot fit.
    validate_hf_id "$MACPROVIDER_MODEL"
    enforce_model_ram_fit "$MACPROVIDER_MODEL" "$ram_gb" >&2
    printf "%s" "$MACPROVIDER_MODEL"
    return
  fi

  default_model="$(model_default_for_ram "$ram_gb")"
  if [ "$NO_PROMPT" = "1" ]; then
    printf "%s" "$default_model"
    return
  fi

  printf "[macprovider-install] Detected approximately %s GB RAM.\n" "$ram_gb" >&2
  printf "Choose a model:\n" >&2
  printf "  1) mlx-community/Llama-3.2-3B-Instruct-4bit      ~2 GB, 8 GB Macs\n" >&2
  printf "  2) mlx-community/Qwen3-4B-Instruct-2507-4bit     ~2 GB, 12 GB+ Macs\n" >&2
  printf "  3) mlx-community/Qwen2.5-7B-Instruct-4bit        ~4 GB, 16 GB Macs\n" >&2
  printf "  4) mlx-community/DeepSeek-R1-0528-Qwen3-8B-4bit  ~4 GB, 16 GB+ Macs\n" >&2
  printf "  5) mlx-community/Qwen2.5-14B-Instruct-4bit       ~8 GB, 24 GB+ Macs\n" >&2
  printf "  6) mlx-community/Qwen3-32B-4bit                  ~18 GB, 32 GB+ Macs\n" >&2
  printf "  7) mlx-community/Qwen2.5-Coder-32B-Instruct-4bit ~17 GB, 32 GB+ Macs\n" >&2
  printf "  8) mlx-community/Llama-3.3-70B-Instruct-4bit     ~35 GB, 48 GB+ Macs\n" >&2
  printf "  9) mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit ~40 GB, 64 GB+ Macs\n" >&2
  printf "  c) custom HuggingFace MLX model id\n" >&2
  printf "Selection [default: %s]: " "$default_model" >&2
  read_line
  selection="$REPLY"
  case "$selection" in
    1) printf "mlx-community/Llama-3.2-3B-Instruct-4bit" ;;
    2) printf "mlx-community/Qwen3-4B-Instruct-2507-4bit" ;;
    3) printf "mlx-community/Qwen2.5-7B-Instruct-4bit" ;;
    4) printf "mlx-community/DeepSeek-R1-0528-Qwen3-8B-4bit" ;;
    5) printf "mlx-community/Qwen2.5-14B-Instruct-4bit" ;;
    6) printf "mlx-community/Qwen3-32B-4bit" ;;
    7) printf "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit" ;;
    8) printf "mlx-community/Llama-3.3-70B-Instruct-4bit" ;;
    9) printf "mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit" ;;
    c|C)
      printf "HuggingFace model id (org/name): " >&2
      read_line
      custom_id="$REPLY"
      [ -n "$custom_id" ] || die 7 "custom model id cannot be empty"
      validate_hf_id "$custom_id"
      hf_check_model "$custom_id" "$ram_gb" >&2
      printf "%s" "$custom_id"
      ;;
    "") printf "%s" "$default_model" ;;
    *) die 7 "invalid model selection" ;;
  esac
}

choose_provider_id() {
  if [ -f "$PROVIDER_ID_PATH" ]; then
    saved="$(cat "$PROVIDER_ID_PATH")"
    if [ -n "$saved" ]; then
      printf "%s" "$saved"
      return
    fi
  fi

  existing="$(read_config_provider_id || true)"
  if [ -n "$existing" ]; then
    printf "%s" "$existing"
    return
  fi

  random_suffix="$(openssl rand -hex 16)" \
    || die 7 "could not generate a high-entropy provider auth principal"
  case "$random_suffix" in
    *[!0-9a-f]*|'') die 7 "unexpected provider auth principal encoding" ;;
  esac
  [ "${#random_suffix}" -eq 32 ] || die 7 "unexpected provider auth principal length"
  printf "mp-%s" "$random_suffix"
}

is_bootstrap_principal() {
  candidate="$1"
  case "$candidate" in
    mp-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;;
    *) return 1 ;;
  esac
}

choose_coordinator_url() {
  if [ -n "${MACPROVIDER_COORDINATOR_URL:-}" ]; then
    printf "%s" "$MACPROVIDER_COORDINATOR_URL"
    return
  fi
  if [ "$NO_PROMPT" = "1" ]; then
    printf "%s" "$COORDINATOR_URL_DEFAULT"
    return
  fi

  printf "Coordinator URL [default: %s]: " "$COORDINATOR_URL_DEFAULT" >&2
  read_line
  value="$REPLY"
  printf "%s" "${value:-$COORDINATOR_URL_DEFAULT}"
}

validate_inputs() {
  model="$1"
  provider_id="$2"
  coordinator_url="$3"
  reject_newlines "model" "$model"
  reject_newlines "provider_id" "$provider_id"
  reject_newlines "coordinator_url" "$coordinator_url"
  case "$model" in
    *[!A-Za-z0-9._/:+-]*) die 7 "model contains unsupported characters" ;;
  esac
  case "$provider_id" in
    ''|*[!a-z0-9-]*) die 7 "provider_id contains unsupported characters" ;;
  esac
  case "$coordinator_url" in
    wss://*) ;;
    *) die 7 "coordinator URL must start with wss://" ;;
  esac
}

latest_release_tag() {
  # Scan the recent release list and pick the newest tag that names a
  # macprovider-cli release (tag matches ^v[0-9], e.g. v1.3.1). The
  # /releases/latest endpoint can't be trusted on its own: it returns
  # whichever release is flagged "Latest" repo-wide, so any unrelated
  # release published under the same repo (e.g. macprovider-verify
  # under tag verify-vX.Y.Z) silently hijacks the installer.
  api_url="https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=30"
  json="$(curl -fsSL "$api_url")" || die 3 "failed to query GitHub Releases API: $api_url"
  tag="$(
    printf "%s" "$json" \
      | awk '
          function maybe_print_release(obj, tag, prerelease) {
            tag = ""
            prerelease = "false"
            if (match(obj, /"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
              tag = substr(obj, RSTART, RLENGTH)
              sub(/^"tag_name"[[:space:]]*:[[:space:]]*"/, "", tag)
              sub(/"$/, "", tag)
            }
            if (match(obj, /"prerelease"[[:space:]]*:[[:space:]]*true/)) {
              prerelease = "true"
            }
            if (tag ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ && prerelease != "true") {
              print tag
              exit
            }
          }
          {
            data = data $0 "\n"
          }
          END {
            depth = 0
            in_string = 0
            escaped = 0
            start = 0
            for (i = 1; i <= length(data); i++) {
              ch = substr(data, i, 1)
              if (in_string) {
                if (escaped) {
                  escaped = 0
                } else if (ch == "\\") {
                  escaped = 1
                } else if (ch == "\"") {
                  in_string = 0
                }
                continue
              }
              if (ch == "\"") {
                in_string = 1
              } else if (ch == "{") {
                depth++
                if (depth == 1) {
                  start = i
                }
              } else if (ch == "}") {
                if (depth == 1 && start > 0) {
                  maybe_print_release(substr(data, start, i - start + 1))
                  start = 0
                }
                depth--
              }
            }
          }
        '
  )"
  [ -n "$tag" ] || die 3 "no non-prerelease macprovider-cli release (tag ^v[0-9]) found in recent GitHub Releases"
  printf "%s" "$tag"
}

version_at_least() (
  candidate_version="$1"
  floor_version="$2"
  IFS=.
  set -- ${candidate_version#v}
  a_major="$1"
  a_minor="$2"
  a_patch="$3"
  set -- ${floor_version#v}
  b_major="$1"
  b_minor="$2"
  b_patch="$3"

  [ "$a_major" -gt "$b_major" ] && exit 0
  [ "$a_major" -lt "$b_major" ] && exit 1
  [ "$a_minor" -gt "$b_minor" ] && exit 0
  [ "$a_minor" -lt "$b_minor" ] && exit 1
  [ "$a_patch" -ge "$b_patch" ]
)

validate_macprovider_version_tag() {
  tag="$1"
  case "$tag" in
    *[[:space:]]*|*[[:cntrl:]]*) die 7 "MACPROVIDER_VERSION must not contain whitespace or control characters" ;;
  esac
  if ! [[ "$tag" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    die 7 "MACPROVIDER_VERSION must look like vMAJOR.MINOR.PATCH"
  fi
  if ! version_at_least "$tag" "$MACPROVIDER_MIN_SUPPORTED_VERSION"; then
    die 7 "MACPROVIDER_VERSION $tag is below supported rollback floor $MACPROVIDER_MIN_SUPPORTED_VERSION"
  fi
}

resolve_release_tag() {
  case "${EMERGENCY_ROLLBACK:-0}" in
    0|1) ;;
    *) die 7 "MACPROVIDER_EMERGENCY_ROLLBACK must be 0 or 1" ;;
  esac
  if [ "${EMERGENCY_ROLLBACK:-0}" = "1" ] && [ -z "${MACPROVIDER_VERSION:-}" ]; then
    die 7 "emergency rollback requires MACPROVIDER_VERSION pinned to the prior signed tag"
  fi
  if [ -n "${MACPROVIDER_VERSION:-}" ]; then
    validate_macprovider_version_tag "$MACPROVIDER_VERSION"
    if [ "${EMERGENCY_ROLLBACK:-0}" = "1" ] && ! version_at_least "$MACPROVIDER_VERSION" "$MACPROVIDER_MIN_EMERGENCY_VERSION"; then
      die 7 "emergency rollback target $MACPROVIDER_VERSION predates the config-compatible floor $MACPROVIDER_MIN_EMERGENCY_VERSION"
    fi
    printf "%s" "$MACPROVIDER_VERSION"
  else
    tag="$(latest_release_tag)"
    printf "%s" "$tag"
  fi
}

download_release() {
  tag="$1"
  tarball_asset="macprovider-cli-${tag}-darwin-arm64.tar.gz"
  pkg_asset="macprovider-cli-${tag}-darwin-arm64.pkg"
  base="https://github.com/${GITHUB_REPO}/releases/download/${tag}"
  TMPDIR_PATH="$(mktemp -d)"
  tarball_path="$TMPDIR_PATH/$tarball_asset"
  pkg_path="$TMPDIR_PATH/$pkg_asset"
  checksums_path="$TMPDIR_PATH/checksums.txt"
  checksums_sig_path="$TMPDIR_PATH/checksums.txt.sig"
  asset_path=""
  asset_kind=""

  curl -fL "$base/checksums.txt" -o "$checksums_path" || die 3 "failed to download checksums.txt"
  curl -fL "$base/checksums.txt.sig" -o "$checksums_sig_path" || die 3 "failed to download checksums.txt.sig"
  verify_checksum_signature

  release_format="${MACPROVIDER_RELEASE_FORMAT:-auto}"
  case "$release_format" in
    auto|pkg|tar) ;;
    *) die 7 "MACPROVIDER_RELEASE_FORMAT must be auto, pkg, or tar" ;;
  esac

  if [ "$release_format" != "tar" ]; then
    pkg_expected="$(checksum_for_asset "$pkg_asset")"
    if [ -n "$pkg_expected" ]; then
      log "Downloading signed package $pkg_asset from GitHub Releases."
      curl -fL "$base/$pkg_asset" -o "$pkg_path" || die 3 "failed to download release package"
      asset_path="$pkg_path"
      asset_kind="pkg"
      log "Using signed package release asset: $pkg_asset"
      return
    fi
    [ "$release_format" = "auto" ] || die 3 "checksums.txt has no entry for $pkg_asset"
    log "Signed release manifest has no package for $tag; falling back to tarball."
  fi

  log "Downloading $tarball_asset from GitHub Releases."
  curl -fL "$base/$tarball_asset" -o "$tarball_path" || die 3 "failed to download release tarball"
  asset_path="$tarball_path"
  asset_kind="tar"
}

write_checksum_public_key() {
  if [ -n "${MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM:-}" ]; then
    printf "%s\n" "$MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM"
    return
  fi
  cat <<'EOF'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEwwd0Vzj35OP8DlZU+0lUa8vI9gHK
09J48LDizWScsH6rutnZLkKnGQ4X5Q8lT9L5mglF8Ba0DDoUXKrFfSAX4Q==
-----END PUBLIC KEY-----
EOF
}

verify_checksum_signature() {
  public_key_path="$TMPDIR_PATH/release-signing-public.pem"
  write_checksum_public_key > "$public_key_path"
  if grep -q "REPLACE_WITH_MACPROVIDER" "$public_key_path"; then
    die 3 "release signing public key is not configured in install.sh"
  fi
  openssl dgst -sha256 \
    -verify "$public_key_path" \
    -signature "$checksums_sig_path" \
    "$checksums_path" >/dev/null || die 4 "checksums.txt signature verification failed"
  log "checksums.txt signature verified."
}

checksum_for_asset() {
  asset_name="$1"
  awk -v asset="$asset_name" '$2 == asset { print $1; exit }' "$checksums_path"
}

verify_sha256() {
  asset_name="$(basename "$asset_path")"
  expected="$(checksum_for_asset "$asset_name")"
  [ -n "$expected" ] || die 4 "checksums.txt has no entry for $asset_name"
  actual="$(shasum -a 256 "$asset_path" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || die 4 "checksum mismatch for $asset_name"
  log "SHA256 verified."
}

validate_tarball() {
  entries="$(tar tzf "$asset_path")" || die 5 "failed to list release tarball"
  [ -n "$entries" ] || die 5 "release tarball is empty"

  validate_staged_entries "$entries" "tarball"
  if tar tvzf "$asset_path" | awk '{print substr($1,1,1), $0}' | grep -E '^[lhbcp]' >/dev/null; then
    die 5 "release tarball contains unsafe link or device members"
  fi
}

validate_staged_entries() {
  entries="$1"
  label="$2"
  has_binary=0
  has_metallib=0
  has_bundle=0
  has_bundled_metallib=0
  has_catalog_manifest=0
  has_catalog_keyring=0
  has_catalog_candidates=0
  has_catalog_candidates_signature=0
  has_catalog_demand=0
  has_catalog_demand_signature=0
  while IFS= read -r entry; do
    normalized_entry="$entry"
    while :; do
      case "$normalized_entry" in
        ./*) normalized_entry="${normalized_entry#./}" ;;
        *) break ;;
      esac
    done
    case "$normalized_entry" in
      ""|.) continue ;;
    esac
    case "$normalized_entry" in
      /*|*"/../"*|../*|*/..|..)
        die 5 "unsafe tarball path: $entry"
        ;;
      macprovider-cli)
        has_binary=1
        ;;
      mlx.metallib)
        has_metallib=1
        ;;
      mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib)
        has_bundle=1
        has_bundled_metallib=1
        ;;
      THIRD-PARTY-NOTICES.txt)
        ;;
      *.bundle|*.bundle/*)
        has_bundle=1
        ;;
      catalog-release|catalog-release/)
        ;;
      catalog-release/release.json)
        has_catalog_manifest=1
        ;;
      catalog-release/trusted-keys.json)
        has_catalog_keyring=1
        ;;
      catalog-release/autotune-candidates.json)
        has_catalog_candidates=1
        ;;
      catalog-release/autotune-candidates.json.sig)
        has_catalog_candidates_signature=1
        ;;
      catalog-release/demand-rank.json)
        has_catalog_demand=1
        ;;
      catalog-release/demand-rank.json.sig)
        has_catalog_demand_signature=1
        ;;
      *)
        die 5 "unexpected $label member: $entry"
        ;;
    esac
  done <<EOF
$entries
EOF

  [ "$has_binary" -eq 1 ] || die 5 "$label does not contain macprovider-cli"
  [ "$has_bundle" -eq 1 ] || die 5 "$label does not contain a SwiftPM resource bundle"
  catalog_member_count=$((
    has_catalog_manifest +
    has_catalog_keyring +
    has_catalog_candidates +
    has_catalog_candidates_signature +
    has_catalog_demand +
    has_catalog_demand_signature
  ))
  if [ "${EMERGENCY_ROLLBACK:-0}" = "1" ] && [ "$catalog_member_count" -eq 0 ]; then
    [ "$has_metallib" -eq 1 ] || [ "$has_bundled_metallib" -eq 1 ] \
      || die 5 "$label does not contain signed MLX Metal kernels"
    log "Emergency rollback accepted a signed legacy payload without catalog assets."
  else
    [ "$has_metallib" -eq 1 ] || die 5 "$label does not contain mlx.metallib"
    [ "$has_catalog_manifest" -eq 1 ] || die 5 "$label does not contain catalog-release/release.json"
    [ "$has_catalog_keyring" -eq 1 ] || die 5 "$label does not contain catalog-release/trusted-keys.json"
    [ "$has_catalog_candidates" -eq 1 ] || die 5 "$label does not contain catalog-release/autotune-candidates.json"
    [ "$has_catalog_candidates_signature" -eq 1 ] || die 5 "$label does not contain catalog-release/autotune-candidates.json.sig"
    [ "$has_catalog_demand" -eq 1 ] || die 5 "$label does not contain catalog-release/demand-rank.json"
    [ "$has_catalog_demand_signature" -eq 1 ] || die 5 "$label does not contain catalog-release/demand-rank.json.sig"
  fi
}

validate_package() {
  require_tool pkgutil
  if command -v spctl >/dev/null 2>&1; then
    spctl -a -vv -t install "$asset_path" || die 4 "package failed Gatekeeper assessment"
    log "Package Gatekeeper assessment passed."
  else
    log "spctl not found; package checksum was verified but Gatekeeper assessment was skipped."
  fi
  if command -v xcrun >/dev/null 2>&1 && xcrun --find stapler >/dev/null 2>&1; then
    xcrun stapler validate "$asset_path" || die 4 "package stapler validation failed"
    log "Package stapler validation passed."
  else
    log "stapler not found; local package stapler validation skipped."
  fi
}

validate_release_payload() {
  case "$asset_kind" in
    tar) validate_tarball ;;
    pkg) validate_package ;;
    *) die 5 "release asset was not selected" ;;
  esac
}

stage_release_payload() {
  staging_dir="$TMPDIR_PATH/staging"
  rm -rf "$staging_dir"
  mkdir -p "$staging_dir"

  case "$asset_kind" in
    tar)
      tar xzf "$asset_path" -C "$staging_dir" || die 5 "failed to extract release tarball"
      ;;
    pkg)
      expanded_dir="$TMPDIR_PATH/pkg-expanded"
      rm -rf "$expanded_dir"
      pkgutil --expand-full "$asset_path" "$expanded_dir" || die 5 "failed to expand release package"
      [ -d "$expanded_dir/Payload" ] || die 5 "expanded package does not contain Payload"
      payload_entries="$(cd "$expanded_dir/Payload" && find . -mindepth 1 -print)" \
        || die 5 "failed to list expanded package payload"
      validate_staged_entries "$payload_entries" "package payload"
      if find "$expanded_dir/Payload" \( -type l -o -type b -o -type c -o -type p \) -print -quit | grep -q .; then
        die 5 "package payload contains unsafe link or device members"
      fi
      cp -R "$expanded_dir/Payload/." "$staging_dir"/
      ;;
    *)
      die 5 "release asset was not selected"
      ;;
  esac
  chmod +x "$staging_dir/macprovider-cli" 2>/dev/null || true
  [ -x "$staging_dir/macprovider-cli" ] || die 5 "staged macprovider-cli is not executable"
  MACPROVIDER_CLI_EXECUTABLE="$staging_dir/macprovider-cli"
}

prepare_staged_config() {
  [ -n "$staging_dir" ] || die 5 "release payload must be staged before config preparation"
  STAGED_CONFIG_PATH="$staging_dir/config.yaml"
  STAGED_PROVIDER_ID_PATH="$staging_dir/provider_id"
  if [ -f "$LIVE_CONFIG_PATH" ]; then
    cp "$LIVE_CONFIG_PATH" "$STAGED_CONFIG_PATH" || die 5 "failed to stage existing provider config"
    chmod 600 "$STAGED_CONFIG_PATH" 2>/dev/null || true
  fi
  if [ -f "$LIVE_PROVIDER_ID_PATH" ]; then
    cp "$LIVE_PROVIDER_ID_PATH" "$STAGED_PROVIDER_ID_PATH" || die 5 "failed to stage existing provider identity"
    chmod 600 "$STAGED_PROVIDER_ID_PATH" 2>/dev/null || true
  fi
  CONFIG_PATH="$STAGED_CONFIG_PATH"
  PROVIDER_ID_PATH="$STAGED_PROVIDER_ID_PATH"
}

activate_staged_config() {
  if [ "${INSTALL_TX_ACTIVE:-0}" -eq 1 ]; then
    assert_install_lock_ownership
  fi
  [ -n "$STAGED_CONFIG_PATH" ] && [ -f "$STAGED_CONFIG_PATH" ] \
    || die 5 "staged provider config is missing at cutover"
  mkdir -p "$CONFIG_DIR"
  config_temp="$LIVE_CONFIG_PATH.install.$$"
  cp "$STAGED_CONFIG_PATH" "$config_temp" || die 5 "failed to prepare provider config activation"
  chmod 600 "$config_temp" 2>/dev/null || true
  mv "$config_temp" "$LIVE_CONFIG_PATH" || die 5 "failed to activate provider config"
  if [ -f "$STAGED_PROVIDER_ID_PATH" ]; then
    provider_id_temp="$LIVE_PROVIDER_ID_PATH.install.$$"
    cp "$STAGED_PROVIDER_ID_PATH" "$provider_id_temp" || die 5 "failed to prepare provider identity activation"
    chmod 600 "$provider_id_temp" 2>/dev/null || true
    mv "$provider_id_temp" "$LIVE_PROVIDER_ID_PATH" || die 5 "failed to activate provider identity"
  fi
  CONFIG_PATH="$LIVE_CONFIG_PATH"
  PROVIDER_ID_PATH="$LIVE_PROVIDER_ID_PATH"
}

semantic_merge_config() {
  config_path="$1"
  model_value="$2"
  provider_id_value="$3"
  coordinator_url_value="$4"
  port_value="$5"
  referral_code_value="${6:-}"
  referral_reservation_value="${7:-}"
  MACPROVIDER_CONFIG_REFERRAL_CODE="$referral_code_value" \
    MACPROVIDER_CONFIG_REFERRAL_RESERVATION_ID="$referral_reservation_value" \
    python3 - "$config_path" "$model_value" "$provider_id_value" "$coordinator_url_value" "$port_value" <<'PY'
import json
import os
import re
import sys
import tempfile

path, model, provider_id, coordinator_url, port = sys.argv[1:]
referral_code = os.environ.pop("MACPROVIDER_CONFIG_REFERRAL_CODE", "")
referral_reservation_id = os.environ.pop("MACPROVIDER_CONFIG_REFERRAL_RESERVATION_ID", "")
owned = {
    "coordinator_url": json.dumps(coordinator_url),
    "provider_id": json.dumps(provider_id),
    "port": str(int(port)),
}
if model:
    owned["model"] = json.dumps(model)
if referral_code:
    owned["referral_code"] = json.dumps(referral_code)
if referral_reservation_id:
    owned["referral_reservation_id"] = json.dumps(referral_reservation_id)
try:
    with open(path, "r", encoding="utf-8") as handle:
        lines = handle.read().splitlines()
except FileNotFoundError:
    lines = []

merged = []
seen = set()
top_level_key = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*)[ \t]*:")
for line in lines:
    match = top_level_key.match(line)
    key = match.group(1) if match else None
    if key not in owned:
        merged.append(line)
        continue
    if key in seen:
        continue
    merged.append(f"{key}: {owned[key]}")
    seen.add(key)

for key in ("model", "coordinator_url", "provider_id", "port", "referral_code", "referral_reservation_id"):
    if key not in owned:
        continue
    if key not in seen:
        merged.append(f"{key}: {owned[key]}")

directory = os.path.dirname(path)
os.makedirs(directory, mode=0o700, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=".config.yaml.merge-", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write("\n".join(merged) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY
}

write_config() {
  model="$1"
  provider_id="$2"
  coordinator_url="$3"
  run mkdir -p "$CONFIG_DIR"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would semantic-merge provider identity, coordinator URL, and port into $CONFIG_PATH; verified autotune supplies model provenance."
    return
  fi
  provider_id_temp="$PROVIDER_ID_PATH.tmp.$$"
  printf "%s\n" "$provider_id" > "$provider_id_temp"
  chmod 600 "$provider_id_temp" 2>/dev/null || true
  mv "$provider_id_temp" "$PROVIDER_ID_PATH"
  semantic_merge_config "$CONFIG_PATH" "$model" "$provider_id" "$coordinator_url" "$PORT" "$REFERRAL_CODE" "$REFERRAL_RESERVATION_ID"
  chmod 600 "$CONFIG_PATH" "$PROVIDER_ID_PATH" 2>/dev/null || true
}

read_config_model() {
  [ -f "$CONFIG_PATH" ] || return 1
  awk -F: '
    /^model:/ {
      value=$0
      sub(/^model:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$CONFIG_PATH"
}

read_config_provider_token() {
  [ -f "$CONFIG_PATH" ] || return 1
  awk -F: '
    /^provider_token[[:space:]]*:/ {
	  value=$0
	  sub(/^provider_token[[:space:]]*:[[:space:]]*/, "", value)
	  gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
	  gsub(/^"|"$/, "", value)
	  print value
      exit
    }
  ' "$CONFIG_PATH"
}

existing_provider_credential_configured() {
  [ -n "$(read_config_provider_token || true)" ] && return 0
  if [ "${APP_MANAGED_REPAIR:-0}" -eq 1 ] \
    && [ -r "$APP_MARKER_PATH" ] \
    && [ -n "$(read_config_provider_id || true)" ]; then
    return 0
  fi
  return 1
}

read_config_provider_id() {
  [ -f "$CONFIG_PATH" ] || return 1
  awk -F: '
    /^provider_id:/ {
      value=$0
      sub(/^provider_id:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$CONFIG_PATH"
}

read_config_artifact_sha() {
  [ -f "$CONFIG_PATH" ] || return 1
  awk -F: '
    /^model_artifact_sha256:/ {
      value=$0
      sub(/^model_artifact_sha256:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$CONFIG_PATH"
}

read_config_artifact_path() {
  [ -f "$CONFIG_PATH" ] || return 1
  awk -F: '
    /^model_artifact_path:/ {
      value=$0
      sub(/^model_artifact_path:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$CONFIG_PATH"
}

read_config_donor_mode() {
  [ -f "$CONFIG_PATH" ] || return 1
  awk -F: '
    /^donor_mode:/ {
      value=$0
      sub(/^donor_mode:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$CONFIG_PATH"
}

ensure_provider_credentials() {
  if existing_provider_credential_configured; then
    return 0
  fi
  provider_id="$(read_config_provider_id || true)"
  case "$provider_id" in
    mp-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die 6 "tokenless credential bootstrap requires a fresh high-entropy mp-* provider ID; this existing predictable ID needs an operator-issued ownership credential" ;;
  esac
  log "Acquiring first-install provider credential before evidence admission."
  # PROD-M2: capture bootstrap-auth stderr so we can distinguish a referral
  # rejection (machine-readable MACPROVIDER_REFERRAL_REJECTED marker) from a
  # generic failure, and surface the specific reason so the app can route the
  # user back to the invite step.
  bootstrap_err="$(mktemp -t macprovider-bootstrap-err 2>/dev/null || mktemp)"
  bootstrap_rc=0
  run_macprovider_cli_with_amfi_retry bootstrap-auth --timeout-seconds 30 --config "$CONFIG_PATH" \
    2>"$bootstrap_err" || bootstrap_rc=$?
  cat "$bootstrap_err" >&2
  if [ "$bootstrap_rc" -ne 0 ]; then
    referral_reason="$(sed -n 's/.*MACPROVIDER_REFERRAL_REJECTED reason=referral_\([a-z]*\).*/\1/p' "$bootstrap_err" | head -n1)"
    rm -f "$bootstrap_err"
    if [ -n "$referral_reason" ]; then
      die 7 "provider registration rejected the invite (referral_$referral_reason); enter a new invite and try again"
    fi
    die 6 "provider credential bootstrap failed before evidence admission"
  fi
  rm -f "$bootstrap_err"
  [ -n "$(read_config_provider_token || true)" ] \
    || die 6 "provider credential bootstrap completed without persisting provider_token"
  if [ -n "${STAGED_CONFIG_PATH:-}" ] && [ "$CONFIG_PATH" = "$STAGED_CONFIG_PATH" ]; then
    # Coordinator bootstrap creates a durable principal. Publish its exact key
    # material into the protected live transaction immediately so #547's
    # rollback helper can preserve custody even if later evidence or startup
    # admission fails. The incumbent process remains running until cutover.
    assert_install_lock_ownership
    mkdir -p "$CONFIG_DIR"
    bootstrap_config_temp="$LIVE_CONFIG_PATH.bootstrap.$$"
    cp "$STAGED_CONFIG_PATH" "$bootstrap_config_temp" \
      || die 70 "could not preserve the bootstrapped provider credential for rollback"
    chmod 600 "$bootstrap_config_temp" 2>/dev/null || true
    mv "$bootstrap_config_temp" "$LIVE_CONFIG_PATH" \
      || die 70 "could not publish the bootstrapped provider credential for rollback"
    if [ -f "$STAGED_PROVIDER_ID_PATH" ]; then
      bootstrap_provider_id_temp="$LIVE_PROVIDER_ID_PATH.bootstrap.$$"
      cp "$STAGED_PROVIDER_ID_PATH" "$bootstrap_provider_id_temp" \
        || die 70 "could not preserve the bootstrapped provider identity for rollback"
      chmod 600 "$bootstrap_provider_id_temp" 2>/dev/null || true
      mv "$bootstrap_provider_id_temp" "$LIVE_PROVIDER_ID_PATH" \
        || die 70 "could not publish the bootstrapped provider identity for rollback"
    fi
    CUTOVER_STARTED=1
  fi
}

submit_required_hardware_evidence() {
  log "Submitting the exact stored autotune evidence before provider service start."
  run_macprovider_cli_with_amfi_retry autotune --recommend --freshness-check \
    --submit-hardware-evidence --require-hardware-evidence --config "$CONFIG_PATH" >/dev/null \
    || die 6 "authenticated hardware evidence admission failed before service start"
}

select_autotune_benchmark_port() {
  requested="${MACPROVIDER_AUTOTUNE_PORT:-}"
  if [ -n "$requested" ]; then
    validate_port_value "$requested"
    [ "$requested" != "$PORT" ] || die 7 "autotune benchmark port must differ from live provider port $PORT"
    if lsof -nP -iTCP:"$requested" -sTCP:LISTEN -t 2>/dev/null | grep -q .; then
      die 7 "autotune benchmark port $requested is already in use"
    fi
    AUTOTUNE_BENCHMARK_PORT="$requested"
    return
  fi

  candidate=19080
  while [ "$candidate" -le 19179 ]; do
    if [ "$candidate" != "$PORT" ] && ! lsof -nP -iTCP:"$candidate" -sTCP:LISTEN -t 2>/dev/null | grep -q .; then
      AUTOTUNE_BENCHMARK_PORT="$candidate"
      return
    fi
    candidate=$((candidate + 1))
  done
  die 7 "no free autotune benchmark port is available in 19080-19179"
}

run_autotune_recommend_apply() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would run paid-yield recommendation before service start."
    return 0
  fi
  if [ ! -x "${MACPROVIDER_CLI_EXECUTABLE:-$INSTALL_DIR/macprovider-cli}" ]; then
    die 5 "staged macprovider-cli missing before autotune recommendation"
  fi
  log "Running paid-yield recommendation before service start."
  if run_macprovider_cli_with_amfi_retry autotune --recommend --apply \
    --port "${AUTOTUNE_BENCHMARK_PORT:-19080}" --config "$CONFIG_PATH" --no-submit-hardware-evidence; then
    recommended_model="$(read_config_model || true)"
    artifact_path="$(read_config_artifact_path || true)"
    artifact_sha="$(read_config_artifact_sha || true)"
    if [ -n "$recommended_model" ] && [ -n "$artifact_path" ] && [ -n "$artifact_sha" ]; then
      case "$artifact_path" in
        /*)
          if prompt_yes_no "Start provider with $recommended_model? [Y/n]" "Y"; then
            model="$recommended_model"
            log "Recommendation selected verified model: $model (artifact: $artifact_path)"
            ensure_provider_credentials
            submit_required_hardware_evidence
            return 0
          fi
          SKIP_PROVIDER_START=1
          log "Provider start declined. macprovider-cli is installed, but the provider service will not be started."
          return 0
          ;;
      esac
    fi
    log "No paid model currently clears the minimum net-yield threshold on this Mac."
    if prompt_yes_no "Enable donor mode? [y/N]" "N"; then
      log "Applying donor-mode configuration."
      run_macprovider_cli_with_amfi_retry autotune --recommend --apply --donor-mode \
        --port "${AUTOTUNE_BENCHMARK_PORT:-19080}" --config "$CONFIG_PATH" --no-submit-hardware-evidence \
        || die 6 "donor-mode recommendation failed before service start"
      recommended_model="$(read_config_model || true)"
      artifact_path="$(read_config_artifact_path || true)"
      artifact_sha="$(read_config_artifact_sha || true)"
      if [ -n "$recommended_model" ] && [ -n "$artifact_path" ] && [ -n "$artifact_sha" ]; then
        case "$artifact_path" in
          /*)
            model="$recommended_model"
            log "Donor mode selected verified model: $model (artifact: $artifact_path)"
            SKIP_PROVIDER_START=1
            log "Donor-mode configuration applied. Provider service will not be started automatically."
            return 0
            ;;
        esac
      fi
      die 6 "donor mode did not apply a verified local model artifact before service start"
    fi
    SKIP_PROVIDER_START=1
    log "Donor mode declined. macprovider-cli is installed, but the provider service will not be started."
    return 0
  fi
  die 6 "autotune recommendation failed before service start"
}

use_fresh_recommendation_if_available() {
  if [ "$DRY_RUN" -eq 1 ]; then
    return 1
  fi
  if [ ! -x "$MACPROVIDER_CLI_EXECUTABLE" ] || [ ! -f "$CONFIG_PATH" ]; then
    return 1
  fi

  if run_macprovider_cli_with_amfi_retry autotune --recommend --freshness-check --no-submit-hardware-evidence --config "$CONFIG_PATH" >/dev/null; then
    ensure_provider_credentials
    submit_required_hardware_evidence
    recommended_model="$(read_config_model || true)"
    artifact_path="$(read_config_artifact_path || true)"
    artifact_sha="$(read_config_artifact_sha || true)"
    donor_mode="$(read_config_donor_mode || true)"
    if [ "$donor_mode" = "true" ]; then
      SKIP_PROVIDER_START=1
      log "Stored donor-mode recommendation is fresh; provider service will not be started automatically."
      return 0
    fi
    if [ -n "$recommended_model" ] && [ -n "$artifact_path" ] && [ -n "$artifact_sha" ]; then
      case "$artifact_path" in
        /*)
          model="$recommended_model"
          log "Stored paid-yield recommendation is fresh; skipping re-tune."
          log "Using verified model from existing config: $model (artifact: $artifact_path)"
          return 0
          ;;
      esac
    fi
    log "Stored recommendation is fresh but config lacks a verified local model; re-running recommendation."
    return 1
  else
    rc=$?
    if [ "$rc" -eq 10 ]; then
      log "Stored recommendation is stale or missing; running recommendation."
      return 1
    fi
    die 6 "recommendation freshness check failed before service start"
  fi
}

install_binary() {
  if [ "${INSTALL_TX_ACTIVE:-0}" -eq 1 ]; then
    assert_install_lock_ownership
  fi
  run mkdir -p "$BIN_DIR" "$INSTALL_DIR"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would install macprovider-cli to $BINARY_PATH"
    log "Would keep release support files in $INSTALL_DIR"
    return
  fi
  if [ -z "$staging_dir" ] || [ ! -x "$staging_dir/macprovider-cli" ]; then
    stage_release_payload
  fi

  # CRITICAL: mlx-swift loads Metal kernels from mlx.metallib and/or
  # .bundle directories adjacent to the binary. We install the REAL binary
  # into $INSTALL_DIR alongside those resources, then place a symlink at
  # $BINARY_PATH so PATH users + the launchd plist still find it via the canonical
  # SPEC-003 FR-C2 location (~/.local/bin/macprovider-cli).
  # Prior v1.2.1 install separated them and Metal failed with
  # "library not found" at runtime.
  real_binary="$INSTALL_DIR/macprovider-cli"
  cp "$staging_dir/macprovider-cli" "$real_binary"
  chmod +x "$real_binary" 2>/dev/null || true

  # Metal resources live alongside the real binary (where mlx-swift looks).
  rm -f "$INSTALL_DIR/mlx.metallib"
  if [ -f "$staging_dir/mlx.metallib" ]; then
    cp "$staging_dir/mlx.metallib" "$INSTALL_DIR/mlx.metallib"
  fi
  rm -f "$INSTALL_DIR/THIRD-PARTY-NOTICES.txt"
  if [ -f "$staging_dir/THIRD-PARTY-NOTICES.txt" ]; then
    cp "$staging_dir/THIRD-PARTY-NOTICES.txt" "$INSTALL_DIR/THIRD-PARTY-NOTICES.txt"
  fi
  find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -name '*.bundle' -exec rm -rf {} +
  find "$staging_dir" -mindepth 1 -maxdepth 1 -name '*.bundle' -exec cp -R {} "$INSTALL_DIR"/ \;
  rm -rf "$INSTALL_DIR/catalog-release"
  if [ -d "$staging_dir/catalog-release" ]; then
    cp -R "$staging_dir/catalog-release" "$INSTALL_DIR/catalog-release"
  elif [ "${EMERGENCY_ROLLBACK:-0}" != "1" ]; then
    die 5 "staged provider release is missing catalog-release"
  fi

  # Atomic symlink swap at the canonical path.
  rm -f "$BINARY_PATH"
  ln -s "$real_binary" "$BINARY_PATH"

  [ -x "$real_binary" ] || die 5 "macprovider-cli was not installed at $real_binary"
  [ -L "$BINARY_PATH" ] || die 5 "symlink not created at $BINARY_PATH"
  MACPROVIDER_CLI_EXECUTABLE="$real_binary"
}

check_install_dir_clean() {
  if [ ! -d "$INSTALL_DIR" ]; then
    return 0
  fi
  local entries
  # F-603-V7-7: warn on mixed-state directories such as leftover Python
  # virtualenvs, but do not block an otherwise valid partner upgrade.
  entries=$(ls -A "$INSTALL_DIR" 2>/dev/null | grep -vE '^(macprovider-cli(\.v[0-9.]+\.bak)?|mlx\.metallib|THIRD-PARTY-NOTICES\.txt|catalog-release|.*\.bundle)$' | head -20 || true)
  if [ -n "$entries" ]; then
    log "WARNING: $INSTALL_DIR contains non-macprovider entries:"
    while IFS= read -r entry; do
      log "  - $entry"
    done <<EOF
$entries
EOF
    log "These will not be modified by install.sh, but you may want"
    log "to clean up the directory after the upgrade. Continuing..."
  fi
}

check_path_hint() {
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) log "$BIN_DIR is not in PATH; use $BINARY_PATH directly or add ~/.local/bin to PATH." ;;
  esac
}

clear_quarantine() {
  quarantine_path="${1:-$INSTALL_DIR}"
  if ! command -v xattr >/dev/null 2>&1; then
    log "xattr not found; skipping quarantine cleanup."
    return
  fi
  if [ "${asset_kind:-}" = "pkg" ]; then
    log "Package release passed Gatekeeper assessment; quarantine cleanup is not required."
    return
  fi
  log "Tarball release may carry a quarantine attribute. Clearing it lets macOS run the staged CLI."
  if prompt_yes_no "Clear quarantine attribute on the verified staged release? [Y/n]" "Y"; then
    run xattr -dr com.apple.quarantine "$quarantine_path"
  else
    die 7 "user declined quarantine cleanup"
  fi
}

install_plist() {
  if [ "${INSTALL_TX_ACTIVE:-0}" -eq 1 ]; then
    assert_install_lock_ownership
  fi
  model="$1"
  provider_id="$2"
  coordinator_url="$3"
  if [ "$NO_LAUNCHD" = "1" ]; then
    log "Skipping launchd service install (MACPROVIDER_NO_LAUNCHD=1 expert/debug override)."
    return
  fi
  log "Installing as a background launchd service."

  run mkdir -p "$(dirname "$PLIST_PATH")" "$LOG_DIR"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would render launchd plist to $PLIST_PATH"
    log "Would enable launchd service: launchctl enable gui/$UID/live.streamvc.macprovider"
    log "Would bootstrap with: launchctl bootstrap gui/$UID $PLIST_PATH"
    return
  fi

  render_plist "$model" "$provider_id" "$coordinator_url" > "$PLIST_PATH"

  plutil -lint "$PLIST_PATH" >/dev/null || die 5 "rendered launchd plist is invalid"
  launchctl bootout "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1 || true
  launchctl enable "gui/$UID/live.streamvc.macprovider" || die 5 "failed to enable launchd service"
  launchctl bootstrap "gui/$UID" "$PLIST_PATH" || die 5 "failed to load launchd service"
  LAUNCHD_INSTALLED=1
}

render_plist() {
  user_home="$(xml_escape "$HOME")"
  install_prefix="$(xml_escape "$INSTALL_DIR")"
  config_path="$(xml_escape "$CONFIG_PATH")"
  # F-603-V7-4: launchd must invoke the real binary path, not the
  # ~/.local/bin symlink, so Swift Bundle resolution finds adjacent bundles.
  binary_path="$(xml_escape "$INSTALL_DIR/macprovider-cli")"
  log_dir="$(xml_escape "$LOG_DIR")"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>live.streamvc.macprovider</string>
  <key>ProgramArguments</key>
  <array>
    <string>$binary_path</string>
    <string>serve</string>
    <string>--config</string>
    <string>$config_path</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>$log_dir/macprovider.out.log</string>
  <key>StandardErrorPath</key>
  <string>$log_dir/macprovider.err.log</string>
  <key>WorkingDirectory</key>
  <string>$install_prefix</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$user_home</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$user_home/.local/bin</string>
    <key>MACPROVIDER_CONFIG</key>
    <string>$config_path</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>ProcessType</key>
  <string>Adaptive</string>
</dict>
</plist>
EOF
}

# Issue #191: write the inlined watchdog.sh to disk.
#
# IMPORTANT: the body below must stay byte-identical (after comment
# / blank-line normalization) with `ops/macprovider-watchdog/watchdog.sh`.
# `scripts/test-watchdog-inline-drift.sh` enforces this in CI.
write_watchdog_script() {
  cat <<'WATCHDOG_EOF' > "$WATCHDOG_PATH"
#!/usr/bin/env bash
set -euo pipefail
LABEL="${MACPROVIDER_WATCHDOG_LABEL:-live.streamvc.macprovider}"
CONFIG_PATH="${MACPROVIDER_CONFIG_PATH:-$HOME/.config/macprovider/config.yaml}"
BINARY_PATH="${MACPROVIDER_BINARY_PATH:-$HOME/macprovider/macprovider-cli}"
COORDINATOR_HOST="${MACPROVIDER_COORDINATOR_HOST:-coordinator.streamvc.live}"
COORDINATOR_PORT="${MACPROVIDER_COORDINATOR_PORT:-443}"
LOG_DIR="${MACPROVIDER_LOG_DIR:-$HOME/Library/Logs/macprovider}"
LOG_PATH="$LOG_DIR/watchdog.log"
STATE_DIR="${MACPROVIDER_WATCHDOG_STATE_DIR:-$HOME/.local/share/macprovider-watchdog/state}"
ARMED_FILE="$STATE_DIR/armed"
LAST_KICK_FILE="$STATE_DIR/last_kick"
KICK_GRACE_SECONDS="${MACPROVIDER_WATCHDOG_KICK_GRACE_SECONDS:-300}"
mkdir -p "$LOG_DIR" "$STATE_DIR"
current_boot_id() {
  sysctl -n kern.bootsessionuuid 2>/dev/null
}
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
  netstat -an -p tcp 2>/dev/null \
    | awk -v target="${ip}.${COORDINATOR_PORT}" '
        $0 ~ /ESTABLISHED/ && $5 == target { found = 1; exit }
        END { exit found ? 0 : 1 }
      '
}
provider_process_pid() {
  expected="$BINARY_PATH"
  if command -v realpath >/dev/null 2>&1 && [ -e "$expected" ]; then
    expected="$(realpath "$expected" 2>/dev/null || printf "%s" "$expected")"
  fi
  matches=""
  for candidate in $(pgrep -x macprovider-cli 2>/dev/null || true); do
    cmd="$(ps -p "$candidate" -o command= 2>/dev/null || true)"
    command_path="${cmd%% *}"
    if command -v realpath >/dev/null 2>&1 && [ -e "$command_path" ]; then
      command_path="$(realpath "$command_path" 2>/dev/null || printf "%s" "$command_path")"
    fi
    [ "$command_path" = "$expected" ] && matches="${matches}${candidate}
"
  done
  count="$(printf "%s" "$matches" | awk 'NF { n++ } END { print n + 0 }')"
  [ "$count" -eq 1 ] || return 1
  printf "%s" "$matches" | awk 'NF { print; exit }'
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
note_provider_restart_request() {
  log "provider restart requested for $LABEL but skipped: launchd KeepAlive is the sole runtime manager"
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
import uuid
root = os.environ["AUTUPDATE_STATE_ROOT"]
label = os.environ["MACPROVIDER_LABEL"]
log_path = os.environ["LOG_PATH"]
pending = os.path.join(root, "pending.json")
lock_path = os.path.join(root, "update.lock")
install_lock_path = os.path.expanduser("~/.config/macprovider/install.lock")
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
        allowed = lambda name: name in {"mlx.metallib", "THIRD-PARTY-NOTICES.txt", "catalog-release"} or name.endswith(".bundle")
        if any(not allowed(name) for name in os.listdir(release_backup)):
            raise RuntimeError("release_backup_unexpected_entry")
        if release_tree_sha256(release_backup) != str(marker["release_backup_sha256"]):
            raise RuntimeError("release_backup_sha256_mismatch")
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
    return name in {"mlx.metallib", "THIRD-PARTY-NOTICES.txt", "catalog-release"} or name.endswith(".bundle")
def copy_release_resources(source, destination):
    for name in os.listdir(source):
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
            fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
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
        source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
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
def restore(marker):
    backup, target, release_backup = validate_restore_inputs(marker)
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
    atomic_copy_binary(backup, target, int(marker["mode"]))
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
        os.unlink(backup)
    except FileNotFoundError:
        pass
    if release_backup:
        shutil.rmtree(release_backup, ignore_errors=True)
    reason = "restored_prior_release" if release_backup else "restored_prior_binary"
    event("failure", "rollback", classify_post_start_failure(marker), reason, marker)
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
try:
    verify_root()
    acquired = acquire_transaction_locks()
    if acquired is None:
        sys.exit(0)
    transaction_locks = acquired
    if not os.path.exists(pending):
        scan_without_pending()
        sys.exit(0)
    reject_path(pending)
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
        restore(marker)
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
PY
}
main() {
  autoupdate_recovery_tick
  pid="$(read_provider_id || true)"
  if [ -z "$pid" ]; then
    exit 0
  fi
  provider_pid="$(provider_process_pid || true)"
  if [ -z "$provider_pid" ]; then
    log "provider process unhealthy: expected exactly one macprovider-cli at $BINARY_PATH"
    now_epoch > "$LAST_KICK_FILE"
    note_provider_restart_request
    exit 0
  fi
  boot_id="$(current_boot_id)"
  if ! local_provider_health_ok "$provider_pid"; then
    armed_boot=""
    if [ -f "$ARMED_FILE" ]; then
      armed_boot="$(cat "$ARMED_FILE" 2>/dev/null || true)"
    fi
    if [ "$armed_boot" != "$boot_id" ]; then
      log "provider process $provider_pid not locally healthy yet; watchdog remains disarmed for boot=${boot_id}"
      exit 0
    fi
    if [ -f "$LAST_KICK_FILE" ]; then
      last_kick="$(cat "$LAST_KICK_FILE" 2>/dev/null || printf 0)"
      elapsed=$(( $(now_epoch) - last_kick ))
      if [ "$elapsed" -lt "$KICK_GRACE_SECONDS" ]; then
        exit 0
      fi
    fi
    log "provider process $provider_pid failed local /v1/health after arming; leaving restart ownership to launchd KeepAlive for $LABEL"
    now_epoch > "$LAST_KICK_FILE"
    note_provider_restart_request
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
    exit 0
  fi
  log "warning: provider process $provider_pid is locally healthy, but no ESTABLISHED TCP to ${coord_ip}:${COORDINATOR_PORT} for provider_id=${pid}"
  exit 0
}
main "$@"
WATCHDOG_EOF
  chmod 0755 "$WATCHDOG_PATH"
}

render_watchdog_plist() {
  watchdog_path="$(xml_escape "$WATCHDOG_PATH")"
  user_home="$(xml_escape "$HOME")"
  log_dir="$(xml_escape "$LOG_DIR")"
  config_path="$(xml_escape "$CONFIG_PATH")"
  binary_path="$(xml_escape "$INSTALL_DIR/macprovider-cli")"
  coord_host="$(xml_escape "$(printf "%s" "$1" | sed -E 's#^wss?://##; s#/.*##')")"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$WATCHDOG_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$watchdog_path</string>
  </array>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$log_dir/watchdog.out.log</string>
  <key>StandardErrorPath</key>
  <string>$log_dir/watchdog.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$user_home</string>
    <key>PATH</key>
    <!-- Issue #191 R4 architect HIGH: include /usr/sbin and /sbin
         so the watchdog finds sysctl + netstat under launchd's
         minimal PATH. -->
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>MACPROVIDER_WATCHDOG_LABEL</key>
    <string>live.streamvc.macprovider</string>
    <key>MACPROVIDER_CONFIG_PATH</key>
    <string>$config_path</string>
    <key>MACPROVIDER_BINARY_PATH</key>
    <string>$binary_path</string>
    <key>MACPROVIDER_COORDINATOR_HOST</key>
    <string>$coord_host</string>
    <key>MACPROVIDER_LOG_DIR</key>
    <string>$log_dir</string>
  </dict>
  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
EOF
}

# Issue #191: install the LaunchAgent watchdog. Idempotent (same
# bootout-before-bootstrap pattern as install_plist).
install_watchdog() {
  coordinator_url="$1"
  if [ "$NO_WATCHDOG" = "1" ]; then
    log "Skipping watchdog install (MACPROVIDER_NO_WATCHDOG=1)."
    return
  fi
  if [ "$NO_LAUNCHD" = "1" ]; then
    log "Skipping watchdog install (MACPROVIDER_NO_LAUNCHD=1)."
    return
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would write watchdog to $WATCHDOG_PATH and bootstrap $WATCHDOG_LABEL"
    return
  fi
  if [ "${INSTALL_TX_ACTIVE:-0}" -eq 1 ]; then
    assert_install_lock_ownership
  fi
  log "Installing watchdog LaunchAgent (operator-visibility safety net for iss-189-class wedges)."
  mkdir -p "$WATCHDOG_DIR" "$LOG_DIR" "$(dirname "$WATCHDOG_PLIST_PATH")"
  legacy_watchdog="$WATCHDOG_DIR/watchdog.sh"
  if [ -f "$legacy_watchdog" ] && [ "$legacy_watchdog" != "$WATCHDOG_PATH" ]; then
    rm -f "$legacy_watchdog"
  fi
  write_watchdog_script
  render_watchdog_plist "$coordinator_url" > "$WATCHDOG_PLIST_PATH"
  plutil -lint "$WATCHDOG_PLIST_PATH" >/dev/null \
    || die 5 "rendered watchdog plist is invalid"
  launchctl bootout "gui/$UID" "$WATCHDOG_PLIST_PATH" >/dev/null 2>&1 || true
  launchctl enable "gui/$UID/$WATCHDOG_LABEL" \
    || die 5 "failed to enable watchdog launchd service"
  launchctl bootstrap "gui/$UID" "$WATCHDOG_PLIST_PATH" \
    || die 5 "failed to load watchdog launchd service"
  WATCHDOG_INSTALLED=1
  log "Watchdog installed. Logs at $LOG_DIR/watchdog.log."
}

write_install_manifest() {
  if [ "${INSTALL_TX_ACTIVE:-0}" -eq 1 ]; then
    assert_install_lock_ownership
  fi
  version="${1:-unknown}"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would write install manifest to $MANIFEST_PATH"
    return
  fi
  mkdir -p "$MANIFEST_DIR"
  labels_json="[]"
  if [ "$LAUNCHD_INSTALLED" -eq 1 ] && [ "$WATCHDOG_INSTALLED" -eq 1 ]; then
    labels_json='["live.streamvc.macprovider","live.streamvc.macprovider-watchdog"]'
  elif [ "$LAUNCHD_INSTALLED" -eq 1 ]; then
    labels_json='["live.streamvc.macprovider"]'
  elif [ "$WATCHDOG_INSTALLED" -eq 1 ]; then
    labels_json='["live.streamvc.macprovider-watchdog"]'
  fi
  cat > "$MANIFEST_PATH" <<EOF
{
  "install_prefix": $(json_escape "$INSTALL_DIR"),
  "binary_path": $(json_escape "$INSTALL_DIR/macprovider-cli"),
  "symlink_path": $(json_escape "$BINARY_PATH"),
  "launchd_labels": $labels_json,
  "launchd_plists": [
    $(json_escape "$PLIST_PATH"),
    $(json_escape "$WATCHDOG_PLIST_PATH")
  ],
  "data_dirs": [
    $(json_escape "$INSTALL_DIR"),
    $(json_escape "$LOG_DIR"),
    $(json_escape "$WATCHDOG_DIR")
  ],
  "version": $(json_escape "$version")
}
EOF
  chmod 600 "$MANIFEST_PATH" 2>/dev/null || true
}

start_manual_service() {
  [ "$LAUNCHD_INSTALLED" -eq 1 ] && return
  if [ "${INSTALL_TX_ACTIVE:-0}" -eq 1 ]; then
    assert_install_lock_ownership
  fi
  log "Starting macprovider-cli directly for non-launchd self-test."
  mkdir -p "$LOG_DIR"
  (
    cd "$INSTALL_DIR"
    # F-603-V7-4: direct background self-test also invokes the real binary
    # so MLX resolves adjacent Metal resources.
    nohup "$INSTALL_DIR/macprovider-cli" \
      serve \
      --config "$CONFIG_PATH" \
      > "$LOG_DIR/macprovider.out.log" \
      2> "$LOG_DIR/macprovider.err.log" &
    echo "$!"
  ) > "$TMPDIR_PATH/manual.pid"
  MANUAL_PID="$(cat "$TMPDIR_PATH/manual.pid")"
  if [ "$INSTALL_TX_ACTIVE" -eq 1 ]; then
    printf '%s\n' "$MANUAL_PID" > "$INSTALL_TX_BACKUP/new-manual.pid" \
      || die 70 "could not durably record the manual provider process for rollback"
    chmod 600 "$INSTALL_TX_BACKUP/new-manual.pid" \
      || die 70 "could not secure the manual provider rollback record"
  fi
}

unload_app_managed_launchd_jobs() {
  [ "${INSTALL_TX_ACTIVE:-0}" -eq 1 ] && assert_install_lock_ownership
  # Address the launchd domain by label even when a crashing KeepAlive job has
  # no listener. Port-based cutover detection cannot see that state.
  launchctl bootout "gui/$UID/live.streamvc.macprovider" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID/$WATCHDOG_LABEL" >/dev/null 2>&1 || true
  # Older launchctl versions are more reliable with the plist form.
  [ ! -f "$PLIST_PATH" ] \
    || launchctl bootout "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1 \
    || true
  [ ! -f "$WATCHDOG_PLIST_PATH" ] \
    || launchctl bootout "gui/$UID" "$WATCHDOG_PLIST_PATH" >/dev/null 2>&1 \
    || true
  attempts=0
  while [ "$attempts" -lt 40 ]; do
    provider_loaded=0
    watchdog_loaded=0
    launchctl print "gui/$UID/live.streamvc.macprovider" >/dev/null 2>&1 \
      && provider_loaded=1
    launchctl print "gui/$UID/$WATCHDOG_LABEL" >/dev/null 2>&1 \
      && watchdog_loaded=1
    listener_present=0
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1 \
      && listener_present=1
    if [ "$provider_loaded" -eq 0 ] \
      && [ "$watchdog_loaded" -eq 0 ] \
      && [ "$listener_present" -eq 0 ]; then
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  die 70 "could not confirm launchd ownership release for app-managed repair"
}

cache_size_kb() {
  path="$1"
  if [ -d "$path" ]; then
    du -sk "$path" 2>/dev/null | awk '{ print $1 }'
  else
    printf "0"
  fi
}

format_kb_gib() {
  kb="$1"
  awk -v kb="$kb" 'BEGIN { printf "%.1f", kb / 1048576 }'
}

progress_bar() {
  percent="$1"
  width=20
  filled=$(( percent * width / 100 ))
  bar=""
  i=0
  while [ "$i" -lt "$width" ]; do
    if [ "$i" -lt "$filled" ]; then
      bar="${bar}#"
    else
      bar="${bar}."
    fi
    i=$((i + 1))
  done
  printf "[%s]" "$bar"
}

model_download_estimate_gb() {
  model="$1"
  estimate="$(known_weight_gb_for_model "$model")"
  if [ -z "$estimate" ]; then
    estimate="$(estimate_weights_gb_from_name "$model")"
  fi
  printf "%s" "${estimate:-0}"
}

model_cache_is_warm() {
  current_kb="$1"
  estimate_gb="$2"
  if [ "$estimate_gb" -le 0 ]; then
    return 0
  fi
  estimate_kb=$(( estimate_gb * 1048576 ))
  warm_threshold_kb=$(( estimate_kb * 80 / 100 ))
  [ "$current_kb" -ge "$warm_threshold_kb" ]
}

print_model_download_progress() {
  cache_path="$1"
  estimate_gb="$2"
  elapsed="$3"
  previous_kb="$4"
  current_kb="$(cache_size_kb "$cache_path")"
  delta_kb=$(( current_kb - previous_kb ))
  [ "$delta_kb" -lt 0 ] && delta_kb=0

  if [ "$estimate_gb" -gt 0 ] && [ "$current_kb" -gt 0 ]; then
    estimate_kb=$(( estimate_gb * 1048576 ))
    percent=$(( current_kb * 100 / estimate_kb ))
    [ "$percent" -gt 99 ] && percent=99
    bar="$(progress_bar "$percent")"
    current_gib="$(format_kb_gib "$current_kb")"
    delta_gib="$(format_kb_gib "$delta_kb")"
    log "Model download ${bar} ${current_gib}/${estimate_gb} GiB (${percent}%, +${delta_gib} GiB; ${elapsed}s elapsed)."
  elif [ "$current_kb" -gt 0 ]; then
    current_gib="$(format_kb_gib "$current_kb")"
    delta_gib="$(format_kb_gib "$delta_kb")"
    log "Model download cache: ${current_gib} GiB (+${delta_gib} GiB; ${elapsed}s elapsed)."
  else
    log "Waiting for model download to start (${elapsed}s elapsed)."
  fi
  MODEL_PROGRESS_CACHE_KB="$current_kb"
}

wait_for_local_model() {
  model="$1"
  # F-603-V7-5: first install can take much longer if MLX has to download a
  # multi-GB model. Keep warm-cache installs at 5 minutes; allow cold-cache
  # installs 20 minutes with visible progress.
  local cache_check="$HOME/.cache/huggingface/hub/models--${model//\//--}"
  start_ts="$(date +%s)"
  estimate_gb="$(model_download_estimate_gb "$model")"
  previous_cache_kb="$(cache_size_kb "$cache_check")"
  if [ -d "$cache_check" ] && model_cache_is_warm "$previous_cache_kb" "$estimate_gb"; then
    deadline=$(( start_ts + 300 ))
    next_progress=$(( start_ts + 15 ))
    if [ "$estimate_gb" -gt 0 ]; then
      log "Waiting up to 5 min for local /v1/models (model cache detected; expected weights ~${estimate_gb} GiB)."
    else
      log "Waiting up to 5 min for local /v1/models (model cache detected)."
    fi
  elif [ -d "$cache_check" ]; then
    deadline=$(( start_ts + 1200 ))
    next_progress=$(( start_ts + 15 ))
    cache_gib="$(format_kb_gib "$previous_cache_kb")"
    if [ "$estimate_gb" -gt 0 ]; then
      log "Waiting up to 20 min for local /v1/models (partial model cache detected: ${cache_gib}/${estimate_gb} GiB; continuing download for ${model})."
    else
      log "Waiting up to 20 min for local /v1/models (model cache detected but may still be downloading ${model})."
    fi
  else
    deadline=$(( start_ts + 1200 ))
    next_progress=$(( start_ts + 15 ))
    if [ "$estimate_gb" -gt 0 ]; then
      log "Waiting up to 20 min for local /v1/models (first-time install; downloading ${model} ~${estimate_gb} GiB)."
    else
      log "Waiting up to 20 min for local /v1/models (first-time install; downloading ${model})."
    fi
  fi
  port_seen=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    raw_models_json="$(curl -sS --max-time 3 "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true)"
    # The Swift JSON encoder emits forward-slashes as \/ (legal per RFC 8259
    # but cosmetically ugly). Normalize so grep -Fq "$model" matches whether
    # the encoder emits / or \/.
    models_json="$(printf "%s" "$raw_models_json" | sed 's|\\/|/|g')"
    if [ -n "$models_json" ] && [ "$port_seen" -eq 0 ]; then
      port_seen=1
      elapsed=$(( $(date +%s) - start_ts ))
      log "Port ${PORT} is listening (after ${elapsed}s). Waiting for model load..."
    fi
    if printf "%s" "$models_json" | grep -q '"owned_by"[[:space:]]*:[[:space:]]*"macprovider"' &&
       printf "%s" "$models_json" | grep -Fq "$model"; then
      return 0
    fi
    now="$(date +%s)"
    if [ "$now" -ge "$next_progress" ]; then
      elapsed=$(( now - start_ts ))
      if [ "$port_seen" -eq 0 ]; then
        log "Still waiting for macprovider-cli to bind port ${PORT} (${elapsed}s elapsed)..."
        print_model_download_progress "$cache_check" "$estimate_gb" "$elapsed" "$previous_cache_kb"
        previous_cache_kb="$MODEL_PROGRESS_CACHE_KB"
      else
        log "Model still loading (${elapsed}s elapsed; first run may still be downloading from Hugging Face)..."
        print_model_download_progress "$cache_check" "$estimate_gb" "$elapsed" "$previous_cache_kb"
        previous_cache_kb="$MODEL_PROGRESS_CACHE_KB"
      fi
      next_progress=$(( now + 15 ))
    fi
    sleep 2
  done
  return 1
}

print_local_self_test_diagnostics() {
  # F-603-V7-6: distinguish a timeout from a proven binary failure and leave
  # the user with concrete checks for process, download, and stderr state.
  log ""
  log "==========================================================="
  log "Self-test timeout reached. THIS DOES NOT NECESSARILY MEAN"
  log "THE BINARY FAILED. macprovider-cli is likely still loading"
  log "the model in the background."
  log ""
  log "To check if the binary is alive:"
  log "  ps aux | grep macprovider-cli | grep -v grep"
  log ""
  log "To check if the model is still downloading:"
  log "  du -sh ~/.cache/huggingface/hub/"
  log "  (run twice 30s apart; growing = downloading)"
  log ""
  log "To check for errors:"
  log "  tail -30 $LOG_DIR/macprovider.err.log"
  log ""
  log "Once the binary fully loads, it joins the pool. You can"
  log "verify from the coordinator side via /v1/pool/check (see docs)."
  log "==========================================================="
  log ""

  raw_response="$(curl -sS --max-time 3 "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true)"
  if [ -n "$raw_response" ]; then
    log "Raw /v1/models response (first 200 bytes):"
    printf "  %.200s\n" "$raw_response"
    return
  fi

  log "/v1/models did not respond. Binary may not have bound port ${PORT}."
  log "stderr log path: $LOG_DIR/macprovider.err.log"
  if [ -s "$LOG_DIR/macprovider.err.log" ]; then
    log "Last 200 bytes of macprovider.err.log:"
    tail -c 200 "$LOG_DIR/macprovider.err.log" | sed 's/^/  /'
  fi
}

wait_for_coordinator() {
  provider_id="$1"
  coordinator_base="$2"
  deadline=$(( $(date +%s) + 30 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local_status="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/v1/status" 2>/dev/null || true)"
    assigned_id="$(python3 - "$provider_id" "$local_status" <<'PY' 2>/dev/null || true
import json
import sys

provider_id, local_raw = sys.argv[1:]
local = json.loads(local_raw)
coordinator = local.get("coordinator")
if local.get("provider_id") != provider_id or not isinstance(coordinator, dict):
    raise SystemExit(1)
assigned_id = coordinator.get("session")
if coordinator.get("connected") is not True or not isinstance(assigned_id, str) or not assigned_id:
    raise SystemExit(1)
print(assigned_id)
PY
)"
    if [ -z "$assigned_id" ]; then
      sleep 2
      continue
    fi
    response="$(curl -fsS --max-time 5 "$coordinator_base/v1/pool/check?provider_id=$(urlencode "$provider_id")&assigned_id=$(urlencode "$assigned_id")&details=readiness" 2>/dev/null || true)"
    local_status="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/v1/status" 2>/dev/null || true)"
    if python3 - "$provider_id" "$assigned_id" "$response" "$local_status" \
      "$INSTALL_DIR/catalog-release/release.json" \
      "$INSTALL_DIR/catalog-release/autotune-candidates.json" \
      "${EMERGENCY_ROLLBACK:-0}" <<'PY' 2>/dev/null
import hashlib
import json
import re
import sys

provider_id, assigned_id, response_raw, local_raw, release_path, candidates_path, emergency_raw = sys.argv[1:]
response = json.loads(response_raw)
local = json.loads(local_raw)
coordinator = local.get("coordinator")
if not isinstance(coordinator, dict):
    raise SystemExit(1)
if coordinator.get("connected") is not True or coordinator.get("session") != assigned_id:
    raise SystemExit(1)
if response.get("assigned_id") != assigned_id:
    raise SystemExit(1)
if emergency_raw == "1":
    # Coordinator buyer-serving admission for the exact connected session is
    # the authority for this deliberately legacy-only recovery path; do not
    # make rollback depend on optional local status fields across prior builds.
    if local.get("provider_id") != provider_id:
        raise SystemExit(1)
    if response.get("provider_id") != provider_id or response.get("buyer_serving") is not True:
        raise SystemExit(1)
    if response.get("catalog_evidence_source") != "provider_reported":
        raise SystemExit(1)
    if response.get("catalog_admission_mode") != "legacy_bridge":
        raise SystemExit(1)
    raise SystemExit(0)
with open(release_path, "rb") as handle:
    release = json.load(handle)
with open(candidates_path, "rb") as handle:
    candidate_bytes = handle.read()
candidates = json.loads(candidate_bytes)

candidate_feed = release["feeds"]["autotune-candidates.json"]
candidate_sha = hashlib.sha256(candidate_bytes).hexdigest()
if candidate_sha != candidate_feed["sha256"]:
    raise SystemExit(1)
if candidates["version"] != release["release_id"] or candidates["policy_version"] != release["policy_version"]:
    raise SystemExit(1)

catalog = local.get("catalog")
if not isinstance(catalog, dict):
    raise SystemExit(1)
model = local.get("model")
key = catalog.get("catalog_key")
rows = candidates.get("rows")
if not isinstance(rows, dict):
    raise SystemExit(1)
if not isinstance(key, str) or key not in rows or rows[key].get("model_id") != model:
    raise SystemExit(1)
row_identity = catalog.get("row_identity")
if re.fullmatch(r"[0-9a-f]{64}", row_identity or "") is None:
    raise SystemExit(1)
if catalog.get("policy_version") != candidates["policy_version"]:
    raise SystemExit(1)

expected = {
    "catalog_release_id": release["release_id"],
    "catalog_policy_version": release["policy_version"],
    "catalog_candidate_sha256": candidate_sha,
    "catalog_signer_key_id": candidate_feed["signer_key_id"],
    "catalog_row_identity": row_identity,
}
if local.get("provider_id") != provider_id or local.get("network_state") != "buyer_serving":
    raise SystemExit(1)
if catalog.get("release_id") != expected["catalog_release_id"]:
    raise SystemExit(1)
if catalog.get("digest") != expected["catalog_candidate_sha256"]:
    raise SystemExit(1)
if catalog.get("signer_key_id") != expected["catalog_signer_key_id"]:
    raise SystemExit(1)
if response.get("provider_id") != provider_id:
    raise SystemExit(1)
if response.get("buyer_serving") is not True:
    raise SystemExit(1)
if response.get("catalog_evidence_source") != "provider_reported":
    raise SystemExit(1)
if response.get("catalog_admission_mode") not in {"current", "previous"}:
    raise SystemExit(1)
if any(response.get(field) != value for field, value in expected.items()):
    raise SystemExit(1)
PY
    then
      return 0
    fi
    sleep 2
  done
  return 1
}

print_pid() {
  if [ -n "$MANUAL_PID" ]; then
    printf "%s\n" "$MANUAL_PID"
    return
  fi
  launchctl list 2>/dev/null | awk '/live.streamvc.macprovider/ {print $1; exit}'
}

print_autotune_handoff() {
  printf "To tune throughput / latency parameters for your specific Mac, run:\n"
  printf '  macprovider-cli autotune --config "%s"\n' "$CONFIG_PATH"
  printf "To refresh the paid-model recommendation after install or update, run:\n"
  printf "  macprovider-cli autotune --recommend --apply\n"
}

validate_emergency_target() {
  target="$1"
  [ -x "$BINARY_PATH" ] || die 7 "emergency rollback requires an installed provider binary"
  installed_version="$("$BINARY_PATH" --version 2>/dev/null | tr -d '\r\n')"
  case "$installed_version" in
    v*) installed_tag="$installed_version" ;;
    *) installed_tag="v$installed_version" ;;
  esac
  validate_macprovider_version_tag "$installed_tag"
  if version_at_least "$target" "$installed_tag"; then
    die 7 "emergency rollback target $target must be older than installed $installed_tag"
  fi
}

verify_emergency_coordinator_advertisement() {
  coordinator_base="$1"
  target="$2"
  health="$(curl -fsS --max-time 10 "$coordinator_base/healthz" 2>/dev/null || true)"
  python3 - "$target" "$health" <<'PY' \
    || die 7 "coordinator must advertise the exact rollback target before emergency provider downgrade"
import json
import sys

target, raw = sys.argv[1:]
payload = json.loads(raw)
if payload.get("recommended_binary_version") != target.removeprefix("v"):
    raise SystemExit(1)
PY
}

validate_emergency_config_backup() {
  [ -n "$EMERGENCY_CONFIG_BACKUP" ] \
    || die 7 "emergency rollback requires MACPROVIDER_EMERGENCY_CONFIG_BACKUP"
  [ -n "$EMERGENCY_CONFIG_SHA256" ] \
    || die 7 "emergency rollback requires MACPROVIDER_EMERGENCY_CONFIG_SHA256"
  case "$EMERGENCY_CONFIG_BACKUP" in
    /*) ;;
    *) die 7 "emergency config backup path must be absolute" ;;
  esac
  if [[ ! "$EMERGENCY_CONFIG_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    die 7 "emergency config backup sha256 must be exactly 64 lowercase hex characters"
  fi
  python3 - "$EMERGENCY_CONFIG_BACKUP" "$LIVE_CONFIG_PATH" "$EMERGENCY_CONFIG_SHA256" <<'PY' \
    || die 7 "emergency config backup is not an owned private regular file with the expected sha256"
import hashlib
import os
import stat
import sys

source, live, expected = sys.argv[1:]
source_real = os.path.realpath(source)
live_real = os.path.realpath(live)
if source_real == live_real:
    raise SystemExit(1)
info = os.lstat(source)
if (
    not stat.S_ISREG(info.st_mode)
    or stat.S_ISLNK(info.st_mode)
    or info.st_uid != os.geteuid()
    or info.st_nlink != 1
    or stat.S_IMODE(info.st_mode) != 0o600
    or info.st_size <= 0
    or info.st_size > 1024 * 1024
):
    raise SystemExit(1)
descriptor = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
try:
    opened = os.fstat(descriptor)
    if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
        raise SystemExit(1)
    payload = b""
    while True:
        block = os.read(descriptor, 65536)
        if not block:
            break
        payload += block
        if len(payload) > 1024 * 1024:
            raise SystemExit(1)
finally:
    os.close(descriptor)
if hashlib.sha256(payload).hexdigest() != expected:
    raise SystemExit(1)
PY
}

stage_emergency_config_backup() {
  python3 - "$EMERGENCY_CONFIG_BACKUP" "$EMERGENCY_CONFIG_SHA256" "$STAGED_CONFIG_PATH" <<'PY' \
    || die 7 "failed to stage the verified pre-upgrade emergency config"
import hashlib
import os
import stat
import sys

source, expected, destination = sys.argv[1:]
source_info = os.lstat(source)
source_fd = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
try:
    opened = os.fstat(source_fd)
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_uid != os.geteuid()
        or opened.st_nlink != 1
        or stat.S_IMODE(opened.st_mode) != 0o600
        or (opened.st_dev, opened.st_ino) != (source_info.st_dev, source_info.st_ino)
    ):
        raise SystemExit(1)
    payload = b""
    while True:
        block = os.read(source_fd, 65536)
        if not block:
            break
        payload += block
        if len(payload) > 1024 * 1024:
            raise SystemExit(1)
finally:
    os.close(source_fd)
if not payload or hashlib.sha256(payload).hexdigest() != expected:
    raise SystemExit(1)
try:
    os.unlink(destination)
except FileNotFoundError:
    pass
destination_fd = os.open(
    destination,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
    0o600,
)
try:
    with os.fdopen(destination_fd, "wb", closefd=False) as output:
        output.write(payload)
        output.flush()
        os.fsync(output.fileno())
finally:
    os.close(destination_fd)
PY
}

disable_staged_autoupdate() {
  python3 - "$STAGED_CONFIG_PATH" <<'PY'
import os
import re
import sys
import tempfile

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines()
top_level_legacy = re.compile(r"^auto_update_enabled\s*:")
merged = [line for line in lines if not top_level_legacy.match(line)]
if merged and merged[-1].strip():
    merged.append("")
merged.append("auto_update_enabled: false")
directory = os.path.dirname(path)
fd, temporary = tempfile.mkstemp(prefix=".emergency-config-", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write("\n".join(merged) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY
}

verify_emergency_config_activation() {
  [ -n "$EMERGENCY_STAGED_CONFIG_SHA256" ] \
    || die 7 "emergency staged config digest was not recorded"
  actual_config_sha="$(shasum -a 256 "$LIVE_CONFIG_PATH" | awk '{print $1}')"
  [ "$actual_config_sha" = "$EMERGENCY_STAGED_CONFIG_SHA256" ] \
    || die 7 "activated emergency config does not match the verified staged config"
  activated_model="$(read_config_model || true)"
  [ -n "$activated_model" ] && [ "$activated_model" = "$EMERGENCY_MODEL" ] \
    || die 7 "activated emergency config does not retain the inventoried model"
  log "Emergency config proof: source_sha256=$EMERGENCY_CONFIG_SHA256 activated_sha256=$actual_config_sha model=$activated_model"
}

main() {
  detect_platform
  validate_port_value "$PORT"
  for tool in curl tar shasum grep sed awk date hostname mktemp openssl find python3 lsof cmp diff readlink ps; do
    require_tool "$tool"
  done
  validate_install_dir
  case "$APP_MANAGED_REPAIR" in
    0|1) ;;
    *) die 7 "MACPROVIDER_APP_MANAGED_REPAIR must be 0 or 1" ;;
  esac
  acquire_install_lock
  recover_orphaned_install_transactions

  ram_gb="$(detect_ram_gb)"
  model=""
  provider_id="$(choose_provider_id)"
  coordinator_url="$(choose_coordinator_url)"
  coordinator_base="$(coordinator_http_base "$coordinator_url")"
  validate_inputs "$model" "$provider_id" "$coordinator_url"
  if [ "$DRY_RUN" -eq 0 ]; then
    if existing_provider_credential_configured; then
      log "Existing provider credential found; referral pre-check is not required for repair or upgrade."
    else
      reserve_referral_capacity "$coordinator_base" "$provider_id"
    fi
  fi
  if [ "$APP_MANAGED_REPAIR" -eq 1 ]; then
    existing_provider_credential_configured \
      || die 7 "app-managed repair requires an existing provider credential"
    [ "$EMERGENCY_ROLLBACK" -eq 0 ] \
      || die 7 "app-managed repair cannot perform an emergency rollback"
  fi
  log "Model selection: signed catalog recommendation after release verification"
  log "Provider ID: $provider_id"
  log "Coordinator: $coordinator_url"
  log "Binary path: $BINARY_PATH"
  log "Support dir: $INSTALL_DIR"
  ensure_port_free 0

  if [ "$DRY_RUN" -eq 1 ]; then
    log "Dry run: would query latest release for $GITHUB_REPO, download, verify, install, and self-test."
    write_config "$model" "$provider_id" "$coordinator_url"
    install_binary
    install_plist "$model" "$provider_id" "$coordinator_url"
    install_watchdog "$coordinator_url"
    write_install_manifest "dry-run"
    check_path_hint
    exit 0
  fi

  tag="$(resolve_release_tag)"
  if [ "$EMERGENCY_ROLLBACK" = "1" ]; then
    validate_emergency_target "$tag"
    verify_emergency_coordinator_advertisement "$coordinator_base" "$tag"
    validate_emergency_config_backup
  fi
  if [ -n "${MACPROVIDER_VERSION:-}" ]; then
    log "Using operator-pinned version: $tag (via MACPROVIDER_VERSION)"
  else
    log "Latest release: $tag"
  fi
  download_release "$tag"
  verify_sha256
  validate_release_payload
  check_install_dir_clean
  begin_install_transaction
  stage_release_payload
  clear_quarantine "$staging_dir"
  prepare_staged_config
  if [ "$EMERGENCY_ROLLBACK" = "1" ]; then
    [ "$EXISTING_INSTALL_WAS_PRESENT" -eq 1 ] \
      || die 7 "emergency rollback requires an existing provider installation to restore"
    [ "$SKIP_PROVIDER_START" -eq 0 ] \
      || die 7 "emergency rollback must start and prove the restored provider before commit"
    stage_emergency_config_backup
    model="$(read_config_model || true)"
    [ -n "$model" ] \
      || die 7 "emergency rollback backup must retain its prior model"
    EMERGENCY_MODEL="$model"
    disable_staged_autoupdate
    EMERGENCY_STAGED_CONFIG_SHA256="$(shasum -a 256 "$STAGED_CONFIG_PATH" | awk '{print $1}')"
    log "Emergency rollback: restoring the verified pre-upgrade config and model while disabling provider autoupdate."
    log "The signed prior release will commit only after exact legacy_bridge buyer admission."
  else
    log "Validating signed catalog and stored recommendation with the staged release while the current provider remains available."
    if ! use_fresh_recommendation_if_available; then
      write_config "$model" "$provider_id" "$coordinator_url"
      AUTOTUNE_RECOMMENDATION_REQUIRED=1
    fi
  fi
  if [ "$SKIP_PROVIDER_START" -eq 1 ]; then
    if restore_existing_provider_if_start_skipped; then
      log "Re-run macprovider-cli autotune --recommend --apply when you want to change the active provider model."
      exit 0
    fi
    assert_install_lock_ownership
    ensure_port_free 1
    install_binary
    activate_staged_config
    check_path_hint
    write_install_manifest "$tag"
    # An explicit no-start choice has no new local service to validate, but its
    # manifest mutation is still covered by the recovery transaction.
    commit_install_transaction
    log "Install complete without starting a provider service."
    log "To re-check paid-yield recommendation later, run:"
    log "  macprovider-cli autotune --recommend --apply"
    log "To opt into local donor-mode testing, run:"
    log "  macprovider-cli autotune --recommend --apply --donor-mode"
    exit 0
  fi
  if [ "$AUTOTUNE_RECOMMENDATION_REQUIRED" -eq 1 ]; then
    # Candidate providers load full model weights. Stop the incumbent before
    # benchmarks so unified-memory pressure cannot disrupt buyer traffic or
    # corrupt benchmark results through contention.
    assert_install_lock_ownership
    ensure_port_free 1
    CUTOVER_STARTED=1
    select_autotune_benchmark_port
    run_autotune_recommend_apply
    if [ "$SKIP_PROVIDER_START" -eq 1 ]; then
      if restore_existing_provider_if_start_skipped; then
        log "Re-run macprovider-cli autotune --recommend --apply when you want to change the active provider model."
        exit 0
      fi
      install_binary
      activate_staged_config
      check_path_hint
      write_install_manifest "$tag"
      commit_install_transaction
      log "Install complete without starting a provider service."
      exit 0
    fi
  fi
  # Cut over only after the staged CLI has completed catalog validation and
  # freshness evaluation; when benchmarks are required the incumbent is
  # deliberately stopped first to avoid double-loading model weights.
  assert_install_lock_ownership
  ensure_port_free 1
  CUTOVER_STARTED=1
  install_binary
  activate_staged_config
  check_path_hint
  if [ "$APP_MANAGED_REPAIR" -eq 1 ]; then
    # The app-owned config intentionally contains no bearer. Do not start or
    # health-gate a launchd job that cannot authenticate. The caller starts the
    # verified binary as a Malibu child with its Keychain bearer immediately
    # after this transaction commits.
    unload_app_managed_launchd_jobs
    rm -f "$PLIST_PATH" "$WATCHDOG_PLIST_PATH"
    write_install_manifest "$tag"
    commit_install_transaction
    log "App-managed repair artifacts are ready; Malibu will start and verify the provider."
    exit 0
  fi
  install_plist "$model" "$provider_id" "$coordinator_url"
  install_watchdog "$coordinator_url"
  write_install_manifest "$tag"
  start_manual_service "$model" "$provider_id" "$coordinator_url"

  if ! wait_for_local_model "$model"; then
    print_local_self_test_diagnostics
    exit 6
  fi

  # Keep rollback armed until coordinator admission proves the selected mode:
  # exact current/previous catalog identity for normal upgrades, or exact
  # buyer-serving legacy_bridge for an explicit signed emergency downgrade.
  log "Waiting up to 30s for exact coordinator admission and buyer-serving readiness."
  if ! wait_for_coordinator "$provider_id" "$coordinator_base"; then
    if [ "$EMERGENCY_ROLLBACK" = "1" ]; then
      log "Coordinator did not admit the restored provider through active legacy_bridge; rolling back."
    else
      log "Coordinator did not admit the exact local catalog envelope for buyer traffic; rolling back."
    fi
    exit 6
  fi
  if [ "$EMERGENCY_ROLLBACK" = "1" ]; then
    verify_emergency_config_activation
  fi
  commit_install_transaction

  pid="$(print_pid || true)"
  log "Ready to serve."
  log "PID: ${pid:-unknown}"
  log "Logs: tail -f $LOG_DIR/macprovider.out.log $LOG_DIR/macprovider.err.log"
  log "Coordinator pool check: $coordinator_base/v1/pool/check?provider_id=$(urlencode "$provider_id")"
  print_autotune_handoff
  log "Uninstall: bash <(curl -fsSL https://get.streamvc.live/uninstall.sh)"
}

main "$@"

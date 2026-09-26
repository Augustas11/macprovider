# shellcheck shell=sh
# L0 one-writer guard for the live coordinator config (#1693).
#
# Every script that writes the live /opt/macprovider/coordinator.yaml or
# /etc/macprovider/coordinator.pearl-overlays.yaml (or SIGHUPs the coordinator
# after such a write) must, for its whole read-modify-write + HUP:
#   1. hold the Pearl lock set in lease order: the updater lock
#      (/run/lock/macprovider-pearl-updater.lock) THEN the coordinator deploy
#      lock (<install_root>/.coordinator-deploy.lock) — ccg_take_lock_set; and
#   2. refuse while a pricing transaction journal (<install_root>/.pricing-txn)
#      exists — ccg_refuse_if_pricing_txn.
# The pricing lane (scripts/catalog-content-release.sh) holds the same lock set
# while its journal is live, and --recover-pricing-txn resolves an abandoned
# journal. Python writers use scripts/lib/coordinator_config_guard.py, which
# implements the same contract.
#
# POSIX sh, functions only, no top-level side effects: sourced by local bash
# scripts, and embedded verbatim into remote Pearl shells by
# ccg_remote_guard_script. Keep it free of single-quoted Python heredocs so it
# embeds inside the callers' double-quoted ssh command strings.
#
# Test overrides (the same variables coordinator-deploy-recover.sh honours):
#   MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE   updater lock path
#   MACPROVIDER_DEPLOY_LOCK_FILE          deploy lock path
#   MACPROVIDER_DEPLOY_LOCK_REQUIRED_UID  lock owner uid (default 0)
#   MACPROVIDER_DEPLOY_LOCK_REQUIRED_GID  lock owner gid (default 0)
#   MACPROVIDER_FLOCK                     flock(1) binary
#
# Exit codes:
#   75  refused: a pricing transaction journal exists (EX_TEMPFAIL).
#   76  --pre-start only: a journal exists; the caller has nothing of its own
#       to restore, so it treats 76 as "exit 0, no-op" (the pricing pre-start
#       recovery owns the journal). A pre-start caller that DOES have its own
#       state to restore treats 76 as a conflict and fails.

CCG_EX_REFUSED=75
CCG_EX_PRE_START_JOURNAL=76

# ccg_refuse_if_pricing_txn <install_root> [--pre-start]
#   0 when <install_root>/.pricing-txn is absent (as a path entry: a dangling
#   symlink counts as present); otherwise prints the refusal and returns 75, or
#   76 with --pre-start.
ccg_refuse_if_pricing_txn() {
  ccg_txn_root=${1:?ccg_refuse_if_pricing_txn: install root required}
  ccg_txn_mode=${2:-}
  case "$ccg_txn_mode" in
    ""|--pre-start) ;;
    *) printf 'ccg_refuse_if_pricing_txn: unknown flag %s\n' "$ccg_txn_mode" >&2; return 2 ;;
  esac
  ccg_txn_path="${ccg_txn_root%/}/.pricing-txn"
  if [ -e "$ccg_txn_path" ] || [ -L "$ccg_txn_path" ]; then
    printf 'refusing: pricing transaction journal present at %s; run scripts/catalog-content-release.sh --recover-pricing-txn\n' "$ccg_txn_path" >&2
    if [ "$ccg_txn_mode" = --pre-start ]; then
      return "$CCG_EX_PRE_START_JOURNAL"
    fi
    return "$CCG_EX_REFUSED"
  fi
  return 0
}

# ccg_take_lock_set <install_root> [wait_seconds]
#   Validates (creating when absent: root-owned 0600, one link, no symlink) and
#   takes the updater lock on fd 8, then the deploy lock on fd 9, in lease
#   order. wait_seconds 0 (default) = flock -n; otherwise flock -w. The locks
#   stay held until the calling shell exits (children inherit fds 8 and 9).
#   Returns 1 when a lock is busy or unsafe. Scripts that already hold the lock
#   set (deploy-pearl-vps.sh's lease, the content lane's lease runner) must not
#   call this: a second open file description would conflict with their own.
ccg_take_lock_set() {
  ccg_lock_root=${1:?ccg_take_lock_set: install root required}
  ccg_lock_wait=${2:-0}
  case "$ccg_lock_wait" in ""|*[!0-9]*) printf 'ccg_take_lock_set: wait must be whole seconds\n' >&2; return 2 ;; esac
  ccg_updater_lock=${MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE:-/run/lock/macprovider-pearl-updater.lock}
  ccg_deploy_lock=${MACPROVIDER_DEPLOY_LOCK_FILE:-${ccg_lock_root%/}/.coordinator-deploy.lock}
  ccg_flock=${MACPROVIDER_FLOCK:-flock}
  command -v "$ccg_flock" >/dev/null 2>&1 || { printf 'refusing: flock is unavailable\n' >&2; return 1; }
  python3 -I -c '
import os, stat, sys
uid, gid = int(sys.argv[1]), int(sys.argv[2])
nofollow = getattr(os, "O_NOFOLLOW", 0)
for path in sys.argv[3:]:
    try:
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL | nofollow, 0o600)
    except FileExistsError:
        fd = os.open(path, os.O_RDWR | nofollow)
    try:
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != uid
            or info.st_gid != gid
            or stat.S_IMODE(info.st_mode) != 0o600
            or info.st_nlink != 1
        ):
            raise SystemExit("refusing: unsafe coordinator config lock " + path)
    finally:
        os.close(fd)
' "${MACPROVIDER_DEPLOY_LOCK_REQUIRED_UID:-0}" "${MACPROVIDER_DEPLOY_LOCK_REQUIRED_GID:-0}" \
    "$ccg_updater_lock" "$ccg_deploy_lock" || return 1
  if [ "$ccg_lock_wait" = 0 ]; then ccg_flock_mode=-n; else ccg_flock_mode="-w $ccg_lock_wait"; fi
  exec 8<"$ccg_updater_lock" || return 1
  # shellcheck disable=SC2086
  $ccg_flock $ccg_flock_mode 8 || { printf 'refusing: Pearl updater lock held (%s)\n' "$ccg_updater_lock" >&2; exec 8<&-; return 1; }
  exec 9<"$ccg_deploy_lock" || { exec 8<&-; return 1; }
  # shellcheck disable=SC2086
  $ccg_flock $ccg_flock_mode 9 || { printf 'refusing: coordinator deploy lock held (%s)\n' "$ccg_deploy_lock" >&2; exec 9<&- 8<&-; return 1; }
  return 0
}

# ccg_sh_quote <value>: one single-quoted shell word.
ccg_sh_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# ccg_remote_guard_script <lib_path> <install_root> [wait_seconds]
#   Prints a remote shell prologue: `set -eu`, this library's function
#   definitions, then take the lock set and refuse while a journal exists. A
#   caller prepends it to the remote command that does its read-modify-write +
#   HUP so the whole command runs guarded; the remote shell exits 75 (journal)
#   or 1 (lock busy/unsafe) before any mutation.
ccg_remote_guard_script() {
  ccg_lib_path=${1:?ccg_remote_guard_script: library path required}
  ccg_remote_root=$(ccg_sh_quote "${2:?ccg_remote_guard_script: install root required}")
  ccg_remote_wait=${3:-0}
  case "$ccg_remote_wait" in ""|*[!0-9]*) printf 'ccg_remote_guard_script: wait must be whole seconds\n' >&2; return 2 ;; esac
  printf 'set -eu\n'
  cat "$ccg_lib_path" || return 1
  printf 'ccg_take_lock_set %s %s\n' "$ccg_remote_root" "$ccg_remote_wait"
  printf 'ccg_refuse_if_pricing_txn %s\n' "$ccg_remote_root"
}

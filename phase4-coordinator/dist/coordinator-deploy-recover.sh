#!/bin/sh
set -eu

ROOT=${MACPROVIDER_ROOT:-/opt/macprovider}
STATS_ROOT=${MACPROVIDER_STATS_ROOT:-/opt/macprovider-stats}
SYSTEMD_ROOT=${MACPROVIDER_SYSTEMD_ROOT:-/etc/systemd/system}
NGINX_ROOT=${MACPROVIDER_NGINX_ROOT:-/etc/nginx}
ETC_MACPROVIDER_ROOT=${MACPROVIDER_ETC_ROOT:-/etc/macprovider}
SYSTEMCTL=${MACPROVIDER_SYSTEMCTL:-systemctl}
FLOCK=${MACPROVIDER_FLOCK:-flock}
PYTHON=${MACPROVIDER_PYTHON:-python3}
SETFACL=${MACPROVIDER_SETFACL:-setfacl}
NGINX=${MACPROVIDER_NGINX:-nginx}
GLOBAL_LOCK_FILE=${MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE:-/run/lock/macprovider-pearl-updater.lock}
LOCK_FILE=${MACPROVIDER_DEPLOY_LOCK_FILE:-/opt/macprovider/.coordinator-deploy.lock}
OPERATION_LOCK_FILE=${MACPROVIDER_DEPLOY_OPERATION_LOCK_FILE:-/opt/macprovider/.coordinator-deploy-operation.lock}
LOCK_REQUIRED_UID=${MACPROVIDER_DEPLOY_LOCK_REQUIRED_UID:-0}
LOCK_REQUIRED_GID=${MACPROVIDER_DEPLOY_LOCK_REQUIRED_GID:-0}
ROLLBACK="$ROOT/.coordinator-deploy-rollback"
CATALOG_ROOT="$ROOT/autotune"
UNIT="$SYSTEMD_ROOT/macprovider-coordinator.service"
WANTS_LINK="$SYSTEMD_ROOT/multi-user.target.wants/macprovider-coordinator.service"
TIMERS_WANTS="$SYSTEMD_ROOT/timers.target.wants"
RECOVERY_HELPER="$ROOT/coordinator-deploy-recover"
RECOVERY_UNIT="$SYSTEMD_ROOT/macprovider-coordinator-deploy-recovery.service"
WATCHDOG_UNIT="$SYSTEMD_ROOT/macprovider-coordinator-deploy-watchdog.service"
GUARD_DROPIN="$SYSTEMD_ROOT/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf"
TIER2_CATALOG="$ROOT/tier2-catalog.json"
OVERLAY="$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml"
MODE=${1:---recover}

case "$MODE" in
  --recover|--recover-under-global|--pre-start) ;;
  *) echo "usage: $0 [--recover|--recover-under-global|--pre-start]" >&2; exit 2 ;;
esac

validate_global_lock() {
  "$PYTHON" - "$GLOBAL_LOCK_FILE" "$LOCK_REQUIRED_UID" "$LOCK_REQUIRED_GID" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
required_uid = int(sys.argv[2])
required_gid = int(sys.argv[3])
nofollow = getattr(os, "O_NOFOLLOW", 0)
try:
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | nofollow, 0o600)
except OSError as exc:
    raise SystemExit(f"cannot safely open global Pearl deployment lock: {exc}") from exc
try:
    info = os.fstat(descriptor)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != required_uid
        or info.st_gid != required_gid
        or stat.S_IMODE(info.st_mode) != 0o600
        or info.st_nlink != 1
    ):
        raise SystemExit("unsafe global Pearl deployment lock")
finally:
    os.close(descriptor)
PY
}

# An active deploy holds LOCK_FILE for its full lifetime. Its deliberate
# restart may consume the pending files. Any later boot/restart sees the lock
# free and restores the last committed release before ExecStart runs. Lock
# ordering is global Pearl mutation lock, deploy lease, operation barrier. This
# is the same order used by direct deploy and prevents abandoned recovery from
# racing the signed updater after the controller lease disappears.
validate_global_lock
if [ "$MODE" = "--pre-start" ]; then
  exec 7>"$GLOBAL_LOCK_FILE"
  if ! $FLOCK -n 7; then
    exit 0
  fi
  exec 9>"$LOCK_FILE"
  if ! $FLOCK -n 9; then
    exit 0
  fi
  exec 8>"$OPERATION_LOCK_FILE"
  $FLOCK 8
elif [ "$MODE" = "--recover" ]; then
  exec 7>"$GLOBAL_LOCK_FILE"
  $FLOCK 7
  exec 9>"$LOCK_FILE"
  $FLOCK 9
  exec 8>"$OPERATION_LOCK_FILE"
  $FLOCK 8
fi

[ -d "$ROLLBACK" ] || exit 0
[ ! -L "$ROLLBACK" ] || { echo "unsafe coordinator rollback symlink" >&2; exit 1; }
[ -f "$ROLLBACK/complete" ] || {
  echo "incomplete coordinator rollback snapshot; preserving it for manual recovery" >&2
  exit 1
}

if [ -f "$ROLLBACK/committed" ]; then
  rm -rf "$ROLLBACK"
  exit 0
fi

restore_regular() {
  marker=$1
  snapshot=$2
  destination=$3
  if [ -f "$ROLLBACK/$marker" ]; then
    [ -f "$ROLLBACK/$snapshot" ] || {
      echo "rollback snapshot missing $snapshot" >&2
      exit 1
    }
    rm -f "$destination"
    cp -p "$ROLLBACK/$snapshot" "$destination"
  else
    rm -f "$destination"
  fi
}

restore_link_or_file() {
  marker=$1
  snapshot=$2
  destination=$3
  rm -f "$destination"
  if [ -f "$ROLLBACK/$marker" ]; then
    [ -e "$ROLLBACK/$snapshot" ] || [ -L "$ROLLBACK/$snapshot" ] || {
      echo "rollback snapshot missing $snapshot" >&2
      exit 1
    }
    cp -a "$ROLLBACK/$snapshot" "$destination"
  fi
}

restore_acl() {
  marker=$1
  snapshot=$2
  if [ -f "$ROLLBACK/$marker" ]; then
    [ -f "$ROLLBACK/$snapshot" ] || {
      echo "rollback snapshot missing $snapshot" >&2
      exit 1
    }
    "$SETFACL" --restore="$ROLLBACK/$snapshot"
  fi
}

restore_active_state() {
  unit_name=$1
  active_marker=$2
  if [ -f "$ROLLBACK/$active_marker" ]; then
    "$SYSTEMCTL" start "$unit_name"
  else
    "$SYSTEMCTL" stop "$unit_name" 2>/dev/null || true
    if "$SYSTEMCTL" is-active --quiet "$unit_name"; then
      echo "$unit_name remained active after rollback stop" >&2
      exit 1
    fi
  fi
}

# Stop sidecar scheduling before replacing its units and executables. This
# prevents a timer firing against a half-restored release.
for rollback_unit in \
  stats-inventory-sync.timer stats-inventory-sync.service \
  stats-billing-mirror.timer stats-billing-mirror.service \
  stats-hardware-verifier.timer stats-hardware-verifier.service; do
  load_state=$("$SYSTEMCTL" show -p LoadState --value "$rollback_unit")
  [ "$load_state" = "not-found" ] && continue
  "$SYSTEMCTL" stop "$rollback_unit"
  active_state=$("$SYSTEMCTL" show -p ActiveState --value "$rollback_unit")
  case "$active_state" in
    inactive|failed) ;;
    *) echo "$rollback_unit did not stop before rollback: state=$active_state" >&2; exit 1 ;;
  esac
done

restore_regular had-coordinator coordinator "$ROOT/coordinator"
restore_regular had-coordinator-cli coordinator-cli "$ROOT/coordinator-cli"
restore_regular had-coordinator-prev coordinator.prev "$ROOT/coordinator.prev"
restore_regular had-config coordinator.yaml "$ROOT/coordinator.yaml"
restore_regular had-config-prev coordinator.yaml.prev "$ROOT/coordinator.yaml.prev"
config_backup_name=$(cat "$ROLLBACK/config-backup-name" 2>/dev/null || true)
case "$config_backup_name" in
  coordinator.yaml.bak-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z)
    restore_regular had-config-dated-backup coordinator-dated-backup "$ROOT/$config_backup_name"
    ;;
	  *) echo "invalid rollback config backup name: $config_backup_name" >&2; exit 1 ;;
esac
mkdir -p "$ETC_MACPROVIDER_ROOT"
restore_regular had-overlay coordinator.pearl-overlays.yaml "$OVERLAY"
restore_regular had-overlay-prev coordinator.pearl-overlays.yaml.prev "$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml.prev"
if [ -f "$ROLLBACK/overlay-config-backup-name" ]; then
  overlay_config_backup_name=$(cat "$ROLLBACK/overlay-config-backup-name" 2>/dev/null || true)
  case "$overlay_config_backup_name" in
    coordinator.pearl-overlays.yaml.bak-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z)
      restore_regular had-overlay-dated-backup coordinator-overlay-dated-backup "$ETC_MACPROVIDER_ROOT/$overlay_config_backup_name"
      ;;
    *) echo "invalid rollback overlay backup name: $overlay_config_backup_name" >&2; exit 1 ;;
  esac
fi
restore_regular had-tier2-catalog tier2-catalog.json "$TIER2_CATALOG"
restore_regular had-stats-inventory-binary stats-inventory-sync "$STATS_ROOT/stats-inventory-sync"
restore_regular had-stats-billing-binary stats-billing-mirror "$STATS_ROOT/stats-billing-mirror"
restore_regular had-stats-hardware-binary stats-hardware-verifier "$STATS_ROOT/stats-hardware-verifier"
restore_link_or_file had-service-unit macprovider-coordinator.service "$UNIT"
restore_link_or_file had-wants-link macprovider-coordinator.wants "$WANTS_LINK"

restore_link_or_file had-stats-inventory-service stats-inventory-sync.service "$SYSTEMD_ROOT/stats-inventory-sync.service"
restore_link_or_file had-stats-inventory-timer stats-inventory-sync.timer "$SYSTEMD_ROOT/stats-inventory-sync.timer"
restore_link_or_file had-stats-billing-service stats-billing-mirror.service "$SYSTEMD_ROOT/stats-billing-mirror.service"
restore_link_or_file had-stats-billing-timer stats-billing-mirror.timer "$SYSTEMD_ROOT/stats-billing-mirror.timer"
restore_link_or_file had-stats-hardware-service stats-hardware-verifier.service "$SYSTEMD_ROOT/stats-hardware-verifier.service"
restore_link_or_file had-stats-hardware-timer stats-hardware-verifier.timer "$SYSTEMD_ROOT/stats-hardware-verifier.timer"
restore_link_or_file had-stats-inventory-wants stats-inventory-sync.wants "$TIMERS_WANTS/stats-inventory-sync.timer"
restore_link_or_file had-stats-billing-wants stats-billing-mirror.wants "$TIMERS_WANTS/stats-billing-mirror.timer"
restore_link_or_file had-stats-hardware-wants stats-hardware-verifier.wants "$TIMERS_WANTS/stats-hardware-verifier.timer"

restore_link_or_file had-nginx-stats-shared stats-shared.conf "$NGINX_ROOT/conf.d/stats-shared.conf"
restore_link_or_file had-nginx-stats-security-headers stats-security-headers.conf "$NGINX_ROOT/conf.d/stats-security-headers.conf"
restore_link_or_file had-nginx-stats-cors-429 cors-429.conf "$NGINX_ROOT/conf.d/cors-429.conf"
restore_link_or_file had-nginx-stats-proxy-public stats-proxy-public.conf "$NGINX_ROOT/conf.d/stats-proxy-public.conf"
restore_link_or_file had-nginx-stats-proxy-partner stats-proxy-partner.conf "$NGINX_ROOT/conf.d/stats-proxy-partner.conf"
restore_link_or_file had-nginx-coordinator-site nginx-coordinator.site "$NGINX_ROOT/sites-available/coordinator.malibu.tech"
restore_link_or_file had-nginx-stats-site nginx-stats.site "$NGINX_ROOT/sites-available/stats.malibu.tech"
restore_link_or_file had-nginx-coordinator-enabled nginx-coordinator.enabled "$NGINX_ROOT/sites-enabled/coordinator.malibu.tech"
restore_link_or_file had-nginx-stats-enabled nginx-stats.enabled "$NGINX_ROOT/sites-enabled/stats.malibu.tech"
restore_link_or_file had-nginx-coordinator-full nginx-coordinator.full "$NGINX_ROOT/sites-available/coordinator.malibu.tech.full"

restore_acl had-request-log-dir-acl request-log-dir.acl
restore_acl had-request-log-db-acl request-log-db.acl
restore_acl had-request-log-wal-acl request-log-wal.acl
restore_acl had-request-log-shm-acl request-log-shm.acl

previous=$(cat "$ROLLBACK/catalog-current-target" 2>/dev/null || true)
case "$previous" in
  releases/*)
    mkdir -p "$CATALOG_ROOT"
    if [ -e "$CATALOG_ROOT/current" ] && [ ! -L "$CATALOG_ROOT/current" ]; then
      echo "unsafe non-symlink catalog current path" >&2
      exit 1
    fi
    ln -sfn "$previous" "$CATALOG_ROOT/current"
    ;;
  '') rm -f "$CATALOG_ROOT/current" ;;
  *) echo "invalid rollback catalog target: $previous" >&2; exit 1 ;;
esac

restore_regular had-previous-target catalog-previous-target "$CATALOG_ROOT/.previous-target"

if [ -f "$ROLLBACK/release-was-absent" ]; then
  release_id=$(cat "$ROLLBACK/release-id")
  case "$release_id" in
    ''|*[!A-Za-z0-9._-]*) echo "invalid rollback release ID" >&2; exit 1 ;;
  esac
  rm -rf "$CATALOG_ROOT/releases/$release_id"
fi

# Restore the guard definition before daemon-reload. The helper itself is
# restored last so this running process cannot lose its executable before all
# service and catalog recovery work succeeds.
restore_link_or_file had-recovery-unit macprovider-coordinator-deploy-recovery.service "$RECOVERY_UNIT"
restore_link_or_file had-watchdog-unit macprovider-coordinator-deploy-watchdog.service "$WATCHDOG_UNIT"
restore_link_or_file had-guard-dropin 10-deploy-transaction-guard.conf "$GUARD_DROPIN"

if [ "$MODE" = "--recover" ]; then
  $SYSTEMCTL daemon-reload
  # Issue #582 MIGRATION-019 ROLLBACK COUPLING: the stats-inventory-sync binary
  # restored above is the pre-019 build that reconciles with a 2-col
  # `ON CONFLICT (provider_id, hardware_identity_hash)`. If migration 019 (the
  # 3-col PRIMARY KEY on hardware_verification_trust) is still applied on the
  # database, that old binary fails reconciliation. The deploy quiesced AND
  # disabled the inventory sidecar BEFORE the migration, so its was-active marker
  # is intentionally unset and restore_active_state below leaves it stopped — the
  # old 2-col binary must never run against the migrated 3-col schema. Re-enable
  # stats-inventory-sync only after schema and binary are matched: either finish
  # rolling forward to the 3-col binary, OR run
  # 019_hardware_trust_operator_approval.down.sql to restore the 2-col PK first
  # and THEN re-enable the (now-matching) 2-col sidecar.
  if [ ! -f "$ROLLBACK/stats-inventory-timer-was-active" ]; then
    echo "note: stats-inventory-sync left stopped after rollback; verify migration-019 PK vs sidecar-binary parity before re-enabling (see 019_hardware_trust_operator_approval.down.sql)" >&2
  fi
  restore_active_state stats-inventory-sync.timer stats-inventory-timer-was-active
  restore_active_state stats-inventory-sync.service stats-inventory-service-was-active
  restore_active_state stats-billing-mirror.timer stats-billing-timer-was-active
  restore_active_state stats-billing-mirror.service stats-billing-service-was-active
  restore_active_state stats-hardware-verifier.timer stats-hardware-timer-was-active
  restore_active_state stats-hardware-verifier.service stats-hardware-service-was-active
  if [ -f "$ROLLBACK/restart-attempted" ]; then
    if [ -f "$ROLLBACK/service-was-active" ]; then
      $SYSTEMCTL restart macprovider-coordinator
    else
      $SYSTEMCTL stop macprovider-coordinator
      if $SYSTEMCTL is-active --quiet macprovider-coordinator; then
        echo "coordinator remained active after rollback stop" >&2
        exit 1
      fi
    fi
  fi
else
  # This runs in a separate root oneshot ordered before the coordinator, so
  # reloading here makes the restored unit definition effective for the start
  # that follows without recursively restarting the service.
  $SYSTEMCTL daemon-reload
fi

# The nginx files are part of the same release transaction. Validate the
# restored graph before making it live; preserve the snapshot if validation or
# reload fails so an operator can recover manually.
"$NGINX" -t
"$SYSTEMCTL" try-reload-or-restart nginx

restore_link_or_file had-recovery-helper coordinator-deploy-recover "$RECOVERY_HELPER"
rm -rf "$ROLLBACK"

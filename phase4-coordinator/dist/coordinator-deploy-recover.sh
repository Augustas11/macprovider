#!/bin/sh
set -eu

ROOT=${MACPROVIDER_ROOT:-/opt/macprovider}
SYSTEMD_ROOT=${MACPROVIDER_SYSTEMD_ROOT:-/etc/systemd/system}
SYSTEMCTL=${MACPROVIDER_SYSTEMCTL:-systemctl}
FLOCK=${MACPROVIDER_FLOCK:-flock}
LOCK_FILE=${MACPROVIDER_DEPLOY_LOCK_FILE:-/opt/macprovider/.coordinator-deploy.lock}
OPERATION_LOCK_FILE=${MACPROVIDER_DEPLOY_OPERATION_LOCK_FILE:-/opt/macprovider/.coordinator-deploy-operation.lock}
ROLLBACK="$ROOT/.coordinator-deploy-rollback"
CATALOG_ROOT="$ROOT/autotune"
UNIT="$SYSTEMD_ROOT/macprovider-coordinator.service"
WANTS_LINK="$SYSTEMD_ROOT/multi-user.target.wants/macprovider-coordinator.service"
RECOVERY_HELPER="$ROOT/coordinator-deploy-recover"
RECOVERY_UNIT="$SYSTEMD_ROOT/macprovider-coordinator-deploy-recovery.service"
WATCHDOG_UNIT="$SYSTEMD_ROOT/macprovider-coordinator-deploy-watchdog.service"
GUARD_DROPIN="$SYSTEMD_ROOT/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf"
TIER2_CATALOG="$ROOT/tier2-catalog.json"
MODE=${1:---recover}

case "$MODE" in
  --recover|--pre-start) ;;
  *) echo "usage: $0 [--recover|--pre-start]" >&2; exit 2 ;;
esac

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

# An active deploy holds LOCK_FILE for its full lifetime. Its deliberate
# restart may consume the pending files. Any later boot/restart sees the lock
# free and restores the last committed release before ExecStart runs.
if [ "$MODE" = "--pre-start" ]; then
  exec 9>"$LOCK_FILE"
  if ! $FLOCK -n 9; then
    exit 0
  fi
  exec 8>"$OPERATION_LOCK_FILE"
  $FLOCK 8
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

restore_regular had-coordinator coordinator "$ROOT/coordinator"
restore_regular had-config coordinator.yaml "$ROOT/coordinator.yaml"
restore_regular had-tier2-catalog tier2-catalog.json "$TIER2_CATALOG"
restore_link_or_file had-service-unit macprovider-coordinator.service "$UNIT"
restore_link_or_file had-wants-link macprovider-coordinator.wants "$WANTS_LINK"

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

restore_link_or_file had-recovery-helper coordinator-deploy-recover "$RECOVERY_HELPER"
rm -rf "$ROLLBACK"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RECOVER="$SCRIPT_DIR/../coordinator-deploy-recover.sh"
TMP="$(umask 077 && mktemp -d -t coordinator-recovery-test.XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ROOT="$TMP/opt/macprovider"
SYSTEMD="$TMP/etc/systemd/system"
ROLLBACK="$ROOT/.coordinator-deploy-rollback"
SYSTEMCTL_LOG="$TMP/systemctl.log"
mkdir -p "$ROOT/autotune/releases/new" "$SYSTEMD/multi-user.target.wants" "$TMP/bin"

cat >"$TMP/bin/systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$MACPROVIDER_SYSTEMCTL_LOG"
case "$1" in
  stop)
    if [ "${MACPROVIDER_SYSTEMCTL_FAIL_STOP:-0}" = "1" ]; then
      exit 1
    fi
    ;;
  is-active) exit 1 ;;
esac
SH
cat >"$TMP/bin/flock-free" <<'SH'
#!/bin/sh
exit 0
SH
cat >"$TMP/bin/flock-busy" <<'SH'
#!/bin/sh
exit 1
SH
cat >"$TMP/bin/flock-operation-blocked" <<'SH'
#!/bin/sh
if [ "${1:-}" = "-n" ]; then
  exit 0
fi
while [ -f "$MACPROVIDER_OPERATION_BLOCK_SENTINEL" ]; do
  sleep 0.05
done
SH
chmod +x "$TMP/bin/systemctl" "$TMP/bin/flock-free" "$TMP/bin/flock-busy" "$TMP/bin/flock-operation-blocked"

run_recover() {
  MACPROVIDER_ROOT="$ROOT" \
  MACPROVIDER_SYSTEMD_ROOT="$SYSTEMD" \
  MACPROVIDER_SYSTEMCTL="$TMP/bin/systemctl" \
  MACPROVIDER_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  MACPROVIDER_SYSTEMCTL_FAIL_STOP="${MACPROVIDER_SYSTEMCTL_FAIL_STOP:-0}" \
  MACPROVIDER_FLOCK="${MACPROVIDER_FLOCK_OVERRIDE:-$TMP/bin/flock-free}" \
  MACPROVIDER_OPERATION_BLOCK_SENTINEL="${MACPROVIDER_OPERATION_BLOCK_SENTINEL:-}" \
  MACPROVIDER_DEPLOY_LOCK_FILE="$TMP/deploy.lock" \
  MACPROVIDER_DEPLOY_OPERATION_LOCK_FILE="$TMP/deploy-operation.lock" \
    "$RECOVER" "${1:---recover}"
}

seed_transaction() {
  rm -rf "$ROLLBACK" "$ROOT/autotune/releases/new"
  rm -f "$SYSTEMD/macprovider-coordinator.service" \
    "$SYSTEMD/macprovider-coordinator-deploy-watchdog.service" \
    "$SYSTEMD/multi-user.target.wants/macprovider-coordinator.service" \
    "$ROOT/autotune/current" "$ROOT/autotune/.previous-target" \
    "$ROOT/tier2-catalog.json"
  mkdir -p "$ROLLBACK" "$ROOT/autotune/releases/new"
  printf old-binary >"$ROLLBACK/coordinator"
  printf old-config >"$ROLLBACK/coordinator.yaml"
  printf old-tier2-catalog >"$ROLLBACK/tier2-catalog.json"
  touch "$ROLLBACK/had-coordinator" "$ROLLBACK/had-config" "$ROLLBACK/had-tier2-catalog"
  ln -s /dev/null "$ROLLBACK/macprovider-coordinator.service"
  touch "$ROLLBACK/had-service-unit"
  ln -s ../macprovider-coordinator.service "$ROLLBACK/macprovider-coordinator.wants"
  touch "$ROLLBACK/had-wants-link"
  printf old-watchdog-unit >"$ROLLBACK/macprovider-coordinator-deploy-watchdog.service"
  touch "$ROLLBACK/had-watchdog-unit"
  printf releases/old >"$ROLLBACK/catalog-current-target"
  printf releases/older >"$ROLLBACK/catalog-previous-target"
  touch "$ROLLBACK/had-previous-target" "$ROLLBACK/release-was-absent"
  printf new >"$ROLLBACK/release-id"
  touch "$ROLLBACK/restart-attempted" "$ROLLBACK/service-was-active"
  touch "$ROLLBACK/complete"

  printf new-binary >"$ROOT/coordinator"
  printf new-config >"$ROOT/coordinator.yaml"
  printf new-tier2-catalog >"$ROOT/tier2-catalog.json"
  printf new-unit >"$SYSTEMD/macprovider-coordinator.service"
  printf new-watchdog-unit >"$SYSTEMD/macprovider-coordinator-deploy-watchdog.service"
  ln -s ../wrong.service "$SYSTEMD/multi-user.target.wants/macprovider-coordinator.service"
  ln -sfn releases/new "$ROOT/autotune/current"
  printf releases/new >"$ROOT/autotune/.previous-target"
  : >"$SYSTEMCTL_LOG"
}

seed_transaction
run_recover
[ "$(cat "$ROOT/coordinator")" = old-binary ] || fail "binary was not restored"
[ "$(cat "$ROOT/coordinator.yaml")" = old-config ] || fail "config was not restored"
[ "$(cat "$ROOT/tier2-catalog.json")" = old-tier2-catalog ] || fail "Tier-2 catalog was not restored"
[ "$(readlink "$SYSTEMD/macprovider-coordinator.service")" = /dev/null ] || fail "masked unit was not restored"
[ "$(readlink "$SYSTEMD/multi-user.target.wants/macprovider-coordinator.service")" = ../macprovider-coordinator.service ] || fail "enablement link was not restored"
[ "$(cat "$SYSTEMD/macprovider-coordinator-deploy-watchdog.service")" = old-watchdog-unit ] || fail "deploy watchdog unit was not restored"
[ "$(readlink "$ROOT/autotune/current")" = releases/old ] || fail "catalog current was not restored"
[ "$(cat "$ROOT/autotune/.previous-target")" = releases/older ] || fail "catalog previous target was not restored"
[ ! -d "$ROOT/autotune/releases/new" ] || fail "new release was not removed"
[ ! -e "$ROLLBACK" ] || fail "successful recovery did not remove its snapshot"
grep -qx 'daemon-reload' "$SYSTEMCTL_LOG" || fail "recovery did not reload systemd"
grep -qx 'restart macprovider-coordinator' "$SYSTEMCTL_LOG" || fail "recovery did not restore active service state"

seed_transaction
rm -f "$ROLLBACK/macprovider-coordinator.wants" "$ROLLBACK/had-wants-link"
run_recover
[ ! -e "$SYSTEMD/multi-user.target.wants/macprovider-coordinator.service" ] &&
  [ ! -L "$SYSTEMD/multi-user.target.wants/macprovider-coordinator.service" ] ||
  fail "disabled service state was not restored"

seed_transaction
rm -f "$ROLLBACK/tier2-catalog.json" "$ROLLBACK/had-tier2-catalog"
run_recover
[ ! -e "$ROOT/tier2-catalog.json" ] || fail "previously absent Tier-2 catalog was not removed"

seed_transaction
rm -f "$ROLLBACK/coordinator"
if run_recover >/dev/null 2>&1; then
  fail "incomplete rollback snapshot was accepted"
fi
[ -d "$ROLLBACK" ] || fail "failed rollback did not preserve its snapshot"

seed_transaction
rm -f "$ROLLBACK/complete"
if run_recover >/dev/null 2>&1; then
  fail "incomplete rollback publication was accepted"
fi
[ -d "$ROLLBACK" ] || fail "incomplete rollback publication was not preserved"

seed_transaction
rm -f "$ROLLBACK/service-was-active"
if MACPROVIDER_SYSTEMCTL_FAIL_STOP=1 run_recover >/dev/null 2>&1; then
  fail "failed service stop was accepted"
fi
[ -d "$ROLLBACK" ] || fail "failed service stop did not preserve its snapshot"

seed_transaction
touch "$ROLLBACK/committed"
run_recover
[ "$(cat "$ROOT/coordinator")" = new-binary ] || fail "committed cleanup rolled back live files"
[ ! -e "$ROLLBACK" ] || fail "committed cleanup did not remove its snapshot"
[ ! -s "$SYSTEMCTL_LOG" ] || fail "committed cleanup changed service state"

seed_transaction
MACPROVIDER_ROOT="$ROOT" \
MACPROVIDER_SYSTEMD_ROOT="$SYSTEMD" \
MACPROVIDER_SYSTEMCTL="$TMP/bin/systemctl" \
MACPROVIDER_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
MACPROVIDER_FLOCK="$TMP/bin/flock-busy" \
MACPROVIDER_DEPLOY_LOCK_FILE="$TMP/deploy.lock" \
MACPROVIDER_DEPLOY_OPERATION_LOCK_FILE="$TMP/deploy-operation.lock" \
  "$RECOVER" --pre-start
[ "$(cat "$ROOT/coordinator")" = new-binary ] || fail "active deploy pre-start was rolled back"
[ -d "$ROLLBACK" ] || fail "active deploy snapshot was consumed"

run_recover --pre-start
[ "$(cat "$ROOT/coordinator")" = old-binary ] || fail "orphaned pre-start transaction was not restored"
[ ! -e "$ROLLBACK" ] || fail "orphaned pre-start snapshot was not removed"
grep -qx 'daemon-reload' "$SYSTEMCTL_LOG" || fail "pre-start recovery did not reload the restored unit"
! grep -Eq '^(restart|stop) ' "$SYSTEMCTL_LOG" || fail "pre-start recovery recursively changed service state"

seed_transaction
OPERATION_BLOCK_SENTINEL="$TMP/operation-blocked"
touch "$OPERATION_BLOCK_SENTINEL"
MACPROVIDER_FLOCK_OVERRIDE="$TMP/bin/flock-operation-blocked" \
MACPROVIDER_OPERATION_BLOCK_SENTINEL="$OPERATION_BLOCK_SENTINEL" \
  run_recover --pre-start &
blocked_recover_pid=$!
sleep 0.15
kill -0 "$blocked_recover_pid" 2>/dev/null || fail "pre-start recovery did not wait for the operation barrier"
[ "$(cat "$ROOT/coordinator")" = new-binary ] || fail "pre-start recovery mutated files before the operation barrier cleared"
rm -f "$OPERATION_BLOCK_SENTINEL"
wait "$blocked_recover_pid"
[ "$(cat "$ROOT/coordinator")" = old-binary ] || fail "pre-start recovery did not run after the operation barrier cleared"

echo "PASS: coordinator deploy recovery is durable and state-exact"

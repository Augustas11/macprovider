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
STATS_ROOT="$TMP/opt/macprovider-stats"
SYSTEMD="$TMP/etc/systemd/system"
NGINX_ROOT="$TMP/etc/nginx"
ETC_MACPROVIDER_ROOT="$TMP/etc/macprovider"
ROLLBACK="$ROOT/.coordinator-deploy-rollback"
SYSTEMCTL_LOG="$TMP/systemctl.log"
SETFACL_LOG="$TMP/setfacl.log"
mkdir -p "$ROOT/autotune/releases/new" "$STATS_ROOT" \
  "$SYSTEMD/multi-user.target.wants" "$SYSTEMD/timers.target.wants" \
  "$NGINX_ROOT/conf.d" "$NGINX_ROOT/sites-available" "$NGINX_ROOT/sites-enabled" \
  "$ETC_MACPROVIDER_ROOT" "$TMP/bin"

cat >"$TMP/bin/systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$MACPROVIDER_SYSTEMCTL_LOG"
case "$1" in
  show)
    case "$2" in
      -p)
        case "$3" in
          LoadState) printf '%s\n' loaded ;;
          ActiveState) printf '%s\n' inactive ;;
          *) exit 1 ;;
        esac
        ;;
      *) exit 1 ;;
    esac
    ;;
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
cat >"$TMP/bin/setfacl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$MACPROVIDER_SETFACL_LOG"
SH
cat >"$TMP/bin/nginx" <<'SH'
#!/bin/sh
[ "${1:-}" = -t ]
[ "${MACPROVIDER_NGINX_FAIL:-0}" != 1 ]
SH
chmod +x "$TMP/bin/systemctl" "$TMP/bin/flock-free" "$TMP/bin/flock-busy" \
  "$TMP/bin/flock-operation-blocked" "$TMP/bin/setfacl" "$TMP/bin/nginx"

run_recover() {
  MACPROVIDER_ROOT="$ROOT" \
  MACPROVIDER_STATS_ROOT="$STATS_ROOT" \
	  MACPROVIDER_SYSTEMD_ROOT="$SYSTEMD" \
	  MACPROVIDER_NGINX_ROOT="$NGINX_ROOT" \
	  MACPROVIDER_ETC_ROOT="$ETC_MACPROVIDER_ROOT" \
	  MACPROVIDER_SYSTEMCTL="$TMP/bin/systemctl" \
  MACPROVIDER_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  MACPROVIDER_SYSTEMCTL_FAIL_STOP="${MACPROVIDER_SYSTEMCTL_FAIL_STOP:-0}" \
  MACPROVIDER_FLOCK="${MACPROVIDER_FLOCK_OVERRIDE:-$TMP/bin/flock-free}" \
  MACPROVIDER_SETFACL="$TMP/bin/setfacl" \
  MACPROVIDER_SETFACL_LOG="$SETFACL_LOG" \
  MACPROVIDER_NGINX="$TMP/bin/nginx" \
  MACPROVIDER_NGINX_FAIL="${MACPROVIDER_NGINX_FAIL:-0}" \
  MACPROVIDER_OPERATION_BLOCK_SENTINEL="${MACPROVIDER_OPERATION_BLOCK_SENTINEL:-}" \
  MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE="$TMP/global-deploy.lock" \
  MACPROVIDER_DEPLOY_LOCK_FILE="$TMP/deploy.lock" \
  MACPROVIDER_DEPLOY_OPERATION_LOCK_FILE="$TMP/deploy-operation.lock" \
  MACPROVIDER_DEPLOY_LOCK_REQUIRED_UID="$(id -u)" \
  MACPROVIDER_DEPLOY_LOCK_REQUIRED_GID="$(id -g)" \
    "$RECOVER" "${1:---recover}"
}

seed_transaction() {
  rm -rf "$ROLLBACK" "$ROOT/autotune/releases/new"
  rm -f "$SYSTEMD/macprovider-coordinator.service" \
    "$SYSTEMD/macprovider-coordinator-deploy-watchdog.service" \
    "$SYSTEMD/multi-user.target.wants/macprovider-coordinator.service" \
    "$ROOT/autotune/current" "$ROOT/autotune/.previous-target" \
	    "$ROOT/tier2-catalog.json" "$ROOT/coordinator-cli" "$ROOT/coordinator.prev" \
	    "$ROOT/coordinator.yaml.prev" "$ROOT/coordinator.yaml.bak-20260711T120000Z" \
	    "$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml" \
	    "$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml.prev" \
	    "$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml.bak-20260711T120000Z" \
    "$STATS_ROOT/stats-inventory-sync" "$STATS_ROOT/stats-billing-mirror" "$STATS_ROOT/stats-hardware-verifier" \
    "$SYSTEMD/stats-inventory-sync.service" "$SYSTEMD/stats-inventory-sync.timer" \
    "$SYSTEMD/stats-billing-mirror.service" "$SYSTEMD/stats-billing-mirror.timer" \
    "$SYSTEMD/stats-hardware-verifier.service" "$SYSTEMD/stats-hardware-verifier.timer" \
    "$SYSTEMD/timers.target.wants/stats-inventory-sync.timer" \
    "$SYSTEMD/timers.target.wants/stats-billing-mirror.timer" \
    "$SYSTEMD/timers.target.wants/stats-hardware-verifier.timer" \
    "$NGINX_ROOT/conf.d/stats-shared.conf" "$NGINX_ROOT/conf.d/stats-security-headers.conf" \
    "$NGINX_ROOT/conf.d/cors-429.conf" "$NGINX_ROOT/conf.d/stats-proxy-public.conf" \
    "$NGINX_ROOT/conf.d/stats-proxy-partner.conf" "$NGINX_ROOT/sites-available/coordinator.streamvc.live" \
    "$NGINX_ROOT/sites-available/stats.streamvc.live" "$NGINX_ROOT/sites-enabled/coordinator.streamvc.live" \
    "$NGINX_ROOT/sites-enabled/stats.streamvc.live" "$NGINX_ROOT/sites-available/coordinator.streamvc.live.full"
  mkdir -p "$ROLLBACK" "$ROOT/autotune/releases/new"
  printf old-binary >"$ROLLBACK/coordinator"
  printf old-config >"$ROLLBACK/coordinator.yaml"
  printf old-tier2-catalog >"$ROLLBACK/tier2-catalog.json"
  touch "$ROLLBACK/had-coordinator" "$ROLLBACK/had-config" "$ROLLBACK/had-tier2-catalog"
  printf old-cli >"$ROLLBACK/coordinator-cli"
  touch "$ROLLBACK/had-coordinator-cli"
  printf old-coordinator-prev >"$ROLLBACK/coordinator.prev"
	  printf old-config-prev >"$ROLLBACK/coordinator.yaml.prev"
	  printf old-dated-backup >"$ROLLBACK/coordinator-dated-backup"
	  printf coordinator.yaml.bak-20260711T120000Z >"$ROLLBACK/config-backup-name"
	  touch "$ROLLBACK/had-coordinator-prev" "$ROLLBACK/had-config-prev" "$ROLLBACK/had-config-dated-backup"
	  printf old-overlay >"$ROLLBACK/coordinator.pearl-overlays.yaml"
	  printf old-overlay-prev >"$ROLLBACK/coordinator.pearl-overlays.yaml.prev"
	  printf old-overlay-dated-backup >"$ROLLBACK/coordinator-overlay-dated-backup"
	  printf coordinator.pearl-overlays.yaml.bak-20260711T120000Z >"$ROLLBACK/overlay-config-backup-name"
	  touch "$ROLLBACK/had-overlay" "$ROLLBACK/had-overlay-prev" "$ROLLBACK/had-overlay-dated-backup"
  for artifact in stats-inventory-sync stats-billing-mirror stats-hardware-verifier; do
    printf 'old-%s' "$artifact" >"$ROLLBACK/$artifact"
  done
  touch "$ROLLBACK/had-stats-inventory-binary" "$ROLLBACK/had-stats-billing-binary" "$ROLLBACK/had-stats-hardware-binary"
  ln -s /dev/null "$ROLLBACK/macprovider-coordinator.service"
  touch "$ROLLBACK/had-service-unit"
  ln -s ../macprovider-coordinator.service "$ROLLBACK/macprovider-coordinator.wants"
  touch "$ROLLBACK/had-wants-link"
  printf old-watchdog-unit >"$ROLLBACK/macprovider-coordinator-deploy-watchdog.service"
  touch "$ROLLBACK/had-watchdog-unit"
  for unit in stats-inventory-sync.service stats-inventory-sync.timer \
    stats-billing-mirror.service stats-billing-mirror.timer \
    stats-hardware-verifier.service stats-hardware-verifier.timer; do
    printf 'old-%s' "$unit" >"$ROLLBACK/$unit"
  done
  touch "$ROLLBACK/had-stats-inventory-service" "$ROLLBACK/had-stats-inventory-timer" \
    "$ROLLBACK/had-stats-billing-service" "$ROLLBACK/had-stats-billing-timer" \
    "$ROLLBACK/had-stats-hardware-service" "$ROLLBACK/had-stats-hardware-timer"
  ln -s ../stats-inventory-sync.timer "$ROLLBACK/stats-inventory-sync.wants"
  touch "$ROLLBACK/had-stats-inventory-wants"
  touch "$ROLLBACK/stats-inventory-timer-was-active" "$ROLLBACK/stats-billing-service-was-active"
  for nginx_file in stats-shared.conf stats-security-headers.conf cors-429.conf stats-proxy-public.conf stats-proxy-partner.conf; do
    printf 'old-%s' "$nginx_file" >"$ROLLBACK/$nginx_file"
  done
  printf old-coordinator-site >"$ROLLBACK/nginx-coordinator.site"
  printf old-stats-site >"$ROLLBACK/nginx-stats.site"
  ln -s ../sites-available/coordinator.streamvc.live "$ROLLBACK/nginx-coordinator.enabled"
  touch "$ROLLBACK/had-nginx-stats-shared" "$ROLLBACK/had-nginx-stats-security-headers" \
    "$ROLLBACK/had-nginx-stats-cors-429" "$ROLLBACK/had-nginx-stats-proxy-public" \
    "$ROLLBACK/had-nginx-stats-proxy-partner" "$ROLLBACK/had-nginx-coordinator-site" \
    "$ROLLBACK/had-nginx-stats-site" "$ROLLBACK/had-nginx-coordinator-enabled"
  printf '# acl fixture\n' >"$ROLLBACK/request-log-db.acl"
  touch "$ROLLBACK/had-request-log-db-acl"
  printf releases/old >"$ROLLBACK/catalog-current-target"
  printf releases/older >"$ROLLBACK/catalog-previous-target"
  touch "$ROLLBACK/had-previous-target" "$ROLLBACK/release-was-absent"
  printf new >"$ROLLBACK/release-id"
  touch "$ROLLBACK/restart-attempted" "$ROLLBACK/service-was-active"
  touch "$ROLLBACK/complete"

  printf new-binary >"$ROOT/coordinator"
  printf new-cli >"$ROOT/coordinator-cli"
  printf new-coordinator-prev >"$ROOT/coordinator.prev"
	  printf new-config-prev >"$ROOT/coordinator.yaml.prev"
	  printf new-dated-backup >"$ROOT/coordinator.yaml.bak-20260711T120000Z"
	  printf new-config >"$ROOT/coordinator.yaml"
	  printf new-overlay >"$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml"
	  printf new-overlay-prev >"$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml.prev"
	  printf new-overlay-dated-backup >"$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml.bak-20260711T120000Z"
	  printf new-tier2-catalog >"$ROOT/tier2-catalog.json"
  printf new-unit >"$SYSTEMD/macprovider-coordinator.service"
  printf new-watchdog-unit >"$SYSTEMD/macprovider-coordinator-deploy-watchdog.service"
  for artifact in stats-inventory-sync stats-billing-mirror stats-hardware-verifier; do
    printf 'new-%s' "$artifact" >"$STATS_ROOT/$artifact"
  done
  for unit in stats-inventory-sync.service stats-inventory-sync.timer \
    stats-billing-mirror.service stats-billing-mirror.timer \
    stats-hardware-verifier.service stats-hardware-verifier.timer; do
    printf 'new-%s' "$unit" >"$SYSTEMD/$unit"
  done
  ln -s ../stats-inventory-sync.timer "$SYSTEMD/timers.target.wants/stats-inventory-sync.timer"
  ln -s ../stats-billing-mirror.timer "$SYSTEMD/timers.target.wants/stats-billing-mirror.timer"
  for nginx_file in stats-shared.conf stats-security-headers.conf cors-429.conf stats-proxy-public.conf stats-proxy-partner.conf; do
    printf 'new-%s' "$nginx_file" >"$NGINX_ROOT/conf.d/$nginx_file"
  done
  printf new-coordinator-site >"$NGINX_ROOT/sites-available/coordinator.streamvc.live"
  printf new-stats-site >"$NGINX_ROOT/sites-available/stats.streamvc.live"
  ln -s ../sites-available/stats.streamvc.live "$NGINX_ROOT/sites-enabled/stats.streamvc.live"
  ln -s ../wrong.service "$SYSTEMD/multi-user.target.wants/macprovider-coordinator.service"
  ln -sfn releases/new "$ROOT/autotune/current"
  printf releases/new >"$ROOT/autotune/.previous-target"
  : >"$SYSTEMCTL_LOG"
  : >"$SETFACL_LOG"
}

seed_transaction
run_recover
[ "$(cat "$ROOT/coordinator")" = old-binary ] || fail "binary was not restored"
[ "$(cat "$ROOT/coordinator.yaml")" = old-config ] || fail "config was not restored"
[ "$(cat "$ROOT/tier2-catalog.json")" = old-tier2-catalog ] || fail "Tier-2 catalog was not restored"
[ "$(cat "$ROOT/coordinator-cli")" = old-cli ] || fail "coordinator CLI was not restored"
[ "$(cat "$ROOT/coordinator.prev")" = old-coordinator-prev ] || fail "coordinator convenience backup was not restored"
[ "$(cat "$ROOT/coordinator.yaml.prev")" = old-config-prev ] || fail "config convenience backup was not restored"
[ "$(cat "$ROOT/coordinator.yaml.bak-20260711T120000Z")" = old-dated-backup ] || fail "dated config backup collision was not restored"
[ "$(cat "$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml")" = old-overlay ] || fail "overlay was not restored"
[ "$(cat "$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml.prev")" = old-overlay-prev ] || fail "overlay convenience backup was not restored"
[ "$(cat "$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml.bak-20260711T120000Z")" = old-overlay-dated-backup ] || fail "dated overlay backup collision was not restored"
[ "$(cat "$STATS_ROOT/stats-inventory-sync")" = old-stats-inventory-sync ] || fail "stats inventory binary was not restored"
[ "$(cat "$STATS_ROOT/stats-billing-mirror")" = old-stats-billing-mirror ] || fail "stats billing binary was not restored"
[ "$(cat "$STATS_ROOT/stats-hardware-verifier")" = old-stats-hardware-verifier ] || fail "stats hardware binary was not restored"
[ "$(readlink "$SYSTEMD/macprovider-coordinator.service")" = /dev/null ] || fail "masked unit was not restored"
[ "$(readlink "$SYSTEMD/multi-user.target.wants/macprovider-coordinator.service")" = ../macprovider-coordinator.service ] || fail "enablement link was not restored"
[ "$(cat "$SYSTEMD/macprovider-coordinator-deploy-watchdog.service")" = old-watchdog-unit ] || fail "deploy watchdog unit was not restored"
[ "$(cat "$SYSTEMD/stats-inventory-sync.timer")" = old-stats-inventory-sync.timer ] || fail "stats timer unit was not restored"
[ -L "$SYSTEMD/timers.target.wants/stats-inventory-sync.timer" ] || fail "prior stats timer enablement was not restored"
[ ! -e "$SYSTEMD/timers.target.wants/stats-billing-mirror.timer" ] || fail "new stats timer enablement was not removed"
[ "$(cat "$NGINX_ROOT/conf.d/stats-shared.conf")" = old-stats-shared.conf ] || fail "nginx snippet was not restored"
[ "$(cat "$NGINX_ROOT/sites-available/coordinator.streamvc.live")" = old-coordinator-site ] || fail "coordinator nginx site was not restored"
[ ! -e "$NGINX_ROOT/sites-enabled/stats.streamvc.live" ] || fail "new stats nginx enablement was not removed"
grep -qx -- "--restore=$ROLLBACK/request-log-db.acl" "$SETFACL_LOG" || fail "request-log ACL was not restored"
[ "$(readlink "$ROOT/autotune/current")" = releases/old ] || fail "catalog current was not restored"
[ "$(cat "$ROOT/tier2-catalog.json")" = old-tier2-catalog ] &&
  [ "$(readlink "$ROOT/autotune/current")" = releases/old ] ||
  fail "legacy Tier-2 bridge and current pointer were not restored together"
[ "$(cat "$ROOT/autotune/.previous-target")" = releases/older ] || fail "catalog previous target was not restored"
[ ! -d "$ROOT/autotune/releases/new" ] || fail "new release was not removed"
[ ! -e "$ROLLBACK" ] || fail "successful recovery did not remove its snapshot"
grep -qx 'daemon-reload' "$SYSTEMCTL_LOG" || fail "recovery did not reload systemd"
grep -qx 'restart macprovider-coordinator' "$SYSTEMCTL_LOG" || fail "recovery did not restore active service state"
grep -qx 'start stats-inventory-sync.timer' "$SYSTEMCTL_LOG" || fail "active stats timer state was not restored"
grep -qx 'start stats-billing-mirror.service' "$SYSTEMCTL_LOG" || fail "active stats service state was not restored"
grep -qx 'try-reload-or-restart nginx' "$SYSTEMCTL_LOG" || fail "restored nginx graph was not reloaded"

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
[ "$(readlink "$ROOT/autotune/current")" = releases/old ] || fail "current pointer was not restored when legacy Tier-2 was absent"

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
if MACPROVIDER_NGINX_FAIL=1 run_recover >/dev/null 2>&1; then
  fail "invalid restored nginx graph was accepted"
fi
[ -d "$ROLLBACK" ] || fail "nginx validation failure did not preserve its snapshot"

seed_transaction
touch "$ROLLBACK/committed"
run_recover
[ "$(cat "$ROOT/coordinator")" = new-binary ] || fail "committed cleanup rolled back live files"
[ ! -e "$ROLLBACK" ] || fail "committed cleanup did not remove its snapshot"
[ ! -s "$SYSTEMCTL_LOG" ] || fail "committed cleanup changed service state"

seed_transaction
MACPROVIDER_ROOT="$ROOT" \
MACPROVIDER_STATS_ROOT="$STATS_ROOT" \
MACPROVIDER_SYSTEMD_ROOT="$SYSTEMD" \
MACPROVIDER_NGINX_ROOT="$NGINX_ROOT" \
MACPROVIDER_SYSTEMCTL="$TMP/bin/systemctl" \
MACPROVIDER_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
MACPROVIDER_FLOCK="$TMP/bin/flock-busy" \
MACPROVIDER_SETFACL="$TMP/bin/setfacl" \
MACPROVIDER_SETFACL_LOG="$SETFACL_LOG" \
MACPROVIDER_NGINX="$TMP/bin/nginx" \
MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE="$TMP/global-deploy.lock" \
MACPROVIDER_DEPLOY_LOCK_FILE="$TMP/deploy.lock" \
MACPROVIDER_DEPLOY_OPERATION_LOCK_FILE="$TMP/deploy-operation.lock" \
MACPROVIDER_DEPLOY_LOCK_REQUIRED_UID="$(id -u)" \
MACPROVIDER_DEPLOY_LOCK_REQUIRED_GID="$(id -g)" \
  "$RECOVER" --pre-start
[ "$(cat "$ROOT/coordinator")" = new-binary ] || fail "active deploy pre-start was rolled back"
[ -d "$ROLLBACK" ] || fail "active deploy snapshot was consumed"

run_recover --pre-start
[ "$(cat "$ROOT/coordinator")" = old-binary ] || fail "orphaned pre-start transaction was not restored"
[ ! -e "$ROLLBACK" ] || fail "orphaned pre-start snapshot was not removed"
grep -qx 'daemon-reload' "$SYSTEMCTL_LOG" || fail "pre-start recovery did not reload the restored unit"
! grep -Eq '^(restart|stop) macprovider-coordinator$' "$SYSTEMCTL_LOG" || fail "pre-start recovery recursively changed coordinator service state"

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

seed_transaction
MACPROVIDER_FLOCK_OVERRIDE="$TMP/bin/flock-busy" run_recover --recover-under-global
[ "$(cat "$ROOT/coordinator")" = old-binary ] || fail "caller-held global recovery did not restore the transaction"
[ ! -e "$ROLLBACK" ] || fail "caller-held global recovery did not remove the snapshot"

# The watchdog starts before direct deploy publishes its rollback snapshot. It
# must wait behind the global lease, then observe and restore the snapshot that
# appears while the controller still owns that lease.
rm -rf "$ROLLBACK"
GLOBAL_BLOCK_SENTINEL="$TMP/global-blocked"
touch "$GLOBAL_BLOCK_SENTINEL"
MACPROVIDER_FLOCK_OVERRIDE="$TMP/bin/flock-operation-blocked" \
MACPROVIDER_OPERATION_BLOCK_SENTINEL="$GLOBAL_BLOCK_SENTINEL" \
  run_recover --recover &
watchdog_pid=$!
sleep 0.15
kill -0 "$watchdog_pid" 2>/dev/null || fail "watchdog exited before the controller published rollback state"
seed_transaction
rm -f "$GLOBAL_BLOCK_SENTINEL"
wait "$watchdog_pid"
[ "$(cat "$ROOT/coordinator")" = old-binary ] || fail "watchdog did not restore the snapshot published behind its lease"
[ ! -e "$ROLLBACK" ] || fail "watchdog did not consume the restored snapshot"

echo "PASS: coordinator deploy recovery is durable and state-exact"

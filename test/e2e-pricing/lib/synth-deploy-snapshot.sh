#!/usr/bin/env bash
# Runs ON the VM (root). Synthesizes the coordinator deploy rollback snapshot
# that deploy-pearl-vps.sh step 4/9 leaves when the deploy dies right after it
# armed its transaction (/opt/macprovider/.coordinator-deploy-rollback with
# `complete`, no `committed`): a verbatim port of that step's snapshot list
# (same file names, markers and copy modes), taken from the host as it is now.
# Overrides let a scenario build a snapshot that is NOT the live state:
#   SNAP_COORDINATOR=<file>  the snapshot's coordinator binary (e.g. pre-#1693)
#   SNAP_YAML=<file>         the snapshot's coordinator.yaml
#   SNAP_CURRENT=<releases/...> the snapshot's catalog-current-target
#   SNAP_WINDOW=<file>       the snapshot's catalog-previous-target bytes
# Usage: synth-deploy-snapshot.sh   (refuses if a snapshot already exists)
set -euo pipefail
R=/opt/macprovider
_rollback=$R/.coordinator-deploy-rollback
_rollback_stage=$_rollback.stage.$$
DOMAIN=coordinator.malibu.tech STATS_DOMAIN=stats.malibu.tech
BACKUP_TS=$(date -u +%Y%m%dT%H%M%SZ)
umask 077
[ ! -e "$_rollback" ] && [ ! -L "$_rollback" ] || { echo "snapshot already exists" >&2; exit 1; }
rm -rf "$_rollback_stage"; mkdir "$_rollback_stage"; chown root:root "$_rollback_stage"; chmod 0700 "$_rollback_stage"
snapshot_node() { if [ -e "$1" ] || [ -L "$1" ]; then cp -a "$1" "$_rollback_stage/$2"; touch "$_rollback_stage/$3"; fi; }
snapshot_active() { if systemctl is-active --quiet "$1"; then touch "$_rollback_stage/$2"; fi; }
snapshot_acl() { if [ -e "$1" ]; then getfacl -p "$1" >"$_rollback_stage/$2" 2>/dev/null; touch "$_rollback_stage/$3"; fi; }
snapshot_node $R/coordinator.prev coordinator.prev had-coordinator-prev
if [ -x $R/coordinator ]; then cp -p "${SNAP_COORDINATOR:-$R/coordinator}" "$_rollback_stage/coordinator"; touch "$_rollback_stage/had-coordinator"; fi
snapshot_node $R/coordinator-cli coordinator-cli had-coordinator-cli
snapshot_node $R/coordinator.yaml.prev coordinator.yaml.prev had-config-prev
printf '%s' "coordinator.yaml.bak-$BACKUP_TS" >"$_rollback_stage/config-backup-name"
snapshot_node $R/coordinator.yaml.bak-$BACKUP_TS coordinator-dated-backup had-config-dated-backup
snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml coordinator.pearl-overlays.yaml had-overlay
snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml.prev coordinator.pearl-overlays.yaml.prev had-overlay-prev
printf '%s' "coordinator.pearl-overlays.yaml.bak-$BACKUP_TS" >"$_rollback_stage/overlay-config-backup-name"
snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml.bak-$BACKUP_TS coordinator-overlay-dated-backup had-overlay-dated-backup
for s in stats-inventory-sync:had-stats-inventory-binary stats-billing-mirror:had-stats-billing-binary stats-hardware-verifier:had-stats-hardware-binary; do
  snapshot_node "/opt/macprovider-stats/${s%%:*}" "${s%%:*}" "${s#*:}"
done
# An override file takes the LIVE file's owner/mode (a real deploy snapshot is
# `cp -p` of the live file; journal payloads are 0600 root).
if [ -f $R/coordinator.yaml ]; then
  cp -p "${SNAP_YAML:-$R/coordinator.yaml}" "$_rollback_stage/coordinator.yaml"; touch "$_rollback_stage/had-config"
  chown --reference=$R/coordinator.yaml "$_rollback_stage/coordinator.yaml"; chmod --reference=$R/coordinator.yaml "$_rollback_stage/coordinator.yaml"
fi
if [ -f $R/tier2-catalog.json ]; then cp -p $R/tier2-catalog.json "$_rollback_stage/tier2-catalog.json"; touch "$_rollback_stage/had-tier2-catalog"; fi
if [ -e /etc/systemd/system/macprovider-coordinator.service ]; then cp -a /etc/systemd/system/macprovider-coordinator.service "$_rollback_stage/macprovider-coordinator.service"; touch "$_rollback_stage/had-service-unit"; fi
for u in inventory:stats-inventory-sync billing:stats-billing-mirror hardware:stats-hardware-verifier; do
  k="${u%%:*}"; n="${u#*:}"
  snapshot_node "/etc/systemd/system/$n.service" "$n.service" "had-stats-$k-service"
  snapshot_node "/etc/systemd/system/$n.timer" "$n.timer" "had-stats-$k-timer"
  snapshot_node "/etc/systemd/system/timers.target.wants/$n.timer" "$n.wants" "had-stats-$k-wants"
done
for u in inventory:stats-inventory-sync billing:stats-billing-mirror hardware:stats-hardware-verifier; do
  k="${u%%:*}"; n="${u#*:}"
  snapshot_active "$n.timer" "stats-$k-timer-was-active"
  snapshot_active "$n.service" "stats-$k-service-was-active"
done
snapshot_node /etc/nginx/conf.d/stats-shared.conf stats-shared.conf had-nginx-stats-shared
snapshot_node /etc/nginx/conf.d/stats-security-headers.conf stats-security-headers.conf had-nginx-stats-security-headers
snapshot_node /etc/nginx/conf.d/cors-429.conf cors-429.conf had-nginx-stats-cors-429
snapshot_node /etc/nginx/conf.d/stats-proxy-public.conf stats-proxy-public.conf had-nginx-stats-proxy-public
snapshot_node /etc/nginx/conf.d/stats-proxy-partner.conf stats-proxy-partner.conf had-nginx-stats-proxy-partner
snapshot_node /etc/nginx/sites-available/$DOMAIN nginx-coordinator.site had-nginx-coordinator-site
snapshot_node /etc/nginx/sites-available/$STATS_DOMAIN nginx-stats.site had-nginx-stats-site
snapshot_node /etc/nginx/sites-enabled/$DOMAIN nginx-coordinator.enabled had-nginx-coordinator-enabled
snapshot_node /etc/nginx/sites-enabled/$STATS_DOMAIN nginx-stats.enabled had-nginx-stats-enabled
snapshot_node /etc/nginx/sites-available/$DOMAIN.full nginx-coordinator.full had-nginx-coordinator-full
if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
  snapshot_acl /var/lib/macprovider request-log-dir.acl had-request-log-dir-acl
  snapshot_acl /var/lib/macprovider/request-log.sqlite request-log-db.acl had-request-log-db-acl
  snapshot_acl /var/lib/macprovider/request-log.sqlite-wal request-log-wal.acl had-request-log-wal-acl
  snapshot_acl /var/lib/macprovider/request-log.sqlite-shm request-log-shm.acl had-request-log-shm-acl
fi
snapshot_node /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service macprovider-coordinator.wants had-wants-link
snapshot_node $R/coordinator-deploy-recover coordinator-deploy-recover had-recovery-helper
snapshot_node /etc/systemd/system/macprovider-coordinator-deploy-recovery.service macprovider-coordinator-deploy-recovery.service had-recovery-unit
snapshot_node /etc/systemd/system/macprovider-coordinator-deploy-watchdog.service macprovider-coordinator-deploy-watchdog.service had-watchdog-unit
snapshot_node /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf 10-deploy-transaction-guard.conf had-guard-dropin
snapshot_node $R/coordinator-pricing-recover coordinator-pricing-recover had-pricing-recover-helper
snapshot_node $R/coordinator-config-guard.sh coordinator-config-guard.sh had-config-guard-lib
snapshot_node /etc/systemd/system/macprovider-coordinator-pricing-close.service macprovider-coordinator-pricing-close.service had-pricing-close-unit
printf '%s' "${SNAP_CURRENT:-$(readlink $R/autotune/current 2>/dev/null || true)}" >"$_rollback_stage/catalog-current-target"
if [ -f $R/autotune/.previous-target ]; then
  cp -p "${SNAP_WINDOW:-$R/autotune/.previous-target}" "$_rollback_stage/catalog-previous-target"; touch "$_rollback_stage/had-previous-target"
  chown --reference=$R/autotune/.previous-target "$_rollback_stage/catalog-previous-target"; chmod --reference=$R/autotune/.previous-target "$_rollback_stage/catalog-previous-target"
fi
printf '%s' "$(basename "$(readlink $R/autotune/current)")" >"$_rollback_stage/release-id"
if systemctl is-active --quiet macprovider-coordinator; then touch "$_rollback_stage/service-was-active"; fi
touch "$_rollback_stage/complete"
mv "$_rollback_stage" "$_rollback"
echo "snapshot armed at $_rollback ($(ls "$_rollback" | wc -l) entries)"

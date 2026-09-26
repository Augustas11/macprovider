#!/usr/bin/env bash
# Tier E2 step 0b: return the "fake Pearl" VM to the post-00 state so a full
# run starts from a FRESH world (no floor marker, no pricing units, no ledger,
# no journal, no request_log history, no stats DB) without deleting the VM.
# Removes exactly what 03/04/05, the deploy scripts, the updater installer and
# the scenarios install; 00-setup-vm.sh then recreates the empty layout.
# Refuses to run against any VM other than $E2E_VM (never macprovider-540).
set -euo pipefail
. "$(dirname "$0")/env.sh"
[ "$E2E_VM" = macprovider-1693 ] || e2e_die "refusing to reset VM '$E2E_VM' (only macprovider-1693)"
e2e_write_ssh_config
e2e_repin_hostkey || true
[ "$(vm hostname)" = "lima-$E2E_VM" ] || e2e_die "VM hostname is not lima-$E2E_VM"
vm_script <<'SH'
set -uo pipefail
units="$(systemctl list-unit-files --no-legend 'macprovider*' 'stats-*' 'e2e-fakeprov*' 2>/dev/null | awk '{print $1}')"
for u in $(systemctl list-units --all --no-legend --plain 'macprovider*' 'stats-*' 'e2e-fakeprov@*' | awk '{print $1}') $units; do
  systemctl disable --now "$u" >/dev/null 2>&1 || systemctl stop "$u" >/dev/null 2>&1 || true
done
systemctl reset-failed >/dev/null 2>&1 || true
pkill -f /opt/macprovider/ 2>/dev/null || true
pkill -f /root/e2e/tools/ 2>/dev/null || true
rm -rf /etc/systemd/system/macprovider-* /etc/systemd/system/stats-* /etc/systemd/system/e2e-fakeprov@.service \
  /etc/systemd/system/multi-user.target.wants/macprovider-* /etc/systemd/system/multi-user.target.wants/e2e-fakeprov@* \
  /etc/systemd/system/timers.target.wants/stats-* /etc/systemd/system/timers.target.wants/macprovider-*
find /etc/systemd/system -xtype l -delete 2>/dev/null || true
systemctl daemon-reload
rm -rf /opt/macprovider /opt/macprovider-stats /etc/macprovider /etc/macprovider-stats /var/lib/macprovider \
  /var/lib/macprovider-monitor /var/lib/macprovider-pearl-updater /var/log/macprovider /run/macprovider \
  /usr/local/sbin/macprovider-* /usr/local/share/macprovider /root/e2e /root/e2e-stage /root/e2e-pair /root/e2e-checkout \
  /tmp/macprovider-* /tmp/e2e-* /etc/sysctl.d/99-macprovider-tcp.conf /etc/modules-load.d/tcp_bbr.conf
rm -f /etc/nginx/sites-enabled/coordinator.malibu.tech* /etc/nginx/sites-enabled/stats.malibu.tech* \
  /etc/nginx/sites-available/coordinator.malibu.tech* /etc/nginx/sites-available/stats.malibu.tech* \
  /etc/nginx/conf.d/cors-429.conf /etc/nginx/conf.d/stats-*.conf /etc/nginx/conf.d/e2e-pearl-shared-zones.conf
[ -e /etc/nginx/sites-enabled/default ] || ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null || true
nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
if systemctl is-active --quiet postgresql; then
  su postgres -c "dropdb --if-exists macprovider_stats" >/dev/null
  for r in $(su postgres -c "psql -tAc \"select rolname from pg_roles where rolname not like 'pg\\_%' and rolname <> 'postgres'\""); do
    su postgres -c "psql -q -c 'DROP ROLE IF EXISTS \"$r\"'" >/dev/null 2>&1 || true
  done
fi
echo "left: $(ls -d /opt/macprovider* /etc/macprovider* /var/lib/macprovider* /usr/local/sbin/macprovider-* 2>/dev/null | tr '\n' ' ')"
SH
# Mac side of the world: the canary stand-in sandbox, tunnels, oracle tables.
. "$E2E_HARNESS/lib/common.sh"
e2e_tunnel_down
env E2E_CANARY_HOME="$E2E_CANARY_HOME" "$E2E_HARNESS/canary-bin/launchctl" bootout 2>/dev/null || true
rm -rf "$E2E_CANARY_HOME" "$E2E_WORK/tables.json"
e2e_log "host reset to the post-00 state"

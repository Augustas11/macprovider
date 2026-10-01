#!/usr/bin/env bash
# VM step 21 (after the shared #1690 vm/20-bootstrap.sh: old coordinator + old
# gateway on a Pearl-shaped host, two native fake providers): the rest of the
# host state a Pearl updater rollout and the #1816 pool-model members need.
#   - provider tokens for e2e-prov-4/-5 and the catalog canary;
#   - the coordinator.malibu.tech nginx vhost as Pearl has it: the baseline
#     tree's vhost WITHOUT the /v1/catalog-artifacts blocks (Pearl's live nginx
#     lags the repo; the runbook adds them by hand), plus the http-context
#     zones it references;
#   - Pearl-side updater prerequisites: monitor.env, the disabled buyer-canary
#     posture (real canary-buyer units installed but disabled, the DISABLED
#     sentinel), the stats billing mirror unit at its pinned path, the
#     pricing-runtime-floor marker (#1693 transaction has run on Pearl);
#   - a stand-in for the Better Stack heartbeat API (uptime.betterstack.com
#     pinned to this host, TLS from the VM test CA);
#   - the catalog canary: a fake CLI run as the user e2ecanary from a
#     LaunchAgent-shaped plist, reached over real sshd by the updater, which
#     streams the REAL ops/pearl-updater/catalog-canary-proof.py to it;
#   - keys (VM only, never printed): the P-256 test release key, the canary ssh
#     key, the provider-owner Ed25519 key of e2e-prov-5.
set -euo pipefail
. /root/e2e/h/vm/lib.sh
. /root/e2e/h/vm/lib-deploy.sh
. /root/e2e/h/vm/lib-scn.sh
. /root/e2e/h16/vm/lib-1816.sh
WTO=/root/e2e/wt-old

log "1816: provider tokens"
rm -f /root/e2e/receipt-key-* /root/e2e/admission-key-4 /root/e2e/admission-key-5
for p in e2e-prov-4 e2e-prov-5 $CANARY_ID; do
  for t in 1 2 3 4 5 6 7 8 9 10; do out="$(/opt/macprovider/coordinator-cli issue-token -db $CDB -provider-id $p -provider-name $p 2>&1)" && break; sleep 3; done
  printf '%s\n' "$out" | sed -n 's/^token=//p' >/root/e2e/token-$p; chmod 600 /root/e2e/token-$p
  [ -s /root/e2e/token-$p ] || die "issue-token $p failed"
done
chown -R macprovider:macprovider /var/lib/macprovider

log "1816: keys"
[ -f $K/release-signing.key ] || { openssl ecparam -name prime256v1 -genkey -noout -out $K/release-signing.key 2>/dev/null; chmod 600 $K/release-signing.key; }
openssl ec -in $K/release-signing.key -pubout -out $K/release-signing-public.pem 2>/dev/null
[ -f $K/owner-prov-5.pem ] || { openssl genpkey -algorithm ed25519 -out $K/owner-prov-5.pem; chmod 600 $K/owner-prov-5.pem; }
[ -f $K/canary_ssh ] || ssh-keygen -q -t ed25519 -N '' -C e2e-canary -f $K/canary_ssh
if [ ! -f $K/betterstack.pem ]; then
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=uptime.betterstack.com" -keyout $K/betterstack.key -out $K/betterstack.csr 2>/dev/null
  printf 'subjectAltName=DNS:uptime.betterstack.com\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' >$K/betterstack.ext
  openssl x509 -req -in $K/betterstack.csr -CA $K/ca.pem -CAkey $K/ca.key -CAcreateserial -days 825 -extfile $K/betterstack.ext -out $K/betterstack.pem 2>/dev/null
fi
grep -q 'e2e-1816 names' /etc/hosts || printf '127.0.0.1 uptime.betterstack.com # e2e-1816 names\n' >>/etc/hosts

log "1816: coordinator.malibu.tech vhost (baseline, without catalog-artifacts), Better Stack stand-in"
python3 - $WTO/phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf "$NGX_COORD" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s, n = re.subn(r"(?ms)^    location = /v1/catalog-artifacts(?:\.sig)? \{.*?^    \}\n", "", s)
open(sys.argv[2], "w").write(s)
print("removed %d catalog-artifacts blocks (Pearl's live vhost lags the repo)" % n)
PY
ln -sfn "$NGX_COORD" /etc/nginx/sites-enabled/coordinator.malibu.tech
install -d -m 0755 /var/cache/nginx   # stats proxy_cache_path parent (exists on Pearl)
# The coordinator deploy installs these shared stats snippets into conf.d
# (phase4-coordinator/dist/deploy-pearl-vps.sh, nginx step).
for f in stats-shared stats-security-headers cors-429 stats-proxy-public stats-proxy-partner; do
  install -o root -g root -m 0644 $WTO/phase4-coordinator/dist/nginx-snippets/$f.conf /etc/nginx/conf.d/$f.conf
done
{
  for z in $(grep -o 'zone=[a-z_]*' "$NGX_COORD" | sed 's/zone=//' | sort -u); do
    grep -rqs --exclude=e2e-1816-coordinator-zones.conf "zone=$z:" /etc/nginx/conf.d /etc/nginx/sites-available/api.malibu.tech || echo "limit_req_zone \$binary_remote_addr zone=$z:1m rate=6000r/m;"
  done
} >/etc/nginx/conf.d/e2e-1816-coordinator-zones.conf
install -d -m 0755 /etc/letsencrypt/live/uptime.betterstack.com
install -m 0644 $K/betterstack.pem /etc/letsencrypt/live/uptime.betterstack.com/fullchain.pem
install -m 0600 $K/betterstack.key /etc/letsencrypt/live/uptime.betterstack.com/privkey.pem
cat >/etc/nginx/sites-available/e2e-betterstack <<'NGX'
# e2e-1816 stand-in for the Better Stack Uptime API (VM only).
server {
    listen 443 ssl;
    server_name uptime.betterstack.com;
    ssl_certificate /etc/letsencrypt/live/uptime.betterstack.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/uptime.betterstack.com/privkey.pem;
    location / { proxy_pass http://127.0.0.1:18991; }
}
NGX
ln -sfn /etc/nginx/sites-available/e2e-betterstack /etc/nginx/sites-enabled/e2e-betterstack
nginx -t 2>/dev/null || { nginx -t; die "nginx config invalid"; }
systemctl reload nginx
cat >/etc/systemd/system/e2e-betterstack.service <<UNIT
[Unit]
Description=e2e-1816 Better Stack heartbeat API stand-in
[Service]
ExecStart=/usr/bin/python3 $E2E_H16/tools/fake-betterstack.py 18991 /root/e2e/logs/betterstack.jsonl
Restart=always
UNIT
systemctl daemon-reload; systemctl restart e2e-betterstack

log "1816: Pearl-side updater prerequisites"
umask 077
printf 'ALERT_EMAIL=e2e-ops@e2e.invalid\nGMAIL_USER=e2e-alerts@e2e.invalid\nGMAIL_APP_PASSWORD=%s\n' "$(openssl rand -hex 8)" >/etc/macprovider/monitor.env
umask 022
chown root:macprovider /etc/macprovider/monitor.env; chmod 0640 /etc/macprovider/monitor.env
install -d -o root -g root -m 0755 /opt/macprovider-canary-buyer /var/lib/macprovider-canary-buyer
: >/var/lib/macprovider-canary-buyer/DISABLED; chmod 0644 /var/lib/macprovider-canary-buyer/DISABLED
for f in canary-buyer.service canary-buyer.timer; do install -o root -g root -m 0644 /root/e2e/wt-new/test/e2e/canary-buyer/$f /etc/systemd/system/$f; done
rm -f /etc/macprovider-canary-buyer/enabled /etc/macprovider/canary-buyer.enabled
getent group macprovider-stats >/dev/null || groupadd --system macprovider-stats
id macprovider-stats >/dev/null 2>&1 || useradd --system --gid macprovider-stats --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin macprovider-stats
install -d -o root -g root -m 0755 /opt/macprovider-stats
install -o root -g macprovider-stats -m 0750 /root/e2e/bins/old/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror
# Pearl's live billing DB is request-log.sqlite (lib/live-config.py); the unit names it.
sed 's#/var/lib/macprovider/coordinator.db#/var/lib/macprovider/request-log.sqlite#g' $WTO/phase4-coordinator/dist/stats-billing-mirror.service >/etc/systemd/system/stats-billing-mirror.service
install -o root -g root -m 0644 $WTO/phase4-coordinator/dist/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer
chmod 0644 /etc/systemd/system/stats-billing-mirror.service
for u in macprovider-archive-rotate.service macprovider-archive-rotate.timer; do
  [ -f /etc/systemd/system/$u ] || install -o root -g root -m 0644 $WTO/phase5-gateway/dist/$u /etc/systemd/system/$u
done
systemctl daemon-reload
systemctl disable --now canary-buyer.timer >/dev/null 2>&1 || true
systemctl stop canary-buyer.service >/dev/null 2>&1 || true
# The #1693 pricing transaction has run on Pearl: the floor marker is present.
install -o root -g root -m 0644 /dev/null /opt/macprovider/.pricing-runtime-floor
[ -e /usr/sbin/lsof ] || ln -s /usr/bin/lsof /usr/sbin/lsof

log "1816: catalog canary (user $CANARY_USER, real sshd, real proof script)"
id $CANARY_USER >/dev/null 2>&1 || useradd --create-home --shell /bin/bash $CANARY_USER
CH=/home/$CANARY_USER
install -m 0755 $E2E_H16/lib/launchctl /usr/local/bin/launchctl
su - $CANARY_USER -c 'launchctl bootout' >/dev/null 2>&1 || true
install -d -o $CANARY_USER -g $CANARY_USER -m 0700 $CH/.ssh $CH/.config $CH/.config/macprovider
install -d -o $CANARY_USER -g $CANARY_USER -m 0755 $CH/Library $CH/Library/LaunchAgents $CH/macprovider $CH/macprovider/catalog-release
install -o $CANARY_USER -g $CANARY_USER -m 0600 $K/canary_ssh.pub $CH/.ssh/authorized_keys
printf '%s\n' $CANARY_ID >$CH/.config/macprovider/provider_id
install -o $CANARY_USER -g $CANARY_USER -m 0600 /root/e2e/token-$CANARY_ID $CH/.config/macprovider/provider-token
install -o $CANARY_USER -g $CANARY_USER -m 0755 /root/e2e/bins/fakeprov $CH/macprovider/macprovider-cli
cat >$CH/.config/macprovider/config.yaml <<CFG
# e2e-1816 catalog canary (fakeprov serve --config)
port: 19196
coordinator_ws: ws://127.0.0.1:8444/ws/provider
provider_id: $CANARY_ID
token_file: $CH/.config/macprovider/provider-token
http_listen: 127.0.0.1:19106
endpoint_url: http://127.0.0.1:19106
catalog_from_coordinator: http://127.0.0.1:8443
settlement: true
CFG
python3 - $CH <<'PY'
import plistlib, sys
h = sys.argv[1]
plistlib.dump({"Label": "live.malibu.provider",
               "ProgramArguments": [h + "/macprovider/macprovider-cli", "serve", "--config", h + "/.config/macprovider/config.yaml"],
               "RunAtLoad": True}, open(h + "/Library/LaunchAgents/live.malibu.provider.plist", "wb"))
PY
chown -R $CANARY_USER:$CANARY_USER $CH/.config $CH/Library $CH/macprovider
canary_ctl bootstrap
ssh-keyscan -t ed25519 127.0.0.1 2>/dev/null >$K/canary_known_hosts
ssh -i $K/canary_ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$K/canary_known_hosts -F /dev/null \
  $CANARY_USER@127.0.0.1 true || die "canary ssh failed"
for i in $(seq 1 60); do canary_status 2>/dev/null | grep -q '"connected":true' && break; sleep 2; done
canary_status | grep -q '"connected":true' || die "canary provider did not connect: $(canary_status 2>&1 | head -c 300)"
log "1816 bootstrap ok: canary $(canary_status | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["network_state"],d["catalog"]["release_id"])')"

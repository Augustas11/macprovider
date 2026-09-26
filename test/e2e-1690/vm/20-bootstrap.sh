#!/usr/bin/env bash
# VM step 20: the host state Pearl already has before any #1690 deploy
# ("stage 1"), then the OLD (production-equivalent) coordinator and gateway:
#   - operator SSH (the operator lane runs in this VM and SSHes to root@127.0.0.1,
#     exactly as deploy-pearl-vps.sh SSHes from the operator Mac to Pearl);
#   - test CA + server cert for api.malibu.tech at the Let's Encrypt paths,
#     /etc/hosts pinning the production names to this host, Pearl's shared
#     nginx http-context zones;
#   - Postgres with the SPEC-017/026 schema (the coordinator opens the
#     onboarding store unconditionally) and /etc/macprovider/*.env test secrets;
#   - the live /opt/macprovider/coordinator.yaml (lib/live-config.py) + overlay;
#   - the committed signed autotune release under /opt/macprovider/autotune;
#   - old coordinator (vm/lib-deploy.sh coord_install) and old gateway through
#     the REAL phase5-gateway/dist/deploy-pearl-vps.sh;
#   - buyer account + API key, provider tokens, two native fake providers.
# Destroys any previous e2e state first (run-from-scratch).
set -euo pipefail
. /root/e2e/h/vm/lib.sh
. /root/e2e/h/vm/lib-deploy.sh

log "reset: stop services and wipe state"
systemctl stop 'e2e-fakeprov@*' macprovider-gateway macprovider-coordinator e2e-faultproxy 2>/dev/null || true
rm -rf /var/lib/macprovider/* /opt/macprovider/* /etc/macprovider/* /root/e2e/token-* /root/e2e/buyer-api-key /root/e2e/fakeprov-*.env
rm -f /etc/nginx/sites-enabled/api.malibu.tech /etc/nginx/sites-available/api.malibu.tech
install -d -o root -g macprovider -m 0750 /opt/macprovider /etc/macprovider
install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider /var/log/macprovider

log "operator SSH to root@127.0.0.1"
install -d -m 700 /root/.ssh
[ -f /root/.ssh/e2e_operator ] || ssh-keygen -q -t ed25519 -N '' -C e2e-operator -f /root/.ssh/e2e_operator
touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
grep -qxF "$(cat /root/.ssh/e2e_operator.pub)" /root/.ssh/authorized_keys || cat /root/.ssh/e2e_operator.pub >>/root/.ssh/authorized_keys
systemctl enable --now ssh >/dev/null 2>&1 || true
ssh-keyscan -t ed25519 127.0.0.1 2>/dev/null >/root/.ssh/known_hosts
ssh -i /root/.ssh/e2e_operator -o BatchMode=yes root@127.0.0.1 true || die "operator ssh failed"

log "TLS + names"
K=/root/e2e/keys; install -d -m 700 $K
if [ ! -f $K/ca.pem ] || ! openssl x509 -in $K/ca.pem -noout -ext keyUsage >/dev/null 2>&1; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj "/CN=macprovider e2e-1690 test CA" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -keyout $K/ca.key -out $K/ca.pem 2>/dev/null
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=api.malibu.tech" -keyout $K/server.key -out $K/server.csr 2>/dev/null
  printf 'subjectAltName=DNS:api.malibu.tech,DNS:coordinator.malibu.tech,DNS:stats.malibu.tech\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' >$K/san.ext
  openssl x509 -req -in $K/server.csr -CA $K/ca.pem -CAkey $K/ca.key -CAcreateserial -days 825 -extfile $K/san.ext -out $K/server.pem 2>/dev/null
fi
cp $K/ca.pem /usr/local/share/ca-certificates/e2e-1690-ca.crt && update-ca-certificates >/dev/null 2>&1
for d in api.malibu.tech coordinator.malibu.tech; do
  install -d -m 0755 /etc/letsencrypt/live/$d
  install -m 0644 $K/server.pem /etc/letsencrypt/live/$d/fullchain.pem
  install -m 0600 $K/server.key /etc/letsencrypt/live/$d/privkey.pem
done
grep -q 'e2e-1690 names' /etc/hosts || printf '127.0.0.1 api.malibu.tech coordinator.malibu.tech stats.malibu.tech # e2e-1690 names\n' >>/etc/hosts
# Pearl keeps these zones in the shared http context (the vhost templates say so).
cat >/etc/nginx/conf.d/e2e-pearl-shared-zones.conf <<'NGX'
limit_req_zone $binary_remote_addr zone=ws_provider_rate:10m rate=10r/m;
limit_conn_zone $binary_remote_addr zone=ws_provider_conn:10m;
limit_conn_zone $binary_remote_addr zone=buyer_conn:10m;
NGX
rm -f /etc/nginx/sites-enabled/default
nginx -t 2>/dev/null && systemctl enable --now nginx >/dev/null 2>&1 && systemctl reload nginx

log "Postgres + secrets"
systemctl enable --now postgresql >/dev/null 2>&1
su postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='macprovider_stats'\"" | grep -q 1 || su postgres -c "createdb macprovider_stats"
install -m 0755 /root/e2e/bins/old/coordinator-linux-amd64 /tmp/e2e-stats-migrate
su postgres -c "/tmp/e2e-stats-migrate stats-migrate --admin-dsn 'host=/var/run/postgresql dbname=macprovider_stats sslmode=disable'" >/dev/null
rm -f /tmp/e2e-stats-migrate
for r in provider_onboarding provider_auth_policy_requester provider_auth_policy_approver provider_auth_policy_cutover hardware_trust_requester hardware_trust_approver stats_reader stats_rollup; do
  su postgres -c "psql -v ON_ERROR_STOP=1 -q -d macprovider_stats -c \"ALTER ROLE $r LOGIN PASSWORD 'e2e-$r-local'\""
done
d() { echo "postgres://$1:e2e-$1-local@127.0.0.1:5432/macprovider_stats?sslmode=disable"; }
for n in operator_key gateway_service_token key_hash_secret; do [ -f $K/$n ] || { openssl rand -hex 32 >$K/$n; chmod 600 $K/$n; }; done
OPK="$(cat $K/operator_key)"; GST="$(cat $K/gateway_service_token)"
umask 077
cat >/etc/macprovider/coordinator.env <<ENV
OPERATOR_KEY=$OPK
GATEWAY_SERVICE_TOKEN=$GST
OPERATOR_AUTH_POLICY_A=$(openssl rand -hex 32)
OPERATOR_AUTH_POLICY_B=$(openssl rand -hex 32)
MAL_REFERRAL_HMAC_K1=$(openssl rand -hex 32)
APPLE_TEAM_ID=E2ETEAM001
STATS_READER_DSN=$(d stats_reader)
STATS_ROLLUP_DSN=$(d stats_rollup)
ONBOARDING_POSTGRES_DSN=$(d provider_onboarding)
ONBOARDING_AUTH_POLICY_REQUEST_DSN=$(d provider_auth_policy_requester)
ONBOARDING_AUTH_POLICY_APPROVE_DSN=$(d provider_auth_policy_approver)
ONBOARDING_AUTH_POLICY_CUTOVER_DSN=$(d provider_auth_policy_cutover)
ONBOARDING_HARDWARE_TRUST_REQUEST_DSN=$(d hardware_trust_requester)
ONBOARDING_HARDWARE_TRUST_APPROVE_DSN=$(d hardware_trust_approver)
ENV
cat >/etc/macprovider/gateway.env <<ENV
COORDINATOR_OPERATOR_KEY=$OPK
COORDINATOR_SERVICE_TOKEN=$GST
MACPROVIDER_KEY_HASH_SECRET=$(cat $K/key_hash_secret)
MACPROVIDER_DEMO_SIGNING_SECRET=$(openssl rand -hex 32)
ENV
umask 022
chown root:macprovider /etc/macprovider/*.env; chmod 0640 /etc/macprovider/*.env

log "live coordinator config, overlay, autotune release (old tree)"
python3 $E2E_H/lib/live-config.py </root/e2e/wt-old/phase4-coordinator/dist/coordinator.yaml >/tmp/e2e-coordinator.yaml
install -o root -g root -m 0644 /tmp/e2e-coordinator.yaml /opt/macprovider/coordinator.yaml
printf '# E2E Pearl overlay (non-pricing keys only)\nrouting:\n  sticky_enabled: true\n' >/etc/macprovider/coordinator.pearl-overlays.yaml
chown root:macprovider /etc/macprovider/coordinator.pearl-overlays.yaml; chmod 0640 /etc/macprovider/coordinator.pearl-overlays.yaml
autotune_install /root/e2e/wt-old
install -o root -g root -m 0644 $E2E_H/lib/gateway.yaml /opt/macprovider/gateway.yaml.seed

log "old coordinator"
coord_install old
log "provider tokens"
for p in e2e-prov-1 e2e-prov-2 e2e-prov-3; do
  out="$(/opt/macprovider/coordinator-cli issue-token -db $CDB -provider-id $p -provider-name $p)"
  printf '%s\n' "$out" | sed -n 's/^token=//p' >/root/e2e/token-$p; chmod 600 /root/e2e/token-$p
  [ -s /root/e2e/token-$p ] || die "issue-token $p failed: $out"
done
chown -R macprovider:macprovider /var/lib/macprovider

log "old gateway via the real deploy-pearl-vps.sh (first deploy: FORCE_RESTART=1, no live gateway yet)"
install -o macprovider -g macprovider -m 0640 $E2E_H/lib/gateway.yaml /opt/macprovider/gateway.yaml
FORCE_RESTART=1 gw_deploy old first || die "first gateway deploy failed"
for i in $(seq 1 30); do gwsql "select 1 from sqlite_master where name='api_keys'" 2>/dev/null | grep -q 1 && break; sleep 2; done
python3 $E2E_H/lib/seed-buyer.py $GWDB "$(cat $K/key_hash_secret)" >/root/e2e/buyer-api-key; chmod 600 /root/e2e/buyer-api-key
chown macprovider:macprovider $GWDB* 2>/dev/null || true

log "fake providers"
install -o root -g root -m 0755 /root/e2e/bins/fakeprov /opt/macprovider/e2e-fakeprov
install -o root -g root -m 0644 $E2E_H/lib/fakeprov@.service /etc/systemd/system/e2e-fakeprov@.service
for i in 1 2; do printf 'FAKEPROV_ARGS=-stream-chunks 20 -chunk-delay-ms 100 -nonstream-delay-ms 1500\n' >/root/e2e/fakeprov-$i.env; done
systemctl daemon-reload
systemctl enable --now e2e-fakeprov@1 e2e-fakeprov@2 >/dev/null 2>&1
wait_providers 2 || die "providers did not become ready"
log "bootstrap ok: $(curl -fsS http://127.0.0.1:8443/healthz) | gw $(curl -fsS http://127.0.0.1:9443/healthz | head -c 200)"

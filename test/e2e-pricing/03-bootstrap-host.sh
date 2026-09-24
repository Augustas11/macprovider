#!/usr/bin/env bash
# Tier E2 step 3: "Stage 1" host state that deploy-pearl-vps.sh assumes already
# exists on Pearl (it is not what the pricing lane tests):
#   - Postgres with the SPEC-017/026 schema and login roles (the coordinator
#     opens the onboarding store unconditionally);
#   - /etc/macprovider/coordinator.env (test secrets; DSNs to the local PG);
#   - the operator-owned live /opt/macprovider/coordinator.yaml (lib/live-config.py
#     over the pre-#1693 tag's template) and a non-empty overlay;
#   - the gateway (binary from the pre tag, config, env, unit) + a buyer account
#     and API key, and the fake provider tokens;
#   - the fake providers (systemd units) that serve and settle requests.
# The coordinator itself, its units, nginx and the catalog release are installed
# by the real deploy in 04-seed-pre-1693.sh.
set -euo pipefail
. "$(dirname "$0")/env.sh"
e2e_write_ssh_config
BINS="$E2E_WORK/bins/$E2E_TAG_PRE"
[ -x "$BINS/coordinator-linux-amd64" ] || e2e_die "run 02-build.sh first"
FAKEPROV="$E2E_HARNESS/fakeprov/dist/fakeprov-linux-amd64"
[ -x "$FAKEPROV" ] || e2e_die "build test/e2e-pricing/fakeprov first (fakeprov/build.sh)"

stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
cp "$BINS/coordinator-linux-amd64" "$BINS/coordinator-cli-linux-amd64" "$BINS/gateway-linux-amd64" "$FAKEPROV" "$stage/"
git -C "$E2E_REPO" show "$E2E_TAG_PRE:phase4-coordinator/dist/coordinator.yaml" | python3 "$E2E_HARNESS/lib/live-config.py" >"$stage/coordinator.yaml"
git -C "$E2E_REPO" show "$E2E_TAG_PRE:phase5-gateway/dist/macprovider-gateway.service" >"$stage/macprovider-gateway.service"
cp "$E2E_HARNESS/lib/gateway.yaml" "$E2E_HARNESS/lib/fakeprov@.service" "$E2E_HARNESS/lib/seed-buyer.py" "$stage/"
for n in operator_key gateway_service_token key_hash_secret; do cp "$E2E_KEYS/$n" "$stage/$n"; done
tar -C "$stage" -cf - . | vm "rm -rf /root/e2e-stage && mkdir -m 700 /root/e2e-stage && tar -xf - -C /root/e2e-stage"

vm_script <<'SH'
set -euo pipefail
S=/root/e2e-stage
# ---- Postgres (SPEC-017/026 schema via the coordinator's own stats-migrate) --
systemctl enable --now postgresql >/dev/null 2>&1
su postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='macprovider_stats'\"" | grep -q 1 || su postgres -c "createdb macprovider_stats"
install -m 0755 $S/coordinator-linux-amd64 /tmp/e2e-stats-migrate
su postgres -c "/tmp/e2e-stats-migrate stats-migrate --admin-dsn 'host=/var/run/postgresql dbname=macprovider_stats sslmode=disable'" >/dev/null
rm -f /tmp/e2e-stats-migrate
for r in provider_onboarding provider_auth_policy_requester provider_auth_policy_approver provider_auth_policy_cutover hardware_trust_requester hardware_trust_approver stats_reader stats_rollup; do
  su postgres -c "psql -v ON_ERROR_STOP=1 -q -d macprovider_stats -c \"ALTER ROLE $r LOGIN PASSWORD 'e2e-$r-local'\""
done
d() { echo "postgres://$1:e2e-$1-local@127.0.0.1:5432/macprovider_stats?sslmode=disable"; }
OPK="$(cat $S/operator_key)"; GST="$(cat $S/gateway_service_token)"
umask 077
cat >/etc/macprovider/coordinator.env <<EOF
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
EOF
chown root:macprovider /etc/macprovider/coordinator.env; chmod 0640 /etc/macprovider/coordinator.env
cat >/etc/macprovider/gateway.env <<EOF
COORDINATOR_OPERATOR_KEY=$OPK
COORDINATOR_SERVICE_TOKEN=$GST
MACPROVIDER_KEY_HASH_SECRET=$(cat $S/key_hash_secret)
MACPROVIDER_DEMO_SIGNING_SECRET=$(openssl rand -hex 32)
EOF
chown root:macprovider /etc/macprovider/gateway.env; chmod 0640 /etc/macprovider/gateway.env
umask 022
# ---- live coordinator config + overlay (operator-owned on Pearl) -------------
install -o root -g root -m 0644 $S/coordinator.yaml /opt/macprovider/coordinator.yaml
if [ ! -e /etc/macprovider/coordinator.pearl-overlays.yaml ]; then
  printf '# E2E Pearl overlay (non-pricing keys only)\nrouting:\n  sticky_enabled: true\n' >/etc/macprovider/coordinator.pearl-overlays.yaml
  chown root:macprovider /etc/macprovider/coordinator.pearl-overlays.yaml; chmod 0640 /etc/macprovider/coordinator.pearl-overlays.yaml
fi
install -d -o macprovider -g macprovider -m 0750 /var/log/macprovider
# Pearl's shared http-context nginx zone (declared outside the repo's vhost
# templates: "Pearl keeps the gateway zones in the shared/legacy http context").
printf 'limit_req_zone $binary_remote_addr zone=ws_provider_rate:10m rate=10r/m;\nlimit_conn_zone $binary_remote_addr zone=ws_provider_conn:10m;\n' >/etc/nginx/conf.d/e2e-pearl-shared-zones.conf
# ---- gateway ------------------------------------------------------------------
install -o root -g root -m 0755 $S/gateway-linux-amd64 /opt/macprovider/gateway
install -o macprovider -g macprovider -m 0640 $S/gateway.yaml /opt/macprovider/gateway.yaml
install -o root -g root -m 0644 $S/macprovider-gateway.service /etc/systemd/system/macprovider-gateway.service
install -o root -g root -m 0755 $S/coordinator-cli-linux-amd64 /opt/macprovider/coordinator-cli
install -o root -g root -m 0755 $S/fakeprov-linux-amd64 /opt/macprovider/e2e-fakeprov
install -o root -g root -m 0644 $S/fakeprov@.service /etc/systemd/system/e2e-fakeprov@.service
systemctl daemon-reload
systemctl enable --now macprovider-gateway >/dev/null 2>&1 || true
for i in $(seq 1 30); do [ -f /var/lib/macprovider/gateway.db ] && sqlite3 /var/lib/macprovider/gateway.db "select 1 from sqlite_master where name='api_keys'" | grep -q 1 && break; sleep 2; done
install -d -m 0700 /root/e2e
[ -s /root/e2e/buyer-api-key ] || python3 $S/seed-buyer.py /var/lib/macprovider/gateway.db "$(cat $S/key_hash_secret)" >/root/e2e/buyer-api-key
chmod 600 /root/e2e/buyer-api-key
# ---- provider tokens for the pinned fake providers (coordinator DB) ------------
install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider
for p in e2e-prov-1 e2e-prov-2 e2e-canary-provider; do
  [ -s /root/e2e/token-$p ] && continue
  out="$(/opt/macprovider/coordinator-cli issue-token -db /var/lib/macprovider/request-log.sqlite -provider-id $p -provider-name $p)"
  printf '%s\n' "$out" | sed -n 's/^token=//p' >/root/e2e/token-$p
  chmod 600 /root/e2e/token-$p
done
chown -R macprovider:macprovider /var/lib/macprovider
rm -rf $S
echo "bootstrap ok"
SH
e2e_log "host bootstrap done"

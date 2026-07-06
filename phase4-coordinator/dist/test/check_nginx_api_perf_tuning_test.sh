#!/usr/bin/env bash
# check_nginx_api_perf_tuning_test.sh — assert #378 buyer-facing nginx
# latency/connection tuning stays active in the gateway deploy surface.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
NGINX_CONF="$REPO_ROOT/phase5-gateway/dist/nginx-api.streamvc.live.conf"
GATEWAY_DEPLOY="$REPO_ROOT/phase5-gateway/dist/deploy-pearl-vps.sh"

FAIL=0
fail() { echo "FAIL: $1" >&2; FAIL=1; }

if [ ! -f "$NGINX_CONF" ]; then
  fail "$NGINX_CONF: missing"
  exit "$FAIL"
fi
if [ ! -f "$GATEWAY_DEPLOY" ]; then
  fail "$GATEWAY_DEPLOY: missing"
  exit "$FAIL"
fi

ACTIVE_CONF="$(sed 's/[[:space:]]*#.*$//' "$NGINX_CONF")"
ACTIVE_DEPLOY="$(grep -vE '^[[:space:]]*#' "$GATEWAY_DEPLOY")"
require_conf_directive() {
  local directive="$1"
  if ! grep -qF "$directive" <<<"$ACTIVE_CONF"; then
    fail "$NGINX_CONF missing active directive: $directive"
  fi
}

require_conf_directive "keepalive_timeout 300s;"
require_conf_directive "keepalive_requests 1000;"
require_conf_directive "client_body_timeout 300s;"
require_conf_directive "send_timeout 300s;"

# `worker_connections` is an nginx events-context directive, so the gateway
# deploy script owns the idempotent global nginx.conf tuning before `nginx -t`.
if ! grep -qE "grep[[:space:]].*worker_connections.*/etc/nginx/nginx.conf" <<<"$ACTIVE_DEPLOY"; then
  fail "$GATEWAY_DEPLOY missing active worker_connections precheck"
fi
if ! grep -qE "sed[[:space:]].*worker_connections 4096;" <<<"$ACTIVE_DEPLOY"; then
  fail "$GATEWAY_DEPLOY missing active worker_connections 4096 deploy tuning"
fi
if ! grep -qF "nginx.conf.bak.macprovider-c2" <<<"$ACTIVE_DEPLOY"; then
  fail "$GATEWAY_DEPLOY missing nginx.conf backup naming for C2 rollback"
fi
if ! grep -qE "if[[:space:]]+\\[[[:space:]]+![[:space:]]+-f[[:space:]]+/etc/nginx/nginx.conf.bak.macprovider-c2[[:space:]]+\\]" <<<"$ACTIVE_DEPLOY"; then
  fail "$GATEWAY_DEPLOY does not preserve the first C2 nginx.conf backup"
fi
if ! grep -qE "grep[[:space:]].*worker_connections.*4096.*/etc/nginx/nginx.conf" <<<"$ACTIVE_DEPLOY"; then
  fail "$GATEWAY_DEPLOY missing active worker_connections 4096 postcondition"
fi
if ! grep -qF "/etc/nginx/nginx.conf" <<<"$ACTIVE_DEPLOY"; then
  fail "$GATEWAY_DEPLOY does not apply worker_connections via /etc/nginx/nginx.conf"
fi
if ! grep -qF "nginx worker tuning rollback" "$GATEWAY_DEPLOY"; then
  fail "$GATEWAY_DEPLOY missing C2 nginx rollback guidance"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "ok: nginx API buyer-path performance tuning configured"
fi
exit "$FAIL"

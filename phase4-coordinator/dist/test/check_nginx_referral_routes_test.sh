#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config="$root/dist/nginx-coordinator.streamvc.live.conf"
shared_config="$root/dist/nginx-snippets/stats-shared.conf"
deploy="$root/dist/deploy-pearl-vps.sh"

count="$(grep -c 'location \^~ /j/' "$config")"
test "$count" -eq 2
grep -A12 'location \^~ /j/' "$config" | grep -q 'access_log off;'
grep -A12 'location \^~ /j/' "$config" | grep -q 'proxy_pass http://127.0.0.1:8443;'
grep -A5 'location \^~ /j/' "$config" | grep -q 'add_header Cache-Control "no-store" always;'
grep -A5 'location \^~ /j/' "$config" | grep -q 'return 307 https://coordinator\.streamvc\.live\$request_uri;'
if grep -A5 'location \^~ /j/' "$config" | grep -q 'https://\$host'; then
  echo "invite redirect must pin the trusted coordinator origin" >&2
  exit 1
fi
if grep -A5 'location \^~ /j/' "$config" | grep -q 'return 301 '; then
  echo "invite redirect must not be permanent" >&2
  exit 1
fi

grep -q 'zone=referral_validate_rate:10m rate=30r/m;' "$shared_config"
grep -q 'NGINX_STATS_SHARED=.*nginx-snippets/stats-shared.conf' "$deploy"
grep -q 'install .*nginx-stats-shared.conf /etc/nginx/conf.d/stats-shared.conf' "$deploy"
test "$(grep -c 'location = /v1/referrals/validate' "$config")" -eq 1
validate_block="$(grep -A18 'location = /v1/referrals/validate' "$config")"
grep -q 'limit_req zone=referral_validate_rate burst=10 nodelay;' <<<"$validate_block"
grep -q 'proxy_pass http://127.0.0.1:8443/v1/referrals/validate;' <<<"$validate_block"
grep -q 'proxy_no_cache 1;' <<<"$validate_block"
grep -q 'proxy_cache_bypass 1;' <<<"$validate_block"
grep -q 'client_max_body_size 1k;' <<<"$validate_block"
grep -q 'add_header Cache-Control "no-store" always;' <<<"$validate_block"
validate_line="$(grep -nE '^[[:space:]]*location = /v1/referrals/validate' "$config" | cut -d: -f1)"
catchall_line="$(grep -nE '^[[:space:]]*location[[:space:]]+/v1/[[:space:]]*[{]' "$config" | cut -d: -f1)"
test "$validate_line" -lt "$catchall_line"

echo "nginx referral route checks passed"

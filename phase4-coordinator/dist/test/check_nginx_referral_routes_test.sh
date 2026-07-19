#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config="$root/dist/nginx-coordinator.streamvc.live.conf"
shared_config="$root/dist/nginx-snippets/stats-shared.conf"
deploy="$root/dist/deploy-pearl-vps.sh"

test "$(grep -c 'location \^~ /j/' "$config")" -eq 2
legacy_blocks="$(grep -A5 'location \^~ /j/' "$config")"
test "$(grep -c 'access_log off;' <<<"$legacy_blocks")" -eq 2
test "$(grep -c 'add_header Cache-Control "no-store" always;' <<<"$legacy_blocks")" -eq 2
test "$(grep -c 'return 404;' <<<"$legacy_blocks")" -eq 2
if grep -Eq 'proxy_pass|return 30[1278]' <<<"$legacy_blocks"; then
  echo "legacy credential-bearing /j/<code> privacy tombstones must not proxy or redirect" >&2
  exit 1
fi

grep -q 'zone=referral_validate_rate:10m rate=30r/m;' "$shared_config"
grep -q 'zone=referral_provider_rate:10m rate=60r/m;' "$shared_config"
grep -q 'NGINX_STATS_SHARED=.*nginx-snippets/stats-shared.conf' "$deploy"
grep -q 'install .*nginx-stats-shared.conf /etc/nginx/conf.d/stats-shared.conf' "$deploy"
test "$(grep -c 'location = /v1/referrals/validate' "$config")" -eq 1
validate_block="$(grep -A18 'location = /v1/referrals/validate' "$config")"
grep -q 'limit_req zone=referral_validate_rate burst=10 nodelay;' <<<"$validate_block"
grep -q 'proxy_pass http://127.0.0.1:8443/v1/referrals/validate;' <<<"$validate_block"
grep -q 'proxy_pass_header Access-Control-Allow-Origin;' <<<"$validate_block"
grep -q 'proxy_no_cache 1;' <<<"$validate_block"
grep -q 'proxy_cache_bypass 1;' <<<"$validate_block"
grep -q 'client_max_body_size 1k;' <<<"$validate_block"
grep -q 'add_header Cache-Control "no-store" always;' <<<"$validate_block"
validate_line="$(grep -nE '^[[:space:]]*location = /v1/referrals/validate' "$config" | cut -d: -f1)"
catchall_line="$(grep -nE '^[[:space:]]*location[[:space:]]+/v1/[[:space:]]*[{]' "$config" | cut -d: -f1)"
test "$validate_line" -lt "$catchall_line"

for path in \
  /v1/provider/referrals \
  /v1/provider/referrals/x/challenge \
  /v1/provider/referrals/x/verify
do
  test "$(grep -Fc "location = $path {" "$config")" -eq 1
  block="$(grep -FA18 "location = $path {" "$config")"
  grep -q "proxy_pass http://127.0.0.1:8443$path;" <<<"$block"
  grep -q 'limit_req zone=referral_provider_rate burst=10 nodelay;' <<<"$block"
  grep -q 'proxy_set_header Authorization $http_authorization;' <<<"$block"
  grep -q 'proxy_no_cache 1;' <<<"$block"
  grep -q 'proxy_cache_bypass 1;' <<<"$block"
  grep -q 'client_max_body_size ' <<<"$block"
  grep -q 'add_header Cache-Control "no-store" always;' <<<"$block"
  route_line="$(grep -nF "location = $path {" "$config" | cut -d: -f1)"
  test "$route_line" -lt "$catchall_line"
done

echo "nginx referral route checks passed"

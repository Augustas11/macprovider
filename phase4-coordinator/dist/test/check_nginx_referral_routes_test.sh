#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config="$root/dist/nginx-coordinator.streamvc.live.conf"
api_config="$root/../phase5-gateway/dist/nginx-api.streamvc.live.conf"

count="$(grep -c 'location \^~ /j/' "$config")"
test "$count" -eq 2
grep -A12 'location \^~ /j/' "$config" | grep -q 'access_log off;'
grep -A12 'location \^~ /j/' "$config" | grep -q 'proxy_pass http://127.0.0.1:8443;'
grep -A12 'location \^~ /j/' "$config" | grep -q 'return 301 https://\$host\$request_uri;'

for declaration in \
    'zone=referral_validate_rate:10m rate=60r/m' \
    'zone=referral_status_rate:10m rate=60r/m' \
    'zone=referral_social_rate:10m rate=30r/m'; do
    grep -Fq "$declaration" "$api_config"
done

check_route() {
    local route="$1"
    local zone="$2"
    block="$(grep -F -A18 "location = $route {" "$config")"
    grep -Fq "limit_req zone=$zone" <<<"$block"
    if grep -Fq 'limit_req zone=ws_provider_rate' <<<"$block"; then
        echo "referral route $route must not share the WebSocket rate bucket" >&2
        return 1
    fi
    grep -Fq "proxy_pass http://127.0.0.1:8443$route;" <<<"$block"
    grep -Fq 'proxy_no_cache 1;' <<<"$block"
    grep -Fq 'add_header Cache-Control "no-store" always;' <<<"$block"
}

check_route /v1/referrals/validate referral_validate_rate
check_route /v1/provider/referrals referral_status_rate
check_route /v1/provider/referrals/x/challenge referral_social_rate
check_route /v1/provider/referrals/x/verify referral_social_rate

for route in \
    /v1/provider/referrals \
    /v1/provider/referrals/x/challenge \
    /v1/provider/referrals/x/verify; do
    grep -F -A18 "location = $route {" "$config" | grep -Fq 'proxy_set_header Authorization $http_authorization;'
done

echo "nginx referral route checks passed"

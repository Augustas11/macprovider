#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config="$root/dist/nginx-coordinator.streamvc.live.conf"

count="$(grep -c 'location \^~ /j/' "$config")"
test "$count" -eq 2
grep -A12 'location \^~ /j/' "$config" | grep -q 'access_log off;'
grep -A12 'location \^~ /j/' "$config" | grep -q 'proxy_pass http://127.0.0.1:8443;'
grep -A12 'location \^~ /j/' "$config" | grep -q 'return 301 https://\$host\$request_uri;'

for route in \
    /v1/referrals/validate \
    /v1/provider/referrals \
    /v1/provider/referrals/x/challenge \
    /v1/provider/referrals/x/verify; do
    block="$(grep -F -A18 "location = $route {" "$config")"
    grep -Fq 'limit_req zone=ws_provider_rate' <<<"$block"
    grep -Fq "proxy_pass http://127.0.0.1:8443$route;" <<<"$block"
    grep -Fq 'proxy_no_cache 1;' <<<"$block"
    grep -Fq 'add_header Cache-Control "no-store" always;' <<<"$block"
done

for route in \
    /v1/provider/referrals \
    /v1/provider/referrals/x/challenge \
    /v1/provider/referrals/x/verify; do
    grep -F -A18 "location = $route {" "$config" | grep -Fq 'proxy_set_header Authorization $http_authorization;'
done

echo "nginx referral route checks passed"

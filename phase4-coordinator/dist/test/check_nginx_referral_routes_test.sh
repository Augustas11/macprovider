#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config="$root/dist/nginx-coordinator.streamvc.live.conf"

count="$(grep -c 'location \^~ /j/' "$config")"
test "$count" -eq 2
grep -A12 'location \^~ /j/' "$config" | grep -q 'access_log off;'
grep -A12 'location \^~ /j/' "$config" | grep -q 'proxy_pass http://127.0.0.1:8443;'
grep -A12 'location \^~ /j/' "$config" | grep -q 'return 301 https://\$host\$request_uri;'

echo "nginx referral route checks passed"

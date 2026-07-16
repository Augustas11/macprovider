#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config="$root/dist/nginx-coordinator.streamvc.live.conf"

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

echo "nginx referral route checks passed"

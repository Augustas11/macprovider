#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config="$root/dist/nginx-coordinator.malibu.tech.conf"

test "$(grep -c 'location = /v1/enroll' "$config")" -eq 1
enroll_block="$(grep -A18 'location = /v1/enroll' "$config")"
grep -q 'proxy_pass http://127.0.0.1:8443/v1/enroll;' <<<"$enroll_block"
grep -q 'client_max_body_size 4k;' <<<"$enroll_block"
grep -q 'add_header Cache-Control "no-store" always;' <<<"$enroll_block"

enroll_line="$(grep -nE '^[[:space:]]*location = /v1/enroll' "$config" | cut -d: -f1)"
catchall_line="$(grep -nE '^[[:space:]]*location[[:space:]]+/v1/[[:space:]]*[{]' "$config" | cut -d: -f1)"
test "$enroll_line" -lt "$catchall_line"

test "$(grep -c 'location /mdm/' "$config")" -eq 1
mdm_block="$(grep -A14 'location /mdm/' "$config")"
grep -q 'proxy_pass http://127.0.0.1:8080;' <<<"$mdm_block"
grep -q 'proxy_set_header X-Forwarded-Proto \$scheme;' <<<"$mdm_block"

test "$(grep -c 'location = /scep' "$config")" -eq 1
scep_block="$(grep -A12 'location = /scep' "$config")"
grep -q 'proxy_pass http://127.0.0.1:8080/scep;' <<<"$scep_block"

echo "nginx MDM enroll route checks passed"

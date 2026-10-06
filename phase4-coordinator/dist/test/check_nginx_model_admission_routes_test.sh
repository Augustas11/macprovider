#!/usr/bin/env bash
# BYOM model-admission (SPEC-046/047) provider endpoints must reach the
# coordinator provider mux (8444) ahead of the /v1/ 404 catch-all. Pearl once
# carried this block only by hand; a vhost rewrite dropped it and every BYOM
# offer returned 404 (#1690 M1, 2026-10-06).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config="$root/dist/nginx-coordinator.malibu.tech.conf"
active="$(sed 's/[[:space:]]*#.*$//' "$config")"

test "$(grep -cE '^[[:space:]]*location[[:space:]]+/v1/provider/model-admission/[[:space:]]*[{]' <<<"$active")" -eq 1
block="$(grep -A8 -E '^[[:space:]]*location[[:space:]]+/v1/provider/model-admission/' <<<"$active")"
grep -qE '^[[:space:]]*proxy_pass http://127\.0\.0\.1:8444;' <<<"$block"
grep -q 'proxy_set_header Authorization \$http_authorization;' <<<"$block"

route_line="$(grep -nE '^[[:space:]]*location[[:space:]]+/v1/provider/model-admission/' <<<"$active" | cut -d: -f1)"
catchall_line="$(grep -nE '^[[:space:]]*location[[:space:]]+/v1/[[:space:]]*[{]' <<<"$active" | cut -d: -f1)"
test "$route_line" -lt "$catchall_line"

echo "nginx BYOM model-admission route checks passed"

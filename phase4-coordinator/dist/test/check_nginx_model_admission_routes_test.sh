#!/usr/bin/env bash
# BYOM model-admission (SPEC-046/047) provider endpoints must reach the
# coordinator provider mux (8444) ahead of the /v1/ 404 catch-all. Pearl once
# carried this block only by hand; a vhost rewrite dropped it and every BYOM
# offer returned 404 (#1690 M1, 2026-10-06).
#
# Usage: check_nginx_model_admission_routes_test.sh [vhost-config]
# The default is the repo template. deploy-pearl-vps.sh passes the exact
# vhost file it uploads, so a stale pinned vhost fails the deploy pre-upload.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config="${1:-$root/dist/nginx-coordinator.malibu.tech.conf}"
test -f "$config" || { echo "FAIL: $config: missing" >&2; exit 1; }
active="$(sed 's/[[:space:]]*#.*$//' "$config")"

test "$(grep -cE '^[[:space:]]*location[[:space:]]+/v1/provider/model-admission/[[:space:]]*[{]' <<<"$active")" -eq 1
block="$(grep -A8 -E '^[[:space:]]*location[[:space:]]+/v1/provider/model-admission/' <<<"$active")"
grep -qE '^[[:space:]]*proxy_pass http://127\.0\.0\.1:8444;' <<<"$block"
grep -q 'proxy_set_header Authorization \$http_authorization;' <<<"$block"

route_line="$(grep -nE '^[[:space:]]*location[[:space:]]+/v1/provider/model-admission/' <<<"$active" | cut -d: -f1)"
catchall_line="$(grep -nE '^[[:space:]]*location[[:space:]]+/v1/[[:space:]]*[{]' <<<"$active" | cut -d: -f1)"
test "$route_line" -lt "$catchall_line"

# Repo mode also pins the deploy wiring: the pre-upload gate checks the
# uploaded vhost, not the template.
if [ "$#" -eq 0 ]; then
  grep -qE '^bash "\$DIST_DIR/test/check_nginx_model_admission_routes_test\.sh" "\$NGINX_SITE" \|\| \{' \
    "$root/dist/deploy-pearl-vps.sh"
fi

echo "nginx BYOM model-admission route checks passed ($config)"

#!/usr/bin/env bash
# check_nginx_catalog_routes_test.sh — assert SPEC-015 v0.3 §M.4 catalog
# routes are present in the coordinator nginx conf.
#
# The /catalog/ block must be declared BEFORE the catch-all `location /`
# 404 block, mirroring the /v1/receipt-keys/ shape PR #129 landed for
# v0.2. This script is the static counterpart to the in-coordinator
# unit tests at internal/buyer/catalog_endpoints_test.go.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
NGINX_CONF="$REPO_ROOT/phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf"

FAIL=0
fail() { echo "FAIL: $1" >&2; FAIL=1; }
ok()   { echo "ok: $1"; }

if [ ! -f "$NGINX_CONF" ]; then
  fail "$NGINX_CONF: missing"
  exit "$FAIL"
fi

# Strip comments before scanning so a commented-out block does not pass.
ACTIVE="$(sed 's/[[:space:]]*#.*$//' "$NGINX_CONF")"

if ! grep -qE '^[[:space:]]*location[[:space:]]+/catalog/[[:space:]]+\{' <<<"$ACTIVE"; then
  fail "missing active 'location /catalog/ { ... }' block"
fi

if ! grep -qE '^[[:space:]]*location[[:space:]]+=[[:space:]]+/v1/pool/check[[:space:]]+\{' <<<"$ACTIVE"; then
  fail "missing active 'location = /v1/pool/check { ... }' block"
fi

if ! grep -qE '^[[:space:]]*location[[:space:]]+=[[:space:]]+/v1/autotune-release[[:space:]]+\{' <<<"$ACTIVE"; then
  fail "missing active 'location = /v1/autotune-release { ... }' block"
fi

AUTOTUNE_RELEASE_PROXY=$(awk '
  /^[[:space:]]*location[[:space:]]+=[[:space:]]+\/v1\/autotune-release[[:space:]]+\{/ { in_block=1; depth=1; next }
  in_block {
    nopen=gsub(/\{/, "{")
    nclose=gsub(/\}/, "}")
    depth += nopen - nclose
    if ($0 ~ /proxy_pass[[:space:]]+/) { print }
    if (depth == 0) { in_block=0 }
  }
' <<<"$ACTIVE")
expected_autotune_release_proxy='proxy_pass http://127.0.0.1:8443/v1/autotune-release$is_args$args'
if ! grep -Fq "$expected_autotune_release_proxy" <<<"$AUTOTUNE_RELEASE_PROXY"; then
  fail "/v1/autotune-release block proxy_pass is not $expected_autotune_release_proxy; got: $(echo "$AUTOTUNE_RELEASE_PROXY" | tr -d '\n' | head -c 200)"
fi
AUTOTUNE_RELEASE_PROXY_COUNT=$(grep -cE 'proxy_pass[[:space:]]+' <<<"$AUTOTUNE_RELEASE_PROXY" || true)
if [ "$AUTOTUNE_RELEASE_PROXY_COUNT" -ne 1 ]; then
  fail "/v1/autotune-release block has $AUTOTUNE_RELEASE_PROXY_COUNT proxy_pass directives, want exactly 1"
fi

POOL_CHECK_PROXY=$(awk '
  /^[[:space:]]*location[[:space:]]+=[[:space:]]+\/v1\/pool\/check[[:space:]]+\{/ { in_block=1; depth=1; next }
  in_block {
    nopen=gsub(/\{/, "{")
    nclose=gsub(/\}/, "}")
    depth += nopen - nclose
    if ($0 ~ /proxy_pass[[:space:]]+/) { print }
    if (depth == 0) { in_block=0 }
  }
' <<<"$ACTIVE")
expected_pool_proxy='proxy_pass http://127.0.0.1:8443/v1/pool/check$is_args$args'
if ! grep -Fq "$expected_pool_proxy" <<<"$POOL_CHECK_PROXY"; then
  fail "/v1/pool/check block proxy_pass is not $expected_pool_proxy; got: $(echo "$POOL_CHECK_PROXY" | tr -d '\n' | head -c 200)"
fi
POOL_PROXY_COUNT=$(grep -cE 'proxy_pass[[:space:]]+' <<<"$POOL_CHECK_PROXY" || true)
if [ "$POOL_PROXY_COUNT" -ne 1 ]; then
  fail "/v1/pool/check block has $POOL_PROXY_COUNT proxy_pass directives, want exactly 1"
fi

# Scope the proxy_pass assertion to the body of the /catalog/ block
# ONLY. A repo-wide grep would false-pass because the v0.2
# /v1/receipt-keys/ block already proxies to 127.0.0.1:8443; a
# regression that changed the new block to proxy to 8444 (operator
# port) would slip past a loose check.
CATALOG_PROXY=$(awk '
  /^[[:space:]]*location[[:space:]]+\/catalog\/[[:space:]]+\{/ { in_block=1; depth=1; next }
  in_block {
    nopen=gsub(/\{/, "{")
    nclose=gsub(/\}/, "}")
    depth += nopen - nclose
    if ($0 ~ /proxy_pass[[:space:]]+/) { print }
    if (depth == 0) { in_block=0 }
  }
' <<<"$ACTIVE")
if ! grep -qE 'proxy_pass[[:space:]]+http://127\.0\.0\.1:8443' <<<"$CATALOG_PROXY"; then
  fail "/catalog/ block proxy_pass is not 127.0.0.1:8443 (buyer port); got: $(echo "$CATALOG_PROXY" | tr -d '\n' | head -c 200)"
fi
# A second proxy_pass inside /catalog/ would be a config error
# (nginx would reject); fail closed if anything other than the
# single buyer-port directive is present.
PROXY_COUNT=$(grep -cE 'proxy_pass[[:space:]]+' <<<"$CATALOG_PROXY" || true)
if [ "$PROXY_COUNT" -ne 1 ]; then
  fail "/catalog/ block has $PROXY_COUNT proxy_pass directives, want exactly 1"
fi

# Ordering: /catalog/ block must precede the catch-all
# `location / { return 404; }` block in the TLS server. There are
# two `location /` lines in the conf — the port-80 → 443 redirect
# (always declared before any /catalog/), and the TLS catch-all
# 404. We anchor on the LAST `location / {` whose body matches
# `return 404` (the actual catch-all). Fail closed if no catch-all
# is found — the ordering invariant cannot be asserted without it.
CATALOG_LINE=$(grep -nE '^[[:space:]]*location[[:space:]]+/catalog/' <<<"$ACTIVE" | head -1 | cut -d: -f1)
POOL_CHECK_LINE=$(grep -nE '^[[:space:]]*location[[:space:]]+=[[:space:]]+/v1/pool/check' <<<"$ACTIVE" | head -1 | cut -d: -f1)
AUTOTUNE_RELEASE_LINE=$(grep -nE '^[[:space:]]*location[[:space:]]+=[[:space:]]+/v1/autotune-release' <<<"$ACTIVE" | head -1 | cut -d: -f1)
CATCHALL_LINE=$(awk '/^[[:space:]]*location[[:space:]]+\/[[:space:]]+\{/ { saved=NR; next } saved && /^[[:space:]]*return[[:space:]]+404/ { print saved; saved=0 }' <<<"$ACTIVE" | tail -1)
V1_CATCHALL_LINE=$(grep -nE '^[[:space:]]*location[[:space:]]+/v1/[[:space:]]+\{' <<<"$ACTIVE" | tail -1 | cut -d: -f1)
if [ -z "$CATCHALL_LINE" ]; then
  fail "TLS catch-all 'location / { return 404; }' block not found — nginx conf shape changed; the catalog-route ordering assertion would silently pass without this anchor"
elif [ -n "$CATALOG_LINE" ] && [ "$CATALOG_LINE" -gt "$CATCHALL_LINE" ]; then
  fail "/catalog/ block (line $CATALOG_LINE) declared AFTER the catch-all location / { return 404 } block (line $CATCHALL_LINE)"
fi
if [ -n "$POOL_CHECK_LINE" ] && [ "$POOL_CHECK_LINE" -gt "$CATCHALL_LINE" ]; then
  fail "/v1/pool/check block (line $POOL_CHECK_LINE) declared AFTER the catch-all location / { return 404 } block (line $CATCHALL_LINE)"
fi
if [ -z "$V1_CATCHALL_LINE" ]; then
  fail "catch-all 'location /v1/ { return 404; }' block not found"
elif [ -n "$AUTOTUNE_RELEASE_LINE" ] && [ "$AUTOTUNE_RELEASE_LINE" -gt "$V1_CATCHALL_LINE" ]; then
  fail "/v1/autotune-release block (line $AUTOTUNE_RELEASE_LINE) declared AFTER the /v1/ catch-all block (line $V1_CATCHALL_LINE)"
fi

if [ "$FAIL" -eq 0 ]; then
  ok "coordinator public catalog and pool-check routes present in nginx conf"
fi
exit "$FAIL"

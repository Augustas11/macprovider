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

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

if [ ! -f "$NGINX_CONF" ]; then
  fail "$NGINX_CONF: missing"
  exit "$FAIL"
fi

# Strip comments before scanning so a commented-out block does not pass.
# Normalize compact nginx syntax before the line/depth scans below:
# `location / { return 301; } location ~ ... { ... }` must be seen as
# separate records, not one allowed line with hidden trailing directives.
CONF_ACTIVE="$(sed 's/[[:space:]]*#.*$//' "$NGINX_CONF" | awk '{ gsub(/[{};]/, "&\n"); print }')"
ACTIVE="$(awk '
  function listen_has_port(line, port, parts, n, i, token) {
    sub(/^[[:space:]]*listen[[:space:]]+/, "", line)
    sub(/[[:space:]]*;[[:space:]]*$/, "", line)
    n=split(line, parts, /[[:space:]]+/)
    for (i=1; i<=n; i++) {
      token=parts[i]
      if (token == port || token ~ ":" port "$") { return 1 }
    }
    return 0
  }
  function server_name_has(line, name, parts, n, i) {
    sub(/^[[:space:]]*server_name[[:space:]]+/, "", line)
    sub(/[[:space:]]*;[[:space:]]*$/, "", line)
    n=split(line, parts, /[[:space:]]+/)
    for (i=1; i<=n; i++) {
      if (parts[i] == name) { return 1 }
    }
    return 0
  }
  /^[[:space:]]*server[[:space:]]*\{/ {
    in_server=1
    depth=1
    block=$0 ORS
    tls=0
    name=0
    next
  }
  in_server {
    block = block $0 ORS
    if ($0 ~ /^[[:space:]]*listen[[:space:]]/ && listen_has_port($0, "443") && $0 ~ /(^|[[:space:]])ssl([[:space:]]|;|$)/) { tls=1 }
    if ($0 ~ /^[[:space:]]*server_name[[:space:]]/ && server_name_has($0, "coordinator.streamvc.live")) { name=1 }
    nopen=gsub(/\{/, "{")
    nclose=gsub(/\}/, "}")
    depth += nopen - nclose
    if (depth == 0) {
      if (tls && name) { print block }
      in_server=0
      block=""
    }
  }
' <<<"$CONF_ACTIVE")"
COORDINATOR_TLS_SERVER_COUNT=$(grep -cE '^[[:space:]]*server[[:space:]]*\{' <<<"$ACTIVE" || true)
HTTP_ACTIVE="$(awk '
  function listen_has_port(line, port, parts, n, i, token) {
    sub(/^[[:space:]]*listen[[:space:]]+/, "", line)
    sub(/[[:space:]]*;[[:space:]]*$/, "", line)
    n=split(line, parts, /[[:space:]]+/)
    for (i=1; i<=n; i++) {
      token=parts[i]
      if (token == port || token ~ ":" port "$") { return 1 }
    }
    return 0
  }
  function server_name_has(line, name, parts, n, i) {
    sub(/^[[:space:]]*server_name[[:space:]]+/, "", line)
    sub(/[[:space:]]*;[[:space:]]*$/, "", line)
    n=split(line, parts, /[[:space:]]+/)
    for (i=1; i<=n; i++) {
      if (parts[i] == name) { return 1 }
    }
    return 0
  }
  /^[[:space:]]*server[[:space:]]*\{/ {
    in_server=1
    depth=1
    block=$0 ORS
    port80=0
    tls=0
    name=0
    next
  }
  in_server {
    block = block $0 ORS
    if ($0 ~ /^[[:space:]]*listen[[:space:]]/ && listen_has_port($0, "80")) { port80=1 }
    if ($0 ~ /^[[:space:]]*listen[[:space:]]/ && $0 ~ /(^|[[:space:]])ssl([[:space:]]|;|$)/) { tls=1 }
    if ($0 ~ /^[[:space:]]*server_name[[:space:]]/ && server_name_has($0, "coordinator.streamvc.live")) { name=1 }
    nopen=gsub(/\{/, "{")
    nclose=gsub(/\}/, "}")
    depth += nopen - nclose
    if (depth == 0) {
      if (port80 && !tls && name) { print block }
      in_server=0
      block=""
    }
  }
' <<<"$CONF_ACTIVE")"
COORDINATOR_HTTP_SERVER_COUNT=$(grep -cE '^[[:space:]]*server[[:space:]]*\{' <<<"$HTTP_ACTIVE" || true)
HTTP_CONTEXT_DIRECTIVES="$(awk '
  /^[[:space:]]*server[[:space:]]*\{/ {
    in_server=1
    depth=1
    next
  }
  in_server {
    line=$0
    nopen=gsub(/\{/, "{", line)
    nclose=gsub(/\}/, "}", line)
    depth += nopen - nclose
    if (depth == 0) { in_server=0 }
    next
  }
  NF { print }
' <<<"$CONF_ACTIVE")"

if [ "$COORDINATOR_TLS_SERVER_COUNT" -eq 0 ]; then
  fail "TLS server block for coordinator.streamvc.live not found"
elif [ "$COORDINATOR_TLS_SERVER_COUNT" -ne 1 ]; then
  fail "expected exactly one coordinator.streamvc.live TLS server block, found $COORDINATOR_TLS_SERVER_COUNT"
fi
if [ "$COORDINATOR_HTTP_SERVER_COUNT" -eq 0 ]; then
  fail "port-80 server block for coordinator.streamvc.live not found"
elif [ "$COORDINATOR_HTTP_SERVER_COUNT" -ne 1 ]; then
  fail "expected exactly one coordinator.streamvc.live port-80 server block, found $COORDINATOR_HTTP_SERVER_COUNT"
fi

extract_server_scope_directives() {
  awk '
    function trim_awk(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function flush_directive() {
      if (directive == "") { return }
      if (directive !~ /^location([[:space:]]|=|~|\^~|$)/) { print directive }
      directive=""
    }
    function append_depth1_directive(line, t) {
      t=trim_awk(line)
      if (t == "" || t ~ /^}/) { return }
      directive = directive == "" ? t : directive " " t
      if (t ~ /;[[:space:]]*$/ || t ~ /\{[[:space:]]*$/) { flush_directive() }
    }
    NR == 1 {
      depth=1
      line=$0
      sub(/^[^{]*\{/, "", line)
      append_depth1_directive(line)
      next
    }
    {
      line=$0
      if (depth == 1) { append_depth1_directive(line) }
      nopen=gsub(/\{/, "{", line)
      nclose=gsub(/\}/, "}", line)
      depth += nopen - nclose
    }
    END { flush_directive() }
  '
}
TLS_SERVER_DIRECTIVES="$(extract_server_scope_directives <<<"$ACTIVE")"
HTTP_SERVER_DIRECTIVES="$(extract_server_scope_directives <<<"$HTTP_ACTIVE")"

if ! grep -qE '^[[:space:]]*location[[:space:]]+/catalog/[[:space:]]+\{' <<<"$ACTIVE"; then
  fail "missing active 'location /catalog/ { ... }' block"
fi

if ! grep -qE '^[[:space:]]*location[[:space:]]+=[[:space:]]+/v1/pool/check[[:space:]]+\{' <<<"$ACTIVE"; then
  fail "missing active 'location = /v1/pool/check { ... }' block"
fi

if ! grep -qE '^[[:space:]]*location[[:space:]]+=[[:space:]]+/v1/autotune-release[[:space:]]+\{' <<<"$ACTIVE"; then
  fail "missing active 'location = /v1/autotune-release { ... }' block"
fi

SIGNED_FEED_ROUTES=(
  /v1/rate-card
  /v1/rate-card.sig
  /v1/demand-rank
  /v1/demand-rank.sig
  /v1/autotune-candidates
  /v1/autotune-candidates.sig
)

extract_exact_location_body() {
  local path="$1"
  awk -v path="$path" '
    !in_block {
      if ($1 == "location" && $2 == "=" && $3 == path && $4 == "{") {
        in_block=1
        depth=1
        line=$0
        sub(/^[^{]*\{/, "", line)
        if (line !~ /^[[:space:]]*$/) { print line }
      }
      next
    }
    in_block {
      line=$0
      nopen=gsub(/\{/, "{", line)
      nclose=gsub(/\}/, "}", line)
      next_depth = depth + nopen - nclose
      if (next_depth > 0) { print $0 }
      depth = next_depth
      if (depth == 0) { in_block=0 }
    }
  ' <<<"$ACTIVE"
}

extract_exact_location_proxy() {
  local path="$1"
  extract_exact_location_body "$path" | grep -E '^[[:space:]]*proxy_pass[[:space:]]+' || true
}

extract_http_root_location_body() {
  awk '
    !in_block {
      if ($1 == "location" && $2 == "/" && $3 == "{") {
        in_block=1
        depth=1
        line=$0
        sub(/^[^{]*\{/, "", line)
        if (line !~ /^[[:space:]]*$/) { print line }
      }
      next
    }
    in_block {
      line=$0
      nopen=gsub(/\{/, "{", line)
      nclose=gsub(/\}/, "}", line)
      next_depth = depth + nopen - nclose
      if (next_depth > 0) { print $0 }
      depth = next_depth
      if (depth == 0) { in_block=0 }
    }
  ' <<<"$HTTP_ACTIVE"
}

escape_location_path() {
  sed "s/[.[\\*^\\$()+?{}|\\\\/]/\\\\&/g" <<<"$1"
}

forbidden_nginx_policy_directives() {
  tr ';' '\n' | grep -E '^[[:space:]]*(auth_request|auth_basic|auth_basic_user_file|satisfy|allow|deny|proxy_cache|proxy_cache_valid|proxy_cache_use_stale|include)([[:space:]]|$)' || true
}

forbidden_nginx_routing_directives() {
  tr ';' '\n' | grep -E '^[[:space:]]*(return|rewrite|if|error_page)([[:space:]]|$|\()' || true
}

assert_port80_server_directive_allowlist() {
  local line
  local trimmed
  while IFS= read -r line; do
    trimmed="$(trim "$line")"
    [ -z "$trimmed" ] && continue
    case "$trimmed" in
      "listen 80;" | \
      "listen [::]:80;" | \
      "server_name coordinator.streamvc.live;")
        ;;
      *)
        fail "port-80 server block contains unexpected server-level directive; keep port-80 behavior in explicit validated locations; got: $(echo "$trimmed" | head -c 200)"
        ;;
    esac
  done <<<"$HTTP_SERVER_DIRECTIVES"
}

assert_exact_location_line() {
  local path="$1"
  local body="$2"
  local expected="$3"
  local label="$4"
  local count
  count=$(while IFS= read -r line; do
    if [ "$(trim "$line")" = "$expected" ]; then
      printf 'x\n'
    fi
  done <<<"$body" | wc -l | tr -d '[:space:]')
  if [ "$count" -ne 1 ]; then
    fail "$path block has $count exact $label directives, want exactly 1: $expected"
  fi
}

assert_signed_feed_body_allowlist() {
  local path="$1"
  local body="$2"
  local expected_proxy="proxy_pass http://127.0.0.1:8443$path\$is_args\$args;"
  local line
  local trimmed
  while IFS= read -r line; do
    trimmed="$(trim "$line")"
    [ -z "$trimmed" ] && continue
    case "$trimmed" in
      "$expected_proxy" | \
      "proxy_set_header Host \$host;" | \
      "proxy_set_header X-Real-IP \$remote_addr;" | \
      "proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;" | \
      "proxy_set_header X-Forwarded-Proto \$scheme;" | \
      "proxy_read_timeout 10s;")
        ;;
      *)
        fail "$path block contains unexpected directive outside the signed-feed proxy allowlist; got: $(echo "$trimmed" | head -c 200)"
        ;;
    esac
  done <<<"$body"
}

assert_exact_v1_buyer_route() {
  local path="$1"
  local escaped_path
  escaped_path="$(escape_location_path "$path")"
  if ! grep -qE "^[[:space:]]*location[[:space:]]+=[[:space:]]+${escaped_path}[[:space:]]+\\{" <<<"$ACTIVE"; then
    fail "missing active 'location = $path { ... }' block"
    return
  fi

  local proxy
  proxy="$(extract_exact_location_proxy "$path")"
  local body
  body="$(extract_exact_location_body "$path")"
  local proxy_count
  proxy_count=$(grep -cE 'proxy_pass[[:space:]]+' <<<"$proxy" || true)
  if [ "$proxy_count" -ne 1 ]; then
    fail "$path block has $proxy_count proxy_pass directives, want exactly 1"
  fi
  local expected_proxy="proxy_pass http://127.0.0.1:8443$path\$is_args\$args;"
  local actual_proxy
  actual_proxy="$(trim "$proxy")"
  if [ "$actual_proxy" != "$expected_proxy" ]; then
    fail "$path block proxy_pass is not exactly: $expected_proxy got: $(echo "$actual_proxy" | tr -d '\n' | head -c 200)"
  fi
  assert_exact_location_line "$path" "$body" "proxy_set_header Host \$host;" 'Host header'
  assert_exact_location_line "$path" "$body" "proxy_set_header X-Real-IP \$remote_addr;" 'X-Real-IP header'
  assert_exact_location_line "$path" "$body" "proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;" 'X-Forwarded-For header'
  assert_exact_location_line "$path" "$body" "proxy_set_header X-Forwarded-Proto \$scheme;" 'X-Forwarded-Proto header'
  assert_exact_location_line "$path" "$body" "proxy_read_timeout 10s;" 'proxy_read_timeout'
  assert_signed_feed_body_allowlist "$path" "$body"
  local forbidden_policy
  forbidden_policy="$(forbidden_nginx_policy_directives <<<"$body")"
  if [ -n "$forbidden_policy" ]; then
    fail "$path block contains auth/cache/access policy directives; got: $(echo "$forbidden_policy" | tr -d '\n' | head -c 200)"
  fi
}

server_forbidden_policy="$(forbidden_nginx_policy_directives <<<"$TLS_SERVER_DIRECTIVES")"
if [ -n "$server_forbidden_policy" ]; then
  fail "TLS server block contains inherited auth/cache/access policy directives for public signed feeds; got: $(echo "$server_forbidden_policy" | tr -d '\n' | head -c 200)"
fi
server_forbidden_routing="$(forbidden_nginx_routing_directives <<<"$TLS_SERVER_DIRECTIVES")"
if [ -n "$server_forbidden_routing" ]; then
  fail "TLS server block contains inherited return/rewrite/if routing directives that can bypass public signed feeds; got: $(echo "$server_forbidden_routing" | tr -d '\n' | head -c 200)"
fi
http_context_forbidden_policy="$(forbidden_nginx_policy_directives <<<"$HTTP_CONTEXT_DIRECTIVES")"
if [ -n "$http_context_forbidden_policy" ]; then
  fail "top-level nginx http-context directives contain inherited auth/cache/access policy for public signed feeds; got: $(echo "$http_context_forbidden_policy" | tr -d '\n' | head -c 200)"
fi
http_context_forbidden_routing="$(forbidden_nginx_routing_directives <<<"$HTTP_CONTEXT_DIRECTIVES")"
if [ -n "$http_context_forbidden_routing" ]; then
  fail "top-level nginx http-context directives contain return/rewrite/if routing policy that can bypass public signed feeds; got: $(echo "$http_context_forbidden_routing" | tr -d '\n' | head -c 200)"
fi
http_server_forbidden_routing="$(forbidden_nginx_routing_directives <<<"$HTTP_SERVER_DIRECTIVES")"
if [ -n "$http_server_forbidden_routing" ]; then
  fail "port-80 server block contains server-level return/rewrite/if routing directives; keep redirects inside the validated location / block; got: $(echo "$http_server_forbidden_routing" | tr -d '\n' | head -c 200)"
fi
http_server_forbidden_policy="$(forbidden_nginx_policy_directives <<<"$HTTP_SERVER_DIRECTIVES")"
if [ -n "$http_server_forbidden_policy" ]; then
  fail "port-80 server block contains server-level auth/cache/access/include policy directives; keep port-80 behavior in explicit validated locations; got: $(echo "$http_server_forbidden_policy" | tr -d '\n' | head -c 200)"
fi
assert_port80_server_directive_allowlist

if [ -n "$HTTP_ACTIVE" ]; then
  http_location_lines="$(grep -E '^[[:space:]]*location[[:space:]]+' <<<"$HTTP_ACTIVE" || true)"
  while IFS= read -r location_line; do
    [ -z "$location_line" ] && continue
    if ! grep -qE '^[[:space:]]*location[[:space:]]+/\.well-known/acme-challenge/[[:space:]]+\{' <<<"$location_line" &&
       ! grep -qE '^[[:space:]]*location[[:space:]]+\^~[[:space:]]+/j/[[:space:]]+\{' <<<"$location_line" &&
       ! grep -qE '^[[:space:]]*location[[:space:]]+/[[:space:]]+\{' <<<"$location_line"; then
      fail "unexpected location in port-80 redirect server; only ACME, /j/, and redirect / are allowed; got: $(echo "$location_line" | head -c 200)"
    fi
  done <<<"$http_location_lines"
  if grep -qE '^[[:space:]]*(proxy_pass|rewrite)[[:space:]]+' <<<"$HTTP_ACTIVE"; then
    fail "port-80 server contains proxy/rewrite directives; only ACME, /j/ tombstone, and HTTPS redirect locations are allowed"
  fi
  http_root_body="$(extract_http_root_location_body)"
  http_root_return_count=$(while IFS= read -r line; do
    if [ "$(trim "$line")" = "return 301 https://\$host\$request_uri;" ]; then
      printf 'x\n'
    fi
  done <<<"$http_root_body" | wc -l | tr -d '[:space:]')
  if [ "$http_root_return_count" -ne 1 ]; then
    fail "port-80 redirect location / must contain exactly one canonical HTTPS redirect"
  fi
  while IFS= read -r line; do
    trimmed="$(trim "$line")"
    [ -z "$trimmed" ] && continue
    if [ "$trimmed" != "return 301 https://\$host\$request_uri;" ]; then
      fail "port-80 redirect location / contains unexpected directive; got: $(echo "$trimmed" | head -c 200)"
    fi
  done <<<"$http_root_body"
fi
for route in "${SIGNED_FEED_ROUTES[@]}"; do
  assert_exact_v1_buyer_route "$route"
done

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
AUTOTUNE_RELEASE_PROXY_COUNT=$(grep -cE 'proxy_pass[[:space:]]+' <<<"$AUTOTUNE_RELEASE_PROXY" || true)
if [ "$AUTOTUNE_RELEASE_PROXY_COUNT" -ne 1 ]; then
  fail "/v1/autotune-release block has $AUTOTUNE_RELEASE_PROXY_COUNT proxy_pass directives, want exactly 1"
fi
expected_autotune_release_proxy="proxy_pass http://127.0.0.1:8443/v1/autotune-release\$is_args\$args;"
actual_autotune_release_proxy="$(trim "$AUTOTUNE_RELEASE_PROXY")"
if [ "$actual_autotune_release_proxy" != "$expected_autotune_release_proxy" ]; then
  fail "/v1/autotune-release block proxy_pass is not exactly: $expected_autotune_release_proxy got: $(echo "$actual_autotune_release_proxy" | tr -d '\n' | head -c 200)"
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
POOL_PROXY_COUNT=$(grep -cE 'proxy_pass[[:space:]]+' <<<"$POOL_CHECK_PROXY" || true)
if [ "$POOL_PROXY_COUNT" -ne 1 ]; then
  fail "/v1/pool/check block has $POOL_PROXY_COUNT proxy_pass directives, want exactly 1"
fi
expected_pool_proxy="proxy_pass http://127.0.0.1:8443/v1/pool/check\$is_args\$args;"
actual_pool_proxy="$(trim "$POOL_CHECK_PROXY")"
if [ "$actual_pool_proxy" != "$expected_pool_proxy" ]; then
  fail "/v1/pool/check block proxy_pass is not exactly: $expected_pool_proxy got: $(echo "$actual_pool_proxy" | tr -d '\n' | head -c 200)"
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

# Ordering: inside the TLS server, public route blocks must precede the
# catch-all `location / { return 404; }` and `/v1/` deny blocks. Fail
# closed if no catch-all is found — the ordering invariant cannot be
# asserted without those anchors.
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
if [ -n "$V1_CATCHALL_LINE" ]; then
  for route in "${SIGNED_FEED_ROUTES[@]}"; do
    escaped_route="$(escape_location_path "$route")"
    route_line=$(grep -nE "^[[:space:]]*location[[:space:]]+=[[:space:]]+${escaped_route}[[:space:]]+\\{" <<<"$ACTIVE" | head -1 | cut -d: -f1)
    if [ -n "$route_line" ] && [ "$route_line" -gt "$V1_CATCHALL_LINE" ]; then
      fail "$route block (line $route_line) declared AFTER the /v1/ catch-all block (line $V1_CATCHALL_LINE)"
    fi
  done
fi

if [ "$FAIL" -eq 0 ]; then
  ok "coordinator public catalog, pool-check, and signed feed routes present in nginx conf"
fi
exit "$FAIL"

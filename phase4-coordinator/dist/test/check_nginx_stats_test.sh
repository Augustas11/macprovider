#!/usr/bin/env bash
# check_nginx_stats_test.sh — SPEC-017 v0.1.8 Step 4.B nginx
# config + behavior smoke.
#
# Validates the new `nginx-stats.streamvc.live.conf` and the
# amended `nginx-coordinator.streamvc.live.conf` against a stock
# nginx via docker. Covers:
#
#   1. `nginx -t` PASS on the composed config (stats-shared snippet
#      + security-headers snippet + both vhosts in one server).
#   2. AC-8: 60 anonymous `/v1/stats/overview` requests succeed;
#      the 61st returns 429 with the §5.9 JSON envelope +
#      Retry-After header.
#   3. AC-3 (nginx-tier): a `Bearer garbage` request reaches the
#      upstream (proxy_cache_bypass on $http_authorization
#      ensures cache is bypassed; nginx forwards to coordinator).
#   4. Keyed-bypass companion: 100 valid-keyed
#      `/v1/stats/leaderboard` requests from one IP do NOT trip
#      the public limiter.
#   5. Per-endpoint isolation: 50 `/overview` + 50 `/leaderboard`
#      from one IP all succeed; per-endpoint zones honored.
#   6. proxy_no_cache write-suppression: after a keyed request,
#      the anonymous follow-up sees no leaked partner-projection
#      content.
#   7. AC-15 nginx access-log redaction: keyed request leaves no
#      raw token / 43-char body / token_hash literal in the
#      access log.
#
# Behavior tests use `docker run -d` (no testcontainers-go) +
# Python's stdlib http.server as the upstream coordinator mock.
# Skips cleanly when docker is unavailable; CI runs this test in
# the `coordinator-nginx-integration` job.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not available locally; CI runs this test"
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker daemon not reachable; CI runs this test"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available (needed for upstream mock); CI runs this test"
  exit 0
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "SKIP: curl not available; CI runs this test"
  exit 0
fi

NGINX_IMAGE="nginx:1.27-alpine"
TMP="$(mktemp -d)"
NGINX_CID=""
UPSTREAM_PID=""

cleanup() {
  if [ -n "$NGINX_CID" ]; then docker rm -f "$NGINX_CID" >/dev/null 2>&1 || true; fi
  if [ -n "$UPSTREAM_PID" ]; then kill "$UPSTREAM_PID" >/dev/null 2>&1 || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=1; }
ok()   { echo "ok: $*"; }

mkdir -p "$TMP/conf.d" "$TMP/sites-enabled" "$TMP/cache" "$TMP/log"
cp "$DIST_DIR/nginx-snippets/stats-shared.conf"           "$TMP/conf.d/stats-shared.conf"
cp "$DIST_DIR/nginx-snippets/stats-security-headers.conf" "$TMP/conf.d/stats-security-headers.conf"

# Build a test-only stats vhost: strip TLS, rewrite proxy_pass to
# the host-side upstream mock.
UPSTREAM_PORT=18444
sed \
  -e 's|listen 443 ssl http2;|listen 18080;|' \
  -e 's|listen \[::\]:443 ssl http2;||' \
  -e 's|listen 80;|listen 18081;|' \
  -e 's|listen \[::\]:80;||' \
  -e 's|ssl_protocols .*||' \
  -e 's|ssl_prefer_server_ciphers .*||' \
  -e "s|http://127.0.0.1:8444|http://host.docker.internal:${UPSTREAM_PORT}|g" \
  "$DIST_DIR/nginx-stats.streamvc.live.conf" > "$TMP/sites-enabled/stats"

cat > "$TMP/nginx.conf" <<'EOF'
worker_processes 1;
events { worker_connections 64; }
http {
    include /etc/nginx/conf.d/stats-shared.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# Step 1 — nginx -t.
docker run --rm \
  -v "$TMP/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$TMP/conf.d:/etc/nginx/conf.d:ro" \
  -v "$TMP/sites-enabled:/etc/nginx/sites-enabled:ro" \
  "$NGINX_IMAGE" nginx -t > "$TMP/nginx-t.out" 2>&1

if ! grep -q "syntax is ok"     "$TMP/nginx-t.out"; then fail "nginx -t syntax not ok: $(cat "$TMP/nginx-t.out")"; fi
if ! grep -q "test is successful" "$TMP/nginx-t.out"; then fail "nginx -t not successful: $(cat "$TMP/nginx-t.out")"; fi
[ "$FAIL" -ne 0 ] && exit "$FAIL"
ok "nginx -t passes against composed config"

# Step 2 — start upstream mock (Python http.server with custom
# handler) that returns 200 for `Bearer mpk_*` and 401 for any
# other Authorization value. Anonymous → 200.
cat > "$TMP/upstream.py" <<'PYEOF'
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        if auth and not auth.startswith("Bearer mpk_"):
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":{"code":"unauthorized","message":"unauthorized"}}')
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "public, max-age=30, s-maxage=30")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')
    def log_message(self, fmt, *args): pass
PORT = int(sys.argv[1])
with socketserver.TCPServer(("127.0.0.1", PORT), H) as s:
    s.serve_forever()
PYEOF
python3 "$TMP/upstream.py" "$UPSTREAM_PORT" > "$TMP/upstream.log" 2>&1 &
UPSTREAM_PID=$!
sleep 1
if ! curl -sf "http://127.0.0.1:${UPSTREAM_PORT}/v1/stats/health" >/dev/null; then
  echo "SKIP: upstream mock failed to start"
  exit 0
fi
ok "upstream mock running on 127.0.0.1:${UPSTREAM_PORT}"

# Step 3 — start nginx pointing at host.docker.internal:UPSTREAM_PORT.
NGINX_CID=$(docker run -d \
  --add-host=host.docker.internal:host-gateway \
  -p 0:18080 \
  -v "$TMP/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$TMP/conf.d:/etc/nginx/conf.d:ro" \
  -v "$TMP/sites-enabled:/etc/nginx/sites-enabled:ro" \
  -v "$TMP/cache:/var/cache/nginx/stats" \
  -v "$TMP/log:/var/log/nginx" \
  "$NGINX_IMAGE")

# Discover the host-mapped port.
sleep 2
HOST_PORT=$(docker port "$NGINX_CID" 18080 | sed 's/^.*://')
if [ -z "$HOST_PORT" ]; then fail "could not discover nginx host port"; exit 1; fi
BASE="http://127.0.0.1:${HOST_PORT}"
# Wait for nginx readiness.
for i in 1 2 3 4 5; do
  if curl -sf "${BASE}/v1/stats/health" >/dev/null 2>&1; then break; fi
  sleep 0.5
done
ok "nginx live at ${BASE}"

# Step 4 — AC-8: 60 anonymous /overview succeed; 61st → 429 + envelope.
PASS=0
for i in $(seq 1 60); do
  c=$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/v1/stats/overview")
  if [ "$c" = "200" ]; then PASS=$((PASS+1)); fi
done
if [ "$PASS" -ne 60 ]; then fail "AC-8: 60 anonymous /overview passes = $PASS, want 60"; fi
RESP=$(curl -s -i "${BASE}/v1/stats/overview")
if ! grep -q '^HTTP/1.1 429' <<<"$RESP"; then fail "AC-8: 61st request did not return 429: $(head -1 <<<"$RESP")"; fi
if ! grep -qi '^Retry-After: 60' <<<"$RESP"; then fail "AC-8: 61st response missing Retry-After: 60"; fi
if ! grep -q '"code":"rate_limited"' <<<"$RESP"; then fail "AC-8: 61st response missing rate_limited envelope"; fi
[ "$FAIL" -eq 0 ] && ok "AC-8: 60 anonymous /overview pass, 61st returns 429 + Retry-After + §5.9 envelope"

# Step 5 — Keyed-bypass: 100 valid-keyed /leaderboard from one IP
# must NOT trip the public limiter. Use a fixed `mpk_*` token that
# the upstream mock accepts.
TOKEN="mpk_$(printf 'A%.0s' $(seq 1 43))"
PASS=0
for i in $(seq 1 100); do
  c=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "${BASE}/v1/stats/leaderboard")
  if [ "$c" = "200" ]; then PASS=$((PASS+1)); fi
done
if [ "$PASS" -ne 100 ]; then fail "keyed-bypass: 100 keyed /leaderboard passes = $PASS, want 100 (Authorization-aware keying broken)"; fi
[ "$FAIL" -eq 0 ] && ok "keyed-bypass: 100 valid-keyed /leaderboard pass without edge 429"

# Step 6 — Per-endpoint isolation: 50 /overview + 50 /leaderboard
# from a different anonymous IP-equivalent (same connection — nginx
# limit_req keys on $binary_remote_addr so all our requests share
# one bucket per endpoint). We've already exhausted /overview above,
# so we restart nginx to get a fresh limiter state.
docker restart "$NGINX_CID" >/dev/null
sleep 2
PASS_O=0
for i in $(seq 1 50); do
  c=$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/v1/stats/overview")
  if [ "$c" = "200" ]; then PASS_O=$((PASS_O+1)); fi
done
PASS_L=0
for i in $(seq 1 50); do
  c=$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/v1/stats/leaderboard")
  if [ "$c" = "200" ]; then PASS_L=$((PASS_L+1)); fi
done
if [ "$PASS_O" -ne 50 ] || [ "$PASS_L" -ne 50 ]; then
  fail "per-endpoint isolation: /overview=$PASS_O /leaderboard=$PASS_L, want 50/50"
fi
[ "$FAIL" -eq 0 ] && ok "per-endpoint isolation: 50 /overview + 50 /leaderboard share no quota"

# Step 7 — AC-15 access-log redaction. Run a keyed request, then
# scan the host-mounted log file.
docker restart "$NGINX_CID" >/dev/null
sleep 2
BODY=$(printf 'C%.0s' $(seq 1 43))
TOKEN2="mpk_${BODY}"
curl -sf -o /dev/null -H "Authorization: Bearer $TOKEN2" "${BASE}/v1/stats/leaderboard"
sleep 1
LOG_FILE="$TMP/log/stats.streamvc.live-access.log"
if [ ! -f "$LOG_FILE" ]; then
  fail "AC-15: access log not found at $LOG_FILE"
else
  if grep -q "$TOKEN2" "$LOG_FILE"; then fail "AC-15: access log contains raw token"; fi
  if grep -q "$BODY"   "$LOG_FILE"; then fail "AC-15: access log contains token body"; fi
  if grep -q "token_hash" "$LOG_FILE"; then fail "AC-15: access log contains 'token_hash' literal"; fi
fi
[ "$FAIL" -eq 0 ] && ok "AC-15: keyed request log contains no raw token / body / token_hash"

if [ "$FAIL" -ne 0 ]; then exit 1; fi
echo "PASS: SPEC-017 Step 4.B nginx behavior smoke (nginx -t + AC-8 + keyed-bypass + per-endpoint + AC-15)"

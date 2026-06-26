# SPEC-017 IMPL Step 4.B - Code Audit Round 3

Branch: `impl/spec-017-step-1`
HEAD audited: `ecc02ad049fdb0ade3b3539c0c6f1b59f3c66ce2`
Diff base checked: `51b9736`
Auditor lane: CODE
Prior rounds checked:
- `specs/SPEC-017-IMPL-STEP_4B-code-r1-audit.md`
- `specs/SPEC-017-IMPL-STEP_4B-code-r2-audit.md`
- `specs/SPEC-017-IMPL-STEP_4B-arch-r2-audit.md`

Verdict: NOT READY TO LOCK -
1 CRITICAL + 0 HIGH + 1 MEDIUM + 0 LOW + 12 INFO

## Validation evidence

- Required reading completed: `SPEC-017-network-stats-api.md` v0.1.8 sections 5.6, 5.7, 6.6.2, 7.1, 7.4, and 8.5; `BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.B and the AC-to-step matrix; `SPEC-017-IMPL-STEP_3-r8-convergence.md`; current coordinator/stats nginx files; Step 4.B CODE r1/r2; Step 4.B ARCH r2.
- `git fetch origin` completed; local branch is `impl/spec-017-step-1...origin/impl/spec-017-step-1`.
- `git diff --check 51b9736..HEAD -- phase4-coordinator/dist/ .github/workflows/ci.yml Makefile` - PASS.
- `rg -n '\$http_authorization|Authorization|limit_req_zone|limit_req |burst=|rate=|proxy_cache_path|proxy_cache |proxy_cache_bypass|proxy_no_cache|proxy_pass|client_max_body_size|access_log|log_format|ssl_protocols|ssl_certificate|Access-Control|Vary|error_page|listen 443' phase4-coordinator/dist/...` - scoped directive sweep completed.
- Static brace-depth check over `stats-shared.conf`, `stats-security-headers.conf`, `nginx-stats.streamvc.live.conf`, and `nginx-coordinator.streamvc.live.conf` - PASS, final brace depth 0.
- Local `nginx -t` was not directly executable: no local `nginx` binary.
- `docker info` - FAIL locally; Docker CLI exists, but the daemon socket is unavailable.
- `bash phase4-coordinator/dist/test/check_nginx_stats_test.sh` - SKIP, `docker daemon not reachable; CI runs this test`.
- `make test-dist` - PASS overall, but `check_nginx_stats_test.sh` skipped locally for the same Docker-daemon reason.
- Local sed simulation of the deploy-time stats-vhost certificate uncomment left `# ssl_certificate     /etc/letsencrypt/live/stats.streamvc.live/fullchain.pem;` commented while uncommenting `ssl_certificate_key`.

## Category verdicts

A. `nginx -t` compatibility: FAIL. Core stats directives are stock nginx, but the deploy path still enables a `listen 443 ssl` stats vhost with no active `ssl_certificate` because its sed pattern does not match the shipped padded directive line.

B. map directive correctness: PASS. `stats-shared.conf` declares `map $http_authorization $public_rl_key` before the three `limit_req_zone` declarations.

C. limit_req_zone declarations: PASS. `stats_overview`, `stats_leaderboard`, and `stats_health` are declared in the shared http-context snippet at `:10m` with `rate=60r/m`, and all stats locations reference matching names.

D. location block ordering: PASS. Coordinator exact stats locations precede `location /v1/ { return 404; }`.

E. proxy_pass posture: PASS. Stats locations proxy to `http://127.0.0.1:8444` without a URI suffix/trailing slash rewrite.

F. proxy_cache_path: PASS. Shared snippet declares `/var/cache/nginx/stats`, `levels=1:2`, `keys_zone=stats_public:10m`, `inactive=300s`; stats locations use `proxy_cache stats_public`.

G. proxy_cache_bypass + proxy_no_cache: PASS for config. Every stats location on both hostnames pairs `proxy_cache_bypass $http_authorization` with `proxy_no_cache $http_authorization`.

H. access-log format: PASS. `stats_redacted` omits `$http_authorization`, and the dedicated stats vhost uses it. No changed nginx log format includes `$http_authorization`.

I. Header forwarding: PASS. Stats locations forward Host, X-Real-IP, X-Forwarded-For, X-Forwarded-Proto, and Authorization.

J. HEAD method behavior: PASS. No method-specific nginx block intercepts HEAD; exact stats locations forward to the Step 3 mux.

K. TLS posture: FAIL. TLS protocol versions are correct, but deploy-time activation for `stats.streamvc.live` leaves the certificate directive commented.

L. Test harness: FAIL. The shell harness is now a real nginx+curl fixture when Docker is available, but it still does not drive the required AC-3 invalid-Bearer request and does not assert the declared `proxy_no_cache` write-suppression behavior.

## Findings

### CRITICAL

1. `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:54` and `phase4-coordinator/dist/deploy-pearl-vps.sh:427`
   - Evidence: the stats vhost ships `# ssl_certificate     /etc/letsencrypt/live/stats.streamvc.live/fullchain.pem;` with multiple spaces between `ssl_certificate` and the path.
   - Evidence: the deploy script tries to activate that line with `sed -i 's|# ssl_certificate /etc/letsencrypt|ssl_certificate /etc/letsencrypt|g' /etc/nginx/sites-available/$STATS_DOMAIN`, which requires exactly one space after `ssl_certificate`.
   - Evidence: local text simulation of the deploy sed left the certificate line commented and uncommented only `ssl_certificate_key`.
   - Why this is CRITICAL: the deployed stats vhost still has `listen 443 ssl http2;` but no active `ssl_certificate` directive. The final deploy `nginx -t` at `deploy-pearl-vps.sh:439` is therefore in the "config fails `nginx -t`" class unless Pearl happens to carry an unsupported out-of-band inherited certificate.
   - Fix: make the uncomment step whitespace-tolerant, for example `sed -i -E 's|^[[:space:]]*#[[:space:]]*(ssl_certificate[[:space:]]+)|    \\1|' ...` and the matching key variant, or remove the padded spacing in the stats vhost so the existing sed matches. Add a deploy-sed fixture that applies the script's uncomment expressions to both vhosts before running `nginx -t`.

### HIGH

None.

### MEDIUM

1. `phase4-coordinator/dist/test/check_nginx_stats_test.sh:14`, `:22`, and `:166-229`
   - Evidence: BUILD Step 4.B requires AC-3 nginx-tier confirmation: send `Authorization: Bearer garbage` through nginx and assert 401 `unauthorized`, proving Authorization-bearing requests bypass the public cache and reach the handler.
   - Evidence: the harness comment lists AC-3, and the upstream mock can emit 401 for non-`mpk_` Authorization, but the executed curl steps never send `Bearer garbage` or assert 401.
   - Evidence: the harness comment lists `proxy_no_cache` write-suppression, but the executed steps never inspect `$TMP/cache`, never expose/assert cache status, and use the same `{"ok":true}` body for keyed and anonymous 200s, so it cannot prove partner bytes were not cached.
   - Why this matters: `make test-dist` can pass in CI without exercising two of the Step 4.B cache/auth correctness checks that were added specifically to prevent cached public responses from masking invalid Authorization and to prove partner projections are not written into shared cache.
   - Fix: add an explicit invalid-Bearer curl after nginx starts and assert HTTP 401 plus `code:"unauthorized"`. For write-suppression, make the mock return distinguishable keyed vs anonymous bodies, add an `X-Cache-Status` test-only header or inspect `$TMP/cache`, then assert a keyed request does not create a reusable cache entry and the anonymous follow-up is not a HIT of keyed content.

### LOW

None.

### INFO

- `phase4-coordinator/dist/deploy-pearl-vps.sh:365-406` now treats `stats.streamvc.live` as a first-class ACME/certbot hostname, partially addressing the r2 TLS finding.
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf:24-27` implements the preferred map-based Authorization bypass shape.
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf:31-33` declares separate per-endpoint zones with `rate=60r/m`.
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf:39-40` declares the expected `stats_public:10m` cache zone at `/var/cache/nginx/stats` with `inactive=300s`.
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf:45-49` defines a redacted stats log format without `$http_authorization`.
- `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:99-167` uses exact endpoint locations, per-endpoint `limit_req ... nodelay`, `limit_req_status 429`, and no stats `burst=`.
- `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:80-93` returns the JSON `rate_limited` envelope with `Retry-After: 60` for nginx-tier 429s.
- `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:212-270` mirrors the three stats exact locations on the coordinator hostname before the `/v1/` catch-all.
- `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:302-311` mirrors the stats 429 JSON mapping on the coordinator hostname.
- `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:63` sets `client_max_body_size 64k`, above the 8K floor named in the CODE lane prompt.
- `Makefile:50-55` wires `check_nginx_stats_test.sh` into `make test-dist`.
- `.github/workflows/ci.yml:262-281` runs `make test-dist` on `ubuntu-latest`, where the Docker-backed nginx harness should execute if the hosted Docker daemon is available.

## Round-2 closure checks

- CODE r2 CRITICAL: NOT CLOSED. The implementation now obtains a stats-host certificate and tries to uncomment the stats vhost cert lines, but the `ssl_certificate` sed pattern does not match the current padded directive line.
- CODE r2 MEDIUM: PARTIALLY CLOSED. The script is now a real Docker nginx+curl fixture for AC-8, keyed-bypass, per-endpoint isolation, and AC-15 when Docker is available, but AC-3 and proxy-cache write-suppression are still not executed.

## Final verdict

READY TO LOCK: NO
Blocking count: 1 CRITICAL / 0 HIGH / 1 MEDIUM / 0 LOW / 12 INFO

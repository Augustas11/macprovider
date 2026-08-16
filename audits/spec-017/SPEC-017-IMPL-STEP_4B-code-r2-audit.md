# SPEC-017 IMPL Step 4.B - Code Audit Round 2

Branch: `impl/spec-017-step-1`
HEAD audited: `435858e157ba9e4fa69bb192982d7a7227870d00`
Diff base checked: `51b9736`
Auditor lane: CODE
Prior rounds checked:
- `specs/SPEC-017-IMPL-STEP_4B-code-r1-audit.md`

Verdict: NOT READY TO LOCK -
1 CRITICAL + 0 HIGH + 1 MEDIUM + 0 LOW + 12 INFO

## Validation evidence
- Required reading completed: `SPEC-017-network-stats-api.md` v0.1.8 sections 5.6, 5.7, 6.6.2, 7.1, 7.4, and 8.5; `BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.B and the AC-to-step matrix; `SPEC-017-IMPL-STEP_3-r8-convergence.md`; current coordinator/stats nginx files; Step 4.B ARCH r1; Step 4.B CODE r1.
- `git fetch origin` completed; local branch is `impl/spec-017-step-1...origin/impl/spec-017-step-1`.
- `git diff 51b9736..HEAD -- phase4-coordinator/dist/` - scoped to the Step 4.B nginx/deploy/test artifacts.
- `grep -RInE 'limit_req_zone|limit_req |proxy_cache|proxy_no_cache|\$http_authorization' phase4-coordinator/dist/nginx-*.conf phase4-coordinator/dist/nginx-snippets/*.conf` - confirmed map, zones, cache, and Authorization directives.
- Static brace-depth check over both vhosts and the shared snippet - PASS, final brace depth 0.
- Local `nginx -t` was not directly executable: `nginx` is not installed locally; Docker CLI is installed, but `docker info` cannot reach the daemon.
- `bash phase4-coordinator/dist/test/check_nginx_stats_test.sh` - SKIP, `docker daemon not reachable; CI runs this test`.
- `make test-dist` - PASS overall, but `check_nginx_stats_test.sh` skipped the nginx validation for the same Docker-daemon reason.

## Category verdicts
A. `nginx -t` compatibility: FAIL. Core stats directives are stock nginx, but the deploy-enabled `stats.malibu.tech` TLS server has `listen 443 ssl` while its cert lines remain commented and the deploy script only obtains/uncomments the coordinator certificate.

B. map directive correctness: PASS. `stats-shared.conf` declares `map $http_authorization $public_rl_key` before the three `limit_req_zone` declarations.

C. limit_req_zone declarations: PASS. `stats_overview`, `stats_leaderboard`, and `stats_health` are declared in the shared http-context snippet at `:10m` with `rate=60r/m`, and all stats locations reference matching names.

D. location block ordering: PASS. Coordinator exact stats locations precede `location /v1/ { return 404; }`.

E. proxy_pass posture: PASS. Stats locations proxy to `http://127.0.0.1:8444` without a URI suffix/trailing slash rewrite.

F. proxy_cache_path: PASS. Shared snippet declares `/var/cache/nginx/stats`, `levels=1:2`, `keys_zone=stats_public:10m`, `inactive=300s`; stats locations use `proxy_cache stats_public`.

G. proxy_cache_bypass + proxy_no_cache: PASS. Every stats location on both hostnames pairs `proxy_cache_bypass $http_authorization` with `proxy_no_cache $http_authorization`.

H. access-log format: PASS for the dedicated stats vhost. `stats_redacted` omits `$http_authorization`, and `stats.malibu.tech` uses it. The coordinator vhost still relies on inherited logging, but this diff does not introduce an Authorization-bearing log format.

I. Header forwarding: PASS. Stats locations forward Host, X-Real-IP, X-Forwarded-For, X-Forwarded-Proto, and Authorization.

J. HEAD method behavior: PASS. No method-specific nginx block intercepts HEAD; exact stats locations forward to the Step 3 mux.

K. TLS posture: FAIL. TLS protocol versions are correct, but certbot/deploy handling is incomplete for the new stats hostname.

L. Test harness: FAIL. The shipped shell harness performs only `nginx -t` when Docker is available, then points to a nonexistent heavier fixture/job for AC-8, AC-3, AC-15, per-endpoint isolation, keyed bypass, and cache write-suppression.

## Findings

### CRITICAL
1. `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:49` and `phase4-coordinator/dist/deploy-pearl-vps.sh:386`
   - Evidence: the stats vhost enables `listen 443 ssl http2;` at `nginx-stats.malibu.tech.conf:49-50`, but its certificate directives are still comments at `:54-55`.
   - Evidence: the deploy script obtains a certificate only for `$DOMAIN` (`coordinator.malibu.tech`) at `deploy-pearl-vps.sh:386-392`, installs/enables the stats vhost at `:404-407`, and only uncomments certificate directives in `/etc/nginx/sites-available/$DOMAIN` at `:414-415`.
   - Evidence: the shipped nginx test strips `listen 443 ssl http2;` to `listen 8443;` at `check_nginx_stats_test.sh:65-72`, so it cannot catch the production TLS/certificate shape.
   - Why this is CRITICAL: in the deployed stock-nginx shape, the enabled `stats.malibu.tech` SSL server has no server-local certificate and the repo deploy path provides no stats-host certificate or uncomment step. That is an `nginx -t` failure class unless Pearl happens to carry an out-of-band inherited global certificate, which the shipped config/deploy path does not define.
   - Fix: add first-class stats-host cert handling. Either introduce `STATS_DOMAIN=stats.malibu.tech`, install a port-80 stub for it, run certbot for that hostname, and uncomment `/etc/letsencrypt/live/stats.malibu.tech/...` in the stats vhost before `nginx -t`; or issue a SAN cert covering both hostnames and wire both vhosts to the actual installed certificate. Update the nginx test to preserve TLS using mounted dummy certs or to exercise the same uncomment/cert path.

### HIGH
None.

### MEDIUM
1. `phase4-coordinator/dist/test/check_nginx_stats_test.sh:100`
   - Evidence: BUILD Step 4.B requires nginx-surface AC-8, AC-3, AC-15, keyed-through-nginx bypass, per-endpoint isolation, and `proxy_no_cache` write-suppression tests. The shell harness runs `nginx -t` only, then prints that the live tests run in `phase4-coordinator/dist/test/nginx_fixture_test.go` and a `coordinator-nginx-integration` CI job.
   - Evidence: `find phase4-coordinator -path '*nginx_fixture_test.go'` returned no fixture, and `rg 'coordinator-nginx-integration|nginx_fixture_test' .github phase4-coordinator` found only the shell-script comments. `.github/workflows/ci.yml` has no such job; `make test-dist` only invokes the shell script.
   - Why this matters: the repo can report a passing Step 4.B dist target while the required behavior tests are absent. This would miss rate-limit behavior, cache write-suppression, keyed bypass, per-endpoint quota isolation, and nginx access-log redaction regressions.
   - Fix: either implement the referenced testcontainers/nginx fixture and wire it into CI, or expand `check_nginx_stats_test.sh` to run a real nginx container plus mock upstream and drive the required curl assertions. The harness should fail if those behavior checks are not executed in CI.

### LOW
None.

### INFO
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf:24-27` implements the preferred map-based Authorization bypass shape.
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf:31-33` declares separate per-endpoint zones with `rate=60r/m`.
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf:39-40` declares the expected `stats_public:10m` cache zone at `/var/cache/nginx/stats` with `inactive=300s`.
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf:45-49` defines a redacted stats log format without `$http_authorization`.
- `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:92`, `:120`, and `:143` use `limit_req zone=<endpoint> nodelay` with no stats `burst=`.
- `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:93`, `:121`, and `:144` set `limit_req_status 429`.
- `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:94`, `:122`, and `:145` route nginx-generated 429s through `@stats_rate_limited`.
- `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:80-86` returns the JSON `rate_limited` envelope with `Retry-After: 60` for nginx-tier 429s.
- `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf:212-269` mirrors the three stats exact locations on the coordinator hostname before the `/v1/` catch-all.
- `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf:302-308` mirrors the stats 429 JSON mapping on the coordinator hostname.
- `phase4-coordinator/dist/deploy-pearl-vps.sh:49-50` now treats the shared snippet and stats vhost as required local deploy artifacts, closing the r1 undeclared-zone issue in intent.
- `Makefile:50-55` wires `check_nginx_stats_test.sh` into `make test-dist`, closing the r1 "not wired at all" issue but not the behavior-test coverage gap above.

## Final verdict
READY TO LOCK: NO
Blocking count: 1 CRITICAL / 0 HIGH / 1 MEDIUM / 0 LOW / 12 INFO

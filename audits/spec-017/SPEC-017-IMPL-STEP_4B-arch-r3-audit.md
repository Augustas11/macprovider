# SPEC-017 IMPL Step 4.B - Architecture Audit Round 3

Branch: `impl/spec-017-step-1`
HEAD audited: `ecc02ad049fdb0ade3b3539c0c6f1b59f3c66ce2`
Diff base: Step 4.A base `51b9736`
Auditor lane: ARCHITECTURE
Prior rounds checked:
- `specs/SPEC-017-IMPL-STEP_4B-arch-r1-audit.md`
- `specs/SPEC-017-IMPL-STEP_4B-arch-r2-audit.md`

Verdict: READY TO LOCK -
0 CRITICAL + 0 HIGH + 0 MEDIUM + 1 LOW + 15 INFO

## Validation evidence
- Required reading completed:
  - `specs/SPEC-017-network-stats-api.md` v0.1.8 sections 5.6, 5.7, 6.6.2, 7.1, 7.4, and 8.5.
  - `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.B block and AC-to-step matrix.
  - `specs/SPEC-017-IMPL-STEP_3-r8-convergence.md`.
  - `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`.
  - `phase4-coordinator/dist/nginx-stats.malibu.tech.conf`.
  - `phase4-coordinator/dist/nginx-snippets/stats-shared.conf`.
  - `phase4-coordinator/dist/nginx-snippets/stats-security-headers.conf`.
  - Prior Step 4.B ARCH audit rounds r1 and r2.
- `nginx -t -c /Users/augstar/macprovider-spec017-step1/phase4-coordinator/dist/nginx-stats.malibu.tech.conf` - NOT EXECUTABLE in this environment; `/bin/bash: nginx: command not found`.
- `bash phase4-coordinator/dist/test/check_nginx_stats_test.sh` - SKIPPED locally because the Docker daemon is not reachable: `SKIP: docker daemon not reachable; CI runs this test`.
- `grep -E 'limit_req_zone|limit_req |proxy_cache|proxy_no_cache|\$http_authorization' phase4-coordinator/dist/nginx-*.conf` - PASS for per-location stats `limit_req`, cache, `proxy_no_cache`, and `Authorization` forwarding. As in r2, the http-context `limit_req_zone`, `map`, `proxy_cache_path`, and `log_format` declarations live in `phase4-coordinator/dist/nginx-snippets/stats-shared.conf`.
- Expanded grep including `phase4-coordinator/dist/nginx-snippets/*.conf` - PASS for the preferred map-based Authorization bypass, three per-endpoint `limit_req_zone` declarations, `proxy_cache_path`, and redacted log format.
- `git diff 51b9736..HEAD -- phase4-coordinator/dist/` - scope confirmed: `deploy-pearl-vps.sh`, coordinator vhost, shared snippets, stats vhost, and nginx stats smoke script changed.
- `git diff --check 51b9736..HEAD -- phase4-coordinator/dist/` - PASS.
- Focused sweeps for `Access-Control-*`, `Vary: Authorization`, `add_header`, `Cache-Control`, `$http_authorization`, `server_tokens`, `burst=`, and Cloudflare-specific directives found no stats-surface CORS headers, no `Vary: Authorization` directive in nginx, no raw Authorization-bearing log format, and no stats `burst=` parameter.
- CI wiring check: `Makefile:54` invokes `phase4-coordinator/dist/test/check_nginx_stats_test.sh`, and `.github/workflows/ci.yml:280` runs `make test-dist` in the `dist-tooling` job.

## Category verdicts
A. Vhost surface: PASS. `stats.malibu.tech` has a port-80 ACME/redirect server and a port-443 TLS server. `deploy-pearl-vps.sh` now treats `STATS_DOMAIN` as a first-class certbot target, installs the stats vhost, and uncomments the stats certificate lines before the final `nginx -t`. `coordinator.malibu.tech` exposes the three locked stats endpoints before the `/v1/` 404 catch-all.
B. Per-endpoint rate-limit zones: PASS. `stats-shared.conf` declares `stats_overview`, `stats_leaderboard`, and `stats_health` separately at `rate=60r/m`, and all stats locations reference their own zone with `nodelay` and no stats `burst=`.
C. Authorization-aware keying: PASS. The author chose shape (a): `map $http_authorization $public_rl_key` with an empty key for Authorization-bearing requests.
D. Cache hygiene: PASS. `proxy_cache_path` is declared once for `stats_public`, and every stats location in both vhosts has both `proxy_cache_bypass $http_authorization` and `proxy_no_cache $http_authorization`.
E. Header hygiene: PASS. Both stats surfaces forward `X-Forwarded-For` and `Authorization` to the coordinator. The dedicated stats vhost uses `stats_redacted`, whose `log_format` excludes `$http_authorization`. No `server_tokens` directive is added in this diff, so Pearl's global posture remains inherited.
F. Method allowlist + 405: PASS. The exact stats endpoint locations do not short-circuit non-GET methods with cached 200s; nginx forwards them to the Step 3 handler, and default proxy caching remains GET/HEAD scoped.
G. CORS - application layer: PASS. The changed nginx files do not emit `Access-Control-*` headers; Step 3 remains the CORS owner, including sibling-subdomain rejection.
H. Cloudflare / Pearl posture: PASS. No Cloudflare-specific cache, CORS, or bot-management directives were added. The only nginx `add_header Cache-Control` in the stats surface is scoped to the internal 429 rate-limit location.

## Findings
### CRITICAL
None.

### HIGH
None.

### MEDIUM
None.

### LOW
1. `phase4-coordinator/dist/test/check_nginx_stats_test.sh:5`, `phase4-coordinator/dist/test/check_nginx_stats_test.sh:22`, and `phase4-coordinator/dist/test/check_nginx_stats_test.sh:31`
   - Evidence: the script header says it validates the amended coordinator vhost, claims `proxy_no_cache` write-suppression coverage, and says CI runs it in a `coordinator-nginx-integration` job. The executable body builds only a test-only stats vhost from `nginx-stats.malibu.tech.conf`; it does not include `nginx-coordinator.malibu.tech.conf`, and it does not inspect the cache directory or assert `MISS`/`BYPASS` after a keyed request. CI actually runs it through `make test-dist` in the `dist-tooling` job.
   - Risk: this is not a config blocker because the static architecture checks prove the coordinator allow-through and the required cache directives, and the script now covers the critical rate-limit/keyed-bypass/log-redaction behavior shape. The comments overstate the exact behavior proof, which can mislead later audit rounds.
   - Fix: either narrow the header comments to the stats-vhost smoke that the script actually runs, or extend the script to include the coordinator vhost and a real cache-directory or cache-status assertion for the `proxy_no_cache` write-suppression claim.

### INFO
- ARCH r1 HIGH is closed: both stats surfaces route nginx-generated 429s through `@stats_rate_limited` and return a JSON `rate_limited` envelope with `Retry-After: 60`.
- ARCH r2 HIGH is closed: `deploy-pearl-vps.sh:369` defines `STATS_DOMAIN`, lines `371-393` install ACME stubs for both hostnames, lines `396-405` obtain certs for both hostnames, and lines `416-439` install snippets/vhosts and activate the stats certificate before `nginx -t`.
- ARCH r2 LOW is materially closed: `check_nginx_stats_test.sh` now contains real Docker/nginx behavior checks for `nginx -t`, AC-8, keyed-bypass, per-endpoint isolation, and AC-15 redaction, and the script is wired through `Makefile:54` plus CI's `dist-tooling` job.
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf:24` through `:27` implements the preferred map-based Authorization bypass shape.
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf:31` through `:33` define separate per-endpoint zones, preserving the endpoint dimension.
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf:39` uses `/var/cache/nginx/stats`, a normal disk-backed cache path rather than an obvious tmpfs-only path.
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf:45` through `:49` defines `stats_redacted` without `$http_authorization`.
- `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:99`, `:127`, and `:150` use exact endpoint locations for overview, leaderboard, and health.
- `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:100`, `:128`, and `:151` use `limit_req zone=<endpoint> nodelay` with no stats `burst=`.
- `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:119` and `:120` pair cache read-bypass and write-suppression for Authorization-bearing overview responses; leaderboard and health mirror the same pair.
- `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf:212`, `:232`, and `:252` place all three stats endpoints before the `/v1/` catch-all at `:280`.
- `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf:220` and `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:107` forward `X-Forwarded-For` using `$proxy_add_x_forwarded_for`.
- `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf:222` and `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:109` forward `Authorization` to the coordinator so the in-process partner dispatcher remains authoritative.
- No `Access-Control-Allow-Origin`, `Access-Control-Allow-Headers`, or `Access-Control-Allow-Methods` directives appear in the changed nginx stats files.
- No `Vary: Authorization` directive appears in the changed nginx stats files; Vary remains an application-layer response concern.

## Round-2 closure checks
- ARCH r2 HIGH: CLOSED. The prior finding required `stats.malibu.tech` to use the same TLS/cert pipeline as the rest of Pearl. The deploy script now obtains a cert for `STATS_DOMAIN`, installs the stats vhost, uncomments its cert directives, and runs `nginx -t` only after the stats certificate path is wired.
- ARCH r2 LOW: CLOSED AS BLOCKER / RESIDUAL LOW. The previous concern that the stats nginx script only claimed behavior coverage is mostly closed by the Docker/nginx harness now present in the script and wired into `make test-dist`; the remaining mismatch is limited to overbroad comments and missing cache-write/coordinator-surface assertions.

## Final verdict
READY TO LOCK: YES
Blocking count: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 1 LOW / 15 INFO

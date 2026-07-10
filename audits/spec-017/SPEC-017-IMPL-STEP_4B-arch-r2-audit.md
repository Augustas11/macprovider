# SPEC-017 IMPL Step 4.B - Architecture Audit Round 2

Branch: `impl/spec-017-step-1`
HEAD audited: `435858e157ba9e4fa69bb192982d7a7227870d00`
Diff base: Step 4.A base `51b9736`
Auditor lane: ARCHITECTURE
Prior rounds checked:
- `specs/SPEC-017-IMPL-STEP_4B-arch-r1-audit.md`

Verdict: NOT READY TO LOCK -
0 CRITICAL + 1 HIGH + 0 MEDIUM + 1 LOW + 12 INFO

## Validation evidence
- Required reading completed:
  - `specs/SPEC-017-network-stats-api.md` v0.1.8 sections 5.6, 5.7, 6.6.2, 7.1, 7.4, and 8.5.
  - `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.B block and AC-to-step matrix.
  - `specs/SPEC-017-IMPL-STEP_3-r8-convergence.md`.
  - `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`.
  - `phase4-coordinator/dist/nginx-stats.streamvc.live.conf`.
  - `phase4-coordinator/dist/nginx-snippets/stats-shared.conf`.
  - Prior Step 4.B ARCH audit round r1.
- `nginx -t -c /Users/augstar/macprovider-spec017-step1/phase4-coordinator/dist/nginx-stats.streamvc.live.conf` - NOT EXECUTABLE in this environment; `/bin/bash: nginx: command not found`.
- `bash phase4-coordinator/dist/test/check_nginx_stats_test.sh` - SKIPPED locally because the Docker daemon is not reachable. The script itself only performs composed `nginx -t`; its comments reference a Go fixture / CI job that is not present in this tree.
- `grep -E 'limit_req_zone|limit_req |proxy_cache|proxy_no_cache|\$http_authorization' phase4-coordinator/dist/nginx-*.conf` - PASS for per-location stats `limit_req`, cache, `proxy_no_cache`, and `Authorization` forwarding. The per-endpoint `limit_req_zone` declarations now live in `phase4-coordinator/dist/nginx-snippets/stats-shared.conf`, so this exact grep no longer sees the http-context declarations.
- Expanded grep including `phase4-coordinator/dist/nginx-snippets/*.conf` - PASS for the shared `map`, three per-endpoint `limit_req_zone` declarations, `proxy_cache_path`, and redacted log format.
- `git diff 51b9736..HEAD -- phase4-coordinator/dist/` - scope confirmed: `deploy-pearl-vps.sh`, coordinator vhost, new shared snippet, new stats vhost, and new nginx stats test script changed.
- `git diff --check 51b9736..HEAD -- phase4-coordinator/dist/` - PASS.

## Category verdicts
A. Vhost surface: FAIL. The static stats vhost has port 80 redirect and port 443 TLS blocks, and the coordinator vhost exposes all three stats endpoints before the `/v1/` 404 catch-all. The deploy pipeline, however, installs the stats TLS vhost without obtaining or activating a `stats.streamvc.live` certificate.
B. Per-endpoint rate-limit zones: PASS. The shared http-context snippet declares `stats_overview`, `stats_leaderboard`, and `stats_health` separately at `rate=60r/m`, and all stats locations reference their own zone with `nodelay` and no `burst=`.
C. Authorization-aware keying: PASS. The author chose shape (a): `map $http_authorization $public_rl_key` with an empty key for Authorization-bearing requests.
D. Cache hygiene: PASS. `proxy_cache_path` is declared once in the shared snippet, and every stats location in both vhosts has both `proxy_cache_bypass $http_authorization` and `proxy_no_cache $http_authorization`.
E. Header hygiene: PASS. Both vhosts forward `X-Forwarded-For` and `Authorization`; the stats log format excludes `$http_authorization`. No `server_tokens` directive is present in this diff, so that part remains inherited from Pearl's global nginx posture.
F. Method allowlist + 405: PASS. The stats endpoint locations do not short-circuit non-GET methods; nginx forwards them to the Step 3 handler for the 405 envelope. The nginx cache remains GET/HEAD-scoped by default.
G. CORS - application layer: PASS. The changed nginx files do not emit `Access-Control-*` headers; Step 3 remains the CORS owner.
H. Cloudflare / Pearl posture: PASS. No Cloudflare-specific cache or CORS directives were added. The only nginx `add_header Cache-Control` in the changed stats config is scoped to the internal 429 rate-limit location.

## Findings
### CRITICAL
None.

### HIGH
1. `phase4-coordinator/dist/deploy-pearl-vps.sh:386`, `phase4-coordinator/dist/deploy-pearl-vps.sh:396`, `phase4-coordinator/dist/deploy-pearl-vps.sh:404`, `phase4-coordinator/dist/deploy-pearl-vps.sh:414`, and `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:53`
   - Evidence: the deploy script obtains a Let's Encrypt cert only for `$DOMAIN`, whose default is `coordinator.streamvc.live`. It then installs `/etc/nginx/sites-available/stats.streamvc.live` and enables it, but the only certificate-uncommenting sed commands target `/etc/nginx/sites-available/$DOMAIN`. The stats vhost still ships with its `ssl_certificate` and `ssl_certificate_key` lines commented.
   - Why: SPEC-017 Section 7.1 requires `stats.streamvc.live` as the public hostname with TLS via the same cert pipeline as the other `*.streamvc.live` vhosts, and BUILD Step 4.B requires TLS per the existing cert pipeline. Installing a `listen 443 ssl` stats vhost before acquiring and wiring a `stats.streamvc.live` certificate does not match that pipeline.
   - Risk: first deploy can fail `nginx -t` / reload because the stats TLS server has no active certificate, or it can come up with an inherited/default certificate that does not validate for `stats.streamvc.live`. Either outcome leaves the primary public surface broken and forces an operator reconfiguration before cutover.
   - Fix: extend the deploy sequence to treat `stats.streamvc.live` as a first-class cert target: DNS-check it, install an HTTP-01 stub for it, run certbot for the stats hostname, then install the full stats TLS vhost with its `ssl_certificate` lines activated before the final `nginx -t`. Keep the shared snippet installation before either vhost references `stats_*` zones.

### MEDIUM
None.

### LOW
1. `phase4-coordinator/dist/test/check_nginx_stats_test.sh:100`
   - Evidence: the shell script says live AC-8 / AC-3 / AC-15 / keyed-bypass / cache tests live in `phase4-coordinator/dist/test/nginx_fixture_test.go` and a `coordinator-nginx-integration` CI job, but `rg` finds those names only in this script's comments. Locally, the script skipped because Docker was unavailable.
   - Risk: the architecture lane can statically inspect the intended nginx topology, but the repo does not currently provide the behavior evidence the script claims for edge rate-limit, cache, and redaction semantics.
   - Fix: either add the referenced fixture / CI job or reduce the shell script's claims to the composed `nginx -t` preflight it actually performs.

### INFO
- Round-1 HIGH is closed in the config: both vhosts now route nginx limiter 429s through `@stats_rate_limited` and emit a JSON `rate_limited` envelope with `Retry-After: 60`.
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf:24` implements the preferred map-based Authorization bypass shape.
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf:31` through `:33` define separate per-endpoint zones, preserving the required endpoint dimension.
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf:39` uses `/var/cache/nginx/stats`, a normal disk-backed cache path rather than an obvious tmpfs path.
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf:45` defines `stats_redacted` without `$http_authorization`.
- `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:91`, `:119`, and `:142` use exact endpoint locations for overview, leaderboard, and health.
- `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:111` and `:112` pair cache read-bypass and write-suppression for Authorization-bearing overview responses; leaderboard and health mirror the same pair.
- `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:212` places `/v1/stats/overview` before the `/v1/` 404 catch-all at `:280`; leaderboard and health are likewise before the catch-all.
- `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:220` and `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:99` forward `X-Forwarded-For` using `$proxy_add_x_forwarded_for`.
- `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:222` and `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:101` forward `Authorization` to the coordinator so the in-process partner dispatcher remains authoritative.
- No `Access-Control-Allow-Origin`, `Access-Control-Allow-Headers`, or `Access-Control-Allow-Methods` directives appear in the changed nginx stats files.
- No `Vary: Authorization` directive appears in the changed nginx stats files; Vary remains an application-layer response concern.

## Round-1 closure checks
- ARCH r1 HIGH: CLOSED. The prior finding required nginx-tier 429s to return the locked JSON rate-limit envelope plus `Retry-After`. Both stats surfaces now use `error_page 429 = @stats_rate_limited;`, and both named locations return `{"error":{"code":"rate_limited","message":"rate limited","retry_after_seconds":60}}` with `Retry-After: 60`.

## Final verdict
READY TO LOCK: NO
Blocking count: 0 CRITICAL / 1 HIGH / 0 MEDIUM / 1 LOW / 12 INFO

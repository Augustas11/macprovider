# SPEC-017 IMPL Step 4.B - Architecture Audit Round 1

Branch: `impl/spec-017-step-1`
HEAD audited: `d8a8a4538b34d62a530263b75a7cddccba7279be` (`impl(017): Step 4.A round-2 fixes (CODE 2M closure) - subprocess + handler test surface`)
Diff base: Step 4.A base `51b9736`
Auditor lane: ARCHITECTURE
Prior rounds checked:
- None. This is the first Step 4.B ARCH audit file found under `specs/`.

Verdict: NOT READY TO LOCK -
0 CRITICAL + 1 HIGH + 0 MEDIUM + 0 LOW + 10 INFO

## Validation evidence
- Required reading completed:
  - `specs/SPEC-017-network-stats-api.md` v0.1.8 sections 5.6, 5.7, 6.6.2, 7.1, 7.4, and 8.5.
  - `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.B block and AC-to-step matrix.
  - `specs/SPEC-017-IMPL-STEP_3-r8-convergence.md`.
  - `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`.
  - `phase4-coordinator/dist/nginx-stats.malibu.tech.conf`.
  - No prior `SPEC-017-IMPL-STEP_4B-arch-r*-audit.md` files were present.
- `nginx -t -c /Users/augstar/macprovider-spec017-step1/phase4-coordinator/dist/nginx-stats.malibu.tech.conf` - NOT EXECUTED in this environment; `/bin/bash: nginx: command not found`.
- `grep -E 'limit_req_zone|limit_req |proxy_cache|proxy_no_cache|\$http_authorization' phase4-coordinator/dist/nginx-*.conf` - PASS for structural sweep: found per-endpoint `limit_req_zone` declarations, per-location `limit_req ... nodelay`, `proxy_cache_bypass`, `proxy_no_cache`, and forwarded `Authorization`.
- `git diff 51b9736..HEAD -- phase4-coordinator/dist/` - PASS for scope: two files changed, `nginx-coordinator.malibu.tech.conf` and new `nginx-stats.malibu.tech.conf`.
- `rg -n "Retry-After|rate_limited|error_page|limit_req_status|add_header" phase4-coordinator/dist/nginx-*.conf` - FAIL for nginx limiter response shape: only `limit_req_status 429` appears; no `Retry-After`, JSON `rate_limited` body, or `error_page` mapping exists for stats limit rejections.

## Category verdicts
A. Vhost surface: PASS. `stats.malibu.tech` has 80 redirect + 443 TLS server blocks, and `coordinator.malibu.tech` now exposes exact `/v1/stats/{overview,leaderboard,health}` locations before the `/v1/` 404 catch-all.
B. Per-endpoint rate-limit zones: FAIL. Zone isolation and no-burst `nodelay` shape are correct, but nginx-generated 429s do not satisfy the locked stats error-envelope/Retry-After contract.
C. Authorization-aware keying: PASS. The author chose shape (a): `map $http_authorization $public_rl_key` with empty key for Authorization-bearing requests.
D. Cache hygiene: PASS. `proxy_cache_path` is present, and every stats location has both `proxy_cache_bypass $http_authorization` and `proxy_no_cache $http_authorization`.
E. Header hygiene: PASS. Stats locations forward `X-Forwarded-For` and `Authorization`; the new stats access log format excludes `$http_authorization`.
F. Method allowlist + 405: PASS. The exact endpoint locations do not short-circuit POST/PUT/etc.; nginx forwards them to the Step 3 handler for the 405 envelope. Default nginx caching remains GET/HEAD scoped.
G. CORS - application layer: PASS. The nginx config does not emit `Access-Control-*` headers; Step 3 remains the CORS owner.
H. Cloudflare / Pearl posture: PASS. No Cloudflare-specific cache/header directives were added to the stats vhost.

## Findings
### CRITICAL
None.

### HIGH
1. `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:116` and `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf:213`
   - Evidence:
     ```nginx
     limit_req zone=stats_overview nodelay;
     limit_req_status 429;
     ```
     The same pattern appears for leaderboard and health on both vhosts. A repository-wide scan finds no `error_page` mapping, no `Retry-After` header, and no `rate_limited` JSON response in the nginx artifacts.
   - Why: SPEC-017 v0.1.8 Section 5.6 says both tiers return `429 Too Many Requests` with `Retry-After` and the Section 5.9 JSON body. BUILD Step 4.B makes AC-8 an nginx-surface test: the 61st anonymous request through nginx must return 429 with `Retry-After` and `code: "rate_limited"`. `limit_req_status 429` changes only the status code; nginx still owns the response and will not produce the stats API envelope or retry header by itself.
   - Risk: The edge limiter can be structurally correct on quota isolation while still failing AC-8 and exposing clients to a bare nginx 429 response instead of the locked API contract. This is a deploy-shape mismatch at the edge/API boundary and would require an nginx reconfiguration before public cutover.
   - Fix: Add a stats-specific internal 429 mapping on both vhosts, for example an `error_page 429 = @stats_rate_limited;` location that returns `application/json` with `{"error":{"code":"rate_limited",...,"retry_after_seconds":60}}` and `add_header Retry-After "60" always;`, or an equivalent coordinator-owned envelope path. Keep `limit_req_status 429`; add the envelope/header layer around it and cover all three endpoint locations on both hostnames.

### MEDIUM
None.

### LOW
None.

### INFO
- `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:40` implements the preferred map-based Authorization bypass shape from BUILD Step 4.B.
- `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:45` through `:47` define separate `stats_overview`, `stats_leaderboard`, and `stats_health` zones at `rate=60r/m`.
- `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:56` uses `/var/cache/nginx/stats`, a normal disk-backed nginx cache path rather than an obvious tmpfs-only path.
- `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:66` defines `stats_redacted` without `$http_authorization`.
- `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:93` through `:95` mirrors the existing certbot-compatible commented cert path pattern used by the coordinator vhost.
- `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:134` and `:135` include both cache read-bypass and write-suppression for Authorization-bearing overview responses; leaderboard and health mirror the same pair.
- `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf:212` places `/v1/stats/overview` before the `/v1/` 404 catch-all at `:277`.
- `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf:231` and `:250` do the same for leaderboard and health.
- No `Access-Control-Allow-Origin`, `Access-Control-Allow-Headers`, or `Access-Control-Allow-Methods` directives appear in the changed nginx stats blocks.
- No `add_header Cache-Control` or other Cloudflare-specific cache shadowing directive appears in the changed stats vhost.

## Round-0 closure checks
- No prior Step 4.B ARCH findings exist.

## Final verdict
READY TO LOCK: NO
Blocking count: 0 CRITICAL / 1 HIGH / 0 MEDIUM / 0 LOW / 10 INFO

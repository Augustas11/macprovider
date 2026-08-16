# SPEC-017 IMPL Step 4.B Security Audit r2

Date: 2026-06-26
PR: Augustas11/macprovider#173 (`impl/spec-017-step-1`, open)
HEAD audited: `435858e157ba9e4fa69bb192982d7a7227870d00`
Lens: SECURITY - edge-side isolation / cache / log-leak
Controlling contract: `specs/SPEC-017-network-stats-api.md` v0.1.8 LOCKED; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.B.
Prior round checked: `specs/SPEC-017-IMPL-STEP_4B-security-r1-audit.md`.

## Verdict

**Not locked: 0 CRITICAL / 0 HIGH / 2 MEDIUM / 1 LOW / 7 INFO.**

Static leak posture improved and remains broadly correct: the shared http-context snippet now declares Authorization-aware empty-key public limiter bypass, per-endpoint zones, bounded public cache, and a redacted stats log format. Both stats surfaces use `proxy_cache_bypass` plus `proxy_no_cache` on `$http_authorization`, and the committed stats `error_log` is `warn`.

The security lane still cannot lock. The r1 deployment LOW is closed, but the required live Step 4.B proof harness is still absent despite a script comment that says CI runs one. A new named-location 429 envelope also adds location-level `add_header` blocks in the stats vhost without the Pearl snippet+include pattern required by this security prompt.

## Validation

- `gh pr view 173 --repo Augustas11/macprovider --json number,state,headRefName,headRefOid,baseRefName,updatedAt,title,url` - PR is open; head `impl/spec-017-step-1`; head OID `435858e157ba9e4fa69bb192982d7a7227870d00`; updated `2026-06-26T15:43:12Z`.
- `find specs -maxdepth 1 -name 'SPEC-017-IMPL-STEP_4B-security-r*-audit.md'` - prior security round is r1 only; this is r2.
- Required contract reads: SPEC §5.4.7, §5.6, §5.7, §6.4, §6.6.2, §7.4, §10 AC-8/15/21/22; BUILD Step 4.B SECURITY r5 C1 and AC-15 nginx redaction text; the Step 4.B security prompt; prior ARCH/CODE/security r1 audits.
- Static reads: `phase4-coordinator/dist/nginx-stats.malibu.tech.conf`, `phase4-coordinator/dist/nginx-snippets/stats-shared.conf`, `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`, `phase4-coordinator/dist/deploy-pearl-vps.sh`, `phase4-coordinator/dist/test/check_nginx_stats_test.sh`, `.github/workflows/ci.yml`, `Makefile`, Pearl console/portal security-header snippets, and decision-log Entry 86.
- `bash phase4-coordinator/dist/test/check_nginx_stats_test.sh` - SKIP locally: `docker daemon not reachable; CI runs this test`.
- `find phase4-coordinator -path '*nginx_fixture_test.go' -print` - no fixture exists.
- `rg 'coordinator-nginx-integration|nginx_fixture_test' .github Makefile phase4-coordinator` - only `check_nginx_stats_test.sh` comments mention them; no CI job or target exists.
- `git diff --check origin/main...HEAD -- phase4-coordinator/dist/nginx-stats.malibu.tech.conf phase4-coordinator/dist/nginx-snippets/stats-shared.conf phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf phase4-coordinator/dist/test/check_nginx_stats_test.sh` - PASS.

## Findings

### MEDIUM 1 - Required Step 4.B live nginx security proof remains absent

Evidence:
- `phase4-coordinator/dist/test/check_nginx_stats_test.sh:14-28` documents seven behavior checks, including AC-8, keyed-bypass, AC-15 access-log redaction, and `proxy_no_cache` write-suppression.
- The executable body only stages config and runs `nginx -t`; lines 100-109 state that live AC-8 / AC-3 / AC-15 / keyed-bypass / cache write-suppression tests live in `phase4-coordinator/dist/test/nginx_fixture_test.go` and CI job `coordinator-nginx-integration`.
- No `nginx_fixture_test.go` exists under `phase4-coordinator`, and `.github/workflows/ci.yml` has no `coordinator-nginx-integration` job. CI's `dist-tooling` job runs `make test-dist`, which invokes this shell script only.
- Local execution skipped before even `nginx -t` because Docker daemon is unavailable; that is acceptable locally, but the committed CI path still cannot perform the advertised live request/log/cache probes.

Why it matters:
Categories A, B, and I require behavioral evidence, not just directive-shape inspection. The lock target needs proof that a valid keyed request writes no partner projection to `/var/cache/nginx/stats`, that 100 keyed requests from one IP do not hit an edge 429, and that the actual nginx access log contains zero raw token/body/`token_hash` strings after a keyed request.

Required fix:
Add and wire a real nginx integration harness. It must run the composed config, mock or run the coordinator upstream, issue the required anonymous and valid-keyed requests through nginx, inspect the cache directory, and scan the real access log path(s). Either make `check_nginx_stats_test.sh` perform those checks or add the referenced fixture/job and fail if the fixture is missing.

### MEDIUM 2 - Stats vhost now has location-level `add_header` without the required security-header snippet pattern

Evidence:
- The Step 4.B security prompt lines 53-59 require the Pearl security-header snippet+include pattern or no `add_header` blocks at all in the stats vhost, because location-level `add_header` shadows inherited server-level headers.
- `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:80-86` declares named location `@stats_rate_limited` with `add_header Retry-After "60" always;` and `add_header Cache-Control "no-store" always;`.
- `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf:302-307` mirrors the same location-level `add_header` block.
- The stats vhost has no stats security-header snippet include. Adjacent Pearl vhosts demonstrate the required pattern: `frontdoor/console/dist/nginx-console.malibu.tech.conf:15-20` documents the inheritance trap, and `frontdoor/console/dist/nginx-snippets/console-security-headers.conf:1-5` carries the header set.

Why it matters:
This does not leak tokens and is not the cache CRITICAL/HIGH class. It is still a prompt-level security hardening failure: the vhost now contains exactly the location-level `add_header` shape the prompt told the audit to reject unless every security header is re-declared via snippet/include. Future server-level HSTS/X-Content-Type-Options/CSP additions would silently disappear on the edge-generated 429 path.

Required fix:
Either remove the nginx-owned `add_header` path and let the coordinator own 429 headers, or add a stats security-header snippet and include it in every stats location that declares `add_header`, including `@stats_rate_limited` on both hostnames. Keep the Retry-After/JSON 429 fix, but make it compatible with the Pearl snippet pattern.

### LOW 1 - `stats_redacted` comment overstates nginx default combined-log behavior

Evidence:
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf:42-44` says the default `combined` format would carry `$http_authorization` indirectly.
- The standard nginx combined format logs request line, referer, and user-agent; it does not include the Authorization header by default. The committed explicit `stats_redacted` format is still the right hardening choice, but the comment is misleading audit rationale.

Suggested fix:
Reword the comment to say the explicit format prevents future/custom log formats from adding `$http_authorization` and makes AC-15 grepable.

## Category Sweep

A. Partner-projection cache hygiene: **STATIC PASS, DYNAMIC GAP.** `stats-shared.conf:39-40` bounds `/var/cache/nginx/stats`; stats vhost lines 104-112, 132-136, and 155-159 set public cache plus both `proxy_cache_bypass` and `proxy_no_cache` on `$http_authorization`. Coordinator vhost lines 225-229, 245-249, and 265-269 mirror the same pair. No live cache-directory proof exists; covered by MEDIUM 1.

B. Public-tier rate-limit bypass for Authorization: **STATIC PASS, DYNAMIC GAP.** `stats-shared.conf:24-27` maps any present Authorization header to an empty `$public_rl_key`; lines 31-33 define separate 60 rpm zones. All stats locations use `limit_req zone=... nodelay` with no stats `burst=`. No 100-request valid-keyed nginx proof exists; covered by MEDIUM 1.

C. Access-log redaction: **STATIC PASS, DYNAMIC GAP.** `stats_redacted` omits `$http_authorization`, and the stats vhost uses `/var/log/nginx/stats.malibu.tech-access.log stats_redacted`. The coordinator vhost adds no custom `$http_authorization` log format. No live keyed-request log scan exists; covered by MEDIUM 1.

D. `add_header` inheritance trap: **FAIL.** The new stats and coordinator named 429 locations declare location-level `add_header` without the required Pearl snippet/include pattern; covered by MEDIUM 2.

E. Method allowlist: **PASS.** No `limit_except` block is present. Exact stats locations forward all methods to the coordinator, so Step 3 owns the 405 envelope and `Allow: GET, HEAD, OPTIONS`. HEAD is not rate-limited differently from GET.

F. TLS posture parity: **PASS WITH NOTE.** Stats vhost pins `ssl_protocols TLSv1.2 TLSv1.3` and follows the certbot path used by coordinator/api vhosts. No `ssl_session_tickets` directive appears in the existing coordinator vhost either, so Step 4.B does not regress that posture. HSTS is not handled for stats yet; MEDIUM 2 covers the required header-snippet pattern.

G. Cloudflare / external-CDN compatibility: **PASS BY ABSENCE.** No repo evidence shows Cloudflare in front of `stats.malibu.tech`; Step 3 handler emits partner projection `Cache-Control: private, max-age=30, s-maxage=30`, and Step 4.B adds no Cloudflare cache override.

H. Subdomain-trust boundary: **PASS.** The nginx files contain no Origin-based `if`, `map`, `return 444`, `return 200`, or `Access-Control-Allow-Origin` directive. `Origin: https://evil.malibu.tech` is forwarded to the coordinator for Step 3 CORS rejection on the exact stats locations.

I. AC-15 nginx access-log redaction: **STATIC PASS, DYNAMIC GAP.** The dedicated stats log omits Authorization by format, but no harness produces a valid `mpk_*` request, waits for flush, and scans for raw token, 43-char body, extra `mpk_...`, or `token_hash`; covered by MEDIUM 1.

J. error_log posture: **PASS.** The stats vhost sets `error_log /var/log/nginx/stats.malibu.tech-error.log warn;`. No committed stats nginx `error_log debug` directive was found.

## Closed Since r1

- r1 LOW deployment wiring gap is **closed**. `deploy-pearl-vps.sh:59-61` requires `NGINX_STATS_SHARED` and `NGINX_STATS_SITE`; lines 310-311 upload them; lines 396-419 install the shared snippet, enable the stats vhost, install the coordinator vhost, run `nginx -t`, and reload nginx.
- r1 static config positives remain closed: paired bypass/no-cache, empty-key Authorization bypass, per-endpoint zones, and warn-level stats error log are still present.

## Positive Observations

- INFO: The SECURITY r5 C1 trap is avoided statically: `proxy_no_cache` is present everywhere `proxy_cache_bypass` is present for stats.
- INFO: Public limiter zones are per endpoint, so `/overview`, `/leaderboard`, and `/health` do not share one public bucket.
- INFO: Authorization-bearing requests bypass the edge public limiter by empty map key, preventing bystander-IP collision from exhausting partner-key quota.
- INFO: No nginx CORS headers are emitted, preserving Step 3's partner CORS decisions and sibling-subdomain rejection.
- INFO: Cache disk use is bounded by `max_size=128m`.
- INFO: `git diff --check` passes on the Step 4.B nginx/test files reviewed here.
- INFO: The Step 4.B deploy path now installs the shared http-context snippet before either vhost references its zones/cache/log format.

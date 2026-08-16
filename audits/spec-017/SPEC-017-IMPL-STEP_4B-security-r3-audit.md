# SPEC-017 IMPL Step 4.B Security Audit r3

Date: 2026-06-26
PR: Augustas11/macprovider#173 (`impl/spec-017-step-1`, open)
HEAD audited: `ecc02ad049fdb0ade3b3539c0c6f1b59f3c66ce2`
Lens: SECURITY - edge-side isolation / cache / log-leak
Controlling contract: `specs/SPEC-017-network-stats-api.md` v0.1.8 LOCKED; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.B.
Prior round checked: `specs/SPEC-017-IMPL-STEP_4B-security-r2-audit.md`.

## Verdict

**Not locked: 0 CRITICAL / 0 HIGH / 1 MEDIUM / 1 LOW / 8 INFO.**

The r2 `add_header` inheritance issue is closed: both stats 429 named locations now include `stats-security-headers.conf` before the response-specific `Retry-After` / `Cache-Control` headers. The r2 TLS/deploy concern from ARCH/CODE is also closed from the security lane's posture: `deploy-pearl-vps.sh` now treats `stats.malibu.tech` as a first-class certbot target and installs/uncomments the stats vhost cert lines before `nginx -t`.

The security lane still cannot lock because the shipped nginx behavior harness still does not prove the exact SECURITY r5 C1 `proxy_no_cache` write-suppression invariant required by this prompt: after a keyed request, no cache entry exists for that URL on disk. The harness now makes keyed and anonymous bodies distinguishable and verifies an anonymous follow-up is not served the partner body, which is good leak coverage, but it never inspects the mounted cache directory and does not assert `MISS` / `BYPASS` / no cache file.

## Validation

- `gh pr view 173 --repo Augustas11/macprovider --json ...` - PR head is `impl/spec-017-step-1` at `ecc02ad049fdb0ade3b3539c0c6f1b59f3c66ce2`; base is `main`.
- `ls specs/SPEC-017-IMPL-STEP_4B-*` - prior Step 4.B security rounds are r1 and r2; this is r3.
- Required contract reads completed: SPEC §5.4.7, §5.6, §5.7, §6.6.2, §7.1, §7.4, §10 AC-3/8/15/22; BUILD Step 4.B including SECURITY r5 C1, keyed-through-nginx bypass, `proxy_no_cache` write-suppression, Cloudflare, subdomain trust, and AC-15 nginx redaction.
- Required implementation reads completed: `phase4-coordinator/dist/nginx-stats.malibu.tech.conf`, `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`, `phase4-coordinator/dist/nginx-snippets/stats-shared.conf`, `phase4-coordinator/dist/nginx-snippets/stats-security-headers.conf`, `phase4-coordinator/dist/deploy-pearl-vps.sh`, `phase4-coordinator/dist/test/check_nginx_stats_test.sh`, Pearl console security-header snippet, and Step 4.B ARCH/CODE/security prior rounds.
- `bash phase4-coordinator/dist/test/check_nginx_stats_test.sh` - SKIP locally: `docker daemon not reachable; CI runs this test`.
- `docker info` - FAIL locally: Docker client exists, but the daemon socket is missing.
- `make test-dist` - PASS overall, with `check_nginx_stats_test.sh` skipped for the same Docker-daemon reason and the optional SPEC-015 live nginx smoke skipped by design.
- `git diff --check origin/main...HEAD -- phase4-coordinator/dist/...` - PASS for the Step 4.B nginx/deploy/test files inspected.
- Static grep over stats/coordinator vhosts and snippets confirmed: no nginx CORS headers, no Origin-based edge block, no `limit_except`, no `error_log debug`, no `$http_authorization` in `log_format`, paired `proxy_cache_bypass` + `proxy_no_cache` on each stats location, per-endpoint `limit_req_zone` declarations, and `ssl_protocols TLSv1.2 TLSv1.3`.
- Worktree note: this r3 audit reflects the current local Step 4.B worktree contents, including the added AC-3 and keyed-vs-anonymous cache-leak checks in `check_nginx_stats_test.sh`.

## Findings

### MEDIUM 1 - The live harness still does not prove the required no-cache-entry-on-disk invariant

Evidence:
- BUILD Step 4.B and this security prompt require a test that, after a successful partner-key request through nginx, proves the nginx `proxy_cache_path` contains no entry for that URL+Authorization combination on disk.
- `phase4-coordinator/dist/test/check_nginx_stats_test.sh:165` mounts `$TMP/cache` to `/var/cache/nginx/stats`, and the script now gives keyed and anonymous responses distinguishable bodies at lines 128-143.
- The new cache-leak check at lines 237-250 sends a keyed request, then an anonymous follow-up, and fails if the anonymous response contains the partner marker. This proves a useful no-served-leak shape.
- The check still never inspects `$TMP/cache`, never counts files before/after the keyed request, never exposes/asserts `$upstream_cache_status`, and never asserts `MISS` or `BYPASS`. A keyed response could still be written to disk and the test would only catch it if nginx served that entry to the immediate anonymous follow-up.

Why it matters:
The static nginx config has the correct `proxy_no_cache $http_authorization` directives, so this is not the HIGH class where `proxy_no_cache` is missing. The remaining gap is proof of the requested disk invariant. SECURITY r5 C1 is specifically about write suppression, not only immediate anonymous cache-hit leakage.

Required fix:
Extend `check_nginx_stats_test.sh` from the current keyed-vs-anonymous body check to a true write-suppression proof:
- record `$TMP/cache` contents before and after the keyed request and fail on any new cache file for the keyed URL, or expose `add_header X-Stats-Cache $upstream_cache_status always;` in the test-only config and assert the keyed response is not stored and the anonymous follow-up is `MISS` or `BYPASS`, not `HIT`;
- keep the existing keyed-marker anonymous-follow-up check as the leak proof.

### LOW 1 - `stats_redacted` comment still overstates nginx default combined-log behavior

Evidence:
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf:42-44` still says the default `combined` format would carry `$http_authorization` indirectly.
- Standard nginx `combined` logs request line, referer, and user-agent; it does not include the Authorization header unless the operator customizes the format.

Why it matters:
The actual `stats_redacted` format is safe and intentionally omits `$http_authorization`; this is only misleading rationale in a security-sensitive comment.

Suggested fix:
Reword the comment to say the explicit stats format prevents future custom log formats from adding `$http_authorization` and makes AC-15 grepable.

## Category Sweep

A. Partner-projection cache hygiene: **STATIC PASS, DYNAMIC PARTIAL / FAIL FOR DISK PROOF.** `stats-shared.conf:39-40` declares bounded `/var/cache/nginx/stats`; both stats surfaces pair `proxy_cache_bypass $http_authorization` with `proxy_no_cache $http_authorization` on overview, leaderboard, and health. The script now checks that an anonymous follow-up is not served the keyed partner body, but it still does not prove no keyed cache entry exists on disk; covered by MEDIUM 1.

B. Public-tier rate-limit bypass for Authorization: **STATIC PASS, HARNESS PRESENT BUT NOT RUN LOCALLY.** `stats-shared.conf:24-27` maps any present Authorization header to an empty `$public_rl_key`; lines 31-33 declare separate 60 rpm zones. The script now attempts 100 valid-keyed leaderboard requests without edge 429, but local Docker is unavailable, so this audit did not observe the live pass.

C. Access-log redaction: **STATIC PASS, HARNESS PRESENT BUT NOT RUN LOCALLY.** `stats_redacted` omits `$http_authorization`, and `stats.malibu.tech` writes `/var/log/nginx/stats.malibu.tech-access.log stats_redacted`. The script scans for the exact raw token, its 43-character body, and `token_hash`; it does not perform a broader base64url regex scan, but the committed format has no field that should carry Authorization material.

D. `add_header` inheritance trap: **PASS.** The stats and coordinator `@stats_rate_limited` locations include `/etc/nginx/conf.d/stats-security-headers.conf` before their location-level `add_header` directives. The snippet redeclares `X-Content-Type-Options`, `X-Frame-Options`, and `Referrer-Policy` with `always`.

E. Method allowlist: **PASS.** No `limit_except` block or method-specific HEAD handling exists. GET, HEAD, OPTIONS, and invalid methods reach the Step 3 coordinator handler on exact stats locations; nginx does not create a separate cheap HEAD bypass.

F. TLS posture parity: **PASS.** Stats vhost pins TLSv1.2/TLSv1.3. The deploy script now installs ACME stubs for both `$DOMAIN` and `$STATS_DOMAIN`, runs certbot for both, installs the stats vhost, uncomments its certificate directives, then runs `nginx -t`. No `ssl_session_tickets` directive appears in the adjacent coordinator vhost either, so Step 4.B does not regress that inherited posture.

G. Cloudflare / external-CDN compatibility: **PASS BY ABSENCE.** No Cloudflare cache override appears in this PR. Step 3 remains responsible for partner `Cache-Control: private`, and no repo evidence shows Cloudflare in front of `stats.malibu.tech`.

H. Subdomain-trust boundary: **PASS.** The stats nginx files contain no Origin-based `if`, `map`, `return 444`, `return 200`, or `Access-Control-Allow-Origin` directive. `Origin: https://evil.malibu.tech` is forwarded to the coordinator for application-layer rejection.

I. AC-15 nginx access-log redaction: **STATIC PASS, HARNESS PRESENT BUT NOT RUN LOCALLY.** The access-log format omits Authorization and the script scans the mounted stats access log after a keyed request. Local execution skipped because Docker is unavailable.

J. error_log posture: **PASS.** The stats vhost sets `error_log /var/log/nginx/stats.malibu.tech-error.log warn;`; no committed stats nginx `error_log debug` directive was found.

## Closed Since r2

- r2 MEDIUM 2 is **closed**. `phase4-coordinator/dist/nginx-snippets/stats-security-headers.conf` exists, and both stats 429 named locations include it at the same location scope as their response-specific `add_header` directives.
- The ARCH/CODE r2 TLS/certbot blocker is **closed for this security sweep**. `deploy-pearl-vps.sh` now defines `STATS_DOMAIN`, provisions ACME stubs and certs for both hostnames, installs the stats security/header snippets, enables the stats vhost, uncomments its certificate directives, and runs `nginx -t`.
- r2 MEDIUM 1 is **mostly closed but not lockable**. A real Docker/nginx behavior harness now exists and is wired through `make test-dist`; it covers AC-3, keyed-bypass, per-endpoint isolation, AC-15 exact-token scans, and keyed-vs-anonymous leak behavior. It still lacks the cache-directory or cache-status write-suppression assertion required for security lock.

## Positive Observations

- INFO: The SECURITY r5 C1 static directive trap is avoided everywhere: `proxy_no_cache` accompanies `proxy_cache_bypass` on all stats locations.
- INFO: Authorization-bearing requests bypass the edge public limiter via an empty map key, preventing bystander-IP collision from throttling partner traffic at nginx.
- INFO: Public limiter zones remain per endpoint, preserving `/overview`, `/leaderboard`, and `/health` quota isolation.
- INFO: The committed nginx config emits no CORS headers and therefore cannot override Step 3 sibling-subdomain rejection.
- INFO: The 429 edge path now uses the security-header snippet pattern required by the Pearl add-header inheritance trap.
- INFO: Cache disk use is bounded by `max_size=128m inactive=300s`, reducing disk-fill exposure for public projections.
- INFO: The deploy path installs the shared http-context snippet before either vhost references its zones/cache/log format.
- INFO: `git diff --check` passes on the reviewed Step 4.B nginx, deploy, and test files.

# SPEC-017 IMPL Step 4.B Security Audit r1

Date: 2026-06-26
PR: Augustas11/macprovider#173 (`impl/spec-017-step-1`, open, updated 2026-06-26T15:33:09Z)
Lens: SECURITY - edge-side isolation / cache / log-leak
Controlling contract: `specs/SPEC-017-network-stats-api.md` v0.1.8 LOCKED; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.B.

## Verdict

**Not locked: 0 CRITICAL / 0 HIGH / 1 MEDIUM / 1 LOW / 6 INFO.**

The committed nginx config has the required leak-prevention primitives on static inspection: Authorization-aware empty-key public limiter bypass, per-endpoint zones, `proxy_cache_bypass` plus `proxy_no_cache` on `$http_authorization`, a redacted stats access-log format, no nginx CORS `add_header`, no location-level `add_header`, and `error_log ... warn`.

The security lane cannot lock because the required live proof harness for the nginx cache/log/rate-limit invariants is missing. There is no Step 4.B script or testcontainers fixture that runs nginx, sends a valid `mpk_*` request, verifies no edge cache write, proves 100 keyed requests avoid edge 429s, and scans `/var/log/nginx/stats.streamvc.live-access.log` for raw token material.

## Validation

- `gh pr view 173 --repo Augustas11/macprovider --json ...` - PR is open; head `impl/spec-017-step-1`; latest listed commit `d8a8a4538b34d62a530263b75a7cddccba7279be`.
- `find specs -maxdepth 1 -name 'SPEC-017-IMPL-STEP_4B-security-r*-audit.md'` - no prior Step 4.B security audit file; this is r1.
- `nginx -v` - not installed locally (`/bin/bash: nginx: command not found`), so no local `nginx -t` execution evidence.
- Static reads: `phase4-coordinator/dist/nginx-stats.streamvc.live.conf`, `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`, `phase4-coordinator/dist/deploy-pearl-vps.sh`, `phase4-coordinator/dist/test/*`, `frontdoor/console/dist/nginx-snippets/console-security-headers.conf`.
- Required contract reads: SPEC §5.4.6, §5.4.7, §5.6, §5.7, §6.4, §6.6.2, §7.1, §10 AC-8/15/21/22; BUILD Step 4.B lines covering SECURITY r5 C1 and AC-15 nginx log redaction.

## Findings

### MEDIUM 1 - Required Step 4.B nginx security proof harness is absent

Evidence:
- Existing dist tests are `check_deploy_config_test.sh`, `check_nginx_catalog_routes_test.sh`, `check_nginx_receipt_buffers_test.sh`, and `check_nginx_receipt_header_live_test.sh`; none exercise `nginx-stats.streamvc.live.conf`.
- `phase4-coordinator/dist/nginx-stats.streamvc.live.conf` is the only new stats nginx file; no `dist/test` script or Go fixture drives the Step 4.B AC-8 / cache / keyed-bypass / AC-15 checks.
- Local `nginx` is not installed, so this audit also could not independently run `nginx -t` or live curl/log/cache probes.

Why it matters:
Categories A, B, and I are security proof obligations, not just directive-shape checks. Static config shows the intended controls, but it does not prove nginx actually writes no partner-key cache entry, skips edge 429s for valid keyed traffic, or keeps the raw `mpk_*` token/body/`token_hash` out of the deployed access log after a real request.

Required fix:
Add a Step 4.B nginx harness, either under `phase4-coordinator/dist/test/` or as a testcontainers nginx fixture, that:
- runs `nginx -t` against a composed config containing both stats and coordinator vhosts;
- sends 100 valid-keyed `/v1/stats/leaderboard` requests from one client IP and asserts no edge 429 / `Retry-After`;
- sends a valid-keyed request, then inspects `/var/cache/nginx/stats` and an anonymous follow-up response to prove no partner projection was stored or served;
- scans `/var/log/nginx/stats.streamvc.live-access.log` for the raw token, its 43-char body, disallowed `mpk_...` strings, and literal `token_hash`, all zero.

### LOW 1 - Stats vhost deployment path is not wired into `deploy-pearl-vps.sh`

Evidence:
- `phase4-coordinator/dist/deploy-pearl-vps.sh` sets `NGINX_SITE="$DIST_DIR/nginx-coordinator.streamvc.live.conf"` and uploads only that file to `/tmp/nginx-coordinator-full.conf`.
- The same script never references `nginx-stats.streamvc.live.conf`, `stats.streamvc.live`, or the `stats_overview` / `stats_public` http-context declarations.
- The coordinator vhost references the stats zones/cache by name, while comments say their declarations live in the stats vhost file.

Why it matters:
This is primarily an ARCH/CODE deployment gap, but it affects the security validation surface: the deployed Pearl config must include the stats http-context declarations before the coordinator allow-through can be tested for keyed bypass, cache no-write, and access-log redaction. Without an automated deploy or runbook hook, the security evidence can drift from what is actually enabled on Pearl.

Suggested fix:
Extend the Pearl deploy/runbook path to install and enable the stats vhost or ship the shared `map` / `limit_req_zone` / `proxy_cache_path` / `log_format` declarations in an explicit http-level snippet included by both vhosts. Add the Step 4.B harness above so this cannot regress silently.

## Category Sweep

A. Partner-projection cache hygiene: **STATIC PASS, DYNAMIC GAP.** `nginx-stats.streamvc.live.conf` uses `proxy_cache_path /var/cache/nginx/stats ... keys_zone=stats_public:10m max_size=128m inactive=300s`; all three stats locations set both `proxy_cache_bypass $http_authorization` and `proxy_no_cache $http_authorization`. No live cache-directory proof exists; covered by MEDIUM 1.

B. Public-tier rate-limit bypass for Authorization: **STATIC PASS, DYNAMIC GAP.** The stats vhost declares `map $http_authorization $public_rl_key { "" $binary_remote_addr; default ""; }` and per-endpoint zones `stats_overview`, `stats_leaderboard`, `stats_health` at `rate=60r/m`. Locations use `limit_req zone=... nodelay` with no `burst=`. No 100-request keyed-through-nginx proof exists; covered by MEDIUM 1.

C. Access-log redaction: **STATIC PASS.** `log_format stats_redacted` omits `$http_authorization`; stats access log uses that format. The committed stats error log is `warn`, not `debug`.

D. `add_header` inheritance trap: **PASS.** The stats and coordinator nginx files contain no `add_header` directives. The console snippet confirms the inheritance hazard exists in adjacent Pearl vhosts, but Step 4.B uses the safe no-`add_header` pattern.

E. Method allowlist: **PASS.** Nginx does not add `limit_except`; it forwards methods to the coordinator for the exact stats locations. Step 3 owns the 405 envelope and `Allow: GET, HEAD, OPTIONS`.

F. TLS posture parity: **PASS WITH NOTE.** Stats vhost pins `ssl_protocols TLSv1.2 TLSv1.3` and follows the certbot-commented certificate path pattern used by the coordinator vhost. No `ssl_session_tickets` directive appears in either vhost, so Step 4.B does not regress the existing coordinator posture. HSTS is not added at nginx, consistent with the no-`add_header` Step 4.B posture.

G. Cloudflare / external-CDN compatibility: **PASS BY ABSENCE.** No Cloudflare-specific caching directive is present in the Step 4.B config. The handler sets partner projection `Cache-Control: private, max-age=30, s-maxage=30`; no repo evidence shows Cloudflare caching in front of `stats.streamvc.live`.

H. Subdomain-trust boundary: **PASS.** The nginx files contain no Origin-based `if`, `map`, `return 444`, or `Access-Control-Allow-Origin` directive. `Origin: https://evil.streamvc.live` reaches the coordinator for application-layer CORS/auth handling.

I. AC-15 nginx access-log redaction: **STATIC PASS, DYNAMIC GAP.** The access-log format omits Authorization and the path is `/var/log/nginx/stats.streamvc.live-access.log`. No live keyed request/log-flush/token-scan proof exists; covered by MEDIUM 1.

J. error_log posture: **PASS.** Stats vhost has `error_log /var/log/nginx/stats.streamvc.live-error.log warn;`; no debug error log is committed.

## Positive Observations

- INFO: All three stats locations use both cache read-bypass and write-suppression on `$http_authorization`; the specific SECURITY r5 C1 trap is not present.
- INFO: The public limiter zones are per endpoint, so `/overview` traffic cannot consume `/leaderboard` quota at the edge.
- INFO: Authorization-bearing requests intentionally produce an empty nginx limit key, avoiding partner-key traffic being throttled by public bystander IP collision.
- INFO: The config contains no nginx CORS headers, preserving Step 3's partner projection `ACAO != *` and sibling-subdomain rejection rules.
- INFO: HEAD is not special-cased in nginx; it uses the same locations and rate-limit directives as GET.
- INFO: Cache disk use is bounded by `max_size=128m`, reducing the immediate cache-disk-fill risk.

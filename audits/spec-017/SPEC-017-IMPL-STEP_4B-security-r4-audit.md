# SPEC-017 IMPL Step 4.B Security Audit r4

Date: 2026-06-26
PR: Augustas11/macprovider#173 (`impl/spec-017-step-1`, open)
HEAD audited: `022cd553fdc1b9ab06f149c7a1add4a4397b793c`
Lens: SECURITY - edge-side isolation / cache / log-leak
Controlling contract: `specs/SPEC-017-network-stats-api.md` v0.1.8 LOCKED; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.B.
Prior round checked: `specs/SPEC-017-IMPL-STEP_4B-security-r3-audit.md`.

## Verdict

**READY TO LOCK: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 2 LOW / 9 INFO.**

The r3 MEDIUM is closed. The current nginx harness now performs the missing
SECURITY r5 C1 write-suppression proof: it warms the public cache, sends a
keyed request, counts the mounted `proxy_cache_path` files before/after the
keyed request, and fails if the keyed request adds any cache file. Static nginx
config still carries the required paired `proxy_cache_bypass` and
`proxy_no_cache` directives everywhere `/v1/stats/*` is cached.

The remaining observations are non-blocking documentation/test-polish issues:
the shared log-format comment overstates nginx `combined`, and the test header
still implies coordinator-vhost runtime coverage even though the Docker harness
exercises the dedicated stats vhost plus shared snippets.

## Validation

- Required contract reads completed: SPEC v0.1.8 sections 5.4.7, 5.6, 5.7,
  6.6.2, 7.1, 7.4, and AC-3/8/15/22; BUILD Step 4.B lines covering
  Authorization-aware nginx keying, SECURITY r5 C1 `proxy_no_cache`,
  Cloudflare, subdomain trust, and AC-15 nginx redaction.
- Required implementation reads completed:
  `phase4-coordinator/dist/nginx-stats.malibu.tech.conf`,
  `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`,
  `phase4-coordinator/dist/nginx-snippets/stats-shared.conf`,
  `phase4-coordinator/dist/nginx-snippets/stats-security-headers.conf`,
  `phase4-coordinator/dist/deploy-pearl-vps.sh`,
  `phase4-coordinator/dist/test/check_nginx_stats_test.sh`, Pearl console
  security-header snippet, and Step 4.B ARCH/CODE/security prior rounds.
- `git rev-parse HEAD` - `022cd553fdc1b9ab06f149c7a1add4a4397b793c`.
- `ls specs/SPEC-017-IMPL-STEP_4B-security-r*-audit.md` - prior security
  rounds are r1, r2, and r3; this is r4.
- `rg` static sweep over Step 4.B nginx files - PASS for no edge CORS, no
  Origin-based `if` / `return 444`, no `limit_except`, no `error_log debug`, no
  `$http_authorization` in `log_format`, TLSv1.2/TLSv1.3 only, paired
  `proxy_cache_bypass` + `proxy_no_cache`, and map-based empty-key bypass.
- `git diff --check origin/main...HEAD -- phase4-coordinator/dist Makefile .github/workflows/ci.yml specs/SPEC-017-IMPL-STEP_4B-security-r3-audit.md`
  - PASS.
- `bash phase4-coordinator/dist/test/check_nginx_stats_test.sh` - SKIP locally:
  Docker daemon is not reachable.
- `make test-dist` - PASS overall; the Docker-backed stats nginx smoke skipped
  locally with `SKIP: docker daemon not reachable; CI runs this test`, and the
  optional SPEC-015 live nginx smoke skipped by design.

## Findings

### CRITICAL

None.

### HIGH

None.

### MEDIUM

None.

### LOW

1. `phase4-coordinator/dist/nginx-snippets/stats-shared.conf:42`
   - Issue: The `stats_redacted` comment still says nginx `combined` would
     carry `$http_authorization` indirectly. Stock `combined` does not include
     the Authorization header; a custom log format would.
   - Risk: The deployed `stats_redacted` format is safe and omits
     `$http_authorization`; this is misleading rationale only.
   - Fix: Reword the comment to say the explicit format prevents future custom
     formats from adding Authorization and makes AC-15 grepable.

2. `phase4-coordinator/dist/test/check_nginx_stats_test.sh:5`
   - Issue: The script header says it validates the amended coordinator vhost,
     but the Docker config only rewrites and includes
     `nginx-stats.malibu.tech.conf` plus the shared snippets.
   - Risk: Low. Static inspection confirms the coordinator stats locations
     mirror the same cache/no-cache and Authorization forwarding posture, and
     the deploy script installs the shared snippet before both vhosts. The
     comment can still mislead future auditors about runtime coverage.
   - Fix: Either narrow the comment to the stats-vhost runtime smoke or extend
     the harness to compose both vhosts.

## Category Sweep

A. Partner-projection cache hygiene: **PASS.** `stats-shared.conf:39-40`
declares bounded `/var/cache/nginx/stats`. Both stats surfaces pair
`proxy_cache_bypass $http_authorization` with
`proxy_no_cache $http_authorization` for overview, leaderboard, and health.
The current harness warms anonymous cache, then proves a keyed request adds
zero cache files and that anonymous follow-up receives only the public body.

B. Public-tier rate-limit bypass for Authorization: **PASS STATIC, HARNESS
PRESENT BUT NOT RUN LOCALLY.** `stats-shared.conf:24-27` maps present
Authorization to an empty `$public_rl_key`; the harness sends 100 valid-keyed
leaderboard requests and expects zero edge 429s.

C. Access-log redaction: **PASS.** `stats_redacted` omits
`$http_authorization`, and the stats vhost writes
`/var/log/nginx/stats.malibu.tech-access.log stats_redacted`. The harness
scans after a keyed request for the raw token, its 43-character body, and
`token_hash`; the static format has no Authorization-bearing field.

D. `add_header` inheritance trap: **PASS.** Both stats 429 named locations
include `/etc/nginx/conf.d/stats-security-headers.conf` at the same scope as
their response-specific `Retry-After` and `Cache-Control` headers.

E. Method allowlist: **PASS.** No `limit_except` or method-specific HEAD path
exists. Nginx forwards methods on exact stats locations to the coordinator;
HEAD is not cheaper or differently rate-limited than GET at the edge.

F. TLS posture parity: **PASS.** Stats and coordinator vhosts pin TLSv1.2 and
TLSv1.3 and do not enable SSLv3, TLS 1.0, or TLS 1.1. The deploy script obtains
certbot certificates for both hostnames and uncomments the stats certificate
directives before the final `nginx -t`.

G. Cloudflare / external-CDN compatibility: **PASS BY ABSENCE.** No Cloudflare
cache override is introduced in this PR. Step 3 remains responsible for
partner `Cache-Control: private`; no repo evidence shows Cloudflare caching in
front of `stats.malibu.tech`.

H. Subdomain-trust boundary: **PASS.** The changed nginx files contain no
Origin-based branch, no `Access-Control-*` directives, and no edge-side
short-circuit for `https://evil.malibu.tech`. That request is forwarded to
the coordinator for the Step 3 CORS reject.

I. AC-15 nginx access-log redaction: **PASS STATIC, HARNESS PRESENT BUT NOT RUN
LOCALLY.** The access-log format excludes Authorization, and the harness scans
the mounted stats access log after a keyed request. Local execution skipped
because Docker is unavailable.

J. error_log posture: **PASS.** Stats vhost sets
`error_log /var/log/nginx/stats.malibu.tech-error.log warn;`; no committed
stats nginx config sets `error_log debug`.

## Closed Since r3

- r3 MEDIUM 1 is **closed**. `check_nginx_stats_test.sh:237-284` now implements
  both required checks: no keyed body served to anonymous follow-up, and no new
  on-disk cache file after the keyed request.

## Positive Observations

- INFO: The SECURITY r5 C1 static directive trap is avoided on every stats
  location; `proxy_no_cache` always accompanies `proxy_cache_bypass`.
- INFO: Authorization-bearing requests bypass the nginx public limiter via an
  empty map key, preventing bystander-IP collision from throttling partner-key
  traffic at the edge.
- INFO: The public limiter remains per endpoint, preserving `/overview`,
  `/leaderboard`, and `/health` quota isolation.
- INFO: The committed nginx stats surface emits no CORS headers and cannot
  override Step 3 sibling-subdomain rejection.
- INFO: The 429 edge path uses the security-header snippet pattern required by
  the Pearl add-header inheritance trap.
- INFO: Cache disk use is bounded by `max_size=128m inactive=300s`.
- INFO: The deploy path installs the shared http-context snippet before either
  vhost references its zones/cache/log format.
- INFO: `make test-dist` passed in this environment with the expected local
  Docker skip for the nginx behavior smoke.
- INFO: `git diff --check` passes on the reviewed Step 4.B nginx, deploy, CI,
  and audit files.

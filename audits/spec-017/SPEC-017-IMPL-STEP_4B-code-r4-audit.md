# SPEC-017 IMPL Step 4.B - Code Audit Round 4

Branch: `impl/spec-017-step-1`
HEAD audited: `022cd55` (`impl(017): Step 4.B round-3 fixes - CRITICAL ssl_certificate spacing + harness AC-3 + cache write-suppression`)
Diff base checked: `51b9736`
Auditor lane: CODE
Prior rounds checked:
- `specs/SPEC-017-IMPL-STEP_4B-code-r1-audit.md`
- `specs/SPEC-017-IMPL-STEP_4B-code-r2-audit.md`
- `specs/SPEC-017-IMPL-STEP_4B-code-r3-audit.md`
- `specs/SPEC-017-IMPL-STEP_4B-arch-r1-audit.md`
- `specs/SPEC-017-IMPL-STEP_4B-arch-r2-audit.md`
- `specs/SPEC-017-IMPL-STEP_4B-arch-r3-audit.md`

Verdict: READY TO LOCK -
0 CRITICAL + 0 HIGH + 0 MEDIUM + 1 LOW + 14 INFO

## Validation evidence

- Required reading completed: `SPEC-017-network-stats-api.md` v0.1.8 sections 5.6, 5.7, 6.6.2, 7.1, 7.4, and 8.5; `BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.B and AC-to-step matrix; `SPEC-017-IMPL-STEP_3-r8-convergence.md`; current coordinator/stats nginx files; Step 4.B CODE r1/r2/r3; Step 4.B ARCH r1/r2/r3.
- `git fetch origin` completed; local branch is `impl/spec-017-step-1...origin/impl/spec-017-step-1`.
- `git diff --check 51b9736..HEAD -- phase4-coordinator/dist/ .github/workflows/ci.yml Makefile` - PASS.
- Static directive sweep over `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`, `phase4-coordinator/dist/nginx-stats.streamvc.live.conf`, and `phase4-coordinator/dist/nginx-snippets/*.conf` - PASS for stock nginx directive names, expected `$http_authorization` forwarding/cache bypass references, no stats `burst=`, no `Access-Control-*`, and no nginx-level `Vary: Authorization`.
- Static brace-depth check over `stats-shared.conf`, `stats-security-headers.conf`, `nginx-stats.streamvc.live.conf`, and `nginx-coordinator.streamvc.live.conf` - PASS; final depth 0 for each file.
- Local deploy-sed simulation for both vhosts - PASS. After applying the deploy script's current uncomment expressions, both stats and coordinator vhosts have active `ssl_certificate` and `ssl_certificate_key` lines and zero remaining commented `# ssl_certificate` lines.
- Local `nginx -t` was not directly executable: no local `nginx` binary.
- `docker info` failed locally because the Docker daemon socket is unavailable. Consequently `bash phase4-coordinator/dist/test/check_nginx_stats_test.sh` skipped with `SKIP: docker daemon not reachable; CI runs this test`.
- `make test-dist` - PASS locally, with the same Docker-daemon skip for `check_nginx_stats_test.sh` and the existing optional SPEC-015 live smoke skip. Non-Docker dist tests passed.

## Category verdicts

A. `nginx -t` compatibility: PASS by static syntax/context evidence plus deploy-sed simulation. Local stock `nginx -t` could not run, and the Docker-backed composed-config test skipped locally because Docker daemon is unavailable.

B. map directive correctness: PASS. `stats-shared.conf:24-27` declares `map $http_authorization $public_rl_key` before the three `limit_req_zone` declarations, with an empty key for Authorization-bearing requests.

C. limit_req_zone declarations: PASS. `stats-shared.conf:31-33` declares `stats_overview`, `stats_leaderboard`, and `stats_health` at http context with `:10m` zones and `rate=60r/m`; all stats locations reference matching names.

D. location block ordering: PASS. `nginx-coordinator.streamvc.live.conf:212`, `:232`, and `:252` declare the exact stats endpoint locations before the `/v1/` catch-all at `:280`.

E. proxy_pass posture: PASS. All stats locations proxy to `http://127.0.0.1:8444` without a URI suffix or trailing-slash rewrite.

F. proxy_cache_path: PASS. `stats-shared.conf:39-40` declares `/var/cache/nginx/stats`, `levels=1:2`, `keys_zone=stats_public:10m`, `inactive=300s`, and `use_temp_path=off`; all stats locations use `proxy_cache stats_public`.

G. proxy_cache_bypass + proxy_no_cache: PASS. Every stats location on both hostnames pairs `proxy_cache_bypass $http_authorization` with `proxy_no_cache $http_authorization`.

H. access-log format: PASS. `stats-shared.conf:45-49` defines `stats_redacted` without `$http_authorization`; `stats.streamvc.live` uses it at `nginx-stats.streamvc.live.conf:69`; no changed nginx log format includes `$http_authorization`.

I. Header forwarding: PASS. Stats locations forward Host, X-Real-IP, X-Forwarded-For, X-Forwarded-Proto, and Authorization.

J. HEAD method behavior: PASS. No method-specific nginx block intercepts HEAD; exact stats locations forward to the Step 3 mux, whose convergence record says public and partner HEAD parity is covered.

K. TLS posture: PASS. Both vhosts use TLSv1.2/TLSv1.3 only; `deploy-pearl-vps.sh:396-405` obtains certs for `$DOMAIN` and `$STATS_DOMAIN`, and `:427-436` uncomments cert directives before final `nginx -t`.

L. Test harness: PASS with one LOW. `check_nginx_stats_test.sh` is wired through `Makefile:54` and CI `dist-tooling`, and its executable body now drives nginx `-t`, AC-8, keyed-bypass, per-endpoint isolation, AC-3 invalid-Bearer, proxy_no_cache write-suppression, and AC-15 redaction when Docker is available. It still does not compose the amended coordinator vhost despite saying it does.

## Findings

### CRITICAL

None.

### HIGH

None.

### MEDIUM

None.

### LOW

1. `phase4-coordinator/dist/test/check_nginx_stats_test.sh:5-10` and `:76-96`
   - Evidence: the script header says it validates both the new `nginx-stats.streamvc.live.conf` and the amended `nginx-coordinator.streamvc.live.conf`, but the executable sed/composed-config path only copies and includes a rewritten stats vhost.
   - Risk: this is not a lock blocker because the coordinator vhost's stats locations are statically simple, share the same http-context declarations, and passed the directive/brace/order sweep in this audit. The script comment can still mislead a future maintainer into believing the coordinator hostname is dynamically exercised by the Docker harness.
   - Fix: either narrow the header to the stats-vhost harness it actually runs, or add a second rewritten coordinator vhost to the test composition and curl the coordinator-host stats locations too.

### INFO

- CODE r3 CRITICAL is closed: `nginx-stats.streamvc.live.conf:54-55` now use the exact single-space `# ssl_certificate /etc/letsencrypt...` shape that `deploy-pearl-vps.sh:427-428` matches; local sed simulation activates both certificate directives.
- CODE r3 MEDIUM is closed: `check_nginx_stats_test.sh:228-235` now sends `Authorization: Bearer garbage` through nginx and asserts a 401 unauthorized envelope.
- CODE r3 MEDIUM is closed: `check_nginx_stats_test.sh:237-284` now uses distinguishable partner/public bodies, counts cache files, and asserts the keyed request adds no cache entry and the anonymous follow-up does not receive partner bytes.
- `stats-shared.conf:24-27` implements the preferred map-based Authorization-aware public limiter.
- `stats-shared.conf:31-33` declares separate per-endpoint zones with `rate=60r/m` and no stats `burst=`.
- `nginx-stats.streamvc.live.conf:99-167` uses exact endpoint locations, per-endpoint `limit_req ... nodelay`, `limit_req_status 429`, and no stats `burst=`.
- `nginx-stats.streamvc.live.conf:80-93` and `nginx-coordinator.streamvc.live.conf:302-311` route nginx-generated limiter 429s through a JSON `rate_limited` envelope with `Retry-After: 60`.
- `nginx-stats.streamvc.live.conf:104`, `:132`, and `:155` proxy to `127.0.0.1:8444` with no trailing slash; the coordinator vhost mirrors the same target at `:217`, `:237`, and `:257`.
- `nginx-stats.streamvc.live.conf:119-120`, `:143-144`, and `:166-167` pair cache read-bypass with write-suppression for Authorization-bearing requests; the coordinator vhost mirrors this at `:228-229`, `:248-249`, and `:268-269`.
- `nginx-stats.streamvc.live.conf:63` sets `client_max_body_size 64k`, above the 8K floor named in the CODE prompt.
- `stats-security-headers.conf:20-22` is included inside both `@stats_rate_limited` locations before the response-specific `add_header` directives, avoiding the nginx add-header inheritance trap.
- `deploy-pearl-vps.sh:416-419` installs the shared snippets and stats vhost before installing the coordinator vhost and running final `nginx -t`.
- `Makefile:50-55` wires the stats nginx harness into `make test-dist`.
- `.github/workflows/ci.yml:262-281` runs `make test-dist` on `ubuntu-latest`, where the Docker-backed nginx harness should execute if the hosted Docker daemon is available.

## Round-3 closure checks

- CODE r3 CRITICAL: CLOSED. The prior finding required the stats cert uncomment path to match the shipped vhost. The vhost spacing now matches the deploy sed expression, and local text simulation proves both cert directives are activated.
- CODE r3 MEDIUM: CLOSED. The harness now executes the missing AC-3 invalid-Bearer assertion and the proxy_no_cache write-suppression assertion.

## Final verdict

READY TO LOCK: YES
Blocking count: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 1 LOW / 14 INFO

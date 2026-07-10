# SPEC-017 IMPL Step 4.B — Code Audit Round 1

Branch: `impl/spec-017-step-1`
HEAD audited: `d8a8a45`
Diff base checked: `51b9736`
Auditor lane: CODE
Prior rounds checked: none for Step 4.B CODE.

Verdict: NOT READY TO LOCK —
1 CRITICAL + 0 HIGH + 1 MEDIUM + 0 LOW + 11 INFO

## Validation evidence
- Required reading completed: `SPEC-017-network-stats-api.md` v0.1.8 §5.6 / §5.7 / §6.6.2 / §7.1 / §7.4 / §8.5, `BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.B + AC matrix, Step 3 convergence record, the coordinator nginx vhost, and the new stats nginx vhost.
- `git status -sb` — branch `impl/spec-017-step-1...origin/impl/spec-017-step-1`; pre-existing untracked Step 4.C prompt files ignored.
- `git diff 51b9736..HEAD -- phase4-coordinator/dist/` — Step 4.B adds `nginx-stats.streamvc.live.conf` and the coordinator `/v1/stats/*` allow-through block.
- `grep -RInE 'limit_req_zone|limit_req |proxy_cache|proxy_no_cache|\$http_authorization' phase4-coordinator/dist/nginx-*.conf` — confirmed map/zone/cache/auth directives.
- Static brace-depth check over both nginx files — PASS, balanced braces.
- Static context check — `map`, `limit_req_zone`, `proxy_cache_path`, and `log_format` are outside any `server` block in `nginx-stats.streamvc.live.conf`.
- Local `nginx -t` was not executable: `nginx` is not installed locally, and Docker is present but the Docker daemon socket is unavailable. Static deploy-path evidence below is therefore the load-bearing syntax finding.
- Existing dist nginx tests run:
  - `bash phase4-coordinator/dist/test/check_nginx_receipt_buffers_test.sh` — PASS.
  - `bash phase4-coordinator/dist/test/check_nginx_catalog_routes_test.sh` — PASS.
  - `SPEC015_NGINX_LIVE_OPTIONAL=1 bash phase4-coordinator/dist/test/check_nginx_receipt_header_live_test.sh` — SKIP by explicit optional mode.

## Category Verdicts
A. `nginx -t` compatibility: FAIL — directive spelling/context is otherwise stock nginx, but the deploy-installed coordinator site can reference undeclared `stats_*` limit zones.

B. map directive correctness: PASS within `nginx-stats.streamvc.live.conf` — `map $http_authorization $public_rl_key` precedes the three `limit_req_zone` declarations and uses empty-key bypass for Authorization-present requests.

C. limit_req_zone declarations: FAIL in deployment shape — declarations exist at http context in the stats vhost file, but the coordinator deploy script does not install/enable that file before testing the coordinator vhost that references those zones.

D. location block ordering: PASS — coordinator `/v1/stats/{overview,leaderboard,health}` exact locations are before `location /v1/ { return 404; }`.

E. proxy_pass posture: PASS — all stats locations proxy to `http://127.0.0.1:8444` with no trailing slash rewrite.

F. proxy_cache_path: PASS in the stats vhost file — `/var/cache/nginx/stats`, `levels=1:2`, `keys_zone=stats_public:10m`, `inactive=300s`, and all stats locations reference `proxy_cache stats_public`.

G. proxy_cache_bypass + proxy_no_cache: PASS — every stats location in both vhosts uses both directives with `$http_authorization`.

H. access-log format: PASS for the new stats vhost — `stats_redacted` omits `$http_authorization` and `access_log` uses that format. The coordinator vhost relies on inherited logging, but no `$http_authorization` log format is introduced in this diff.

I. Header forwarding: PASS — Host, X-Real-IP, X-Forwarded-For, X-Forwarded-Proto, and Authorization are forwarded on every stats location.

J. HEAD method behavior: PASS at nginx layer — no method-specific edge block intercepts HEAD; stats requests are forwarded to the Step 3 mux.

K. TLS posture: PASS — stats vhost matches TLSv1.2/TLSv1.3 and certbot-compatible commented certificate paths.

L. Test harness: FAIL — no Step 4.B stats nginx harness was shipped or wired into `make test-dist`.

## Findings

### CRITICAL
1. `phase4-coordinator/dist/deploy-pearl-vps.sh:36`
   - Evidence: the deploy script only requires and uploads `NGINX_SITE="$DIST_DIR/nginx-coordinator.streamvc.live.conf"`, then installs `/tmp/nginx-coordinator-full.conf` to `/etc/nginx/sites-available/$DOMAIN` and runs `nginx -t` at lines 373-384. It never copies, installs, or enables `phase4-coordinator/dist/nginx-stats.streamvc.live.conf`.
   - Evidence: the coordinator vhost now references `limit_req zone=stats_overview`, `stats_leaderboard`, and `stats_health` at `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:213`, `:232`, and `:251`.
   - Evidence: the matching `limit_req_zone` declarations exist only in `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:45-47`.
   - Why this is CRITICAL: the Step 4.B deploy path can install a coordinator vhost whose `limit_req` zones are undeclared in the active nginx config. That is a stock nginx syntax failure class and violates category A/C. It also means the new coordinator `/v1/stats/*` exception can break `nginx -t` before the stats vhost ever serves traffic.
   - Fix: move the shared `map`, three `limit_req_zone` declarations, `proxy_cache_path`, and `log_format` into an http-level snippet installed before any site that references them, and update deploy automation to install/enable that snippet plus the stats vhost before running `nginx -t`. Alternatively, update the deploy script to install/enable `stats.streamvc.live` first and prove include order, but a dedicated snippet is less fragile.

### HIGH
None.

### MEDIUM
1. `Makefile:50`
   - Evidence: `make test-dist` runs only deploy-config, SPEC-015 receipt-buffer, catalog-route, receipt-live, and launchd-install checks. There is no Step 4.B stats nginx test script under `phase4-coordinator/dist/test/`, and no testcontainers-go nginx fixture found under `phase4-coordinator`.
   - Evidence: BUILD Step 4.B requires nginx config validation, AC-8 public 61st-request behavior, AC-3 invalid-bearer-through-nginx behavior, per-endpoint isolation, keyed-through-nginx bypass, `proxy_no_cache` write suppression, and AC-15 nginx access-log redaction.
   - Why this matters: the implementation ships the directives but no executable harness that would catch the CRITICAL deploy-path zone issue or prove the required rate-limit/cache/redaction behavior.
   - Fix: add a `dist/test/check_nginx_stats_test.sh` or testcontainers nginx fixture and wire it into `make test-dist` / CI. It should run `nginx -t` against the actual deployed include shape and drive AC-8, AC-3, per-endpoint isolation, keyed bypass, cache write-suppression, and access-log redaction.

### LOW
None.

### INFO
- `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:40-47` uses the preferred shape (a) map-based Authorization-aware public limiter.
- `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:45-47` declares separate `stats_overview`, `stats_leaderboard`, and `stats_health` zones with `rate=60r/m`.
- `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:116`, `:143`, and `:165` use `limit_req zone=<endpoint> nodelay` with no `burst=`.
- `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:117`, `:144`, and `:166` set `limit_req_status 429`.
- `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:56-57` declares `proxy_cache_path /var/cache/nginx/stats levels=1:2 keys_zone=stats_public:10m max_size=128m inactive=300s use_temp_path=off`.
- `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:134-135`, `:157-158`, and `:179-180` pair `proxy_cache_bypass` with `proxy_no_cache` on `$http_authorization`.
- `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:227-228`, `:246-247`, and `:265-266` mirror the same cache bypass/no-cache pair on the coordinator hostname.
- `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:66-70` defines a redacted stats log format that omits `$http_authorization`.
- `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:119`, `:146`, and `:168` proxy stats endpoints to `127.0.0.1:8444` with no trailing slash.
- `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:212-277` places the three stats exact locations before the `/v1/` catch-all.
- `phase4-coordinator/cmd/coordinator/main.go:523-542` mounts the Step 3 stats mux on `providerMux` at `/v1/stats/`, matching the nginx target port `8444`.

## Final Verdict
READY TO LOCK: NO
Blocking count: 1 CRITICAL / 0 HIGH / 1 MEDIUM / 0 LOW / 11 INFO

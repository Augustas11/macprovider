## Verdict

REQUEST CHANGES

Blocking count: 0 CRITICAL / 0 HIGH / 1 MEDIUM / 1 LOW / 6 INFO.

## Validation evidence

Commands run:

- `git status -sb`
- `git rev-parse --abbrev-ref HEAD && git rev-parse HEAD && git merge-base HEAD main`
- `git diff --name-only $(git merge-base HEAD main)..HEAD`
- `git diff --stat $(git merge-base HEAD main)..HEAD`
- `rg -n "partner[-_ ]?keys|partner_key|mpk_|Authorization|Bearer|Origin|allowed_origins|stats_components_health|last_error_message|JOURNAL_STREAM|token-out|proxy_no_cache|proxy_cache_bypass|/metrics|zerolog|panic|redact|sha256|pqStringArrayLiteral|resolvePrincipal|generatePartnerToken" . --glob '!vendor/**' --glob '!node_modules/**'`
- `rg -n "log_format|access_log|error_log|\\$http_authorization|Authorization|token_hash|mpk_|partner_key_id|label|created_by|reason|last_error_message|panic_type|stats_handler_panic|stats_partner_key_issued|stats_partner_key_revoked|stats_request_served" phase4-coordinator/dist phase4-coordinator/internal/stats phase4-coordinator/cmd/coordinator -g '!**/*_test.go'`
- `rg -n "listen|BindAddress|0\\.0\\.0\\.0|127\\.0\\.0\\.1|/metrics|metrics endpoint|loopback" ...`
- `go test ./internal/stats -run 'TestNormalizeOrigin|TestOriginAllowed|TestAC18_TimingEquivalenceRows5_6_7|TestCORSDecisionTable|TestAC15|TestNoTraceImports' -count=1`
- `go test ./internal/stats/metrics -count=1`
- `go test ./cmd/coordinator -run 'TestPartnerKeys|TestIssue|TestRevoke|Test.*Journal|Test.*TokenOut|Test.*Event|Test.*Origin|Test.*CreatedBy|Test.*Burst' -count=1`

Paths inspected:

- `phase4-coordinator/cmd/coordinator/main.go`
- `phase4-coordinator/cmd/coordinator/partnerkeys.go`
- `phase4-coordinator/internal/config/config.go`
- `phase4-coordinator/internal/stats/auth.go`
- `phase4-coordinator/internal/stats/cors.go`
- `phase4-coordinator/internal/stats/envelope.go`
- `phase4-coordinator/internal/stats/handlers.go`
- `phase4-coordinator/internal/stats/middleware.go`
- `phase4-coordinator/internal/stats/mux.go`
- `phase4-coordinator/internal/stats/origin.go`
- `phase4-coordinator/internal/stats/ratelimit.go`
- `phase4-coordinator/internal/stats/metrics/metrics.go`
- `phase4-coordinator/internal/stats/rollup/health.go`
- `phase4-coordinator/internal/stats/rollup/runner.go`
- `phase4-coordinator/internal/stats/store/store.go`
- `phase4-coordinator/internal/stats/migrations/001_stats_tables.up.sql`
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf`
- `phase4-coordinator/dist/nginx-stats.streamvc.live.conf`
- `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`
- `phase4-coordinator/dist/test/check_nginx_stats_test.sh`
- `OPS.md`

## Findings

### MEDIUM

1. `/metrics` is protected only by deployment posture, not by a stats-specific fail-closed guard.

Evidence: `main.go` mounts `providerMux.Handle("/metrics", promhttp.HandlerFor(...))` whenever `statsPools != nil` (`phase4-coordinator/cmd/coordinator/main.go:534-559`). The same provider listener address is built from `cfg.Listen.BindAddress` and `cfg.Listen.ProviderPort` (`main.go:510-511`). The default bind address is loopback (`phase4-coordinator/internal/config/config.go:381-387`), and OPS documents Pearl as `127.0.0.1:8444` (`OPS.md:23`), but `validateStats()` does not reject `stats.enabled=true` with `listen.bind_address=0.0.0.0`, `::`, or any non-loopback address (`config.go:1022-1068`).

Attack: a misconfigured deployment that exposes provider port 8444 publicly now exposes unauthenticated `/metrics`. That leaks `stats_partner_key_request_total{partner_key_id="N"}` from `metrics.go:69-75`, an oracle for issued key ids and partner usage. The key id is not a raw secret, but it is a monotonic internal identifier and partner-key enumeration surface that did not need to exist publicly.

Fix: when stats are enabled and `/metrics` is mounted on the provider mux, fail startup unless `listen.bind_address` is loopback, or mount metrics on a separate loopback-only listener. Add a config validation test for `stats.enabled=true` + `bind_address=0.0.0.0` and `::`.

### LOW

1. Partner-key CLI accepts control characters in display/audit fields.

Evidence: `--label` only checks non-empty (`partnerkeys.go:170-184`) and is printed raw in the issue metadata line (`partnerkeys.go:290-291`) and list TSV (`partnerkeys.go:529-534`). `--created-by` is trimmed but otherwise accepted as-is (`partnerkeys.go:583-586`) and printed raw in the metadata line. `--reason` only checks non-empty (`partnerkeys.go:377-388`) and is printed raw in revoke stdout (`partnerkeys.go:455`). The JSON structured events use `json.Encoder`, so newline log-line breakout is defeated for `stats_partner_key_issued` / `stats_partner_key_revoked`, but operator-facing stdout remains forgeable with `\n`, `\t`, or terminal escapes.

Attack: an operator or compromised invocation wrapper can create misleading CLI/list output, e.g. a label containing `\nrevoked id=...`. This does not leak a token or bypass auth, but it weakens audit readability.

Fix: validate CLI free-form fields as printable single-line strings with a length cap, or encode them with `%q`/JSON in all operator-facing output.

### INFO

- Nginx access-log redaction is explicit: `stats_redacted` omits `$http_authorization` (`stats-shared.conf:42-49`) and the behavior smoke scans the access log for raw token/body/`token_hash` (`check_nginx_stats_test.sh:308-325`).
- Go request-path redaction is explicit: `redactionContextMiddleware` stores the bearer in context and overwrites `Authorization` with `REDACTED` before downstream logging (`middleware.go:52-72`); recover strips it again (`middleware.go:87-137`).
- `stats_components_health.last_error_message` can persist arbitrary rollup `err.Error()` strings (`rollup/health.go:51-65`, `rollup/runner.go:233-241`), but the rollup path does not touch partner request tokens, and panic payloads are classified by type only (`runner.go:272-287`).
- `partner_keys.token_hash` stores SHA-256 of the raw token by design (`partnerkeys.go:245-277`, `auth.go:214-217`); no request response, metric, or structured event exposes it.
- AC-18’s 100-sample test is not a cryptographic proof against 10,000-sample attackers, but the inspected code path performs the same SHA-256 plus indexed DB SELECT before rows 5/6/7 branch (`auth.go:214-264`), which is the important constant-work property.
- Nginx `proxy_cache_bypass` plus `proxy_no_cache` is correctly paired on all stats locations (`nginx-stats.streamvc.live.conf:122-154`, `160-177`) and has a smoke test proving keyed responses add zero cache files and anonymous follow-up receives public content (`check_nginx_stats_test.sh:251-306`).

## Category sweep

### A. Token redaction surface

Sinks checked:

- Nginx access log: explicit `stats_redacted` format omits Authorization; tested by `check_nginx_stats_test.sh`.
- Nginx error log: standard `error_log ... warn`; no custom header logging found. I did not find a concrete 47-char-token path at warn level, but this is not covered by the access-log smoke.
- Go zerolog request sink: `stats_request_served` emits endpoint/status/latency/age/integer partner key id only (`middleware.go:194-201`).
- Structured partner-key events: issued/revoked events intentionally include label/created_by/reason but no raw token, prefix, or hash (`partnerkeys.go:312-319`, `449-453`); JSON encoding prevents newline record breakout.
- Prometheus labels: closed labels only; partner metric uses integer id only (`metrics.go:10-33`, `69-75`).
- `stats_components_health.last_error_message`: rollup error/panic path only; panic messages classified by type, error strings stored raw.
- CLI stdout list: emits id, label, prefix, timestamps; no raw token/hash (`partnerkeys.go:506-534`), but free-form label can inject display lines.
- `partner_keys.token_hash`: SHA-256 bytes stored as DB credential verifier, never selected into response/event/metric labels.
- Panic stack line: error event omits panic payload; debug stack does not serialize request headers/local token strings (`middleware.go:119-132`). Tests scan raw bearer, panic substring, cookie, API key, and `token_hash`.

Result: no raw-token leak found. Missing guard: CLI display fields are not single-line/safe-display validated.

### B. Origin allowlist bypass

`NormalizeOrigin` lowercases scheme/host, IDNA-punycodes host, strips default ports, and rejects path/query/fragment/userinfo (`origin.go:36-77`). Tests cover uppercase, default port, path/trailing slash/query/fragment/userinfo (`origin_test.go:5-38`). The example `HTTPS://Acme.Example/.` is rejected as pathful; `https://acme.example:443` normalizes to `https://acme.example`; `https://acme.example//path` is rejected as pathful.

Residual: IPv6 and trailing-dot cases are not in `origin_test.go`; by inspection they do not create a bypass against canonical CLI-issued origins because the CLI uses the same normalizer and requires `norm == raw`.

### C. Timing equivalence rows 5, 6, 7

Implementation does the right thing: keyed requests compute SHA-256 and call `LookupPartnerKeyByHash` before no-row, revoked, or origin-allowlist branching (`auth.go:214-264`; `store.go:117-135`). The 100-sample AC-18 test passed locally. A 10,000-sample attacker may still distinguish tiny in-process branch deltas, but not the avoided early-return class; the DB SELECT dominates the route.

### D. `--token-out` file path

`writeTokenFile` uses `O_CREATE|O_EXCL|O_WRONLY` and mode 0600 (`partnerkeys.go:352-367`). This protects the final component against overwrite and final symlink following. Parent directories are still whatever the operator chooses; if the operator writes into an attacker-controlled parent, the attacker can cause operational disruption but should not read a 0600 file owned by the issuing user. No blocker.

### E. `JOURNAL_STREAM` env detection

The CLI refuses stdout raw-token printing when `JOURNAL_STREAM` is set (`partnerkeys.go:321-345`), and tests cover suppression. This protects against accidental systemd-journal capture, not a malicious parent process. An attacker who can run `env -i coordinator partner-keys issue` with the admin DSN can capture stdout by design; that is outside the CLI’s accidental-journal boundary and equivalent to having issuance authority.

### F. `partner_keys` schema / array literal integrity

The INSERT is parameterized (`partnerkeys.go:259-277`). `pqStringArrayLiteral` returns a parameter value, not SQL text concatenated into the query, and also quotes/backslash-escapes defensively (`partnerkeys.go:598-634`). Hostile `--allowed-origin` payloads are rejected before insertion by `NormalizeOrigin` plus canonical equality (`partnerkeys.go:190-207`). SQL injection attempt `'); DROP TABLE partner_keys; --` cannot parse as http/https Origin.

### G. CLI argv injection

Structured JSON event line injection is defeated by `json.Encoder` (`partnerkeys.go:469-474`). However, raw stdout/list formatting still accepts control characters in `label`, `created_by`, and `reason`; recorded as LOW above.

### H. `proxy_cache` hostility

The config pairs read bypass and write suppression on Authorization (`nginx-stats.streamvc.live.conf:129-154`, `176-177`; coordinator vhost mirrors this at `nginx-coordinator.streamvc.live.conf:228-269`). The smoke test warms anonymous cache, sends keyed request, verifies no cache-file count increase, then verifies anonymous follow-up is public (`check_nginx_stats_test.sh:251-306`). I did not find a race that would write the partner projection under this config.

### I. CORS reflection on auth-failed paths

Rejected keyed leaderboard requests return 401 before `writeCORSHeaders` and set only public `Vary` (`mux.go:137-141`); tests expect ACAO absent for rows 3/5/6/7 (`handlers_integration_test.go:1402-1435`). No CORS reflection on auth-failed keyed paths found.

### J. CLI principal default

`resolvePrincipal("")` returns `$USER@hostname`, else `unknown@hostname`, else `unknown@unknown`, with no `os/user.Current()` NSS fallback (`partnerkeys.go:569-596`). An explicit `--created-by postgres` is accepted, so created_by is operator-asserted text, not OS-authenticated identity. That is acceptable if treated as an audit label; it is not strong identity.

### K. Coordinator binary surface increase

Blocking MEDIUM above. `/metrics` is mounted on the provider mux and relies on the global listener being loopback-only. There is no stats-specific guard preventing public bind when stats are enabled.

### L. Anything else

No additional auth bypass found. Notable non-blockers:

- `/overview` and `/health` intentionally ignore Authorization (`mux.go:17-28`, `165-176`), so partner keys do not unlock extra fields there.
- Public/partner projection cache headers diverge correctly (`handlers.go:488-493`; `envelope.go:96-116`).
- The partner metric label uses integer `partner_key_id`, not prefix/label/raw token/hash.

## Final recommendation

Do not lock PR #173 until the `/metrics` exposure guard is fixed or consciously accepted as a documented deployment-only control. The minimal ship fix is a startup validation that rejects `stats.enabled=true` unless `listen.bind_address` is loopback, or a separate loopback-only metrics listener. Also sanitize partner-key CLI display fields before merge or track it as a post-lock hardening item if the team accepts LOW audit-output risk.

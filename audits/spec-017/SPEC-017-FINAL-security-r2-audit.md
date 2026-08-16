## Verdict

REQUEST CHANGES

Blocking count: 1 CRITICAL / 0 HIGH / 0 MEDIUM / 1 LOW / 7 INFO.

## Validation evidence

Commands run:

- `git status -sb`
- `git rev-parse --abbrev-ref HEAD && git rev-parse HEAD && git merge-base HEAD main`
- `git diff --name-only $(git merge-base HEAD main)..HEAD`
- `sed -n '1,260p' CLAUDE.md`
- `sed -n '1,260p' specs/SPEC-017-FINAL-security-audit.md`
- `rg -n "partner[-_ ]?keys|partner_key|mpk_|Authorization|Bearer|Origin|allowed_origins|stats_components_health|last_error_message|JOURNAL_STREAM|token-out|proxy_no_cache|proxy_cache_bypass|/metrics|zerolog|panic|redact|sha256|pqStringArrayLiteral|resolvePrincipal|generatePartnerToken" . --glob '!vendor/**' --glob '!node_modules/**'`
- `rg -n "sign|production|prod|staging|environment|partner_keys_admin_dsn|admin_dsn|PartnerKeysAdminDSN|issue" phase4-coordinator/internal/config phase4-coordinator/cmd/coordinator/partnerkeys.go phase4-coordinator/cmd/coordinator/admin_dsn_parse.go phase4-coordinator/dist/coordinator.yaml.example beta/config-coord.yaml`
- `go test ./internal/config -run TestStatsRequiresLoopbackBind -count=1`
- `go test ./internal/stats -run 'TestNormalizeOrigin|TestOriginAllowed|TestAC12_304IfNoneMatch_CORSHeadersPresent|TestSection_5_7_CORSMatrix|TestAC15_RedactionSweep|TestAC11_RealPanicInjected|TestAC18_TimingEquivalenceRows5_6_7|TestAC22_AuthFailureLimiter' -count=1`
- `go test ./internal/stats/metrics -count=1`
- `go test ./cmd/coordinator -run 'TestPartnerKeys|TestIssue|TestRevoke|TestAC17|TestTokenRedaction|TestStep4C_StatsPartnerKey|TestIssueAllowedOrigin|TestIssueJournalStreamSuppresses|TestIssueTokenOutWritesFile|TestIssueBurstFlagRejected' -count=1`
- `docker info >/dev/null 2>&1; echo docker_status=$?`
- `go test -tags integration ./cmd/coordinator -run 'TestIssueJournalStreamSuppresses|TestIssueTokenOutWritesFile|TestIssueAllowedOriginRFC6454|TestTokenRedactionOnFailedInsert|TestStep4C_StatsPartnerKeyIssuedEvent|TestStep4C_StatsPartnerKeyRevokedEvent' -count=1`
- `./dist/test/check_nginx_stats_test.sh`

Relevant results:

- Branch is `impl/spec-017-step-1` at `264a6061cf7b7727047231966f70613b9e455961`.
- Metrics bind-guard test passed.
- Targeted stats handler, metrics, and tagged partner-key CLI integration tests passed.
- Nginx smoke passed, including keyed bypass, `proxy_no_cache` write suppression, and access-log token redaction.
- Plain `go test ./cmd/coordinator ...` reported `[no tests to run]` because the relevant partner-key integration tests are behind the `integration` build tag; the tagged command above executed the selected subset.

Paths inspected:

- `specs/SPEC-017-network-stats-api.md`
- `specs/SPEC-017-FINAL-security-audit.md`
- `specs/SPEC-017-FINAL-arch-audit.md`
- `specs/SPEC-017-FINAL-code-audit.md`
- `OPS.md`
- `phase4-coordinator/cmd/coordinator/main.go`
- `phase4-coordinator/cmd/coordinator/partnerkeys.go`
- `phase4-coordinator/cmd/coordinator/admin_dsn_parse.go`
- `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go`
- `phase4-coordinator/internal/config/config.go`
- `phase4-coordinator/internal/config/config_stats_bind_test.go`
- `phase4-coordinator/internal/stats/auth.go`
- `phase4-coordinator/internal/stats/cors.go`
- `phase4-coordinator/internal/stats/handlers.go`
- `phase4-coordinator/internal/stats/handlers_integration_test.go`
- `phase4-coordinator/internal/stats/middleware.go`
- `phase4-coordinator/internal/stats/mux.go`
- `phase4-coordinator/internal/stats/origin.go`
- `phase4-coordinator/internal/stats/origin_test.go`
- `phase4-coordinator/internal/stats/store/store.go`
- `phase4-coordinator/internal/stats/metrics/metrics.go`
- `phase4-coordinator/internal/stats/rollup/health.go`
- `phase4-coordinator/internal/stats/rollup/runner.go`
- `phase4-coordinator/dist/nginx-snippets/stats-shared.conf`
- `phase4-coordinator/dist/nginx-stats.malibu.tech.conf`
- `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`
- `phase4-coordinator/dist/test/check_nginx_stats_test.sh`

## Findings

### CRITICAL

1. Production partner-key issuance can bypass the binding §6.6.2 disclosure sign-off gate.

Evidence:

- SPEC §6.6.2 says production issuance of partner keys under §5.4.2, meaning any `coordinator partner-keys issue` invocation on a non-staging coordinator that produces a key delivered to a real partner, "MUST NOT begin" until SPEC-014 v0.9 is deployed, both provider disclosures are live, and the operator runbook has a recorded sign-off entry (`specs/SPEC-017-network-stats-api.md:1529`).
- OPS repeats the gate as "BLOCKING for first PRODUCTION partner-key issuance" and says current status on 2026-06-26 is "NOT YET SATISFIED" (`OPS.md:748`, `OPS.md:779`).
- The CLI issue path accepts `--admin-dsn` / env / YAML DSN, `--label`, optional origin/rpm/principal/rotation fields, then directly generates and inserts the key (`phase4-coordinator/cmd/coordinator/partnerkeys.go:165`, `phase4-coordinator/cmd/coordinator/partnerkeys.go:209`, `phase4-coordinator/cmd/coordinator/partnerkeys.go:245`, `phase4-coordinator/cmd/coordinator/partnerkeys.go:259`).
- `resolveAdminDSN` has no production/staging discriminator or sign-off artifact input (`phase4-coordinator/cmd/coordinator/partnerkeys.go:76`). `parseAdminDSNFromYAML` reads only `stats.partner_keys_admin_dsn` from a trimmed YAML file (`phase4-coordinator/cmd/coordinator/admin_dsn_parse.go:29`).
- Repository search found no sign-off, environment, or production-gate check in the partner-key issue path.

Attack:

An operator or wrapper with the production partner-key admin DSN can run:

```bash
coordinator partner-keys issue --admin-dsn "$PROD_DSN" --label "real partner"
```

and receive a real `mpk_*` token even while OPS says the live disclosure gate is not satisfied. That token unlocks partner projection exact dollar fields for all providers, including providers still publicly bucketed. Under this audit prompt's severity bar, "§6.6.2 sign-off circumvent" is CRITICAL.

Fix direction:

Make the gate mechanical before `INSERT INTO partner_keys`. Minimal acceptable shapes:

- Add a production/staging environment signal to config/CLI and require a signed-off artifact or explicit immutable sign-off fields for production issue.
- Persist the sign-off evidence with the issuance event/row or abort fail-closed when the production sign-off artifact is absent or incomplete.
- Add tests proving production issue cannot insert when the sign-off is missing, while staging issue still works for AC fixtures.

### LOW

1. Partner-key CLI display fields still accept control characters.

Evidence:

- `--label` only checks non-empty (`phase4-coordinator/cmd/coordinator/partnerkeys.go:181`) and is printed raw in issue metadata and TSV list output (`phase4-coordinator/cmd/coordinator/partnerkeys.go:290`, `phase4-coordinator/cmd/coordinator/partnerkeys.go:529`).
- `--created-by` trims but otherwise accepts arbitrary text (`phase4-coordinator/cmd/coordinator/partnerkeys.go:583`) and is printed raw in metadata (`phase4-coordinator/cmd/coordinator/partnerkeys.go:290`).
- `--reason` only checks non-empty (`phase4-coordinator/cmd/coordinator/partnerkeys.go:385`) and is printed raw on revoke stdout (`phase4-coordinator/cmd/coordinator/partnerkeys.go:455`).

Impact:

JSON structured events are encoded with `json.Encoder`, so newline record breakout is defeated for `stats_partner_key_issued` and `stats_partner_key_revoked` (`phase4-coordinator/cmd/coordinator/partnerkeys.go:469`). The remaining issue is operator-facing stdout/list forgery with `\n`, `\t`, or terminal escapes. This is not a token leak or auth bypass, but it weakens audit readability.

Fix direction:

Validate these fields as printable single-line strings with length caps, or encode display output using JSON/quoted formatting.

### INFO

- Round-1 SECURITY M1 is fixed: `validateStats()` now rejects `stats.enabled=true` unless `listen.bind_address` is non-empty loopback (`phase4-coordinator/internal/config/config.go:1022`), and `TestStatsRequiresLoopbackBind` covers loopback accepted plus `0.0.0.0`, `::`, public IP, empty bind, and stats-disabled bypass cases (`phase4-coordinator/internal/config/config_stats_bind_test.go:18`). The targeted test passed.
- `/metrics` is still mounted on the provider mux (`phase4-coordinator/cmd/coordinator/main.go:557`), but the new config-validation guard makes the prior public-bind enumeration issue fail closed before startup.
- Nginx access-log redaction is explicit: `stats_redacted` omits `$http_authorization` (`phase4-coordinator/dist/nginx-snippets/stats-shared.conf:45`), and the nginx smoke test scanned for raw token/body/`token_hash` successfully.
- Go request-path redaction is explicit: `redactionContextMiddleware` stashes the parsed bearer in context and overwrites `Authorization` with `REDACTED`; it also strips `Cookie` and `X-Api-Key` (`phase4-coordinator/internal/stats/middleware.go:52`). The panic path strips again before logging (`phase4-coordinator/internal/stats/middleware.go:87`).
- Rollup `last_error_message` redaction has been hardened since the earlier code audit: ordinary errors are passed through `redactErrMsg` before health persistence (`phase4-coordinator/internal/stats/rollup/runner.go:253`), and tests cover DSN, `mpk_`, and token-hash-shaped substrings.
- 304+CORS is fixed: `writeCORSHeaders` now runs before the 304 branch (`phase4-coordinator/internal/stats/handlers.go:699`), and `TestAC12_304IfNoneMatch_CORSHeadersPresent` passed.
- `partner_keys.token_hash` remains SHA-256 verifier material and is not selected into CLI list, request responses, metric labels, or structured events.

## Category sweep

### A. Token redaction surface

Sinks checked:

- Nginx access log: explicit `stats_redacted` format omits Authorization and passed the smoke scan.
- Nginx error log: configured at `warn`; no custom header logging found.
- Go zerolog request sink: `stats_request_served` emits endpoint/status/latency/generated age/integer partner id only (`phase4-coordinator/internal/stats/middleware.go:194`).
- Structured event lines: partner-key issued/revoked events omit raw token, token body, prefix, and hash; JSON encoding prevents line breakout (`phase4-coordinator/cmd/coordinator/partnerkeys.go:312`, `phase4-coordinator/cmd/coordinator/partnerkeys.go:449`).
- Prometheus labels: closed label sets; partner key metric uses integer id only (`phase4-coordinator/internal/stats/metrics/metrics.go:69`).
- `stats_components_health.last_error_message`: ordinary returned errors are redacted before persistence; panic payloads are classified by type only.
- CLI stdout list: raw token/hash omitted, prefix intentionally shown; display-control chars remain a LOW hardening issue.
- Panic stack line: public panic event omits panic payload; debug stack path does not serialize request headers or token strings (`phase4-coordinator/internal/stats/middleware.go:119`).

Result: no raw-token leak found in tested request/nginx/metrics paths.

### B. Origin allowlist bypass

`NormalizeOrigin` lowercases scheme/host, IDNA-punycodes host, strips default ports, and rejects path/query/fragment/userinfo (`phase4-coordinator/internal/stats/origin.go:36`). CLI issuance requires `norm == raw` for every `--allowed-origin` (`phase4-coordinator/cmd/coordinator/partnerkeys.go:190`), so handler and persisted allowlist semantics share one normalizer.

Prompted probes by inspection:

- `HTTPS://Acme.Example/.` rejects as pathful.
- `https://acme.example:443` normalizes to `https://acme.example`; CLI rejects it as non-canonical.
- `https://acme.example//path` rejects as pathful.
- Punycode uses `idna.Lookup.ToASCII`; Unicode forms cannot directly match an ASCII allowlist unless canonicalized through the same CLI normalizer.

No origin allowlist bypass found.

### C. Timing equivalence for rows 5, 6, 7

All bearer-present paths compute SHA-256 and call `LookupPartnerKeyByHash` before no-row, revoked, or origin-allowlist branching (`phase4-coordinator/internal/stats/auth.go:214`, `phase4-coordinator/internal/stats/store/store.go:117`). `TestAC18_TimingEquivalenceRows5_6_7` uses 100 samples per row and passed locally. A 10,000-sample attacker may distinguish tiny in-process branch deltas, but the avoided early-return class is closed because the indexed DB SELECT dominates all three rows.

### D. Partner-key issuance secret file path

`writeTokenFile` uses `O_CREATE|O_EXCL|O_WRONLY` with mode `0600` (`phase4-coordinator/cmd/coordinator/partnerkeys.go:357`), which protects the final component from overwrite and final symlink following. Parent directories remain operator-chosen; if an operator deliberately writes inside an attacker-controlled directory, an attacker can cause denial/disruption but should not read the new 0600 file owned by the issuing user. No blocker.

### E. `JOURNAL_STREAM` env-detection bypass

The CLI refuses stdout token printing when `JOURNAL_STREAM` is set and no `--token-out` is provided (`phase4-coordinator/cmd/coordinator/partnerkeys.go:341`), and the tagged integration tests passed. This protects accidental systemd-journal capture. A malicious parent process that can run `env -i coordinator partner-keys issue` with the admin DSN can capture stdout by design; that is equivalent to having issuance authority, not a failure of the accidental-journal boundary.

### F. `partner_keys` schema integrity

The INSERT is parameterized (`phase4-coordinator/cmd/coordinator/partnerkeys.go:259`). `pqStringArrayLiteral` is passed as a parameter value, not concatenated into SQL, and it quote/backslash-escapes defensively (`phase4-coordinator/cmd/coordinator/partnerkeys.go:612`). Hostile `--allowed-origin` payloads such as `'); DROP TABLE partner_keys; --` are rejected before insertion by `NormalizeOrigin` plus canonical equality.

### G. CLI subcommand argv injection

No structured-event newline injection found because events are JSON-encoded. Raw stdout/TSV display injection remains the LOW finding above.

### H. `proxy_cache` hostility

Both stats vhosts pair `proxy_cache_bypass $http_authorization` with `proxy_no_cache $http_authorization` on each stats location (`phase4-coordinator/dist/nginx-stats.malibu.tech.conf:129`, `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf:228`). The nginx smoke proved public cache warm-up works, keyed responses add zero cache files, and anonymous follow-up receives the public projection. No cache poisoning path found.

### I. CORS reflection on auth-failed paths

Rejected keyed leaderboard requests return 401 before `writeCORSHeaders` and explicitly set only public `Vary` (`phase4-coordinator/internal/stats/mux.go:137`). The CORS matrix test asserts ACAO absent for rows 3/5/6/7 and passed. No CORS reflection on auth-failed keyed paths found.

### J. CLI principal default

`resolvePrincipal("")` returns `$USER@hostname`, else `unknown@hostname`, else `unknown@unknown`, with no `os/user.Current()` fallback (`phase4-coordinator/cmd/coordinator/partnerkeys.go:583`). An explicit `--created-by postgres` is accepted; this is an operator-asserted audit label, not authenticated OS identity. No security blocker as long as consumers do not treat `created_by` as a strong principal.

### K. Coordinator binary surface area increase

Round-1 `/metrics` blocker is resolved. The endpoint is still unauthenticated on the provider mux, but `stats.enabled=true` now fails config validation unless `listen.bind_address` is loopback. This closes the public-interface partner-key-id enumeration oracle under the audited config path.

### L. Anything else

Blocking issue found: the §6.6.2 launch-sequencing gate is only operational text, not enforced by the CLI before production-capable `partner_keys` insertion. This is the remaining lock blocker.

Other attacks tried that the implementation defeats:

- Raw `mpk_*` token leakage through nginx access logs, Go request logs, metrics labels, CLI structured events, and panic logs.
- Partner projection cache poisoning from interleaved anonymous/keyed nginx requests.
- Origin-rejection early-return timing oracle before hash + DB lookup.

## Final recommendation

Do not lock PR #173. The round-1 metrics exposure is fixed, but the implementation still allows a production partner key to be issued before the binding §6.6.2 disclosure/sign-off precondition is satisfied. Because a valid partner key exposes exact dollar figures for all providers, this is a CRITICAL lock blocker under the prompt's severity bar.

After the production issuance gate is mechanical and tested, the remaining CLI display-field issue can be handled as low-risk hardening unless the team requires perfectly injection-resistant operator output before merge.

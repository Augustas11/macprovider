## Verdict

REQUEST CHANGES

Blocking count: 0 CRITICAL / 1 HIGH / 0 MEDIUM / 1 LOW / 0 INFO

## Validation evidence

- Scope verified: `git rev-parse --short HEAD` -> `e2eb011`; branch `impl/spec-017-step-1`; worktree clean via `git status -sb`.
- Diff scope enumerated with `git diff --name-only $(git merge-base HEAD main)..HEAD`; current merge-base was `e816dffb82cb08a9c8010a467498f9e6a1ac09f9`.
- Inspected request-path auth, redaction, CORS, origin normalization, response headers, metrics, health, rollup error redaction, partner-key CLI, Postgres schema, nginx stats/coordinator vhosts, shared nginx snippets, config validation, and OPS.md.
- Passed: `go test ./internal/config ./internal/stats/metrics`.
- Passed: `go test -tags=integration -timeout 5m ./cmd/coordinator -run 'TestPartnerKeys|TestProductionRequiresSignoff|TestStep4C' -count=1 -v`.
- Failed: `go test -tags=integration -timeout 5m ./internal/stats -run 'TestSection_5_7_CORSMatrix|TestAC18_TimingEquivalenceRows5_6_7|TestActivePartnerOriginsPreflightUnion|TestStep4C|TestPartnerProjectionNeverWildcard|TestAC15|TestAC6' -count=1 -v`.
  Failure: `TestAC18_TimingEquivalenceRows5_6_7`: row5 median `918µs`, row6 median `1.663916ms`, row7 median `2.151708ms`; variance `57.3%`, limit `20%`.
- Passed partially: `bash phase4-coordinator/dist/test/check_nginx_stats_test.sh` validated composed `nginx -t`; local behavior smoke skipped after the upstream mock failed to start.

## Findings

### HIGH

1. AC-18 timing equivalence is not holding; rows 5/6/7 are distinguishable with the implementation's own 100-sample test.

Evidence:
- `phase4-coordinator/internal/stats/handlers_integration_test.go:967` samples 100 requests per row at about 265 rpm, below the 300 rpm auth-failure cap.
- The r3 run failed at `phase4-coordinator/internal/stats/handlers_integration_test.go:1010` with medians row5 `918µs`, row6 `1.663916ms`, row7 `2.151708ms`.
- The code path does a shared hash + SELECT before branching, but then immediately returns through distinct branches for no row, revoked row, and origin mismatch in `phase4-coordinator/internal/stats/auth.go:214`.

Risk:
SPEC §5.4.3 / AC-18 promises rows 5, 6, and 7 are timing-equivalent. A public attacker can pace below the auth-failure limiter and collect far more than 100 samples. The current code already fails at 100 samples locally, so the "DB SELECT dominates branch cost" assumption is false enough to block lock.

Fix direction:
Make the post-SELECT work shape equivalent for rows 5/6/7, or replace the guarantee with a stronger constant response delay/jitter design that is explicitly tested at the intended statistical bar.

### LOW

1. Free-form CLI text is JSON-safe in structured events but not escaped in plaintext operator output.

Evidence:
- Issue metadata prints `label` and `created_by` with raw `%s` to stderr at `phase4-coordinator/cmd/coordinator/partnerkeys.go:343`.
- Revoke prints raw `reason` to stdout at `phase4-coordinator/cmd/coordinator/partnerkeys.go:528`.
- List prints raw `label` in a tab-delimited table at `phase4-coordinator/cmd/coordinator/partnerkeys.go:602`.
- Structured JSON events use `json.Encoder` at `phase4-coordinator/cmd/coordinator/partnerkeys.go:542`, so newline injection does not break the event line itself.

Risk:
An operator or wrapper that passes a label/reason containing newline or tab characters can forge misleading adjacent plaintext lines in terminal or captured operator logs. I am not rating this MEDIUM because the structured `stats_partner_key_issued` / `stats_partner_key_revoked` event lines are JSON-encoded and not line-break injectable.

Fix direction:
Reject or quote control characters for `--label`, `--created-by`, and `--reason`, and add an integration test with `"\nFAKE EVENT\n"` proving both structured events and plaintext diagnostics stay one-record-per-line.

## Category sweep

### A. Token redaction surface

Mostly defeated.

- Go request path: `redactionContextMiddleware` parses the bearer into context, then overwrites `Authorization` with `REDACTED` before access logging and recovery middleware.
- Panic path: recover middleware strips `Authorization`, `Cookie`, and `X-Api-Key`, logs only locked fields, and puts stack details in an untagged debug line.
- Metrics: `partner_key_id` is integer-only, and label hygiene tests passed.
- `stats_components_health.last_error_message`: rollup errors pass through `redactErrMsg`, which redacts `mpk_*`, DSN-shaped substrings, `token_hash=...`, and long hex strings before persistence.
- CLI list omits `token_hash`; issue emits the raw token only to stdout or `--token-out`.
- Nginx access log uses the explicit `stats_redacted` format with no `$http_authorization`; `nginx -t` passed for the composed config. The full live cache/log smoke skipped locally because the mock upstream failed to start.

No raw-token leak found in this pass.

### B. Origin allowlist bypass

No bypass found.

`NormalizeOrigin` lowercases scheme/host, uses `idna.Lookup.ToASCII`, strips default ports, and rejects path/query/fragment/userinfo. The existing unit test covers case and default-port normalization plus slash/path/query/fragment rejection. Inputs such as `HTTPS://Acme.Example/.`, `https://acme.example:443/`, and `https://acme.example//path` are malformed because path is non-empty. A trailing-dot host does not match a non-dot allowlist entry; I did not find a widening bypass.

### C. Timing equivalence for rows 5, 6, 7

Blocking. See HIGH finding 1.

The shared `sha256 + SELECT` is not enough. The implementation's own paced 100-sample test distinguished the rows beyond the allowed band.

### D. Partner-key issuance `--token-out` file path

No token-read attack found.

`writeTokenFile` uses `O_CREAT|O_EXCL|O_WRONLY` and mode `0600`, so a final-component symlink or pre-existing file is refused. A hostile parent directory can deny, delete, or observe the filename if the operator chooses that directory, but cannot read a different user's `0600` file solely from directory ownership. This is operator path hygiene, not a production secret leak in the code path.

### E. `JOURNAL_STREAM` detection bypass

No blocker.

The guard prevents accidental stdout capture when systemd sets `JOURNAL_STREAM`; the tagged integration test confirms suppression and the r3 signoff/event tests passed. A process that intentionally clears the environment and captures stdout can capture the token by design. That is outside the CLI's accidental-journal-capture boundary.

### F. `partner_keys` schema integrity / array literal

No SQL injection found.

The INSERT is parameterized, and `allowed_origins` is supplied as one parameter. Origins are normalized by the same request-path normalizer and must be canonical before insertion. Classic payloads with quotes, semicolons, paths, or userinfo are rejected before the array literal builder matters.

### G. CLI subcommand argv injection

Low issue found in plaintext diagnostics only.

Structured event lines are JSON-encoded and survive newlines safely; plaintext stderr/stdout/list rows do not quote control characters. See LOW finding 1.

### H. `proxy_cache` hostility

No source-level bypass found.

Both stats vhosts pair `proxy_cache_bypass $http_authorization` with `proxy_no_cache $http_authorization` on all three stats locations, which is the correct read-bypass plus write-suppression contract. The local nginx behavior smoke did not complete beyond `nginx -t`, so I am relying on config inspection plus the existing script coverage intent for the race/cache-poisoning case.

### I. CORS reflection on auth-failed paths

Defeated.

Rows 3/5/6/7 return 401 without echoing the attacker's Origin. The integration CORS matrix passed and asserts absent ACAO for those rows. Successful partner projection echoes only the normalized Origin and includes credentials; public projection uses `*` without credentials.

### J. CLI principal default

No blocker.

`resolvePrincipal("")` uses trimmed `$USER` plus hostname, else `unknown@host` / `unknown@unknown`; it intentionally avoids NSS `os/user.Current()` drift. A malicious operator can pass `--created-by postgres`, but that requires operator authority on the issuance command and is an audit-fraud problem, not an elevation path for a non-admin shell.

### K. Coordinator binary surface area increase / `/metrics`

Defeated.

`/metrics` is mounted on the provider mux only when stats are enabled. Config validation now fails closed unless `listen.bind_address` is loopback, with a specific error naming the `partner_key_id` enumeration risk. The config/metrics unit tests passed.

### L. Additional attack surface

No additional CRITICAL/HIGH/MEDIUM issues found beyond timing equivalence.

The r3 production signoff closure is present and mechanically tested: production issuance requires `--production` plus a well-formed `--signoff-spec-6-6-2` before DSN resolution, and the event carries the signoff fields on success.

## Final recommendation

Do not lock PR #173 in this state. The final security gate should remain closed until AC-18 passes reliably under the integration test and the implementation no longer depends on the disproven claim that the DB SELECT dominates all row-specific timing.

After the timing blocker is fixed, rerun:

- `go test -tags=integration -timeout 5m ./internal/stats -run 'TestAC18_TimingEquivalenceRows5_6_7' -count=1 -v`
- the broader SPEC-017 integration subset used above
- the nginx stats smoke in an environment where the upstream mock starts, so the cache write-suppression behavior is observed, not just syntactically validated.

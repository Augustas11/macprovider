# SPEC-017 IMPL Step 4.A - Security Audit Round 1

Branch: `impl/spec-017-step-1`
HEAD audited: `51b9736cc8d9817cedc5cab119a8b36871904aca` (`impl(017): Step 4.A - partner-keys CLI + visibility revert (initial drop)`)
Diff base: Step 3 converged tip `2b27256`
Auditor lane: SECURITY
Prior rounds checked: none; this is Step 4.A security round 1.

Verdict: NOT READY TO LOCK - 0 CRITICAL + 1 HIGH + 0 MEDIUM + 2 LOW + 8 INFO

## Validation evidence

- `git status -sb`: on `impl/spec-017-step-1...origin/impl/spec-017-step-1`.
- `git diff --name-only 2b27256..HEAD -- phase4-coordinator/`: scoped to `cmd/coordinator/{admin_dsn_parse.go,main.go,partnerkeys.go,partnerkeys_integration_test.go,visibility.go,visibility_integration_test.go}` and `internal/stats/{auth.go,cors.go,mux.go,origin.go,origin_test.go}`.
- Required reading completed: `CLAUDE.md`; locked `specs/SPEC-017-network-stats-api.md` v0.1.8 focused on §5.4.3, §5.4.6, §5.7, §6.5, §6.6.2, §7.2.4, §7.4, AC-15, AC-17, AC-20; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.A, §C.3, Step 4.C log/runbook rows, AC matrix; `specs/SPEC-017-IMPL-STEP_3-r8-convergence.md`; `phase4-coordinator/internal/stats/migrations/001_stats_tables.up.sql`.
- `go build ./...` from `phase4-coordinator/`: PASS.
- `go test ./cmd/coordinator/... ./internal/stats/...`: PASS.
- `go vet ./...`: PASS.
- `gofmt -l ./cmd/coordinator ./internal/stats`: PASS, no output.
- `go list -f '{{.ImportPath}} {{join .Imports "\n"}}' ./cmd/coordinator`: imports `crypto/rand`, `crypto/sha256`, `database/sql`, shared `internal/stats`; no `math/rand`; no `internal/stats/store` admin-side helper path beyond daemon imports already present in `main.go`.
- `go test -tags=integration ./cmd/coordinator/...`: NOT RUN TO COMPLETION; local environment panicked in testcontainers setup with `rootless Docker not found` before the first Postgres fixture.
- `rg -n "rate_limit_burst" phase4-coordinator --glob '!**/*_test.go' --glob '!internal/stats/migrations/**'`: one non-runtime comment hit in `cmd/coordinator/partnerkeys.go:156`; no column/flag implementation hit.
- Static sweeps: `rg` found `crypto/rand` only in `partnerkeys.go`, `rand.Read` only at `partnerkeys.go:448`, no `"math/rand"` import in Step 4.A CLI files, no `net.LookupCNAME` or hostname-resolution helper, no `--mode` / `--exact` flag definition for `visibility revert`, and no `stats_partner_key_issued` / `stats_partner_key_revoked` emit in Step 4.A code.

## Category Verdicts

A. Token-leak surface map: FAIL HIGH - raw token is printed to ordinary stdout at `partnerkeys.go:289`; if the CLI is launched through a journald-capturing wrapper, that stdout becomes durable journal content. Other reviewed surfaces avoid raw token/body/hash: stderr paths do not include generated token material, list SELECT omits `token_hash`, and visibility audit writes only provider visibility fields.

B. CSPRNG audit: PASS - `partnerkeys.go` imports `crypto/rand` and calls `rand.Read(random[:])` with error handling at `partnerkeys.go:447-449`; no `math/rand` import appears in `cmd/coordinator`.

C. Admin DSN handling: PASS with LOW hygiene - subcommands resolve an admin DSN and open/close a local `*sql.DB` per invocation (`partnerkeys.go:206-221`, `318-323`, `387-397`; `visibility.go:87-97`). The daemon path passes `PartnerKeysAdminDSN` through `stats.Config` but `stats.Open` does not validate or open it. Error strings do not explicitly print the DSN, but `--admin-dsn` in argv remains operator hygiene risk.

D. No reuse of runtime DSNs: PASS - `resolveAdminDSN` uses `--admin-dsn`, `COORDINATOR_PARTNER_KEYS_ADMIN_DSN`, or `stats.partner_keys_admin_dsn` only; no fallback to `stats_reader_dsn`, `stats_rollup_dsn`, `provider_portal_dsn`, or `partner_keys.writer_dsn`.

E. Visibility revert privilege boundary: PASS - `visibility revert` defines only `--id`, `--reason`, `--config`, and `--admin-dsn`; the SQL hardcodes `mode = 'bucketed'`, `new_mode = 'bucketed'`, and `actor_kind = 'operator'` at `visibility.go:139-157`; `visibility exact` is hard-rejected at `visibility.go:41-50`.

F. `actor_id` PII / fingerprint surface: PASS - default principal uses `$USER`, fallback `os/user.Current`, and `os.Hostname()` only (`partnerkeys.go:473-487`); no DNS/FQDN lookup code was found. The value is durable in `provider_visibility_audit`, as expected.

G. Structured log emissions: PASS for leak, LOW for completeness - Step 4.A emits no `stats_partner_key_issued` or `stats_partner_key_revoked` structured event, so it does not leak token material there. The absence of those events is an observability/completeness gap against BUILD Step 4.C expectations, not a secret leak by itself.

H. RFC 6454 normalization parity: PASS - the CLI calls exported `stats.NormalizeOrigin` at `partnerkeys.go:194`, and Step 3 handler/preflight/mux code now calls the same exported helper in `internal/stats/{auth.go,cors.go,mux.go}`.

I. Operator runbook redaction defaults: PASS/NOT YET APPLICABLE - no Step 4.C `OPS.md` partner-key recipes were present in this Step 4.A diff, and no real-looking `mpk_*` recipe string was found in `OPS.md`. This must be rechecked in Step 4.C.

J. AC-15 / journalctl scan: FAIL HIGH - tests capture in-memory stdout/stderr and DB state, but no test executes the built CLI under `systemd-run --user` or an equivalent journald-readable wrapper. More importantly, the current stdout behavior would put the raw token in the journal when stdout is captured by systemd.

## Findings

### CRITICAL

None.

### HIGH

1. `phase4-coordinator/cmd/coordinator/partnerkeys.go:287`
   - Evidence: `runPartnerKeysIssue` writes metadata to `stdout` and then writes `rawToken` to the same `stdout` stream at `partnerkeys.go:287-289`. The integration suite only calls the function with `bytes.Buffer` writers (`partnerkeys_integration_test.go:121-124`) and has no `systemd-run --user` / `journalctl --user` wrapper assertion.
   - Why: AC-17 allows exactly one raw-token print to the operator, but §5.4.6 and the Step 4.A SECURITY prompt require the raw token, 43-char body, and `token_hash` not to appear in journald. Under systemd, stdout is commonly captured as a durable journal stream. A command such as `systemd-run --user --wait coordinator partner-keys issue --label X ...` would persist the raw `mpk_...` line in `journalctl --user`, converting the one-time stdout secret into a durable log leak. The prompt's severity model names this as HIGH.
   - Fix: Add a journald-safe execution shape and test. Minimal acceptable patch: when `JOURNAL_STREAM`/systemd-captured stdout is detected, do not emit the raw token to the journal stream; either refuse with a clear error instructing the operator to run from an interactive terminal or write the one-time token only to an explicitly opened operator TTY/0600 output file while logging only label/id/prefix metadata. Then add an integration/smoke test that runs the compiled CLI under `systemd-run --user` or the repo's journal-readable equivalent and asserts `journalctl --user` contains label + prefix only, not the raw token, token body substring, or `token_hash`.

### MEDIUM

None.

### LOW

1. `phase4-coordinator/cmd/coordinator/partnerkeys.go:167`
   - Evidence: all Step 4.A subcommands accept `--admin-dsn`; integration tests use `--admin-dsn` directly. Postgres DSNs often embed passwords, and command-line args can land in shell history or process listings while the command is running.
   - Why: This is not the raw partner token and is not currently logged by the code, so it is not a lock-target blocker under the supplied severity model. It is still weaker than the preferred env/config-file path for an operator admin secret.
   - Fix: Prefer env/config in docs and tests where possible. Consider hiding `--admin-dsn` behind test-only helpers or documenting it as local/test-only with a warning.

2. `phase4-coordinator/cmd/coordinator/partnerkeys.go:156`
   - Evidence: the literal `rate_limit_burst` remains in a non-test, non-migration comment. The required validation scan for `rate_limit_burst` in non-test/non-migration paths therefore does not return zero hits, even though no column or flag is implemented.
   - Why: Not a security leak and not a behavior defect, but it weakens the mechanical v0.1.8 "burst removed" validation.
   - Fix: Reword the comment without the removed identifier or narrow the validation command to executable tokens if the team wants comments allowed.

### INFO

- `partnerkeys.go:256-274` inserts only `label`, `token_hash`, `token_hash_alg`, `prefix`, `allowed_origins`, `rate_limit_rpm`, `created_by`, and `rotated_from_id`; no raw token or body is inserted.
- `partnerkeys.go:400-403` list SELECT deliberately omits `token_hash`; stdout columns are `id`, `label`, `prefix`, `created_at`, `revoked_at`, `last_used_at`, `rotated_from_id`.
- `partnerkeys.go:242-289` generates the raw token after validation and prints it only after successful INSERT, avoiding an unbound-token print on DB failure.
- `partnerkeys_integration_test.go:394-437` covers failed INSERT stdout/stderr redaction in the in-memory function-call path.
- `visibility.go:139-157` hardcodes bucketed/operator values in SQL, not flag-derived parameters.
- `visibility_integration_test.go:100-130` asserts AC-20 (`new_mode='exact' AND actor_kind='operator'`) remains zero after a revert.
- `internal/stats/origin.go:36-77` is exported and shared by CLI plus handler, closing normalization drift risk.
- `cmd/coordinator/main.go:67-73` dispatches CLI verbs before daemon flag parsing, and `stats.Open` does not open `PartnerKeysAdminDSN`.

## Round-0 Closure Checks

No prior Step 4.A SECURITY rounds exist.

## Final Verdict

READY TO LOCK: NO

Blocking count: 0 CRITICAL / 1 HIGH / 0 MEDIUM / 2 LOW / 8 INFO.

The lock target is not met because the raw token can become durable journal content when stdout is captured by systemd, and the required journalctl-style AC-15/AC-17 assertion is absent.

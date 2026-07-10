# SPEC-017 IMPL Step 4.A - Security Audit Round 2

Branch: `impl/spec-017-step-1`
HEAD audited: `6248b9e` (`impl(017): Step 4.A round-1 fixes (CODE H1 + SECURITY H1 + 4M + 3L) + Step 4.B nginx vhost`)
Diff base: Step 3 converged tip `2b27256`
Auditor lane: SECURITY
Prior rounds checked: `specs/SPEC-017-IMPL-STEP_4A-security-r1-audit.md`

Verdict: READY TO LOCK - 0 CRITICAL + 0 HIGH + 0 MEDIUM + 2 LOW + 10 INFO

## Validation evidence

- `git status -sb`: on `impl/spec-017-step-1...origin/impl/spec-017-step-1`; unrelated Step 4.A ARCH/CODE round-2 artifacts and a CODE-lane edit to `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go` were present during final sanity status and were not touched by this SECURITY audit.
- Required reading completed: `CLAUDE.md`; locked `specs/SPEC-017-network-stats-api.md` v0.1.8 focused on §5.4.3, §5.4.6, §5.7, §6.5, §6.6.2, §7.2.4, §7.4, AC-15, AC-17, AC-20; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.A, §C.3, Step 4.C log/runbook rows, AC matrix; Step 4.A ARCH prompt; Step 4.A SECURITY r1 audit.
- `git diff --name-status 2b27256...HEAD`: Step 4.A delta includes `cmd/coordinator/{admin_dsn_parse.go,main.go,partnerkeys.go,visibility.go}`, CLI tests, shared origin helper changes, and Step 4.B nginx prompt/config additions.
- `git diff --name-status 51b9736..HEAD`: round-1 fixes touched dispatcher, partner-key token/journal behavior, list output, principal fallback, tests, and Step 4.B artifacts.
- `go build ./...` from `phase4-coordinator/`: PASS.
- `go test ./cmd/coordinator/... ./internal/stats/...` from `phase4-coordinator/`: PASS.
- `go vet ./...` from `phase4-coordinator/`: PASS.
- `gofmt -l ./cmd/coordinator ./internal/stats` from `phase4-coordinator/`: PASS, no output.
- `go test -tags=integration ./cmd/coordinator/... ./internal/stats/...`: NOT RUN TO COMPLETION in this local environment; `testcontainers-go` panicked before fixtures with `rootless Docker not found`.
- `go list -f '{{join .Imports "\n"}}' ./cmd/coordinator | rg ...`: package imports include `crypto/rand` and shared `internal/stats`; no `math/rand` or `os/user`.
- Static sweeps: no executable `math/rand`, `net.Lookup*`, `actor-kind` override, runtime-DSN fallback in Step 4.A CLI files, or `stats_partner_key_issued` / `stats_partner_key_revoked` emissions. `--mode` / `--exact` hits are comments and the hard-rejected `visibility exact` path.
- `git grep -n "mpk_" HEAD -- OPS.md specs`: no `OPS.md` hits; Step 4.C partner-key runbook recipes are not present yet.

## Category Verdicts

A. Token-leak surface map: PASS. `runPartnerKeysIssue` generates the raw token after validation, stores only `token_hash` bytes plus `prefix`, prints journal-safe metadata, and emits the raw token only to stdout when not journal-captured or to an explicit `--token-out` 0600 file (`partnerkeys.go:244-317`, `326-335`). Stderr paths do not format raw token/body/hash. `partner-keys list` omits `token_hash` (`partnerkeys.go:448-457`). `provider_visibility_audit` carries no partner-key fields (`visibility.go:153-157`).

B. CSPRNG audit: PASS. `crypto/rand` is imported; `generatePartnerToken` calls `rand.Read(random[:])` and checks the error before encoding (`partnerkeys.go:492-507`). No `math/rand` import appears in `cmd/coordinator`.

C. Admin DSN handling: PASS. Subcommands resolve `--admin-dsn` / `COORDINATOR_PARTNER_KEYS_ADMIN_DSN` / `stats.partner_keys_admin_dsn`, open a local `*sql.DB`, and `defer db.Close()` (`partnerkeys.go:208-223`, `435-445`; `visibility.go:87-97`). The daemon passes `PartnerKeysAdminDSN` through config but `stats.Open` opens only reader, rollup, provider-portal, and optional writer pools (`main.go:163-178`; `internal/stats/stats.go:177-220`).

D. No reuse of runtime DSNs: PASS. Step 4.A CLI files contain no references to `stats_reader_dsn`, `stats_rollup_dsn`, `provider_portal_dsn`, or `partner_keys_writer_dsn`. `stats.Open` validates those runtime DSNs separately and never uses them as admin fallbacks (`internal/stats/stats.go:230-245`).

E. Visibility revert privilege boundary: PASS. `visibility revert` exposes only `--config`, `--admin-dsn`, `--id`, and `--reason`; UPDATE hardcodes `mode = 'bucketed'`; audit INSERT hardcodes `new_mode = 'bucketed'` and `actor_kind = 'operator'` (`visibility.go:69-75`, `139-157`). `visibility exact` is explicitly rejected, and tests assert both rejection and AC-20 zero-count (`dispatch_test.go:109-122`; `visibility_integration_test.go:98-129`).

F. `actor_id` PII / fingerprint surface: PASS. Default principal is `$USER@os.Hostname()` with `unknown` fallbacks; the round-1 `os/user.Current` fallback was removed (`partnerkeys.go:525-537`). No DNS or FQDN lookup helper was found.

G. Structured log emissions: PASS for leak. Step 4.A emits no `stats_partner_key_issued` or `stats_partner_key_revoked` structured log events, so raw token/body/hash cannot leak through those fields in this step. Step 4.C still owns event/runbook completion.

H. RFC 6454 normalization parity: PASS. CLI issue validation calls the exported `stats.NormalizeOrigin` helper (`partnerkeys.go:195-205`), and the request handler uses the same helper before allowlist comparisons (`internal/stats/origin.go:36-77`; `internal/stats/auth.go:170-171`).

I. Operator runbook redaction defaults: PASS / NOT YET APPLICABLE. `OPS.md` has no Step 4.C partner-key recipes yet and no real-looking `mpk_*` strings. Recheck when Step 4.C lands.

J. AC-15 / journalctl scan: PASS with local validation gap. The r1 HIGH behavior is fixed: when `JOURNAL_STREAM` is set and no `--token-out` is supplied, the CLI refuses to print the raw token to stdout and exits non-zero after telling the operator to revoke the inserted row (`partnerkeys.go:311-315`). Tests cover the `JOURNAL_STREAM` branch and `--token-out` 0600 file path (`partnerkeys_integration_test.go` near `TestIssueJournalStreamSuppresses` / `TestIssueTokenOutWritesFile`), but this local machine could not run the Docker-backed integration suite, and no actual `systemd-run --user` wrapper was executed here.

## Findings

### CRITICAL

None.

### HIGH

None.

### MEDIUM

None.

### LOW

1. `phase4-coordinator/cmd/coordinator/partnerkeys.go:168`
   - Evidence: Step 4.A still exposes `--admin-dsn`, and integration tests pass DSNs on argv.
   - Why: Postgres DSNs commonly embed passwords; argv can be visible in shell history or short-lived process listings. The code does not log the DSN, and env/config are available, so this is operator hygiene rather than a lock-target leak.
   - Fix: In Step 4.C `OPS.md`, prefer `COORDINATOR_PARTNER_KEYS_ADMIN_DSN` or a minimal `--config` file and document `--admin-dsn` as test/local-only.

2. `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go`
   - Evidence: the journal-suppression assertion simulates systemd capture with `JOURNAL_STREAM` in an integration test, but there is no committed `systemd-run --user` / `journalctl --user` harness.
   - Why: The source behavior is now journal-safe, but the exact AC-15-style journal scan remains environment-dependent and was not executable on this machine.
   - Fix: Add a host-gated smoke script or CI job that skips cleanly when user-systemd is absent and otherwise asserts `journalctl --user` contains only metadata, not raw token/body/hash.

### INFO

- R1 SECURITY H1 is closed: `JOURNAL_STREAM` suppresses raw stdout token emission and `--token-out` writes an operator-owned 0600 file instead (`partnerkeys.go:299-317`, `326-335`).
- R1 CODE H1 is closed: unknown top-level subcommands now exit 2 with usage instead of falling into daemon config load (`main.go:67-90`; `dispatch_test.go:71-91`).
- R1 ARCH/CODE list-column finding is closed: `partner-keys list` selects and prints only `id`, `label`, `prefix`, `created_at`, `revoked_at`, `last_used_at` (`partnerkeys.go:448-457`).
- R1 ARCH principal drift is closed: no `os/user` import or NSS lookup remains; `$USER` unset maps to `unknown`.
- `partnerkeys.go:258-276` INSERTs only the locked partner-key row fields and never stores the raw token or 43-character body.
- `partnerkeys.go:277-283` returns on INSERT failure before metadata or raw-token output.
- `partnerkeys.go:492-507` enforces the 43-character base64url body invariant before constructing `mpk_`.
- `visibility.go:102-107` starts a transaction and `SELECT ... FOR UPDATE`s the visibility row before bucketed update plus audit insert.
- `visibility_integration_test.go:98-129` asserts no `new_mode='exact' AND actor_kind='operator'` row after revert.
- `OPS.md` has no Step 4.C partner-key recipe surface yet, so there are no real-looking runbook `mpk_*` tokens to redact in this round.

## Round-1 Closure Checks

- SECURITY r1 HIGH 1 (raw token can enter journald through stdout): CLOSED. Current code refuses raw stdout token emission when `JOURNAL_STREAM` is present and offers `--token-out` 0600 delivery.
- SECURITY r1 LOW 1 (`--admin-dsn` argv hygiene): STILL LOW. No code leak, but Step 4.C docs should steer operators to env/config.
- SECURITY r1 LOW 2 (`rate_limit_burst` production comment): CLOSED for Step 4.A executable code. The remaining hit is a migration comment outside the Step 4.A CLI path.

## Final Verdict

READY TO LOCK: YES

Blocking count: 0 CRITICAL / 0 HIGH / 0 MEDIUM. The Step 4.A SECURITY lock target is met. LOW items are deferrable to Step 4.C runbook/CI hardening.

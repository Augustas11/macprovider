# SPEC-017 IMPL Step 4.A - Code Audit Round 3

Branch: `impl/spec-017-step-1`
HEAD audited: `d8a8a4538b34d62a530263b75a7cddccba7279be` (`impl(017): Step 4.A round-2 fixes (CODE 2M closure) - subprocess + handler test surface`)
Diff base: Step 3 converged tip `2b27256`
Auditor lane: CODE
Prior rounds checked:
- `specs/SPEC-017-IMPL-STEP_4A-code-r1-audit.md` - 0 CRITICAL / 1 HIGH / 2 MEDIUM / 1 LOW / 8 INFO.
- `specs/SPEC-017-IMPL-STEP_4A-code-r2-audit.md` - 0 CRITICAL / 0 HIGH / 2 MEDIUM / 0 LOW / 12 INFO.

Verdict: NOT READY TO LOCK -
0 CRITICAL + 0 HIGH + 1 MEDIUM + 0 LOW + 13 INFO

## Validation evidence
- `git status -sb` - branch `impl/spec-017-step-1...origin/impl/spec-017-step-1`; working tree contained only this audit-file write after review started.
- `git rev-parse HEAD && git log -1 --pretty=%s` - audited `d8a8a4538b34d62a530263b75a7cddccba7279be`, subject above.
- `git diff --name-status 2b27256...HEAD` - Step 4.A implementation files present under `cmd/coordinator/{main.go,admin_dsn_parse.go,partnerkeys.go,partnerkeys_integration_test.go,visibility.go,visibility_integration_test.go,dispatch_test.go}` plus shared Step 3 origin helper changes and Step 4.B nginx files outside this CODE lane.
- `git diff --stat 6248b9e..HEAD` - only code delta after round 2 is `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go`; production CLI files are unchanged from the round-2 implementation.
- `go build ./...` from `phase4-coordinator/` - PASS.
- `go test ./cmd/coordinator/... ./internal/stats/...` from `phase4-coordinator/` - PASS.
- `go vet ./...` from `phase4-coordinator/` - PASS.
- `gofmt -l ./cmd/coordinator ./internal/stats` from `phase4-coordinator/` - PASS, no output.
- `rg -n "rate_limit_burst" phase4-coordinator --glob '!**/*_test.go' --glob '!**/migrations/**'` - PASS, no non-test/non-migration hits.
- `go list -f '{{.ImportPath}} {{join .Imports "\n"}}' ./cmd/coordinator` - package imports include `internal/stats/store` through daemon code, but Step 4.A CLI writes are local `database/sql` admin-DSN paths; no reader-store INSERT path found.
- `go test -tags=integration ./cmd/coordinator -list 'Test'` - PASS; lists Step 4.A subprocess tests for AC-17, explicit `--created-by`, RFC 6454, `--burst`, missing revoke, and rotation-through-handler, plus visibility tests.
- `go test -tags=integration ./cmd/coordinator/... ./internal/stats/... -run TestDoesNotExist -count=0` - PASS compile-only for the integration-tag packages.
- `go test -tags=integration ./cmd/coordinator -run TestAC17_IssueLockedSPECCommand_Subprocess -count=1` - BLOCKED by local runtime before product assertions: testcontainers panicked with `rootless Docker not found`.
- `go test -tags=integration ./cmd/coordinator -run TestRotationThroughHandler_Subprocess -count=1` - BLOCKED by the same local Docker panic before product assertions.
- Static fixture/schema sweep found `partnerkeys_integration_test.go:62` still inserting `stats_rewards_populated (singleton, ...)` and `partnerkeys_integration_test.go:65` still inserting `stats_leaderboard_24h (provider_id, rank, ..., active_accounts, ...)`, while the locked migrations define `stats_rewards_populated.window_label` and `stats_leaderboard_24h.rank_earnings/rank_tokens/rank_jobs` with no `rank` or `active_accounts` column.

## Category Verdicts
A. Subcommand dispatch: PASS - `main.go` dispatches `partner-keys` and `visibility` before daemon flag parsing, preserves daemon flag forms, and rejects unknown non-flag first positionals with usage plus exit 2.

B. `flag.NewFlagSet` per subcommand: PASS - issue, revoke, list, and visibility revert each use isolated `flag.FlagSet` instances; repeatable `--allowed-origin` appends via `flag.Var`.

C. CSPRNG usage: PASS - `generatePartnerToken` uses `crypto/rand.Read` on 32 bytes and aborts on error without printing partial token material.

D. base64url encoding: PASS - token body uses `base64.RawURLEncoding.EncodeToString` and enforces the 43-character invariant.

E. Token assembly + sha256: PASS - raw token is `"mpk_" + body`, hash is `sha256.Sum256([]byte(raw))`, and prefix is the first 8 bytes of the generated ASCII token.

F. INSERT statement: PASS - issue inserts `label`, `token_hash`, `token_hash_alg`, `prefix`, `allowed_origins`, `rate_limit_rpm`, `created_by`, and `rotated_from_id`; absent rotation uses SQL NULL; no removed burst column is inserted.

G. Print exactly once on success: PASS - the default interactive path prints the raw token once after INSERT; `JOURNAL_STREAM`/`--token-out` is the acknowledged security-lane exception and does not print the raw token to stdout.

H. Rotation path: PASS for implementation, FAIL for required handler-proof test - production code verifies the predecessor row exists, stores `rotated_from_id`, and does not auto-revoke, but the new handler-level subprocess regression test has stale seed SQL and cannot prove A and B authenticate through the Step 3 handler.

I. Revoke + list: PASS - revoke returns clean non-panic errors for missing rows and updates `revoked_at` plus `revoked_reason`; list SELECT/output is limited to id, label, prefix, created_at, revoked_at, last_used_at, with no `token_hash`.

J. Visibility revert: PASS - one transaction, `SELECT ... FOR UPDATE`, hard-coded `mode='bucketed'`, audit insert with `actor_kind='operator'`, and no accepted exact-enable flag/verb.

K. Operator DSN open + close: PASS - subcommands open `sql.Open("postgres", dsn)` at CLI entry and defer `Close`; daemon startup does not open `PartnerKeysAdminDSN`; error paths do not format the DSN value.

L. Error wrapping hygiene: PASS - implementation does not include raw token/body/hash in error strings; failed INSERT returns before metadata/token output; tests now scan for arbitrary 43-character base64url body substrings in stderr.

M. Tests: FAIL - subprocess coverage was added for most locked variants, and the prefix-vs-token assertion bug is fixed, but the new rotation-through-handler subprocess test is not executable against the locked schema because its seed SQL uses stale Step 3 table shapes.

## Findings
### CRITICAL
None.

### HIGH
None.

### MEDIUM
1. `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:62`
   - Evidence: `seedRotationHandlerFixture` inserts `stats_rewards_populated (singleton, rewards_populated, generated_at)` and later inserts `stats_leaderboard_24h (provider_id, rank, tokens, jobs, active_accounts, ...)` at line 65. The locked migrations define `stats_rewards_populated (window_label, rewards_populated, generated_at)` in `phase4-coordinator/internal/stats/migrations/001_stats_tables.up.sql:191`, bootstrap rows by `window_label` in `002_bootstrap_health_and_rewards.up.sql:21`, and define leaderboard rank columns as `rank_earnings`, `rank_tokens`, `rank_jobs` in `001_stats_tables.up.sql:43`; there is no `singleton`, `rank`, or `active_accounts` column on those tables.
   - Why: Round 2 CODE M1 required binary-level, DB-backed coverage proving the rotation overlap through the Step 3 auth handler: A and B both work before revocation, then A returns 401 and B still works. The newly added `TestRotationThroughHandler_Subprocess` reaches `seedRotationHandlerFixture` before the handler probes at lines 812-835, so with Docker available it will fail during fixture setup instead of proving the locked AC variant.
   - Fix: update the rotation fixture to the current locked schema, e.g. rely on the bootstrap `stats_rewards_populated` rows or upsert `window_label='24h'`, and insert a valid leaderboard row with `pseudonym`, `rank_earnings`, `rank_tokens`, `rank_jobs`, `earnings_bucket`, `tokens`, `jobs`, and timestamp fields. Re-run the integration test under Docker and keep the A/B pre-revoke plus A-401/B-200 assertions.

### LOW
None.

### INFO
- `phase4-coordinator/cmd/coordinator/main.go:82` keeps round-1 CODE H1 closed by rejecting unknown top-level subcommands before daemon config loading.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:176` rejects unknown issue flags through the subcommand FlagSet; `--burst` is not registered.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:196` validates allowed origins with the shared `stats.NormalizeOrigin` helper.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:258` uses the locked v0.1.8 issue INSERT column set with no burst column.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:277` returns before any stdout write on INSERT failure.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:289` prints only operator metadata before token delivery; the allowed `prefix` is not the raw token/body.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:317` is the default interactive raw-token stdout print and occurs after INSERT success.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:376` revokes with `revoked_at = now()` and `revoked_reason` in a single UPDATE.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:448` keeps `token_hash` out of the list SELECT.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:492` uses `crypto/rand.Read`, `base64.RawURLEncoding`, and `sha256.Sum256([]byte(raw))`.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:525` defaults principals with the locked `$USER@hostname` / `unknown@hostname` rule.
- `phase4-coordinator/cmd/coordinator/visibility.go:110` locks the old visibility row with `SELECT ... FOR UPDATE`.
- `phase4-coordinator/cmd/coordinator/visibility.go:139` and `:153` hardcode revert/audit to `bucketed` and `operator`.

## Round-2 Closure Checks
- CODE r2 MEDIUM 1 (DB-backed AC variants still bypass compiled binary and rotation did not prove handler acceptance/rejection): PARTIAL / STILL OPEN. Subprocess tests now exist for AC-17 literal issue, explicit `--created-by`, RFC 6454 cases, `--burst`, revoke-missing, and rotation. However, the rotation-through-handler fixture uses stale schema columns, so the most important missing handler-proof variant still cannot pass. Re-raised as the single round-3 MEDIUM above.
- CODE r2 MEDIUM 2 (journal/token-out tests rejected allowed `mpk_` prefix instead of full raw tokens): CLOSED. `TestIssueJournalStreamSuppresses` and `TestIssueTokenOutWritesFile` now scan with the full 47-character token regex, allowing the 8-character prefix metadata while rejecting a full raw-token leak.
- CODE r1 HIGH 1 (unknown top-level subcommand fell through to daemon): remains CLOSED by `main.go:82` and default `dispatch_test.go`.
- CODE r1 MEDIUM 1 (`partner-keys list` selected/printed `rotated_from_id`): remains CLOSED by `partnerkeys.go:448`.
- CODE r1 LOW 1 (production comment retained removed column name): remains CLOSED by the non-test/non-migration grep.

## Final Verdict
READY TO LOCK: NO
Blocking count: 0 CRITICAL / 0 HIGH / 1 MEDIUM / 0 LOW / 13 INFO

# SPEC-017 IMPL Step 4.A - Code Audit Round 4

Branch: `impl/spec-017-step-1`
HEAD audited: `435858e157ba9e4fa69bb192982d7a7227870d00` (`impl(017): Step 4.A CODE r3 close + Step 4.B r1 closures (ARCH H1 + CODE C1 + MEDIUM harness)`)
Diff base: Step 3 converged tip `2b27256`
Auditor lane: CODE
Prior rounds checked:
- `specs/SPEC-017-IMPL-STEP_4A-code-r1-audit.md` - 0 CRITICAL / 1 HIGH / 2 MEDIUM / 1 LOW / 8 INFO.
- `specs/SPEC-017-IMPL-STEP_4A-code-r2-audit.md` - 0 CRITICAL / 0 HIGH / 2 MEDIUM / 0 LOW / 12 INFO.
- `specs/SPEC-017-IMPL-STEP_4A-code-r3-audit.md` - 0 CRITICAL / 0 HIGH / 1 MEDIUM / 0 LOW / 13 INFO.

Verdict: READY TO LOCK -
0 CRITICAL + 0 HIGH + 0 MEDIUM + 0 LOW + 14 INFO

## Validation evidence
- `git status -sb` - branch `impl/spec-017-step-1...origin/impl/spec-017-step-1`; working tree was clean before writing this audit file.
- `git rev-parse HEAD && git log -1 --pretty='%h %s'` - audited `435858e157ba9e4fa69bb192982d7a7227870d00`, subject above.
- `git log --oneline 2b27256..HEAD` - Step 4.A implementation commits are `51b9736`, `6248b9e`, `d8a8a45`, and current `435858e`.
- `git diff --name-status d8a8a4538b34d62a530263b75a7cddccba7279be..HEAD` - the only Step 4.A code delta after round 3 is `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go`; other changed files are Step 4.B / audit-prompt artifacts outside this CODE lane.
- `git diff d8a8a4538b34d62a530263b75a7cddccba7279be..HEAD -- phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go` - confirms the r3 blocker fixture now uses `stats_rewards_populated.window_label`, `stats_leaderboard_24h.rank_earnings/rank_tokens/rank_jobs`, `pseudonym`, and `earnings_bucket`.
- `go build ./...` from `phase4-coordinator/` - PASS.
- `go test ./cmd/coordinator/... ./internal/stats/...` from `phase4-coordinator/` - PASS.
- `go vet ./...` from `phase4-coordinator/` - PASS.
- `gofmt -l ./cmd/coordinator ./internal/stats` from `phase4-coordinator/` - PASS, no output.
- `go test -tags=integration ./cmd/coordinator -list 'Test'` - PASS; lists subprocess coverage for AC-17, explicit `--created-by`, RFC 6454 cases, `--burst`, revoke-missing, rotation-through-handler, and visibility revert.
- `go test -tags=integration ./cmd/coordinator/... ./internal/stats/... -run TestDoesNotExist -count=0` - PASS compile-only for integration-tag packages.
- `go test ./cmd/coordinator -run 'TestDispatch' -count=1` - PASS.
- `go test -tags=integration ./cmd/coordinator -run TestRotationThroughHandler_Subprocess -count=1` - BLOCKED by local runtime before product assertions: `testcontainers-go` panicked with `rootless Docker not found`.
- `rg -n "stats_rewards_populated \\(singleton|stats_leaderboard_24h \\([^)]*rank|active_accounts|provider_id, rank" phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go phase4-coordinator/internal/stats/migrations` - PASS for stale executable fixture SQL; only an explanatory comment says `NOT active_accounts`.
- `rg -n "rate_limit_burst" phase4-coordinator --glob '!**/*_test.go' --glob '!**/migrations/**'` - PASS, no output.

## Category Verdicts
A. Subcommand dispatch: PASS - `main.go:67-90` dispatches `partner-keys` and `visibility` before daemon flag parsing, preserves daemon flag forms such as `--version` / `--config`, and rejects unknown first-position subcommands with usage plus exit 2.

B. `flag.NewFlagSet` per subcommand: PASS - `partnerkeys.go:164-178`, `:340-349`, `:427-434`, and `visibility.go:69-78` use isolated FlagSets; `--allowed-origin` appends through `originsFlag` at `partnerkeys.go:137-145` and `:174-175`.

C. CSPRNG usage: PASS - `generatePartnerToken` uses `crypto/rand.Read` on 32 bytes and checks the error at `partnerkeys.go:492-496`.

D. base64url encoding: PASS - token body uses `base64.RawURLEncoding.EncodeToString` and enforces 43 characters at `partnerkeys.go:497-505`; tests assert the full `mpk_[A-Za-z0-9_-]{43}` shape.

E. Token assembly + sha256: PASS - `partnerkeys.go:506-508` computes `raw := "mpk_" + body` and `sha256.Sum256([]byte(raw))`; `partnerkeys.go:265` stores `rawToken[:8]` as prefix. The generated token is ASCII, so the byte/rune surface is stable.

F. INSERT statement: PASS - `partnerkeys.go:258-276` inserts only `label`, `token_hash`, `token_hash_alg`, `prefix`, `allowed_origins`, `rate_limit_rpm`, `created_by`, and `rotated_from_id`; absent rotation stays SQL NULL via `sql.NullInt64`; `resolvePrincipal` at `partnerkeys.go:525-537` implements the locked non-empty default rule.

G. Print exactly once on success: PASS - `partnerkeys.go:277-284` returns before any stdout write on INSERT failure; metadata is printed after INSERT at `:289`, and the raw token is printed once at `:317` unless the security-lane `JOURNAL_STREAM` / `--token-out` branch is used.

H. Rotation path: PASS - production code checks predecessor existence before INSERT at `partnerkeys.go:228-241`, writes `rotated_from_id` at `:253-276`, and does not auto-revoke the predecessor. The required handler-proof subprocess test is present at `partnerkeys_integration_test.go:792-870`, and the stale schema fixture that blocked r3 is now corrected at `:65-110`.

I. Revoke + list: PASS - revoke updates `revoked_at = now()` and `revoked_reason` in one UPDATE at `partnerkeys.go:376-381` and returns a clean missing-row error at `:391-401`; list selects only `id`, `label`, `prefix`, `created_at`, `revoked_at`, and `last_used_at` at `:448-457`, with no `token_hash`.

J. Visibility revert: PASS - `visibility.go:102-107` opens one transaction, `:110-113` locks old mode with `SELECT ... FOR UPDATE`, `:139-143` updates to literal `bucketed`, and `:153-157` inserts audit with literal `new_mode='bucketed'` and `actor_kind='operator'`. `visibility exact` hard-rejects at `:44-50`; no `--mode` or `--exact` flag exists.

K. Operator DSN open + close: PASS - issue/revoke/list/revert open `sql.Open("postgres", dsn)` at subcommand entry and defer `Close` (`partnerkeys.go:215-223`, `:363-369`, `:440-445`; `visibility.go:92-97`). Error strings identify source/path but do not format the DSN value.

L. Error wrapping hygiene: PASS - no error path formats `rawToken`, token body, or token hash. Failed INSERT returns before metadata/token output (`partnerkeys.go:277-284`), and integration tests scan stderr for raw-token, body-shaped, and `token_hash` leaks at `partnerkeys_integration_test.go:619-677`.

M. Tests: PASS - subprocess tests now cover the locked AC variants named in the prompt. The r3 blocker was only the rotation-through-handler fixture schema; current fixture SQL matches the locked migrations (`001_stats_tables.up.sql:39-55`, `:191-196`) and integration packages compile with `-tags=integration`.

## Findings
### CRITICAL
None.

### HIGH
None.

### MEDIUM
None.

### LOW
None.

### INFO
- `phase4-coordinator/cmd/coordinator/main.go:82-89` keeps the unknown top-level subcommand fix closed.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:176-178` rejects typo flags through the subcommand FlagSet; no `--burst` flag is registered.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:196-203` validates allowed origins through the shared `stats.NormalizeOrigin` helper and rejects non-canonical operator input before any INSERT.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:258-276` uses the locked v0.1.8 issue INSERT column set with no removed burst column.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:277-284` keeps raw-token printing after INSERT success only.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:299-309` retains the security-lane `--token-out` branch with `O_EXCL` / mode 0600 semantics.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:448-457` keeps `token_hash` and `rotated_from_id` out of the list surface.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:492-508` implements CSPRNG, unpadded base64url, and sha256 over raw token UTF-8 bytes.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:525-537` keeps `$USER@hostname` / `unknown@hostname` default principal behavior without `os/user.Current` fallback drift.
- `phase4-coordinator/cmd/coordinator/visibility.go:110-157` keeps revert atomic and bucketed-only.
- `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:270-304` covers the literal AC-17 subprocess issue path.
- `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:682-740` covers explicit `--created-by` and RFC 6454 subprocess cases.
- `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:746-784` covers `--burst` rejection and missing revoke via subprocess.
- `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:792-870` now provides the required A/B rotation-through-handler subprocess proof shape; local execution remains Docker-blocked before product assertions.

## Round-3 Closure Checks
- CODE r3 MEDIUM 1 (rotation-through-handler subprocess fixture used stale schema columns): CLOSED. The fixture now updates `stats_rewards_populated.window_label`, inserts `stats_leaderboard_24h` with `pseudonym`, `rank_earnings`, `rank_tokens`, `rank_jobs`, `earnings_bucket`, `tokens`, `jobs`, and timestamp fields, and seeds `stats_overview_current` with the locked columns. Static comparison to `001_stats_tables.up.sql` shows the executable SQL aligns with the locked schema; `go test -tags=integration ... -run TestDoesNotExist -count=0` compiles the integration package. Full execution remains blocked locally by missing Docker, before any product SQL or handler assertion runs.
- CODE r2 MEDIUM 2 (journal/token-out tests rejected allowed prefix): remains CLOSED. Current tests reject only full `mpk_[A-Za-z0-9_-]{43}` raw tokens and body-shaped leaks.
- CODE r1 HIGH 1 (unknown top-level subcommand fell through to daemon): remains CLOSED by `main.go:82-89` and `go test ./cmd/coordinator -run 'TestDispatch' -count=1`.
- CODE r1 MEDIUM 1 (`partner-keys list` selected/printed `rotated_from_id`): remains CLOSED by `partnerkeys.go:448-457`.
- CODE r1 LOW 1 (removed burst column comment in production): remains CLOSED by the non-test/non-migration `rg` sweep.

## Final Verdict
READY TO LOCK: YES
Blocking count: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW / 14 INFO

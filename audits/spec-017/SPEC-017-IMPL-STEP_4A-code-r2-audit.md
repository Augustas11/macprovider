# SPEC-017 IMPL Step 4.A — Code Audit Round 2

Branch: `impl/spec-017-step-1`
HEAD audited: `6248b9e032d139eff6d8b80b1201682a9abf185c` (`impl(017): Step 4.A round-1 fixes (CODE H1 + SECURITY H1 + 4M + 3L) + Step 4.B nginx vhost`)
Diff base: Step 3 converged tip `2b27256`
Auditor lane: CODE
Prior rounds checked:
- `specs/SPEC-017-IMPL-STEP_4A-code-r1-audit.md` — 0 CRITICAL / 1 HIGH / 2 MEDIUM / 1 LOW / 8 INFO.

Verdict: NOT READY TO LOCK —
0 CRITICAL + 0 HIGH + 2 MEDIUM + 0 LOW + 12 INFO

## Validation evidence
- `git status -sb` — branch `impl/spec-017-step-1...origin/impl/spec-017-step-1`; working tree unchanged before this audit file.
- `git diff --name-status 2b27256...HEAD` — Step 4.A files present under `cmd/coordinator/{main.go,admin_dsn_parse.go,partnerkeys.go,partnerkeys_integration_test.go,visibility.go,visibility_integration_test.go,dispatch_test.go}` plus shared origin helper changes; Step 4.B nginx files also present but outside this CODE lane except for diff-scope awareness.
- `go build ./...` from `phase4-coordinator/` — PASS.
- `go test ./cmd/coordinator/... ./internal/stats/...` from `phase4-coordinator/` — PASS.
- `go vet ./...` from `phase4-coordinator/` — PASS.
- `gofmt -l ./cmd/coordinator ./internal/stats` from `phase4-coordinator/` — PASS, no output.
- `go run . frobnicate` from `phase4-coordinator/cmd/coordinator` — PASS for round-1 H1 closure: exits non-zero with `unknown subcommand "frobnicate"` usage, not daemon config loading.
- `go test ./cmd/coordinator -run 'TestDispatch' -count=1` — PASS.
- `go test -tags=integration ./cmd/coordinator/... ./internal/stats/...` — BLOCKED by local runtime: testcontainers panicked with `rootless Docker not found` before Postgres fixtures started.
- `rg -n "rate_limit_burst" phase4-coordinator --glob '!**/*_test.go' --glob '!**/migrations/**'` — PASS, no non-test/non-migration hits.
- `rg -n "exec\.Command|runPartnerKeysIssue|runPartnerKeysRevoke|runPartnerKeysList|runVisibilityRevert\(" phase4-coordinator/cmd/coordinator/*_test.go` — FAIL for category M harness shape: DB-backed Step 4.A integration tests still call in-process helpers; only dispatch-only tests use `exec.Command`.
- Static SQL/output sweeps over `phase4-coordinator/cmd/coordinator` — no `partner-keys list` `token_hash` SELECT; list SELECT is pinned to id/label/prefix/created_at/revoked_at/last_used_at; issue INSERT omits the removed burst column.

## Category Verdicts
A. Subcommand dispatch: PASS — known `partner-keys` and `visibility` verbs dispatch before daemon flag parsing; unknown first positional args now print usage and exit 2. `--version` and daemon flag forms still remain on the daemon path.

B. `flag.NewFlagSet` per subcommand: PASS — `issue`, `revoke`, `list`, and `visibility revert` each use isolated `flag.FlagSet` values; `--allowed-origin` appends through `flag.Var`.

C. CSPRNG usage: PASS — `generatePartnerToken` uses `crypto/rand.Read` on 32 bytes and checks the returned error.

D. base64url encoding: PASS — token body uses `base64.RawURLEncoding.EncodeToString` and guards the 43-character invariant.

E. Token assembly + sha256: PASS — raw token is `"mpk_" + body`, hash is `sha256.Sum256([]byte(raw))`, and prefix is `rawToken[:8]` from an ASCII-only generated token.

F. INSERT statement: PASS — issue inserts the v0.1.8 column set (`label`, `token_hash`, `token_hash_alg`, `prefix`, `allowed_origins`, `rate_limit_rpm`, `created_by`, `rotated_from_id`) with no removed burst column; absent `--rotate-from` uses NULL; `created_by` defaults non-empty.

G. Print exactly once on success: PASS — the raw token is printed only after INSERT succeeds, or written to `--token-out`; failure paths do not print the raw token. The metadata line is non-secret but remains stdout-visible.

H. Rotation path: PASS for implementation, PARTIAL for test evidence — `--rotate-from` verifies predecessor existence, stores a BIGINT `rotated_from_id`, and does not auto-revoke the predecessor. The test still does not prove A and B both authenticate through the handler before A is revoked.

I. Revoke + list: PASS — revoke handles missing rows cleanly and updates `revoked_at` plus `revoked_reason`; list SELECT/output no longer includes `rotated_from_id` or `token_hash`.

J. Visibility revert: PASS — one transaction, `SELECT ... FOR UPDATE`, hard-coded `mode='bucketed'`, audit insert with `actor_kind='operator'`, and no supported exact-enable flag or verb. `changed_at` is covered by the table default `DEFAULT now()`.

K. Operator DSN open + close: PASS — subcommands open `sql.Open("postgres", dsn)` at CLI entry and defer `Close`; daemon startup does not open the admin DSN; error paths do not format the DSN value.

L. Error wrapping hygiene: PASS for code, PARTIAL for test evidence — code does not format raw token/body/hash into error strings. The failure-insert test cannot know the failed run's generated body, so this remains covered mostly by static inspection.

M. Tests: FAIL — default tests pass, but the locked DB-backed AC variants still bypass `main()`/argv/env by calling in-process helpers, and two journal/token-out integration assertions are inconsistent with the implementation's metadata stdout.

## Findings

### CRITICAL
None.

### HIGH
None.

### MEDIUM
1. `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:122`
   - Evidence: the integration helpers call `runPartnerKeysIssue`, `runPartnerKeysRevoke`, and `runPartnerKeysList` directly with `bytes.Buffer` writers. The only `exec.Command(coordinatorBinary, ...)` coverage is in `dispatch_test.go`, and those subprocess cases either avoid Postgres or intentionally use a broken DSN.
   - Why: Category M requires the locked Step 4.A CLI variants to run through the compiled coordinator binary with `exec.Command(coordinatorBinary, ...)`, capturing stdout/stderr against testcontainers Postgres. The current AC-17, `--created-by`, RFC 6454, rotation, revoke-missing, and failed-insert redaction tests bypass `main()` dispatch, process environment, real argv parsing, and executable packaging. This was the core round-1 CODE M2 gap; the new dispatch tests close the top-level typo case but not the DB-backed AC harness shape.
   - Additional evidence: `TestRotationOverlap` verifies DB state only; it does not prove "A+B both work; revoke A -> A rejected, B works" through the Step 3 auth handler. `TestTokenRedactionOnFailedInsert` compares stderr from the failing issue only against the prior successful token/body, not the failing run's generated random body.
   - Fix: make the Postgres-backed Step 4.A tests build/locate the coordinator binary and drive literal commands via `exec.Command`. Keep direct function tests as unit tests if useful, but add subprocess coverage for AC-17 literal issue, explicit `--created-by`, all RFC 6454 cases, rotation through handler auth, revoke-missing, `--burst`, and failed-insert stderr scans.

2. `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:407`
   - Evidence: `TestIssueJournalStreamSuppresses` asserts `strings.Contains(stdout, "mpk_")` is false, and `TestIssueTokenOutWritesFile` repeats the same check at line 436. The implementation always prints a metadata line before token delivery: `partnerkeys.go:289` includes `prefix=%s`, where `prefix := rawToken[:8]` at line 265 and therefore always starts with `mpk_`.
   - Why: With Docker available, these integration tests are expected to fail even though the prefix is explicitly allowed by SPEC §5.4.6 and category M only forbids the raw token/body/hash outside the one-time token sink. A failing required integration suite blocks a lockable Step 4.A code lane.
   - Fix: either remove `prefix` from stdout when `JOURNAL_STREAM`/`--token-out` is active, or change the tests to reject only full 47-character `mpk_[A-Za-z0-9_-]{43}` raw tokens and 43-character body substrings, not the allowed 8-character prefix.

### LOW
None.

### INFO
- `phase4-coordinator/cmd/coordinator/main.go:82` closes round-1 CODE H1 by rejecting unknown top-level positional subcommands before daemon config loading.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:154` closes the removed-column comment LOW; `rate_limit_burst` no longer appears in non-test/non-migration code.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:448` closes round-1 CODE/ARCH M1: `partner-keys list` now SELECTs only id, label, prefix, created_at, revoked_at, and last_used_at.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:525` closes the `$USER` default drift: no `os/user.Current` fallback remains; unset `$USER` produces `unknown@<hostname>`.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:196` reuses `stats.NormalizeOrigin` for allowed-origin validation.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:258` INSERT uses the locked v0.1.8 column list with no `rate_limit_burst`.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:277` returns before metadata/token output on INSERT failure.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:299` supports `--token-out` with `O_CREAT|O_EXCL|O_WRONLY` and mode 0600.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:376` revokes with `revoked_at = now()` and `revoked_reason` in one UPDATE.
- `phase4-coordinator/cmd/coordinator/visibility.go:110` locks the old visibility row with `SELECT ... FOR UPDATE` in the same transaction.
- `phase4-coordinator/cmd/coordinator/visibility.go:139` hardcodes operator revert to `mode='bucketed'`.
- `phase4-coordinator/cmd/coordinator/visibility.go:153` hardcodes audit `new_mode='bucketed'` and `actor_kind='operator'`.

## Round-1 Closure Checks
- CODE r1 HIGH 1 (unknown top-level subcommand falls through to daemon): CLOSED. `go run . frobnicate` now prints unknown-subcommand usage and exits non-zero before config loading.
- CODE r1 MEDIUM 1 (`partner-keys list` selected/printed `rotated_from_id`): CLOSED. Current list SELECT/output excludes `rotated_from_id`.
- CODE r1 MEDIUM 2 (DB-backed tests bypass binary and miss rotation handler proof): PARTIAL. Dispatch-only subprocess tests were added, but the AC-17/RFC6454/rotation/revoke DB-backed tests still call in-process helpers and rotation still does not prove handler acceptance/rejection.
- CODE r1 LOW 1 (`rate_limit_burst` production comment): CLOSED. No non-test/non-migration hits remain.

## Final Verdict
READY TO LOCK: NO
Blocking count: 0 CRITICAL / 0 HIGH / 2 MEDIUM / 0 LOW / 12 INFO

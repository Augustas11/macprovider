# SPEC-017 IMPL Step 4.A — Code Audit Round 1

Branch: `impl/spec-017-step-1`
HEAD audited: `51b9736cc8d9817cedc5cab119a8b36871904aca` (`impl(017): Step 4.A — partner-keys CLI + visibility revert (initial drop)`)
Diff base: Step 3 converged tip `2b27256`
Auditor lane: CODE
Prior rounds checked:
- None. This is the first Step 4.A CODE audit round in this tree.

Verdict: NOT READY TO LOCK —
0 CRITICAL + 1 HIGH + 2 MEDIUM + 1 LOW + 8 INFO

## Validation evidence
- `git status -sb` — clean working tree on `impl/spec-017-step-1`.
- `git diff --name-only 2b27256..HEAD -- phase4-coordinator/` — scoped Step 4.A delta to `cmd/coordinator/{main.go,admin_dsn_parse.go,partnerkeys.go,visibility.go}`, Step 4.A integration tests, and Step 3 stats-origin adjustments.
- `go build ./...` from `phase4-coordinator/` — PASS.
- `go test ./cmd/coordinator/... ./internal/stats/...` from `phase4-coordinator/` — PASS.
- `go vet ./...` from `phase4-coordinator/` — PASS.
- `gofmt -l ./cmd/coordinator ./internal/stats` from `phase4-coordinator/` — PASS, no output.
- `go list -f '{{.ImportPath}} {{join .Imports "\n"}}' ./cmd/coordinator` — PASS for the requested import check: the CLI package imports `internal/stats` and `internal/stats/rollup`/`store` only through existing daemon files; the Step 4.A CLI files do not route partner-key INSERTs through `internal/stats/store`.
- `rg -n "rate_limit_burst" phase4-coordinator` — FAIL for the literal validation criterion in non-test code comments: `cmd/coordinator/partnerkeys.go:156` still contains the removed column name in a comment. No behavioral column/flag use found.
- `go test -tags=integration ./cmd/coordinator/... ./internal/stats/...` — BLOCKED by local environment, not code result: testcontainers panics with `rootless Docker not found` before the first Postgres fixture starts.
- `go run . frobnicate` from `phase4-coordinator/cmd/coordinator` — FAILS the unknown-subcommand contract: output is `config: open coordinator.yaml: no such file or directory`, showing the unknown positional verb fell into daemon config loading instead of usage.

## Category Verdicts
A. Subcommand dispatch: FAIL — known `partner-keys` and `visibility` dispatch before daemon flags, but an unknown top-level positional verb falls through to daemon startup/config loading instead of printing CLI usage and exiting as an unknown subcommand.

B. `flag.NewFlagSet` per subcommand: PASS — `issue`, `revoke`, `list`, and `visibility revert` each use their own `flag.FlagSet` with explicit `ContinueOnError` handling; `--allowed-origin` uses `flag.Var` append semantics.

C. CSPRNG usage: PASS — `generatePartnerToken` uses `crypto/rand.Read` on 32 bytes and aborts on error.

D. base64url encoding: PASS — token body uses `base64.RawURLEncoding.EncodeToString` and checks the 43-character invariant.

E. Token assembly + sha256: PASS — raw token is `"mpk_" + body`, hash is `sha256.Sum256([]byte(raw))`, and prefix is the first 8 characters of the generated ASCII token.

F. INSERT statement: PASS — issue inserts the v0.1.8 column set without `rate_limit_burst`, defaults `created_by` through `resolvePrincipal`, and prints no raw token on INSERT failure.

G. Print exactly once on success: PASS — raw token is printed once after the INSERT returns. The implementation also prints a metadata line before the token; that is not a raw-token leak, but the harness should be kept aligned if it expects token-only stdout.

H. Rotation path: PASS — `--rotate-from` is parsed as BIGINT, checked for existence before insert, stored as `sql.NullInt64`, and the predecessor is not auto-revoked.

I. Revoke + list: FAIL — revoke handles missing rows cleanly and updates `revoked_at` plus `revoked_reason`, but list SELECTs/prints `rotated_from_id`, which is outside the locked list column set.

J. Visibility revert: PASS — uses one transaction, `SELECT ... FOR UPDATE`, hard-coded `mode='bucketed'`, audit insert with `actor_kind='operator'`, and no supported `--exact`/`--mode exact` path. `visibility exact` is explicitly rejected.

K. Operator DSN open + close: PASS — CLI subcommands open `sql.Open("postgres", dsn)` at subcommand entry and defer `db.Close()`; daemon startup comments and code avoid opening the admin DSN. Error strings do not format the DSN directly.

L. Error wrapping hygiene: PASS with test gap — code paths do not format raw token/body/hash into errors, and failed INSERT prints only the driver error. The current redaction test does not prove the failed run's generated random body is absent because the failed token is intentionally not exposed to the test.

M. Tests: FAIL — default tests pass, but Step 4.A integration coverage is not runnable in this environment, and the test shape does not match the required `exec.Command(coordinatorBinary, ...)` subprocess harness, leaving main-dispatch behavior uncovered.

## Findings

### CRITICAL
None.

### HIGH
1. `phase4-coordinator/cmd/coordinator/main.go:67`
   - Evidence: the dispatcher only handles `os.Args[1] == "partner-keys"` or `"visibility"`; every other first positional arg falls through to daemon `flag.Parse()` and config loading. Running `go run . frobnicate` from `cmd/coordinator` exits with `config: open coordinator.yaml: no such file or directory`, not an unknown-subcommand usage error.
   - Why: CODE category A requires unknown subcommands to print usage to stderr and exit non-zero, not silently fall through to daemon mode. In a host with a valid `coordinator.yaml`, this false negative can start the daemon when an operator intended a CLI command typo.
   - Fix: after preserving daemon flag forms (`--config`, `--version`, etc.), reject any non-flag first positional arg that is not a known top-level CLI verb. Print a top-level usage line that names daemon flags plus `partner-keys`/`visibility`, then return/exit non-zero.

### MEDIUM
1. `phase4-coordinator/cmd/coordinator/partnerkeys.go:400`
   - Evidence: `partner-keys list` runs `SELECT id, label, prefix, created_at, revoked_at, last_used_at, rotated_from_id` and prints a matching `rotated_from_id` column at line 409.
   - Why: CODE category I locks the list query/output to `id, label, prefix, created_at, revoked_at, last_used_at — and nothing else`. The extra `rotated_from_id` column is non-secret, but it violates the locked operator surface and can fail an exact-column harness.
   - Fix: remove `rotated_from_id` from the SELECT, scan variables, header, and output row. Keep rotation lineage discoverability for a future explicitly specified subcommand if needed.

2. `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:104`
   - Evidence: the Step 4.A tests call `runPartnerKeysIssue`, `runPartnerKeysRevoke`, `runPartnerKeysList`, and `runVisibilityRevert` directly through in-process buffers. They do not use `exec.Command(coordinatorBinary, ...)`, so they bypass `main()` and did not catch the top-level dispatch bug above. The rotation test also verifies DB state but does not prove A+B both unlock the partner projection before revoking A as category M requires.
   - Why: CODE category M requires a subprocess CLI harness capturing stdout/stderr against Postgres. Direct function tests are useful unit coverage, but partial for locked AC variants and insufficient for dispatch/argv behavior.
   - Fix: add a binary-level integration harness that builds or locates the coordinator binary, invokes literal commands with `exec.Command`, captures stdout/stderr, and covers top-level unknown subcommands, AC-17 literal issue, explicit `--created-by`, RFC 6454 cases, rotation via the handler auth path, revoke-missing, `--burst`, and leak scans.

### LOW
1. `phase4-coordinator/cmd/coordinator/partnerkeys.go:156`
   - Evidence: mandated validation `rg -n "rate_limit_burst" phase4-coordinator` still finds the removed column name in a non-test, non-migration code comment.
   - Why: behavior is correct, but the audit prompt's grep check says non-test/non-migration paths should have zero hits so simple scans cannot confuse a removed-column comment with implementation usage.
   - Fix: reword the comment without the literal removed column name, or narrow the validation script in the next prompt if comments are intentionally allowed.

### INFO
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:164` — each partner-key verb has an isolated `FlagSet`; `--burst` is not registered and default flag handling rejects it.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:190` — allowed-origin validation calls `stats.NormalizeOrigin`, preserving Step 3 handler equivalence rather than reimplementing RFC 6454 normalization.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:242` — token generation happens after rotation existence checks and before INSERT; failed INSERT returns before stdout writes.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:256` — issue insert uses the v0.1.8 column set and stores `rotated_from_id` as NULL unless explicitly supplied.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:263` — prefix is derived from the generated raw token and cannot diverge from the printed token in the success path.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:331` — revoke writes `revoked_at = now()` and `revoked_reason` in one UPDATE and handles non-existent IDs without panic.
- `phase4-coordinator/cmd/coordinator/visibility.go:110` — visibility revert locks the old row with `SELECT ... FOR UPDATE` and writes update + audit insert in one transaction.
- `phase4-coordinator/cmd/coordinator/visibility.go:153` — visibility audit insert hardcodes `new_mode='bucketed'` and `actor_kind='operator'`; no operator exact-enable path was found.

## Round-0 Closure Checks
- Not applicable. No prior Step 4.A CODE audit rounds exist.

## Final Verdict
READY TO LOCK: NO
Blocking count: 0 CRITICAL / 1 HIGH / 2 MEDIUM / 1 LOW / 8 INFO

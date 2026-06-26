# SPEC-017 IMPL Step 4.A - Architecture Audit Round 1

Branch: `impl/spec-017-step-1`
HEAD audited: `51b9736cc8d9817cedc5cab119a8b36871904aca` (`impl(017): Step 4.A - partner-keys CLI + visibility revert (initial drop)`)
Diff base: Step 3 converged tip `2b27256`
Auditor lane: ARCHITECTURE
Prior rounds checked:
- None. This is the first Step 4.A ARCH audit file found under `specs/`.

Verdict: NOT READY TO LOCK -
0 CRITICAL + 0 HIGH + 2 MEDIUM + 1 LOW + 9 INFO

## Validation evidence
- `git diff --name-only 2b27256..HEAD -- phase4-coordinator/` - PASS; Step 4.A delta is scoped to `cmd/coordinator/{main.go,admin_dsn_parse.go,partnerkeys.go,visibility.go}`, CLI integration tests, and exporting `internal/stats.NormalizeOrigin`.
- `go build ./...` from `phase4-coordinator/` - PASS.
- `go test ./cmd/coordinator/... ./internal/stats/...` - PASS.
- `go test -tags integration ./cmd/coordinator/... ./internal/stats/...` - NOT EXECUTED TO COMPLETION in this environment; testcontainers panicked with `rootless Docker not found` before running AC-17/CLI integration assertions.
- `go vet ./...` - PASS.
- `gofmt -l ./cmd/coordinator ./internal/stats` - PASS; no files listed.
- `go list -f '{{.ImportPath}} {{join .Imports "\n"}}' ./cmd/coordinator` - package imports `internal/stats/store` through daemon `main.go`, but Step 4.A CLI files use `database/sql` directly and do not route INSERT/UPDATE through store helpers.
- `grep -rn "rate_limit_burst" phase4-coordinator/` - FAIL against the prompt's zero-hit check for non-test/non-migration paths: hits are comments/tests/migrations plus one production comment at `cmd/coordinator/partnerkeys.go:156`; no executable SQL or flag surface uses the column.

## Category Verdicts
A. CLI surface contract: FAIL - `partner-keys list` prints `rotated_from_id`, outside the locked list columns.
B. Token-generation pipeline: PASS - uses `crypto/rand.Read`, `base64.RawURLEncoding`, 47-char `mpk_` raw token, `sha256([]byte(raw))`, first 8 chars as prefix, and literal `token_hash_alg = 'sha256'`.
C. Database access posture: PASS - Step 4.A writes open a dedicated admin DSN at subcommand invocation; daemon startup documents and avoids opening the admin DSN.
D. Section 5.4.2 INSERT column set: FAIL - SQL column set is correct, but the default `created_by` rule diverges when `$USER` is unset.
E. Section 5.4.4 rotation flow: PASS - `--rotate-from` inserts `rotated_from_id` and does not auto-revoke the predecessor or require a reason.
F. RFC 6454 idempotency validation: PASS - CLI calls the same exported `stats.NormalizeOrigin` used by the handler and rejects non-idempotent values before DSN open/INSERT.
G. `visibility revert` audit row: FAIL - writes are bucketed-only and audited, but default `actor_id` shares the same `$USER`-unset divergence as `created_by`.
H. Log + redaction surface: PASS - raw token is printed only by the issue success path; error paths do not print raw token or hash bytes.
I. Test surface alignment: PARTIAL - source includes CLI integration tests, but this environment could not execute them; current rotation test validates DB overlap/revoke state but not the full "both keys unlock partner projection; revoke A rejects A while B still works" handler flow.

## Findings
### CRITICAL
None.

### HIGH
None.

### MEDIUM
1. `phase4-coordinator/cmd/coordinator/partnerkeys.go:400`
   - Evidence:
     ```go
     SELECT id, label, prefix, created_at, revoked_at, last_used_at, rotated_from_id
       FROM partner_keys
     ```
     and:
     ```go
     fmt.Fprintln(stdout, "id\tlabel\tprefix\tcreated_at\trevoked_at\tlast_used_at\trotated_from_id")
     ```
   - Why: BUILD Step 4.A and the audit contract pin `partner-keys list` to exactly `id`, `label`, `prefix`, `created_at`, `revoked_at`, and `last_used_at`. `rotated_from_id` is not a secret, but it is an extra operator CLI column outside the locked surface, so downstream scripts and later audit lanes could reasonably disagree about the supported list contract.
   - Fix: Remove `rotated_from_id` from the SELECT, scan variables, header, and row formatter. Keep rotation evidence available through the issue metadata or a future explicitly specified command.

2. `phase4-coordinator/cmd/coordinator/partnerkeys.go:477`
   - Evidence:
     ```go
     if u := strings.TrimSpace(os.Getenv("USER")); u != "" {
     	userPart = u
     } else if cur, err := user.Current(); err == nil && strings.TrimSpace(cur.Username) != "" {
     	userPart = strings.TrimSpace(cur.Username)
     }
     ```
   - Why: BUILD Step 4.A and SPEC Section 5.4.2 define the default principal as `$USER@$(hostname)`, or `unknown@<hostname>` if `$USER` is unset. Falling back to `os/user.Current()` creates a third behavior and means `created_by`/operator `actor_id` differ across environments even when `$USER` is deliberately unset. This does not violate NOT NULL, so it is not CRITICAL/HIGH, but it is a locked default-rule drift.
   - Fix: Delete the `os/user` fallback. Use `os.Getenv("USER")` when non-empty; otherwise use `unknown` for the user part. Keep the existing hostname fallback.

### LOW
1. `phase4-coordinator/cmd/coordinator/partnerkeys.go:156`
   - Evidence:
     ```go
     //     rate_limit_burst - v0.1.8 removed).
     ```
   - Why: The requested grep check says `rate_limit_burst` must return zero hits in non-test, non-migration paths. This is only a comment, and executable code correctly omits the flag/column, but it still makes the mechanical validation fail.
   - Fix: Reword the comment without the literal removed column name, or keep that note only in tests/migrations where the audit prompt permits it.

### INFO
- `phase4-coordinator/cmd/coordinator/main.go:67` dispatches `coordinator partner-keys ...` and `coordinator visibility ...` before daemon flag parsing, preserving the literal SPEC invocation shape.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:163` defines no `--burst` flag, so Go's flag parser rejects it as unknown.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:193` calls `stats.NormalizeOrigin` directly, avoiding a parallel CLI normalizer.
- `phase4-coordinator/internal/stats/origin.go:36` exports the Step 3 handler normalizer with existing handler call sites updated to use it.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:242` generates the raw token only after flag/origin/DSN/rotation validation; the token is printed only after INSERT succeeds.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:256` INSERTs only the locked Step 4.A column set and stores literal `sha256`.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:331` revokes with `revoked_at = now()` and `revoked_reason = $1`, with a clean missing-row diagnostic.
- `phase4-coordinator/cmd/coordinator/visibility.go:139` hardcodes the UPDATE to `mode = 'bucketed'`.
- `phase4-coordinator/cmd/coordinator/visibility.go:153` hardcodes audit `new_mode = 'bucketed'` and `actor_kind = 'operator'`; `visibility exact` is explicitly rejected at `visibility.go:44`.

## Round-0 Closure Checks
- No prior Step 4.A ARCH findings exist.

## Final Verdict
READY TO LOCK: NO
Blocking count: 0 CRITICAL / 0 HIGH / 2 MEDIUM / 1 LOW / 9 INFO

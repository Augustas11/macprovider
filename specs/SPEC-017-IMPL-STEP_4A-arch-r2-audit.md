# SPEC-017 IMPL Step 4.A - Architecture Audit Round 2

Branch: `impl/spec-017-step-1`
HEAD audited: `6248b9e032d139eff6d8b80b1201682a9abf185c` (`impl(017): Step 4.A round-1 fixes (CODE H1 + SECURITY H1 + 4M + 3L) + Step 4.B nginx vhost`)
Diff base: Step 3 converged tip `2b27256`
Auditor lane: ARCHITECTURE
Prior rounds checked:
- `specs/SPEC-017-IMPL-STEP_4A-arch-r1-audit.md`

Verdict: READY TO LOCK -
0 CRITICAL + 0 HIGH + 0 MEDIUM + 1 LOW + 13 INFO

## Validation evidence
- `git diff --name-only 2b27256..HEAD -- phase4-coordinator/` - PASS; Step 4.A delta includes `cmd/coordinator/{main.go,admin_dsn_parse.go,partnerkeys.go,visibility.go}`, CLI tests, exported origin normalization, and Step 4.B nginx files that are outside this 4.A architecture lane.
- `go build ./...` from `phase4-coordinator/` - PASS.
- `go test ./cmd/coordinator/... ./internal/stats/...` - PASS.
- `go test -tags integration ./cmd/coordinator/... ./internal/stats/...` - NOT EXECUTED TO COMPLETION in this environment; testcontainers panicked with `rootless Docker not found` before product assertions ran.
- `go vet ./...` - PASS.
- `gofmt -l ./cmd/coordinator ./internal/stats` - PASS; no files listed.
- `go list -f '{{.ImportPath}} {{join .Imports "\n"}}' ./cmd/coordinator` - package-level imports include `internal/stats/store` through daemon `main.go`, but `rg` confirms only `main.go` uses `statsstore.New(statsPools.Reader)`; Step 4.A CLI files use `database/sql` directly for admin writes and do not route INSERT/UPDATE through reader-store helpers.
- `rg -n "rate_limit_burst" .` - only test and migration-comment hits remain.
- `rg -n "rate_limit_burst" --glob '!**/*_test.go' --glob '!internal/stats/migrations/**' .` - PASS; zero non-test, non-migration hits.

## Category Verdicts
A. CLI surface contract: PASS - partner-key verbs, visibility revert, unknown-flag rejection, no `--burst`, list columns, and `visibility exact` hard rejection match the locked Step 4.A surface; see LOW-1 for documenting the security-lane `--token-out` exception.
B. Token-generation pipeline: PASS - `generatePartnerToken` uses `crypto/rand.Read`, `base64.RawURLEncoding`, 43-char body, `mpk_` prefix, `sha256([]byte(raw))`, first 8 chars as prefix, and literal `sha256` in the INSERT.
C. Database access posture: PASS - issue/revoke/list/revert resolve the operator admin DSN at subcommand invocation and open `sql.DB` locally; daemon startup documents and avoids opening `PartnerKeysAdminDSN`.
D. Section 5.4.2 INSERT column set: PASS - INSERT contains only `label`, `token_hash`, `token_hash_alg`, `prefix`, `allowed_origins`, `rate_limit_rpm`, `created_by`, and `rotated_from_id`; `created_by` now defaults via `$USER@hostname` or `unknown@hostname`.
E. Section 5.4.4 rotation flow: PASS - `--rotate-from` verifies the predecessor, inserts `rotated_from_id`, and does not auto-revoke or require a reason.
F. RFC 6454 idempotency validation: PASS - CLI calls the same exported `stats.NormalizeOrigin` used by the handler and rejects non-idempotent values before opening the admin DB.
G. `visibility revert` audit row: PASS - update is hardcoded to `mode='bucketed'`, audit INSERT is hardcoded to `new_mode='bucketed'` and `actor_kind='operator'`, and `visibility exact` hard-rejects.
H. Log + redaction surface: PASS - normal issue flow prints the raw token once after INSERT; stderr/error paths avoid raw token and hash bytes; JOURNAL_STREAM paths suppress stdout token leakage and require an explicit 0600 token file.
I. Test surface alignment: PASS with environment gap - source includes default dispatch tests and integration-tag tests for AC-17, explicit `--created-by`, RFC 6454, rotation DB overlap, missing revoke, `--burst`, journald suppression, token file output, and visibility AC-20, but Docker-backed integration execution could not run here.

## Findings
### CRITICAL
None.

### HIGH
None.

### MEDIUM
None.

### LOW
1. `phase4-coordinator/cmd/coordinator/partnerkeys.go:173`
   - Evidence:
     ```go
     tokenOut := fs.String("token-out", "", "write the raw mpk_* token to this file path with mode 0600 instead of stdout ...")
     ```
     and the delivery branch at `phase4-coordinator/cmd/coordinator/partnerkeys.go:299` writes the raw token to a 0600 file instead of stdout when requested.
   - Why: This is a security-lane fix for journald capture and is defensible, but it is now an intentional exception to the locked prose that says issue prints the raw token to stdout exactly once. Future Step 4 convergence/OPS readers need a single recorded decision so this does not get rediscovered as either an ARCH surface expansion or a SECURITY regression.
   - Fix: In the Step 4.A convergence record and operator runbook, explicitly document: default interactive issue prints the token to stdout exactly once; if stdout is journal-captured, the CLI refuses and operators must use `--token-out FILE` with mode 0600. No code change is required for lock.

### INFO
- `phase4-coordinator/cmd/coordinator/main.go:67` dispatches `partner-keys` and `visibility` before daemon flag parsing, preserving the literal `coordinator partner-keys issue` invocation.
- `phase4-coordinator/cmd/coordinator/main.go:82` rejects unknown non-flag first positionals instead of silently booting daemon mode.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:176` relies on Go's `flag` parser, so unknown flags including `--burst` fail before DB access.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:196` calls `stats.NormalizeOrigin` directly, preserving CLI/handler equivalence.
- `phase4-coordinator/internal/stats/origin.go:36` is the shared RFC 6454 normalizer and strips default ports, lowercases scheme/host, and Punycode-encodes IDNs.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:258` inserts only the locked v0.1.8 partner-key columns and returns id/created_at for operator metadata.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:317` is the only normal stdout raw-token print in the issue path.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:448` selects only id/label/prefix/created_at/revoked_at/last_used_at for list; `token_hash` and `rotated_from_id` are absent.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:525` removed the `os/user.Current()` fallback; `$USER` unset now yields `unknown@<hostname>`.
- `phase4-coordinator/cmd/coordinator/visibility.go:44` explicitly rejects `visibility exact` with a clear operator message.
- `phase4-coordinator/cmd/coordinator/visibility.go:139` hardcodes visibility revert updates to `mode = 'bucketed'`.
- `phase4-coordinator/cmd/coordinator/visibility.go:153` hardcodes audit `new_mode = 'bucketed'` and `actor_kind = 'operator'`.
- `phase4-coordinator/internal/stats/stats.go:193` through `:219` opens only runtime role pools; `PartnerKeysAdminDSN` is present in config but not opened by daemon startup.

## Round-1 Closure Checks
- ARCH r1 MEDIUM 1 (`partner-keys list` printed `rotated_from_id`) - closed. New list query at `phase4-coordinator/cmd/coordinator/partnerkeys.go:448` selects only `id, label, prefix, created_at, revoked_at, last_used_at`, and the header at `:457` matches exactly.
- ARCH r1 MEDIUM 2 (`created_by` / `actor_id` default used `os/user.Current()` when `$USER` was unset) - closed. `resolvePrincipal` at `phase4-coordinator/cmd/coordinator/partnerkeys.go:525` uses explicit value, then `$USER`, else `unknown`, with hostname fallback; `visibility revert` reuses it at `phase4-coordinator/cmd/coordinator/visibility.go:149`.
- ARCH r1 LOW 1 (production comment kept literal `rate_limit_burst`) - closed. The production Step 4.A comment was reworded, and the non-test/non-migration grep returned zero hits.

## Final Verdict
READY TO LOCK: YES
Blocking count: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 1 LOW / 13 INFO

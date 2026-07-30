# Security Review Report

**Scope:** SPEC-016 FULL implementation security lane r3 on `impl/spec-016` at `dec55ee` (audit prompt commit; implementation fix-pass under audit is `90e3dbf`). Reviewed r2 delta files:

- `phase4-coordinator/internal/payout/migrations.go`
- `phase4-coordinator/internal/payout/migrations_test.go`
- `phase4-coordinator/internal/payout/runner.go`
- `phase4-coordinator/internal/payout/runner_e2e_test.go`

**Risk Level:** LOW

**Verdict:** CONVERGENT - 0 Critical / 0 High / 0 Medium / 0 Low findings.

## Summary

- Critical Issues: 0
- High Issues: 0
- Medium Issues: 0
- Low Issues: 0

## Critical Issues (Fix Immediately)

None.

## High Issues

None.

## Medium Issues

None.

## Low Issues

None.

## r2 Closure Verification

### [full-sec:r2-1] ADD COLUMN regex skips comments and string literals

**Status:** Closed.

`stripExistingColumnAlters` builds a per-byte executable SQL mask before acting on `addColumnStmt` matches. It checks `skipMask[start]` before performing `PRAGMA table_info` and rewrite work, so `ALTER TABLE ... ADD COLUMN ...` text inside `--` line comments or string/identifier literals is ignored.

Evidence:

- `phase4-coordinator/internal/payout/migrations.go:135` finds regex matches.
- `phase4-coordinator/internal/payout/migrations.go:140` builds the executable mask.
- `phase4-coordinator/internal/payout/migrations.go:148` skips non-executable match starts.
- `phase4-coordinator/internal/payout/migrations.go:193` implements the mask state machine.
- `phase4-coordinator/internal/payout/migrations_test.go:16` verifies commented and single-quoted existing-column `ALTER` text is byte-identical after filtering, and `migrations_test.go:38` verifies a real top-level existing-column `ALTER` still rewrites.

Manual state-machine probe results:

- `ALTER TABLE t ADD COLUMN c INTEGER;` -> all bytes executable.
- `-- A\nALTER TABLE t ADD COLUMN c INTEGER;` -> `-- A` non-executable, newline and following `ALTER` executable.
- `SELECT 'ALTER TABLE x ADD COLUMN y INTEGER';` -> `SELECT ` and trailing `;` executable, quoted `ALTER` non-executable.
- `'a''b' c` -> the full doubled-quote literal non-executable, trailing ` c` executable.
- `'foo''bar ALTER TABLE x ADD COLUMN y'` -> embedded `ALTER` non-executable.
- `"foo""bar ALTER TABLE x ADD COLUMN y"` -> embedded `ALTER` non-executable.
- Empty body -> empty mask, no panic.

The doubled-quote behavior is acceptable: adjacent quote bytes toggle out/in across consecutive iterations, leaving all literal bytes marked false and returning to executable context only after the closing quote. Single quotes ignore double quotes while in a single-quoted literal, and double quotes ignore single quotes while in a double-quoted identifier.

### r2 confirmedDepth security probe

**Status:** Closed / no security regression.

`pollAndConfirm` assigns `recPri`, `recSec`, and `confirmedDepth=true` only inside the branch where both RPC receipt depths meet `ConfirmationBlocks` (`runner.go:1248`). The post-loop guard (`runner.go:1257`) returns before `markConfirmedStandalone` and `claimAndLog`, so the `confirmedDepth=false` path skips both the database confirmation write and `ClaimPayoutReady`.

The new deadline log at `runner.go:1261` includes only `payout_id` and `tx_hash`. No bearer token, raw signed transaction, private key, or secret material is emitted by the r2 change.

The regression test `TestRunner_PollAndConfirm_RejectsShallowSecondary` at `runner_e2e_test.go:203` covers a primary-deep/secondary-shallow receipt pair and asserts zero claim calls plus `confirmed_at_utc` remaining NULL.

## OWASP Top 10 Coverage

| Category | Result |
| --- | --- |
| A01 Broken Access Control | No new access-control surface in r2 delta. Confirmation path still requires both RPC depth agreement before claim. |
| A02 Cryptographic Failures | No new cryptographic primitives, key handling, or secret storage in r2 delta. |
| A03 Injection | Closed. SQL migration regex filtering now ignores comments/literals. `columnExists` uses a regex-restricted identifier and `%q` quoting for `PRAGMA table_info`. No command execution or user-controlled SQL concatenation found in the reviewed delta. |
| A04 Insecure Design | Closed. Prior regex robustness gap is addressed by executable-context masking and regression coverage. |
| A05 Security Misconfiguration | No new config/default/header changes in r2 delta. |
| A06 Vulnerable Components | `govulncheck ./...` reports 0 called vulnerabilities. |
| A07 Identification/Auth Failures | No auth/session/JWT/password flow changes in r2 delta. Test bearer fixture remains test-only. |
| A08 Software/Data Integrity Failures | Migration idempotency and both-RPC confirmation invariants hold for the reviewed fix-pass. |
| A09 Logging/Monitoring Failures | No secret-bearing logs added. The new retry log is operationally useful and limited to non-secret identifiers. |
| A10 SSRF | No outbound URL/fetch surface introduced by r2 delta. |

## Validation Evidence

Commands run from `/Users/augstar/macprovider-poc-spec016-audit/phase4-coordinator`:

```bash
govulncheck ./...
```

Result: no vulnerabilities found in called code; 0 vulnerabilities in imported packages.

```bash
go test -race -count=1 ./...
```

Result: passed for all `phase4-coordinator` packages, including `internal/payout`.

```bash
go test -count=1 ./internal/payout -run 'TestStripExistingColumnAlters_SkipsCommentsAndStringLiterals|TestRunner_PollAndConfirm_RejectsShallowSecondary'
```

Result: passed.

Secrets / dangerous-pattern scans:

```bash
rg -n '(?i)(bearer|api[_-]?key|password|passwd|secret|token|raw_signed_tx|raw-tx|private[_-]?key|authorization|credential)' \
  phase4-coordinator/internal/payout/runner.go \
  phase4-coordinator/internal/payout/runner_e2e_test.go \
  phase4-coordinator/internal/payout/migrations.go \
  phase4-coordinator/internal/payout/migrations_test.go
```

Only expected test fixture text and comments were found; no new runtime secret or raw transaction logging.

```bash
git log -p 90e3dbf^..90e3dbf -- \
  phase4-coordinator/internal/payout/runner.go \
  phase4-coordinator/internal/payout/runner_e2e_test.go \
  phase4-coordinator/internal/payout/migrations.go \
  phase4-coordinator/internal/payout/migrations_test.go
```

Diff/history scan found no hardcoded secret, bearer credential, private key, or raw transaction log addition in the r2 fix-pass.

## Security Checklist

- [x] No hardcoded secrets in reviewed r2 fix-pass files
- [x] No new raw signed transaction / bearer / key logging in reviewed r2 fix-pass files
- [x] Injection prevention verified for ADD COLUMN regex masking
- [x] Authentication/authorization impact reviewed; no new auth surface in r2 delta
- [x] Dependencies audited with `govulncheck`
- [x] Race test suite passed
- [x] OWASP Top 10 categories evaluated against the reviewed delta

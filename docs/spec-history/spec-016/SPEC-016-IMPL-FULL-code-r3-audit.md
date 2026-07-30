# SPEC-016 FULL IMPL code review audit r3

**Verdict:** APPROVE / CONVERGENT. Counts:

| CRITICAL | HIGH | MAJOR | MEDIUM | LOW |
|----------|------|-------|--------|-----|
| 0 | 0 | 0 | 0 | 1 |

Scope: SPEC-016 implementation on `impl/spec-016` after r2 fix-pass
(implementation HEAD `90e3dbf`; audit target `dec55ee`). 4 files
reviewed (r2 fix-pass surface).

## Summary

Both r2 closures hold. The single LOW finding is a comment-only
gofmt drift in `migrations.go` from the r2 fix-pass, closed in
the same commit as this report.

## r2 Closure Verification

### [full-code:r2-1] confirmedDepth bool — CLOSED

- New `confirmedDepth bool` declared before the for-loop.
- `candidatePri` / `candidateSec` capture per-iteration results.
- `recPri` / `recSec` assigned ONLY inside the break path,
  alongside `confirmedDepth = true`.
- Post-loop guard `!confirmedDepth || recPri == nil || recSec == nil`
  returns rowOutcomeFailed when depth wasn't confirmed.
- Updated log message reflects new failure mode accurately.
- `TestRunner_PollAndConfirm_RejectsShallowSecondary` exercises
  the exact scenario the r1 fix was supposed to defend against
  (receipt block 100, primary head 200, secondary head 102,
  ConfirmationBlocks 5) and asserts 0 claim calls + NULL
  confirmed_at_utc.

### [full-code:r2-2] regression test — CLOSED

- Test exists in `runner_e2e_test.go`, runs as part of the
  default test corpus, asserts both `len(s.claimer.calls) == 0`
  and `confirmed_at_utc` is NULL.

## Findings

### [full-code:r3-1] LOW — gofmt drift in r2-touched file

**File:** `phase4-coordinator/internal/payout/migrations.go:189`

**Confidence:** HIGH

**Issue:** `gofmt -l` reports `internal/payout/migrations.go`;
diff is comment-only (whitespace alignment after r2 addColumnStmt
comment edits).

**Fix:** `gofmt -w phase4-coordinator/internal/payout/migrations.go`.

## Positive Observations
- Halt composition correct for the prompt's intent: polling
  doesn't have an inner halt gate; `claimAndLog` halt gate is
  the irreversible-write boundary.
- candidatePri/candidateSec re-allocation is GC-safe.
- The post-loop guard's nil checks are defense-in-depth.

## Validation
- `go test -count=1 -run TestRunner_PollAndConfirm_RejectsShallowSecondary ./internal/payout` PASS
- `go test -count=1 ./internal/payout/...` PASS
- `go test -race -count=1 ./internal/payout/...` PASS
- `govulncheck ./...` — no called vulnerabilities

## Recommendation

APPROVE / CONVERGENT — no CRITICAL, HIGH, or MEDIUM at HIGH
confidence. The LOW gofmt is closed in the same fix-pass commit.

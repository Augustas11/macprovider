## Code Review Summary

**Scope:** SPEC-016 Step 4 IMPL, round 8, code-only audit of commit `1975494`.
**Files Reviewed:** 2
**Total Issues:** 1

### By Severity

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 1

### Stage 1 - Spec Compliance

The r7 HIGH is behaviorally closed.

- `deductPaidAmount` is called only from the two actual spend-event paths:
  `rebroadcastAndPoll` after persisted bytes are accepted and broadcast
  stamped, and `allocateBuildSignBroadcast` after the fresh transaction is
  accepted and broadcast stamped.
- No deduction occurs from `claimAndLog`, `pollAndConfirm`, the `RunOnce`
  `rowOutcomePaid` switch, or `pollCancelOnce`.
- `rebroadcastAndPoll` nonce-too-low fallback stamps and polls without
  deduction. This matches the modeled race: the prior holder or peer already
  broadcast the bytes; this cycle did not newly spend from the hot wallet.
- Fresh `allocateBuildSignBroadcast` deducts after `BroadcastBoth` returns
  accepted and after `StampBroadcastAt`; if both RPCs reject, no deduction
  fires.
- `hotWalletBalance` still returns a defensive `big.Int` copy.
- `runningBalance` is set once at the top of `RunOnce` and cleared by defer;
  `RunOnce` remains single-threaded under `mu` plus `inFlight`.
- The new regression test wires the audit boundary correctly: nonce cursor is
  `2`, the pre-seeded confirmed attempt uses nonce `1`, top-of-cycle balance
  is `100`, and it asserts two claims with no `payout_insufficient_funds` or
  `skipped_funds=1`.
- Earlier r5/r6 boundaries remain covered by existing tests for
  insufficient-funds halt, daily-cap halt, guard placement after cap/state
  checks, and existing-confirmed low-balance behavior.

### Stage 2 - Code Quality Findings

[LOW] Stale comments still describe the removed outcome-level deduction

File: `phase4-coordinator/internal/payout/runner.go:127`
Confidence: HIGH

Issue: The `runningBalance` field comment still says that on each
`rowOutcomePaid` in the row loop, `RunOnce` deducts the paid amount. That is
now false; round 8 intentionally moved deduction into the broadcast acceptance
paths.

Fix: Update the field comment to say that `runningBalance` is deducted only
when a fresh or persisted-bytes broadcast is accepted, and not from
claim/poll/cancel outcome handling.

Related stale lines:

- `phase4-coordinator/internal/payout/runner.go:483` says `RunOnce` deducts
  after each successful row.
- `phase4-coordinator/internal/payout/runner.go:942` says the running balance
  is deducted by `RunOnce` after each `rowOutcomePaid`.

### Open Questions (low-confidence findings - surfaced, not blocking)

None.

### Positive Observations

- Deduction is now co-located with the two paths that actually submit spend to
  the chain, which removes the r7 double-counting defect from existing
  confirmed and prior-broadcast rows.
- The row-loop comment at `runner.go:517` clearly documents why
  `rowOutcomePaid` is no longer the deduction authority.
- The new regression test directly encodes the audit failure mode and would
  fail under the pre-r8 behavior.
- The §7.1 event surface for `payout_insufficient_funds`,
  `payout_daily_cap_tripped`, `payout_paid`, and `payout_run_finished` was not
  changed by commit `1975494`.

### Verification

- `go test -count=1 ./...` from `phase4-coordinator/`: PASS
- `go test -race -count=1 ./internal/payout/...`: PASS
- `go vet ./...` from `phase4-coordinator/`: PASS
- `gofmt -l phase4-coordinator/internal/payout/ phase4-coordinator/cmd/coordinator/`: PASS, no output
- `git diff --check 1975494^..1975494`: PASS, no output
- `lsp_diagnostics`: not available in this Codex tool surface; `gopls` was
  also not installed, so `go test` plus `go vet` were used as the type/static
  diagnostic substitute.
- Pattern scan for `console.log`, empty catch blocks, and obvious hardcoded
  secret assignments in the modified files: PASS, no matches.

### Recommendation

COMMENT

No CRITICAL/HIGH/MEDIUM code defects were found. The r7 HIGH is closed, but
the audit is not `0/0/0/0` because the implementation commit left a LOW
documentation drift in comments that now contradict the subtle deduction
placement.

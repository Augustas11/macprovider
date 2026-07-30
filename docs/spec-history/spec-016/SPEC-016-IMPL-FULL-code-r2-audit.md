# SPEC-016 FULL IMPL code review audit r2

**Verdict:** REQUEST CHANGES on 1 HIGH + 1 MEDIUM. Counts:

| CRITICAL | HIGH | MAJOR | MEDIUM | LOW |
|----------|------|-------|--------|-----|
| 0 | 1 | 0 | 1 | 0 |

Scope: SPEC-016 implementation on `impl/spec-016` after r1 fix-pass
(implementation HEAD `3b41c0d`; audit target `09163b6`). 15 files
reviewed.

## Summary

The r1 fix-pass closed every r1 finding correctly EXCEPT one regression:
the r1 `[full-code:r1-1]` HIGH closure rewrote `pollAndConfirm`'s
depth check to read both heads, but left `recPri`/`recSec` assigned
to whatever the LAST poll returned. If the loop exits via deadline
expiry (not via a successful both-RPC depth check), and the last
poll returned non-nil receipts that did NOT satisfy both depths,
the post-loop guard (`recPri == nil || recSec == nil`) passes
through, and `markConfirmedStandalone` + `ClaimPayoutReady` are
called on a shallow receipt. This regresses `[full-code:r1-1]` and
violates SPEC §4.3 step 7.

The missing primary-deep/secondary-shallow regression test would
have caught this; the r2 prompt explicitly asked for it.

## Findings

### [full-code:r2-1] HIGH — `pollAndConfirm` can confirm shallow receipts after the polling deadline

**File:** `phase4-coordinator/internal/payout/runner.go:1216` (assignment)
`phase4-coordinator/internal/payout/runner.go:1243` (nil-only guard)
`phase4-coordinator/internal/payout/runner.go:1273` (markConfirmedStandalone)

**Confidence:** HIGH

**Issue:** `pollAndConfirm` assigns `recPri`/`recSec` before the
depth check. The poll loop exits via `break` only when BOTH per-RPC
depths satisfy `ConfirmationBlocks`; otherwise the loop sleeps and
polls again. But `recPri`/`recSec` retain their last assignment.
When `deadline` expires while the last poll returned receipts at
insufficient depth, the post-loop guard `if recPri == nil || recSec == nil`
falls through. Execution reaches `markConfirmedStandalone` +
`ClaimPayoutReady` and a shallow receipt marks paid. Regresses
`[full-code:r1-1]`; violates SPEC §4.3 step 7.

**Fix:** Track an explicit `confirmedDepth bool`. Only set it to
true inside the break path. On deadline exit, treat
`!confirmedDepth` as transient (the same path the nil check
currently takes — emit "receipt poll deadline expired; will retry
next cycle" and return rowOutcomeFailed without marking confirmed).

### [full-code:r2-2] MEDIUM — Missing primary-deep / secondary-shallow regression test

**File:** `phase4-coordinator/internal/payout/runner_e2e_test.go:148`

**Confidence:** HIGH

**Issue:** The r2 prompt explicitly asked for a regression test
where the primary head is deep (depth >= ConfirmationBlocks) and
the secondary head is shallow. Current coverage sets both heads to
the same deep block and does not exercise the shallow-secondary
path. This is the test that would have caught `[full-code:r2-1]`
above.

**Fix:** Add a test with receipt block 100, primary head 200,
secondary head 102, ConfirmationBlocks=5, short ReceiptPollTimeout.
Assert: no `confirmed_at_utc`, no `ClaimPayoutReady` call. Mirror
in `pollCancelOnce` (cancel path) as well so both confirmation
paths are locked.

## Positive Observations
- Halt gates correctly placed at rowLoop top + 3 chain-write sites.
- Post-COMMIT halt recovers via persisted bytes (rebroadcastAndPoll).
- `withHaltObservability` is well-composed with operator-key auth.
- `stripExistingColumnAlters` preserves surrounding SQL.
- TestE2E_RegisterThroughClaim exercises the HTTP path correctly.
- govulncheck + race + gofmt all clean on SPEC-016 surface.

## Recommendation

REQUEST CHANGES.

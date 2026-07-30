# IMPL audit prompt — SPEC-016 Step 4, **CODE REVIEW lane, round 7 (code-only)**

Architecture lane CONVERGED at r4. Security lane CONVERGED at r5.
Only code lane re-audits at r7.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the code-reviewer lane auditing SPEC-016 Step 4 IMPL —
round 7, code-only since security + arch already CONVERGED.

## Round history

| Round | Code | Security | Arch | Verdict |
|-------|------|----------|------|---------|
| r1 | 0/2/3/1 | 0/1/3/0 | 1/2/1/2 | BLOCK |
| r2 | 0/1/3/0 | 0/1/1/0 | 0/2/0/0 | BLOCK |
| r3 | 0/1/3/1 | 0/1/1/0 | 0/1/1/0 | BLOCK |
| r4 | 0/0/4/1 | 0/0/1/1 | **0/0/0/0** | arch CONVERGENT |
| r5 | 0/2/3/3 | **0/0/0/0** | — | security CONVERGENT |
| r6 | 0/1/0/0 | — | — | code REQUEST CHANGES (one HIGH I introduced in r5) |

## What changed between r6 and r7 (fix-pass commit `2935ed6`)

The r6 code lane found ONE HIGH: my r5 placement of the
insufficient-funds guard at the top of the row loop regressed
per-payout-cap, daily-cap-trip, and existing-confirmed-attempt rows.
The r6 fix-pass relocated the check to the architecturally-correct
layer.

### Closed HIGH

**[code:r6-1]** — `Runner.allocateBuildSignBroadcast` now performs the
per-row hot-wallet USDC balance check AFTER the per-day cap check
(in this function) AND AFTER the per-payout-cap + existing-attempt
state machine (in `processRow`). The check fires only when money
would actually leave the hot wallet.

Specifically:
- `Runner.runningBalance *big.Int` field tracks the cycle-scoped
  USDC balance (mirrors `activeSnap` pattern: set at top of RunOnce,
  cleared in defer).
- `hotWalletBalance()` returns a defensive copy.
- `deductPaidAmount(amount)` subtracts on each `rowOutcomePaid`.
- New `rowOutcomeInsufficientFunds` constant; RunOnce row loop
  handles it with skippedFunds++ + break rowLoop.
- The check is INSIDE `allocateBuildSignBroadcast` between the
  per-day cap check (line ~850) and the attempt INSERT (line ~893).
  The BEGIN IMMEDIATE txn rolls back on the deferred ROLLBACK
  when committed=false.
- Early guard at the row-loop top (previous r5 placement) is REMOVED.

### Regression tests (3 new boundary cases + 2 r5 locks)

- `TestRunner_RunOnce_OverPerPayoutCapWithLowBalance_StillEmitsCappedAndContinues`
  Row1 (150) > PerPayoutCap (100); balance 50. Asserts
  `payout_capped` emitted, `payout_insufficient_funds` NOT emitted,
  row2 (40) still processes.

- `TestRunner_RunOnce_DailyCapTrippedWithLowBalance_EmitsDailyCapEvent`
  PerDayCap 100; balance 200. Row1 (60) processes; row2 (60) trips
  daily cap. Asserts `payout_daily_cap_tripped` emitted,
  `payout_insufficient_funds` NOT emitted, loop halts.

- `TestRunner_RunOnce_ExistingConfirmedAttemptWithLowBalance_StillClaims`
  Balance 0. Row1 has an existing confirmed `payout_attempts` row.
  Asserts claimer called once, `payout_insufficient_funds` NOT
  emitted, `skipped_funds` stays 0.

The existing `TestRunner_RunOnce_InsufficientFundsHaltsAndEmits`
(happy-path) and `TestRunner_RunOnce_DailyCapTrippedHaltsLoop` still
pass — the in-broadcast check fires for fresh-broadcast rows with
truly insufficient running balance.

## Branch + commit under audit

- Branch: `impl/spec-016`
- HEAD: `2935ed6 impl(016): Step 4 r6 fix-pass — relocate
  insufficient-funds guard into broadcast path`
- Step 4 is the LAST step. After r7 CONVERGENCE, the single PR opens.

## SPEC under audit

- `specs/SPEC-016-payout-pipeline.md` v0.1.21 LOCKED at commit
  `f0152c0`.

## What the r7 lane MUST check

### A. r6 closure verification

Verify the relocation actually closes [code:r6-1]:

1. The check at `runner.go:451` is GONE (the original misplaced
   guard from r5).
2. The check INSIDE `allocateBuildSignBroadcast` exists at the
   right location: AFTER the per-day cap check, BEFORE
   `InsertAttempt`. On insufficient balance: emit
   `payout_insufficient_funds`, return
   `rowOutcomeInsufficientFunds`. The deferred ROLLBACK fires
   because `committed=false`.
3. `Runner.runningBalance` is properly scoped: set at top of
   RunOnce, cleared in defer. Single-threaded under mu+inFlight.
4. `hotWalletBalance()` returns a defensive copy (so the caller
   can't mutate the running tally accidentally).
5. `deductPaidAmount` is called ONLY on `rowOutcomePaid` (not on
   capped/skipped/failed outcomes).
6. `rowOutcomeInsufficientFunds` is handled in the RunOnce switch:
   skippedFunds++ + `break rowLoop`.
7. The 3 new regression tests + 2 r5 tests cover the boundary
   matrix:
   - over-per-payout-cap + low balance → payout_capped, continue
   - daily-cap trip + low balance → payout_daily_cap_tripped, halt
   - existing confirmed + low balance → claim, no halt
   - happy-path fresh + sufficient balance → process, run finished
   - happy-path fresh + low balance → payout_insufficient_funds, halt

### B. No regressions of earlier closures

Spot-check that nothing from r1-r5 regressed.

### C. New defects from the r6 fix-pass

1. Does the running balance update happen at the right moment?
   `deductPaidAmount` is called after `rowOutcomePaid` is asserted
   (the switch). Verify the deduction uses the SAME amount that
   was actually paid (not the row's provider_credits if they
   differed; not the pre-claim amount).

2. The defensive-copy `hotWalletBalance` returns a new big.Int.
   Verify the caller in `allocateBuildSignBroadcast` doesn't
   pre-allocate based on the running balance and then never check
   again — the check + InsertAttempt must be the same logical step.

3. The `rowOutcomeInsufficientFunds` value MUST be distinct from
   `rowOutcomeCapped`, `rowOutcomeDailyCapTripped`,
   `rowOutcomeFailed`, `rowOutcomeSkipped`. Verify enum.

4. RPC failure for initial balance read: the running balance stays
   nil; the in-broadcast check falls through (no halt). Verify
   that downstream sign/broadcast still completes successfully
   when balance is unknown — this is the documented fallback
   per the inline comment.

### D. §7.1 sweep — final pass

Re-verify EVERY Step 4 event field set (SPEC §7.1 lines 3712-3732).
The r5 + r6 fix-passes touched event emissions; verify nothing
regressed.

### E. Tests + race + gofmt

- `go test -count=1 ./...` from `phase4-coordinator/`
- `go test -race -count=1 ./internal/payout/...`
- `gofmt -l phase4-coordinator/internal/payout/ phase4-coordinator/cmd/coordinator/`
- `git diff --check 2935ed6^..2935ed6`

## Output

Write findings to `specs/SPEC-016-IMPL-STEP_4-code-r7-audit.md`.

**If 0/0/0/0 — declare CONVERGENT.** This is the FINAL audit round
before PR-open. After convergence the single PR opens per the
consolidation plan in commit `92c8672`.

## Discipline

- Don't re-flag closed findings.
- Wall-clock target: 25-35 min.

=== END PROMPT ===
```

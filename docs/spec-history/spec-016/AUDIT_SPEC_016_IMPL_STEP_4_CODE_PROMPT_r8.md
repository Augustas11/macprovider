# IMPL audit prompt — SPEC-016 Step 4, **CODE REVIEW lane, round 8 (code-only)**

Architecture lane CONVERGED at r4. Security lane CONVERGED at r5.
Only code lane re-audits at r8.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the code-reviewer lane auditing SPEC-016 Step 4 IMPL —
round 8, code-only since security + arch already CONVERGED.

## Round history

| Round | Code | Security | Arch | Verdict |
|-------|------|----------|------|---------|
| r1 | 0/2/3/1 | 0/1/3/0 | 1/2/1/2 | BLOCK |
| r2 | 0/1/3/0 | 0/1/1/0 | 0/2/0/0 | BLOCK |
| r3 | 0/1/3/1 | 0/1/1/0 | 0/1/1/0 | BLOCK |
| r4 | 0/0/4/1 | 0/0/1/1 | **0/0/0/0** | arch CONVERGENT |
| r5 | 0/2/3/3 | **0/0/0/0** | — | security CONVERGENT |
| r6 | 0/1/0/0 | — | — | code: HIGH (guard at wrong layer) |
| r7 | 0/1/0/0 | — | — | code: HIGH (deduction overloaded across 4 paths) |

## What changed between r7 and r8 (fix-pass commit `1975494`)

The r7 code lane found ONE HIGH: `RunOnce.deductPaidAmount` ran on
every `rowOutcomePaid`, but only the fresh-broadcast paths
(`allocateBuildSignBroadcast` + `rebroadcastAndPoll`) actually spent
hot-wallet USDC in this cycle. The two prior-cycle paths
(`claimAndLog` + `pollAndConfirm`) double-counted, causing spurious
`payout_insufficient_funds` on subsequent fresh rows.

### Closed HIGH

**[code:r7-1]** — Deduction co-located with the actual spend EVENT:

- `allocateBuildSignBroadcast`: `r.deductPaidAmount(amount)` called
  immediately after the chain accepts the tx (after `BroadcastBoth`
  returns `acceptedAny` AND after `StampBroadcastAt`).
- `rebroadcastAndPoll`: same — `r.deductPaidAmount(attempt.AmountBaseUnits)`
  after the persisted-bytes rebroadcast accepts + stamps. (The
  prior cycle stored the bytes but never stamped; THIS cycle is
  when money actually leaves.)
- `claimAndLog` (existing confirmed): no deduction. Prior cycle
  already spent; top-of-cycle balance reflects it.
- `pollAndConfirm` (prior broadcast confirms now): no deduction.
  Same rationale.
- `RunOnce` row-loop `case rowOutcomePaid`: deduction REMOVED with a
  comment explaining the co-location.

### Regression test added (audit-named boundary)

**`TestRunner_RunOnce_ExistingConfirmedThenFreshExactlyFits`**
- Row 1: 80 base units, existing CONFIRMED `payout_attempts` row
  (simulating a prior cycle's broadcast that confirmed before this
  cycle started).
- Row 2: 100 base units, fresh.
- Top-of-cycle balance = 100 (already reflects row 1's prior 80).
- Asserts:
  - `claimer.calls == 2` (row 1 claim + row 2 fresh pay)
  - NO `payout_insufficient_funds` emitted
  - `skipped_funds` stays 0

Before this fix-pass: row 1 claim deducts 80, row 2 in-broadcast
check sees 20 < 100, emits insufficient_funds + halts.

The 5 prior boundary tests (r5 + r6) still pass — the new
co-location is strictly tighter than the outcome-switch version.

## Branch + commit under audit

- Branch: `impl/spec-016`
- HEAD: `1975494 impl(016): Step 4 r7 fix-pass — deduction co-located
  with broadcast acceptance`
- Step 4 is the LAST step. After r8 CONVERGENCE, the single PR opens.

## SPEC under audit

- `specs/SPEC-016-payout-pipeline.md` v0.1.21 LOCKED at commit
  `f0152c0`.

## What the r8 lane MUST check

### A. r7 closure verification

1. **deductPaidAmount sites.** Confirm the deduction is called ONLY
   in `allocateBuildSignBroadcast` + `rebroadcastAndPoll`, at the
   moment of broadcast acceptance. NOT in:
   - `claimAndLog`
   - `pollAndConfirm`
   - `RunOnce` row-loop switch
   - `pollCancelOnce` (semantic-abuse rowOutcomePaid for cancel
     transitions — verify NO deduction for cancels)
2. **rebroadcastAndPoll nonce-too-low branch.** When `BroadcastBoth`
   returns nonce-too-low and the code falls through to
   `StampBroadcastAt + pollAndConfirm` (treating the chain-serialized
   race as broadcast complete), should the deduction fire? Read the
   code carefully — the prior holder already broadcast the SAME
   bytes; money already left in a prior cycle (when it actually
   reached the chain). Verify the placement matches the SPEC
   intent for this race.
3. **allocateBuildSignBroadcast nonce-too-low path.** Same question
   for the fresh broadcast path: when does deduction happen relative
   to nonce-too-low handling? Read the code.
4. **defensive copy hotWalletBalance.** Still correct (returns a
   new big.Int).
5. **runningBalance lifecycle.** Set at top of RunOnce, cleared in
   defer. The r5+r6+r7 changes don't introduce a race.
6. **The new regression test.** Asserts the audit-named boundary
   exactly. The test data wiring is sane (nonce cursor=2,
   pre-seeded confirmed attempt at nonce=1).

### B. No regressions of earlier closures

Spot-check that the r7 fix-pass did NOT regress any of:
- r5: `payout_insufficient_funds` happy-path emission + halt
- r5: `payout_daily_cap_tripped` event + loop halt
- r6: in-broadcast guard placement (NOT at row-loop top)
- r6: 3 boundary tests (over-cap+low balance, daily-cap+low balance,
  existing-confirmed+low balance — single row each)

### C. New defects introduced by r7

1. Is there any path where rowOutcomePaid is returned WITHOUT the
   deduction having fired? The runner's overall balance accounting
   would then drift LOW (running stays higher than chain reality)
   on subsequent fresh rows — false negatives on insufficient_funds.
   Trace each rowOutcomePaid emit site:
   - claimAndLog: prior cycle spent. Correct: no deduction here.
   - pollAndConfirm (called from broadcast path AFTER fresh broadcast):
     fresh broadcast deducted before pollAndConfirm. So pollAndConfirm
     returning rowOutcomePaid does NOT need its own deduction.
   - allocateBuildSignBroadcast: deducts before returning. ✓
   - rebroadcastAndPoll: deducts before returning. ✓
   - pollCancelOnce: semantic abuse for cancel — no transfer, no
     deduction. ✓

2. The amount used for deduction matches what the chain actually
   accepts:
   - allocateBuildSignBroadcast: `amount` (= row.ProviderCredits,
     which equals the C3-invariant-checked `lprProviderCredits`).
   - rebroadcastAndPoll: `attempt.AmountBaseUnits` (the persisted
     attempt row's amount). Verify this equals what's in the raw
     signed tx bytes (it must, otherwise the prior cycle's
     `verifySignedTx` would have failed). ✓

### D. §7.1 sweep — final pass

The r7 fix-pass didn't touch event emits. Verify nothing regressed.

### E. Tests + race + gofmt

- `go test -count=1 ./...` from `phase4-coordinator/`
- `go test -race -count=1 ./internal/payout/...`
- `gofmt -l phase4-coordinator/internal/payout/ phase4-coordinator/cmd/coordinator/`
- `git diff --check 1975494^..1975494`

## Output

Write findings to `specs/SPEC-016-IMPL-STEP_4-code-r8-audit.md`.

**If 0/0/0/0 — declare CONVERGENT.** This is the FINAL audit round.
After convergence the single PR opens.

## Discipline

- Don't re-flag closed findings.
- Trace the rowOutcomePaid emit sites carefully — the deduction
  placement is subtle.
- Wall-clock target: 25-35 min.

=== END PROMPT ===
```

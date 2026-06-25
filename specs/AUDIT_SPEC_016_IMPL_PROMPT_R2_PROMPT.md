# AUDIT_SPEC_016_IMPL_PROMPT_R2 — Verify closure of round-1 findings

You are auditing the BUILD prompt
`specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md` on branch
`spec/016-payout-impl-prompt` ROUND 2, AFTER the round-1
fix-pass. The round-1 findings live in
[`specs/SPEC-016-IMPL-PROMPT-audit.md`](SPEC-016-IMPL-PROMPT-audit.md)
(verdict: NEEDS FIX PASS; CRITICAL 4 / MAJOR 2 / MEDIUM 3 /
LOW 1).

The controlling contract is unchanged:
[`specs/SPEC-016-payout-pipeline.md`](SPEC-016-payout-pipeline.md)
at v0.1.19, commit `5c034a0` on `main`.

## Scope

Same as round 1: the only intended modified file is
`specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md`. Anything else
in the diff is CRITICAL.

## Closure-verification tasks

For each round-1 finding, verify the fix has landed and does
not re-introduce a new defect:

1. **C1 (§9 prerequisite gate relaxed).** Round-1 found the
   prompt allowed "code can land on `main`" and "Steps 1-3
   can proceed without §9.1 / §9.2 / §9.5b", contradicting
   SPEC §9 "IMPL MUST NOT begin until ALL EIGHT prerequisites
   are discharged." Verify the §1 section now restates the
   SPEC gate unambiguously AND the closing paragraph after
   item 9 no longer carries the "Steps 1-3 can proceed
   without …" carve-out.

2. **C2 (§9 item citations wrong).** Round-1 found Nginx
   labeled as `[§9.6]` and BetterStack as `[§9.7]`, but the
   SPEC has BetterStack as item 6 and Nginx as item 7.
   Verify the labels now read "§9 item 6 — BetterStack" and
   "§9 item 7 — Nginx" (or equivalent unambiguous reordering)
   AND the §1 numbered-list items still cover the eight SPEC
   prerequisites without omission.

3. **C3 (§3.2 ±5 min skew missing).** Round-1 found the §3.2
   EIP-712 block didn't require `ts_utc` within ±5 minutes.
   Verify the block now carries an explicit skew bullet
   citing the `signature_skew` 400 response.

4. **C4 (§4.9 manual-funding trigger-presence check
   missing).** Round-1 found the Step 3 record-funding
   block didn't require the §4.8a same-transaction
   `sqlite_master` count check for the three bootstrap
   triggers. Verify the block now requires that check AND
   the rejection code `422 bootstrap_trigger_missing` is
   named.

5. **M1 (Signer contract under-specified).** Round-1 found
   the prompt named only `FromAddress` / `SignTx` / NO
   `SignMessage`, missing unsignedTxBytes format,
   caller-does-not-pre-hash rule, determinism guidance,
   cancellation behavior, and typed error semantics. Verify
   the §6.3 / §6.3.1 block in Step 2 now surfaces all five.

6. **M2 (§9.5b SPEC-005 handoff incomplete).** Round-1
   found the prompt's §9.5b bullet list missing
   `Idempotency-Key` header/body equality,
   `min_payout_credits_override=0`, "MUST NOT trigger fresh
   settlement run", `ledger_payout_ready_admin_inserted`
   event, AND the same-SQLite-DB requirement. Verify all
   five are now present in the §1 item 6 §9.5b bullet list.

7. **Med1 (Step 1 same-DB rule too strong).** Round-1 found
   the prompt asserted "All SPEC-016 tables MUST live in
   the same SQLite database file" but SPEC explicitly
   defers the comprehensive pin to v0.2 (per-table pins
   only at v0.1.x). Verify the Step 1 section now lists
   the SPEC's per-table pins (§3.1, §4.7, §4.8a, §4.8b,
   §4.9) WITHOUT the global all-table claim.

8. **Med2 (§7.4 query labels collide).** Round-1 found the
   prompt called the per-provider sum query "(A)" and the
   NULL-currency detector "(B)" while SPEC §7.4 reserves
   (A) for stale-orphan, (B) for compensation-forgery, (C)
   for orphan-mismatch, (D) for cancel-observability.
   Verify the prompt's Step 4 §7.4 block uses the SPEC's
   (A)/(B)/(C)/(D) labels for the labeled queries AND uses
   descriptive names (NOT new letter labels) for the
   unlabeled regression queries.

9. **Med3 (§4.5 index count).** Round-1 found the prompt
   said "FIVE partial UNIQUE / non-UNIQUE indexes" while
   listing seven. Verify the prompt now says "seven" (or
   equivalent count) consistent with the bullet list.

10. **L1 (`feedback-spec-audit-loop-before-pr` missing).**
    Round-1 found the prompt did not cite this memory
    rule. Verify §3 now references it.

## Calibration

This is a closure-verification audit. Treat as CRITICAL only
if a round-1 CRITICAL finding remains unfixed OR a fix
introduced a NEW CRITICAL-class defect. New MAJOR / MEDIUM /
LOW findings against the round-1 fix-pass MAY surface; flag
them with severity but report them separately from the
closure-check.

## Verdict + counts

- **Closure verdict:** READY (all round-1 findings closed) or
  NEEDS FIX PASS (any round-1 finding still open).
- **New findings (if any):** CRITICAL / MAJOR / MEDIUM / LOW
  counts on text introduced by the fix-pass, with
  prompt-line references.
- **Merge gate:** 0 round-1 CRITICAL/MAJOR still open AND 0
  NEW CRITICAL/MAJOR.

If both gates pass, the prompt is READY for merge.

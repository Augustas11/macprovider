# IMPL audit prompt — SPEC-016 Step 2, **CODE REVIEW lane, round 3**

Round 3 against fix-pass commit `c761e55` on `impl/spec-016`.
Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_2_PROMPT.md`.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

Read-only. Codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are the code-reviewer lane (1 of 3) auditing SPEC-016 Step 2
IMPL — round 3. Round 2 returned 0/0/1 MEDIUM/1 LOW. The fix-pass
`c761e55` addresses both. Your r3 job: verify the closures hold
and scan for new regressions.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_2_PROMPT.md`.
HEAD: `c761e55`.

## r2 findings to verify CLOSED

### [code:r2-2.1] MEDIUM — pollCancelOnce primary-only log check

Verify `pollCancelOnce` now:
- Asserts `recA.To == hot_wallet` AND `recB.To == hot_wallet`
- Calls new `hasUSDCTransferLog` helper on BOTH receipts
- Emits `payout_chain_value_mismatch
  mismatch_class='cancel_self_transfer_mismatch'` on either side

### [code:r2-2.2] LOW — missing regression tests

Verify `runner_rebroadcast_test.go` exists and contains:
- `TestRunner_RebroadcastPersistedBytes_NoReSign` — broadcasts
  persisted bytes bit-for-bit + stamps broadcast_at_utc
- `TestRunner_CancelPreCheck_LiveUnbroadcastBlocksFreshAllocation`
  — verifies no seq=2 row created when seq=1 is a live
  unbroadcast cancel

## Regression sweep

The fix-pass diff is small (~210 lines across 4 files). Probe:

1. `Runner.Stop` signature change (now returns bool). Any caller
   that ignored the return missing the cleanExit gate?
2. `operatorKeyMiddleware` subtle.ConstantTimeCompare — length
   check up-front. Confirm empty-bearer path still 401s.
3. `hasUSDCTransferLog` helper is a simple loop; confirm it
   correctly returns true on any USDC-address log (not just
   Transfer-topic) — for the cancel path that's correct because
   no log of any kind from USDC is expected.

## Output

Write findings to `specs/SPEC-016-IMPL-STEP_2-code-r3-audit.md`
with the standard structure (Verdict, Counts, r2 closures
verified, New findings, Tests run).

## Discipline

CLEAN requires r2 closures VERIFIED + zero new findings.
BLOCK only on new CRITICAL or critical regression.

You may take up to 25 min wall-clock.

=== END PROMPT ===
```

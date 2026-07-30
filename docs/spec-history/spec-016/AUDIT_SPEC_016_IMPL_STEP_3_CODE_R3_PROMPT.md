# IMPL audit prompt — SPEC-016 Step 3, **CODE REVIEW lane, round 3**

Round 3 against fix-pass commit `9bbec55` on `impl/spec-016`.
Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_3_PROMPT.md`.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

Read-only. Codex MUST NOT modify any file.

**Note:** Security lane converged at r2 (CLEAN 0/0/0/1 LOW perf
hint). This r3 is code + arch only.

---

```
=== BEGIN PROMPT ===

You are the code-reviewer lane (1 of 2 in r3) auditing SPEC-016
Step 3 IMPL — round 3.

Round 2 returned 0/0/2 MEDIUM/0. The fix-pass `9bbec55` folds
the code lane's [code:r2-2.1] MEDIUM into the architecture fix
([arch:r2-3.3]) — both closed via migration 0012 + run_id
persistence + emit updates. Your r3 job: verify the closure
holds and confirm the [code:r2-2.2] open-question on per-cycle
producer scale is now mitigated or still acceptable.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_3_PROMPT.md`.

HEAD: `9bbec55`. Branch `impl/spec-016`.

## r2 findings to verify CLOSED

### [code:r2-2.1] MEDIUM — stale PAGE event missing run_id + updated_at_utc

Verify:
- Migration 0012 adds nullable `run_id` column to
  cancel_reconfirm_stale_outbox via ALTER TABLE ADD COLUMN.
- `orphans.go` ProduceStaleOutboxRows persists runID inline
  in the INSERT.
- `orphans.go` ListUnemittedStaleOutboxOlderThan reads
  `COALESCE(run_id, '')` so older rows still work.
- `orphans.go` ClaimAndEmitStaleOutbox row-read includes
  the run_id column.
- `orphans.go` sync emit (inside ProduceStaleOutboxRows)
  emits both `run_id` and `updated_at_utc` fields.
- `reaper.go` recovery emit emits both fields.
- StaleOutboxRow struct has a RunID field.

### [code:r2-2.2] MEDIUM (LOW confidence "open question") — per-cycle producer scale

The r2 audit flagged that ProduceStaleOutboxRows scans every
candidate row with no partial index AND no per-cycle limit.

Probe in r3:
1. Look at the cardinality assumption: how many cancel rows
   could meet the predicate
   `is_cancel_self_transfer=1 AND broadcast_at_utc IS NOT NULL
    AND confirmed_at_utc IS NULL AND
    cancel_reconfirm_stale_paged_at_utc IS NULL AND
    abandoned_at_utc IS NULL AND updated_at_utc < cutoff`?
   In practice this is "broadcast cancels that never
   reconfirmed" — should be near-zero in steady state.
2. Should a partial index on the predicate be added? Or is
   the producer correctly bounded by the natural rarity of
   stale cancels?
3. If still an open question, propose the index spec for
   r4 / Step 4.

## Cross-lane closures touching code-review surface

### [arch:r2-3.2-A] MAJOR — two-RPC verification before stale PAGE

Verify:
- `ProduceStaleOutboxRows` signature now includes
  `rpcs TwoRPCs, runID string`.
- Per-candidate loop calls Primary.TransactionReceipt + 
  Secondary.TransactionReceipt before CAS.
- Skips on either RPC error.
- Skips on either non-nil receipt.
- The zero-TwoRPCs early-return at the top of the function
  preserves the test-disable contract.

### [arch:r2-3.2-B] MAJOR — admin-side stale-outbox INSERT removed

Verify `orphans.go` serveRecord cancel-self-transfer branch:
- The INSERT OR IGNORE INTO cancel_reconfirm_stale_outbox
  block is GONE.
- A clear comment block explains the removal AND directs
  future-readers to the runner-owned producer.
- The branch still records the orphan observation per
  v0.1.14 (no ledger_payout_ready revert).
- The isCancelSelf + reorgReactivatedAt locals are still
  used by the §7.1 emit at emitOrphanRecorded.

## Regression sweep

The fix-pass diff is ~259 lines across 5 files. Probe:

1. Migration 0012 uses ALTER TABLE ADD COLUMN — verify the
   migrations runner tracks it via payout_schema_applied so
   it's idempotent.
2. Producer signature change ripple: runner.go RunOnce call
   site passes `r.opts.RPCs, runID`. Verify no test path
   that bypasses the producer.
3. step3_r2_test.go: TestProduceStaleOutboxRows tests cover
   the happy path + reconfirmable-skip path + disabled path.
   Does any test still assert the OLD signature (without
   rpcs + runID)?

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_3-code-r3-audit.md`.

## Discipline

CLEAN requires r2 closures VERIFIED + zero new findings.
BLOCK only on new CRITICAL or HIGH.

Wall-clock target: 20-25 min.

=== END PROMPT ===
```

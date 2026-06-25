# SPEC-016 v0.1.16 Codex Round 18 audit

**Audit target:** `specs/SPEC-016-payout-pipeline.md` v0.1.16 at commit `ac31250` on branch `spec/016-payout-pipeline-v0.1`.
**Auditor:** codex (via `/ask codex` per [[feedback-codex-only-audits]]).
**Fix pass:** v0.1.17.
**Date:** 2026-06-25.

---

## Codex verdict

**Audit Verdict**
NOT CONVERGED — 0 CRITICAL, 0 MAJOR, 2 MEDIUM.

Audited `/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md` at `ac31250` on `spec/016-payout-pipeline-v0.1`. Actual file length is 5,617 lines.

**MEDIUM-1 — Stale PAGE can be durably suppressed before it is emitted**

Reference: [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:3351)

The §4.7 stale CAS durably sets `cancel_reconfirm_stale_paged_at_utc = :now`, commits, then says the PAGE emits only if the CAS affected 1 row. There is no durable outbox/reaper for `payout_cancel_self_transfer_reconfirm_stale`. If the coordinator crashes after `COMMIT` and before the journalctl emit, the marker remains non-NULL, future cycles hit the 0-row path, and the only operator-recovery PAGE is permanently suppressed. This reopens the “silent stranded cancel” visibility gap that v0.1.15/v0.1.16 were trying to close.

Recommended fix wording:

```md
For `payout_cancel_self_transfer_reconfirm_stale`, the CAS marker is NOT itself the delivery record. IMPL MUST insert a durable outbox row in the same `BEGIN IMMEDIATE` transaction as the NULL→:now transition, keyed by `(payout_id, attempt_seq, stale_started_at_utc)` and carrying `emitted_to_log INTEGER NOT NULL DEFAULT 0`.

After COMMIT, the runner emits the PAGE from the committed outbox row and then marks `emitted_to_log = 1`. If the process crashes before the emit or before marking emitted, a background reaper MUST scan `emitted_to_log = 0` rows older than 5 minutes and emit the same event with a stable `event_id = <outbox id>`. Downstream consumers MUST de-dupe by `event_id`. The once-per-transition contract is the UNIQUE outbox row; log delivery is retryable.
```

**MEDIUM-2 — §4.7 step-4 SQL still does not clear the new marker**

Reference: [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:3286)

The changelog and §4.7 prose say the reorg-reactivation UPDATE clears `cancel_reconfirm_stale_paged_at_utc`, and later prose repeats that requirement at line 3339. But the actual step-4 SQL block only clears `confirmed_at_utc`, `block_number`, and `gas_used_native_wei`; it does not set the new column to NULL. A cold implementer copying the SQL block could miss the re-arm, leaving a previously marked row unable to emit a fresh stale PAGE after a later reactivation.

Recommended fix wording:

```sql
UPDATE payout_attempts
   SET confirmed_at_utc = NULL,
       block_number = NULL,
       gas_used_native_wei = NULL,
       cancel_reconfirm_stale_paged_at_utc = NULL,
       last_error = 'cancel_self_transfer_reorged:' || :prior_tx_hash,
       updated_at_utc = :now
 WHERE payout_id = :payout_id
   AND attempt_seq = :attempt_seq
   AND is_cancel_self_transfer = 1
   AND abandoned_at_utc IS NULL
   AND confirmed_at_utc IS NOT NULL;
```

**Non-Findings**

Cross-mutator ordering is otherwise acceptable: the §4.3 confirmed branch is specified as transition-only and clears the marker, while the stale CAS is gated on `confirmed_at_utc IS NULL` and serialized by `BEGIN IMMEDIATE`.

The direct `payout_attempts` column addition is acceptable for a design-only spec; there is no shipped downstream reader to break. The in-spec `SELECT * FROM payout_attempts` remains undesirable implementation style, but not a v0.1.16 blocker.

No new replay, MEV, Signer, reorg money-out, race-to-double-pay, or operator-key drain path found. Markdown fences are balanced, `git diff --check` is clean, BetterStack includes the new stale event, and the 4 deferred LOWs remain present. The v0.1.16 changelog is structurally readable, but its closure claim is inaccurate because the step-4 SQL clear did not land.

---

## Cross-reference

- Raw codex CLI artifact (full prompt + transcript):
  `.omc/artifacts/ask/codex-audit-spec-016-v0-1-16-commit-ac31250-branch-spec-016-payout-2026-06-25T05-36-57-381Z.md`
- Fix pass commit message: see `git log ac31250..HEAD --oneline -- specs/SPEC-016-payout-pipeline.md`
  for the v0.1.17 commit that absorbed these findings.
- Audit-loop discipline: [[feedback-spec-audit-loop-before-pr]] + [[feedback-codex-only-audits]].

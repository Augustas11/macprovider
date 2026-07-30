## Code Review Summary

**Files Reviewed:** 5 modified files, plus supporting migration/spec context  
**Total Issues:** 1 confirmed, 2 open questions  
**Validation:** `go test ./internal/payout -run 'TestProduceStaleOutboxRows|TestMigrate' -count=1` passed; `go test ./internal/payout -count=1` passed. `lsp_diagnostics` was unavailable in this session.

### By Severity
- CRITICAL: 0
- HIGH: 0
- MEDIUM: 1
- LOW: 0

### Issues

[MEDIUM] Stale-marker CAS does not update `payout_attempts.updated_at_utc`  
File: [orphans.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/orphans.go:476)  
Confidence: HIGH  
Issue: SPEC §4.7’s stale transition SQL sets both `cancel_reconfirm_stale_paged_at_utc = :now` and `updated_at_utc = :now`, but the implementation only sets the stale marker. The outbox correctly preserves the pre-read reorg timestamp as `reorg_reactivated_at_utc`, so this is not a PAGE emission blocker, but it leaves the attempt row’s own update timestamp stale after the CAS.  
Fix: Add `updated_at_utc = ?` to the CAS update and pass `staleStarted`; extend `TestProduceStaleOutboxRows_BothRPCsMissAfterThreshold_Produces` to assert the attempt row timestamp advances while the outbox keeps the original reactivation timestamp.

### Open Questions

[MEDIUM] Per-cycle producer scale remains acceptable but unindexed on full predicate  
File: [orphans.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/orphans.go:397)  
Confidence: LOW  
Issue: The producer still scans all matching stale-candidate cancel broadcasts before RPC checks. Existing `idx_pa_cancel_recent` bounds this to cancel broadcasts, and the practical cardinality should be near-zero, so this is acceptable for Step 3.  
Fix if needed in r4/Step 4: add a partial index such as `idx_pa_cancel_reconfirm_stale_scan ON payout_attempts(updated_at_utc, payout_id, attempt_seq, nonce, tx_hash, block_number) WHERE is_cancel_self_transfer=1 AND raw_signed_tx IS NOT NULL AND broadcast_at_utc IS NOT NULL AND confirmed_at_utc IS NULL AND cancel_reconfirm_stale_paged_at_utc IS NULL AND abandoned_at_utc IS NULL`.

[LOW] Non-idempotent `ALTER TABLE ADD COLUMN` is tracked, but not transactionally paired with the tracking insert  
File: [migrations.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/migrations.go:73)  
Confidence: MEDIUM  
Issue: Normal reruns are safe because `payout_schema_applied` records `0012_stale_outbox_run_id.sql`, but a crash after the `ALTER TABLE` succeeds and before the tracking row insert would make the next run hit duplicate-column failure. This is an existing migration-runner limitation, not specific to this fix-pass.  
Fix: If crash-safe migration recovery is in scope, wrap each migration body plus tracking insert in a transaction where SQLite permits it, or make ADD COLUMN migrations duplicate-column tolerant.

### Positive Observations
- [code:r2-2.1] is closed: migration 0012 adds nullable `run_id`, producer persists it, list/claim use `COALESCE(run_id, '')`, and sync/reaper PAGE emits include `run_id` plus `updated_at_utc`.
- [arch:r2-3.2-A] is closed: producer takes `TwoRPCs`, skips on either RPC error or non-nil receipt, and preserves the zero-RPC disabled test path.
- [arch:r2-3.2-B] is closed: admin-side stale-outbox insert is gone, with a clear comment pointing to the runner-owned producer.
- Regression tests cover happy path, reconfirmable skip, and disabled producer path.

### Recommendation

COMMENT. No CRITICAL or HIGH findings; r2 closures are verified, with one MEDIUM spec-alignment fix recommended before calling the r3 code lane fully clean.


---

_Persisted from codex artifact codex-impl-audit-prompt-spec-016-step-3-code-review-lane-round-3-r-2026-06-25T17-58-40-406Z.md._

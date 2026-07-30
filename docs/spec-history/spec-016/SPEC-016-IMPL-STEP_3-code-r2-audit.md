
```text
## Code Review Summary

**Files Reviewed:** 10  
**Total Issues:** 2  
**Validation:** `git diff --check`, `go test ./internal/payout`, targeted Step 3 tests, `go test ./cmd/coordinator`, `go vet ./internal/payout ./cmd/coordinator` all passed. `gopls`/LSP diagnostics unavailable (`gopls` not installed).  
**Note:** I did not write `specs/SPEC-016-IMPL-STEP_3-code-r2-audit.md` because the prompt also says read-only / must not modify files.

### By Severity
- CRITICAL: 0
- HIGH: 0
- MEDIUM: 2
- LOW: 0

### Issues

[MEDIUM] Stale PAGE event field set is still incomplete on the runner sync path, and `run_id` is missing on both PAGE emitters  
File: `/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/orphans.go:491`  
File: `/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/reaper.go:192`  
Confidence: HIGH  
Issue: `payout_cancel_self_transfer_reconfirm_stale` from the runner sync path emits `event_id`, payout fields, `reorg_reactivated_at_utc`, and `ts_utc`, but not `updated_at_utc`. The reaper path adds `updated_at_utc`, but both paths still omit spec-required `run_id` from `SPEC-016` §7.1. Current outbox schema also does not persist `run_id`, so the reaper cannot reconstruct it.  
Fix: Thread `run_id` into `ProduceStaleOutboxRows`, persist it in `cancel_reconfirm_stale_outbox` via an idempotent migration, and emit `run_id` + `updated_at_utc` from both sync and reaper paths. Add log-field assertions for both emitters.

### Open Questions

[MEDIUM] Per-cycle stale-outbox producer may be unbounded at scale  
File: `/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/orphans.go:370`  
Confidence: LOW  
Issue: `ProduceStaleOutboxRows` scans every stale cancel candidate before the normal §4.3 ready-payout query, with no batch limit and no index tailored to the full predicate. This may be fine if cancel rows remain tiny, but the regression prompt explicitly asks whether the new pre-run DB scan can affect `payout_run_started` → `payout_run_finished` latency.  
Fix: If expected cardinality is non-trivial, add a partial index on the stale-cancel predicate keyed by `updated_at_utc`, and/or cap rows per cycle.

### Positive Observations

- Duplicate orphan submission closure is present: migration `0011_orphan_uniqueness.sql` uses `CREATE UNIQUE INDEX IF NOT EXISTS idx_pro_unique_active`, and the handler maps unique violations to `409 orphan_already_recorded`.
- Bootstrap-reopen defense is implemented inside the same `BEGIN IMMEDIATE` manual funding transaction.
- Strict 32-byte uint256 decode is present; truncating low-8-byte behavior is gone.
- ReorgPoller `Start`/`Stop` uses locking and mirrors the bool-return shutdown contract.
- Handler-level tests cover the requested pause/resume, funding, orphan, reaper, and poller paths.

### Recommendation

COMMENT

No CRITICAL or HIGH issues found, so this does not block under the r2 discipline. The stale-event field-set gap should be fixed before calling the r1 `[code:1.3]` closure fully clean.


---

_Persisted from codex artifact codex-impl-audit-prompt-spec-016-step-3-code-review-lane-round-2-r-2026-06-25T17-45-39-345Z.md._

## Code Review Summary

**Files Reviewed:** 8  
**Total Issues:** 8

### By Severity
- CRITICAL: 0
- HIGH: 0
- MEDIUM: 5
- LOW: 3

### Findings

[MEDIUM] [code:1.1] Duplicate orphan submissions are not rejected as 409  
File: `phase4-coordinator/internal/payout/orphans.go:192`  
Confidence: HIGH  
Issue: `serveRecord` inserts into `payout_reorg_orphans` without first checking for an existing `(payout_id, attempt_seq, orphan_tx_hash)` row, and the Step 1 schema has no uniqueness constraint for that tuple. The handler’s own response table promises 409 for an existing orphan, but duplicate submissions currently create duplicate orphan rows.  
Fix: Inside the existing `BEGIN IMMEDIATE`, check for an existing matching orphan before the insert and return 409, or add a unique index/migration if schema changes are allowed.

[MEDIUM] [code:1.2] `payout_flag_audit_reaped` omits required audit fields  
File: `phase4-coordinator/internal/payout/pauseresume.go:227`  
Confidence: HIGH  
Issue: The reaper emits `event_id`, `flag`, `new_value`, and `severity`, but SPEC §7.1 requires the reaped event to include `flag_audit_id`, `flag_name`, `old_value`, `new_value`, `occurred_at_utc`, `reap_lag_seconds`, and `ts_utc`. This weakens the audit trail for orphaned runtime flag events.  
Fix: Emit the full §7.1 field set from `AuditRow` plus computed reap lag and current timestamp.

[MEDIUM] [code:1.3] Stale cancel outbox reaper events omit required §7.1 fields  
File: `phase4-coordinator/internal/payout/reaper.go:188`  
Confidence: HIGH  
Issue: `payout_cancel_self_transfer_reconfirm_stale` omits `run_id`, `updated_at_utc`, and `ts_utc`, and the aggregate `payout_stale_outbox_reaped` event at line 166 does not emit the per-row fields required by §7.1.  
Fix: Add the required fields when claiming each stale outbox row, or explicitly revise the spec if reaper-originated stale events are intended to have a different schema.

[MEDIUM] [code:1.4] Funding recorded event omits `operator_note` and actor  
File: `phase4-coordinator/internal/payout/funding.go:442`  
Confidence: HIGH  
Issue: SPEC §7.1 lists `operator_note` and `actor=operator_key` for `payout_funding_recorded`, but `emitFundingRecorded` does not log either.  
Fix: Include `operator_note` and a non-secret actor label. If the funding handler needs the actor, pass it through `NewMuxStep3` similarly to pause/resume.

[MEDIUM] [code:1.5] Step 3 tests do not cover several normative handler paths  
File: `phase4-coordinator/internal/payout/step3_test.go:264`  
Confidence: HIGH  
Issue: Several tests validate helper SQL or construction rather than the real HTTP/service behavior. For example, the bootstrap-trigger test replicates the trigger-count query but does not call `ServeRecordFunding` and assert the 422 response/event. Missing coverage includes idempotency mismatch, hot-wallet deny-list, both-RPC receipt validation, pause/resume conflict codes, record-orphan duplicate/resolve paths, and reaper `Start`/`Stop` behavior.  
Fix: Add `httptest` coverage around the actual handlers and explicit tests for each checklist invariant.

[LOW] [code:1.6] `ReapOnce` reports cancellation as an error during graceful shutdown  
File: `phase4-coordinator/internal/payout/pauseresume.go:217`  
Confidence: HIGH  
Issue: On `ctx.Done()`, `ReapOnce` returns `ctx.Err()`, which `Reaper.runOnce` logs as a reaper failure. The audit checklist asks for graceful skipping on cancellation.  
Fix: Return `reaped, nil` on cancellation, or suppress `context.Canceled` / `context.DeadlineExceeded` in `runOnce`.

[LOW] [code:1.7] Receipt uint256 decoding accepts malformed/non-canonical data  
File: `phase4-coordinator/internal/payout/funding.go:373`  
Confidence: MEDIUM  
Issue: `uint256FromData` decodes only the last 8 bytes and does not require a 32-byte ABI word or reject non-zero high bytes. Real USDC values should fit, but the verifier is looser than “Data big-endian uint256”.  
Fix: Require `len(data) == 32`, reject non-zero high 24 bytes, then decode the low 8 bytes.

[LOW] [code:1.8] Whitespace check fails on new blank line at EOF  
File: `phase4-coordinator/internal/payout/funding.go:454`  
Confidence: HIGH  
Issue: `git diff --check 191e3be^ 191e3be` reports a new blank line at EOF.  
Fix: Remove the extra blank line.

### Open Questions

None.

### Positive Observations

- `WriteFlagWithAudit` keeps UPDATE + audit INSERT + COMMIT on one pinned `*sql.Conn` with `BEGIN IMMEDIATE`.
- Runtime flag CAS uses `UPDATE ... RETURNING id` and reads the audit row inside the CAS transaction.
- Pause/resume correctly share `serveFlip` and map already-at-target conflicts to the right endpoint-specific codes.
- Manual funding checks exactly the three bootstrap triggers inside the same transaction before reading `payout_bootstrap_complete`.
- `NewMuxStep3` performs required nil checks and path-table parity verification.

### Validation

- `go test ./internal/payout ./cmd/coordinator` passed.
- `go vet ./internal/payout ./cmd/coordinator` passed.
- Static scan for obvious JS-style debug/secrets patterns found no matches.
- `git diff --check 191e3be^ 191e3be` found the EOF whitespace issue above.

### Recommendation

COMMENT (FIX-THEN-PROCEED)



---

_Persisted from codex artifact codex-impl-audit-prompt-spec-016-step-3-code-review-lane-round-1-m-2026-06-25T17-25-50-262Z.md._

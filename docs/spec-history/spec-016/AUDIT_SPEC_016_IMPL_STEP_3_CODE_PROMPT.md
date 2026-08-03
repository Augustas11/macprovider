# IMPL audit prompt — SPEC-016 Step 3, **CODE REVIEW lane, round 1**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_3_PROMPT.md`.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

Read-only. Codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are the code-reviewer lane (1 of 3) auditing SPEC-016 Step 3
IMPL — round 1.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_3_PROMPT.md`.

HEAD: `191e3be impl(016): Step 3`. Branch `impl/spec-016`.

## Files in scope (~1,565 LOC + ~480 LOC tests)

- `phase4-coordinator/internal/payout/runtime_flags.go`
- `phase4-coordinator/internal/payout/pauseresume.go`
- `phase4-coordinator/internal/payout/funding.go`
- `phase4-coordinator/internal/payout/orphans.go`
- `phase4-coordinator/internal/payout/reaper.go`
- `phase4-coordinator/internal/payout/mux.go` (Step 3 diff only)
- `phase4-coordinator/cmd/coordinator/main.go` (Step 3 diff only)
- `phase4-coordinator/internal/payout/step3_test.go`

## Code-review checklist

### A. §4.8a write-audit pipeline

1. WriteFlagWithAudit — UPDATE + INSERT + COMMIT all run on
   ONE *sql.Conn inside ONE BEGIN IMMEDIATE. No autocommit
   leak.
2. Rate-limit check reads the most recent audit row by
   `ORDER BY id DESC LIMIT 1`. Time parse uses RFC3339Nano.
3. ClaimAndEmit — separate txn from the parent write. CAS
   uses RETURNING id. Read of the audit row happens INSIDE
   the CAS txn so emit sees the committed payload.
4. ListUnemittedOlderThan — index `idx_rfa_unemitted` covers
   the WHERE clause.
5. Sentinel errors (ErrFlagAlreadyAtTarget /
   ErrFlagRateLimited / ErrFlagMissing) are returned cleanly,
   without leaking SQL strings.

### B. §6.4.1 pause/resume

1. ServePause / ServeResume share a serveFlip helper —
   verify the only differences are newValue + conflictCode +
   eventName.
2. The conflict path returns 409 with the right code
   (`already_paused` for pause, `already_running` for resume).
3. The 422 invariant violation path emits
   `payout_invariant_violation` BEFORE returning 500.
4. ReapOnce iterates over ListUnemittedOlderThan and skips
   gracefully on ctx.Done().

### C. §4.9 record-funding

1. Idempotency-Key vs request body tx_hash — case-insensitive
   equality via strings.EqualFold. Missing header → 422
   `idempotency_key_mismatch`.
2. from == hot_wallet → 400 (deny-list).
3. serveManual — count(*) sqlite_master check has exactly the
   3 named triggers (NOT 4 — trg_lpr_terminal_status_guard is
   from SPEC-005, NOT in this set).
4. serveManual — payout_bootstrap_complete SELECT runs after
   the trigger-presence check, INSIDE the same txn.
5. serveRPCConfirmed — verifyFundingReceipt is called on
   BOTH receipts. Side-discriminator emit (primary / secondary).
6. verifyFundingReceipt — Topic[0] = USDC Transfer signature
   hash; from = Topic[1], to = Topic[2]; value = Data
   big-endian uint256.
7. UNIQUE(tx_hash) violation → 409
   `tx_hash_already_recorded` via isUniqueViolation helper
   (string-match works for both modernc.org/sqlite and
   mattn/go-sqlite3).

### D. §4.7 record-orphan

1. serveRecord — observed_* columns populated from lpr+pa
   join INSIDE the same BEGIN IMMEDIATE txn as the orphan
   INSERT.
2. Cancel-self-transfer carve-out — INSERT OR IGNORE on
   cancel_reconfirm_stale_outbox guarded by
   `isCancelSelf == 1 && reorgReactivated.Valid &&
   reorgReactivated.String != ""`.
3. NO ledger_payout_ready UPDATE on the cancel path.
4. serveResolve — guarded by `resolved_at_utc IS NULL` in
   the WHERE clause so a second resolve attempt is 404.
5. emitOrphanRecorded — full §7.1 field set (orphan_id,
   payout_id, attempt_seq, observed_*, is_cancel_self_transfer,
   reason, ts_utc, severity=PAGE).
6. ClaimAndEmitStaleOutbox — CAS + RETURNING id mirrors
   §4.8a discipline.

### E. Reaper

1. runOnce calls both reaper paths every tick.
2. Stop returns bool (true = clean exit; false = timeout).
3. Stop is idempotent (sync.Once + nil-check).
4. Eager first-pass on Start before the ticker tick.
5. No goroutine leak on Stop — done channel closes.

### F. mux.go Step 3 diff

1. step3PathTable has all 4 new routes with RealmOperatorKey.
2. NewMuxStep3 nil-checks every required field.
3. Path-table verifier asserts parity (no drift).

### G. main.go Step 3 wiring

1. setupPayout constructs services in order: writer →
   pauseSvc → fundingSvc → orphansSvc → reaper. Each error
   path Releases the lease (so the next process can acquire).
2. reaper.Start() is called AFTER runner.Start().
3. Shutdown closure: runner.Stop(ctx) → reaper.Stop(ctx) →
   Release-on-clean-exit.
4. Actor string is "operator_key:coordinator" (non-secret
   label).

### H. Tests

1. step3_test.go covers all the SPEC normative invariants
   enumerated above.
2. Tests use the same helpers Step 1/2 tests use (openTestDB,
   insertReadyRow, seedBootstrapForTest).
3. No test depends on time.Now indirectly via NowFn defaults.

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_3-code-r1-audit.md`. Structure:

```
## Code Review Summary

**Files Reviewed:** N
**Total Issues:** N

### By Severity
- CRITICAL: N
- HIGH: N
- MEDIUM: N
- LOW: N

### Findings

[CRITICAL] [code:1.1] <title>
File: file.go:LINE
Confidence: HIGH/MEDIUM/LOW
Issue: <one-paragraph>
Fix: <one-paragraph>

...

### Recommendation

APPROVE / COMMENT (FIX-THEN-PROCEED) / BLOCK
```

## Discipline

- Verify each item above against the actual code.
- Don't re-flag patterns Step 1/2 already audited; only
  audit the Step 3 delta + the cross-cutting wiring.
- Wall-clock target: 25-30 min.

=== END PROMPT ===
```

# IMPL audit prompt — SPEC-016 Step 3, **CODE REVIEW lane, round 2**

Round 2 against fix-pass commit `6044056` on `impl/spec-016`.
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
IMPL — round 2.

Round 1 returned 0/0/5 MEDIUM/3 LOW. The fix-pass `6044056`
addresses all 8 (plus the cross-lane MEDIUM/HIGH/CRITICAL/MAJOR
findings from the other lanes that touch the same files). Your
r2 job: verify each closure holds and look for regressions
introduced by the fix-pass.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_3_PROMPT.md`.

HEAD: `6044056`. Branch `impl/spec-016`.

## r1 code findings to verify CLOSED

### [code:1.1] MEDIUM — orphans duplicate-submission 409

Verify:
- migration `0011_orphan_uniqueness.sql` adds partial UNIQUE
  INDEX `idx_pro_unique_active`.
- `orphans.go` serveRecord maps `isUniqueViolation(err)` to 409
  `orphan_already_recorded`.
- Test `TestServeRecordOrphan_DuplicateSubmission_409` covers it.

### [code:1.2] MEDIUM — payout_flag_audit_reaped field set

Verify the emit in `pauseresume.go` now includes:
flag_audit_id, flag_name, old_value, new_value,
occurred_at_utc, reap_lag_seconds, ts_utc, severity=WARN.

### [code:1.3] MEDIUM — stale-outbox event field sets

Verify in `reaper.go`:
- payout_cancel_self_transfer_reconfirm_stale emits
  updated_at_utc + ts_utc (in addition to existing fields).
- payout_stale_outbox_reaped is now per-row WITH event_id,
  payout_id, attempt_seq, stale_started_at_utc,
  reap_lag_seconds, ts_utc, severity=WARN.
- The aggregate-count emit at the end of runOnce was REMOVED.

### [code:1.4] MEDIUM — payout_funding_recorded field set

Verify `funding.go` emitFundingRecorded now includes
operator_note + actor. Verify main.go passes
`Actor: "operator_key:coordinator"` to NewFundingService.

### [code:1.5] MEDIUM — handler-level test coverage

Verify `step3_http_test.go` covers ALL of:
- ServePause happy + 409 + 400 missing reason + 429 rate-limit
- ServeResume already_running 409
- ServeRecordFunding idempotency mismatch 422 + hot-wallet
  deny-list 400 + manual accept 201 + bootstrap-reopen 422
- ServeRecordOrphan duplicate 409 + resolve 404
- Reaper Start+Stop idempotent + bool
- ReorgPoller Start+Stop idempotent + bool

### [code:1.6] LOW — ReapOnce graceful ctx cancel

Verify ReapOnce returns `reaped, nil` (NOT `reaped, ctx.Err()`)
on ctx.Done().

### [code:1.7] LOW — uint256 strict decode

Already addressed by [sec:2] HIGH fix — verify the strict
big.Int decode at funding.go is present and the truncating
helper is removed.

### [code:1.8] LOW — funding.go EOF whitespace

Verify the trailing blank line is gone.

## Cross-lane closures touching code-review surface

### [sec:1] CRITICAL — bootstrap-reopen defense

Verify funding.go serveManual now performs an EXISTS check
against payout_attempts.confirmed_at_utc IS NOT NULL inside
the same BEGIN IMMEDIATE as the trigger-presence count. Test
`TestServeRecordFunding_ManualBootstrapReopenDefense_422`
covers the attack-sequence simulation.

### [sec:2] HIGH — strict uint256 decode (see [code:1.7])

### [arch:3.1] MAJOR — ReorgPoller.Start/Stop bool

Verify the new Start/Stop methods on ReorgPoller mirror
Runner.Stop's bool-return contract. Verify main.go shutdown
closure waits on BOTH runner AND poller before Release.

### [arch:3.2] MAJOR — runner-owned stale-outbox producer

Verify `orphans.go` exposes `ProduceStaleOutboxRows` and
`runner.go` RunOnce calls it BEFORE SelectReadyPayouts every
cycle. The orphans.go admin path still has INSERT OR IGNORE
as a fallback.

## Regression sweep

The fix-pass diff is ~870 lines across 10 files. Probe:

1. RunOnce now does a per-cycle DB scan via
   ProduceStaleOutboxRows BEFORE the §4.3 step 1 query. Does
   this affect cycle latency in a way that could violate the
   payout_run_started → payout_run_finished SLO?
2. The new ReorgPoller fields (mu, cancel, done, started,
   stopOnce) are NOT thread-safe IF Start is called from
   multiple goroutines without locking. Verify the mu.Lock
   pattern.
3. The orphan UNIQUE index migration: payout_reorg_orphans
   already has data in production? Migration 0011 must be
   idempotent (CREATE UNIQUE INDEX IF NOT EXISTS).
4. The actor parameter wiring through NewFundingService —
   any path that DOESN'T pass it (e.g. older test) would
   silently emit actor="" — confirm tests pass it OR the
   service tolerates empty Actor without breaking the §7.1
   field set.
5. `tokenPrefix` helper in lease.go — confirm it's not
   exported (lowercase initial) and doesn't conflict with any
   Step 2 helper of the same name.

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_3-code-r2-audit.md`.

## Discipline

CLEAN requires r1 closures VERIFIED + zero new findings.
BLOCK only on new CRITICAL or HIGH.

Wall-clock target: 25-30 min.

=== END PROMPT ===
```

# IMPL audit prompt — SPEC-016 Step 3, **SECURITY REVIEW lane, round 2**

Round 2 against fix-pass commit `6044056` on `impl/spec-016`.
Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_3_PROMPT.md`.

Fire via:

```
omc ask codex --agent-prompt security-reviewer --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the security-reviewer lane (2 of 3) auditing SPEC-016
Step 3 IMPL — round 2.

Round 1 returned BLOCK with 1 CRITICAL, 1 HIGH, 1 MEDIUM. The
fix-pass `6044056` addresses all three. Your r2 job: verify the
closures hold and re-run the adversarial probe matrix on the
fixed code.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_3_PROMPT.md`. HEAD: `6044056`.

## r1 findings to verify CLOSED

### [sec:1] CRITICAL — manual-funding bootstrap reopen

Verify `funding.go` serveManual now:
- Inside the SAME BEGIN IMMEDIATE as the trigger-presence
  count, runs:
  `SELECT EXISTS(SELECT 1 FROM payout_attempts WHERE
  confirmed_at_utc IS NOT NULL LIMIT 1)`
- Rejects 422 `bootstrap_complete` when either:
  - payout_bootstrap_complete != 0, OR
  - confirmedExists != 0 (i.e. ANY confirmed attempt exists)
- Emits payout_invariant_violation where='bootstrap_flag_reopened'
  PAGE on the asymmetric (flag=0 BUT confirmed exists) tamper
  signal.

Probe the closure:
1. Can an attacker bypass by DELETING the confirmed row(s) in
   the same DROP+UPDATE+CREATE sequence? Answer should be: the
   SPEC §4.8a startup sentinel-asymmetry detector would catch
   the missing audit-row signal at next boot, but a runtime
   delete is a SPEC §7.4 reconciliation alarm (not closed
   here). Document the residual risk.
2. The new EXISTS check uses LIMIT 1 — does the index
   payout_attempts(confirmed_at_utc) make this O(1)? Or does
   it scan the table?

### [sec:2] HIGH — uint256 truncation

Verify `funding.go` verifyFundingReceipt now:
- Requires len(lg.Data) == 32 — reject if not.
- Iterates bytes[0..23] — reject if any non-zero.
- Uses big.Int.SetBytes + Cmp against
  big.NewInt(req.AmountBaseUnits).

Probe:
1. Test vectors: amount 2^63-1 (max int64) should accept;
   amount 2^64-1 should reject (req.AmountBaseUnits is int64,
   so this isn't representable as a request anyway — but the
   verifier should still reject if any byte > index 24 is
   non-zero).
2. The constant 24 = 32-8: confirm this matches a uint64 max
   exactly.

### [sec:3] MEDIUM — lease holder_token redaction

Verify `lease.go` Heartbeat lease-lost emit uses:
- `tokenPrefix(state.HolderToken)` for local
- `tokenPrefix(observedToken)` for observed
- New helper `tokenPrefix(s string) string` truncates to 8
  chars.

## Cross-lane closures touching security surface

### [arch:3.1] MAJOR — ReorgPoller lifecycle

The poller now owns its own goroutine. From a security lens,
verify:
1. No goroutine leak on Stop (done channel closes).
2. cancel function is reset on subsequent Start? — note:
   stopOnce guards against double-cancel, but a Start-Stop-
   Start sequence is undefined; verify the IMPL doesn't allow
   this.

### [arch:3.2] MAJOR — runner-owned stale-outbox producer

The runner now has a new write path (ProduceStaleOutboxRows).
Verify:
1. CAS pattern matches §4.8a discipline.
2. The UNIQUE INDEX idx_crso_one_per_stale_period prevents
   double-produce on the (payout_id, attempt_seq,
   stale_started_at_utc) tuple across concurrent runners.
3. No path mutates payout_attempts.cancel_reconfirm_stale_paged_at_utc
   from NULL→non-NULL OUTSIDE of this CAS + the runner-side
   MarkConfirmedAtTx path (which sets it back to NULL).

## High-leverage adversarial probes

### Compromised operator-key holder

1. Bootstrap-reopen attack (sec:1 closure):
   - Sequence: DROP trg_prs_bootstrap_one_way, UPDATE flag=0,
     CREATE trigger, then call POST /admin/payout/record-funding
     with source=manual.
   - r1 fix verifies: rejected via EXISTS.
2. Re-attack: also DELETE the confirmed payout_attempts row
   in the same session. r2 SHOULD document this as a defended-
   in-depth-elsewhere class (SPEC §7.4 reconciliation).
3. Idempotency-key collision: empty header AND empty tx_hash
   — does this pass or fail?
4. Idempotency-key with uppercase tx_hash: case-insensitive
   match should accept.

### Lying-RPC value-overflow

5. Construct a malicious primary RPC that returns a Transfer
   log with Data[24..32] = req.AmountBaseUnits (as uint64) but
   Data[0..24] containing a non-zero byte representing
   2^192 + req.AmountBaseUnits. Old code would accept; new
   code must reject because of the high-bytes check.

### Reorg-orphan tampering

6. Snapshot column immutability still intact — verify no path
   mutates observed_* columns.

### Goroutine + lifecycle

7. Reaper + Runner + ReorgPoller — all three Stop with bool;
   main.go waits on runner+poller before Release.
   Verify a partial timeout (runner clean, poller stuck) does
   NOT Release.

## govulncheck + race tests

- `govulncheck ./...` from phase4-coordinator/.
- `go test -race -count=1 ./internal/payout/...`.

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_3-security-r2-audit.md`.

## Discipline

CLEAN requires r1 closures VERIFIED + zero new CRITICAL/HIGH.
BLOCK only on new CRITICAL or HIGH regression introduced by
the fix-pass.

Wall-clock target: 30 min.

=== END PROMPT ===
```

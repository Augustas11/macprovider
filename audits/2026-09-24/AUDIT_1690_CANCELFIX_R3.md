# #1690 audit: cancel-receipt and loopback zero-bill fixes, round 3 (all three lanes)

**READ-ONLY.** Do NOT run builds, package resolves, or tests on this machine.

**Scope:** `git diff 8b3d6313 HEAD`, cumulative. The earlier briefs are `AUDIT_1690_CANCELFIX.md` and `AUDIT_1690_CANCELFIX_R2.md` in `audits/2026-09-24/`.

**Round-2 fixes in `b5c65b7b`:**
1. **HTTP SSE:** blocks are validated on a separate tracker. Output enters the settlement record only after a successful buyer write, and only as complete events. A cancel or failure bills only the provider usage carried by delivered events. Torn writes, including the first flush after commit and the buffered write, record only complete events.
2. **CRLF:** the event boundary is the last blank line under either `\n` or `\r\n` framing (`completeSSEEventsLen`).
3. **Attestation fence:**
   - The attested decision reads the pool's latest durable event id plus the verified label.
   - The hot path and recovery re-read that fence inside the ledger write transaction, from `trustpool_events` via the transaction handle (`trustpool.Store.PoolEventHighWater(ctx, tx, poolID)`).
   - Positive credit is written only if the fence is unchanged and pools are enabled; otherwise the attempt is 0/0, quarantined.
   - When the fence fails, the settlement evidence is downgraded to byte-estimated, so a receipt cannot verify and debit the buyer while the provider row is zero.

**Check:**
- that the round-2 findings are resolved;
- that no new regressions were introduced, in particular:
  - fence correctness: a durable event id covers every relevant change; the transaction isolation guarantees the in-transaction read sees committed events; no false negatives that block legitimate credit forever;
  - no deadlock;
  - the evidence downgrade cannot be used to debit or credit incorrectly;
  - native billing unchanged;
  - no path bills undelivered output or pays an unverified loopback attempt.

Report only real defects at their true severity. End with `VERDICT: <c> CRITICAL / <h> HIGH / <m> MEDIUM / <l> LOW`.

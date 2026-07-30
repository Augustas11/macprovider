# IMPL audit prompt — SPEC-016 Step 3, **ARCHITECTURE REVIEW lane, round 1**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_3_PROMPT.md`.

Fire via:

```
omc ask codex --agent-prompt architect --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the architect lane (3 of 3) auditing SPEC-016 Step 3
IMPL — round 1.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_3_PROMPT.md`. HEAD: `191e3be`.

## Architecture-review focus

Step 3 is the first time we have THREE active background loops
in `internal/payout`: the Runner (Step 2), the ReorgPoller
(Step 2), and the Reaper (Step 3). The shutdown contract is
the load-bearing piece: who waits for whom, who owns the lease,
who is allowed to crash without compromising data.

### A. Shutdown ordering

1. `payoutS2.stop` calls Runner.Stop FIRST. Verify:
   - Runner.Stop returns bool (Step 2 [arch:3.1-r2] closure).
   - On clean exit, Release is safe.
   - On timeout, lease stales out (3 × run_interval).
2. After Runner.Stop, Reaper.Stop is called. Verify:
   - Reaper.Stop also returns bool but main.go doesn't use it
     (no lease for the reaper).
   - Stop is idempotent + safe-to-call-from-multiple-contexts.
3. ReorgPoller has no Stop wired — it's driven by the outer
   `shutdownCtx`. Verify this doesn't leak when the runner
   stops cleanly but the poller is mid-RPC.

### B. Same-DB pin

1. Step 3 services all consume the shared *sql.DB handle
   passed into setupPayout. Verify NO Step 3 file opens its
   own DB.
2. RuntimeFlagWriter.ListUnemittedOlderThan +
   ListUnemittedStaleOutboxOlderThan use the same *sql.DB.
3. The outbox + the runtime_flags table + the
   cancel_reconfirm_stale_outbox table all live in the same
   SQLite database file as ledger_payout_ready. Step 1
   AssertSameDB covers this.

### C. Module boundary

1. Step 3 services do NOT import `internal/billing`. They
   stay inside the payout package. PayoutClaimer interface
   still lives in payout/ (declared in Step 2).
2. Step 3 services do NOT depend on the runner directly
   (no construction-order cycle).

### D. §3.3 path-table parity

1. step3PathTable embeds step2PathTable via slice
   concatenation. Verify no Step 3 admin route is registered
   without a table entry.
2. The verifyPathTable walker excludes only the
   /providers/* wildcard fallback.
3. The realm column for all 4 new routes is
   RealmOperatorKey.

### E. Step 4 forward-looking

1. Step 4 will introduce the §6.5 dual-namespace config
   loader split. Verify Step 3 services accept their config
   knobs via constructor params (not global) so a future
   SIGHUP-on-tuning reload can reconstruct ONLY the affected
   services.
2. The reaper's TickEvery + StaleAge are passed in;
   PauseResumeService.MinInterval is passed in. Verify these
   are NOT captured from a process-global at construction
   time.
3. PayoutTuningProvider (Step 4 abstraction) doesn't exist
   yet; Runner+Reaper.Stop bool return is the primitive
   Step 4 builds on. Verify the bool return is exported in
   both signatures.

### F. Observability events vs §7.1 table

1. Step 3 emits these event names — verify each appears in
   the §7.1 field-set requirements:
   - payout_registration_paused / _resumed (PAGE)
   - payout_flag_audit_reaped (WARN)
   - payout_funding_recorded (INFO)
   - payout_funding_receipt_mismatch (WARN)
   - payout_reorg_orphan_recorded (PAGE)
   - payout_reorg_orphan_resolved (INFO)
   - payout_cancel_self_transfer_reconfirm_stale (PAGE)
   - payout_stale_outbox_reaped (WARN)
   - payout_invariant_violation where=bootstrap_trigger_missing (PAGE)
2. Every emit includes event_id where applicable (audit row
   id or outbox row id) so downstream consumers can dedupe.

## Step 3 → Step 4 readiness matrix

| Row | Step 4 dependency |
|-----|-------------------|
| §6.5 config-loader split | needs Runner.Stop+Reaper.Stop bool primitives (Step 3 has both) |
| §7.4 reconciliation queries | needs payout_hot_wallet_funding table (Step 1 schema; Step 3 inserts) |
| §7.4 chain-balance worker | needs both RPCs (Step 2 setupPayout exposes via TwoRPCs) |
| §6.2 balance monitoring | needs Step 4 worker; Step 3 emits via funding records only |
| Ops bundle | needs systemd unit + journalctl alert filter; not in Step 3 scope |

## Output

Write findings to `specs/SPEC-016-IMPL-STEP_3-arch-r1-audit.md`.

## Discipline

- Wall-clock target: 25 min.

=== END PROMPT ===
```

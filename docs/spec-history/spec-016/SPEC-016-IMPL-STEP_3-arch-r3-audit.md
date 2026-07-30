## Summary
Verdict: **CLEAN for Step 3 -> Step 4 readiness, with Step 4 advisories**. The r2 closures are verified: two-RPC stale verification is enforced, admin-side stale outbox insertion is removed, and stale PAGE/reaper fields now include `run_id` and `updated_at_utc`.

## Analysis
- `[arch:r2-3.2-A] CLOSED`: `ProduceStaleOutboxRows` accepts `TwoRPCs` + `runID`, checks both RPC receipts per candidate, skips on RPC error or any receipt, and only CAS+INSERTs after both return nil.
- `[arch:r2-3.2-B] CLOSED`: `/admin/payout/record-orphan` still records orphan snapshot columns, but no longer inserts into `cancel_reconfirm_stale_outbox`; runner is the single producer.
- `[arch:r2-3.3] CLOSED`: migration `0012` adds nullable `run_id`; list/claim helpers read it; sync and reaper emits include `run_id` and `updated_at_utc`.

Step 4 advisories: add a stale-producer per-cycle cap, add explicit telemetry for chronic RPC-error skips, and implement payout tuning reload as lifecycle-aware runner/reaper/poller replacement rather than a simple field assignment.

## Root Cause
The r2 defects came from stale cancel observability being split across paths with different predicates and incomplete event state. The fix-pass centralizes stale outbox production in the runner, adds the two-RPC not-found gate, and persists `run_id` for recovery emits.

## Recommendations
1. **Proceed to Step 4** - low effort - high impact.
2. **Add stale-producer cap** - medium effort - protects SLO/RPC budget.
3. **Define chronic RPC-error telemetry** - medium effort - avoids silent stuck-cancel ambiguity.
4. **Implement lifecycle-aware payout tuning reload** - high effort - keeps cadence, lease windows, and stale thresholds coherent.

## Trade-offs
| Option | Pros | Cons |
|---|---|---|
| Runner-only producer | Single predicate, no duplicate PAGEs | Manual orphan record alone does not LIVE-AGAIN a still-confirmed cancel |
| Add producer cap | Predictable cycle latency | Backlogs may page over multiple cycles |
| Stop/rebuild on tuning reload | Coherent timers and thresholds | More lifecycle complexity |

## References
- `phase4-coordinator/internal/payout/orphans.go:386` - producer signature.
- `phase4-coordinator/internal/payout/orphans.go:447` - both RPC receipt checks.
- `phase4-coordinator/internal/payout/orphans.go:507` - outbox insert with `run_id`.
- `phase4-coordinator/internal/payout/runner.go:234` - runner passes RPCs/runID/interval.
- `phase4-coordinator/internal/payout/reaper.go:193` - reaper emits `run_id`.
- `phase4-coordinator/internal/payout/migrations/0012_stale_outbox_run_id.sql:12` - nullable `run_id`.

Verification passed:
- `go test -count=1 ./internal/payout`
- `go test -count=1 ./cmd/coordinator`
diff --git a/specs/SPEC-016-IMPL-STEP_3-arch-r3-audit.md b/specs/SPEC-016-IMPL-STEP_3-arch-r3-audit.md
new file mode 100644
index 0000000000000000000000000000000000000000..e9db3cf0f35c20a5e6dc29a5baa3589a8475b895
--- /dev/null
+++ b/specs/SPEC-016-IMPL-STEP_3-arch-r3-audit.md
@@ -0,0 +1,88 @@
+## Summary
+Verdict: **CLEAN for Step 3 -> Step 4 readiness, with Step 4 advisories**. The three r2 findings are verified closed at the fix-pass implementation: stale production now enforces the two-RPC not-found predicate, the admin orphan path no longer directly writes the stale outbox, and the stale PAGE/reaper field set now carries `run_id` plus `updated_at_utc`.
+
+The implementation under audit is effectively `9bbec55`: the current branch HEAD is `8ded65d`, and `9bbec55..HEAD` changes only the r3 prompt files. No named SPEC rule appears blocked in a way Step 4 cannot unwind.
+
+## Analysis
+**[arch:r2-3.2-A] CLOSED - two-RPC verification in `ProduceStaleOutboxRows`.**
+
+The producer signature now accepts both `TwoRPCs` and `runID` at `phase4-coordinator/internal/payout/orphans.go:386`. The zero-value `TwoRPCs` branch returns `(0, nil)` and is explicitly documented as a test-path disable at `phase4-coordinator/internal/payout/orphans.go:391`. Candidate selection still uses the stale DB predicate, including cancel-self-transfer, signed and broadcast, unconfirmed, not abandoned, marker NULL, and `updated_at_utc < cutoff` at `phase4-coordinator/internal/payout/orphans.go:397`.
+
+Inside the candidate loop, the implementation calls both `Primary.TransactionReceipt` and `Secondary.TransactionReceipt` with the candidate `tx_hash` at `phase4-coordinator/internal/payout/orphans.go:447`. Either RPC error skips the candidate without paging at `phase4-coordinator/internal/payout/orphans.go:449`; either non-nil receipt also skips at `phase4-coordinator/internal/payout/orphans.go:455`. Only after both return nil receipt and nil error does execution reach the `BEGIN IMMEDIATE`, marker CAS, and outbox insert path at `phase4-coordinator/internal/payout/orphans.go:460`, `phase4-coordinator/internal/payout/orphans.go:476`, and `phase4-coordinator/internal/payout/orphans.go:507`.
+
+`RunOnce` passes `r.opts.RPCs` and `runID` to the producer before ready selection at `phase4-coordinator/internal/payout/runner.go:234`. This matches the SPEC rule that stale escalation requires both RPCs to return not found for longer than `3 x run_interval` at `specs/SPEC-016-payout-pipeline.md:1998` and `specs/SPEC-016-payout-pipeline.md:2033`. Regression coverage locks the positive, receipt-present negative, and no-RPC test disable paths at `phase4-coordinator/internal/payout/step3_r2_test.go:39`, `phase4-coordinator/internal/payout/step3_r2_test.go:86`, and `phase4-coordinator/internal/payout/step3_r2_test.go:124`.
+
+**[arch:r2-3.2-B] CLOSED - admin-side stale outbox INSERT removed.**
+
+`serveRecord` still captures the immutable `observed_*` columns by joining `ledger_payout_ready` and `payout_attempts` at `phase4-coordinator/internal/payout/orphans.go:164`, then inserts the orphan row with those snapshot values at `phase4-coordinator/internal/payout/orphans.go:196`. The former admin-side `INSERT OR IGNORE` into `cancel_reconfirm_stale_outbox` is gone; the replacement comment explains that the runner-owned producer is canonical and that the removed path lacked the runner CAS plus two-RPC verification at `phase4-coordinator/internal/payout/orphans.go:223`. The cancel carve-out still avoids any `ledger_payout_ready` revert, explicitly documented at `phase4-coordinator/internal/payout/orphans.go:242`.
+
+The normal operational chain holds when the orphan is first observed by the reorg poller: the cancel LIVE-AGAIN update clears `confirmed_at_utc`, `block_number`, `gas_used_native_wei`, and `cancel_reconfirm_stale_paged_at_utc`, and writes `updated_at_utc` at `phase4-coordinator/internal/payout/reorg.go:216`. The next runner cycle's producer selects that live cancel via the predicate at `phase4-coordinator/internal/payout/orphans.go:397`, checks both RPCs at `phase4-coordinator/internal/payout/orphans.go:447`, and emits through `ClaimAndEmitStaleOutbox` at `phase4-coordinator/internal/payout/orphans.go:539`.
+
+Deferred Step 4 note: if an operator manually records a cancel orphan before the reorg poller has run, `serveRecord` records the orphan but does not perform the LIVE-AGAIN update at `phase4-coordinator/internal/payout/orphans.go:196`. A still-confirmed cancel will not be selected by the producer because the producer requires `confirmed_at_utc IS NULL` at `phase4-coordinator/internal/payout/orphans.go:403`. That is not a regression from removing the direct admin outbox insert; it is a runbook/Step 4 reconciliation concern for manually discovered out-of-window cancel reorgs.
+
+**[arch:r2-3.3] CLOSED - stale PAGE field set.**
+
+Migration `0012_stale_outbox_run_id.sql` adds nullable `run_id` to `cancel_reconfirm_stale_outbox` at `phase4-coordinator/internal/payout/migrations/0012_stale_outbox_run_id.sql:12`. `ListUnemittedStaleOutboxOlderThan` reads `COALESCE(run_id, '')` at `phase4-coordinator/internal/payout/orphans.go:571`, and `ClaimAndEmitStaleOutbox` does the same at `phase4-coordinator/internal/payout/orphans.go:656`. `StaleOutboxRow` now includes `RunID` at `phase4-coordinator/internal/payout/orphans.go:603`.
+
+The sync producer emits `run_id` and `updated_at_utc` on `payout_cancel_self_transfer_reconfirm_stale` at `phase4-coordinator/internal/payout/orphans.go:544` and `phase4-coordinator/internal/payout/orphans.go:555`. The reaper emits the same two fields at `phase4-coordinator/internal/payout/reaper.go:193` and `phase4-coordinator/internal/payout/reaper.go:204`.
+
+**Step 3 -> Step 4 readiness matrix**
+
+| Row | r3 verdict |
+|---|---|
+| §6.5 config-loader split | **Partial, no regression.** Security and tuning structs/bounds exist at `phase4-coordinator/internal/config/config.go:56`, `phase4-coordinator/internal/config/config.go:137`, and `phase4-coordinator/internal/config/config.go:997`; current SIGHUP reload is Tier2-only at `phase4-coordinator/cmd/coordinator/main.go:382`, so Step 4 still needs payout-aware reload/replacement semantics. |
+| §7.4 reconciliation queries | **Ready for Step 4.** Funding input exists at `phase4-coordinator/internal/payout/migrations/0006_payout_hot_wallet_funding.sql:3`; payout outflow columns and cancel exclusion key exist at `phase4-coordinator/internal/payout/migrations/0002_payout_attempts.sql:10`; the checked-in `reconcile.sql` itself remains Step 4 scope per `specs/SPEC-016-payout-pipeline.md:3847`. |
+| §7.4 chain-balance worker | **Ready for Step 4.** The code already builds separated `TwoRPCs` clients at `phase4-coordinator/cmd/coordinator/main.go:680`, and config has `chain_recon_interval` plus tolerance at `phase4-coordinator/internal/config/config.go:104`; the actual balance worker remains Step 4. |
+| §6.2 balance monitoring | **No regression.** Step 3 records funding rows and event fields at `phase4-coordinator/internal/payout/funding.go:466` and `phase4-coordinator/internal/payout/funding.go:482`; live low-balance checks remain Step 4. |
+| Ops bundle | **Not Step 3 scope.** No Step 3 implementation change blocks it. |
+
+**Forward-looking probes**
+
+1. **Per-cycle stale producer cardinality:** `ProduceStaleOutboxRows` has no `LIMIT`; it loads all candidates ordered by `updated_at_utc` at `phase4-coordinator/internal/payout/orphans.go:397`, then performs two RPC calls per candidate at `phase4-coordinator/internal/payout/orphans.go:447`. Step 4 should add a bounded per-cycle cap if stale cancel rows can exceed low double digits; `MaxRowsPerRun` already caps ready payout selection at `phase4-coordinator/internal/payout/runner.go:249`, but it does not cap stale production.
+2. **RPC-error skipping:** the producer correctly skips on RPC error because an RPC error is not a not-found signal at `phase4-coordinator/internal/payout/orphans.go:449`. However, the reaper only emits already-created outbox rows via `ListUnemittedStaleOutboxOlderThan` at `phase4-coordinator/internal/payout/reaper.go:175`; it cannot create a missing outbox row after the producer skipped before CAS+INSERT. This is not a SPEC violation because the stale PAGE requires both RPCs to return not-found, but Step 4 should add explicit RPC-health/stuck-cancel telemetry if chronic single-RPC outage needs a separate operator signal.
+3. **SIGHUP `run_interval` semantics:** the producer reads `runInterval` per call at `phase4-coordinator/internal/payout/runner.go:234`, so a future mutable runner option would update the stale threshold. But the runner, reorg poller, and reaper also create tickers or stale ages from construction-time values at `phase4-coordinator/internal/payout/runner.go:155`, `phase4-coordinator/internal/payout/reorg.go:295`, and `phase4-coordinator/cmd/coordinator/main.go:809`. Step 4 can implement this, but it is a controlled stop/rebuild or shared atomic config refactor, not just a SIGHUP assignment to one field.
+
+## Root Cause
+The r2 defects came from splitting stale cancel observability across paths that did not share the same full predicate and event shape: the runner producer had durable CAS/outbox mechanics but lacked chain-state confirmation, the admin endpoint could write the same outbox without that predicate, and the outbox schema could not carry the full event fields for reaper recovery.

---

_Persisted from codex artifact codex-impl-audit-prompt-spec-016-step-3-architecture-review-lane-r-2026-06-25T18-00-04-963Z.md._

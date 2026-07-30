## Summary
Verdict: **FIX-THEN-PROCEED**. I found no CRITICAL/blocking issue, but there are two MAJOR lifecycle/producer issues and one MEDIUM §7.1 observability parity issue.

| Severity | Count |
|---|---:|
| CRITICAL | 0 |
| MAJOR | 2 |
| MEDIUM | 1 |
| LOW | 0 |

## Analysis
**[arch:3.1] MAJOR - ReorgPoller can outlive shutdown and lease release.**  
`startPayoutReorgPoller` receives `shutdownCtx`, but each poll cycle calls `poller.Run(context.Background())`, including the startup pass and ticker pass. `ReorgPoller.Run` passes its `ctx` into DB queries and RPC receipt calls, so using `context.Background()` prevents shutdown cancellation from interrupting a mid-RPC poll. Meanwhile `payoutS2.stop` stops runner, stops reaper, and releases the runner lease on clean runner exit without waiting for the poller. A poller still inside `handleCancelReorg` can continue DB mutation while the lease has already been released.

Evidence: `phase4-coordinator/cmd/coordinator/main.go:997`, `phase4-coordinator/cmd/coordinator/main.go:1006`, `phase4-coordinator/cmd/coordinator/main.go:1014`, `phase4-coordinator/cmd/coordinator/main.go:856`, `phase4-coordinator/cmd/coordinator/main.go:864`, `phase4-coordinator/cmd/coordinator/main.go:868`, `phase4-coordinator/cmd/coordinator/main.go:870`, `phase4-coordinator/internal/payout/reorg.go:72`, `phase4-coordinator/internal/payout/reorg.go:97`, `phase4-coordinator/internal/payout/reorg.go:188`.

**[arch:3.2] MAJOR - §4.8c stale-outbox producer is attached to the admin orphan path, not the runner stale-transition CAS.**  
The only production insert into `cancel_reconfirm_stale_outbox` is in `OrphansService.serveRecord`. The runner never sets `cancel_reconfirm_stale_paged_at_utc` from NULL to now, never inserts the outbox row on the stale threshold, and never performs the required synchronous post-commit CAS emit. This leaves the reaper correctly able to consume rows, but no runner-owned producer creates the rows for the actual cancel-reconfirm-stale transition.

Evidence: `phase4-coordinator/internal/payout/orphans.go:223`, `phase4-coordinator/internal/payout/orphans.go:225`, `phase4-coordinator/internal/payout/reaper.go:176`, `phase4-coordinator/internal/payout/reaper.go:187`, `phase4-coordinator/internal/payout/reorg.go:203`, `phase4-coordinator/internal/payout/reorg.go:208`, `phase4-coordinator/internal/payout/attempts.go:351`, `phase4-coordinator/internal/payout/attempts.go:357`, `specs/SPEC-016-payout-pipeline.md:2033`, `specs/SPEC-016-payout-pipeline.md:2059`, `specs/SPEC-016-payout-pipeline.md:2083`.

**[arch:3.3] MEDIUM - Step 3 observability events drift from §7.1 field sets.**  
Several events exist but do not emit the §7.1 fields. Examples: `payout_flag_audit_reaped` omits `flag_audit_id`, `old_value`, `occurred_at_utc`, `reap_lag_seconds`, and `ts_utc`; `payout_stale_outbox_reaped` emits only an aggregate count and omits per-row `event_id`, `payout_id`, `attempt_seq`, `stale_started_at_utc`, `reap_lag_seconds`, `ts_utc`; `payout_cancel_self_transfer_reconfirm_stale` omits `run_id`, `updated_at_utc`, `ts_utc`; `payout_funding_recorded` omits `operator_note` and `actor`; `payout_funding_receipt_mismatch` and `payout_reorg_orphan_resolved` are emitted but do not appear in the visible §7.1 table.

Evidence: `phase4-coordinator/internal/payout/pauseresume.go:227`, `phase4-coordinator/internal/payout/reaper.go:166`, `phase4-coordinator/internal/payout/reaper.go:188`, `phase4-coordinator/internal/payout/funding.go:443`, `phase4-coordinator/internal/payout/funding.go:276`, `phase4-coordinator/internal/payout/orphans.go:315`, `specs/SPEC-016-payout-pipeline.md:3736`, `specs/SPEC-016-payout-pipeline.md:3738`, `specs/SPEC-016-payout-pipeline.md:3748`, `specs/SPEC-016-payout-pipeline.md:3752`, `specs/SPEC-016-payout-pipeline.md:3753`.

## Root Cause
The architecture split Step 3 into three loops but only gave two of them explicit shutdown ownership, and §4.8c’s durable outbox consumer was implemented without the runner-owned stale-transition producer that the SPEC makes load-bearing. Observability then drifted because emitted log shapes were implemented locally per service instead of being checked against one §7.1 event contract.

## Recommendations
1. **Own ReorgPoller lifecycle in `payoutStep2.stop` - medium effort - high impact.** Add a stop/wait primitive or goroutine `done` channel for the poller, call `poller.Run(ctx)` with the shutdown context, and do not release the runner lease until runner and poller have drained or the timeout path intentionally leaves the lease to stale.

2. **Move §4.8c stale-transition production into runner cancel handling - medium/high effort - high impact.** On stale threshold crossing, perform the SPEC CAS on `payout_attempts.cancel_reconfirm_stale_paged_at_utc`, insert `cancel_reconfirm_stale_outbox` in the same `BEGIN IMMEDIATE`, commit, then CAS-claim and emit from the committed outbox row.

3. **Centralize §7.1 event field definitions - low/medium effort - medium impact.** Add focused tests around the Step 3 event payloads and align emitted fields with §7.1, or update the SPEC table if the new event names/fields are intentional.

## Trade-offs
| Option | Pros | Cons |
|---|---|---|
| Add full Stop/Wait to ReorgPoller | Preserves lease ownership and clean shutdown semantics | More lifecycle state and tests |
| Only pass `shutdownCtx` into `Run` | Small fix; interrupts DB/RPC calls | Still does not prove poller drained before lease release |
| Move §4.8c producer into runner | Matches SPEC and closes silent stranded-cancel gap | Touches money-path runner logic |
| Keep producer in admin orphan path | Minimal code churn | Does not cover autonomous stale cancel transitions |

## References
- `phase4-coordinator/cmd/coordinator/main.go:997` - ReorgPoller loop accepts shutdown context.
- `phase4-coordinator/cmd/coordinator/main.go:1006` - Startup poll uses `context.Background()`.
- `phase4-coordinator/cmd/coordinator/main.go:1014` - Ticker poll uses `context.Background()`.
- `phase4-coordinator/cmd/coordinator/main.go:856` - Stop closure owns runner/reaper release ordering.
- `phase4-coordinator/internal/payout/orphans.go:225` - Only non-test outbox insert path found.
- `phase4-coordinator/internal/payout/reaper.go:187` - Reaper consumes existing outbox rows.
- `specs/SPEC-016-payout-pipeline.md:2033` - SPEC requires stale-marker CAS.
- `specs/SPEC-016-payout-pipeline.md:2059` - SPEC requires outbox insert in same txn.
- `specs/SPEC-016-payout-pipeline.md:3748` - §7.1 field set for `payout_flag_audit_reaped`.
- `specs/SPEC-016-payout-pipeline.md:3752` - §7.1 field set for cancel stale PAGE.



---

_Persisted from codex artifact codex-impl-audit-prompt-spec-016-step-3-architecture-review-lane-r-2026-06-25T17-25-39-788Z.md._

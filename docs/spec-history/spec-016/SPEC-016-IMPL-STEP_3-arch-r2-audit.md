## Summary
Verdict: **FIX-THEN-PROCEED, not CLEAN**. `[arch:3.1]` is closed, but `[arch:3.2]` is only partially closed: the new producer has the DB CAS/outbox shape, but it does not verify the SPEC-required “both RPCs still not found” condition before paging. `[arch:3.3]` also still has field-set drift for the stale PAGE event.

Read-only note: I did not write `specs/SPEC-016-IMPL-STEP_3-arch-r2-audit.md` because the supplied shared context says all lanes are read-only and must not modify files.

## Analysis
**[arch:3.1] CLOSED - ReorgPoller lifecycle ownership is now correct.**  
`ReorgPoller` owns `Start(ctx)` / `Stop(ctx) bool` state with `sync.Mutex`, `started`, `cancel`, `done`, and `sync.Once` fields at `phase4-coordinator/internal/payout/reorg.go:57`. `Start` creates `innerCtx`, stores `cancel`, creates `done`, marks `started=true`, and every `Run` call receives `innerCtx` at `phase4-coordinator/internal/payout/reorg.go:287` and `phase4-coordinator/internal/payout/reorg.go:300`. Main starts runner, poller, reaper in that order at `phase4-coordinator/cmd/coordinator/main.go:342`, `phase4-coordinator/cmd/coordinator/main.go:347`, and `phase4-coordinator/cmd/coordinator/main.go:350`. Shutdown stops runner, then poller, then reaper, and releases only when `runnerClean && pollerClean` at `phase4-coordinator/cmd/coordinator/main.go:873` and `phase4-coordinator/cmd/coordinator/main.go:880`. Timeout WARN includes both bools at `phase4-coordinator/cmd/coordinator/main.go:883`.

Probe result: production wiring calls `reorg.Start(shutdownCtx)` once per instance at `phase4-coordinator/cmd/coordinator/main.go:347`. The reusable-after-Stop contract is implicit, not explicit: `Start` is idempotent while started, but `Stop` does not reset `started` and `stopOnce` prevents restart on the same instance at `phase4-coordinator/internal/payout/reorg.go:327`. That is acceptable for Step 3, but Step 4 should create fresh lifecycle instances when restart is needed.

**[arch:3.2] MAJOR - stale producer omits SPEC-required RPC not-found verification.**  
`ProduceStaleOutboxRows` selects stale cancel rows using only DB state: cancel row, signed/broadcast, unconfirmed, marker NULL, not abandoned, `updated_at_utc < cutoff` at `phase4-coordinator/internal/payout/orphans.go:370`. But SPEC §4.7 requires the stale PAGE only if the cancel remains broadcast-unconfirmed **and BOTH RPCs return not found** for longer than `3 * run_interval` at `specs/SPEC-016-payout-pipeline.md:1998` and `specs/SPEC-016-payout-pipeline.md:2033`. The producer signature has no `TwoRPCs`, so it cannot prove that condition at `phase4-coordinator/internal/payout/orphans.go:365`. Because `RunOnce` calls this producer before `SelectReadyPayouts` and before `pollCancelOnce`, a cancel that would reconfirm during the normal cancel poll can be paged first at `phase4-coordinator/internal/payout/runner.go:228` and `phase4-coordinator/internal/payout/runner.go:246`; the actual two-RPC cancel poll is later at `phase4-coordinator/internal/payout/runner.go:469`.

The CAS/outbox part is otherwise present: per-row `BEGIN IMMEDIATE` at `phase4-coordinator/internal/payout/orphans.go:418`, marker CAS at `phase4-coordinator/internal/payout/orphans.go:426`, outbox insert in the same txn at `phase4-coordinator/internal/payout/orphans.go:459`, post-commit claim/emit at `phase4-coordinator/internal/payout/orphans.go:491`, and unique index at `phase4-coordinator/internal/payout/migrations/0008_cancel_reconfirm_stale_outbox.sql:18`.

**[arch:3.2 cross-check] MAJOR - admin-side INSERT OR IGNORE is not acceptable as implemented.**  
The admin orphan path still inserts `cancel_reconfirm_stale_outbox` directly at `phase4-coordinator/internal/payout/orphans.go:231`, but it does not CAS `payout_attempts.cancel_reconfirm_stale_paged_at_utc`, does not share the runner producer’s `stale_started_at_utc`, and does not sync-claim/emit. The unique index is only `(payout_id, attempt_seq, stale_started_at_utc)` at `phase4-coordinator/internal/payout/migrations/0008_cancel_reconfirm_stale_outbox.sql:18`, so admin and runner inserts with different timestamps can both exist for the same stale period. The belt-and-suspenders idea is acceptable only if the admin path delegates to the same CAS/outbox primitive or uses a canonical stale-period key.

**[arch:3.3] MEDIUM - stale PAGE field-set still drifts from §7.1.**  
`payout_flag_audit_reaped` now matches §7.1 at `phase4-coordinator/internal/payout/pauseresume.go:237`. `payout_stale_outbox_reaped` now matches §7.1 at `phase4-coordinator/internal/payout/reaper.go:212`. `payout_funding_recorded` includes `operator_note` and `actor` at `phase4-coordinator/internal/payout/funding.go:483`. But `payout_cancel_self_transfer_reconfirm_stale` still omits `run_id`; the sync producer also omits `updated_at_utc` at `phase4-coordinator/internal/payout/orphans.go:491`, while §7.1 requires `event_id, run_id, payout_id, attempt_seq, nonce, tx_hash, last_seen_block, updated_at_utc, ts_utc` at `specs/SPEC-016-payout-pipeline.md:3752`.

Step 3 -> Step 4 readiness:
| Row | r2 verdict |
|---|---|
| §6.5 config-loader split | **Partial**: Stop bool primitives exist; Step 4 must rebuild runner/reaper instances, not restart same instances. |
| §7.4 reconciliation queries | **Ready**: funding table exists at `phase4-coordinator/internal/payout/migrations/0006_payout_hot_wallet_funding.sql:3`. |
| §7.4 chain-balance worker | **Ready**: `TwoRPCs` is wired in setup at `phase4-coordinator/cmd/coordinator/main.go:680`. |
| §6.2 balance monitoring | **No regression**: Step 3 records funding; monitoring remains Step 4. |
| Ops bundle | **Not Step 3 scope**. |

Forward probes:
1. Reaper config swap is feasible by `Stop` plus `NewReaper`, not by restarting the same instance, because `Stop` uses `stopOnce` and closed `done` at `phase4-coordinator/internal/payout/reaper.go:137`.
2. `ProduceStaleOutboxRows` processes all candidates; there is no `LIMIT` at `phase4-coordinator/internal/payout/orphans.go:370`.
3. Current SIGHUP handles only Tier2 reload at `phase4-coordinator/cmd/coordinator/main.go:382`; Step 4 needs payout-specific runner replacement semantics.

## Root Cause
The fix-pass added lifecycle ownership and a durable outbox producer, but the stale-transition producer was made DB-only. That lost the SPEC’s chain-state predicate: stale escalation is supposed to be a DB threshold plus two-RPC not-found confirmation, not just elapsed DB time.

## Recommendations
1. **Fix stale producer RPC predicate - medium effort - high impact.** Pass `TwoRPCs` into `ProduceStaleOutboxRows` or move production after `pollCancelOnce`; emit only after both RPCs return nil receipt without RPC error.
2. **Unify admin and runner outbox production - medium effort - high impact.** Remove direct admin insert or route it through the same CAS/outbox helper with a canonical stale-period key.
3. **Align stale PAGE fields - low effort - medium impact.** Add `run_id` and `updated_at_utc` to sync emission, and decide/specify what `run_id` means for reaper emission.

## Trade-offs
| Option | Pros | Cons |
|---|---|---|
| Producer checks RPC before CAS | Matches SPEC and avoids false PAGE | Adds RPC calls before DB write |
| Producer stays DB-only | Simple and deterministic | Pages cancels that may already be reconfirmable |
| Keep admin insert via shared helper | Preserves operator recovery path | More coupling to runner stale logic |
| Remove admin insert | Single producer, less drift | Manual orphan path loses belt-and-suspenders coverage |

## References
- `phase4-coordinator/internal/payout/reorg.go:281` - ReorgPoller `Start(ctx)`.
- `phase4-coordinator/internal/payout/reorg.go:320` - ReorgPoller `Stop(ctx) bool`.
- `phase4-coordinator/cmd/coordinator/main.go:873` - shutdown order and clean bools.
- `phase4-coordinator/internal/payout/orphans.go:365` - stale producer signature lacks RPCs.
- `phase4-coordinator/internal/payout/orphans.go:370` - DB-only stale SELECT.
- `phase4-coordinator/internal/payout/runner.go:228` - producer runs before ready selection/cancel poll.
- `phase4-coordinator/internal/payout/runner.go:469` - actual cancel two-RPC poll.
- `specs/SPEC-016-payout-pipeline.md:1998` - SPEC requires both RPCs not found before stale PAGE.
- `specs/SPEC-016-payout-pipeline.md:3752` - §7.1 stale PAGE field set.

Verification run: `go test -count=1 ./internal/payout` and `go test -count=1 ./cmd/coordinator` both passed.

---

_Persisted from codex artifact codex-impl-audit-prompt-spec-016-step-3-architecture-review-lane-r-2026-06-25T17-46-48-049Z.md._

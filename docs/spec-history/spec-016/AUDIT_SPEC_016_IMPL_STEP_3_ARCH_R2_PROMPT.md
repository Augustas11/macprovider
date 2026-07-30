# IMPL audit prompt — SPEC-016 Step 3, **ARCHITECTURE REVIEW lane, round 2**

Round 2 against fix-pass commit `6044056` on `impl/spec-016`.
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
IMPL — round 2.

Round 1 returned FIX-THEN-PROCEED with 2 MAJOR + 1 MEDIUM. The
fix-pass `6044056` addresses all three. Your r2 job: verify the
shutdown ordering + outbox producer architecture is correct AND
re-confirm Step 3 → Step 4 readiness.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_3_PROMPT.md`. HEAD: `6044056`.

## r1 findings to verify CLOSED

### [arch:3.1] MAJOR — ReorgPoller lifecycle ownership

Verify:
- `internal/payout/reorg.go` now exposes Start(ctx) and
  Stop(ctx) bool.
- Start uses a sync.Mutex + sync.Once for idempotency.
- The poller's inner goroutine threads `innerCtx` (derived
  from outer ctx via context.WithCancel) into every
  poller.Run call — eliminating the round-1
  context.Background() pattern.
- main.go shutdown closure: `runnerClean := runner.Stop(ctx)`
  then `pollerClean := reorgPoller.Stop(ctx)` then
  `_ = reaper.Stop(ctx)`. Lease release happens ONLY when
  `runnerClean && pollerClean` is true.
- On timeout: emits `payout_runner_lease_left_to_stale_out`
  WARN with both bool fields so operators see WHICH component
  was slow.

Probe: what happens if Start is called from a goroutine that
panics before reaching `started = true`? The mutex would still
unlock via defer but `done` channel would never be created.
Verify the Start path can be called only ONCE per *ReorgPoller
instance (i.e. document the contract).

### [arch:3.2] MAJOR — runner-owned stale-outbox producer

Verify the new `ProduceStaleOutboxRows(ctx, db, log, now,
runInterval)` function in `orphans.go`:
- SELECTs cancel rows with the exact predicate set the SPEC
  §4.7/§4.8c describes.
- Per-row BEGIN IMMEDIATE: CAS the marker NULL→now AND INSERT
  outbox row in same txn.
- Post-commit sync CAS-claim emit via ClaimAndEmitStaleOutbox.
- Idempotent on the partial UNIQUE INDEX
  idx_crso_one_per_stale_period.

Verify `runner.go` RunOnce now calls
ProduceStaleOutboxRows BEFORE SelectReadyPayouts every cycle.

Cross-architect check: does the orphans.go admin-side INSERT
OR IGNORE still belong? Argument for: belt-and-suspenders if
operator manually records an orphan that hasn't yet been
runner-caught. Argument against: drift potential — two
producers for the same outbox table. r2 should declare
acceptable or not.

### [arch:3.3] MEDIUM — §7.1 field-set drift

Verify the now-emitted field sets for:
- payout_flag_audit_reaped (in pauseresume.go)
- payout_cancel_self_transfer_reconfirm_stale (in reaper.go)
- payout_stale_outbox_reaped (in reaper.go)
- payout_funding_recorded (in funding.go)
match the SPEC §7.1 event table. Spot-check against
`specs/SPEC-016-payout-pipeline.md` §7.1.

## Step 3 → Step 4 readiness matrix

| Row | r1 verdict | r2 verdict |
|-----|------------|------------|
| §6.5 config-loader split | needs Runner+Reorg+Reaper.Stop bool primitives — all three have it now | ? |
| §7.4 reconciliation queries | needs payout_hot_wallet_funding rows | ? |
| §7.4 chain-balance worker | needs TwoRPCs | ? |
| §6.2 balance monitoring | Step 3 emits funding records only | ? |
| Ops bundle (systemd + journalctl) | not in Step 3 scope | ? |

## Forward-looking probes for Step 4

1. The Reaper accepts TickEvery + StaleAge via constructor.
   Step 4 SIGHUP will need to swap these atomically. Verify
   the constructor pattern would allow reaper Stop + new
   reaper Start with new values.
2. The new ProduceStaleOutboxRows in the runner cycle: Step
   4 will likely want to bound its work per cycle. Currently
   it processes ALL stale rows. Comment-only.
3. The runner+poller+reaper composite shutdown ordering: how
   does Step 4 SIGHUP integrate? It needs to Stop+Restart the
   runner only, leaving the poller + reaper untouched.

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_3-arch-r2-audit.md`.

## Discipline

CLEAN requires r1 closures VERIFIED + Step 3 → Step 4 matrix
shows no regressions.

BLOCK only on named SPEC rule a future step cannot unwind.

Wall-clock target: 25 min.

=== END PROMPT ===
```

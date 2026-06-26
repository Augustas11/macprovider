# IMPL audit prompt — SPEC-016 FULL implementation, **CODE REVIEW lane, r1**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_FULL_PROMPT_r1.md`.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

Read-only. Codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are the code-reviewer lane (1 of 3) auditing the FULL SPEC-016
implementation — round 1.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_FULL_PROMPT_r1.md`. HEAD: `47e4f24`.
This is the holistic audit of Step 1+2+3+4 together. Each Step has
already converged in its own loop; this round catches what only
appears when the steps are read TOGETHER.

## Code-review checklist (cross-step)

### A. Money-path end-to-end trace

Walk a single successful payout from register → confirmed → claimed:

1. `POST /providers/{provider_id}/payout-address` arrives. Step 1
   `addresses.go::ServePayoutAddress` enforces §3.2 EIP-712 +
   §3.3 cooling-off + pre-auth pause + §3.4 audit. Verify no
   path skips the EIP-712 recover + nonce-canonicalization + ±5m
   skew + pruning of 10m-old replay nonces.
2. `ledger_payout_ready` row appears (billing-side, out of scope
   for this audit). Step 2 runner `SelectReadyPayouts` joins on
   `registered_against_hot_wallet = current hot wallet`. Verify
   the join's hot-wallet predicate prevents stale-hot-wallet
   row leak. Cross-check: address was registered against hot
   wallet A; current hot wallet is B; row must NOT select.
3. Runner takes the row through `processRow` → either
   `allocateBuildSignBroadcast` (fresh) or
   `rebroadcastAndPoll` (persisted) or `pollAndConfirm`
   (broadcast) or `claimAndLog` (confirmed).
4. Step 4 in-broadcast insufficient-funds check fires AFTER
   per-payout-cap + daily-cap + existing-attempt checks. Step 4
   `runningBalance` deducts in the broadcast paths only.
5. Confirmation: §4.3 step 7 ConfirmationBlocks (from
   `r.snap().ConfirmationBlocks`, live-reloadable). Verify the
   confirmation depth check is on BOTH RPCs.
6. `claimAndLog` → billing.ClaimPayoutReady. Verify
   `payout_external_id` + `payout_currency` match the spec
   contract.

### B. Cross-step composition

1. **Halt primitive composition.** Step 4
   `Runner.RequestHalt(reason)` halts the next cycle. Step 2's
   self-fence loop in mid-cycle still has to abort cleanly when
   halt is requested while a row is in flight. Trace:
   `chainWorker.haltRunner` → `runner.RequestHalt` →
   `runner.IsHalted()` checked by RunOnce top check AND by
   RunNowController gate. Verify ALL admin entry points
   (run-now, abandon, pause/resume, record-funding,
   record-orphan) gate on IsHalted OR explicitly bypass with
   reason. The abandon endpoint at Step 2 — does it refuse
   while halted? Pause/resume? Record-funding?
2. **TuningProvider plumbing — final audit.** Step 4 r4 architect
   declared TuningSnapshot exhaustive. Verify across ALL Step
   2+3+4 services that no consumer captures a tuning value at
   construction except the documented ticker-cadence
   (RunInterval) cases. Walk every:
   - AddressCoolingOffPeriod (addresses.go)
   - RunInterval (ticker cadences + stale-age use sites)
   - RunNowMinInterval (runnow.go)
   - ConfirmationBlocks (runner.go in 2 sites)
   - MaxRowsPerRun (runner.go)
   - ReorgPollWindow (reorg.go)
   - LowBalanceThreshold / LowNativeThreshold (runner.go)
   - RPCURLPrimaryPinSPKI / RPCURLSecondaryPinSPKI (rpc.go via
     pinFn closure)
3. **Step 3 outbox primitive ↔ Step 2 stale CAS ↔ Step 4 reaper.**
   `ProduceStaleOutboxRows` is runner-owned. The reaper drains
   the §4.7 reconfirm-stale outbox. The Step 3 admin endpoints
   (record-funding / record-orphan / pause/resume) use the same
   outbox primitive. Verify the outbox can't be drained while
   a write is in flight (BEGIN IMMEDIATE + CAS-claim semantics).
4. **Shutdown ordering across all 5 backgrounds.** main.go's
   stop closure: chainWorker → runner → reorgPoller → reaper +
   release only on (runnerClean && pollerClean). Plus the
   SIGHUP listener goroutine bound to shutdownCtx. Trace
   exactly:
   - Does each background process's Stop() return correctly?
   - Lease.Release is gated on runnerClean+pollerClean — verify
     the stale takeover behavior is the documented fallback.
   - SIGHUP listener exits on ctx.Done() — verify no leaked
     goroutine.

### C. §7.1 event sweep across all 4 Steps

Walk every event in SPEC §7.1 lines 3712-3732 against the
implementation:

| Event | Step | Field set match? |
|-------|------|------------------|
| payout_run_started | 2 | ? |
| payout_run_finished | 2 | ? |
| payout_run_now_invoked | 4 | ? |
| payout_paid | 2 | ? |
| payout_failed | 2 | ? |
| payout_capped | 2 | ? |
| payout_low_balance | 4 | ? (§7.1 field rename closed in r2) |
| payout_low_native_balance | 4 | ? |
| payout_insufficient_funds | 4 | ? |
| payout_daily_cap_tripped | 4 | ? |
| payout_reorg_revert (provider + cancel) | 2 + 3 | ? |
| payout_reorg_poll_rpc_error | 2 | ? |
| payout_rpc_disagreement | 2 | ? |
| payout_chain_balance_drift_positive | 4 | ? |
| payout_chain_balance_drift_negative | 4 | ? |
| payout_nonce_cold_start_within_tolerance | 2 (emit in main.go) | ? (r5 fix added ts_utc) |
| payout_config_reloaded | 4 | ? |
| payout_config_reload_rejected | 4 | ? |
| payout_registration_paused | 3 | ? |

Step 4 r5+r6+r7 already swept many of these; re-verify holistic
consistency.

### D. Import-graph + co-residency

Step 1 introduced the one-way import boundary: payout → billing
allowed; reverse FORBIDDEN. Verify:
- `phase4-coordinator/internal/billing/payout_address_reader.go`
  is the only interface payout/ implements for billing.
- No `phase4-coordinator/internal/billing/*.go` file imports
  `phase4-coordinator/internal/payout`.
- payout/ → billing/ only goes through PayoutClaimer +
  PayoutAddressReader interfaces.
- `topology.go::AssertPayoutRuntimeTopology` is invoked from
  main.go before mounting payout routes.

### E. Test coverage holistic

The 4 step audits added many tests. Verify the COMBINED test
corpus covers:
- End-to-end smoke: register → ready → broadcast → confirm →
  claim — does ANY single test exercise the whole chain? If not,
  flag as MEDIUM coverage gap.
- Halt-then-recover: runner halts, restart picks up state
  cleanly.
- SIGHUP-during-cycle: the snapshot is read once per cycle,
  reload mid-cycle doesn't tear.
- Lease takeover: prior holder dies mid-broadcast, fresh holder
  rebroadcasts persisted bytes.

### F. Race detector + govulncheck + gofmt

- `go test -race -count=1 ./...` from `phase4-coordinator/`
- `govulncheck ./...` from `phase4-coordinator/`
- `gofmt -l phase4-coordinator/`

### G. Migration ordering

The 4 Steps add SQL migrations. Verify:
- Migration numbers are monotonic; no gaps.
- Step 3 migrations don't conflict with Step 1 (e.g., adding a
  column to a table Step 1 created — must use ALTER, not
  CREATE).
- Each migration is idempotent (CREATE IF NOT EXISTS,
  CREATE INDEX IF NOT EXISTS).
- `migrations.go` runner reads them in order.

## Output

Write findings to `specs/SPEC-016-IMPL-FULL-code-r1-audit.md`.
Standard structure (Code Review Summary, By Severity, Findings,
Recommendation). If 0/0/0/0 — declare CONVERGENT.

## Discipline

- Cross-step focus. Each per-Step audit already cleared its own
  surface. Look for what only shows when the 4 Steps are read
  TOGETHER.
- Wall-clock target: 35-45 min.

=== END PROMPT ===
```

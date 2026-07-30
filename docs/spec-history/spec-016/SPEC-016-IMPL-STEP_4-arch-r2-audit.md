# SPEC-016 Step 4 — architecture-review lane, r2 audit

Codex run: local architecture lane, round 2
HEAD observed: `62b8d0a` on branch `impl/spec-016` (`dd72e0e` is the implementation fix-pass under audit)

## Verdict

**BLOCK** — 0 CRITICAL / 2 MAJOR / 0 MEDIUM / 0 LOW.

The round-1 halt and core tuning-consumer defects are closed for the fields the fix-pass targeted: runner cycle reads, address cooling-off, reorg poll window, reaper stale age, low-balance thresholds, SIGHUP loader split, deploy gate, and run-now halted 409s. However, the r2 architecture pass found two remaining `payout.tuning.*` authority leaks: `run_now_min_interval` is accepted/reloaded but no run-now handler enforces it, and SPKI pin reloads are accepted/audited but the live RPC clients keep the startup TLS verifier.

Validation: `go test ./... -count=1` passed in `phase4-coordinator`.

## Counts

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| MAJOR    | 2 |
| MEDIUM   | 0 |
| LOW      | 0 |

## R1 Finding Closure

| R1 finding | r2 status | Evidence |
|------------|-----------|----------|
| [arch:4.1] negative drift does not halt runner | **CLOSED** | `ChainBalanceWorker` invokes `haltRunner` on negative drift at `phase4-coordinator/internal/payout/reconcile.go:437`; production wiring now calls `runner.RequestHalt(reason)` at `phase4-coordinator/cmd/coordinator/main.go:894`; `RunOnce` returns `ErrRunnerHalted` before stale-outbox or payout selection at `phase4-coordinator/internal/payout/runner.go:321`. |
| [arch:4.2] accepted tuning reloads do not reach consumers | **PARTIAL / new gaps below** | Targeted consumers are wired: runner snapshots once per cycle at `phase4-coordinator/internal/payout/runner.go:343`; address writes use `currentCoolingOff()` at `phase4-coordinator/internal/payout/addresses.go:441`; reorg uses `currentPollWindow()` at `phase4-coordinator/internal/payout/reorg.go:92`; reaper uses `currentStaleAge()` at `phase4-coordinator/internal/payout/reaper.go:198`. Two other tuning keys still leak; see [arch:r2-4.1] and [arch:r2-4.2]. |
| [arch:4.3] balance monitoring disabled at startup | **CLOSED** | `setupPayout` passes `LowBalanceThreshold` and `LowNativeThreshold` into `RunnerOptions` at `phase4-coordinator/cmd/coordinator/main.go:791`; `emitBalanceAlerts` consumes the per-cycle snapshot at `phase4-coordinator/internal/payout/runner.go:1361`. |
| [arch:4.4] tuning/security static check is string-scan only | **CLOSED** | `TestTuningStaticCheck_NoSecurityNamespaceReference` now AST-walks identifiers and string literals at `phase4-coordinator/internal/payout/config_tuning_test.go:219`. |
| [arch:4.5] Step 3 advisories need tracking | **DEFERRED** | Shared r2 context explicitly defers the tracking issue to PR-open phase; the underlying advisories remain listed at `specs/SPEC-016-IMPL-STEP_3-r4-convergence.md:161`. |
| [arch:4.6] deploy gate omits Step 4 threshold keys | **CLOSED** | Required tuning-key loop includes `low_balance_threshold` and `low_native_threshold` at `phase4-coordinator/dist/check-deploy-config.sh:373`. |

## Findings

### [arch:r2-4.1] MAJOR — `run_now_min_interval` is reloadable but no run-now path enforces it or emits the required invocation event

SPEC §4.2 requires `POST /admin/payout/run-now` to be rate-limited by `payout.tuning.run_now_min_interval` and return 429 if invoked too soon; it also requires every invocation to emit `payout_run_now_invoked` at `specs/SPEC-016-payout-pipeline.md:861` and `specs/SPEC-016-payout-pipeline.md:3716`. The config model and tuning provider treat the key as first-class reloadable state at `phase4-coordinator/internal/config/config.go:151`, `phase4-coordinator/internal/payout/config_tuning.go:31`, and `phase4-coordinator/internal/payout/config_tuning.go:237`.

None of the three mux-level run-now handlers consumes that field. Step2 checks only `Runner.IsHalted()` then calls `Runner.RunOnce()` at `phase4-coordinator/internal/payout/mux.go:160`; Step3 repeats the same pattern at `phase4-coordinator/internal/payout/mux.go:235`; Step4 repeats it again at `phase4-coordinator/internal/payout/mux.go:324`. There is no rate-limit state, no 429 path, and no `payout_run_now_invoked` emission; repository search only finds the event in the SPEC.

This is the same authority bug class as r1: SIGHUP can accept and PAGE-log a changed `payout.tuning.run_now_min_interval`, but the primitive does not control the actual entry point into the payout cycle. It also leaves an operator-key holder able to tight-loop synchronous `RunOnce` calls except when a cycle is already in flight.

**Recommended fix:** create a shared run-now gate used by `NewMuxStep2`, `NewMuxStep3`, and `NewMuxStep4`. The gate should hold the last accepted invocation timestamp, read `TuningProvider.Snapshot().RunNowMinInterval` at request time, return 429 when the interval has not elapsed, emit `payout_run_now_invoked` on accepted requests, and then call `Runner.RunOnce`.

### [arch:r2-4.2] MAJOR — SPKI pin reloads are accepted and audited but cannot affect the live RPC clients

SPEC §6.5 explicitly classifies `payout.tuning.rpc_url_primary_pin_spki` and `payout.tuning.rpc_url_secondary_pin_spki` as hot-reloadable; cert rotation is named as the legitimate hot-reload case at `specs/SPEC-016-payout-pipeline.md:3665`. The SIGHUP path carries those keys into the candidate snapshot at `phase4-coordinator/cmd/coordinator/main.go:1332`, `TuningProvider.Reload` stores the new snapshot atomically at `phase4-coordinator/internal/payout/config_tuning.go:209`, and `emitReloaded` emits `payout_config_reloaded` for SPKI changes at `phase4-coordinator/internal/payout/config_tuning.go:255`.

The RPC clients that actually enforce SPKI pins are constructed once from startup config at `phase4-coordinator/cmd/coordinator/main.go:695`. `NewHTTPRPCClient` then closes over the supplied `spkiPin` inside a `tls.Config.VerifyPeerCertificate` callback at `phase4-coordinator/internal/payout/rpc.go:131` and `phase4-coordinator/internal/payout/rpc.go:140`. There is no later write path from `TuningProvider` into those clients; repository search finds no other use of `RPCURLPrimaryPinSPKI` / `RPCURLSecondaryPinSPKI` outside startup construction and reload logging.

Operationally, a SIGHUP after RPC provider cert rotation can produce a successful `payout_config_reloaded` PAGE while the next RPC call still verifies against the stale startup pin. That contradicts the advertised hot-reload contract and gives operators false evidence that the pin rotation landed.

**Recommended fix:** make pin enforcement read the live provider at TLS verification time, or make SIGHUP perform an atomic RPC-client rebuild/swap after `TuningProvider.Reload` succeeds. If rebuilding, close idle connections on the old clients and ensure all consumers hold an atomic `TwoRPCs` provider rather than copied concrete clients.

## Architecture Analysis

### TuningProvider authority

The core fix-pass shape is sound for the four targeted consumers. `Runner.RunOnce` rejects halted cycles before any row advancement, then captures a single tuning snapshot and passes that snapshot to selection and balance probes at `phase4-coordinator/internal/payout/runner.go:321` and `phase4-coordinator/internal/payout/runner.go:343`. Downstream confirmation checks use `r.snap().ConfirmationBlocks` at `phase4-coordinator/internal/payout/runner.go:646` and `phase4-coordinator/internal/payout/runner.go:934`, and ready selection uses `snap.MaxRowsPerRun` at `phase4-coordinator/internal/payout/runner.go:404`.

The `activeSnap` sentinel is defensible for the present code: `ConfirmationBlocks == 0` is rejected at startup/reload by `validateBounds` at `phase4-coordinator/internal/payout/config_tuning.go:99`, and `RunOnce` sets `activeSnap` only after `inFlight` admission at `phase4-coordinator/internal/payout/runner.go:330`. No production call site invokes `r.snap()` outside runner methods. The limitation remains that `activeSnap` is a plain field, so future goroutine fan-out inside `RunOnce` must either keep all reads on the cycle goroutine or guard the field.

Ticker cadence is documented where it matters for runner and reaper. Runner comments state `RunInterval` is construction-captured and restart-required at `phase4-coordinator/internal/payout/runner.go:86`; reaper comments say the same for `tickEvery` at `phase4-coordinator/internal/payout/reaper.go:69`. Reorg documents that `RunInterval` is not live-reloadable at `phase4-coordinator/internal/payout/reorg.go:54`. The code behavior matches: runner loop tickers use `r.opts.RunInterval` at `phase4-coordinator/internal/payout/runner.go:246`, reorg uses `p.RunInterval` at `phase4-coordinator/internal/payout/reorg.go:312`, and reaper uses `r.tickEvery` at `phase4-coordinator/internal/payout/reaper.go:134`.

### Halt primitive authority

`RequestHalt` is idempotent through `CompareAndSwap(false, true)` at `phase4-coordinator/internal/payout/runner.go:136`, and the first reason wins via `atomic.Value` stores at `phase4-coordinator/internal/payout/runner.go:137`. No code clears the flag; repository search found no `r.halted.Store(false)`.

Every production cycle entry checked in this audit observes the halt. The cadence loop calls `RunOnce`, whose top check returns before `ProduceStaleOutboxRows`, balance probes, or ready-row selection at `phase4-coordinator/internal/payout/runner.go:321`. Admin run-now checks `IsHalted()` in Step2, Step3, and Step4 muxes at `phase4-coordinator/internal/payout/mux.go:165`, `phase4-coordinator/internal/payout/mux.go:237`, and `phase4-coordinator/internal/payout/mux.go:326`.

Shutdown composition is also sound: `main.go` stops `chainWorker` before `runner`, then `reorgPoller`, then `reaper`, and releases only if runner and poller report clean exit at `phase4-coordinator/cmd/coordinator/main.go:978`. `ChainBalanceWorker.Stop` only cancels its own context and waits on `done` at `phase4-coordinator/internal/payout/reconcile.go:339`, so it does not depend on runner state and does not deadlock with `RequestHalt`.

### SIGHUP path architecture

`LoadPayoutTuningOnly` is the right loader surface for the tuning path. The wrapper type contains only `Payout.Tuning` at `phase4-coordinator/internal/config/config.go:614`, the loader explicitly avoids `resolveEnv` and full `Validate` at `phase4-coordinator/internal/config/config.go:620`, and the SIGHUP handler calls it directly at `phase4-coordinator/cmd/coordinator/main.go:1315`. The only mutation of the live payout tuning snapshot is `TuningProvider.Reload` followed by `p.v.Store(candidate)` at `phase4-coordinator/internal/payout/config_tuning.go:200` and `phase4-coordinator/internal/payout/config_tuning.go:210`.

This is structurally analogous to the tier2 reload pattern: build/validate candidate, retain old live value on failure, atomic swap on success. The remaining issue is not loader isolation; it is that two accepted tuning keys still lack authoritative consumers.

## Root Cause

The r1 fix-pass correctly centralized a `TuningProvider`, but it closed only the fields named in the r1 findings. The architecture still treats `payout.tuning.*` as a bag of values rather than an authority contract that every hot-reloadable key must control its production behavior. `run_now_min_interval` and SPKI pins prove the abstraction is not yet exhaustive.

## Recommendations

1. **Block PR until every `payout.tuning.*` key has an authoritative consumer — medium effort, high impact.** Fix [arch:r2-4.1] and [arch:r2-4.2], then add static/test coverage that enumerates all fields of `TuningSnapshot` and proves each either has a live consumer or an explicit restart-only exception.
2. **Deduplicate run-now handler behavior — low/medium effort, medium impact.** The Step2/Step3/Step4 handlers currently copy the same `IsHalted` + `RunOnce` sequence. A shared run-now service/gate prevents future fixes from landing in only one mux level.
3. **Keep ticker cadence as restart-only unless intentionally redesigned — low effort, medium impact.** The comments are adequate; do not attempt partial ticker reset without a coordinated lifecycle design because runner lease, reorg poller, and reaper stop/restart semantics are coupled.

## Trade-offs

| Option | Pros | Cons |
|--------|------|------|
| Shared run-now gate + live tuning read | Small, local fix; closes rate-limit and event semantics across all mux levels. | Adds mutable timestamp state that needs test-controlled clocks and concurrency locking. |
| Atomic RPC-client rebuild on SPKI reload | Preserves normal TLS verifier construction; easy to reason about old vs new clients. | Requires changing consumers to dereference RPC clients through an atomic holder and closing idle connections carefully. |
| TLS verifier reads live `TuningProvider` | Minimal client rebuild surface; pin change lands on the next TLS handshake. | Existing keep-alive connections may continue until closed; verifier now depends on a mutable provider and must be designed for nil/test paths. |
| Treat SPKI pins as restart-only | Simplest implementation. | Violates SPEC §6.5 and contradicts `payout_config_reloaded`; would require SPEC/runbook changes, not just code comments. |

## PR-Readiness Matrix

| Row | Verdict |
|-----|---------|
| §6.5 dual-namespace loader split | **OK** — loader isolation is sound; remaining defects are consumer authority gaps. |
| §7.4 reconciliation queries verbatim | **OK** |
| §7.4 chain-balance worker drift detection | **OK** |
| §7.4 negative-drift halt | **OK** — `RequestHalt` is wired and observed by next cycle/run-now. |
| §6.2 balance monitoring emits | **OK** |
| §7.3 provider-scoped read endpoint | **OK by architecture scope** — code/security lanes own endpoint-specific auth/rate-limit detail. |
| Ops bundle (yaml.example + deploy gate + runbook) | **OK for r1 closure** — threshold gate fixed; runbook still needs PR-open use. |
| 4-background shutdown composition | **OK** |
| TuningProvider authoritative across consumers | **BLOCK** — `run_now_min_interval` and SPKI pins are accepted/reloaded but not authoritative. |
| Halt primitive authoritative across entry points | **OK** |
| Step 3 advisories addressed or deferred | **DEFERRED** — no Step 4 r1 fix closed the stale-producer cap or chronic single-RPC telemetry advisories. |

## Step 3 Advisories

No Step 3 advisory was closed by the Step 4 r1 fix-pass. The per-cycle stale producer cap remains open: `ProduceStaleOutboxRows` selects all candidates without `LIMIT` at `phase4-coordinator/internal/payout/orphans.go:397` and then performs two RPC receipt calls per candidate at `phase4-coordinator/internal/payout/orphans.go:447`. Chronic single-RPC outage telemetry also remains open; RPC errors are intentionally skipped in the stale producer at `phase4-coordinator/internal/payout/orphans.go:449`, and no new Step 4 signal was added for long-lived single-RPC degradation. These are correctly deferred rather than folded into Step 4 convergence.

## References

- `phase4-coordinator/internal/payout/mux.go:160` — Step2 run-now handler has halt check + direct `RunOnce`, but no rate limit or invocation event.
- `phase4-coordinator/internal/payout/mux.go:235` — Step3 repeats the same run-now logic.
- `phase4-coordinator/internal/payout/mux.go:324` — Step4 repeats the same run-now logic.
- `phase4-coordinator/internal/payout/config_tuning.go:237` — `run_now_min_interval` reload changes are audited as accepted config.
- `phase4-coordinator/cmd/coordinator/main.go:695` — RPC clients are constructed once with startup SPKI pins.
- `phase4-coordinator/internal/payout/rpc.go:140` — SPKI verifier closes over the constructor-provided pin.
- `phase4-coordinator/cmd/coordinator/main.go:1332` — SIGHUP loader carries candidate SPKI pins into the tuning snapshot.
- `phase4-coordinator/internal/payout/config_tuning.go:255` — SPKI reloads emit `payout_config_reloaded`.
- `phase4-coordinator/internal/payout/runner.go:321` — halted runner refuses before stale-outbox or payout row advancement.
- `phase4-coordinator/cmd/coordinator/main.go:894` — chain-balance negative-drift halt callback calls `runner.RequestHalt`.
- `phase4-coordinator/internal/payout/addresses.go:441` — address cooling-off reads `currentCoolingOff()` at write time.
- `phase4-coordinator/internal/payout/reorg.go:92` — reorg poll window reads `currentPollWindow()` per cycle.
- `phase4-coordinator/internal/payout/reaper.go:198` — stale outbox cutoff reads `currentStaleAge()` per pass.
- `phase4-coordinator/dist/check-deploy-config.sh:373` — deploy gate now requires low-balance and low-native threshold keys.
- `specs/SPEC-016-payout-pipeline.md:861` — run-now rate-limit requirement.
- `specs/SPEC-016-payout-pipeline.md:3665` — SPKI pins are hot-reloadable tuning keys.
- `specs/SPEC-016-payout-pipeline.md:3716` — `payout_run_now_invoked` event field contract.

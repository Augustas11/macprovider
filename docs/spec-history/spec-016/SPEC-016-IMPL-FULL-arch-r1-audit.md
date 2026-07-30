# SPEC-016 FULL IMPL architecture audit r1

**Verdict:** BLOCKED on one MEDIUM architecture finding. Counts:

| CRITICAL | HIGH | MAJOR | MEDIUM | LOW |
|----------|------|-------|--------|-----|
| 0 | 0 | 0 | 1 | 0 |

Scope note: the lane prompt names `47e4f24` as HEAD, but the checked-out audit target is `7b49cd7` (`spec(016): FULL-implementation r1 audit prompts...`). This report audits the code currently on disk at `7b49cd7`.

## Summary

The cross-step composition is mostly coherent: `TuningProvider`, `RunNowController`, persistent pause flags, lease release gating, migration ordering, and §7.4 reconcile SQL all line up across Steps 1-4. The blocking gap is in the §6.3/topology authority: the code contains a Linux-only startup check, prior Step 1 convergence explicitly said Step 2 must enable it, but `setupPayout` still disables it while `payout.enabled=true`.

That means a runner with an in-memory hot-wallet signer can start on non-Linux, contrary to SPEC §6.3. The same area also leaves signer/RPC presence outside `AssertPayoutRuntimeTopology`, so the named topology assertion is no longer the single startup authority the full audit prompt asks it to be, even though separate setup code currently fails closed before route mounting.

## Analysis

### [full-arch:r1-1] MEDIUM - §6.3 Linux/topology startup authority is not enforced when the runner is enabled

**Evidence:**

- SPEC §6.3 says the payout runner is Linux-only and "IMPL MUST refuse to start the runner on `runtime.GOOS != \"linux\"`" at `specs/SPEC-016-payout-pipeline.md:3263`.
- The topology helper implements the gate: if `LinuxRequired` is true and `runtime.GOOS != "linux"`, `AssertPayoutRuntimeTopology` returns an error at `phase4-coordinator/internal/payout/topology.go:83`.
- `setupPayout` calls `AssertPayoutRuntimeTopology` with `HandlerEnabled:true` and `RunnerCoResident:true`, but hardcodes `LinuxRequired:false` at `phase4-coordinator/cmd/coordinator/main.go:671`.
- Step 1 convergence explicitly carried this as a Step 2 tightening: "Set `LinuxRequired=true` in `setupPayout` when the runner is enabled" at `specs/SPEC-016-IMPL-STEP_1-r2-convergence.md:146`.
- The signer code says §6.3 hardening "runs in the Linux-only setup path" and points to `topology.go` for the Linux hook at `phase4-coordinator/internal/payout/signer.go:70`, but the setup path has that hook disabled.

**Impact:** A non-Linux process can pass topology validation with `payout.enabled=true`, load the signer, acquire the runner lease, build RPC clients, and mount payout routes. This breaks a SPEC-mandated startup invariant and regresses a forward-looking Step 1 closure. The production Pearl host is Linux, so this is not a confirmed production outage on the current intended deployment, but the code path is wrong and the protection is not enforced by the binary.

**Root cause:** `PayoutRuntimeTopology` was introduced in Step 1 as a future-tightenable hook, but later steps tightened co-residency and left the OS gate disabled at the call site. The topology authority also did not evolve to carry `SignerPresent` or `TwoRPCsConstructed`, so some §6.3 / §4.4 startup invariants are enforced by adjacent setup code rather than the named topology assertion.

**Recommended fix:** In `setupPayout`, pass `LinuxRequired:true` whenever `cfg.Payout.Enabled` is true. Add a regression test that exercises the call-site posture or a topology constructor helper so this cannot silently drift back. Consider extending `PayoutRuntimeTopology` with `SignerPresent` and `TwoRPCsConstructed` (or move the topology assertion after signer/RPC construction) so the topology assertion, not surrounding comments, is the single co-residency/startup authority.

## Cross-Step Authority Review

| Authority | Verdict | Evidence |
|-----------|---------|----------|
| `TuningProvider` for §6.5 reloadable keys | PASS | Snapshot field set covers all tuning keys at `phase4-coordinator/internal/payout/config_tuning.go:23`; bounds cover all keys at `config_tuning.go:93`; reload atomic-store path is `config_tuning.go:279`; consumers read live snapshots in address cooling-off `addresses.go:112`, runner cycle `runner.go:341`, reorg window `reorg.go:74`, reaper stale age `reaper.go:58`, run-now `runnow.go:92`, and SPKI closures `main.go:727`. Cadence tickers remain restart-bound by documented limitation. |
| Halt primitive | PASS | `Runner.RequestHalt` / `IsHalted` are the only halt API at `runner.go:191` and `runner.go:211`; `RunOnce` refuses before stale production or row selection at `runner.go:386`; chain balance negative drift calls the halt callback at `reconcile.go:466`; run-now gates on `IsHalted` and maps `ErrRunnerHalted` at `runnow.go:157`. |
| `RunNowController` | PASS | Step 2/3/4 muxes all require and delegate to `RunNowController` at `mux.go:155`, `mux.go:222`, and `mux.go:299`; the controller reads live `RunNowMinInterval` at `runnow.go:92` and emits `payout_run_now_invoked` on every outcome at `runnow.go:108`. |
| Lease / self-fence | PASS | Lease acquire/heartbeat/release live in `lease.go:63`, `lease.go:179`, `lease.go:277`; in-transaction and post-commit self-fences are `lease.go:239` and `lease.go:258`; runner uses the self-fence before persisted-byte rebroadcast at `runner.go:747` and inside fresh allocation at `runner.go:909`. |
| Pause flag | PASS | Persistent reader hits `runtime_flags` each request at `pause_reader.go:35`; §3.3 handler checks pre-auth at `addresses.go:220` and re-checks inside `BEGIN IMMEDIATE` at `addresses.go:389`; writes go through `RuntimeFlagWriter` at `runtime_flags.go:86`. |
| Bootstrap sentinel | PASS | first-cycle seed and sentinel asymmetry logic is in `bootstrap.go:77`; non-first-boot missing flag halts at `bootstrap.go:110`; setup calls it before route mount at `main.go:651`. |
| §4.1 import boundary | PASS | billing declares the seam without importing payout at `billing/payout_address_reader.go:5`; import graph test blocks billing -> payout transitively at `importgraph_test.go:28`; payout -> billing is permitted by the runner seam at `runner.go:38`. |
| §6.3 co-residency / topology | BLOCK | Co-resident runner check is enabled at `main.go:671`, but Linux enforcement is disabled there despite `topology.go:83` and SPEC §6.3. |

## Cross-Step Composition

- Shutdown ordering matches the prompt: main starts runner/reorg/reaper/chain worker at `main.go:341`; shutdown calls `chainWorker.Stop`, then `runner.Stop`, `reorgPoller.Stop`, `reaper.Stop` at `main.go:1016`; lease release is gated only on `runnerClean && pollerClean` at `main.go:1024`.
- SIGHUP listener exits on `ctx.Done()` at `main.go:1353` and uses `LoadPayoutTuningOnly` at `main.go:1359`, so cleanup is implicit via shutdown context.
- Migrations are monotonic `0001` through `0012` with no numbering gaps under `phase4-coordinator/internal/payout/migrations/`.
- Step 3 [arch:4.5] advisories are documented as PR-open tracking work in `specs/SPEC-016-IMPL-STEP_4-r8-convergence.md:105`: one issue for `ProduceStaleOutboxRows` LIMIT and chronic single-RPC outage telemetry.
- §7.4 labeled queries A-F in `reconcile.sql` match the normative SQL blocks in SPEC §7.4: A at `reconcile.sql:75` vs SPEC `3941`, B at `reconcile.sql:87` vs SPEC `3950`, C at `reconcile.sql:101` vs SPEC `3959`, D at `reconcile.sql:118` vs SPEC `3991`, E at `reconcile.sql:136` vs SPEC `4012`, F at `reconcile.sql:150` vs SPEC `4028`.

## Final PR Readiness Matrix

| Row | Verdict |
|-----|---------|
| §3.2 EIP-712 register | PASS |
| §3.3 cooling-off + pre-auth pause | PASS |
| §3.4 audit-log emits | PASS |
| §4.1 import boundary | PASS |
| §4.2 admin run-now contract | PASS |
| §4.3 9-step runner cycle | PASS |
| §4.4 two-RPC discipline | PASS |
| §4.6 abandon endpoint | PASS |
| §4.7 reorg detection + carve-out | PASS |
| §4.8a reaper | PASS |
| §4.8b lease | PASS |
| §4.8c stale-transition CAS + outbox | PASS |
| §4.9 record-funding | PASS |
| §6.2 balance monitoring emits | PASS |
| §6.3 co-residency + dev-mode gate | BLOCK - Linux startup gate disabled in topology call |
| §6.4.1 pause/resume | PASS |
| §6.5 dual-namespace loader split + SIGHUP | PASS |
| §7.1 event field-name compliance | PASS on audited surfaces |
| §7.3 provider-scoped read endpoint | PASS |
| §7.4 reconciliation queries + chain-balance worker | PASS |
| Ops bundle | PASS |
| 5-background shutdown composition | PASS |
| TuningProvider authoritative across consumers | PASS |
| Halt primitive authoritative across entry points | PASS |
| Migration ordering monotonic + idempotent | PASS |
| Step 3 advisories tracked or deferred | PASS - deferred to PR-open tracking issue |

## Root Cause

The implementation treats startup invariants as distributed constructor checks rather than a single topology contract. That works for many fail-closed paths, but it let the Step 1 `LinuxRequired` tightening remain a comment/TODO even after the runner and signer became live production code.

## Recommendations

1. **Enable the Linux gate at the `setupPayout` call site** - small effort - high impact. Change `LinuxRequired:false` to true for the enabled payout runner path and add a test that would fail on the current posture.
2. **Make topology carry the whole startup contract** - medium effort - medium impact. Extend `PayoutRuntimeTopology` or add a `ValidateEnabledPayoutRuntime(...)` helper so runner presence, signer presence, two constructed RPCs, and Linux-only posture are checked together before route mounting.
3. **Keep Step 3 advisory tracking at PR-open** - low effort - low impact. The convergence summary already calls for one tracking issue; ensure the PR links it before merge.

## Trade-offs

| Option | Pros | Cons |
|--------|------|------|
| Minimal fix: flip `LinuxRequired` true | Small diff; directly closes the SPEC violation; low regression risk | Leaves signer/RPC presence enforced by surrounding setup rather than topology |
| Broader topology helper | Centralizes the startup authority and matches the full audit prompt | More test changes; risks overlapping with existing constructor validation if overbuilt |
| Defer to deploy gate / runbook | No code churn | Does not satisfy SPEC §6.3 binary-level refusal and leaves macOS/dev startup footgun |

## References

- `specs/SPEC-016-payout-pipeline.md:3263` - normative Linux-only runner requirement.
- `specs/SPEC-016-payout-pipeline.md:3273` - §6.3 startup hardening context for the signer process.
- `phase4-coordinator/internal/payout/topology.go:83` - Linux-required check exists.
- `phase4-coordinator/cmd/coordinator/main.go:671` - topology call disables `LinuxRequired` while payout is enabled.
- `phase4-coordinator/internal/payout/signer.go:70` - signer comments rely on the Linux-only setup path.
- `specs/SPEC-016-IMPL-STEP_1-r2-convergence.md:146` - prior convergence carried `LinuxRequired=true` as the Step 2 tightening.
- `phase4-coordinator/cmd/coordinator/main.go:1016` - shutdown order and lease-release gate.
- `phase4-coordinator/internal/payout/config_tuning.go:23` - complete `TuningSnapshot` key set.
- `phase4-coordinator/internal/payout/reconcile.sql:75` - labeled reconciliation query section starts.

You are the ARCHITECTURE auditor for draft PR #1947 (Augustas11/macprovider), branch cli/auto-cb-slots, checkout /Users/augstar/macprovider-auto-slots. Review the COMPLETE diff `git diff origin/main...HEAD` (8 commits) and the code it touches. Do not edit files, do not run builds, and do not contact GitHub, Pearl, or any network service.

Context: continuous batching (CB) becomes default-on for every model the native MLX paged engine admits. Each Mac runs an idle-time on-device self-check (ContinuousBatchingSelfCheck.swift): k distinct greedy prompts of unequal length batched on the production scheduler must match each prompt run alone on the same paged engine, or first differ only at a near-tie under the load-time isolation probe rule (top-two, <=1.0 logit, cross-row leak guard); three back-to-back serial/batch repeats per k, median ratio >= 1.2x for a fresh Mac; results stored per (model sha, metallib sha, kernel id, hardware class, macOS build, MLX fork pin) in a 0600 JSON file; applied live (inference gate + ProviderStatus capacity; scheduler rows stay at the memory-fit recommendation). Owner pins are clamped to verified_k. Throughput noise never removes a prior grant (reconcile()); only correctness lowers or revokes. Progress persists; a step that crashed the process is never retried. The signed CB policy becomes revocation-only (rollout:off revokes model sha + metallib + kernel), positive entries are a provisional grant. AutoServedSlots.swift plans rows/initial served slots; Config.swift adds max_concurrency_source (owner|autotune). Native MTP admission becomes model-keyed (runtime revision/hardware/RAM/slots provenance), sidecar expires_at structural, unknown revocation state revokes nothing, load-time self-test compares MTP-on vs ordinary decode on the same engine + 1.15x speedup. Coordinator: heartbeat cb_self_check is parsed (bounded), stored on the pool provider via Registry.SetCBSelfCheck, shown in admin providers; routing unchanged. SPECs 023/031/038/039/048 amended.

Lane: ARCHITECTURE. Focus: SPEC/code consistency (SPEC-038 v0.3.15 FR-CB10/FR-CB11/FR-CB15, SPEC-039 v0.1.15 FR-PKV13/14, SPEC-048 0.1.30 MTP-13/14/16, SPEC-023 v0.22.19 R009/R025, SPEC-031 v0.3.7) and CONFORMANCE mappings; whether scheduler rows = memory-fit cap with served slots < rows violates any SPEC-038 invariant (slots_total vs active rows vs queue), memory envelope / paged pool sizing with more rows, interaction with warm swap/adoption (self-check reset, switchMaxBatchByTarget), status/heartbeat contract additions and backward compatibility (older coordinators, golden frames), deploy ordering (CLI cut vs Pearl train vs MTP bank re-baseline vs pool.max_concurrency_ceiling), and whether the design leaves any path where a currently-batching provider stops batching after the release without a correctness reason.

Output: findings with severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, scenario, fix; mark "pre-existing" when relevant. End with "C/H/M/L = n/n/n/n". Gate: 0 C/H/M.

Round 3 (anchored, final). Your round-2 findings are below (the CODE lane round-2 output was cut off; its summary named prior-grant preservation, swap fencing, admission accounting across serial/batched gates, and crash/progress handling). Commit "Address the round-2 audit of the CB self-check" claims to fix them. For each, state FIXED / NOT FIXED / PARTIAL with evidence, then list only NEW findings the fixes introduced. Same severity scale and gate.

--- Round-2 findings ---

codex
Architecture gate: **FAIL**. Reviewed the complete six-commit `origin/main...HEAD` diff through `a1d80863c` and relevant surrounding code. No edits, tests, builds, or network calls.

Round-1 findings:

1. **FIXED — MTP timing replay.** Both native and ordinary repetitions now use distinct attempt IDs: [ModelRuntime.swift:3628](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3628), [ModelRuntime.swift:3694](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3694). The second timed submission no longer replays the first.

2. **PARTIAL — HIGH — Throughput still lowers existing grants.** [ContinuousBatchingSelfCheck.swift:249](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:249)  
   **Scenario:** Three conformant losses now preserve batching, but reduce an existing grant to two slots without a correctness failure. The test expects this. [SPEC-038:1025](/Users/augstar/macprovider-auto-slots/specs/SPEC-038-continuous-batching.md:1025) prohibits throughput-only lowering, then explicitly permits it at line 1030.  
   **Fix:** Remove the two-slot reduction and its test expectation; preserve the correctness-bounded prior grant while scheduling remeasurement. Remove the contradictory SPEC exception.

3. **FIXED — HTTP batched-row bypass.** Both streaming and non-streaming scheduler submissions acquire `buyerBatchGate`, which resizes with served capacity: [ModelRuntime.swift:4439](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4439), [ModelRuntime.swift:6758](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6758), [ModelRuntime.swift:7217](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7217). The original six-buyer-row scenario is bounded. The gate introduces the queue defect below.

4. **PARTIAL — HIGH — Swap/adoption still lacks target-specific planning before readiness.** [ModelRuntime.swift:5376](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5376)  
   **Scenario:** Adoption no longer advertises all physical rows immediately, but a managed swap publishes the owner pin or one slot before resolving the target’s stored/prior/provisional grant. A qualified target temporarily returns to serial serving without a correctness failure. Separately, [ModelRuntime.swift:3913](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3913) still obtains target rows only through a context-map entry; an operator-owned context can preserve the incumbent’s one-row cap indefinitely. That context/slot coupling is **pre-existing**, newly exposed by this design.  
   **Fix:** Compute target rows independently of context provenance, then resolve target qualification and serving capacity before publishing readiness.

5. **PARTIAL — HIGH — Crash recovery still permits a later retry of the crashed width.** [ContinuousBatchingSelfCheck.swift:803](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:803)  
   **Scenario:** Recovery now checks unfinished attempts first, and journal writes must succeed before width execution. However, suppose remeasurement passes widths 2–3 without sufficient gain, then crashes at 4. Recovery produces `no_net_gain`; reconciliation retains a bounded grant and schedules another measurement. `finish()` clears `inProgressSlots` without retaining a crash boundary. The next measurement again sweeps through width 4.  
   **Fix:** Persist the crashed-width boundary separately from the serving decision and attempt progress; exclude that width and higher widths from every subsequent attempt on that key.

6. **FIXED — Runtime-key changes remove grants at startup.** Startup now restores an older same-model/hardware grant, bounded by current rows, before advertisement: [MacProviderCLI.swift:2997](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:2997). Swap continuity remains finding 4.

7. **FIXED — Provisional grants cross model swaps.** The provisional grant now carries a model artifact hash and reconciliation requires a matching target: [ContinuousBatchingSelfCheck.swift:535](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:535).

8. **FIXED — Serial generation ignores cancellation.** The generation callback observes `BlockingInferenceCancellation` and returns `.stop`: [ModelRuntime.swift:9107](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:9107).

9. **FIXED — Provisional count exceeds computable memory fit.** Provisional rows and initial served slots are bounded by the recommendation when memory fit is known: [AutoServedSlots.swift:56](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/AutoServedSlots.swift:56). Startup supplies the calculated memory-fit availability.

10. **FIXED — Coordinator loses MLX identity.** `runtime_build` is now parsed, bounded, cloned, and serialized to admin output: [provider.go:501](/Users/augstar/macprovider-auto-slots/phase4-coordinator/internal/pool/provider.go:501), [messages.go:1603](/Users/augstar/macprovider-auto-slots/phase4-coordinator/internal/ws/messages.go:1603).

New findings:

1. **NEW — HIGH — Buyer admission now has an unbounded queue outside the scheduler.** [ModelRuntime.swift:6758](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6758), [AsyncSemaphore.swift:58](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/AsyncSemaphore.swift:58)  
   **Scenario:** Direct HTTP acceptance checks pause/drain, not capacity. Excess requests retain prepared submissions and cache leases while waiting in the semaphore’s unbounded waiter list. They have not reached `scheduler.submit()`, so the scheduler’s queue limit, retained-token budget, backpressure, and queue timeout cannot govern them. This violates SPEC-038 FR-CB1’s bounded shared-admission requirement.  
   **Fix:** Put the served-slot limit inside bounded scheduler admission, or implement bounded, timed shared buyer admission before retaining request state. Preserve the existing queue-full and queue-timeout API outcomes.

2. **NEWLY IDENTIFIED — LOW — FR-PKV13 conformance mapping is stale.** [CONFORMANCE.json:5230](/Users/augstar/macprovider-auto-slots/specs/CONFORMANCE.json:5230)  
   **Scenario:** SPEC-039 now delegates its overhead gate to CB self-check, but the **pre-existing** empty implementation/test mapping still says implementation belongs in a follow-up PR.  
   **Fix:** Map R013 to the self-check implementation and tests, distinguishing implemented behavior from pending live evidence.

Physical scheduler rows greater than served slots are compatible with the amended FR-CB11 design, provided buyer admission and waiting work remain correctly bounded. The new gate resolves the original buyer-row bypass but fails that queue requirement.

The optional heartbeat addition remains backward compatible with older coordinators. Deployment verification remains pending: changed MTP numerics require a re-baselined signed bank and matching provider bank references before activation; Pearl must consume the corresponding bank. Routing above the configured `pool.max_concurrency_ceiling` also requires that ceiling change. No live deployment state was checked.

Counts below include remaining and new findings only.

C/H/M/L = 0/4/0/1
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed

You are the ARCHITECTURE auditor for draft PR #1947 (Augustas11/macprovider), branch cli/auto-cb-slots, checkout /Users/augstar/macprovider-auto-slots. Review the COMPLETE diff `git diff origin/main...HEAD` (9 commits) and the code it touches. Do not edit files, do not run builds, and do not contact GitHub, Pearl, or any network service.

Context: continuous batching (CB) becomes default-on for every model the native MLX paged engine admits. Each Mac runs an idle-time on-device self-check (ContinuousBatchingSelfCheck.swift): k distinct greedy prompts of unequal length batched on the production scheduler must match each prompt run alone on the same paged engine, or first differ only at a near-tie under the load-time isolation probe rule (top-two, <=1.0 logit, cross-row leak guard); three back-to-back serial/batch repeats per k, median ratio >= 1.2x for a fresh Mac; results stored per (model sha, metallib sha, kernel id, hardware class, macOS build, MLX fork pin) in a 0600 JSON file; applied live (inference gate + ProviderStatus capacity; scheduler rows stay at the memory-fit recommendation). Owner pins are clamped to verified_k. Throughput noise never removes a prior grant (reconcile()); only correctness lowers or revokes. Progress persists; a step that crashed the process is never retried. The signed CB policy becomes revocation-only (rollout:off revokes model sha + metallib + kernel), positive entries are a provisional grant. AutoServedSlots.swift plans rows/initial served slots; Config.swift adds max_concurrency_source (owner|autotune). Native MTP admission becomes model-keyed (runtime revision/hardware/RAM/slots provenance), sidecar expires_at structural, unknown revocation state revokes nothing, load-time self-test compares MTP-on vs ordinary decode on the same engine + 1.15x speedup. Coordinator: heartbeat cb_self_check is parsed (bounded), stored on the pool provider via Registry.SetCBSelfCheck, shown in admin providers; routing unchanged. SPECs 023/031/038/039/048 amended.

Lane: ARCHITECTURE. Focus: SPEC/code consistency (SPEC-038 v0.3.15 FR-CB10/FR-CB11/FR-CB15, SPEC-039 v0.1.15 FR-PKV13/14, SPEC-048 0.1.30 MTP-13/14/16, SPEC-023 v0.22.19 R009/R025, SPEC-031 v0.3.7) and CONFORMANCE mappings; whether scheduler rows = memory-fit cap with served slots < rows violates any SPEC-038 invariant (slots_total vs active rows vs queue), memory envelope / paged pool sizing with more rows, interaction with warm swap/adoption (self-check reset, switchMaxBatchByTarget), status/heartbeat contract additions and backward compatibility (older coordinators, golden frames), deploy ordering (CLI cut vs Pearl train vs MTP bank re-baseline vs pool.max_concurrency_ceiling), and whether the design leaves any path where a currently-batching provider stops batching after the release without a correctness reason.

Output: findings with severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, scenario, fix; mark "pre-existing" when relevant. End with "C/H/M/L = n/n/n/n". Gate: 0 C/H/M.

Round 4 (anchored confirmation). Your round-3 findings are below. Commit "Address the round-3 audit: cap buyer rows inside the CB scheduler" replaces the outer served-slot gate with a buyer-row limit inside ContinuousBatchScheduler (self-check rows flagged selfCheckProbe use every row; buyer rows wait in the scheduler queue while self-check rows are active), adds a swap generation to self-check targets, gives swap targets provisional grants for every model with a signed positive entry, and reads v5 stores. For each round-3 finding state FIXED / NOT FIXED / PARTIAL with evidence, and list only NEW findings introduced by that commit. Same severity scale and gate.

--- Round-3 findings ---

codex
Architecture gate: **FAIL** at `ab97b409a`. Reviewed the complete local `origin/main...HEAD` diff and relevant surrounding code. No edits, builds, tests, or network calls.

Round-2 findings:

1. **FIXED — MTP timing replay.** Native and ordinary repetitions retain distinct attempt IDs: [ModelRuntime.swift:3632](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3632), [ModelRuntime.swift:3699](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3699).

2. **FIXED — Throughput-only grant reduction.** The repeated-loss reduction to two slots is removed. Reconciliation preserves the prior grant within the correctness-verified bound; losses stretch remeasurement intervals. [ContinuousBatchingSelfCheck.swift:247](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:247). The contradictory SPEC exception and test expectation are removed.

3. **FIXED — HTTP row bypass / mixed serial-batched accounting.** Both batched paths now acquire the same `inferenceGate` used by serial generation, and capacity changes resize it in place. [ModelRuntime.swift:4442](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4442), [ModelRuntime.swift:6800](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6800), [ModelRuntime.swift:7255](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7255). Queue completeness remains unresolved below.

4. **PARTIAL — HIGH — Target-specific swap planning and continuity.** The resolver now applies stored target decisions and older grants before `ProviderStatus.completeTargetSwap`, which fixes the ordinary stored-result case. [ModelRuntime.swift:5527](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5527).

   Two round-2 gaps remain:
   - Target rows still depend on a generated-context entry. With an owner context, a one-row incumbent can carry its one-row scheduler into a qualified target indefinitely. [ModelRuntime.swift:3917](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3917). This context/slot coupling is **pre-existing**.
   - The resolver captures only the startup model’s provisional grant. A swapped-to model with its own positive signed entry but no stored decision receives no target provisional capacity. [MacProviderCLI.swift:2983](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:2983).

   **Fix:** Plan target rows independently of context ownership and resolve provisional grants for the target artifact before publishing readiness.

5. **FIXED — Crashed width retried during later remeasurement.** `finish()` persists the lowest `crashedSlots`; subsequent measurements cap their sweep below it. Clearing `inProgressSlots` no longer loses that boundary. [ContinuousBatchingSelfCheck.swift:661](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:661), [ContinuousBatchingSelfCheck.swift:843](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:843).

6. **FIXED — Runtime-key changes remove startup grants.** Shared resolution restores same-model/hardware prior grants, bounded by current rows. [ContinuousBatchingSelfCheck.swift:369](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:369). Swap limitations remain finding 4.

7. **FIXED — Provisional grants cross model swaps.** Resolution explicitly matches the provisional model SHA. [ContinuousBatchingSelfCheck.swift:368](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:368).

8. **FIXED — Serial generation ignores cancellation.** The self-check serial callback observes blocking-executor cancellation and stops generation. [ModelRuntime.swift:9158](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:9158).

9. **FIXED — Provisional capacity exceeds known memory fit.** The provisional plan remains bounded by the computable recommendation. [AutoServedSlots.swift:56](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/AutoServedSlots.swift:56).

10. **FIXED — Coordinator loses MLX identity.** `runtime_build` remains parsed, bounded, copied, and exposed through admin provider output. [messages.go:1603](/Users/augstar/macprovider-auto-slots/phase4-coordinator/internal/ws/messages.go:1603), [provider.go:501](/Users/augstar/macprovider-auto-slots/phase4-coordinator/internal/pool/provider.go:501).

11. **PARTIAL — HIGH — Admission queue remains outside shared scheduler accounting.** The new gate bounds waiter count and duration, fixing the literal unbounded batched waiter list. However, callers still prepare submissions and acquire cache leases before waiting; the gate does not account for retained tokens. [ModelRuntime.swift:6797](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6797), [AsyncSemaphore.swift:49](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/AsyncSemaphore.swift:49).

   **Scenario:** At eight served slots, the default outer queue permits sixteen prepared requests. Six waiting 200k-token prompts already exceed the scheduler’s 1,048,576-token queue budget, while remaining invisible to its accounting. Streaming preflight also still uses unbounded `withPermit` before this bounded admission. [ModelRuntime.swift:5707](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5707).

   **Fix:** Use one bounded admission owner before retaining prepared request/cache state, covering count, retained-token budget, timeout, and cancellation across both surfaces.

12. **FIXED — LOW — Stale FR-PKV13 mapping.** The **pre-existing** empty mapping now points to the self-check implementation and tests, with live evidence explicitly pending. [CONFORMANCE.json:5230](/Users/augstar/macprovider-auto-slots/specs/CONFORMANCE.json:5230).

Only new finding introduced by the fixes:

- **NEW — MEDIUM — Queue timeout is incorrectly reported as queue-full backpressure.** [ModelRuntime.swift:4467](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4467).

  **Scenario:** A request exhausts the outer gate’s wait deadline. `AdmissionError.timedOut` is caught together with `.queueFull`, producing `continuous_batching_stream_backpressure`. SPEC-038 explicitly requires `continuous_batching_queue_wait_timeout` and distinct timeout diagnostics. [SPEC-038:1473](/Users/augstar/macprovider-auto-slots/specs/SPEC-038-continuous-batching.md:1473).

  **Fix:** Map `.timedOut` to `ContinuousBatchSchedulerError.queueWaitTimedOut`; map only `.queueFull` to `.backpressure`. Verify both streaming and non-streaming error paths.

Physical scheduler rows exceeding served slots remain compatible with amended FR-CB11; the outstanding issue is admission accounting, not that separation itself. The optional heartbeat field remains backward compatible. Deployment ordering remains pending verification: re-baseline/sign the MTP bank and matching provider references, make Pearl consume that bank before changed-numerics native-MTP serving, and raise `pool.max_concurrency_ceiling` before expecting deeper routed capacity.

Counts include unresolved round-2 findings and the new finding.

C/H/M/L = 0/2/1/0
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed

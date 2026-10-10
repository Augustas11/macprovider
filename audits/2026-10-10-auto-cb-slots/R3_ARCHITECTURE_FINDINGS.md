
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

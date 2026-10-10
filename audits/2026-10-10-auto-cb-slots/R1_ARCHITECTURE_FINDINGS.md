
codex
Architecture gate: **FAIL**. Reviewed all four commits against local `origin/main`. No edits, builds, tests, or network calls.

1. **HIGH — Native-MTP speedup measures an idempotent replay.** [ModelRuntime.swift:2935](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2935)  
   **Scenario:** Both timed MTP runs use `native-mtp-selftest-<challengeID>` at line 3615. The scheduler returns the retained terminal result for the second submission (`ContinuousBatchScheduler.swift:2508`); taking the minimum latency therefore measures replay, allowing the MTP-16 1.15× gate to pass without a real speedup.  
   **Fix:** Give every timed execution a unique request ID and verify that every repetition executes inference.

2. **HIGH — Throughput alone still revokes existing CB grants.** [ContinuousBatchingSelfCheck.swift:243](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:243)  
   **Scenario:** Three conformant measurements with aggregate gain below 1.0 return `slots: 1`, permanently stopping batching without a correctness failure. The new test explicitly expects this. SPEC-038:1029 also retains this exception immediately after saying only correctness may lower or revoke grants.  
   **Fix:** Remove throughput-only revocation and its test expectation. Preserve the grant while scheduling remeasurement; reconcile the contradictory SPEC text.

3. **HIGH — HTTP batching can exceed advertised and verified slots.** [ModelRuntime.swift:4426](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4426)  
   **Scenario:** `applyServedSlots()` changes only the serial semaphore. Batched completions bypass it (`ModelRuntime.swift:7532`), while HTTP admission checks pause/drain, not capacity (`HTTPServer.swift:923`, `ProviderStatus.swift:651`). With scheduler rows 8 and `verified_k=5`, six HTTP requests can occupy six rows—including the width rejected by correctness qualification. Relay-only admission does not enforce FR-CB11 across both surfaces.  
   **Fix:** Enforce one shared, dynamically adjustable buyer admission bound before HTTP and relay work reaches the scheduler. Keep physical row capacity separate.

4. **HIGH — Swap/adoption bypasses the target’s served-slot plan.** [ModelRuntime.swift:5330](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5330)  
   **Scenario:** Adoption resets qualification to pending, then installs and advertises `adoptionKnobs.maxBatch` before applying the target’s stored decision or pending/provisional count. Target row sizing also remains coupled to generated-context provenance (`MacProviderCLI.swift:2749`, `ModelRuntime.swift:3899`), allowing another model’s row cap to survive. A one-row incumbent can consequently prevent a qualified replacement from batching.  
   **Fix:** Run the same target-specific planning and qualification resolution on startup, swap, and adoption, before publishing readiness. Compute rows independently of context provenance. The context/slot coupling is **pre-existing**, newly exposed by automatic row sizing.

5. **HIGH — Crashed remeasurement steps are retried.** [ContinuousBatchingSelfCheck.swift:511](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:511)  
   **Scenario:** Remeasurement retains the previous `decision` while persisting `inProgressSlots`. After a process crash, `run()` takes the decision branch before examining the unfinished step. The overdue remeasurement starts again, potentially repeating the same Metal OOM indefinitely, contrary to FR-CB10’s never-retry rule.  
   **Fix:** Recover unfinished attempts before handling completed decisions. Store the retained serving grant separately from attempt progress, preserve the crashed-width bound, and require successful persistence before executing a step.

6. **MEDIUM — Runtime-key changes temporarily remove existing batching grants.** [MacProviderCLI.swift:2977](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:2977)  
   **Scenario:** Startup restores only an exact-key decision. After an OS/MLX/metallib change, a locally qualified model without a signed positive entry starts serially. Its older grant is consulted only after measurement finishes; sustained traffic can defer that indefinitely.  
   **Fix:** Resolve a target-scoped older grant at startup, bounded by current rows, and preserve batching while requalification runs.

7. **MEDIUM — Provisional grants leak across model swaps.** [ContinuousBatchingSelfCheck.swift:731](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:731)  
   **Scenario:** The driver captures the startup model’s `provisionalSlots` once, then treats it as a prior grant for every subsequently loaded target. A different, freshly qualified model whose gain is below 1.2× can inherit that unrelated grant.  
   **Fix:** Bind provisional slots to model/artifact identity and resolve eligibility for the current target at reconciliation time.

8. **MEDIUM — Serial self-check work does not yield when cancelled.** [ModelRuntime.swift:9057](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:9057)  
   **Scenario:** The request watcher cancels the measurement, but the serial generation closure ignores `BlockingInferenceCancellation` and always returns `.more`. On a pending one-slot provider, the arriving buyer waits behind the remaining generation while the self-check holds its permit/container.  
   **Fix:** Observe cancellation during generation and terminate promptly using the existing cancellation mechanism, satisfying FR-CB10’s request-yield contract.

9. **MEDIUM — Provisional planning overrides the computed memory-fit bound.** [AutoServedSlots.swift:58](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/AutoServedSlots.swift:58)  
   **Scenario:** A configured provisional count of 8 with a computed recommendation of 4 produces eight rows and eight served slots. For an operator-owned context, startup does not shrink that context to compensate. This contradicts SPEC-023 R009’s explicit requirement never to exceed computable `memory_fit_cap`; short self-check prompts do not establish full-context memory safety.  
   **Fix:** Bound provisional rows and served slots by the final served-context memory-fit calculation.

10. **LOW — Coordinator observability loses the MLX runtime identity.** [provider.go:491](/Users/augstar/macprovider-auto-slots/phase4-coordinator/internal/pool/provider.go:491)  
    **Scenario:** Swift sends `runtime_build`, but `ProviderCBSelfCheck` omits it. Admin status cannot distinguish qualification records from different MLX pins sharing the other identity fields.  
    **Fix:** Add the optional field to parsing, bounded validation, cloning, and admin serialization.

The optional heartbeat addition is backward compatible with older coordinator parsing. Scheduler rows exceeding served slots is architecturally acceptable only with shared admission enforcement; finding 3 identifies the missing enforcement. SPEC-039 FR-PKV13 also needs alignment with SPEC-038’s near-tie and retained/provisional-grant exceptions. Rollout verification remains pending: a changed MTP challenge baseline must precede serving that runtime, and routing above the existing ceiling requires the coordinated `pool.max_concurrency_ceiling` change.

C/H/M/L = 0/5/4/1
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed

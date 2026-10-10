You are the ARCHITECTURE auditor for draft PR #1947 (Augustas11/macprovider), branch cli/auto-cb-slots, checkout /Users/augstar/macprovider-auto-slots. Review the COMPLETE diff `git diff origin/main...HEAD` (6 commits) and the code it touches. Do not edit files, do not run builds, and do not contact GitHub, Pearl, or any network service.

Context: continuous batching (CB) becomes default-on for every model the native MLX paged engine admits. Each Mac runs an idle-time on-device self-check (ContinuousBatchingSelfCheck.swift): k distinct greedy prompts of unequal length batched on the production scheduler must match each prompt run alone on the same paged engine, or first differ only at a near-tie under the load-time isolation probe rule (top-two, <=1.0 logit, cross-row leak guard); three back-to-back serial/batch repeats per k, median ratio >= 1.2x for a fresh Mac; results stored per (model sha, metallib sha, kernel id, hardware class, macOS build, MLX fork pin) in a 0600 JSON file; applied live (inference gate + ProviderStatus capacity; scheduler rows stay at the memory-fit recommendation). Owner pins are clamped to verified_k. Throughput noise never removes a prior grant (reconcile()); only correctness lowers or revokes. Progress persists; a step that crashed the process is never retried. The signed CB policy becomes revocation-only (rollout:off revokes model sha + metallib + kernel), positive entries are a provisional grant. AutoServedSlots.swift plans rows/initial served slots; Config.swift adds max_concurrency_source (owner|autotune). Native MTP admission becomes model-keyed (runtime revision/hardware/RAM/slots provenance), sidecar expires_at structural, unknown revocation state revokes nothing, load-time self-test compares MTP-on vs ordinary decode on the same engine + 1.15x speedup. Coordinator: heartbeat cb_self_check is parsed (bounded), stored on the pool provider via Registry.SetCBSelfCheck, shown in admin providers; routing unchanged. SPECs 023/031/038/039/048 amended.

Lane: ARCHITECTURE. Focus: SPEC/code consistency (SPEC-038 v0.3.15 FR-CB10/FR-CB11/FR-CB15, SPEC-039 v0.1.15 FR-PKV13/14, SPEC-048 0.1.30 MTP-13/14/16, SPEC-023 v0.22.19 R009/R025, SPEC-031 v0.3.7) and CONFORMANCE mappings; whether scheduler rows = memory-fit cap with served slots < rows violates any SPEC-038 invariant (slots_total vs active rows vs queue), memory envelope / paged pool sizing with more rows, interaction with warm swap/adoption (self-check reset, switchMaxBatchByTarget), status/heartbeat contract additions and backward compatibility (older coordinators, golden frames), deploy ordering (CLI cut vs Pearl train vs MTP bank re-baseline vs pool.max_concurrency_ceiling), and whether the design leaves any path where a currently-batching provider stops batching after the release without a correctness reason.

Output: findings with severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, scenario, fix; mark "pre-existing" when relevant. End with "C/H/M/L = n/n/n/n". Gate: 0 C/H/M.

Round 2 (anchored). Your round-1 findings are below. Commit "Address the round-1 audit of the CB self-check" and the follow-ups claim to fix them. For each round-1 finding state FIXED / NOT FIXED / PARTIAL with evidence, then list any NEW findings introduced by the fixes. Same severity scale and gate.

--- Round-1 findings ---

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

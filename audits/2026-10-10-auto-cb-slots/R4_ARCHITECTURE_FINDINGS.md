
codex
Architecture gate: **FAIL** at `928200167`. Reviewed the complete nine-commit `origin/main...HEAD` diff and relevant surrounding code, with round-4 changes anchored to `8703497e4`. No edits, builds, tests, or network calls.

Round-3 findings:

| # | Status | Evidence |
|---|---|---|
| 1 | **FIXED** — MTP timing replay | Native and ordinary runs retain distinct attempt IDs: [ModelRuntime.swift:3633](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3633), [3699](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3699). |
| 2 | **FIXED** — Throughput-only grant reduction | Reconciliation retains the prior grant within the verified bound; losses affect remeasurement timing: [ContinuousBatchingSelfCheck.swift:245](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:245). |
| 3 | **PARTIAL** — HTTP bypass / mixed accounting | Scheduler buyer rows are capped, but serial and batched work again have independent budgets. See the **NEW HIGH** finding below. |
| 4 | **PARTIAL — HIGH** — Target-specific swap planning | Positive entries now cover swap artifacts: [MacProviderCLI.swift:2988](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:2988). Owner-context row planning remains unresolved, detailed below. |
| 5 | **FIXED** — Crashed width retried | Persistent crash boundaries still constrain subsequent sweeps: [ContinuousBatchingSelfCheck.swift:681](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:681), [864](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:864). |
| 6 | **FIXED** — Runtime-key changes remove startup grants | Same-model/hardware older grants remain available: [ContinuousBatchingSelfCheck.swift:454](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:454). Finding 4 still limits swaps. |
| 7 | **FIXED** — Provisional grants cross model swaps | Provisional lookup remains artifact-specific: [ContinuousBatchingSelfCheck.swift:371](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:371). |
| 8 | **FIXED** — Serial generation ignores cancellation | The generation callback still observes executor cancellation: [ModelRuntime.swift:9136](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:9136). |
| 9 | **FIXED** — Provisional capacity exceeds known memory fit | The startup plan bounds provisional capacity by the computable recommendation: [AutoServedSlots.swift:56](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/AutoServedSlots.swift:56). |
| 10 | **FIXED** — Coordinator loses MLX identity | `runtime_build` remains parsed, bounded, copied, and exposed: [messages.go:1607](/Users/augstar/macprovider-auto-slots/phase4-coordinator/internal/ws/messages.go:1607), [provider.go:501](/Users/augstar/macprovider-auto-slots/phase4-coordinator/internal/pool/provider.go:501). |
| 11 | **PARTIAL — HIGH** — Admission outside scheduler accounting | Served-row waits now enter the bounded scheduler queue, but earlier cache-lease and preflight waits remain outside it, detailed below. |
| 12 | **FIXED** — Stale FR-PKV13 mapping | Implementation/tests are mapped and live evidence remains explicitly pending: [CONFORMANCE.json:5282](/Users/augstar/macprovider-auto-slots/specs/CONFORMANCE.json:5282). |
| Round-3 new | **FIXED** — Queue timeout reported as backpressure | The outer error conversion is removed. Scheduler expiry throws `queueWaitTimedOut`, whose API mapping preserves the distinct timeout code: [ContinuousBatchScheduler.swift:2766](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:2766), [1819](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:1819). |

Remaining portions of existing findings:

- **#4 — HIGH, pre-existing context/slot coupling.** [MacProviderCLI.swift:2755](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:2755) still skips target planning unless context is recommendation-owned, and [ModelRuntime.swift:3920](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3920) constructs swap knobs only through the context map. **Scenario:** an owner-context provider with a one-row incumbent swaps to a qualified target; its scheduler remains one-row, so stored/provisional grants clamp to one without a correctness failure. **Fix:** compute and apply target row capacity independently of context ownership, using the target’s memory fit at the retained context.

- **#11 — HIGH, pre-existing admission gap.** Prepared token arrays reach `conversationCache.begin` before scheduler admission on both surfaces: [ModelRuntime.swift:6723](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6723), [7184](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7184). Its same-key waiters remain unbounded and lack timeout/cancellation handling: [ConversationCache.swift:582](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ConversationCache.swift:582). Streaming preflight also retains the separate semaphore wait at [ModelRuntime.swift:5694](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5694). **Scenario:** many long requests sharing one conversation key retain prepared prompts while waiting outside scheduler count/token accounting; disconnects do not promptly remove those lease waiters. **Fix:** reserve bounded admission before retaining prepared state or waiting for a lease, carrying count, token budget, deadline, and cancellation through submission.

Only **NEW** finding introduced by `8703497e4`:

- **HIGH — Removing the shared gate restores mixed serial/batched over-admission.** Batched requests now submit directly at [ModelRuntime.swift:6787](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6787). The new limit counts only scheduler occupancy: [ContinuousBatchScheduler.swift:5675](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:5675), [5704](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:5704); serial fallbacks independently acquire `inferenceGate` at [ModelRuntime.swift:7711](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7711).

  **Scenario:** with eight served slots, eight ordinary batched HTTP requests occupy scheduler rows while a logprobs/logit-bias request serial-routes and obtains a separate permit. HTTP admission checks pause/drain, not capacity ([ProviderStatus.swift:651](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ProviderStatus.swift:651)). Combined active work exceeds eight, violating FR-CB11’s active-work invariant and potentially retaining contiguous KV beyond the memory envelope.

  **Fix:** keep the scheduler as the bounded admission owner, but share its buyer capacity accounting with serial execution; serial holders must consume the same budget as batched rows. Cover mixed traffic and live limit reductions in regression tests.

Physical scheduler rows above served slots remain compatible with amended FR-CB11. Optional heartbeat additions remain backward compatible. Deployment ordering is still unverified locally: the re-baselined signed MTP bank and matching provider references must reach Pearl before changed-numerics MTP serving; deeper routed capacity requires raising `pool.max_concurrency_ceiling`.

Counts include two remaining HIGH findings and the new HIGH regression, counted once.

C/H/M/L = 0/3/0/0
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed

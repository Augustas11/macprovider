
codex
Architecture gate: **FAIL** at `911dcc70a`. Reviewed the complete ten-commit `origin/main...HEAD` diff, anchoring new findings to `928200167..911dcc70a`. No edits, builds, tests, or network calls.

| Round-4 finding | Status | Evidence |
|---|---|---|
| #1 MTP timing replay | **FIXED** | Distinct attempt IDs remain in [ModelRuntime.swift:3633](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3633) and ordinary-reference runs. |
| #2 Throughput-only grant reduction | **FIXED** | [Reconciliation:245](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:245) retains the prior grant within verified bounds. |
| #3 HTTP bypass / mixed accounting | **FIXED** for active-work accounting | Serial execution now acquires the scheduler buyer budget at [ModelRuntime.swift:7728](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7728), including streaming. New waiting-path issue below. |
| #4 Target-specific swap planning | **PRE-EXISTING** | Target planning still requires recommendation-owned context at [MacProviderCLI.swift:2759](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:2759); [switchKnobs:3920](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3920) still depends on the context map. Latest commit does not worsen it. |
| #5 Crashed width retried | **FIXED** | Persistent crash bounds remain at [SelfCheck.swift:683](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:683); warm-up now receives a durable marker at [723](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:723). |
| #6 Runtime-key changes remove startup grants | **FIXED** | Older-runtime grants remain available through [priorGrant:454](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:454). |
| #7 Provisional grants cross model swaps | **FIXED** | [Resolution:370](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:370) remains artifact-specific; owner pins now retain provisional grants. |
| #8 Serial generation ignores cancellation | **FIXED** | Executor cancellation remains observed at [ModelRuntime.swift:9155](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:9155). |
| #9 Provisional capacity exceeds memory fit | **FIXED** | [AutoServedSlots.swift:56](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/AutoServedSlots.swift:56) bounds provisional capacity by computable memory fit. |
| #10 Coordinator loses MLX identity | **FIXED** | `runtime_build` remains parsed and bounded at [messages.go:1607](/Users/augstar/macprovider-auto-slots/phase4-coordinator/internal/ws/messages.go:1607), copied and exposed. |
| #11 Admission outside scheduler accounting | **PRE-EXISTING** | Conversation-lease waits remain before admission at [ModelRuntime.swift:6734](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6734) and the streaming equivalent. Latest commit does not worsen those earlier waits. |
| #12 Stale FR-PKV13 mapping | **FIXED** | [CONFORMANCE.json:5282](/Users/augstar/macprovider-auto-slots/specs/CONFORMANCE.json:5282) maps implementation/tests and explicitly leaves fleet evidence pending. |
| Round-3 new: timeout reported as backpressure | **FIXED** | Existing scheduler timeout still produces `queueWaitTimedOut` at [Scheduler.swift:2766](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:2766). |
| Round-4 new: mixed serial/batched over-admission | **FIXED** | [Scheduler.swift:5715](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:5715) includes external serial holders in the same buyer occupancy calculation. |

Only **NEW** finding introduced by `911dcc70a`:

- **MEDIUM — Serial buyer admission creates a separate wait path without the scheduler’s bounded-wait contract.** [ContinuousBatchScheduler.swift:5723](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:5723) appends external waiters without a deadline, queue-capacity check, retained-token accounting, or inclusion in queue metrics. Both serial serving paths now enter this wait after acquiring `inferenceGate`.

  **Scenario:** batched requests occupy all served slots longer than `continuous_batch_queue_wait_timeout_ms`; a logprobs/logit-bias request waits for the shared budget beyond that configured deadline, while an equivalent queued batched request receives the specified timeout. The semaphore indirectly limits external waiter count, but does not enforce the configured scheduler queue or timeout contract. This is the newly added wait, distinct from the excluded pre-existing conversation-lease waits.

  **Fix:** represent serial budget waiters in the bounded admission machinery, with shared count/token accounting, absolute deadlines, cancellation, and the existing timeout error mapping. Cover mixed traffic with a short configured deadline.

The claimed generation transaction is **PARTIAL**: [ModelRuntime.swift:4521](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4521) checks generation after awaited mutations; returning `false` does not undo them. Generation advances during swap installation, rather than when loading starts. The underlying reentrancy risk predates this commit and is not counted as a new finding.

Scheduler rows above served slots remain compatible with amended FR-CB11. Optional heartbeat additions remain backward compatible. Deployment ordering remains unverified: Pearl must consume the re-baselined signed MTP bank before changed-numerics MTP serving; deeper routed capacity requires the coordinator ceiling change.

Counts exclude the two explicitly out-of-scope pre-existing findings.

C/H/M/L = 0/0/1/0
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed

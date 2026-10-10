
codex
Architecture anchored-confirmation gate: **PASS** at `7dcb2e628`. Reviewed the complete eleven-commit `origin/main...HEAD` diff and touched code, with new findings anchored to `911dcc70a..7dcb2e628`. No edits, builds, tests, or network calls.

| Round-5 item | Status | Evidence |
|---|---|---|
| #1 MTP timing replay | **FIXED** | Distinct attempt IDs remain in [ModelRuntime.swift:3635](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3635) and ordinary-reference runs. |
| #2 Throughput-only grant reduction | **FIXED** | [Reconciliation:245](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:245) retains the prior grant within verified bounds. |
| #3 HTTP bypass / mixed accounting | **FIXED** for batched admission; separate budgets **PRE-EXISTING** | [Scheduler:5700](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:5700) caps buyer rows. Serial requests retain their served-size semaphore at [Runtime:7728](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7728), as on `origin/main`. |
| #4 Target-specific swap planning | **PRE-EXISTING** | Recommendation-owned context remains required at [CLI:2755](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:2755); [switchKnobs:3920](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3920) remains context-map-dependent. |
| #5 Crashed width retried | **FIXED** | Persistent crash bounds remain at [SelfCheck:686](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:686); warm-up is journaled at [725](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:725). |
| #6 Runtime-key changes remove startup grants | **FIXED** | Older-runtime grants remain available through [priorGrant:464](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:464). |
| #7 Provisional grants cross model swaps | **FIXED** | [Resolution:372](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:372) remains artifact-specific. |
| #8 Serial generation ignores cancellation | **FIXED** | The generation callback observes executor cancellation at [Runtime:9153](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:9153). |
| #9 Provisional capacity exceeds memory fit | **FIXED** | [AutoServedSlots:56](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/AutoServedSlots.swift:56) bounds provisional rows by computable memory fit. |
| #10 Coordinator loses MLX identity | **FIXED** | `runtime_build` remains parsed and bounded at [messages.go:1607](/Users/augstar/macprovider-auto-slots/phase4-coordinator/internal/ws/messages.go:1607), copied and exposed. |
| #11 Admission outside scheduler accounting | **PRE-EXISTING** | Conversation-lease waits remain before scheduler admission at [Runtime:6739](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6739) and the streaming equivalent. |
| #12 Stale FR-PKV13 mapping | **FIXED** | [CONFORMANCE.json:5282](/Users/augstar/macprovider-auto-slots/specs/CONFORMANCE.json:5282) maps implementation/tests and explicitly leaves fleet evidence pending. |
| Round-3: timeout reported as backpressure | **FIXED** | Scheduler timeout still returns `queueWaitTimedOut` at [Scheduler:2766](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:2766). |
| Round-4: mixed serial/batched over-admission | **PRE-EXISTING** relative to `origin/main` | Removing external serial holders restores the separate-budget architecture; each path remains capped individually. |
| Round-5: unbounded external serial wait | **FIXED** | External budget waiters and both acquisition calls are removed. Serial serving now proceeds directly from its semaphore into execution at [Runtime:7728](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7728) and [8447](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:8447). |
| Generation transaction | **PARTIAL** | [Runtime:4451](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4451) captures the scheduler before suspension, preventing mutation of a swapped-in scheduler. Post-await checks still cannot undo completed mutations; generation still advances during installation at [5398](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5398). This is the previously identified limitation, not a new round-6 finding. |
| Owner pin widening an older-runtime grant | **FIXED** | [Resolution:373](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:373) clamps the pin to the stored grant before combining candidates. The commit adds a focused regression test. |

**NEW findings introduced by this commit: none.**

Scheduler rows above served slots remain compatible with amended FR-CB11. Optional heartbeat additions remain backward compatible. No new throughput-only batching withdrawal path was introduced.

Deployment ordering remains unverified by this local audit: changed-numerics MTP requires the re-baselined signed bank before serving; routing above eight slots requires the coordinator ceiling change.

Counts exclude the acknowledged earlier limitation and explicitly out-of-scope pre-existing behavior.

C/H/M/L = 0/0/0/0
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed


codex
**REQUEST CHANGES — CODE gate fails.** Reviewed `origin/main...HEAD` through `ab97b409a` and the touched code. No edits, builds, tests, or network calls.

Round-2 dispositions; unresolved entries are **pre-existing relative to the final fix commit**:

| # | Disposition | Evidence and remaining action |
|---|---|---|
| 1 | **FIXED** | `ContinuousBatchingSelfCheck.swift:245–254` preserves the verified prior count through repeated throughput losses. The revised regression expects preservation. |
| 2 | **PARTIAL — HIGH** | Stored/prior decisions now resolve on swap, but `ModelRuntime.swift:5413` still suspends before replacing A’s identity at `5415–5417`. A’s application can pass the check at `4529` during that suspension; if B has no resolution, A’s state survives. Report and capacity publication also remain separate calls (`ContinuousBatchingSelfCheck.swift:878–886`). **Fix:** invalidate the generation before suspension and fence the entire state/gate/report/capacity transaction. |
| 3 | **FIXED** | `ContinuousBatchingSelfCheck.swift:843–844` persists the lowest crashed width; `661–662` excludes it and wider widths from later sweeps. Driver recovery regression coverage is still absent. |
| 4 | **NOT FIXED — MEDIUM** | Warmup still runs at `ContinuousBatchingSelfCheck.swift:693–696`, before journaling at `699–700`. A process-killing warmup is retried after every restart. **Fix:** durably journal warmup before inference, with recovery handling, or remove it. |
| 5 | **FIXED** | CB now acquires the same `inferenceGate` through `ModelRuntime.swift:4456–4465` that serial execution acquires at `7729` and `8448`. Holder accounting survives resizing. New admission regressions are listed below. |
| 6 | **NOT FIXED — MEDIUM** | `ContinuousBatchingSelfCheck.swift:803–806` still restores the previous record after a deferral, discarding newly completed widths; `669–670` resets each subsequent remeasurement. Busy providers can indefinitely miss higher-width correctness failures. **Fix:** persist resumable sweep progress separately from the applied decision. |
| 7 | **NOT FIXED — HIGH** | `MacProviderCLI.swift:2983–2987` still supplies a provisional grant only for `provisional_policy_entry`; owner plans have reason `owner_pinned`. With no stored prior grant, throughput-only `no_net_gain` still refuses previously serving owner-pinned CB. **Fix:** derive the model-bound positive-policy grant independently of plan reason. |
| 8 | **NOT FIXED — MEDIUM** | Autotune candidates still skip planning/driver startup, but receive default-on coverage. `ModelRuntime.swift:4709` returns `.off` for pending qualification before reaching the explicit accepted-tuple path. **Fix:** preserve explicit candidate admission outside production qualification. |

Only **new findings introduced by the final fixes** follow:

1. **MEDIUM — Shared admission introduces a conversation-lease lock inversion.**  
   [ModelRuntime.swift:4456](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4456)  
   CB obtains a conversation lease at `6736`/`7199` before acquiring the shared gate. Serial execution acquires that gate at `7729`/`8448` before requesting its lease at `7804`/`8591`. If CB holds key K while a serial request takes the last permit and waits for K, CB waits for the permit that serial cannot release. This stalls until CB’s admission timeout—30 seconds by default—and rejects otherwise runnable work.  
   **Fix:** use a consistent acquisition order and hold admission through lease completion. Add a controlled mixed-path, same-key regression.

2. **MEDIUM — Drain/client cancellation no longer covers CB admission waiting.**  
   [ModelRuntime.swift:6800](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6800), [ModelRuntime.swift:7255](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7255)  
   `withBuyerBatchAdmission` now wraps `withDrainAndClientCancellation`. While waiting for a permit, neither cancellation watcher runs. A disconnected or drain-cancelled queued request retains its queue entry, conversation lease, and in-flight registration until admission or timeout. Previously, the watchers enclosed the gate wait.  
   **Fix:** restore cancellation around the entire admission wait and check cancellation before submission. Add queued-disconnect and queued-drain regressions.

3. **MEDIUM — The schema bump discards existing grants and crash journals.**  
   [ContinuousBatchingSelfCheck.swift:387](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:387), [ContinuousBatchingSelfCheck.swift:488](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:488)  
   Restarting with a v5 file produced by the preceding candidate returns an empty store because only v6 is accepted. Previously completed grants, progress, and unfinished crash markers disappear; a crashed width can run again, and a provider without a provisional grant becomes fresh and may lose CB solely from noise.  
   **Fix:** migrate v5 records while preserving grants and crash markers. Add a v5 grant/journal migration regression.

Counts include unresolved anchored findings and new findings.

**C/H/M/L = 0/2/6/0**
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed

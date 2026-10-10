
codex
**REQUEST CHANGES — CODE gate fails.** Reviewed the complete nine-commit `origin/main...HEAD` diff through `928200167`, with new-finding attribution limited to `8703497e4`. No edits, builds, tests, or network calls.

Unresolved anchors below are **pre-existing relative to `8703497e4`**.

| Round-3 anchor | Disposition | Evidence, failure scenario, and remaining fix |
|---|---|---|
| 1 — Throughput preserves prior grant | **FIXED** | `ContinuousBatchingSelfCheck.swift:245–257` preserves the verified prior count through repeated throughput losses. |
| 2 — Swap/application fencing | **PARTIAL — HIGH** | Generation now increments before suspension at `ModelRuntime.swift:5381`. However, application checks the target at `4510`, then suspends while changing admission limits at `4514`. The driver writes the report without fencing at `ContinuousBatchingSelfCheck.swift:898`; its capacity update follows another separate check/await at `905–906`. A swap can interleave and receive stale limits, report, or capacity. **Fix:** generation-fence the entire state/admission/report/capacity transaction, including operations across actor boundaries. |
| 3 — Never retry crashed width | **FIXED** | `ContinuousBatchingSelfCheck.swift:863–864` retains the lowest crashed width; `681–682` excludes it and wider widths from subsequent sweeps. |
| 4 — Unjournaled warmup | **NOT FIXED — MEDIUM** | Warmup still executes at `ContinuousBatchingSelfCheck.swift:713–716`, before journaling at `719–720`. A process-killing warmup repeats after every restart. **Fix:** journal warmup before inference or remove it. |
| 5 — Admission resizing/CB buyer bound | **FIXED**, with a new mixed-path regression below | Semaphore holder accounting remains intact. `ModelRuntime.swift:4449` now applies the scheduler buyer limit, enforced at `ContinuousBatchScheduler.swift:5699–5704`. |
| 6 — Remeasurement progress loss | **NOT FIXED — MEDIUM** | `ContinuousBatchingSelfCheck.swift:823–826` restores the previous record after deferral, discarding completed widths; `689–690` resets the next sweep. Busy providers can indefinitely miss higher-width correctness failures. **Fix:** persist resumable sweep progress separately from the applied decision. |
| 7 — Owner-pinned provisional grant | **NOT FIXED — HIGH** | `MacProviderCLI.swift:2991` still excludes owner pins from provisional grants. Without a stored prior, an already-serving owner-pinned provider can lose CB solely from `no_net_gain`. **Fix:** derive the signed positive-policy grant independently of owner pinning; retain the verified-count clamp. |
| 8 — Explicit autotune candidate admission | **NOT FIXED — MEDIUM** | Candidates skip planning/driver startup, while `ModelRuntime.swift:4691` still returns `.off` for pending default-on qualification before honoring explicit candidate admission. **Fix:** preserve explicit accepted-candidate admission outside production qualification. |
| New finding 1 — Lease/gate inversion | **FIXED** | Removing `withBuyerBatchAdmission` removes the CB lease→shared-gate acquisition that inverted serial acquisition order. |
| New finding 2 — Queued cancellation | **FIXED** | Drain/client cancellation now directly encloses scheduler admission at `ModelRuntime.swift:6787–6788` and `7239–7245`. |
| New finding 3 — v5 store rejection | **FIXED** | `ContinuousBatchingSelfCheck.swift:396,494` accepts v5; the added `crashedSlots` field is optional. Existing grants and unfinished journals remain readable. Migration regression coverage is still absent. |

Only **new findings introduced by `8703497e4`** follow:

1. **MEDIUM — Separate serial and CB limits admit more buyer work than the served capacity.**  
   [ModelRuntime.swift:6788](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6788)

   CB submissions no longer reserve the shared `inferenceGate`. The scheduler independently admits up to k buyer rows, while serial fallback independently takes up to k permits at `7711`/`8430`. For a granted canary model, ordinary requests batch while requests with `logit_bias` serial-route (`5207`). Direct HTTP accepts both: `ProviderStatus.beginRequestIfAccepting` at `651–653` permits `.busy` and imposes no capacity ceiling.

   Consequently, k CB rows and additional serial requests can hold inference resources simultaneously, exceeding the served count and the memory envelope that shaped it. The preceding commit’s shared gate prevented this.

   **Fix:** coordinate a total buyer reservation across scheduler and serial admission while retaining bounded scheduler waiting, cancellation, and consistent conversation-lease ordering. Add a mixed direct-HTTP serial/CB regression; the new scheduler tests exercise each limit separately.

Counts include unresolved anchors and the new finding.

**C/H/M/L = 0/2/4/0**
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed

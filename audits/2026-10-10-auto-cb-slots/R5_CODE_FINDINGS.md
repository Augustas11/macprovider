
codex
**REQUEST CHANGES — CODE gate fails.** Reviewed the complete ten-commit `origin/main...HEAD` diff through `911dcc70a`. New findings below are attributed only to that commit. No edits, builds, tests, or network calls.

| Round-4 finding | Disposition | Evidence |
|---|---|---|
| 1 — Throughput preserves prior grant | **FIXED** | `ContinuousBatchingSelfCheck.swift:245–257` still preserves prior grants through throughput losses. |
| 2 — Swap/application fencing | **PARTIAL — HIGH** | State/report now move together at `ModelRuntime.swift:4519–4520`, but external mutations remain unfenced across awaits; details below. |
| 3 — Never retry crashed width | **FIXED** | `ContinuousBatchingSelfCheck.swift:683–684,872` retains and enforces the lowest crashed width. |
| 4 — Unjournaled warmup | **FIXED** | `ContinuousBatchingSelfCheck.swift:722–727` persists the unfinished-width marker before warmup inference. |
| 5 — Admission resizing/buyer bound | **FIXED** | Serial reservations now contribute to the scheduler’s total buyer occupancy at `ContinuousBatchScheduler.swift:5714–5720`. |
| 6 — Remeasurement progress loss | **FIXED** | `ContinuousBatchingSelfCheck.swift:691–695,834–835` retains completed measurements and resumes the sweep. |
| 7 — Owner-pinned provisional grant | **FIXED** | `MacProviderCLI.swift:2995` no longer excludes owner pins. The new resolution introduces a separate overgrant below. |
| 8 — Explicit autotune candidate admission | **FIXED** | `MacProviderCLI.swift:2933–2937` restores explicit accepted-tuple coverage for candidates, avoiding the production pending-state early refusal. |
| New 1 — Lease/gate inversion | **PARTIAL — HIGH** | The original shared-gate path remains removed, but its replacement reintroduces an acquisition-order cycle; new finding below. |
| New 2 — Queued cancellation | **FIXED** | Drain/client cancellation still directly wraps scheduler admission at `ModelRuntime.swift:6798–6800,7251–7255`. |
| New 3 — v5 store rejection | **FIXED** | v5 remains readable at `ContinuousBatchingSelfCheck.swift:395`; the latest commit adds a migration regression test. |
| Separate serial/CB limits exceed capacity | **FIXED** | Both serial execution paths reserve the scheduler buyer budget at `ModelRuntime.swift:7728,8450`. |

**Remaining round-4 anchor: HIGH — generation checks detect stale application after mutation.**  
[ModelRuntime.swift:4521](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4521)

`applyServedSlots` awaits the inference-gate resize, then reads the current scheduler and changes its buyer limit at `4449`. A swap can complete while the old application is suspended; its continuation can then overwrite the replacement scheduler’s limit. The generation check at `4522` returns `false` after that mutation. Capacity publication similarly has a check before its await and another afterward, without receiver-side generation validation.

**Fix:** serialize swap/application across these awaits, or make each receiver reject stale generations and preserve the intended resource identity. Add deterministic interleaving tests covering gates, scheduler limits, report, and published capacity. This is **pre-existing relative to the latest commit**, still introduced by this PR.

Only **new findings introduced by `911dcc70a`** follow:

1. **HIGH — Shared buyer reservations reintroduce the conversation-lease ordering cycle.**  
   [ModelRuntime.swift:7728](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7728)

   Serial requests reserve buyer budget before waiting for `conversationCache.begin` at `7802`; streaming does the same at `8450/8592`. CB requests acquire the conversation lease first at `6734/7195`, then await scheduler admission.

   With the budget occupied, serial requests for conversation C can queue for reservations before a CB request holding C’s lease reaches scheduler admission. When existing holders finish, FIFO gives those serial requests the budget. They wait for C’s lease, while CB waits for their budget. Filling the served budget this way stalls progress until CB admission times out, producing avoidable buyer failures.

   **Fix:** use one acquisition order across both paths, with cancellable lease waiting and preserved total-budget accounting. Add a mixed serial/CB, same-conversation regression with the budget initially full.

2. **MEDIUM — Owner pin can expand an older-runtime grant before verification.**  
   [ContinuousBatchingSelfCheck.swift:374](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:374)

   With no signed provisional entry, an older-runtime stored grant of four, an owner pin of eight, and eight scheduler rows, `min(ownerPinned ?? prior, target.maxRows)` returns eight and installs `.granted(slots: 8)`. The prior evidence authorizes only four. Startup or warm swap therefore enables unverified widths before the driver corrects or requalifies them.

   **Fix:** clamp stored carry-forward grants to `min(ownerPinned ?? prior, prior, target.maxRows)`. Preserve signed provisional grants separately. Add a regression where the owner pin exceeds the stored prior grant; the new test uses equal pin/provisional counts and misses this case.

The previously identified conversation-lease cancellation wait and warm-switch row-planning provenance limitations remain **PRE-EXISTING relative to `origin/main`**, excluded from counts. Finding 1 above is a new worsening of the lease ordering.

Counts include the unresolved anchor and the two new findings, without double-counting the inversion.

**C/H/M/L = 0/2/1/0**
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed

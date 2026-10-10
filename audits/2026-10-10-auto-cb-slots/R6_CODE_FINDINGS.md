
codex
**REQUEST CHANGES — CODE gate still fails.** Reviewed the complete eleven-commit `origin/main...HEAD` diff through `7dcb2e628`. No edits, builds, tests, or network calls.

| Round-5 finding | Disposition | Current evidence |
|---|---|---|
| Throughput preserves prior grant | **FIXED** | `ContinuousBatchingSelfCheck.swift:245–257` preserves grants through throughput losses. |
| Swap/application fencing | **PARTIAL — HIGH** | `ModelRuntime.swift:4451` captures the old scheduler; shared gate and capacity mutations remain unfenced at their receivers. See below. |
| Never retry crashed width | **FIXED** | `ContinuousBatchingSelfCheck.swift:686–687,875` retains and enforces the lowest crashed width. |
| Unjournaled warmup | **FIXED** | `ContinuousBatchingSelfCheck.swift:725–730` journals before warmup inference. |
| Admission resizing/buyer bound | **FIXED** | `AsyncSemaphore.swift:22–29` resizes in place; `ContinuousBatchScheduler.swift:5699–5704` independently caps batched buyers. |
| Remeasurement progress loss | **FIXED** | `ContinuousBatchingSelfCheck.swift:694–699,837–838` preserves completed measurements across deferrals. |
| Owner-pinned provisional grant | **FIXED** | `MacProviderCLI.swift:2995–3017` includes owner pins; resolution keeps signed provisional handling separate. |
| Explicit autotune candidate admission | **FIXED** | `MacProviderCLI.swift:2933–2937` retains explicit accepted-tuple coverage for candidates. |
| Lease/gate inversion / shared-reservation cycle | **FIXED** | Both serial paths now use only their inference gate (`ModelRuntime.swift:7727–7731,8447–8450`); external scheduler reservations are removed. |
| Queued cancellation | **FIXED** | Drain/client cancellation directly wraps scheduler submission at `ModelRuntime.swift:6804–6805,7258–7262`. |
| v5 store rejection | **FIXED** | `ContinuousBatchingSelfCheck.swift:398,499` accepts v5; migration regression coverage remains. |
| Separate serial/CB limits exceed combined capacity | **PRE-EXISTING** | Independent budgets also exist on `origin/main`; this commit removes the newly introduced shared-budget mechanism. Excluded as instructed. |
| Owner pin widens older-runtime grant | **FIXED** | `ContinuousBatchingSelfCheck.swift:373` clamps to the stored prior count. `ContinuousBatchingSelfCheckTests.swift:222` covers prior four / pin eight. |

**Remaining anchor — HIGH: stale application can still mutate shared receivers.**  
[ModelRuntime.swift:4453](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4453), [ModelRuntime.swift:4530](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4530)

Capturing the scheduler fixes the replacement-scheduler overwrite. However, swaps now retain the same inference semaphore (`ModelRuntime.swift:5413,5534`), and neither `AsyncSemaphore.resize` nor `ProviderStatus.updateServedSlots` receives or validates a generation.

A pending old-generation receiver call can execute after the newer swap’s update: actor execution across competing tasks is not a FIFO transaction. An old eight-slot resize or publication can therefore overwrite the new model’s one-slot setting. The subsequent generation check returns `false` only after mutation; it does not restore the newer value.

**Fix:** serialize application with swap completion, or enforce generations inside both shared receivers. Add deterministic interleaving coverage for the inference limit, scheduler limit, report, and advertised capacity. Current resize tests cover holders and waiters, not swap/application ordering.

This anchor is **pre-existing relative to `7dcb2e628`, introduced by this PR**, and counted once. The excluded conversation-lease waits and warm-switch planning limitations remain **PRE-EXISTING relative to `origin/main`**.

**NEW findings introduced by `7dcb2e628`: none.**

**C/H/M/L = 0/1/0/0**
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed

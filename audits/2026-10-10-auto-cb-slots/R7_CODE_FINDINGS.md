
codex
**REQUEST CHANGES — PARTIAL.** Commit `8c188f170` fixes stale inference-gate resizes, but capacity publication remains incompletely fenced.

**Round-6 anchor: PARTIAL — HIGH.**  
At [ProviderStatus.swift:747](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ProviderStatus.swift:747), `completeTargetSwap` installs the new capacity without advancing `servedSlotsStamp`, then awaits availability refresh. The new stamp arrives only afterward at [ModelRuntime.swift:5555](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5555).

During that suspension, a delayed old-generation publication still passes the receiver’s stamp check and can advertise eight slots for the new one-slot model. The final stamped update restores capacity, but cannot retract requests already routed during that window. This is the remaining anchor, counted once.

**NEW — HIGH: an older swap can publish its count using a newer swap’s generation.**  
[ModelRuntime.swift:5555](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5555)

Failure sequence:

1. Swap A saves an eight-slot count, sets runtime state to `.ready`, and suspends inside `completeTargetSwap`’s thermal await.
2. Swap B starts and completes, installing one-slot inference/scheduler limits and publishing capacity with generation B.
3. A resumes. Its new final publication uses A’s saved eight-slot count **and the live `selfCheckGeneration`, now B**.
4. `updateServedSlots` accepts the equal stamp. Advertised capacity remains eight while B’s gates admit one.

This overwrite is introduced by this commit: its parent performs no capacity mutation after `completeTargetSwap` returns.

**Fix:** capture the swap generation once; apply capacity and its generation atomically inside `completeTargetSwap`, before any await. Remove the redundant trailing publication. Fence swap completion against subsequent swaps and newer self-check decisions.

The added receiver tests cover ordered stamps, but neither interleaving above. Add deterministic coverage using the existing thermal suspension hook, asserting inference limit, scheduler limit, report, and advertised capacity.

Read-only inspection; no edits, builds, tests, or network calls. Findings pre-existing relative to `origin/main` excluded.

**C/H/M/L = 0/2/0/0**
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed

You are the CODE auditor for draft PR #1947 (Augustas11/macprovider), branch cli/auto-cb-slots, checkout /Users/augstar/macprovider-auto-slots. Review the COMPLETE diff `git diff origin/main...HEAD` (13 commits) and the code it touches. Do not edit files, do not run builds, and do not contact GitHub, Pearl, or any network service.

Context: continuous batching (CB) becomes default-on for every model the native MLX paged engine admits. Each Mac runs an idle-time on-device self-check (ContinuousBatchingSelfCheck.swift): k distinct greedy prompts of unequal length batched on the production scheduler must match each prompt run alone on the same paged engine, or first differ only at a near-tie under the load-time isolation probe rule (top-two, <=1.0 logit, cross-row leak guard); three back-to-back serial/batch repeats per k, median ratio >= 1.2x for a fresh Mac; results stored per (model sha, metallib sha, kernel id, hardware class, macOS build, MLX fork pin) in a 0600 JSON file; applied live (inference gate + ProviderStatus capacity; scheduler rows stay at the memory-fit recommendation). Owner pins are clamped to verified_k. Throughput noise never removes a prior grant (reconcile()); only correctness lowers or revokes. Progress persists; a step that crashed the process is never retried. The signed CB policy becomes revocation-only (rollout:off revokes model sha + metallib + kernel), positive entries are a provisional grant. AutoServedSlots.swift plans rows/initial served slots; Config.swift adds max_concurrency_source (owner|autotune). Native MTP admission becomes model-keyed (runtime revision/hardware/RAM/slots provenance), sidecar expires_at structural, unknown revocation state revokes nothing, load-time self-test compares MTP-on vs ordinary decode on the same engine + 1.15x speedup. Coordinator: heartbeat cb_self_check is parsed (bounded), stored on the pool provider via Registry.SetCBSelfCheck, shown in admin providers; routing unchanged. SPECs 023/031/038/039/048 amended.

Lane: CODE. Focus: correctness of the self-check driver (actor reentrancy, cancellation/yield, persistence/crash recovery, record reconciliation, prior-grant logic, applyServedSlots/inference gate replacement under load, ProviderStatus.updateServedSlots vs relay admission), effectiveContinuousBatchingMode precedence (explicit modes, pending/granted/refused, provisional, revoked), AutoServedSlots plan and the serve wiring in MacProviderCLI.swift (startup bound, stored decision, loopback/autotune candidate skips), ConfigApplier/config loader changes, native MTP admission/self-test edits, Go heartbeat parse/store. Find bugs, races, regressions to existing behavior (especially providers already serving CB: they must never lose CB due to noise), and missing tests.

Output: findings with severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, failure scenario, fix; mark "pre-existing" when relevant. End with "C/H/M/L = n/n/n/n". Gate: 0 C/H/M.

Round 8 (anchored confirmation, CODE lane only). Your round-7 findings are below. Commit "Land a swap's served count and generation together" claims to fix them: completeTargetSwap applies the count with the swap generation (servedSlotsStamp) atomically before any await and ignores older stamps; the swap captures swapGeneration once (used for gate resizes, the resolver, the scheduler limit and capacity); the trailing publication is removed; the rebuilt scheduler limit is only set when the generation is unchanged. State FIXED / NOT FIXED / PARTIAL with evidence and list only NEW findings introduced by that commit. Out of scope: findings pre-existing relative to origin/main (a full swap-vs-swap race on non-capacity provider fields predates this PR). Same scale and gate.

--- Round-7 findings ---

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

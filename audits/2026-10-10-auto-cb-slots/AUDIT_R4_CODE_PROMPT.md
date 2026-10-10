You are the CODE auditor for draft PR #1947 (Augustas11/macprovider), branch cli/auto-cb-slots, checkout /Users/augstar/macprovider-auto-slots. Review the COMPLETE diff `git diff origin/main...HEAD` (9 commits) and the code it touches. Do not edit files, do not run builds, and do not contact GitHub, Pearl, or any network service.

Context: continuous batching (CB) becomes default-on for every model the native MLX paged engine admits. Each Mac runs an idle-time on-device self-check (ContinuousBatchingSelfCheck.swift): k distinct greedy prompts of unequal length batched on the production scheduler must match each prompt run alone on the same paged engine, or first differ only at a near-tie under the load-time isolation probe rule (top-two, <=1.0 logit, cross-row leak guard); three back-to-back serial/batch repeats per k, median ratio >= 1.2x for a fresh Mac; results stored per (model sha, metallib sha, kernel id, hardware class, macOS build, MLX fork pin) in a 0600 JSON file; applied live (inference gate + ProviderStatus capacity; scheduler rows stay at the memory-fit recommendation). Owner pins are clamped to verified_k. Throughput noise never removes a prior grant (reconcile()); only correctness lowers or revokes. Progress persists; a step that crashed the process is never retried. The signed CB policy becomes revocation-only (rollout:off revokes model sha + metallib + kernel), positive entries are a provisional grant. AutoServedSlots.swift plans rows/initial served slots; Config.swift adds max_concurrency_source (owner|autotune). Native MTP admission becomes model-keyed (runtime revision/hardware/RAM/slots provenance), sidecar expires_at structural, unknown revocation state revokes nothing, load-time self-test compares MTP-on vs ordinary decode on the same engine + 1.15x speedup. Coordinator: heartbeat cb_self_check is parsed (bounded), stored on the pool provider via Registry.SetCBSelfCheck, shown in admin providers; routing unchanged. SPECs 023/031/038/039/048 amended.

Lane: CODE. Focus: correctness of the self-check driver (actor reentrancy, cancellation/yield, persistence/crash recovery, record reconciliation, prior-grant logic, applyServedSlots/inference gate replacement under load, ProviderStatus.updateServedSlots vs relay admission), effectiveContinuousBatchingMode precedence (explicit modes, pending/granted/refused, provisional, revoked), AutoServedSlots plan and the serve wiring in MacProviderCLI.swift (startup bound, stored decision, loopback/autotune candidate skips), ConfigApplier/config loader changes, native MTP admission/self-test edits, Go heartbeat parse/store. Find bugs, races, regressions to existing behavior (especially providers already serving CB: they must never lose CB due to noise), and missing tests.

Output: findings with severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, failure scenario, fix; mark "pre-existing" when relevant. End with "C/H/M/L = n/n/n/n". Gate: 0 C/H/M.

Round 4 (anchored confirmation). Your round-3 findings are below. Commit "Address the round-3 audit: cap buyer rows inside the CB scheduler" replaces the outer served-slot gate with a buyer-row limit inside ContinuousBatchScheduler (self-check rows flagged selfCheckProbe use every row; buyer rows wait in the scheduler queue while self-check rows are active), adds a swap generation to self-check targets, gives swap targets provisional grants for every model with a signed positive entry, and reads v5 stores. For each round-3 finding state FIXED / NOT FIXED / PARTIAL with evidence, and list only NEW findings introduced by that commit. Same severity scale and gate.

--- Round-3 findings ---

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

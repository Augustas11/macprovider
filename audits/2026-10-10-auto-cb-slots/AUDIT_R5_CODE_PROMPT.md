You are the CODE auditor for draft PR #1947 (Augustas11/macprovider), branch cli/auto-cb-slots, checkout /Users/augstar/macprovider-auto-slots. Review the COMPLETE diff `git diff origin/main...HEAD` (10 commits) and the code it touches. Do not edit files, do not run builds, and do not contact GitHub, Pearl, or any network service.

Context: continuous batching (CB) becomes default-on for every model the native MLX paged engine admits. Each Mac runs an idle-time on-device self-check (ContinuousBatchingSelfCheck.swift): k distinct greedy prompts of unequal length batched on the production scheduler must match each prompt run alone on the same paged engine, or first differ only at a near-tie under the load-time isolation probe rule (top-two, <=1.0 logit, cross-row leak guard); three back-to-back serial/batch repeats per k, median ratio >= 1.2x for a fresh Mac; results stored per (model sha, metallib sha, kernel id, hardware class, macOS build, MLX fork pin) in a 0600 JSON file; applied live (inference gate + ProviderStatus capacity; scheduler rows stay at the memory-fit recommendation). Owner pins are clamped to verified_k. Throughput noise never removes a prior grant (reconcile()); only correctness lowers or revokes. Progress persists; a step that crashed the process is never retried. The signed CB policy becomes revocation-only (rollout:off revokes model sha + metallib + kernel), positive entries are a provisional grant. AutoServedSlots.swift plans rows/initial served slots; Config.swift adds max_concurrency_source (owner|autotune). Native MTP admission becomes model-keyed (runtime revision/hardware/RAM/slots provenance), sidecar expires_at structural, unknown revocation state revokes nothing, load-time self-test compares MTP-on vs ordinary decode on the same engine + 1.15x speedup. Coordinator: heartbeat cb_self_check is parsed (bounded), stored on the pool provider via Registry.SetCBSelfCheck, shown in admin providers; routing unchanged. SPECs 023/031/038/039/048 amended.

Lane: CODE. Focus: correctness of the self-check driver (actor reentrancy, cancellation/yield, persistence/crash recovery, record reconciliation, prior-grant logic, applyServedSlots/inference gate replacement under load, ProviderStatus.updateServedSlots vs relay admission), effectiveContinuousBatchingMode precedence (explicit modes, pending/granted/refused, provisional, revoked), AutoServedSlots plan and the serve wiring in MacProviderCLI.swift (startup bound, stored decision, loopback/autotune candidate skips), ConfigApplier/config loader changes, native MTP admission/self-test edits, Go heartbeat parse/store. Find bugs, races, regressions to existing behavior (especially providers already serving CB: they must never lose CB due to noise), and missing tests.

Output: findings with severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, failure scenario, fix; mark "pre-existing" when relevant. End with "C/H/M/L = n/n/n/n". Gate: 0 C/H/M.

Round 5 (anchored confirmation). Your round-4 findings are below. Commit "Address the round-4 audit of the CB self-check" claims to fix them: serial buyer requests now take a slot of the scheduler buyer budget (acquireExternalBuyerRow, FIFO with batched rows), the apply transaction is generation-fenced inside ModelRuntime.applyContinuousBatchingSelfCheck (state, report, gates, scheduler limit, published capacity), owner-pinned providers keep provisional grants, autotune candidates keep explicit tuple coverage, the warm-up is journaled, and yielded re-measurements resume. Findings you marked pre-existing relative to origin/main (conversation-lease waits before scheduler admission; warm-switch row planning tied to generated-context provenance) are out of scope unless this PR makes them worse. For each round-4 finding state FIXED / NOT FIXED / PARTIAL / PRE-EXISTING with evidence, and list only NEW findings introduced by that commit. Same scale and gate.

--- Round-4 findings ---

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

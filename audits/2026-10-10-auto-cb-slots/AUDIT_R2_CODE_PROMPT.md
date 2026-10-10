You are the CODE auditor for draft PR #1947 (Augustas11/macprovider), branch cli/auto-cb-slots, checkout /Users/augstar/macprovider-auto-slots. Review the COMPLETE diff `git diff origin/main...HEAD` (6 commits) and the code it touches. Do not edit files, do not run builds, and do not contact GitHub, Pearl, or any network service.

Context: continuous batching (CB) becomes default-on for every model the native MLX paged engine admits. Each Mac runs an idle-time on-device self-check (ContinuousBatchingSelfCheck.swift): k distinct greedy prompts of unequal length batched on the production scheduler must match each prompt run alone on the same paged engine, or first differ only at a near-tie under the load-time isolation probe rule (top-two, <=1.0 logit, cross-row leak guard); three back-to-back serial/batch repeats per k, median ratio >= 1.2x for a fresh Mac; results stored per (model sha, metallib sha, kernel id, hardware class, macOS build, MLX fork pin) in a 0600 JSON file; applied live (inference gate + ProviderStatus capacity; scheduler rows stay at the memory-fit recommendation). Owner pins are clamped to verified_k. Throughput noise never removes a prior grant (reconcile()); only correctness lowers or revokes. Progress persists; a step that crashed the process is never retried. The signed CB policy becomes revocation-only (rollout:off revokes model sha + metallib + kernel), positive entries are a provisional grant. AutoServedSlots.swift plans rows/initial served slots; Config.swift adds max_concurrency_source (owner|autotune). Native MTP admission becomes model-keyed (runtime revision/hardware/RAM/slots provenance), sidecar expires_at structural, unknown revocation state revokes nothing, load-time self-test compares MTP-on vs ordinary decode on the same engine + 1.15x speedup. Coordinator: heartbeat cb_self_check is parsed (bounded), stored on the pool provider via Registry.SetCBSelfCheck, shown in admin providers; routing unchanged. SPECs 023/031/038/039/048 amended.

Lane: CODE. Focus: correctness of the self-check driver (actor reentrancy, cancellation/yield, persistence/crash recovery, record reconciliation, prior-grant logic, applyServedSlots/inference gate replacement under load, ProviderStatus.updateServedSlots vs relay admission), effectiveContinuousBatchingMode precedence (explicit modes, pending/granted/refused, provisional, revoked), AutoServedSlots plan and the serve wiring in MacProviderCLI.swift (startup bound, stored decision, loopback/autotune candidate skips), ConfigApplier/config loader changes, native MTP admission/self-test edits, Go heartbeat parse/store. Find bugs, races, regressions to existing behavior (especially providers already serving CB: they must never lose CB due to noise), and missing tests.

Output: findings with severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, failure scenario, fix; mark "pre-existing" when relevant. End with "C/H/M/L = n/n/n/n". Gate: 0 C/H/M.

Round 2 (anchored). Your round-1 findings are below. Commit "Address the round-1 audit of the CB self-check" and the follow-ups claim to fix them. For each round-1 finding state FIXED / NOT FIXED / PARTIAL with evidence, then list any NEW findings introduced by the fixes. Same severity scale and gate.

--- Round-1 findings ---

codex
**REQUEST CHANGES — gate fails.** Reviewed the complete four-commit diff and touched code. No files edited, builds/tests run, or network services contacted.

1. **HIGH — Throughput alone revokes prior CB grants.** [ContinuousBatchingSelfCheck.swift:243](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:243)  
   Three consecutive gains below 1.0 produce `no_net_gain_confirmed` and serve serially, despite passing correctness. Sustained background load or thermal noise can therefore remove an existing grant. **Fix:** preserve prior grants through all throughput-only outcomes; remove this exception from code, SPEC, and `testOnlyRepeatedClearLossesTakeAPriorGrant`.

2. **HIGH — Native-MTP timing measures cached replay.** [ModelRuntime.swift:2935](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2935), [ModelRuntime.swift:3615](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:3615)  
   Both MTP repetitions reuse `native-mtp-selftest-<challengeID>`. The scheduler returns its cached terminal result on repetition two; taking the minimum duration can qualify MTP even when actual inference is slower than ordinary decode. The fixed ID is **pre-existing**; the repeated timing bypass is introduced here. **Fix:** use distinct IDs per execution and test that slower MTP cannot qualify through replay.

3. **HIGH — Direct HTTP can exceed `verified_k`.** [ModelRuntime.swift:4425](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4425), [HTTPServer.swift:923](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/HTTPServer.swift:923)  
   `applyServedSlots` limits only the serial semaphore. Batched HTTP requests bypass it, while `beginRequestIfAccepting` checks pause/drain rather than capacity. With scheduler rows 16 and correctness verified only through 5, six simultaneous HTTP requests can still exercise the rejected six-row shape. **Fix:** enforce the served limit on all buyer batch admissions, retaining a separate self-check path. Add streaming and non-streaming HTTP concurrency regressions.

4. **HIGH — Warm swaps retain unqualified served capacity.** [ModelRuntime.swift:5331](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5331)  
   Swapping resets qualification to `.pending`, but retains the previous capacity or installs `adoptionKnobs.maxBatch`. An autotuned provider swapping from eight-slot A to fresh B can advertise/admit eight serial requests instead of B’s pending one-slot count. Continuous traffic can postpone qualification indefinitely. **Fix:** apply B’s stored/provisional/pending served decision before marking the swap ready. Test swaps with and without adoption knobs.

5. **HIGH — A provisional grant leaks across models.** [ContinuousBatchingSelfCheck.swift:731](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:731)  
   The driver’s startup `provisionalSlots` is included in reconciliation for every subsequent target. After starting with provisionally granted A, fresh B can fail the 1.2× threshold yet receive `kept_prior_grant_no_net_gain` using A’s grant. **Fix:** bind provisional state to the model artifact and resolve it for the current target. Add an A-to-B driver regression.

6. **HIGH — Applying a decision is not fenced against model swaps.** [ContinuousBatchingSelfCheck.swift:773](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:773)  
   The target check in `finish` occurs before another actor hop; stored-result application has no corresponding check. A swap can commit between target lookup/check and application, allowing A’s grant or refusal to overwrite B’s state and capacity. **Fix:** pass the expected target/generation into an atomic runtime application operation, reject stale results, and fence report/capacity updates consistently. Add a controlled swap-interleaving test.

7. **HIGH — Startup restores capacity above the memory bound.** [MacProviderCLI.swift:2971](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:2971)  
   `startupBound` can lower runtime rows, but subsequent application reuses stale `plan.initialServed` and writes it back into resolved configuration. A provisional eight-slot plan lowered to two runtime rows can consequently advertise eight slots while the actual gate permits two. **Fix:** clamp/recompute initial served capacity after the startup bound and advertise exactly the applied count. Add a provisional-plan startup-bound regression.

8. **MEDIUM — Re-measurement crashes are retried.** [ContinuousBatchingSelfCheck.swift:511](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:511)  
   Re-measurement persists both the old decision and `inProgressSlots`. Restart prioritizes the decision, ignores the crash marker, and starts the overdue re-measurement again. **Fix:** recover unfinished attempts before applying decisions; preserve the prior grant separately and persist cancellation cleanup. Test restart with both fields populated.

9. **MEDIUM — Crash journaling does not protect every execution.** [ContinuousBatchingSelfCheck.swift:615](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:615), [ContinuousBatchingSelfCheck.swift:563](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:563)  
   Alone-prompt executions run before the crash marker is persisted. Moreover, `save` logs persistence failures and continues executing the risky step. Either case permits a process-killing step to repeat after restart. **Fix:** durably mark every inference step before execution and defer qualification if that write fails. Add alone-step crash and persistence-failure tests.

10. **MEDIUM — Serial baseline ignores cancellation.** [ModelRuntime.swift:9057](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:9057)  
    The blocking callback ignores its cancellation token and always returns `.more`. When a buyer arrives, the task group cancels the baseline but must still wait for generation to finish, holding inference capacity through the token limit. **Fix:** stop generation cooperatively and reject cancelled measurements. Add a buyer-arrival cancellation test.

11. **MEDIUM — Semaphore replacement loses outstanding-permit accounting.** [ModelRuntime.swift:4426](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4426)  
    Requests holding or waiting on the old semaphore continue there while new requests receive the fresh semaphore’s full capacity. A live reduction can therefore admit beyond the new limit. **Fix:** resize a persistent gate while preserving outstanding permits and waiters, or fence/drain before replacement. Test application while requests hold and await permits.

12. **MEDIUM — Live capacity changes omit immediate publication.** [ProviderStatus.swift:708](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ProviderStatus.swift:708)  
    `updateServedSlots` replaces capacity without invoking availability refresh or the request-capacity handler. Relay admission sees the new limit immediately, but coordinator routing retains the old slots until another refresh/heartbeat, potentially dispatching requests that the relay now rejects. **Fix:** publish the capacity transition through the existing refresh path. Test an idle capacity reduction with a registered handler.

13. **LOW — Coordinator drops the MLX runtime identity.** [provider.go:491](/Users/augstar/macprovider-auto-slots/phase4-coordinator/internal/pool/provider.go:491)  
    Swift emits `runtime_build`, but Go silently discards it, so admin reports cannot distinguish the full qualification key across fork-pin changes. **Fix:** add the field to storage, bounds validation, cloning, and heartbeat tests.

C/H/M/L = 0/7/5/1
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed

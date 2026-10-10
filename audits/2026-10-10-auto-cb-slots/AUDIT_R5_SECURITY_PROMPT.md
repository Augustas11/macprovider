You are the SECURITY auditor for draft PR #1947 (Augustas11/macprovider), branch cli/auto-cb-slots, checkout /Users/augstar/macprovider-auto-slots. Review the COMPLETE diff `git diff origin/main...HEAD` (10 commits) and the code it touches. Do not edit files, do not run builds, and do not contact GitHub, Pearl, or any network service.

Context: continuous batching (CB) becomes default-on for every model the native MLX paged engine admits. Each Mac runs an idle-time on-device self-check (ContinuousBatchingSelfCheck.swift): k distinct greedy prompts of unequal length batched on the production scheduler must match each prompt run alone on the same paged engine, or first differ only at a near-tie under the load-time isolation probe rule (top-two, <=1.0 logit, cross-row leak guard); three back-to-back serial/batch repeats per k, median ratio >= 1.2x for a fresh Mac; results stored per (model sha, metallib sha, kernel id, hardware class, macOS build, MLX fork pin) in a 0600 JSON file; applied live (inference gate + ProviderStatus capacity; scheduler rows stay at the memory-fit recommendation). Owner pins are clamped to verified_k. Throughput noise never removes a prior grant (reconcile()); only correctness lowers or revokes. Progress persists; a step that crashed the process is never retried. The signed CB policy becomes revocation-only (rollout:off revokes model sha + metallib + kernel), positive entries are a provisional grant. AutoServedSlots.swift plans rows/initial served slots; Config.swift adds max_concurrency_source (owner|autotune). Native MTP admission becomes model-keyed (runtime revision/hardware/RAM/slots provenance), sidecar expires_at structural, unknown revocation state revokes nothing, load-time self-test compares MTP-on vs ordinary decode on the same engine + 1.15x speedup. Coordinator: heartbeat cb_self_check is parsed (bounded), stored on the pool provider via Registry.SetCBSelfCheck, shown in admin providers; routing unchanged. SPECs 023/031/038/039/048 amended.

Lane: SECURITY. Focus: trust boundaries changed by making CB default-on and the signed policy revocation-only (can an attacker who blocks the policy/revocation feed keep a revoked tuple serving? is that acceptable given the operator decision "absent = no revocations"?), cross-request isolation risk from accepting near-tie divergences (could a real cross-row leak pass the near-tie rule?), native MTP admission relaxations (model-keyed, no expiry, unknown revocations), the local cb-self-check.json store (path, permissions, symlink/TOCTOU, tampering to raise slots beyond memory fit or force grants), heartbeat cb_self_check parsing in the coordinator (DoS, injection into logs/admin views), and any secret or ops-internal leakage in code/specs (the repo is public).

Output: findings with severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, exploit scenario, fix; mark "pre-existing" when relevant. End with "C/H/M/L = n/n/n/n". Gate: 0 C/H/M.

Round 5 (anchored confirmation). Your round-4 findings are below. Commit "Address the round-4 audit of the CB self-check" claims to fix them: serial buyer requests now take a slot of the scheduler buyer budget (acquireExternalBuyerRow, FIFO with batched rows), the apply transaction is generation-fenced inside ModelRuntime.applyContinuousBatchingSelfCheck (state, report, gates, scheduler limit, published capacity), owner-pinned providers keep provisional grants, autotune candidates keep explicit tuple coverage, the warm-up is journaled, and yielded re-measurements resume. Findings you marked pre-existing relative to origin/main (conversation-lease waits before scheduler admission; warm-switch row planning tied to generated-context provenance) are out of scope unless this PR makes them worse. For each round-4 finding state FIXED / NOT FIXED / PARTIAL / PRE-EXISTING with evidence, and list only NEW findings introduced by that commit. Same scale and gate.

--- Round-4 findings ---

codex
Security gate **FAILS: 1 MEDIUM**, plus the carried LOW.

Reviewed the complete local `origin/main...HEAD` range: **9 commits**, through `928200167`, including `8703497e4`. No edits, builds, tests, or network calls.

Round-3 confirmation:

| Concern | Status | Evidence |
|---|---|---|
| Skipped isolation widths | **FIXED** | [SelfCheck:717](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:717) checks every integer width. |
| Blocking cache open / parent protection | **PARTIAL** | [read():483](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:483) retains nonblocking, no-follow descriptor validation. **Carried LOW, pre-existing to this commit:** [write():499](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:499) still trusts the parent path. Someone able to modify a non-sticky parent can delete the journal and permit crash-step retries. Fix: validate a private, provider-owned parent and use descriptor-relative operations. |
| Revocation suppression | **FIXED as documented acceptance** | [SPEC-038:1050](/Users/augstar/macprovider-auto-slots/specs/SPEC-038-continuous-batching.md:1050) explicitly accepts feed suppression preserving eligibility. This is threat acceptance, not mitigation. |
| Near-tie limitation | **FIXED as documented acceptance** | [divergence():4559](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4559) retains the other-row guard and top-two checks; the residual contamination case remains documented. |
| CB admission queue bounds/timeouts | **FIXED** | [submit():2226](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:2226) bounds admission; [admitWaitingRows():4862](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:4862) leaves blocked buyers in the scheduler queue with deadlines. |
| Prior-grant preservation | **FIXED for the reported migration concern** | [reconcile():244](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:244) preserves grants through throughput losses; v5 now decodes. |
| Swap fencing / grant resolution | **FIXED for the summarized concern** | [apply():4508](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4508) compares the full generation-bearing target; [swap resolution:5509](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5509) resolves grants before publishing readiness. |
| Serial/batched admission accounting | **NOT FIXED — regressed** | CB submissions no longer acquire the semaphore used by serial inference. See the new finding below. |
| Crash/progress handling | **FIXED for the reported migration concern** | [run():599](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:599) recovers unfinished steps; [finish():863](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:863) persists the crash boundary. |
| v5 schema rejection | **FIXED** | [readableSchemaVersions:396](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:396) accepts v5. Its missing optional `crashed_slots` decodes without discarding decisions or unfinished-step markers. |

**NEW — MEDIUM: Separate serial and CB limits permit combined buyer work beyond the served memory envelope.**

Locations: [ModelRuntime.swift:6787](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6787), [ContinuousBatchScheduler.swift:5704](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:5704), [ModelRuntime.swift:7711](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7711).

The commit removes CB’s shared `inferenceGate` acquisition. The replacement counts only scheduler rows, while serial fallback independently acquires up to the same served limit. Direct HTTP admission [checks pause/drain state only](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ProviderStatus.swift:651).

**Exploit scenario:** On a canary/default-on provider serving k slots, a caller with direct HTTP access fills k CB rows, then submits serial-routed work—for example, Harmony structured/tool requests or qualifying cached-turn fallbacks. Serial inference can allocate its contiguous KV cache while the admitted CB rows retain theirs. Model execution serialization does not release those resident caches. Combined residency can therefore exceed the k-slot memory-fit envelope, creating memory-pressure/OOM denial of service. This is introduced by `8703497e4`; the preceding candidate shared the permit count.

**Fix:** Account serial fallback reservations and CB buyer rows against one shared, bounded admission budget, while preserving scheduler queue deadlines, cancellation, and safe conversation-lease ordering. Add a mixed serial/CB regression check.

No other new security findings from that commit.

C/H/M/L = 0/0/1/1
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed

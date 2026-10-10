You are the SECURITY auditor for draft PR #1947 (Augustas11/macprovider), branch cli/auto-cb-slots, checkout /Users/augstar/macprovider-auto-slots. Review the COMPLETE diff `git diff origin/main...HEAD` (9 commits) and the code it touches. Do not edit files, do not run builds, and do not contact GitHub, Pearl, or any network service.

Context: continuous batching (CB) becomes default-on for every model the native MLX paged engine admits. Each Mac runs an idle-time on-device self-check (ContinuousBatchingSelfCheck.swift): k distinct greedy prompts of unequal length batched on the production scheduler must match each prompt run alone on the same paged engine, or first differ only at a near-tie under the load-time isolation probe rule (top-two, <=1.0 logit, cross-row leak guard); three back-to-back serial/batch repeats per k, median ratio >= 1.2x for a fresh Mac; results stored per (model sha, metallib sha, kernel id, hardware class, macOS build, MLX fork pin) in a 0600 JSON file; applied live (inference gate + ProviderStatus capacity; scheduler rows stay at the memory-fit recommendation). Owner pins are clamped to verified_k. Throughput noise never removes a prior grant (reconcile()); only correctness lowers or revokes. Progress persists; a step that crashed the process is never retried. The signed CB policy becomes revocation-only (rollout:off revokes model sha + metallib + kernel), positive entries are a provisional grant. AutoServedSlots.swift plans rows/initial served slots; Config.swift adds max_concurrency_source (owner|autotune). Native MTP admission becomes model-keyed (runtime revision/hardware/RAM/slots provenance), sidecar expires_at structural, unknown revocation state revokes nothing, load-time self-test compares MTP-on vs ordinary decode on the same engine + 1.15x speedup. Coordinator: heartbeat cb_self_check is parsed (bounded), stored on the pool provider via Registry.SetCBSelfCheck, shown in admin providers; routing unchanged. SPECs 023/031/038/039/048 amended.

Lane: SECURITY. Focus: trust boundaries changed by making CB default-on and the signed policy revocation-only (can an attacker who blocks the policy/revocation feed keep a revoked tuple serving? is that acceptable given the operator decision "absent = no revocations"?), cross-request isolation risk from accepting near-tie divergences (could a real cross-row leak pass the near-tie rule?), native MTP admission relaxations (model-keyed, no expiry, unknown revocations), the local cb-self-check.json store (path, permissions, symlink/TOCTOU, tampering to raise slots beyond memory fit or force grants), heartbeat cb_self_check parsing in the coordinator (DoS, injection into logs/admin views), and any secret or ops-internal leakage in code/specs (the repo is public).

Output: findings with severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, exploit scenario, fix; mark "pre-existing" when relevant. End with "C/H/M/L = n/n/n/n". Gate: 0 C/H/M.

Round 4 (anchored confirmation). Your round-3 findings are below. Commit "Address the round-3 audit: cap buyer rows inside the CB scheduler" replaces the outer served-slot gate with a buyer-row limit inside ContinuousBatchScheduler (self-check rows flagged selfCheckProbe use every row; buyer rows wait in the scheduler queue while self-check rows are active), adds a swap generation to self-check targets, gives swap targets provisional grants for every model with a signed positive entry, and reads v5 stores. For each round-3 finding state FIXED / NOT FIXED / PARTIAL with evidence, and list only NEW findings introduced by that commit. Same severity scale and gate.

--- Round-3 findings ---

codex
Security gate **PASSES: 0 CRITICAL/HIGH/MEDIUM**, with one carried LOW and one new LOW.

Reviewed the complete local `origin/main...HEAD` diff through `ab97b409a` and relevant callers. The local range contains **7 commits**, rather than the stated 8. No edits, builds, tests, or network calls.

Round-2 findings and summarized CODE concerns:

- **Skipped isolation widths — FIXED.** [ContinuousBatchingSelfCheck.swift:697](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:697) checks every integer width; throughput selection remains restricted to ladder rungs.

- **Blocking cache open / parent-directory protection — PARTIAL.** [ContinuousBatchingSelfCheck.swift:477](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:477) retains nonblocking, no-follow open and descriptor validation. The **carried LOW** remains at [write():493](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:493): an attacker with write access to a non-sticky parent directory can delete the journal and permit crash-step retries. Fix: validate a private, provider-owned parent and operate relative to its descriptor.

- **Revocation suppression — FIXED as documented threat acceptance.** [SPEC-038:1049](/Users/augstar/macprovider-auto-slots/specs/SPEC-038-continuous-batching.md:1049) explicitly accepts suppression; unknown MTP revocations likewise revoke nothing. Blocking the feeds can preserve eligibility. This remains consistent with the operator decision, not a technical mitigation.

- **Near-tie limitation — FIXED as documented threat acceptance.** [ModelRuntime.swift:4584](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4584) retains the other-row-token guard and top-two/margin checks. Contamination landing on an otherwise permissible token can still pass; that limitation remains documented.

- **CB admission bypasses queue bounds/timeouts — FIXED.** [ModelRuntime.swift:4455](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4455) uses bounded admission; [AsyncSemaphore.swift:42](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/AsyncSemaphore.swift:42) enforces waiter limits and timeout removal.

- **Prior-grant preservation — PARTIAL.** [reconcile():241](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:241) no longer lowers grants for repeated throughput losses. Preservation across the previous candidate’s v5 store is affected by the new finding below.

- **Swap fencing and grant resolution — FIXED for the summarized concern.** [ModelRuntime.swift:5528](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5528) resolves the loaded target before publishing swap completion. [applyContinuousBatchingSelfCheck():4529](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4529) rejects results for a different target key.

- **Serial/batched admission accounting — FIXED.** CB uses the same `inferenceGate` as serial inference, resized in place rather than replaced.

- **Crash/progress handling — PARTIAL.** [ContinuousBatchingSelfCheck.swift:843](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:843) persists the lowest crashed width, and [measure():661](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:661) excludes it and wider widths. Migration remains deficient.

**NEW finding introduced by the fixes:**

- **LOW — Schema bump discards previous-candidate crash journals.**  
  [ContinuousBatchingSelfCheck.swift:387](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:387) changes v5 to v6; [read():488](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:488) rejects v5 entirely.

  **Failure scenario:** A previous PR candidate dies at width k and leaves a v5 `in_progress_slots` journal. Updating to this candidate with the same self-check key discards that journal, allowing k to run and crash again. Stored grants and correctness refusals are also forgotten. This is limited to stores created by earlier PR candidates; v5 is absent from the base branch.

  **Fix:** Migrate v5 records, preserving progress, decisions and unfinished-step markers. Recover an unfinished width into the persistent crash bound before permitting further measurements.

No new security findings in MTP signature/artifact validation, bounded heartbeat parsing/admin serialization, or public secret leakage. Counts include the carried directory LOW.

C/H/M/L = 0/0/0/2
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed

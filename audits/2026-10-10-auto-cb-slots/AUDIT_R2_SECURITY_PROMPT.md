You are the SECURITY auditor for draft PR #1947 (Augustas11/macprovider), branch cli/auto-cb-slots, checkout /Users/augstar/macprovider-auto-slots. Review the COMPLETE diff `git diff origin/main...HEAD` (6 commits) and the code it touches. Do not edit files, do not run builds, and do not contact GitHub, Pearl, or any network service.

Context: continuous batching (CB) becomes default-on for every model the native MLX paged engine admits. Each Mac runs an idle-time on-device self-check (ContinuousBatchingSelfCheck.swift): k distinct greedy prompts of unequal length batched on the production scheduler must match each prompt run alone on the same paged engine, or first differ only at a near-tie under the load-time isolation probe rule (top-two, <=1.0 logit, cross-row leak guard); three back-to-back serial/batch repeats per k, median ratio >= 1.2x for a fresh Mac; results stored per (model sha, metallib sha, kernel id, hardware class, macOS build, MLX fork pin) in a 0600 JSON file; applied live (inference gate + ProviderStatus capacity; scheduler rows stay at the memory-fit recommendation). Owner pins are clamped to verified_k. Throughput noise never removes a prior grant (reconcile()); only correctness lowers or revokes. Progress persists; a step that crashed the process is never retried. The signed CB policy becomes revocation-only (rollout:off revokes model sha + metallib + kernel), positive entries are a provisional grant. AutoServedSlots.swift plans rows/initial served slots; Config.swift adds max_concurrency_source (owner|autotune). Native MTP admission becomes model-keyed (runtime revision/hardware/RAM/slots provenance), sidecar expires_at structural, unknown revocation state revokes nothing, load-time self-test compares MTP-on vs ordinary decode on the same engine + 1.15x speedup. Coordinator: heartbeat cb_self_check is parsed (bounded), stored on the pool provider via Registry.SetCBSelfCheck, shown in admin providers; routing unchanged. SPECs 023/031/038/039/048 amended.

Lane: SECURITY. Focus: trust boundaries changed by making CB default-on and the signed policy revocation-only (can an attacker who blocks the policy/revocation feed keep a revoked tuple serving? is that acceptable given the operator decision "absent = no revocations"?), cross-request isolation risk from accepting near-tie divergences (could a real cross-row leak pass the near-tie rule?), native MTP admission relaxations (model-keyed, no expiry, unknown revocations), the local cb-self-check.json store (path, permissions, symlink/TOCTOU, tampering to raise slots beyond memory fit or force grants), heartbeat cb_self_check parsing in the coordinator (DoS, injection into logs/admin views), and any secret or ops-internal leakage in code/specs (the repo is public).

Output: findings with severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, exploit scenario, fix; mark "pre-existing" when relevant. End with "C/H/M/L = n/n/n/n". Gate: 0 C/H/M.

Round 2 (anchored). Your round-1 findings are below. Commit "Address the round-1 audit of the CB self-check" and the follow-ups claim to fix them. For each round-1 finding state FIXED / NOT FIXED / PARTIAL with evidence, then list any NEW findings introduced by the fixes. Same severity scale and gate.

--- Round-1 findings ---

codex
Security gate **FAILS: 1 MEDIUM finding**. Reviewed the complete four-commit diff and relevant callers locally; no edits, builds, or network calls.

1. **MEDIUM — Isolation qualification skips production row counts.**  
   [ContinuousBatchingSelfCheck.swift:169](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:169) uses the throughput calibration ladder: 2–8, 12, 16, etc. Line 181 treats the highest passing rung as `verifiedSlots`, while [ContinuousBatchScheduler.swift:4449](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:4449) forwards the actual current row count.
   
   **Exploit scenario:** A grant of 12 permits nine, ten, or eleven concurrent rows without qualifying those shapes. A buyer can control overlapping requests and reach a row-count-specific isolation defect that the self-check never exercised. This is an admission gap; no actual kernel leak was demonstrated.
   
   **Fix:** Check every integer depth through the maximum grant. Require a contiguous passing prefix, update the regression that currently expects skipped depths, and invalidate cached decisions produced by the sparse check. The sparse throughput ladder is pre-existing; its use as an isolation authorization is new.

2. **LOW — Store validation happens after a potentially blocking open.**  
   [ContinuousBatchingSelfCheck.swift:426](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:426) opens the path before checking its type and owner.
   
   **Exploit scenario:** If an operator places the config in a directory writable by another local user, that user can create `cb-self-check.json` as a FIFO. `open(O_RDONLY)` blocks before `fstat` can reject it, hanging startup or the driver. The default private-directory deployment limits exposure.
   
   **Fix:** Open with `O_NONBLOCK | O_NOFOLLOW`, then validate the descriptor; verify the parent directory’s ownership and write permissions. Bound file size before decoding. New finding.

3. **INFO — Revocation suppression remains possible by accepted policy.**  
   [ContinuousBatchingSignedPolicy.swift:586](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSignedPolicy.swift:586) substitutes empty coverage on fetch failure; [ModelRuntime.swift:10005](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:10005) substitutes an empty MTP revocation set when loading fails.
   
   **Scenario:** Feed suppression can keep an otherwise revoked tuple eligible when its revocation is unavailable. This implements the explicit “absent = no revocations” decision and is not counted as a blocking defect. A known verified revocation of the selected tuple is enforced.
   
   **Fix:** Document this threat acceptance. A persistent signed deny set would strengthen it without introducing feature expiry, if policy is later changed.

4. **INFO — Near-tie acceptance is a heuristic, not proof against every leak.**  
   [ModelRuntime.swift:4516](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4516) checks other rows’ alone-token IDs at the first divergence; [ContinuousBatchingSelfCheck.swift:687](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:687) accepts the row when that divergence passes.
   
   **Scenario:** Cross-row contamination that selects an allowed top-two token without matching another row’s checked token—or affects the continuation after an accepted tie—can escape this heuristic. This matches the requested rule; no concrete scheduler leak was established.
   
   **Fix:** Describe the limitation accurately; independent same-prefix continuation checks could strengthen detection.

No additional findings in bounded heartbeat parsing, admin serialization, MTP admission signature/artifact checks, or public secret/ops-internal leakage. Stored grants remain clamped to scheduler rows; same-user cache tampering is within the existing operator trust boundary.

C/H/M/L = 0/0/1/1
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed

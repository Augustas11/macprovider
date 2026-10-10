You are the SECURITY auditor for draft PR #1947 (Augustas11/macprovider), branch cli/auto-cb-slots, checkout /Users/augstar/macprovider-auto-slots. Review the COMPLETE diff `git diff origin/main...HEAD` (8 commits) and the code it touches. Do not edit files, do not run builds, and do not contact GitHub, Pearl, or any network service.

Context: continuous batching (CB) becomes default-on for every model the native MLX paged engine admits. Each Mac runs an idle-time on-device self-check (ContinuousBatchingSelfCheck.swift): k distinct greedy prompts of unequal length batched on the production scheduler must match each prompt run alone on the same paged engine, or first differ only at a near-tie under the load-time isolation probe rule (top-two, <=1.0 logit, cross-row leak guard); three back-to-back serial/batch repeats per k, median ratio >= 1.2x for a fresh Mac; results stored per (model sha, metallib sha, kernel id, hardware class, macOS build, MLX fork pin) in a 0600 JSON file; applied live (inference gate + ProviderStatus capacity; scheduler rows stay at the memory-fit recommendation). Owner pins are clamped to verified_k. Throughput noise never removes a prior grant (reconcile()); only correctness lowers or revokes. Progress persists; a step that crashed the process is never retried. The signed CB policy becomes revocation-only (rollout:off revokes model sha + metallib + kernel), positive entries are a provisional grant. AutoServedSlots.swift plans rows/initial served slots; Config.swift adds max_concurrency_source (owner|autotune). Native MTP admission becomes model-keyed (runtime revision/hardware/RAM/slots provenance), sidecar expires_at structural, unknown revocation state revokes nothing, load-time self-test compares MTP-on vs ordinary decode on the same engine + 1.15x speedup. Coordinator: heartbeat cb_self_check is parsed (bounded), stored on the pool provider via Registry.SetCBSelfCheck, shown in admin providers; routing unchanged. SPECs 023/031/038/039/048 amended.

Lane: SECURITY. Focus: trust boundaries changed by making CB default-on and the signed policy revocation-only (can an attacker who blocks the policy/revocation feed keep a revoked tuple serving? is that acceptable given the operator decision "absent = no revocations"?), cross-request isolation risk from accepting near-tie divergences (could a real cross-row leak pass the near-tie rule?), native MTP admission relaxations (model-keyed, no expiry, unknown revocations), the local cb-self-check.json store (path, permissions, symlink/TOCTOU, tampering to raise slots beyond memory fit or force grants), heartbeat cb_self_check parsing in the coordinator (DoS, injection into logs/admin views), and any secret or ops-internal leakage in code/specs (the repo is public).

Output: findings with severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, exploit scenario, fix; mark "pre-existing" when relevant. End with "C/H/M/L = n/n/n/n". Gate: 0 C/H/M.

Round 3 (anchored, final). Your round-2 findings are below (the CODE lane round-2 output was cut off; its summary named prior-grant preservation, swap fencing, admission accounting across serial/batched gates, and crash/progress handling). Commit "Address the round-2 audit of the CB self-check" claims to fix them. For each, state FIXED / NOT FIXED / PARTIAL with evidence, then list only NEW findings the fixes introduced. Same severity scale and gate.

--- Round-2 findings ---

codex
Security gate **PASSES: 0 CRITICAL/HIGH/MEDIUM**, with two LOW findings. Reviewed the complete six-commit `origin/main...HEAD` diff through `a1d80863c` and relevant callers. No edits, builds, or network calls.

Round-1 findings:

1. **MEDIUM — Skipped isolation widths: FIXED.**  
   [ContinuousBatchingSelfCheck.swift:663](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:663) checks every integer width from 2 through the maximum, stopping on nonconformance. Throughput selection remains restricted to ladder rungs. [Schema v5:358](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:358) invalidates sparse-check cached grants; served slots remain clamped to the verified prefix and scheduler rows.

2. **LOW — Potentially blocking cache open: PARTIAL.**  
   [ContinuousBatchingSelfCheck.swift:444](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:444) adds `O_NONBLOCK | O_NOFOLLOW`, descriptor validation, and a size check before decoding. **The original FIFO hang is fixed.**

   Remaining LOW: [write():460](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:460) does not validate parent-directory ownership or write permissions. In a non-sticky directory writable by another local user, that user can delete the crash journal, causing restart to retry a width intended to remain skipped. The file ownership check prevents straightforward forged grants.

   **Fix:** Validate a private, provider-owned parent directory and avoid symlink traversal; perform file operations relative to its validated descriptor. Carried from round 1.

3. **INFO — Revocation suppression: FIXED as documented threat acceptance.**  
   [SPEC-038:1049](/Users/augstar/macprovider-auto-slots/specs/SPEC-038-continuous-batching.md:1049) explicitly acknowledges feed suppression; [SPEC-048:1025](/Users/augstar/macprovider-auto-slots/specs/SPEC-048-native-mtp-serving.md:1025) documents unknown MTP revocations. Suppression can still preserve eligibility, consistent with “absent = no revocations.” Verified matching revocations remain enforced. This resolves the documentation request, not the underlying risk.

4. **INFO — Near-tie heuristic limitation: FIXED as documented threat acceptance.**  
   [SPEC-038:1052](/Users/augstar/macprovider-auto-slots/specs/SPEC-038-continuous-batching.md:1052) names the undetected-contamination case. [ModelRuntime.swift:4551](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4551) retains the top-two, margin, and other-row-token checks. The heuristic limitation persists; no concrete cross-row leak was demonstrated.

NEW finding introduced by the fixes:

- **LOW — Buyer gate bypasses scheduler queue bounds and timeout.**  
  [ModelRuntime.swift:6758](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6758) and [the streaming path:7217](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7217) acquire `buyerBatchGate` before scheduler admission. [AsyncSemaphore.swift:51](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/AsyncSemaphore.swift:51) appends waiters without a bound or deadline.

  **Exploit:** A local process saturates served slots and opens many loopback completion requests. Prepared requests accumulate outside scheduler queue limits and timeout accounting, consuming memory. The endpoint is loopback-only and relay admission is separately bounded, limiting this to local availability exposure.

  **Fix:** Bound gate waiters and apply the queue-wait deadline before suspension, returning existing queue-pressure errors. The unbounded semaphore pattern is pre-existing on the serial path; its placement before bounded CB admission is new.

No additional findings in MTP signature/artifact validation, bounded coordinator heartbeat parsing/admin serialization, or public secret/ops-internal leakage.

C/H/M/L = 0/0/0/2
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed


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

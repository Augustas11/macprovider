
codex
**Security gate PASS.** The round-5 MEDIUM is fixed. No new security findings introduced by `7dcb2e628`.

Reviewed the complete local `origin/main...HEAD` range: 11 commits. Read-only static inspection; no edits, builds, tests, or network calls.

| Round-5 finding | Status | Evidence |
|---|---|---|
| Skipped isolation widths | **FIXED** | [SelfCheck:732](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:732) checks every integer width. |
| Blocking cache open / parent protection | **PARTIAL — carried LOW** | [read:488](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:488) retains nonblocking, no-follow descriptor validation; [write:504](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:504) still trusts the parent path. |
| Revocation suppression | **FIXED as documented acceptance** | [SPEC-038:1050](/Users/augstar/macprovider-auto-slots/specs/SPEC-038-continuous-batching.md:1050) explicitly accepts suppression preserving eligibility. This remains threat acceptance, not mitigation. |
| Near-tie limitation | **FIXED as documented acceptance** | [ModelRuntime:4582](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4582) retains the other-row guard and top-two checks; [SPEC-038:1053](/Users/augstar/macprovider-auto-slots/specs/SPEC-038-continuous-batching.md:1053) documents residual contamination. |
| CB admission queue bounds/timeouts | **FIXED** | Scheduler admission retains [capacity bounds](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:2226) and [absolute deadlines](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:2682). The external serial waiter mechanism is removed. |
| Prior-grant preservation | **FIXED** | [reconcile:244](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:244) preserves grants through throughput noise. [resolution:373](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:373) now prevents owner pins from widening older-runtime grants. |
| Swap fencing / grant resolution | **FIXED** | [applyServedSlots:4451](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4451) captures the scheduler before suspension, checks generation before its setter, and returns the final generation check. [caller:4528](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4528) stops stale capacity publication. |
| Serial/batched admission accounting | **PRE-EXISTING relative to origin/main** | Separate budgets are restored: [serial gate:7726](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7726), [scheduler limit:5704](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:5704). Out of scope under the round-6 instruction. |
| Crash/progress handling | **FIXED** | [warm-up:725](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:725) journals before inference; [crash boundary:686](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:686) prevents retrying crashed widths. |
| v5 schema rejection | **FIXED** | [readable schemas:398](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:398) still accepts v5, including unfinished-step markers. |

**Carried LOW — pre-existing to this commit, introduced within this PR:** [SelfCheck:504](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:504) does not validate/protect the journal parent. An attacker with write access to a non-sticky parent can delete the crash marker, allowing a process-killing width to be retried. **Fix:** require a validated private parent and use descriptor-relative file operations.

C/H/M/L = 0/0/0/1
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed

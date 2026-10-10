
codex
Security gate **FAILS: 1 MEDIUM remains**, plus the carried LOW. The round-4 mixed serial/CB overcommit is fixed. **No new security findings introduced by `911dcc70a`.**

Reviewed the complete local `origin/main...HEAD` range: **10 commits**, through `911dcc70a`. No edits, builds, tests, or network calls.

| Round-4 concern | Status | Evidence |
|---|---|---|
| Skipped isolation widths | **FIXED** | [SelfCheck:729](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:729) checks every integer width. |
| Blocking cache open / parent protection | **PARTIAL — carried LOW** | [read():485](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:485) retains nonblocking, no-follow descriptor validation; [write():501](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:501) still trusts the parent path. Pre-existing to this commit. |
| Revocation suppression | **FIXED as documented acceptance** | [SPEC-038:1050](/Users/augstar/macprovider-auto-slots/specs/SPEC-038-continuous-batching.md:1050) explicitly accepts suppression preserving eligibility. This is threat acceptance, not mitigation. |
| Near-tie limitation | **FIXED as documented acceptance** | [ModelRuntime:4587](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4587) retains the other-row guard and top-two checks; the residual contamination case remains documented. |
| CB admission queue bounds/timeouts | **FIXED** | Scheduler buyers retain bounded admission and absolute deadlines. External serial waiters are bounded by already-acquired inference permits and support cancellation. |
| Prior-grant preservation | **FIXED** | [reconcile():244](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:244) preserves grants through throughput noise; [resolution:375](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:375) now preserves owner-pinned provisional grants. |
| Swap fencing / grant resolution | **PARTIAL — MEDIUM, pre-existing to this commit** | Report/capacity handling improves, but [applyServedSlots():4445](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4445) can still mutate a replacement scheduler before the generation check. Details below. |
| Serial/batched admission accounting | **FIXED** | [buyerRowsOccupied:5714](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:5714) combines scheduler buyers and external serial reservations. Both serial endpoints acquire that budget. |
| Crash/progress handling | **FIXED for the reported concern** | [warm-up:722](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:722) journals before inference; yielded re-measurements preserve progress; crash recovery retains the width boundary. |
| v5 schema rejection | **FIXED** | The readable-schema set still accepts v5; the new regression fixture preserves its decision and unfinished-step marker. |

The remaining **MEDIUM** qualifies the earlier swap confirmation. At [ModelRuntime.swift:4448](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4448), an old-target apply suspends while resizing the inference gate. A swap can rebuild and cap the new scheduler during that suspension. The old apply then reads `continuousBatchScheduler` and sets **the new scheduler’s** limit to the old served count. The generation check at [line 4522](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4522) detects the change only after that mutation.

**Exploit scenario:** A swapped-in model has eight scheduler rows but a stored grant verifying only two. A delayed eight-slot apply from the previous model raises its buyer limit to eight. A direct HTTP caller can then exercise unverified batch widths, bypassing the per-width isolation gate.

**Fix:** Capture the scheduler before suspension and fence post-await mutations against the expected generation; serialize swap/application or use generation-stamped setters. This path predates `911dcc70a`, was introduced within this PR, and is not pre-existing relative to `origin/main`.

The carried **LOW** remains: an attacker able to modify a non-sticky journal parent can delete the crash marker and permit retries. Fix with a validated private parent and descriptor-relative operations.

C/H/M/L = 0/0/1/1
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed

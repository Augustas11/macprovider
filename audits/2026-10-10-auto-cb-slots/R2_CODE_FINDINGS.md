
codex
**REQUEST CHANGES — CODE gate fails.** Reviewed the complete six-commit diff `origin/main...HEAD` through `a1d80863c` and touched code. No files edited, builds/tests run, or network services contacted.

Round-1 disposition:

| # | Status | Evidence |
|---|---|---|
| 1 | **PARTIAL** | Serial revocation was replaced with throughput-only lowering to two slots. See finding 1. |
| 2 | **FIXED** | Native and ordinary repetitions use distinct attempt IDs: `ModelRuntime.swift:3628,3694`. |
| 3 | **FIXED** | Streaming and non-streaming CB submissions acquire `buyerBatchGate`: `ModelRuntime.swift:6756,7212`. Aggregate accounting remains problematic; see finding 5. |
| 4 | **FIXED** | Managed swaps reset capacity to one or the owner pin before readiness: `ModelRuntime.swift:5376,5500`. Swap race remains under #6. |
| 5 | **FIXED** | Provisional grants require matching model SHA: `ContinuousBatchingSelfCheck.swift:536`. |
| 6 | **PARTIAL** | Expected-key check added, but application and swap remain reentrant. See finding 2. |
| 7 | **FIXED** | Startup recomputes bounded rows, clamps served slots, and writes back that count: `MacProviderCLI.swift:2975,3009`. |
| 8 | **PARTIAL** | Crash markers now precede stored decisions, but later reconciliation can retry the crashed width. See finding 3. |
| 9 | **PARTIAL** | Alone runs are journaled and failed writes abort widths; warmup remains unjournaled. See finding 4. |
| 10 | **FIXED** | Serial generation observes cancellation and rejects cancelled measurements: `ModelRuntime.swift:9110`. |
| 11 | **FIXED** | Existing gates resize while preserving holders/waiters: `AsyncSemaphore.swift:22`. |
| 12 | **FIXED** | Capacity changes invoke availability publication: `ProviderStatus.swift:718`. |
| 13 | **FIXED** | `runtime_build` is stored, bounded, cloned, and covered by heartbeat parsing tests: `provider.go:501,519`; `messages.go:1603`. |

**Remaining anchored findings**

1. **HIGH — Throughput noise still lowers prior grants.**  
   [ContinuousBatchingSelfCheck.swift:249](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:249)  
   An eight-slot Mac whose rows remain correct drops to two slots after three clear-loss measurements. This violates “only correctness lowers or revokes.” The revised test explicitly expects this reduction.  
   **Fix:** remove throughput-only lowering; preserve the prior count subject to correctness and memory bounds. Update the test and contradictory SPEC exception.

2. **HIGH — A’s decision can still become B’s state during a swap.**  
   [ModelRuntime.swift:5367](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5367), [ModelRuntime.swift:4497](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4497)  
   Swap A→B resets qualification to pending, then suspends during gate resizing while the current identity still names A. The driver can pass the expected-A check and install A’s grant during that suspension. Swap resumes, installs B, and never resets qualification again. Application also suspends between gate updates; report and ProviderStatus publication remain separate actor calls.  
   **Fix:** invalidate the model generation before swap suspension and serialize generation-fenced state, gate, report, and capacity updates. Add controlled interleaving tests.

3. **MEDIUM — Crash recovery can schedule the crashed width again.**  
   [ContinuousBatchingSelfCheck.swift:806](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:806)  
   Example: a remeasurement retains an old eight-slot decision, crashes at four, and has correct two/three-slot measurements below 1.2×. Recovery produces `no_net_gain`; reconciliation schedules another measurement, then `finish()` clears the crash marker. The next sweep resets measurements and reaches four again.  
   **Fix:** persist a permanent crashed-width bound separately from the transient journal and enforce it across subsequent sweeps.

4. **MEDIUM — Warmup still executes before crash journaling.**  
   [ContinuousBatchingSelfCheck.swift:659](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:659)  
   A process-killing warmup leaves no unfinished marker, so every restart retries it. Warmup also executes before qualification discovers that journal writes fail.  
   **Fix:** durably journal warmup before inference, with explicit recovery handling, or remove it.

**NEW findings introduced by the fixes**

5. **HIGH — Separate gates do not enforce aggregate buyer capacity.**  
   [ModelRuntime.swift:4439](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4439), [ModelRuntime.swift:7686](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7686)  
   Batched buyers hold `buyerBatchGate`; serial buyers hold `inferenceGate`. If requests arrive between measurement completion and refusal application, outstanding CB requests retain batch permits while newly serial-routed HTTP requests enter the independent serial gate. Resizing preserves accounting within each gate, but cannot account for holders of the other gate.  
   **Fix:** use a shared served-slot gate for all buyer execution, or drain/fence decode-mode transitions. Test refusal while CB holders remain active.

6. **MEDIUM — Deferral discards completed remeasurement progress.**  
   [ContinuousBatchingSelfCheck.swift:769](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:769)  
   Completed widths are saved, but a buyer interruption restores the entire previous record. Each later remeasurement starts from width two again. A busy Mac can indefinitely miss higher-width correctness failures while retaining its old grant.  
   **Fix:** persist resumable measurement progress separately from the prior applied decision; clear only the interrupted execution marker.

**Additional findings newly identified in earlier PR code**

7. **HIGH — Owner-pinned CB providers can still lose CB solely from noise.**  
   [MacProviderCLI.swift:3147](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:3147)  
   **Pre-existing in earlier PR revisions, not introduced by the round-1 fix.** An owner plan has reason `owner_pinned`, so the driver receives no provisional grant despite a positive signed entry. With no stored prior decision, correctness-passing `no_net_gain` becomes `.refused` and switches off previously serving CB.  
   **Fix:** supply the model-bound positive-policy grant independently of the slot-plan reason.

8. **MEDIUM — Autotune candidates can remain permanently serial.**  
   [MacProviderCLI.swift:2929](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:2929), [ModelRuntime.swift:4677](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4677)  
   **Pre-existing in earlier PR revisions.** Candidates skip automatic planning and therefore never start the driver, but receive default-on coverage. Pending qualification returns `.off` without a positive policy entry before explicit CB/manual accepted-tuple handling. An explicitly accepted no-join candidate consequently cannot exercise CB.  
   **Fix:** preserve the candidate’s explicit accepted-tuple path outside production pending qualification, without weakening production admission.

The inspected tests do not exercise driver crash/restart recovery, swap/application interleavings, mixed serial/CB admission, or owner-pinned provisional reconciliation. These require regressions beyond the current helper and semaphore tests.

**C/H/M/L = 0/4/4/0**
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed

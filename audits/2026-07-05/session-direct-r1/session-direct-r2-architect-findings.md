# Session direct-push R2 — ARCHITECT lane findings

## Verdict
FAIL

The R2 design closes the original orphan-child chain for the intended timeout/error path: the App keeps a handle to the immediate `macprovider-cli autotune --recommend --json` process, the CLI becomes a process-group leader before spawning `CandidateProviderRunner`, and App escalation uses `killpg(cliPid, SIGKILL)` after a 5 s grace. However, the CLI cascade handler currently calls `killpg(0, SIGTERM)` from the `SIGTERM` dispatch-source handler, which includes the CLI itself and re-triggers the same dispatch source repeatedly. That creates a new shutdown coupling bug: graceful teardown may degrade into signal feedback until process exit or App SIGKILL escalation. This is a MEDIUM finding because it does not reopen the grandchild-orphan hole in the timeout path, but it makes the intended graceful cascade non-idempotent and can keep the CLI burning CPU / delaying unwind during a stuck probe.

## ARCH-R2.1 verification (orphan scenario closure)
- Case A (normal App quit): OPEN — signal delivery reaches the grandchildren, but the CLI handler is not one-shot. App `process.terminate()` sends SIGTERM to the CLI; the CLI dispatch source sets the interrupt flag and calls `killpg(0, SIGTERM)`; that group signal reaches `CandidateProviderRunner` / `serve --no-join`, but also reaches the CLI and re-enters the same handler. A local isolated Swift probe confirmed `killpg(0, SIGTERM)` from such a handler retriggers the handler on Darwin. The design should cascade only once, or target children without signaling itself.
- Case B (CLI hang): CLOSED — App escalation uses `killpg(cliPid, SIGKILL)` plus direct `kill(cliPid, SIGKILL)` after the grace window. This relies on `setpgid(0, 0)` having run, and it does run before any candidate subprocess spawn in `runAutotuneRecommend()`. The pre-`setpgid` race is limited to a CLI wedged before its first process-group syscall; the direct `kill(cliPid, SIGKILL)` fallback covers the CLI in that race, and grandchildren do not yet exist because child spawn happens later. Residual risk is LOW.
- Case C (App SIGKILL): CLOSED_DEFERRED — if the App itself is SIGKILLed, neither App cleanup nor CLI signal handling runs, so the CLI/grandchildren can survive. That is a real follow-up for a parent-death monitor, but it is narrower than the R1 timeout/error orphan and is explicitly deferred as ARCH-M-1-followup. I would not keep it as a convergence-blocking MEDIUM for this R2 slice.

## Findings
### ARCH-R2-M-1 (MEDIUM) CLI cascade handler re-signals itself indefinitely
- File: phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift:46
- Design concern: The `SIGINT`/`SIGTERM` event handlers call `Darwin.killpg(0, SIGTERM)` when `cascadeToProcessGroup` is enabled. Process group `0` includes the CLI itself after `setpgid(0, 0)`, and the CLI has active `DispatchSourceSignal` monitors for the same signals. `SIG_IGN` prevents default process death, but it does not make the dispatch source immune to a new signal event. I verified this with an isolated Swift process-group probe: the handler printed `event 1`, then its own `killpg(0, SIGTERM)` produced `event 2` and `event 3`. In the real CLI this can turn a single App SIGTERM into repeated group SIGTERMs until the CLI exits or the App escalates to SIGKILL.
- Recommendation: Make cascade idempotent. For example, guard the handler with an atomic/locked `didCascade` flag so only the first signal sends `killpg(0, SIGTERM)`, or restore/default/cancel signal sources before re-emitting to the group. Add a regression test that sends SIGTERM to a process-group-leading helper and asserts exactly one cascade action while a child receives the signal.

### ARCH-R2-L-1 (LOW) App-side process-subtree tests do not prove grandchild teardown
- File: phase3-binary/app/Tests/MalibuTests/AutotuneRecommendationRunnerTimeoutTests.swift:84
- Design concern: The new timeout tests spawn `/bin/sh` and assert the immediate child exits, but they do not assert that a nested grandchild dies. A regression that weakens or removes the CLI cascade path could still pass the App helper tests as long as the direct child is gone.
- Recommendation: Add an integration-flavored test helper that creates a child and grandchild in the same process group, records the grandchild pid, runs `terminateAutotuneSubtree`, and asserts the grandchild no longer exists. Keep timing assertions loose; the current `>= 0.4s` / `< 5s` bounds are acceptable for the direct-child test.

### ARCH-R2-L-2 (LOW) Process-group leadership contract is documented but not pinned end-to-end
- File: phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:701
- Design concern: The App now depends on the CLI calling `setpgid(0, 0)` before any subprocess spawn. The comment is discoverable and the helper has a smoke test, but no test fails if a future edit moves/removes the call while leaving candidate spawning intact.
- Recommendation: Add a narrow CLI integration test or debug hook that proves `runAutotuneRecommend()` establishes `pgid == cliPid` before invoking the runner factory. At minimum, log `setpgid` failure; the current return value is ignored.

### ARCH-R2-I-1 (INFO) Optional interrupt flag is acceptable for current production shape
- File: phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift:1741
- Design concern: `AutotuneRecommendationBenchmarker.benchmarks(..., interruptFlag:)` defaults the flag to `nil`, so callers who omit it do not stop between candidates after SIGTERM. In the current production `--recommend` path, the flag is created and passed. The in-flight child is also handled by process-group signaling, so the optional flag mainly prevents fresh post-interrupt spawns.
- Recommendation: Optional is acceptable for compatibility with existing tests and non-signal contexts. If another production caller is added, require an explicit interrupt policy at that boundary rather than silently relying on the default.

### ARCH-R2-I-2 (INFO) Register validator belongs in the HTTP client and same-origin is the right contract
- File: phase3-binary/app/Sources/Malibu/System/RegisterClient.swift:179
- Design concern: The validator rejects `coordinator_ws_url` values whose scheme, host, port, userinfo, or empty path do not match the registrar origin. It intentionally validates same-origin with `coordinatorBaseURL`, not hard-pinned `coordinator.malibu.tech`. Since the production App constructs `LaunchProviderController` with `URL(string: "https://coordinator.malibu.tech")!` in `OnboardingWindow.swift:33`, and there is no on-disk config/env path feeding that constructor, this preserves dev/test flexibility without weakening the shipped production path.
- Recommendation: No blocking architecture change. A SPEC-026 note saying `coordinator_ws_url` MUST be same-origin with the registrar base URL would be useful normative cleanup, but not required for this convergence.

## Validation evidence
- Read the R2 commits `f7d44f9` and `cfc0efe`, plus the touched implementation and test files.
- Ran targeted Swift tests in `phase3-binary`: `swift test --filter 'AutotuneRecommendationRunnerTimeoutTests|AutotuneRecommendTests/testBenchmarksBreaksBetweenCandidatesWhenInterruptFlagIsSet|AutotuneRecommendTests/testAutotuneBecomeProcessGroupLeaderIsIdempotent|RegisterClientTests/testValidateCoordinatorWSURL'`. The SwiftPM package only picked up the CLI tests and they passed: 2 tests, 0 failures.
- Ran an isolated Swift process-group signal probe outside the repo; it confirmed `killpg(0, SIGTERM)` from a dispatch-source handler re-triggers the handler on the process itself.

# Session direct-push audit R2 — CODE lane

You are the **code** lane of a three-lane audit (code / security /
architect) of the R1 → R2 fixes for the six session direct-push
commits v1.8.5-v1.8.9. R1 CODE lane returned PASS; R2 re-fires
because the SEC-M-1 and ARCH-M-1 fixes added substantial new code
that touches your lane's scope.

Convergence bar: **0 CRITICAL, 0 HIGH, 0 MEDIUM findings** across all
three lanes.

## Scope — what changed since R1

Worktree: `/Users/augstar/macprovider-poc-r1fix/` on branch
`fix/session-r1-orphan-and-ws-url` (base = `origin/main` at `2b7021b`).

Two new commits above origin/main:

1. **`f7d44f9` — fix(app): validate coordinator_ws_url origin on /register response (SEC-M-1)**
   - `phase3-binary/app/Sources/Malibu/System/RegisterClient.swift`
     - New static `validateCoordinatorWSURL(_ url: URL, expectedBase: URL) throws`.
     - Called from `postRegister(_:)` immediately after
       `JSONDecoder().decode(RegisterResponse.self, from: data)`.
     - New error case `RegisterClientError.invalidCoordinatorWSURL(reason: String)`
       (enum switched to `Error, Equatable`).
   - `phase3-binary/app/Tests/MalibuTests/RegisterClientTests.swift`
     - 8 new tests covering accept + reject paths.

2. **`cfc0efe` — fix(autotune): tear down orphan-child grandchildren on SIGTERM (ARCH-M-1)**
   - CLI `phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift`
     - `AutotuneSignalSources.init(flag:cascadeToProcessGroup:)` — new
       optional `cascadeToProcessGroup: Bool = false`; when true the
       SIGINT/SIGTERM handlers re-emit via `killpg(0, SIGTERM)` to
       forward to every child in the caller's process group.
     - New free function `autotuneBecomeProcessGroupLeader() -> Bool`
       (wraps `Darwin.setpgid(0, 0)`).
   - CLI `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift`
     - `runAutotuneRecommend()`: prepended `setpgid(0,0)` + install
       `AutotuneSignalSources(flag:, cascadeToProcessGroup: true)`.
     - Passes new `interruptFlag` into the benchmarker call; after
       benchmarks throws `ExitCode(130)` if flag was set.
   - CLI `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
     - `AutotuneRecommendationBenchmarker.benchmarks(...)` gained
       optional `interruptFlag: AutotuneInterruptFlag? = nil`; loop
       checks flag between candidates, breaks with diagnostic
       `"interrupted before probe"`.
   - App `phase3-binary/app/Sources/Malibu/Onboarding/AutotuneRecommendationRunner.swift`
     - Added `subtreeGraceSeconds: TimeInterval = 5`.
     - Added static `terminateAutotuneSubtree(process:graceSeconds:)`:
       `process.terminate()` → poll for grace → escalate to
       `Darwin.killpg(cliPid, SIGKILL)` + `Darwin.kill(cliPid, SIGKILL)` →
       post-kill poll (bounded 1 s) so callers observing
       `process.isRunning` immediately don't race the reap.
     - Rewrote `runProcess(...)`'s timeout branch and error branch to
       call `terminateAutotuneSubtree(...)` instead of raw
       `process.terminate()`.
   - Tests:
     - CLI `Tests/macprovider-cliTests/AutotuneRecommendTests.swift` +
       `testBenchmarksBreaksBetweenCandidatesWhenInterruptFlagIsSet` +
       `testAutotuneBecomeProcessGroupLeaderIsIdempotent`.
     - App `Tests/MalibuTests/AutotuneRecommendationRunnerTimeoutTests.swift` +
       `testTerminateAutotuneSubtreeSIGTERMsCooperativeChild`,
       `testTerminateAutotuneSubtreeSIGKILLEscalatesWhenChildIgnoresSIGTERM`,
       `testSubtreeGraceSecondsIsPositive`.

Read `git log --stat origin/main..HEAD` from the worktree for the full
touched surface.

## Code-lane scope (apply each; stay in lane)

### CODE-R2.1 — SEC-M-1 validator correctness

- `validateCoordinatorWSURL(_:expectedBase:)` — trace every branch on
  paper against these inputs and confirm the return path:
  - base `https://coordinator.streamvc.live`, url
    `wss://coordinator.streamvc.live/v2/provider` → OK.
  - base `https://coordinator.streamvc.live`, url with explicit
    default `:443` port → OK (defaultExpectedPort logic).
  - base `http://127.0.0.1:8080`, url `ws://127.0.0.1:8080/v2/provider`
    → OK.
  - `expectedBase.scheme` = `HTTP` (uppercase) — does `lowercased()`
    normalize? Confirm.
  - `expectedBase.port` = nil for `https` → expectedPort defaults to
    443; url port = nil → actualPort defaults to `defaultExpectedPort`
    (also 443). Both branches align. Confirm.
  - Empty path `""` vs `"/"` — `URL("wss://host").path` returns `""`,
    `URL("wss://host/").path` returns `"/"`. The validator rejects the
    former. Is that the intended contract?
  - Confirm `url.user == nil, url.password == nil` catches
    `wss://attacker@host/path` — Swift URL parses `attacker` into
    `.user`. Verify.
- `postRegister(...)` calls the validator AFTER decoding but before
  returning. Confirm on the error path (invalidCoordinatorWSURL
  thrown) the caller does not accidentally persist anything derived
  from `decoded` (grep for `postRegister` callers).
- `RegisterClientError` enum switched from `Error` to
  `Error, Equatable`. Confirm Equatable synthesis does the right thing
  for `.invalidCoordinatorWSURL(reason:)` (Swift synthesizes Equatable
  for enums whose associated values are Equatable; String is
  Equatable). Any downstream code that pattern-matches this enum
  should keep compiling.

### CODE-R2.2 — Actor / concurrency safety of new code paths

- `AutotuneSignalSources` now closes over `cascadeToProcessGroup`
  (Bool, Sendable). The handler runs on `signalQueue`. Verify no
  captured non-Sendable state, no data race.
- `AutotuneRecommendationBenchmarker.benchmarks(...)` accepts
  `AutotuneInterruptFlag?`. `AutotuneInterruptFlag` uses `NSLock`
  around a `Bool`; safe under contention. Confirm it's not marked
  `@MainActor` or otherwise thread-restricted.
- `AutotuneRecommendationRunner.runProcess(...)` runs on
  `DispatchQueue.global(qos: .utility)`. `terminateAutotuneSubtree`
  is a static method; called from the same queue. Verify no cross-
  thread `Process` mutation.

### CODE-R2.3 — Signal handler correctness

- `signal(SIGINT, SIG_IGN)` + `signal(SIGTERM, SIG_IGN)` runs BEFORE
  `sigintSource.resume()` / `sigtermSource.resume()`. That's the
  documented pattern to make DispatchSourceSignal reliable. Confirm.
- Cascade handler does `Darwin.killpg(0, SIGTERM)`. `killpg(pgid, sig)`
  where `pgid == 0` targets the current process's pgid. Combined
  with `setpgid(0, 0)` making the caller a group leader, this hits
  only OUR spawned children — no risk of hitting the App or unrelated
  processes. Trace one full path: App fires
  `kill(cliPid, SIGTERM)` → CLI signal handler fires → cascade →
  `killpg(0, SIGTERM)` → CLI's SIG_IGN swallows the re-fire → children
  in same pgid receive SIGTERM → Foundation.Process's spawned children
  default signal disposition to SIG_DFL so they exit. Any gap in
  this reasoning?
- What if `setpgid(0, 0)` fails (already a session leader, or perm)?
  `autotuneBecomeProcessGroupLeader()` swallows failure and returns
  `false` but the recommend path doesn't check the return value. In
  that failure mode, cascade may hit the App's original pgid. Is that
  a real risk on macOS, or does `setpgid(0, 0)` from a normal
  Foundation.Process child always succeed? Confirm.

### CODE-R2.4 — Benchmarker interrupt threading

- Loop-break diagnostic writes only for the FIRST unprocessed
  candidate. Every subsequent iteration for other candidates gets
  no diagnostic. Is that acceptable, or should every remaining model
  key be marked interrupted? (Minor observability question.)
- The interrupt check is BEFORE `guard let row = ...`. If the guard
  would have skipped this key anyway (missing row), the interrupt
  diagnostic still overwrites nothing (empty diagnostics). Confirm.
- `interruptFlag: AutotuneInterruptFlag? = nil` default preserves
  every callsite that doesn't pass one. Grep for all callers of
  `benchmarks(...)` to confirm — production path passes it, tests
  omit it. Any third caller?

### CODE-R2.5 — `terminateAutotuneSubtree` correctness

- SIGTERM (via `process.terminate()`) → grace poll → SIGKILL escalation.
  Verify the grace loop:
  - `Date().addingTimeInterval(max(0, graceSeconds))` — negative
    graceSeconds becomes 0. Loop condition
    `process.isRunning && Date() < deadline` returns immediately.
    Guard exits early via `guard process.isRunning else { return }`
    if process already exited. Trace one 0-grace path.
- `Darwin.killpg(cliPid, SIGKILL)` — pgid parameter, but we're
  passing cliPid. This ONLY works if the CLI called `setpgid(0, 0)`,
  making cliPid == pgid. If the CLI is v1.8.9 or earlier (no setpgid),
  this call returns ESRCH. That's why the fallback
  `Darwin.kill(cliPid, SIGKILL)` follows — it hits the CLI even
  without pgid. But grandchildren remain orphaned in that case.
  Confirm: is this "orphaned grandchildren on old-CLI + new-App"
  case an issue when the CLI binary is bundled in the .pkg with the
  App and both versions bump together?
- Post-kill poll: 1s bounded. What if SIGKILL is somehow blocked
  (e.g. process stuck in uninterruptible kernel wait)? `process.isRunning`
  remains true after 1s. The function returns. Caller (`runProcess`)
  calls `process.waitUntilExit()` which would block forever. Real risk
  in the recommend path?

### CODE-R2.6 — Test adequacy

- Do the new tests actually exercise the failure modes:
  - `testTerminateAutotuneSubtreeSIGKILLEscalatesWhenChildIgnoresSIGTERM`
    — spawns `/bin/sh -c 'trap "" 15; sleep 60 & wait'`. The `trap ''
    15` ignores SIGTERM but NOT SIGKILL. The `sleep 60 &` runs in a
    subshell. When the parent shell exits, the child sleep is also
    killed on macOS (SIGHUP by default). Verify the test actually
    proves the escalation path — i.e. the 0.5 s grace expires with
    the parent still running, the SIGKILL fires, and the process is
    reaped within the 1 s post-kill poll.
  - `testTerminateAutotuneSubtreeSIGTERMsCooperativeChild` — spawns
    `sleep 30`. `sleep` exits on SIGTERM. Verify grace of 2 s is
    enough for the terminate + reap on a healthy Mac.
  - Timing assertions (`XCTAssertGreaterThanOrEqual(elapsed, 0.4)`)
    are flaky candidates. Are they inside tolerance to survive CI?
- Missing coverage worth flagging:
  - No test exercises the cascade handler ACTUALLY hitting grandchildren
    (would require a subprocess-of-subprocess setup — hard, but the
    highest-value regression test).
  - No test for `terminateAutotuneSubtree` when process is already
    exited before entry (should be a no-op).
  - No test for the App-side error branch calling
    `terminateAutotuneSubtree` (only the timeout branch is exercised).

## Response format

Write findings to
`audits/2026-07-05/session-direct-r1/session-direct-r2-code-findings.md`
using this template:

```
# Session direct-push R2 — CODE lane findings

## Verdict
PASS / FAIL

## Findings
### CODE-R2-C-1 (CRITICAL) <title>
- File: <path:line>
- Evidence: ...
- Recommendation: ...
### CODE-R2-H-1 (HIGH) <...>
### CODE-R2-M-1 (MEDIUM) <...>
### CODE-R2-L-1 (LOW) <...>
### CODE-R2-I-1 (INFO) <...>
```

Stay in your lane: no security-threat modeling, no
architecture-coupling opinions. Line-level correctness / concurrency /
test adequacy only. If verdict is PASS, still write the file with an
empty findings list and a one-paragraph "what I looked at" narrative.

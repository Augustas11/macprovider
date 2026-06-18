# Implementation audit prompt — SPEC-013 Step 4 (provider lifecycle)

Operator-paste prompt for Codex GPT-5 to perform an adversarial
**code / concurrency / resource-lifecycle review** of the Step 4
commit that landed `CandidateProviderRunner` on branch
`feat/cli-autotune-impl`.

Step 4 carries:

| Commit | Step | Scope |
|---|---|---|
| 994c7ee | 4 | `CandidateProviderRunner` + `ReadyStatus` + `CandidateProviderRunnerError` + `RunningProvider` + `ProcessOutputTail` + 6 unit tests (1 integration-gated) |

Full `phase3-binary` test suite is green per the commit's
`Tested:` line (266 tests, 1 skipped — the integration test
gated behind `MACPROVIDER_INTEGRATION_TEST=1`). Codex (the
implementer) raised zero Open Questions. Operator wants an
independent adversarial pass BEFORE Step 5 (provider-conflict
pre-flight + launchd drain) begins.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~25-40
min — Step 4 introduces process spawning, async HTTP polling,
signal delivery, port-bind-wait, and pipe-based log streaming.
This is a **read-only review** — Codex MUST NOT modify any
file.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial implementation review of the Step
4 commit (994c7ee) on branch `feat/cli-autotune-impl` in the
Augustas11/macprovider repository. The branch is already checked
out at `/Users/augstar/macprovider-poc`. Steps 1 (02b038d), 2
(ffb00fb), and 3 (d0029e9) are LOCKED.

Steps 5-11 have NOT landed yet — your scope is exclusively the
Step 4 commit and its anti-regression impact on the existing
`phase3-binary/`.

This is a **read-only review**. You MUST NOT edit any file,
commit, push, or modify the git state.

## Context

Step 4 of `specs/BUILD_SPEC_013_PROMPT.md` calls for the
`CandidateProviderRunner` lifecycle primitive: spawn
`macprovider-cli serve --no-join`, wait for HTTP readiness,
stop cleanly. The runner is the substrate Step 7 will use to
iterate the Stage 1 candidate list. Step 4 wires the runner but
does NOT call it from `AutotuneCommand.run()` yet.

Specifically:
- `start(model:, port:, kvBits:, maxContext:, maxBatch:)` —
  spawns `serve --no-join` as a subprocess with optional knob
  flags; streams stdout/stderr to a per-trial log file under
  `~/.cache/macprovider/autotune-logs/`.
- `waitForReady(timeout:)` async — polls
  `GET http://127.0.0.1:<port>/v1/models` every ~1s until 200,
  the subprocess exits, or timeout. Returns enum
  `{.ready, .processExited(rc:stderrTail:), .timeout(lastError:)}`.
- `stop(graceSeconds:)` — SIGTERM the subprocess (via
  `Process.terminate()`); poll for port-free + process-exit up
  to the grace window; warn (no SIGKILL) if the port remains
  held. Step 4 explicitly does NOT escalate to SIGKILL — Step 5
  will own launchd-specific behavior.

Invariant: AT MOST ONE provider alive at any moment. The runner
holds at most one `RunningProvider` and `start()` throws
`alreadyRunning` if called while one is still alive.

## Required reading (in this order)

1. The Step 4 commit via `git show 994c7ee`. The commit message
   contains the testing claims and the picked design (no
   `--provider-bin` flag; resolve via `Bundle.main.executablePath`).

2. The Step 4 source under audit:
   - `phase3-binary/Sources/macprovider-cli/CandidateProviderRunner.swift`
     (425 lines, NEW). The bulk of the audit's surface.
   - `phase3-binary/Tests/macprovider-cliTests/CandidateProviderRunnerTests.swift`
     (331 lines, NEW; 6 unit tests including 1 integration-gated).
   - `phase3-binary/implementation-notes.html` — new
     `spec013-autotune-step4` section.

3. The locked SPEC (READ-ONLY):
   - `specs/SPEC-013-cli-autotune.md` v0.3 §3 "Provider
     lifecycle invariant" — single-provider rule.
   - §5.5 FR-E.2 — `--no-join` semantics (the runner's spawn
     always passes `--no-join`).
   - §5.4 FR-D.1 — measurement-isolation contract. The
     `waitForReady` wall-clock is EXCLUDED from gate-ttft-ms
     (Step 7 will enforce this; Step 4 just needs the
     separation to be possible).
   - §5.5 FR-E.1 "Drain sequence" — Step 5 will use this.
     Step 4's `stop()` is the foreground SIGTERM path; verify
     it doesn't preempt FR-E.1's launchd-managed
     bootout/bootstrap (which Step 5 will own).

4. Local style guide:
   - `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift`
     — the existing `Process()` pattern. The BUILD prompt
     explicitly says "Use the same `Process()` pattern as
     `SelfUpdate.swift`." Verify the runner's Process usage
     matches.
   - The existing `runProcess` helper (used in
     `UninstallCommand.swift` / `SelfUpdate.swift` for the
     launchctl calls) — is `CandidateProviderRunner` correctly
     using `Process` directly because it needs lifetime
     control (waitUntilExit isn't called; we want to keep the
     process alive across multiple calls), or could it reuse
     the existing helper?

You do NOT need to re-read SPEC-001, SPEC-002, SPEC-003 — Step
4 is binary-internal.

## Severity definitions (unchanged from prior steps)

- **CRITICAL** — silent contract violation of the
  single-provider invariant (e.g. `start()` succeeds twice and
  leaves a zombie process); resource leak that breaks long-running
  use (pipe FD leak after many start/stop cycles); signal
  delivery race that crashes the autotune; anti-regression broke
  an existing passing test; SIGKILL escalation in v1 (the BUILD
  prompt forbids it for Step 4).
- **MAJOR** — Step 4 contract gap (e.g. `waitForReady` returns
  `.ready` when the process actually exited just after); test
  gap that hides a likely production failure (e.g. no test for
  the "process exits during waitForReady" path); argv assembly
  bug that produces a wrong serve invocation; concurrency bug
  in the NSLock/DispatchQueue interaction.
- **MINOR** — quality issues, naming inconsistencies, log file
  hygiene.
- **QUESTION** — design choice Step 4 made where the SPEC was
  silent (e.g. the choice of 1-second polling interval vs.
  exponential backoff).

## Critical constraints (unchanged from prior steps)

1. SPEC-013 v0.3 is LOCKED.
2. Anti-regression — `swift test --package-path phase3-binary`
   MUST report 266 tests (1 skipped), 0 failures.
3. Strict clean-room on d-inference.
4. Read-only.

Additionally for Step 4:

5. **No SIGKILL escalation in v1.** The BUILD prompt explicitly
   says "Default Step 4 behavior: SIGTERM + wait + log a warning
   if the port remains held after grace." Step 5 will add the
   launchd-managed path. Verify `stop()` does NOT call
   `Process.interrupt()` / SIGKILL anywhere.
6. **Async/await correctness.** `waitForReady` is async. Verify
   it doesn't block the calling thread, doesn't leak Task
   handles, and properly handles cancellation (a future caller
   might use Task cancellation; check the Task.sleep call
   correctly throws on cancel).
7. **File handle / pipe / socket discipline.** Every opened
   file handle MUST be closed on every exit path. Every Pipe()
   reads side must have its readabilityHandler cleared. Every
   socket FD opened in `isPortOpen` MUST be closed.

## Audit categories — work through each

### Category A: Single-provider invariant (load-bearing)

A.1  `start()` lock discipline: reads `current` inside
     `stateLock` and throws `alreadyRunning` if a current
     provider is still running. Race window:
     - Thread A calls `start()` and sets `current = running`.
     - Thread B calls `start()`, holds the lock, observes
       `current.process.isRunning == true`, throws. Correct.
     - Thread A calls `stop()` immediately after, which calls
       `clearCurrentIfSame` and clears `current`.
     - Thread B retries start. OK.
     Now the subtler case: between the `process.terminate()`
     in `stop()` and the process actually exiting, is
     `current.process.isRunning` still true? Yes — `isRunning`
     reflects OS state. So `start()` correctly blocks until
     the prior process has actually exited. Good.

A.2  But: `stop()` returns BEFORE `process.isRunning == false`
     in the case where the port is held but the process is
     still running. After `stop()` returns, can the caller
     immediately call `start()` without `alreadyRunning`?
     Walk the code: `stop()` ends by checking
     `if !provider.process.isRunning { clearCurrentIfSame(provider) }`
     — so if the process is still running, `current` is NOT
     cleared. The next `start()` will see the still-running
     process and throw `alreadyRunning`. Correct.

A.3  But there's a subtler invariant breach: `stop()` does
     NOT throw if the grace window expires with the process
     still alive. It just logs a warning and returns. Step 7
     would call `stop()` and then `start()` for the next
     candidate, hit `alreadyRunning`, and likely... what?
     Whatever Step 7 does. Step 4's contract doesn't have to
     handle this, but document the implication: a stuck
     subprocess effectively halts the iteration. Maybe
     QUESTION whether this should throw instead of warn.

A.4  Concurrent stop: if two threads call `stop()`
     simultaneously, both observe the provider, both attempt
     `process.terminate()` (idempotent), both poll the
     deadline, both check port. `clearCurrentIfSame` is
     guarded by `current === provider` so only one of them
     actually clears + calls `finishLogging()`. Good.

A.5  Test `testStartRejectsSecondRunningProvider`: verify it
     actually proves `alreadyRunning` is thrown when a second
     `start()` is called while the first is alive (read the
     test).

### Category B: Process lifecycle correctness

B.1  Process spawn (`process.run()`): the spawn happens
     INSIDE the lock (line 122 inside the `defer { unlock }`
     scope). This blocks other threads from competing for
     `current`. Good for safety; minor latency cost
     (negligible).

B.2  Pipe handling: `stdoutPipe` and `stderrPipe` are created
     for each spawn. Their `readabilityHandler` reads
     `availableData` and appends to the log + stderr tail.
     - Verify the handlers correctly weakly reference
       `running` to avoid retain cycle.
     - Verify that when `finishLogging` clears the
       readability handlers, no in-flight handler invocation
       can race (Apple's docs: setting the handler to nil
       cancels future callbacks but doesn't synchronize with
       in-flight ones). If an in-flight callback runs after
       `closed = true` is set in the log queue, the guard
       blocks the write. Good.
     - Verify the `readDataToEndOfFile()` calls in
       `finishLogging` are safe when the process is still
       running (the `process.isRunning ? Data() : ...`
       guard handles this).

B.3  Process spawn failure: if `process.run()` throws,
     `running.finishLogging()` runs before the throw
     propagates. Verify: yes (lines 124-126). Good — log file
     is closed even on spawn-fail.

B.4  Zombie risk: macOS `Process` API normally collects child
     state via `waitpid` internally. If a Process object is
     released without `waitUntilExit` being called, is the
     child zombie'd? Apple's docs say `Process` handles
     reaping. Verify by reading: the runner never calls
     `waitUntilExit` — it polls `isRunning`. If `isRunning ==
     false`, `Process` has already reaped (or will reap). The
     test pattern (start → wait → stop → start again) doesn't
     accumulate zombies in any documented Apple Process
     behavior. Acceptable.

B.5  Process binary path: `defaultProviderBinaryPath()` tries
     `Bundle.main.executablePath`, then `CommandLine.arguments[0]`.
     For a unit test running under `swift test`, the executable
     path is the test runner, not `macprovider-cli`. The tests
     work around this by passing an explicit `providerBinaryPath`
     to the runner's init (e.g. the stub binary). Verify the
     test pattern is sound.

B.6  Stub binary pattern: the tests likely build a small Swift
     fixture that mimics a `serve` process for the lifecycle
     tests. Read `testStartWaitReadyStopLifecycleWithStubBinary`
     to verify the fixture handles SIGTERM cleanly (otherwise
     the lifecycle test would fail on the `stop()` step).

### Category C: Async HTTP polling correctness (FR-D.1 measurement isolation)

C.1  `waitForReady` cadence: 1-second sleep between polls. The
     BUILD prompt says "every ~1s" which matches. Faster
     polling would consume more CPU; slower would lengthen
     the cold-start measurement. Acceptable.

C.2  HTTP request timeout: `request.timeoutInterval = 1` per
     attempt. With ~1s sleep + 1s timeout per attempt, each
     iteration is 1-2s. For a 60-second readiness window
     (typical model load), this gives ~30-60 attempts. Fine.

C.3  Process-exit detection: checked TWICE per iteration —
     once before the HTTP attempt, once after (lines 136-142
     and 162-168). This catches the race where the process
     exits during the HTTP attempt. Good defensive pattern.

C.4  Return value when process exits during waitForReady:
     `.processExited(rc:stderrTail:)`. Verify the `rc` is
     correctly read from `process.terminationStatus`. Per Apple
     docs, `terminationStatus` is valid only after the process
     exits (which is the case here). Good.

C.5  Task cancellation: `Task.sleep(nanoseconds:)` throws on
     cancellation. If `waitForReady` is cancelled by the
     caller (Step 10 SIGINT path), the task throws
     `CancellationError` mid-loop. Step 7 will need to handle
     this; Step 4's `waitForReady` propagates the throw,
     which is correct.

C.6  `lastError` initialization: `"not checked yet"`. If the
     loop never executes (timeout=0), `waitForReady` returns
     `.timeout(lastError: "not checked yet")`. Edge case
     unlikely to matter but worth flagging if surprising.

C.7  URL construction: `URL(string: "http://127.0.0.1:\(port)/v1/models")!`
     — the force-unwrap is safe because the port is an Int
     (validated upstream by `serveArguments` to be 1...65535)
     and the URL string is well-formed. But the force-unwrap
     pattern is a hazard if a future port validation slip
     produces e.g. negative numbers. MINOR if you want to flag.

### Category D: Stop/grace correctness (FR-E.1 launchd-safety)

D.1  `stop()` uses `process.terminate()` which sends SIGTERM
     on macOS. Good. NO SIGKILL escalation (the BUILD
     prompt forbids it for v1). Verify by grep: no
     `process.interrupt()` (which would be SIGINT), no
     `kill(_,SIGKILL)`, no `Darwin.kill`. Step 5 will own
     the launchd `bootout/bootstrap` path, which never
     SIGKILLs.

D.2  Grace polling: 100ms `Thread.sleep` between checks.
     Acceptable. Note `Thread.sleep` blocks the calling thread
     — if `stop()` is called from an async context, the caller
     blocks. Step 7 should call `stop()` from a synchronous
     context or wrap in `Task.detached`. MINOR if you want to
     flag; documenting the synchronous semantics is enough.

D.3  Port-free detection: `isPortOpen` uses POSIX
     `connect()`. If `connect()` returns 0, the port is open
     (something is listening). If it returns non-zero, the
     port is closed. Verify the AF_INET / SOCK_STREAM setup.
     Read lines 318-336: looks correct. The socket FD is
     `close()`'d via `defer`. Good resource hygiene.

D.4  Stop with no current provider: `currentProviderIfAny()`
     returns nil → `stop()` returns early. Good.

D.5  Warning on stuck port: appends to log file + writes to
     stderr. The stderr write is good for operator visibility.
     The log file write happens via the async log queue
     (asynchronous) — there's no synchronization to wait for
     the write before stop() returns. If stop() returns and
     the queue is shut down before the warning is flushed,
     the warning is lost. Edge case; flag as MINOR if you
     think it matters.

### Category E: Argv assembly (FR-B.1 alignment with PR #105 + FR-E.2)

E.1  `serveArguments()` static func validates inputs then
     assembles:
     - Base: `["serve", "--no-join", "--model", model,
       "--port", String(port)]`
     - Optional: `--kv-bits {4,8}`, `--max-context N`,
       `--max-batch N`
     Walk against PR #105 + FR-E.2:
     - `--no-join` is always set. Correct for autotune
       candidates (FR-E.2).
     - `--kv-bits` accepts only 4 or 8; matches PR #105.
     - `--max-context` accepts any positive int; matches PR
       #105's range.
     - `--max-batch` accepts any positive int; matches PR
       #105.
     Verify the test
     `testServeArgumentsRejectInvalidKnobs` covers each
     invalid input class.

E.2  Argv ordering: the BUILD prompt didn't pin a specific
     order beyond having `--no-join` present. Order matches
     prior `Process()` patterns in the codebase. OK.

E.3  Missing flags: kv-bits `nil` means "unset" — the runner
     omits the flag entirely. This matches Step 1's
     `unset,4,8` axis semantics. Correct.

E.4  Path injection risk: `model` is interpolated into argv.
     ArgumentParser handles argv as a `[String]` array, so
     shell injection isn't a vector (no shell involvement).
     If the model string contains characters like `;` or
     `&&`, they're just literal argv tokens. The downstream
     `serve` will validate the model id. Acceptable for
     Step 4.

### Category F: Resource hygiene

F.1  Log file handle: opened in `start()`, closed in
     `finishLogging()`. `finishLogging` is called from
     `clearCurrentIfSame` (which happens on natural exit
     paths) and from the spawn-failure catch in `start()`.
     Is there a path where `finishLogging` is NOT called?
     - `init` fails before `start()`: no handle opened.
     - `start()` validation fails: no handle opened.
     - `start()` succeeds and `current` is set: handle is
       owned by `RunningProvider`.
     - Runner is deallocated while `current` is non-nil:
       `RunningProvider.deinit` (Swift class) doesn't call
       `finishLogging` automatically. Are there any tests
       that drop the runner without explicit cleanup?
       Spot-check: if `testStartWaitReadyStopLifecycleWithStubBinary`
       wraps the runner in a `do { ... }` block and lets it
       go out of scope without a final `stop()`, the log
       file handle is leaked. Flag as MINOR if so.

F.2  Pipe FD leaks: each `Pipe()` opens two FDs (read + write).
     `finishLogging()` reads to EOF and clears handlers. The
     `Pipe` Swift wrapper closes its FDs on deinit. As long as
     the `Pipe` value is dropped (when `RunningProvider` is
     dropped), the FDs are closed. Acceptable.

F.3  Socket FD in `isPortOpen`: `defer { close(descriptor) }`.
     Good — even on `connect()` failure, the FD is closed.

F.4  Atomic-write of empty log file: `try Data().write(to:
     logFileURL, options: .atomic)`. This is a write-then-rename.
     Creates the file but does it leave a tmp file on failure?
     Apple's `Data.write(options: .atomic)` cleans up its
     temp file on failure. Good.

### Category G: Anti-regression

G.1  Run `swift test --package-path phase3-binary` and verify
     266 tests + 1 skipped, 0 failures. The integration test
     skip is the only non-pass status.

G.2  Did Step 4 modify any file outside the 3 listed in
     `git show 994c7ee --stat`? No — the diff is additive.

G.3  Existing CLI surface unchanged (`autotune --help`,
     `serve --help`).

### Category H: Forward-compatibility (Step 5, 6, 7, 10)

H.1  Step 5 (provider-conflict pre-flight): will need to
     detect a running launchd-managed serve and a
     foreground serve. Step 4's runner is the foreground
     path (it spawns its own Process). Step 5 will need a
     SEPARATE pre-flight check before invoking the runner.
     The runner's
     `start()` throwing `alreadyRunning` covers the
     "autotune-spawned conflict" case but NOT the "external
     serve already running on the port" case. Step 5 will
     close that gap. Acceptable.

H.2  Step 6 (pre-warm): Shape A or Shape B. The runner is
     a lifecycle primitive; pre-warm is a separate concern.
     Step 6 wraps the runner, not the other way around.
     Acceptable.

H.3  Step 7 (Stage 1 iteration): will use the runner to
     iterate candidates. The `start → waitForReady → stop`
     sequence is what Step 7 needs. The
     `ReadyStatus.processExited` case carries the rc +
     stderr tail for Step 7's failure-reason recording.
     Good.

H.4  Step 10 (signal handling): SIGINT in autotune will need
     to call `stop()` on the runner. The synchronous `stop()`
     is OK from a signal-handler context (NSLock + Thread.sleep
     are signal-safe in this scope). Acceptable.

### Category I: Anything else

Examples:
- The `safeModelName` sanitization is conservative
  (alphanumerics + `._-`). A HuggingFace model id like
  `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit` becomes
  `mlx-community-Qwen2.5-Coder-7B-Instruct-4bit`. Acceptable
  filesystem-safe form.
- The log file path uses `Int(Date().timeIntervalSince1970)`
  — second-resolution timestamps. Two consecutive starts of
  the same model+port within one second collide. Probability
  low for autotune (each candidate takes >10s) but flag as
  MINOR if you want.
- The implementation-notes section accurately describes the
  Step 4 design.

## Output structure

APPEND to
`/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`:

```
---

## Round 5 audit (Codex on 994c7ee — Step 4 round 1)

**Audited:** commit 994c7ee on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 4, round 1 of N
**Date:** 2026-06-18
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]
**Step 4 readiness:** [READY TO PROCEED TO STEP 5 / FIX REQUIRED]

### Executive summary

[2-3 paragraphs.]

### Findings

Group by category A-I. Same finding format as prior audit
rounds in this file.
```

## Out of scope for this audit

- Inspecting d-inference source
- Modifying any file
- Re-litigating Steps 1, 2, 3 (LOCKED)
- Auditing Steps 5-11 (not yet started)
- Re-litigating SPEC-013 v0.3 LOCK
- Running the integration test (gated, requires real model)

## Done criteria

You are done when:

- The new `## Round 5 audit ...` section is appended to
  `/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`
- Earlier sections (rounds 1-4) are unchanged
- Every category A-I has a section
- Every finding has severity, location, what / why /
  recommendation
- The verdict line states READY TO PROCEED TO STEP 5 or
  FIX REQUIRED
- `swift test --package-path phase3-binary` was run and the
  result is reported in the executive summary

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Run with `codex` CLI on the host that has the repo checked out.
- Expected wall-clock: 25-40 min (process spawning + async polling
  + signal handling are easier to read than easy to write).
- If verdict is READY TO PROCEED TO STEP 5: Claude commits and
  fires Step 5 (provider-conflict pre-flight + launchd drain).
- If verdict is FIX REQUIRED: Claude rolls a fix-pass + the next
  round prompt. Loop until 0 CRITICAL / 0 MAJOR.

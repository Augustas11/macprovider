# Implementation audit prompt — SPEC-013 Step 5 (provider-conflict pre-flight + drain/restore)

Operator-paste prompt for Codex GPT-5 to perform an adversarial
**code / contract / DI-surface review** of the Step 5 commit on
branch `feat/cli-autotune-impl`.

Step 5 carries:

| Commit | Step | Scope |
|---|---|---|
| d40a6f7 | 5 | `ProviderConflictDetector` (launchd + foreground detection) + `ProviderDrainer` (bootout/bootstrap + SIGTERM) + extracted `PortProbe.swift` utility + 10 unit tests (1 integration-gated) |

Full `phase3-binary` test suite is green per the commit's
`Tested:` line (283 tests, 2 skipped — Step 4 + new Step 5
integration-gated). Codex (the implementer) raised zero Open
Questions. Operator wants an independent adversarial pass BEFORE
Step 6 (pre-warm — Shape A vs Shape B) begins.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~20-30
min (Step 5 has substantial surface: launchctl output parsing,
KERN_PROCARGS2 sysctl, signal delivery, DI-closure correctness).
This is a **read-only review** — Codex MUST NOT modify any
file.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial implementation review of the Step
5 commit (d40a6f7) on branch `feat/cli-autotune-impl` in the
Augustas11/macprovider repository. The branch is already checked
out at `/Users/augstar/macprovider-poc`. Steps 1 (02b038d), 2
(ffb00fb), 3 (d0029e9), and 4 (4bcef89) are LOCKED.

Steps 6-11 have NOT landed yet — your scope is exclusively the
Step 5 commit and its anti-regression impact on Step 4's
`CandidateProviderRunner.swift` (which Step 5 lightly
refactored to use the new `MacProviderPortProbe`).

This is a **read-only review**. You MUST NOT edit any file,
commit, push, or modify the git state.

## Context

Step 5 of `specs/BUILD_SPEC_013_PROMPT.md` calls for the
provider-conflict pre-flight primitives that Step 7 will use to
detect an existing `macprovider-cli serve` BEFORE attempting to
spawn an autotune candidate. SPEC-013 v0.3 §5.5 FR-E.1 defines:

- **Launchd-managed install** (the dominant SPEC-003 install path):
  service label `live.streamvc.macprovider` loaded via
  `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/<plist>`.
  Detection via `launchctl list | grep`; drain via
  `launchctl bootout gui/$UID/<label>`; restore via
  `launchctl bootstrap gui/$UID <plist>`.

- **Foreground / manually-run process**: PID + argv match on
  `macprovider-cli serve` AS A WHOLE-WORD subcommand match,
  excluding the autotune process itself.

Step 5 is ADDITIVE. The detector and drainer are NOT called from
`AutotuneCommand.run()` yet — Step 7 wires the pre-flight; Step
10 wires post-tune restore.

The Step 5 implementation uses dependency injection on every
side-effecting operation (launchctl exec, signal sending,
process-list snapshot, port probe, foreground restart, warning
writer) so unit tests can verify behavior without mutating real
launchd state. This is the load-bearing testability decision.

## Required reading (in this order)

1. The Step 5 commit via `git show d40a6f7`. The commit message
   contains the rejected alternatives (substring argv matching,
   SIGKILL escalation).

2. The Step 5 source under audit:
   - `phase3-binary/Sources/macprovider-cli/ProviderConflictDetector.swift`
     (314 lines, NEW). The bulk of the audit's surface.
   - `phase3-binary/Sources/macprovider-cli/PortProbe.swift`
     (23 lines, NEW). Extracted from CandidateProviderRunner.
   - `phase3-binary/Sources/macprovider-cli/CandidateProviderRunner.swift`
     — 23-line refactor (extracted `isPortOpen` → `MacProviderPortProbe.isOpen`).
   - `phase3-binary/Tests/macprovider-cliTests/ProviderConflictDetectorTests.swift`
     (155 lines, NEW; 10 unit tests including 1 integration-gated).
   - `phase3-binary/implementation-notes.html` — new
     `spec013-autotune-step5` section.

3. The locked SPEC (READ-ONLY):
   - `specs/SPEC-013-cli-autotune.md` v0.3 §5.5 FR-E.1 "Drain
     sequence on the launchd-managed install path" (the
     bootout/bootstrap sequence + grace + restore rules).
   - §5.5 FR-E.1 "Drain sequence on the foreground process
     path" (SIGTERM only; opt-in restart-foreground flag).

4. SPEC-003 v0.9.2 §FR-C5 — the launchd label
   (`live.streamvc.macprovider`) and bootstrap command. Verify
   Step 5's hardcoded label matches SPEC-003 byte-for-byte
   (this was the round-1 audit E.1 finding from the SPEC-013
   v0.1 review).

5. The install-script reality:
   - `phase3-binary/dist/install.sh` lines ~728-749 + ~923 —
     the actual launchctl invocations and label pattern.
   - `phase3-binary/dist/launchd-plist-template.plist` — the
     plist key shape.
   - `phase3-binary/Sources/macprovider-cli/UninstallCommand.swift`
     + `SelfUpdate.swift` — patterns for invoking launchctl
     from Swift. Verify Step 5 matches these idioms.

6. Local style guide:
   - The Step 4 commit (4bcef89) — recent Swift idioms and
     test patterns in this codebase.
   - The Step 3 commit (d0029e9) — for DI-via-closure pattern
     comparison (`AutotuneDB` doesn't use DI but the runner
     does for `URLSession`).

## Severity definitions (unchanged from prior steps)

- **CRITICAL** — silent contract violation of FR-E.1 (e.g.
  `gui/$UID/...` is malformed and bootout silently no-ops);
  silent contract violation of FR-E.2 self-exclusion (e.g.
  the detector matches the autotune process itself, causing a
  self-refusal loop); SIGKILL escalation in v1; argv extraction
  reads past the buffer; anti-regression broke a Step 4 test;
  the `CandidateProviderRunner.swift` refactor changed behavior.
- **MAJOR** — Step 5 contract gap (e.g. detection misses a
  launchctl output variant like PID `-`; the foreground match
  matches `macprovider-cli-helper` as a substring); DI surface
  too narrow (a production effect leaks into a test); test
  passes by tautology.
- **MINOR** — quality issues, naming inconsistencies, doc
  gaps.
- **QUESTION** — design choice Step 5 made where the SPEC was
  silent (e.g. the choice of `gui/<uid>` vs `user/<uid>`
  launchctl domain).

## Critical constraints (unchanged from prior steps)

1. SPEC-013 v0.3 is LOCKED.
2. Anti-regression — `swift test --package-path phase3-binary`
   MUST report 283 tests (2 skipped), 0 failures.
3. Strict clean-room on d-inference.
4. Read-only.
5. NO SIGKILL escalation in v1. The commit message lists
   "SIGKILL escalation" as rejected. Verify no `SIGKILL` /
   `Process.interrupt()` / `kill(_, SIGKILL)` exists in the
   new code.
6. **Self-exclusion is load-bearing.** If the autotune process
   ever matches its own foreground-serve pre-flight, autotune
   refuses to run = CRITICAL. The detector MUST exclude argv
   containing `autotune`.

## Audit categories — work through each

### Category A: launchd detection correctness (FR-E.1)

A.1  Label match: `ProviderConflictDetector.launchdLabel = "live.streamvc.macprovider"`.
     Cross-check against:
     - SPEC-003 v0.9.2 §FR-C5
     - `phase3-binary/dist/launchd-plist-template.plist` line ~7
     - `phase3-binary/dist/install.sh` line ~749
     - `phase3-binary/Sources/macprovider-cli/UninstallCommand.swift` line ~23
     - `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift` lines ~202, ~217
     Any drift between Step 5's constant and these sites = CRITICAL.

A.2  `parseLaunchdManagedPID(from:)`: parses `launchctl list`
     output. Real `launchctl list` format is roughly:
     `<PID>\t<Status>\t<Label>` where PID is `-` for inactive
     services. Walk the parser:
     - Splits on space OR tab (correct — launchctl uses
       whitespace).
     - Checks if any field equals the label (whole-token
       match — good).
     - Returns the first field as PID, or nil if `-`.
     Verify with each plausible launchctl output variant:
     - `1234\trunning\tlive.streamvc.macprovider`
     - `-\t-\tlive.streamvc.macprovider` (inactive)
     - empty output (no service installed)
     - the label appears as a SUBSTRING of another label
       (e.g. `live.streamvc.macprovider.helper`) — the
       `fields.contains(Substring(launchdLabel))` check uses
       whole-field equality, so substring won't match. Good.
     If any of these isn't handled = MAJOR.

A.3  `defaultLaunchctlList`: invokes `/bin/launchctl list`
     via `Process()`. Verify:
     - Captures stdout via Pipe.
     - Throws if launchctl exits non-zero.
     - Doesn't capture stderr (which would mix with stdout
       parsing). The Pipe is only on stdout — good.
     If launchctl is missing (unusual but possible in CI),
     `Process.run()` throws — the caller sees the error. OK.

A.4  Tests for launchd detection:
     - `testDetectLaunchdManagedProviderFromLaunchctlList` —
       injects a stub launchctl output. Walk the test setup.
     - `testDetectNoneWhenLaunchctlAndProcessListsAreEmpty` —
       both empty inputs → .none. Good baseline.
     - `testRealLaunchctlListWhenIntegrationEnabled` — gated
       behind env var, exercises the real path. Acceptable
       integration deferral.

### Category B: foreground detection correctness (FR-E.2 self-exclusion)

B.1  `isForegroundServe(argv:)`: the function's contract is
     "argv represents a `macprovider-cli serve ...` process,
     NOT autotune, NOT a helper with a similar name." Walk
     the implementation:
     ```
     guard !argv.contains("autotune") else { return false }
     for index in argv.indices {
         guard URL(fileURLWithPath: argv[index]).lastPathComponent == "macprovider-cli" else {
             continue
         }
         let serveIndex = argv.index(after: index)
         if argv.indices.contains(serveIndex), argv[serveIndex] == "serve" {
             return true
         }
     }
     ```
     - Self-exclusion: `argv.contains("autotune")` — checks
       ANY argv element equals "autotune". This catches the
       autotune process itself (argv contains the subcommand
       name "autotune"). Good.
     - Binary match: uses `lastPathComponent` so
       `/usr/local/bin/macprovider-cli` and `./macprovider-cli`
       and bare `macprovider-cli` all match. Good.
     - Subcommand match: `argv[index+1] == "serve"` — exact
       string match. So `serve-helper` doesn't match (different
       string). Good.
     - But what about a process like `/usr/local/bin/macprovider-cli-helper serve`?
       `lastPathComponent` returns `macprovider-cli-helper`,
       which fails the `== "macprovider-cli"` check. Good.
     - What about `/usr/local/bin/macprovider-cli serve-foo`?
       The subcommand match fails because `"serve-foo" != "serve"`.
       Good.

B.2  Edge cases the audit should test mentally:
     - argv `["macprovider-cli", "serve", "--no-join", "--model", "X"]`
       → matches. Correct (foreground serve detected).
     - argv `["macprovider-cli", "autotune", "--target-context", "2000"]`
       → does NOT match (autotune self-exclusion). Correct.
     - argv `["macprovider-cli", "autotune", "--candidate-models", "model-serve"]`
       → does NOT match (argv contains "autotune"). Correct.
     - argv `["/path/macprovider-cli-helper", "serve"]`
       → does NOT match (lastPathComponent != "macprovider-cli"). Correct.
     - argv `["sh", "-c", "macprovider-cli serve"]`
       → does NOT match (the "serve" is INSIDE a quoted shell
       string, not its own argv element). Correct, but limits
       detection to direct exec; flag as QUESTION if you think
       sh-launched serves are common.
     - Empty argv: `argv.contains("autotune")` returns false,
       the loop doesn't iterate, returns false. Correct (no
       conflict).

B.3  Tests for foreground detection:
     - `testDetectForegroundServeProcess` — argv with
       macprovider-cli + serve → .foreground.
     - `testAutotuneProcessDoesNotMatchForegroundServe` —
       self-exclusion regression lock. Verify the test argv
       actually contains "autotune".
     - `testServeSubstringDoesNotMatchForegroundServe` —
       the helper-name regression lock. Verify the test argv
       uses a substring-like name (e.g. `serve-helper`,
       `macprovider-cli-helper`).

B.4  `defaultProcessList`: uses `proc_listpids(PROC_ALL_PIDS, ...)`
     to get all PIDs, then `processArguments(pid:)` to extract
     argv via `sysctl(CTL_KERN, KERN_PROCARGS2, pid)`. This is
     the standard macOS API path. Walk the parsing:
     - First 4 bytes are argc (Int32). Read it.
     - Skip the exec path (null-terminated string after argc).
     - Skip null padding.
     - Read `argc` null-terminated strings.
     This is correct per Apple's KERN_PROCARGS2 documentation.
     Buffer-overrun safety: every loop checks `index < size`. Good.
     Permissions: `sysctl(KERN_PROCARGS2, <other-uid-pid>)`
     may fail (returns EPERM); the function returns nil and the
     caller skips. Acceptable for unprivileged runs.

### Category C: Drain correctness (FR-E.1)

C.1  Launchd drain: `launchctlRunner(launchctlPath, ["bootout", launchdServiceTarget])`
     where `launchdServiceTarget = "gui/<uid>/<label>"`. Verify:
     - `gui/<uid>` matches the launchctl convention for the
       user GUI session (the SPEC-003 install scripts use
       this). Cross-check against
       `phase3-binary/dist/install.sh` line ~728-729 (where the
       install does `launchctl bootstrap gui/$UID <plist>`).
     - `<label>` is the same label as detection. Good.

C.2  Foreground drain: `signalSender(pid, SIGTERM) == 0`. If
     non-zero, throws POSIXError. Good.

C.3  Grace polling: `waitForDrainCompletion` polls every 100ms
     up to graceSeconds. Checks port-not-open AND (for
     foreground) process-not-running. Good.

C.4  SIGKILL-disabled warning: "warning: foreground provider
     pid <n> did not exit within <X>s grace; SIGKILL is
     disabled in v1". Written to stderr via warningWriter.
     Good — operator visibility for the stuck case.

C.5  Return value: `.drained` if port freed, `.portStillOpen(port:)`
     if not. Step 7 will branch on this — acceptable contract.

C.6  Tests for drain:
     - `testLaunchdDrainInvokesBootoutWithGuiServiceTarget` —
       verifies the exact launchctl args. Walk the test
       assertions.
     - `testForegroundDrainSendsSIGTERMToPID` — verifies the
       SIGTERM signal value. Walk the test.

### Category D: Restore correctness (FR-E.1)

D.1  Launchd restore: `launchctlRunner(launchctlPath, ["bootstrap", launchdDomain, plistURL.path])`
     where `launchdDomain = "gui/<uid>"` (NO label). Verify
     this matches Apple's `launchctl bootstrap` syntax:
     `bootstrap <domain-target> <path>`. Yes — domain target
     is `gui/<uid>`, path is the plist. Good.

D.2  Plist URL default:
     `FileManager.default.homeDirectoryForCurrentUser
       .appendingPathComponent("Library/LaunchAgents/live.streamvc.macprovider.plist")`.
     Cross-check against
     `phase3-binary/dist/install.sh` line ~728 and
     `UninstallCommand.swift` line ~54. Any path drift =
     CRITICAL.

D.3  Foreground restore: only re-spawns if `restartForeground
     == true`. Otherwise returns `.skipped`. SPEC-013 §5.5 says
     foreground restart is opt-in via `--restart-foreground`
     (Step 1 added this flag). Good.

D.4  `defaultForegroundRestarter`: if argv[0] starts with "/",
     execs it directly; else execs via /usr/bin/env. Reasonable.

D.5  Tests for restore:
     - `testLaunchdRestoreInvokesBootstrapWithGuiDomainAndPlist`
       — verifies bootstrap args. Walk.
     - `testForegroundRestoreSkipsUnlessRestartForegroundIsTrue`
       — verifies the opt-in. Walk.

### Category E: DI surface completeness

The Step 5 design's key testability decision: every side-effecting
operation is closure-injected. Walk the `ProviderDrainer` init
to enumerate the DI surface:
- `launchctlRunner` — exec launchctl
- `signalSender` — kill() syscall
- `processIsRunning` — kill(pid, 0) probe
- `portIsOpen` — connect() probe
- `foregroundRestarter` — exec the restart
- `warningWriter` — stderr write

E.1  Every effectful operation has a DI seam? Yes — listed
     above. If any production effect is NOT injected (e.g.
     direct `Darwin.kill(...)` in `drain` instead of
     `signalSender(...)`), the tests can't isolate it = MAJOR.

E.2  Default implementations: each closure has a real default.
     Verify the defaults match the production-expected
     behavior (e.g. `defaultProcessIsRunning` uses
     `Darwin.kill(pid, 0)` which is the standard process-exists
     probe).

E.3  Test isolation: walk `ProviderConflictDetectorTests` to
     verify NO test executes a real launchctl, sends a real
     signal, opens a real socket, or restarts a real process.
     Any test that does = MAJOR (CI brittleness).

### Category F: Anti-regression on Step 4

F.1  The `CandidateProviderRunner.swift` 23-line diff replaces
     two calls to private `isPortOpen` with
     `MacProviderPortProbe.isOpen(...)`. Verify:
     - The replacement is byte-equivalent in behavior.
     - The deleted private `isPortOpen` method body matches
       the new `MacProviderPortProbe.isOpen` body
       byte-for-byte.
     - No other behavior in CandidateProviderRunner changed.

F.2  Step 4's tests (Step 4 round-1 fix-pass tests included)
     all still pass under the refactor. `swift test
     --filter CandidateProviderRunnerTests` should report 13
     tests + 1 skipped, 0 failures.

F.3  PortProbe.swift is in the same module
     `(macprovider_cli)`, not a separate module. Verify by
     reading: no `import` of a new module is required.

### Category G: Test coverage

G.1  10 tests total (1 integration-gated). Walk each:
     - Step 5 has 5 detector tests + 4 drain/restore tests + 1
       integration-gated. The detector coverage names the
       expected enums (.launchdManaged, .foreground, .none)
       and the self-exclusion + helper-name regression locks.
     - The drain tests verify launchctl args + SIGTERM signal
       via injected closures.
     - The restore tests verify bootstrap args + the
       restart-foreground gate.

G.2  Coverage gaps to flag:
     - Is there a test for `parseLaunchdManagedPID` returning
       `(found: true, pid: nil)` when PID is `-`? (the
       inactive-service case)
     - Is there a test for empty/malformed launchctl output?
     - Is there a test for the SIGKILL-disabled warning being
       emitted when foreground drain doesn't free the
       process?
     - Is there a test for `defaultProcessIsRunning` returning
       true for the current process (`getpid()`)? (sanity
       check for the helper)
     Flag as MINOR per gap if you think they're load-bearing
     enough.

### Category H: Forward-compatibility

H.1  Step 7 will call detector at autotune start. Verify the
     detector's return enum (`ProviderConflict`) gives Step 7
     enough info to:
     - Refuse with a clear stderr message naming the install
       path
     - Record `tune_runs.exit_reason = 'provider_conflict'`
     - Branch on `.launchdManaged` vs `.foreground` for the
       error text
     Yes — the enum's cases carry pid (for foreground) and
     the launchdManaged variant indicates which install path.
     Step 7 can branch on the case.

H.2  Step 10 (signal handling / failure modes) will call
     restore at autotune exit. Verify the drainer's restore
     function can be called multiple times safely (idempotent)?
     - Calling restore for `.none` returns `.skipped`. Good.
     - Calling restore for `.launchdManaged` after a
       successful bootstrap: launchctl bootstrap returns an
       error if the service is already loaded. The test doesn't
       cover this. MINOR — Step 10 will need to handle.

H.3  The DI surface lets Step 7's main loop inject a single
     `ProviderDrainer` with the same set of closures, ensuring
     the autotune lifecycle uses one consistent set of effects.
     Good.

### Category I: Anything else

Examples that DO belong here:
- Naming: `MacProviderPortProbe` is an enum with a single
  static method. Could be a free function but the enum
  namespace is the local Swift convention here (acceptable).
- The `processArguments` parser uses `String(cString:)` which
  is safe but assumes null-terminated UTF-8. argv strings
  are not guaranteed UTF-8 but are in practice. Acceptable.
- The Step 5 implementation-notes section accurately
  describes the design decisions.

## Output structure

APPEND to
`/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`:

```
---

## Round 7 audit (Codex on d40a6f7 — Step 5 round 1)

**Audited:** commit d40a6f7 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 5, round 1 of N
**Date:** 2026-06-18
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]
**Step 5 readiness:** [READY TO PROCEED TO STEP 6 / FIX REQUIRED]

### Executive summary

[2-3 paragraphs.]

### Findings

Group by category A-I.
```

## Out of scope for this audit

- Inspecting d-inference source
- Modifying any file
- Re-litigating Steps 1, 2, 3, 4 (LOCKED)
- Auditing Steps 6-11 (not yet started)
- Re-litigating SPEC-013 v0.3 LOCK
- Running the integration test (gated, requires real launchctl
  state mutation)

## Done criteria

You are done when:

- The new `## Round 7 audit ...` section is appended
- Earlier sections (rounds 1-6) are unchanged
- Every category A-I has a section
- Every finding has severity, location, what / why /
  recommendation
- `swift test --package-path phase3-binary` was run and the
  result reported in the executive summary
- The verdict line states READY TO PROCEED TO STEP 6 or
  FIX REQUIRED

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Run with `codex` CLI on the host that has the repo checked out.
- Expected wall-clock: 20-30 min.
- If verdict is READY TO PROCEED TO STEP 6: Claude commits and
  fires Step 6 (pre-warm — Shape A vs Shape B).
- If verdict is FIX REQUIRED: Claude rolls a fix-pass + next
  round prompt.

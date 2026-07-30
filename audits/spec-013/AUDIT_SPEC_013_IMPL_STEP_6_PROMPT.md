# Implementation audit prompt — SPEC-013 Step 6 (pre-warm Shape B)

Operator-paste prompt for Codex GPT-5 to perform an adversarial
**code / contract / classification review** of the Step 6 commit
on branch `feat/cli-autotune-impl`.

Step 6 carries:

| Commit | Step | Scope |
|---|---|---|
| e7bfab5 | 6 | `HuggingFaceCacheChecker` + `ProviderPreWarmer` + `PreWarmResult` enum + 7 unit tests |

Full `phase3-binary` test suite is green per the commit's
`Tested:` line (293 tests, 2 skipped). Codex (the implementer)
raised zero Open Questions. Operator wants an independent
adversarial pass BEFORE Step 7 (Stage 1 iteration — the
heaviest step in the BUILD sequence) begins.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~20-30
min. This is a **read-only review** — Codex MUST NOT modify
any file.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial implementation review of the Step
6 commit (e7bfab5) on branch `feat/cli-autotune-impl` in the
Augustas11/macprovider repository. The branch is already checked
out at `/Users/augstar/macprovider-poc`. Steps 1 (02b038d), 2
(ffb00fb), 3 (d0029e9), 4 (4bcef89), and 5 (3adddbf) are LOCKED.

Steps 7-11 have NOT landed yet — your scope is exclusively the
Step 6 commit and its anti-regression impact on the existing
`phase3-binary/`.

This is a **read-only review**.

## Context

Step 6 implements FR-D pre-warm semantics per SPEC-013 v0.3 §5.4.
The BUILD prompt picked **Shape B**: rely on the runtime's online
fallback during model load, with measurement isolation enforced by
the Step 4 `waitForReady` returning AFTER the load completes (so
Step 7's trial measurement, which fires AFTER `ProviderPreWarmer`
returns, sees only WARM weights).

`ProviderPreWarmer.prewarmAndProbe`:
1. Check if model is cached locally (HuggingFaceCacheChecker).
2. Start the candidate provider via CandidateProviderRunner.
3. Wait for readiness (waits for load + first response).
4. Classify the outcome:
   - `.ready` → `.warmed(cacheState:, loadDurationSec:)`
   - `.processExited(rc:, stderrTail:)` → classify stderr for
     integrity markers (8 patterns); `.failed(.integrity, ...)` or
     `.failed(.transient, ...)`.
   - `.timeout(lastError:)` → `.failed(.transient, "load timeout...")`
5. `defer { runner.stop(graceSeconds:) }` — always cleanup.

FR-D.2 transient vs integrity classification is load-bearing for
Step 7's iteration: transient = advance to next candidate;
integrity = abort the whole run (`exit_reason = 'pre_warm_integrity_failure'`).
A misclassified integrity error (treated as transient) would
silently advance past a security-relevant failure.

## Required reading (in this order)

1. The Step 6 commit via `git show e7bfab5`. The commit message
   contains the rejected alternative (Shape A models pull
   subcommand).

2. The Step 6 source under audit:
   - `phase3-binary/Sources/macprovider-cli/ProviderPreWarmer.swift`
     (148 lines, NEW).
   - `phase3-binary/Tests/macprovider-cliTests/ProviderPreWarmerTests.swift`
     (317 lines, NEW; 7 unit tests).
   - `phase3-binary/implementation-notes.html` — new
     `spec013-autotune-step6` section.

3. The locked SPEC (READ-ONLY):
   - `specs/SPEC-013-cli-autotune.md` v0.3 §5.4 FR-D.1 (Shape
     A vs Shape B contract, measurement-isolation rule).
   - §5.4 FR-D.2 (transient vs integrity classification rules;
     integrity-class examples named in the SPEC: "signature
     mismatch, weight hash mismatch, repository contents
     inconsistent with expected shape (e.g. missing
     tokenizer.json), or any tampering signal").
   - §5.8 FR-H.3 ("Integrity class ... ABORT the whole run with
     `exit_reason = 'pre_warm_integrity_failure'`").
   - §6 NFR-4 (the "nothing leaves the machine except FR-D
     HuggingFace pre-warm" exception — note this exception
     COVERS Shape B's runtime online-fallback).

4. The Step 4 source for forward-compat context:
   - `phase3-binary/Sources/macprovider-cli/CandidateProviderRunner.swift`
     — particularly `ReadyStatus` (the input to Step 6's
     classifier) and the test fixture pattern Step 6 mirrors.

5. The Hugging Face cache layout reference: the canonical layout
   for a downloaded model `mlx-community/Llama-3.2-1B-Instruct-4bit`
   is:
   ```
   ~/.cache/huggingface/hub/
     models--mlx-community--Llama-3.2-1B-Instruct-4bit/
       blobs/                  # actual file contents
       refs/main               # commit ref pointing into snapshots
       snapshots/<commit>/     # symlinks into blobs/, named by
                               # logical filename (model.safetensors,
                               # tokenizer.json, etc.)
   ```
   Step 6's checker looks at `snapshots/.../` and counts any
   regular file OR symbolic link as "cached." Verify this matches
   the actual HF cache layout (snapshots/ entries are symlinks).

## Severity definitions (unchanged from prior steps)

- **CRITICAL** — silent contract violation of FR-D.2 (e.g. a
  known integrity error is classified as transient, silently
  advancing past a security failure); silent contract violation
  of FR-D.1 measurement isolation (e.g. load time bleeds into
  gate-ttft-ms); anti-regression broke a Step 4 or Step 5 test;
  the `defer` cleanup fails to stop a running provider.
- **MAJOR** — Step 6 contract gap (e.g. an integrity marker is
  missing from the list that the SPEC explicitly named; the
  cache check has a false-positive that misreports a partial
  download as cached); test gap that hides a likely production
  failure.
- **MINOR** — quality issues; classification heuristic could be
  tighter; integrity-marker list could be longer.
- **QUESTION** — design choice Step 6 made where the SPEC was
  silent (e.g. case-insensitive substring search for integrity
  markers vs case-sensitive).

## Critical constraints (unchanged from prior steps)

1. SPEC-013 v0.3 is LOCKED.
2. Anti-regression — `swift test --package-path phase3-binary`
   MUST report 293 tests (2 skipped), 0 failures.
3. Strict clean-room on d-inference.
4. Read-only.
5. NO SIGKILL escalation in v1.
6. **Integrity classification is asymmetric.** A misclassified
   integrity-as-transient = CRITICAL (security failure
   silently advanced). A misclassified transient-as-integrity =
   MAJOR (operator aborted run for no reason; recoverable). The
   asymmetry guides severity calls.

## Audit categories — work through each

### Category A: FR-D.1 measurement isolation

A.1  `prewarmAndProbe` separates load timing from measurement.
     The load duration is from `started = now()` (BEFORE
     start) to `now()` (AFTER waitForReady returns .ready).
     The trial measurement (Step 7) starts AFTER
     `prewarmAndProbe` returns. So load time is excluded from
     gate-ttft-ms. Verify by reading the contract.

A.2  `.warmed.loadDurationSec` is informational, not a feasibility
     metric. Step 7 will not feed it to the FR-A.3 gate.
     Verify nothing in Step 6 leaks load time into a metric
     Step 7 might mistake for trial time.

A.3  `now: () -> Date` injection lets tests control time. Verify
     the production default is `Date.init` (system clock).
     Acceptable.

### Category B: FR-D.2 transient vs integrity classification

B.1  Integrity-marker list (8 patterns):
     - "signature mismatch"
     - "hash mismatch"
     - "manifest verification failed"
     - "weight verification failed"
     - "checksum mismatch"
     - "signature verification failed"
     - "checksum signature invalid"
     - "missing tokenizer.json"

     Cross-check against the SPEC's named examples:
     - "signature mismatch" ✓
     - "weight hash mismatch" ✓ (matches via "hash mismatch")
     - "repository contents inconsistent with expected shape
       (e.g. missing tokenizer.json)" — covered by "missing
       tokenizer.json"
     - "tampering signal" — vague; covered by signature/checksum/
       verification markers.

     Are there KNOWN integrity-error message strings from
     mlx-swift, safetensors loaders, or Hugging Face transport
     that AREN'T in the list? Cross-check against any
     publicly-documented error message text. If you find a
     known integrity message string not covered = MAJOR.

B.2  Case sensitivity: the matcher `.lowercased().contains($0)`
     normalizes the input to lowercase. The markers are already
     lowercase in the list. So matching is case-insensitive.
     This is the right call (error messages can vary in casing
     across Apple frameworks and Python tracebacks). Good.

B.3  Substring matching false-positive risk: "hash mismatch"
     is short. A benign log line like "no hash mismatch
     detected" would match. A "hash mismatch warning (recovered)"
     would also match. This is a false-positive aborting an
     advanceable transient failure = MAJOR if you find a
     plausible production log line. Probability is low (most
     mlx errors don't contain "hash mismatch" as decorative
     text), but flag the risk class.

B.4  Substring matching false-negative risk: an integrity
     error in a non-English locale (e.g. localized macOS
     error messages) would not match the English markers.
     mlx-swift and Hugging Face errors are English. Apple
     POSIX errors can localize (e.g. "fichier introuvable"
     for ENOENT in French locales). If a Python or C++
     dependency outputs localized errors, the matcher might
     miss them. QUESTION if you think operators in non-en
     locales might be affected.

B.5  Empty stderrTail: when the process exits without writing
     to stderr (e.g. SIGKILL by external operator), `stderrTail`
     is empty. The matcher returns `.transient` (no markers
     found). This is the safer default (advance, don't abort).
     Good.

B.6  Test coverage for classification:
     - `testPreWarmerClassifiesNetworkExitAsTransient` — exit
       with stderr containing "network unreachable" → transient.
     - `testPreWarmerClassifiesSignatureMismatchAsIntegrity` —
       exit with stderr containing "signature mismatch" →
       integrity.
     - `testPreWarmerClassifiesReadinessTimeoutAsTransient` —
       timeout (no exit) → transient.

     Walk each test fixture for the stub binary's stderr output
     and verify the substring match is what the test asserts.

     Coverage gaps:
     - No test for the "missing tokenizer.json" integrity marker.
     - No test for case-insensitive matching (e.g. "Signature
       Mismatch" with mixed case).
     - No test for short-marker false positive (e.g. stderr
       containing "no hash mismatch detected" classified as
       integrity).
     Each missing test = MINOR.

### Category C: HuggingFaceCacheChecker correctness

C.1  Path layout: `cacheRoot/models--<org>--<name>/snapshots/<revision>/`
     for `mlx-community/Llama-3.2-1B-Instruct-4bit`. Walk
     `repositoryDirectory(for:)`:
     - Splits modelID on "/" with maxSplits=1.
     - Requires both halves non-empty.
     - Returns `cacheRoot/models--<org>--<name>`.
     Correct against HF layout.

C.2  Model ID validation: what if `modelID` contains other "/"
     beyond the first (e.g. someone passes a path)? maxSplits=1
     keeps the second half as a single string. Good.

C.3  Snapshot detection: lists snapshots/ contents, requires
     at least one entry that is a directory AND contains at
     least one regular file or symbolic link. The HF cache
     uses symlinks (snapshots/.../<file> → ../../blobs/<hash>).
     Following symbolic links: `containsAnyFile` checks for
     `.isRegularFile == true` OR `.isSymbolicLink == true`.
     Without `.skipsSubdirectoryDescendants` the enumerator
     recurses; for HF snapshots this is fine (flat layout).
     Good.

C.4  Partial-download false positive: if the HF cache has a
     snapshots directory but the blobs are not yet complete
     (e.g. download was interrupted), the symlink might point
     to a missing target. The current check `containsAnyFile`
     would still return true (the symlink exists in the
     directory; we don't follow it to check the target).
     Is this a false positive? A partial download will fail
     at serve start; the pre-warmer would classify the
     resulting failure correctly (load fails → process
     exits → classifier inspects stderr). So the cache check's
     false positive doesn't lead to wrong outcomes; it just
     misreports `.alreadyCached` when the truth is "partially
     cached, will refetch." Acceptable for v1.

C.5  Test coverage:
     - `testHuggingFaceCacheCheckerFindsSnapshotWithFile`
     - `testHuggingFaceCacheCheckerRejectsEmptySnapshot`

C.6  Custom `cacheRoot` injection: lets tests use a temp
     directory without touching the user's real HF cache.
     Good.

### Category D: Provider lifecycle wrapping

D.1  `defer { runner.stop(graceSeconds: stopGraceSeconds) }`
     fires on every exit path (normal return + throw).
     Verify:
     - On `.warmed`: runner stops cleanly (port released).
     - On `.failed`: runner stops the (possibly already-
       exited) provider.
     - On thrown exception (e.g. from `runner.start()`
       throwing): the defer still fires; `stop()` on a
       never-started runner returns `.stopped` (Step 4 A.1).
     Good.

D.2  Stop-grace default of 10s: reasonable for autotune
     candidates (model load can stretch but stop is fast).

D.3  `runner.start()` failure: throws from `prewarmAndProbe`.
     The defer still calls `stop()`. Good.

D.4  `runner.waitForReady()` cancellation: if the caller
     cancels the Task, `waitForReady` throws CancellationError;
     defer fires; stop runs. Good.

### Category E: Test fixtures

E.1  Step 6 tests use stub binaries (matching the Step 4
     pattern). Walk the test fixtures:
     - Happy-path stub: serves 200 and sleeps; the test
       asserts `.warmed`.
     - Cold-cache stub: same stub, but the test sets up an
       empty cache root → `.fetchedDuringLoad`.
     - Network-failure stub: exits with rc=1 and stderr
       "network unreachable" → `.failed(.transient, ...)`.
     - Signature-mismatch stub: exits with rc=1 and stderr
       "signature mismatch" → `.failed(.integrity, ...)`.
     - Timeout stub: hangs without becoming ready →
       `.failed(.transient, "load timeout...")`.

     For each, verify:
     - The stub binary's stderr exactly contains the marker the
       test expects.
     - The test asserts the EXACT enum case (not just
       `.failed`).
     - The `defer` cleanup leaves no zombie processes.

E.2  Test isolation: the cache-checker tests use a temp
     directory. The pre-warmer tests use the stub binary
     approach. Neither touches the real HF cache or real
     macprovider-cli. Good.

E.3  `now()` injection: which tests use it? The happy-path
     tests need it to assert non-zero `loadDurationSec` without
     depending on real time. Verify the tests inject a
     deterministic `now()` to make the assertion stable.

### Category F: Anti-regression

F.1  Run `swift test --package-path phase3-binary` and verify
     293 tests + 2 skipped, 0 failures.

F.2  Did Step 6 modify any file outside the 3 in
     `git show e7bfab5 --stat`? No — the diff is fully
     additive. Verify.

F.3  `ProviderPreWarmer` and `HuggingFaceCacheChecker` are
     top-level types in `ProviderPreWarmer.swift`. They don't
     touch Step 1-5 types beyond CandidateProviderRunner
     (read-only — `runner.start()`, `runner.waitForReady()`,
     `runner.stop()`). Good encapsulation.

### Category G: Forward-compatibility (Step 7, 10)

G.1  Step 7 will call `prewarmAndProbe` for each candidate. The
     returned `PreWarmResult` gives Step 7 enough info to:
     - On `.warmed`: proceed to trial measurement.
     - On `.failed(.transient, ...)`: advance to next
       candidate.
     - On `.failed(.integrity, ...)`: abort the whole run with
       `exit_reason = 'pre_warm_integrity_failure'`.
     Verify the enum is sufficient (yes — has both class and
     reason).

G.2  Step 7's trial measurement starts AFTER `prewarmAndProbe`
     returns `.warmed`. The provider is STILL ALIVE at that
     point because `defer { runner.stop(...) }` only fires
     when `prewarmAndProbe` returns. Wait — that's wrong! If
     `defer` fires on the way out, then by the time the
     caller sees `.warmed`, the provider has been stopped.
     Step 7 needs the provider alive for the trial. Is this a
     CRITICAL bug?

     Read the code carefully:
     ```
     defer { runner.stop(graceSeconds: stopGraceSeconds) }
     try runner.start(...)
     let readyStatus = try await runner.waitForReady(...)
     switch readyStatus {
     case .ready:
         return .warmed(...)
     ...
     }
     ```
     The `defer` fires when the function returns OR throws.
     So `return .warmed(...)` → defer fires → stop() → return.
     By the time the caller sees `.warmed`, the provider is
     stopped.

     Then Step 7 would need to start ANOTHER provider for the
     trial. That doubles the load time. Is this the intended
     design? Re-read the BUILD prompt's Step 6 instructions...

     The BUILD prompt said: "Step 6 is the load phase ONLY"
     and "Step 7 will fire trials AFTER ProviderPreWarmer
     returns." If the provider is stopped after pre-warm,
     Step 7's trial measurement would need a SECOND warm load
     (with warm cache this time, so faster, but still
     non-trivial).

     Is the intended design:
     (a) Step 6 = load phase, provider stopped at end; Step 7
         starts a new provider for measurement (load is fast
         because cache is warm).
     (b) Step 6 = load phase, provider STAYS ALIVE; Step 7
         measures against the alive provider.

     The current implementation does (a). The BUILD prompt
     said "Step 7 will fire trials AFTER ProviderPreWarmer
     returns" which is ambiguous but the current impl is
     plausible. However:
     - Restarting for the trial wastes the load time (load
       happens TWICE: once in pre-warm, once in trial).
     - The cache is warm after pre-warm, so trial-load is
       fast. Tolerable.

     If the intended design is (b), this is a CRITICAL
     design bug in Step 6. If (a), it's an architectural
     choice that Step 7 can adapt to.

     Flag this as a QUESTION for the operator: which design
     was intended? If (b), the `defer` should be removed and
     Step 7 must own the runner.stop() call. If (a), the
     current impl is correct but worth documenting in
     implementation-notes.

G.3  Step 10 signal handling: SIGINT during a pre-warm
     interrupts the async Task. The defer fires; the stop is
     synchronous and blocks; eventually the signal handler
     returns. Acceptable.

### Category H: Anything else

Examples:
- The integrity-marker list might be incomplete. Codex can
  augment via mlx-swift error message inspection (clean-room
  safe; mlx-swift is MIT not Darkbloom).
- The cache check's symlink behavior — does it correctly
  detect the HF symlink-into-blobs pattern? Walk the code.
- Implementation-notes section accurately describes Shape B
  pick + rationale.

## Output structure

APPEND to
`/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`:

```
---

## Round 9 audit (Codex on e7bfab5 — Step 6 round 1)

**Audited:** commit e7bfab5 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 6, round 1 of N
**Date:** 2026-06-18
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]
**Step 6 readiness:** [READY TO PROCEED TO STEP 7 / FIX REQUIRED]

### Executive summary

[2-3 paragraphs.]

### Findings

Group by category A-H.
```

## Out of scope

- Inspecting d-inference source
- Modifying any file
- Re-litigating Steps 1, 2, 3, 4, 5 (LOCKED)
- Auditing Steps 7-11 (not yet started)
- Re-litigating SPEC-013 v0.3 LOCK or Shape A vs Shape B
- Running the integration test (gated)

## Done criteria

- New `## Round 9 audit ...` section appended
- Earlier rounds (1-8) unchanged
- Every category A-H has a section
- Every finding has severity, location, what / why /
  recommendation
- `swift test --package-path phase3-binary` was run and the
  result reported
- Verdict line states READY TO PROCEED TO STEP 7 or FIX
  REQUIRED

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Expected wall-clock: 20-30 min.
- The G.2 question about defer-causing-stop-before-trial is the
  most architecturally consequential audit point. Codex should
  flag this clearly so we can confirm the intended design.
- If verdict is READY TO PROCEED TO STEP 7: Claude commits and
  fires Step 7 (Stage 1 iteration).
- If verdict is FIX REQUIRED: fix-pass + next round.

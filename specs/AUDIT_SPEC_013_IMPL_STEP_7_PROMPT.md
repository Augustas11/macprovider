# Implementation audit prompt — SPEC-013 Step 7 (Stage 1 feasibility iteration)

Operator-paste prompt for Codex GPT-5 to perform an adversarial
**code / orchestration / measurement review** of the Step 7 commit
on branch `feat/cli-autotune-impl`.

Step 7 carries:

| Commit | Step | Scope |
|---|---|---|
| 98d7079 | 7 | `Stage1Iterator` + `Stage1Prober` + 3 protocols for DI + 7 unit tests (529 src + 440 test lines) |

Full `phase3-binary` test suite is green per the commit's
`Tested:` line (306 tests, 2 skipped). Codex (the implementer)
raised zero Open Questions. Operator wants an independent
adversarial pass BEFORE Step 8 (Stage 2 knob hill-climb) begins.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~30-40
min. This is the largest single-step audit so far (970 lines
diff with SSE parsing, TTFT measurement, iteration semantics,
DI protocols). **Read-only review** — Codex MUST NOT modify
any file.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial implementation review of the Step
7 commit (98d7079) on branch `feat/cli-autotune-impl`. The branch
is already checked out at `/Users/augstar/macprovider-poc`. Steps
1-6 are LOCKED.

Steps 8-11 have NOT landed yet — your scope is exclusively the
Step 7 commit. This is a **read-only review**.

## Context

Step 7 is the heaviest BUILD step. It composes everything from
Steps 1-6:
- Step 1 flag set (AutotuneCommand)
- Step 2 `--no-join` on ServeCommand
- Step 3 AutotuneDB + AutotuneTrialRow
- Step 4 CandidateProviderRunner + ReadyStatus + StopResult
- Step 5 (not used in Step 7; called by Step 10's wiring)
- Step 6 ProviderPreWarmer + PreWarmResult

The Stage1Iterator orchestrates:
1. For each candidate IN OPERATOR ORDER (no internal re-rank —
   FR-A.1 / AC-17):
   a. Pre-warm via ProviderPreWarmer.
   b. Classify: integrity → ABORT whole run; transient → log +
      advance; warmed → proceed.
   c. Stage 1 feasibility probe via Stage1Prober.
   d. Apply FR-A.3 four-condition gate: HTTP 2xx + TTFT p95 ≤
      gate + no stop-token leak + no process exit.
   e. STOP on first feasible (FR-A.2); record trial row;
      return.
2. If no candidate passes: throw `noFeasible` with the SMALLEST
   candidate's failure reason surfaced first (FR-A.4 / FR-H.4).

The Stage1Prober:
- Starts a FRESH provider (Step 6 stops the pre-warm provider
  per the G.2 design).
- Fires `replicates` POST requests to
  `/v1/chat/completions` with `stream: true`.
- Parses SSE `data:` lines via `URLSession.bytes(for:).lines`.
- Measures TTFT from request start to first content-delta.
- Measures TPS from whitespace-token count over wall-clock.
- Scans full generated text for stop tokens
  `["<|im_end|>", "<|endoftext|>", "<|eot_id|>"]`.
- Per-request peeks at `runner.waitForReady(timeout: 0.05)` to
  detect mid-probe process exits.

## Required reading (in this order)

1. The Step 7 commit via `git show 98d7079`. The commit message
   contains the rejected alternative (internal size-based
   re-rank, which would violate AC-17).

2. The Step 7 source under audit:
   - `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
     (529 lines, NEW). The bulk of the audit's surface.
   - `phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift`
     (440 lines, NEW; 7 unit tests).
   - `phase3-binary/implementation-notes.html` — new
     `spec013-autotune-step7` section.

3. The locked SPEC (READ-ONLY):
   - `specs/SPEC-013-cli-autotune.md` v0.3 §5.1 FR-A.1 (operator
     order is contract), FR-A.2 (STOP on first feasible),
     FR-A.3 (four-condition gate), FR-A.4 (all-infeasible exit).
   - §5.4 FR-D.2 (transient vs integrity cascade).
   - §5.7 FR-G.1 (`tune_trials` schema; stage=1 for Stage 1).
   - §5.8 FR-H.4 (smallest-first reason on all-infeasible).
   - §8 AC-1, AC-2, AC-3, AC-17 (the load-bearing acceptance
     criteria Step 7 delivers).

4. The Step 6 design context (for forward-compat verification):
   - `phase3-binary/Sources/macprovider-cli/ProviderPreWarmer.swift`
     — the disposable load phase. The G.2 audit confirmed Step
     7 starts a FRESH provider for the probe.

5. Local style guide:
   - The Step 4 commit (4bcef89) — async/await + Process()
     patterns + DI protocols.
   - The Step 6 commit (dcd7f63) — protocol-based DI shape.

## Severity definitions (unchanged from prior steps)

- **CRITICAL** — silent contract violation of FR-A.1 / AC-17
  (e.g. internal re-rank of candidates); silent contract
  violation of FR-A.2 (e.g. iterator continues past a feasible
  candidate); silent contract violation of FR-A.4 (e.g. error
  surfaces LARGEST candidate's reason); silent contract
  violation of FR-D.2 (e.g. integrity failure not aborting
  whole run); TTFT measurement off by orders of magnitude;
  anti-regression broke any locked Step 1-6 test.
- **MAJOR** — Step 7 contract gap; SSE parsing miss for a
  common OpenAI-compat response shape; the
  `failureReasons.last` semantics for smallest-first depend
  silently on caller iteration order — break this assumption
  somewhere = MAJOR; trial row field wrong (e.g. stage=0
  instead of stage=1); test gap that hides a likely
  production failure.
- **MINOR** — quality issues; SSE parser unnecessarily strict;
  prompt token estimate inaccurate (acceptable for v1); DI
  protocol cast is leaky.
- **QUESTION** — design choice where the SPEC was silent.

## Critical constraints (unchanged from prior steps)

1. SPEC-013 v0.3 is LOCKED.
2. Anti-regression — `swift test --package-path phase3-binary`
   MUST report 306 tests (2 skipped), 0 failures.
3. Strict clean-room on d-inference.
4. Read-only.
5. NO SIGKILL escalation in v1.
6. **Biggest-fit, not max-tps.** Stage 1 iteration STOPS on
   first feasible per FR-A.2. Continuing past a feasible
   candidate to find a faster one = CRITICAL (the biggest-fit
   product strategy is broken).
7. **Operator-supplied order is the contract.** AC-17 is the
   load-bearing test; the iterator MUST honor verbatim
   candidate order without internal sort.

## Audit categories — work through each

### Category A: FR-A.1 / AC-17 operator-order contract (HIGHEST PRIORITY)

A.1  Walk `Stage1Iterator.run()` line by line. The candidate
     iteration is `for candidate in candidates`. The
     `candidates` array is set in init from the constructor
     param. No mutation, no sort, no re-rank. Good.

A.2  Walk `testStage1IteratorHonorsOperatorOrderForACSeventeen`
     (the AC-17 regression lock). Verify:
     - The test passes `["1B-model", "32B-model"]` (or
       equivalent) where BOTH are feasible.
     - The expected selection is the FIRST entry (1B), not the
       larger 32B.
     - The test would FAIL if `run()` internally sorted by
       parameter count or by predicted fit.

A.3  Spot-check that no helper function in Stage1Iterator
     internally sorts `candidates`. Even sorting by `count`
     accidentally = CRITICAL.

A.4  The `init` accepts `candidates: [String]` — verify it
     stores the array by value (Swift arrays are value types,
     so the iterator can't see operator mutations). Good.

### Category B: FR-A.2 STOP-on-first-feasible

B.1  Walk the `case .feasible: return ...` branch. The function
     returns immediately on the first feasible probe result. No
     continuation. Good.

B.2  Verify `testStage1IteratorStopsOnFirstFeasible` actually
     locks this: 3-candidate list `[infeasible, feasible,
     never-reached]`; the iterator returns the second; tune_trials
     has rows for ONLY the first two (NOT the third).

B.3  Verify `trialRows` includes the feasible candidate's row
     in the returned `Stage1IteratorResult.trials`. Without it,
     the recommendation surface (Step 9) couldn't surface the
     metrics. Good.

### Category C: FR-A.3 four-condition feasibility gate

C.1  Condition 1: HTTP 2xx. Walk `Stage1Prober.probe()`. The
     status code is checked at `guard (200...299).contains(result.statusCode)`.
     If non-2xx → `nErr += 1`, marker recorded. Good.

C.2  Condition 2: TTFT p95 ≤ gate. Walk `percentile95(ttfts)`.
     - For empty array: the guard `guard !ttfts.isEmpty`
       returns `.infeasible` first. Good.
     - For single value: `Int(ceil(1 * 0.95)) - 1 = 0` → returns
       value at index 0. Correct.
     - For 5 values: `Int(ceil(5 * 0.95)) - 1 = 4` → returns
       sorted index 4 (the max). Correct for percentile-95.
     - Verify the comparison `p95 > Double(gateTTFTMS)` is
       strict (a p95 EQUAL to gate is feasible per FR-A.3's
       "≤ gate"). Correct.

C.3  Condition 3: no stop-token leak. Walk the loop:
     ```
     if let leaked = Self.stopTokens.first(where: { result.generatedText.contains($0) }) {
         return .infeasible(reason: "stop-token leak: \(leaked)", nErr: ...)
     }
     ```
     - Stop tokens: `["<|im_end|>", "<|endoftext|>", "<|eot_id|>"]`.
       Conservative coverage of common open-model stops. Good
       for v1.
     - Substring check is case-sensitive (no `.lowercased()`).
       Stop tokens are not localized; case-sensitive is correct.
     - False-positive risk: if the operator-supplied prompt
       padder happens to contain `<|im_end|>`, the model would
       echo it. The padder is `"probe probe probe ..."` — no
       echo risk. Good.

C.4  Condition 4: no process exit during the probe. Walk the
     two `runner.waitForReady(timeout: 0.05)` checks (lines
     ~377-382 and ~386-391). These peek at process state with
     a tiny timeout AFTER each request to detect mid-probe
     exits. Clever defensive pattern.
     - Race condition: if the process exits between the SSE
       response completion and the 0.05s peek, the peek
       catches it. Good.
     - Performance: each peek adds up to 50ms latency per
       request. For 1 replicate this is negligible; for 100
       replicates this is 5s. Acceptable for Stage 1 where
       wall-clock isn't the primary concern.
     - Cancellation: the peek is awaited in async context;
       Task cancellation propagates. Good.

### Category D: SSE parsing correctness

D.1  Walk `probeOnce()`. The streaming response is consumed
     via `URLSession.bytes(for: request).lines`. This is the
     standard async URLSession streaming API. Good.

D.2  Line filter: `guard rawLine.hasPrefix("data:") else
     continue`. OpenAI-spec SSE format is exactly
     `data: <json>` lines (possibly comments preceded by
     `:`). The current parser:
     - Matches `data:` prefix.
     - Strips `dropFirst(5)` → 5 chars including the `:`.
     - Trims whitespace.
     - Compares to `"[DONE]"` for stream end.
     - Otherwise treats as JSON payload.
     This handles the common OpenAI case. Edge cases:
     - SSE comment lines starting with `:` (heartbeat) →
       skipped by the prefix check. Good.
     - Empty `data:` lines → after trim, `payload` is empty
       string, contentDelta returns nil. Good.
     - Multi-line `data:` (an SSE feature where one event has
       multiple `data:` lines concatenated) → the current
       parser treats each line as separate, which loses
       multi-line events. For OpenAI's streaming format,
       multi-line events don't occur in practice — chunks are
       always single-line JSON. MINOR if you think this matters.
     - SSE retry / event fields → ignored. Acceptable.

D.3  `contentDelta(from:)`: parses JSON, looks for
     `choices[0].delta.content` (chat-completions streaming
     format) OR `choices[0].text` (completions format). Both
     are valid OpenAI-compat responses. Good.

D.4  TTFT measurement: `firstTokenAt = clock()` is set on the
     first non-empty content delta. `ttftMS = firstTokenAt -
     started`. This is the "time-to-first-content" definition,
     which matches OpenAI's TTFT semantics. Good.

D.5  TPS calculation: `outputTokens = max(1,
     generatedText.split(whereSeparator: \.isWhitespace).count)`.
     Whitespace-split is a rough token count (a real
     BPE tokenizer would be more accurate). For Stage 1's
     "is this thing alive at all" feasibility decision, the
     rough count is acceptable. v2 can refine if accuracy
     matters for downstream scoring. Flag as QUESTION if you
     think v1 needs a real tokenizer.

D.6  `elapsed = max(0.001, ended.timeIntervalSince(started))`:
     guards against div-by-zero. Good.

### Category E: FR-A.4 / FR-H.4 smallest-first error

E.1  Walk the `noFeasible` throw:
     ```
     let surfaced = failureReasons.last ?? "no candidates were evaluated"
     throw Stage1IteratorError.noFeasible(reason: surfaced, ...)
     ```
     - `failureReasons` is appended in iteration order (largest
       to smallest, given operator order is largest-first
       default).
     - `.last` returns the SMALLEST candidate's reason —
       matching FR-A.4 / FR-H.4 "the smallest candidate's
       reason MUST be surfaced first."
     - BUT this is silently coupled to "iteration order =
       largest-first." If the operator passes a
       smallest-first list (`--candidate-models 1B,32B`),
       `failureReasons.last` would return the 32B (LARGEST)
       reason — WRONG.
     - Is this a CRITICAL bug? Per AC-17 the operator order is
       the contract, so the iterator MUST honor it. But
       FR-H.4's "smallest-first reason" specifically refers
       to model SIZE, not iteration order. If the operator
       intentionally inverts the order, the FR-H.4 semantics
       become ambiguous.
     - Walk `testStage1IteratorAllInfeasibleSurfacesSmallestFirstReason`
       to see what behavior the test locks. If the test uses
       a largest-first default list, the `.last` semantics
       work. If the test uses operator-supplied
       smallest-first, the test may pass tautologically.

E.2  Recommendation: even if E.1 isn't CRITICAL, the
     `failureReasons.last` shorthand is fragile. A future
     refactor reversing iteration would silently break
     FR-H.4. Document the assumption inline.

### Category F: FR-D.2 integrity-vs-transient cascade

F.1  Walk the `case .failed(.integrity, let reason)` branch:
     ```
     throw Stage1IteratorError.preWarmIntegrityFailure(
         model: candidate,
         reason: reason,
         exitReason: .preWarmIntegrityFailure
     )
     ```
     - Throws IMMEDIATELY (no advance, no further iteration).
     - exit_reason = `.preWarmIntegrityFailure` (matches FR-G.2
       enum + FR-H.3 contract).

F.2  Walk the `case .failed(.transient, let reason)` branch:
     - Appends to `failureReasons`.
     - Creates a trial row with `notes = "pre-warm transient:
       \(reason)"` and `fits = false`, `nErr = 1`.
     - `continue` → advances to next candidate.

F.3  Verify `testStage1IteratorAbortsOnIntegrity` actually
     asserts:
     - The iterator throws `preWarmIntegrityFailure`.
     - Candidate 2 is NEVER probed (assert by counting
       prewarmer invocations).
     - The trial row for candidate 1 is in
       `tune_trials` (the iterator should write it BEFORE
       throwing, per FR-G.1's "every trial is recorded").

     Walk the test to check this.

F.4  Verify `testStage1IteratorAdvancesPastTransient`:
     - Candidate 1 returns transient.
     - Candidate 2 is probed.
     - The trial row for candidate 1 is in tune_trials with
       `fits = 0`, `n_err = 1`, `notes` containing the
     transient reason.

### Category G: DI / Protocol design

G.1  Three protocols: `Stage1ProviderRunning`,
     `Stage1PreWarming`, `Stage1Probing`. The actual types
     conform via extensions:
     - `CandidateProviderRunner: Stage1ProviderRunning` (line
       16) — clean.
     - `ProviderPreWarmer: Stage1PreWarming` (lines 27-44) —
       has a downcast: `guard let concreteRunner = runner as?
       CandidateProviderRunner else { throw
       Stage1IteratorError.invalidInjectedRunner }`. This is
       leaky — a test injecting a fake `Stage1ProviderRunning`
       into the REAL `ProviderPreWarmer` would throw. But
       tests inject a fake `Stage1PreWarming`, so the cast
       only fires in production code where the runner IS a
       `CandidateProviderRunner`. Acceptable in practice;
       flag as MINOR if you think it should be cleaner (e.g.
       generic over the runner type).

G.2  `runnerFactory: () throws -> Stage1ProviderRunning` — the
     iterator calls it TWICE per candidate (once for pre-warm,
     once for probe). Each call creates a fresh runner. Verify
     the factory closure doesn't accidentally return the same
     runner instance both times (which would violate Step 6's
     G.2 single-provider invariant). The protocol typing
     forces fresh `Stage1ProviderRunning` instances. Good.

G.3  Tests inject mock `Stage1PreWarming` and
     `Stage1Probing` for deterministic outcomes. Verify the
     mocks correctly emulate the protocol contracts.

### Category H: AutotuneDB persistence

H.1  `autotuneDB.insertTrial(row)` is called per candidate.
     Verify:
     - Trial row has `stage = 1` (FR-G.1).
     - `runID` is consistent across all trials in a single
       iterator run.
     - `fits` reflects the probe result.
     - `kept` reflects the FIRST FEASIBLE (only one row has
       `kept = true` per run).
     - `notes` carries the failure reason for infeasible
       candidates.
     - `replicatesN = stage1Replicates`.
     - `kvBits = nil` (Stage 1 uses defaults; Stage 2 sets
       knobs).

H.2  Walk `makeTrialRow()`. The kept logic:
     ```
     kept: probeResult.isFeasible
     ```
     Only fires for the FEASIBLE candidate (because
     `Stage1Iterator` STOPs after the first feasible, so only
     one trial row has `kept = true`). Good.

H.3  Pre-warm transient trials get `kept = false`. Good.

H.4  Anti-regression on `AutotuneDB`: does Step 7 modify the
     DB schema in any way? Reading the diff, `git show
     98d7079 -- phase3-binary/Sources/macprovider-cli/AutotuneDB.swift`
     should show no changes. Verify.

### Category I: Anti-regression on Steps 1-6

I.1  `swift test --package-path phase3-binary` reports 306
     tests + 2 skipped, 0 failures. Verify.

I.2  `git diff 0f76bcf 98d7079 -- phase3-binary/Sources/` —
     Step 7 should only add NEW files (Stage1Iterator.swift)
     and not modify Step 1-6 sources. Verify.

I.3  The DI conformance extensions in Stage1Iterator.swift
     (`extension CandidateProviderRunner: Stage1ProviderRunning {}`,
     `extension ProviderPreWarmer: Stage1PreWarming { ... }`)
     ADD protocol conformance to existing types. This is
     additive. Verify no existing method signature changed.

### Category J: Forward-compatibility (Steps 8, 9, 10)

J.1  Step 8 (Stage 2 hill-climb) will receive the chosen model
     from Stage1IteratorResult.selectedModel and run knob
     cells. Verify the result struct provides enough info.
     Yes — selectedModel + trials are present. Good.

J.2  Step 9 (recommendation surface) needs the trial rows
     (with metrics) to assemble the FR-F.1 RECOMMENDATION
     block. `trialRows[where fits=true].first.aggThroughputTPS
     / ttftP95MS` gives the metrics. Good.

J.3  Step 10 (signal handling) needs to clean up if SIGINT
     fires mid-iteration. The defer-stop pattern in
     Stage1Prober ensures the current provider is cleaned. But
     the iterator itself doesn't have a Task cancellation
     handler. If SIGINT propagates to the async Task,
     `Task.sleep` / `URLSession.bytes` throw
     `CancellationError`, which propagates up. Step 10's
     `signalHandler` will need to wrap the iterator's
     `run()` in a Task that can be cancelled. Acceptable
     forward-compat.

J.4  Step 10 wires `AutotuneCommand.run()` to call
     Stage1Iterator. The current AutotuneCommand.run() throws
     `ExitCode(2)` for "not implemented yet". Step 10 will
     replace that. Acceptable.

### Category K: Test fixtures and coverage

K.1  Walk each of the 7 tests:
     - `testStage1IteratorStopsOnFirstFeasible`
     - `testStage1IteratorAdvancesPastTransient`
     - `testStage1IteratorAbortsOnIntegrity`
     - `testStage1IteratorAllInfeasibleSurfacesSmallestFirstReason`
     - `testStage1IteratorHonorsOperatorOrderForACSeventeen`
     - `testStage1ProberDetectsStopTokenLeak`
     - `testStage1ProberDetectsTTFTGateMiss`

     For each, verify:
     - The mock setup is correct (mocks return the intended
       outcomes for the test's named scenarios).
     - The assertions actually verify the named contract (not
       just "didn't throw").
     - The test would FAIL if the corresponding code path
       broke.

K.2  Coverage gaps to flag:
     - Is there a test for HTTP non-2xx (e.g. 503) → infeasible?
     - Is there a test for SSE parse failure (e.g. malformed
       JSON in `data:`) → graceful skip?
     - Is there a test for the iterator's behavior when
       `stage1_replicates = 0`? (Probably guarded at
       AutotuneCommand parse time, but Stage1Prober should
       handle the edge case.)
     - Is there a test verifying tune_trials.stage = 1 for
       every Stage 1 row (vs Step 8's stage = 2)?

### Category O: Anything else

Examples:
- The trial row's `targetContext` field is the same as the
  iterator's `targetContext` (the operator's setting).
  `maxContextCap` is also set to `targetContext`. Step 8's
  Stage 2 cells will override `maxContextCap` when the
  --max-context-axis is opted in. For Stage 1 (no knobs), the
  setting is correct.
- The `iso8601UTC` formatter creates a new instance per row.
  Cheap, but a static formatter would be faster. MINOR
  performance nit if you think it matters.
- The implementation-notes section accurately describes the
  Step 7 design.

## Output structure

APPEND to
`/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`:

```
---

## Round 12 audit (Codex on 98d7079 — Step 7 round 1)

**Audited:** commit 98d7079 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 7, round 1 of N
**Date:** 2026-06-18
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]
**Step 7 readiness:** [READY TO PROCEED TO STEP 8 / FIX REQUIRED]

### Executive summary

[2-3 paragraphs.]

### Findings

Group by category A-K + O.
```

## Out of scope

- Inspecting d-inference source
- Modifying any file
- Re-litigating Steps 1-6 (LOCKED)
- Auditing Steps 8-11 (not yet started)
- Re-litigating SPEC-013 v0.3 LOCK
- Re-litigating Shape A vs Shape B or defer-stop architecture

## Done criteria

- New `## Round 12 audit ...` section appended
- Earlier rounds (1-11) unchanged
- Every category A-K + O has a section (even if `(no findings)`)
- Every finding has severity, location, what / why /
  recommendation
- `swift test --package-path phase3-binary` was run and the
  result reported
- Verdict line states READY TO PROCEED TO STEP 8 or FIX
  REQUIRED

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Expected wall-clock: 30-40 min (largest single-step audit).
- The AC-17 regression lock test (Category A) is the load-
  bearing check. The biggest-fit product strategy lives or dies
  by this test.
- The `failureReasons.last` semantics (Category E) is the
  subtlest design risk. Worth a clear flag from codex.
- If verdict is READY TO PROCEED TO STEP 8: Claude commits and
  fires Step 8 (Stage 2 knob hill-climb).
- If verdict is FIX REQUIRED: fix-pass + next round.

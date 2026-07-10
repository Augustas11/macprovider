# R2 closure-verification audit — SPEC-002 v1.3.5 Phase 2C

Operator-paste prompt for Codex GPT-5 to perform a focused
**closure-verification** review of commit `9d4a423` (the R2 fix
commit that landed on top of `b43e7c8`), confirming each of the 3
findings from the Phase 2C R1 audit at
`.omc/artifacts/ask/codex-execute-the-phase-2c-mid-stream-audit-prompt-at-specs-audit--2026-06-07T03-41-02-566Z.md`
is actually closed AND that the R2 changes themselves did not
introduce new defects.

This mirrors the Phase 2B R2V pattern that successfully caught the
prefix-match regression on commit `83540b1` (which `c739055` then
closed). Money-path code — adversarial closure-verification before
2D begins.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~15-25 min
(targeted verification, small surface).
This is a **read-only** review — Codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are performing an R2 closure-verification audit on commit
`9d4a423` in /Users/augstar/macprovider-poc, branch
`fix/spec-002-v1-3-5-coordinator`. This commit applies 3 fixes
addressing the R1 audit findings on commit `b43e7c8` (Phase 2C —
ApplyHeartbeat REPLACEMENT).

Your task has TWO halves:
  A. Verify each of the 3 R1 findings is genuinely closed by 9d4a423.
  B. Sniff for new findings introduced by 9d4a423 itself.

This is a **read-only review**. You MUST NOT edit any file.

## Context

Branch state:
- de41380 (2A): Provider data-model extension
- 11bf449 (2B): v2 auth_request SPEC-010 + retention lifecycle
- 83540b1 (2B R2): close 2B audit findings
- c739055 (2B R3): close 2B R2V finding
- b43e7c8 (2C): ApplyHeartbeat REPLACEMENT + SPEC-011 path
- 9d4a423 (2C R2): **THIS commit — under closure-verification**

R1 audit verdict for b43e7c8 was FIX-THEN-PROCEED with:
- 0 CRITICAL
- 1 MAJOR — [sec:1.1] same-model loading pulse forges swap events
- 2 MINOR — [code:1.1] AC-K.8 test stops short / [code:1.2]
  SwapEventEmitter comment omits mutex contract

R2 (9d4a423) claims to close all 3 with inline fixes by Claude.

## Required reading (in this order)

1. The R1 audit artifact at
   `.omc/artifacts/ask/codex-execute-the-phase-2c-mid-stream-audit-prompt-at-specs-audit--2026-06-07T03-41-02-566Z.md`
   — read the full Findings section.

2. The R2 commit via `git show 9d4a423`. Read the full diff.

3. The R2 commit message (full body, including the rationale for
   each of the 3 fixes).

4. The locked spec sections cited in the R1 findings:
   - `specs/SPEC-002-coordinator.md` v1.3.5 §7.1 R-7.1.6 + §7.10
     R-7.10.6 (the emission gate + "loading:false carrying the
     NEW model_id" rule).
   - `specs/SPEC-002-coordinator.md` v1.3.5 §11 AC-K.8 (per-
     heartbeat path selection).
   - `specs/SPEC-011-operator-pushed-warm-swap.md` v0.5 §3.3
     R-3.3.5 + §3.6 R-3.6.3 (the binding swap-completion
     semantics).

5. The current source after R2:
   - `phase4-coordinator/internal/pool/provider.go`
   - `phase4-coordinator/internal/pool/provider_test.go`

DO NOT inspect any file under `phase3-binary/.build/checkouts/`.

## Part A — R1 closure verification

For each R1 finding, produce a verdict from {CLOSED, NOT-CLOSED,
PARTIAL}. Cite the file:line that contains the fix and the test
name that proves the closure.

### A1 — [sec:1.1] MAJOR — same-model loading pulse forges swap events

**R1 finding:** The R-7.1.6 emission gate `swapCompleted` was
`hb.ModelHashPresent && priorLoadingState && hb.LoadingPresent &&
!hb.Loading` — missing the model-id-changed conjunct. A malicious
binary could pulse loading:true → loading:false on the SAME
model_id and forge a spurious operator_model_swap event when
Phase 2E hooks the emitter. SPEC-002 v1.3.5 §7.10 R-7.10.6
explicitly requires "loading:false carrying the NEW model_id".

**R2 claimed fix:** Added `modelIDChanged` conjunct to the
swapCompleted gate. Regression test
`TestApplyHeartbeatSwapEmitterDoesNotFireWhenModelIDUnchanged`
exercises the malicious sequence (same-model loading pulse) and
asserts the emitter was NOT called.

**Verify:**
- Read provider.go and locate the `swapCompleted` definition.
  Confirm the gate includes `modelIDChanged` and the comment
  above cites SPEC-002 §7.1 R-7.1.6 + §7.10 R-7.10.6.
- Confirm `modelIDChanged` is defined as
  `!strings.EqualFold(priorModelID, hb.ModelID)` (case-insensitive
  per SPEC-002 §11 D9). A case-sensitive comparison here would
  flag a no-op rename as a swap.
- Read `TestApplyHeartbeatSwapEmitterDoesNotFireWhenModelIDUnchanged`
  in provider_test.go. Confirm it sends:
    - Frame 1: `spec011HeartbeatUpdate("model-a", "hash-a", true, ...)`
    - Frame 2: `spec011HeartbeatUpdate("model-a", "hash-a", false, ...)`
  And asserts the emitter was NOT called (`!called` after both
  frames).
- Run the test: `go test -race -count=1 -run
  TestApplyHeartbeatSwapEmitterDoesNotFireWhenModelIDUnchanged
  ./internal/pool/...`. Confirm exit 0.
- Sanity check: confirm `TestApplyHeartbeatSwapEmitterFiresOnPostSwapTransition`
  STILL passes (the model_id change in that test must satisfy
  the new gate).

### A2 — [code:1.1] MINOR — AC-K.8 test stops before SPEC-011 re-entry

**R1 finding:** `TestApplyHeartbeatPathSelectionIsPerHeartbeatNotSticky`
covered frame#1=SPEC-011 + frame#2=LEGACY but didn't pin the
re-entry case where frame#3 carries model_hash again. Path-
selection per-heartbeat semantics (AC-K.8) require the SPEC-011
path to fully re-take after a LEGACY clear.

**R2 claimed fix:** Extended the test with a third heartbeat
asserting SPEC-011-PATH repopulation: ModelHash = "hash-c" +
HashStatus = HashStatusVerified.

**Verify:**
- Read the extended test in provider_test.go. Confirm:
  - Frame 1: `spec011HeartbeatUpdate("model-a", "hash-b", false,
    ...)` — SPEC-011 PATH, verifier returns HashStatusVerified.
  - Frame 2: `heartbeatUpdateAt("model-b", ...)` — LEGACY PATH,
    clears ModelHash + sets HashStatusUncatalogued.
  - Frame 3: `spec011HeartbeatUpdate("model-c", "hash-c", false,
    ...)` — SPEC-011 PATH re-entry, should repopulate to
    ModelHash="hash-c" + HashStatus=HashStatusVerified.
- Confirm the test exercises a model_id CHANGE on frame 3 (not
  same model) — the SPEC-011 PATH should fire on either
  model_id-changed OR model_hash-changed per provider.go
  ~495 (`modelIDChanged || !strings.EqualFold(priorModelHash, hb.ModelHash)`).
- Run the test: `go test -race -count=1 -run
  TestApplyHeartbeatPathSelectionIsPerHeartbeatNotSticky
  ./internal/pool/...`. Confirm exit 0.

### A3 — [code:1.2] MINOR — SwapEventEmitter comment omits mutex/blocking contract

**R1 finding:** SwapEventEmitter type comment said WHEN the emitter
is called but not that ApplyHeartbeat invokes it while holding
Registry.mu. Future Phase 2E maintainers (or any later caller)
could trigger a deadlock by calling back into Registry, or could
register a long-running emitter that throttles heartbeat
processing.

**R2 claimed fix:** Expanded the SwapEventEmitter doc comment with
the concurrency contract: MUST NOT call back into Registry, MUST
NOT block for long, cites R-7.10.8 audit-write-failure tolerance,
and notes v1.3.4-symmetric panic propagation semantics.

**Verify:**
- Read the SwapEventEmitter type declaration and the comment block
  above it in provider.go.
- Confirm the comment names:
  - "ApplyHeartbeat holds Registry.mu" (or equivalent — the mutex
    is held during the emitter call)
  - explicit "MUST NOT call back into any Registry method"
    (deadlock risk)
  - explicit "MUST NOT block for long" (heartbeat throughput)
  - SPEC-002 v1.3.5 R-7.10.8 mandate (audit write failure MUST
    NOT block heartbeat processing or drop the provider)
  - panic-propagation semantics (the spec doesn't change this from
    v1.3.4 — confirm symmetry mention)
- This is a doc-only fix; no test required. But verify the
  comment is on the SwapEventEmitter type declaration, NOT
  elsewhere (e.g., misplaced on SwapEvent or on WithSwapEmitter).

## Part B — R2 regression sniff

Look for new defects introduced by 9d4a423. Use the same code /
security / architecture lens as R1, but scoped narrowly to the
edits in this commit:

### B1 — Did `modelIDChanged` get computed before its use?

The gate now reads:

    swapCompleted := hb.ModelHashPresent &&
        priorLoadingState &&
        hb.LoadingPresent && !hb.Loading &&
        modelIDChanged

Verify `modelIDChanged` is defined ABOVE this block in the
function body — specifically, at the top of the dispatch logic
(around provider.go ~482). A use-before-define would not compile,
so this is mostly a sanity check, but confirm the variable scope
is correct (single function-scoped declaration, not redefined).

### B2 — Did the new gate break any prior-passing emit test?

The 4 existing emit tests must all still pass:
- `TestApplyHeartbeatSwapEmitterFiresOnPostSwapTransition` —
  uses model-a → model-b transition, MUST still fire emitter.
- `TestApplyHeartbeatSwapEmitterDoesNotFireOnLegacyPath` — uses
  LEGACY path (ModelHashPresent=false), MUST still not fire.
- `TestApplyHeartbeatSwapEmitterDoesNotFireWhenNoPriorLoading` —
  no prior loading:true, MUST still not fire.
- `TestApplyHeartbeatSwapEmitterNilDoesNotCrash` — nil emitter,
  MUST still not crash.

Run `go test -race -count=1 -run TestApplyHeartbeatSwapEmitter
./internal/pool/...` and confirm all 5 (4 existing + 1 new) pass.

### B3 — Same-model + hash-changed forgery vector

The new gate requires `modelIDChanged`. But what if a binary
sends loading:true + model_hash=A, then loading:false +
model_hash=B on the SAME model_id? The SPEC-011 PATH would
re-verify and update ModelHash, but no swap event fires
(modelIDChanged=false). Is this:
  (a) Intentional — only model_id changes count as swaps
      (matches the spec wording "carrying the new model_id"
      strictly).
  (b) A coverage gap — a same-model hash change is a
      legitimate "re-load with new weights" scenario that
      SHOULD audit.

Read SPEC-002 v1.3.5 §7.10 R-7.10.6 + SPEC-011 v0.5 §3.3
R-3.3.5 / §3.6 R-3.6.3 carefully. The spec wording is binding —
"carrying the new model_id". Re-loading with new weights on the
same model_id is NOT a swap per the locked semantics. (a) is
correct. Flag this only if the spec actually demands (b).

### B4 — Comment-only change leaked into a non-doc edit?

The R2 commit modified provider.go and provider_test.go.
Confirm via `git diff b43e7c8..9d4a423 -- phase4-coordinator/`
that:
  - provider.go has exactly two edits: the SwapEventEmitter
    comment expansion (Fix 3) and the swapCompleted gate
    + comment (Fix 1).
  - provider_test.go has exactly two edits: the path-selection
    test extension (Fix 2) and the new
    TestApplyHeartbeatSwapEmitterDoesNotFireWhenModelIDUnchanged
    test (Fix 1 regression test).
  - No unrelated changes anywhere.

### B5 — gofmt + go vet + go test -race -count=1 ./internal/...

The Phase 2B R3 bar was set at `go test -race -count=1 ./internal/ws/...`
clean. 2C R2 must preserve this PLUS `./internal/pool/...` clean.
Run all three commands from /Users/augstar/macprovider-poc/phase4-coordinator
and confirm exit 0 for each.

## Output format

```
# SPEC-002 v1.3.5 Phase 2C R2 closure-verification — Codex GPT-5

## Verdict

<one-line: CLOSED-CLEAN | CLOSED-WITH-MINOR-NOTES | NOT-CLOSED |
NEW-FINDINGS>

## R1 closures

| Finding | R1 severity | R2 verdict | Test/file proof |
|---|---|---|---|
| sec:1.1 (same-model forgery) | MAJOR | CLOSED/NOT-CLOSED/PARTIAL | <test name + file:line> |
| code:1.1 (AC-K.8 re-entry test) | MINOR | CLOSED/NOT-CLOSED/PARTIAL | <test name + file:line> |
| code:1.2 (emitter comment contract) | MINOR | CLOSED/NOT-CLOSED/PARTIAL | <file:line> |

## New findings introduced by R2

(zero is the expected/desired result; report whatever you find)

[r2:N.M] [SEVERITY] <short title>
  File: <path>:<line>
  What: <description>
  Why: <impact>
  Fix: <remediation>

## AC traceability (delta from R1 audit)

| AC | Where satisfied | Test name |
|---|---|---|
| AC-K.8 (per-heartbeat path selection) | <file:line> | <updated tests> |
| AC-K.9 (exactly-once emission, 2C portion) | <file:line> | <updated tests; 2E owns full closure> |

## Build / vet / race / suite evidence

Paste outputs from:
  cd /Users/augstar/macprovider-poc/phase4-coordinator
  go build ./...
  go vet ./...
  gofmt -l ./internal/
  go test -race -count=1 ./internal/pool/...
  go test -race -count=1 ./internal/ws/...

## Cross-cutting observations

<any patterns spanning multiple closures or new findings>
```

## Discipline

- Closure verdicts are CLOSED only when both the production fix
  AND a covering test/comment exist. A fix without a test = PARTIAL
  (except for arch:1.2 / code:1.2 which are doc-only).
- New-finding severity follows the same scale.
- Do not invent findings. Zero is a valid result.
- Cite file:line for every closure verdict.
- You may run `go build / vet / test / -race`. You MUST NOT
  modify any file.

You may take up to 25 minutes wall-clock.

=== END PROMPT ===
```

---

## Operator notes

- Expected outcome: CLOSED-CLEAN, zero new findings. The R2 fixes
  are tightly scoped — Fix 1 is a 1-line gate addition + 1 test,
  Fix 2 is a test extension, Fix 3 is comment expansion.
- If CLOSED-WITH-MINOR-NOTES or new findings emerge, decide
  whether to fix inline (R3) or defer to the pre-merge audit at
  the end of 2E. If CLOSED-CLEAN, proceed to Phase 2D.
- Result artifact lives under
  `.omc/artifacts/ask/codex-execute-the-r2-closure-verification-prompt-*`.

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7).

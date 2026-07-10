# SPEC-019 v0.2 IMPL — Round 4 audit prompt (per-lane)

You are auditing the SPEC-019 v0.2 IMPL after r3 absorption.

**Anchor:** `impl/spec-019-v0-2` HEAD (r3 absorption committed inline).

r3 narrative: `specs/SPEC-019-v0_2-IMPL-r3-audit.md` (0C + 0H + 4M;
C + F READY at r3).

## What changed in r3 absorption (inline, no codex)

3 fixes applied as ~25 LOC across 4 files. r3 narrative cites them all.

- **A-r3-M-1 (Decision C):** `waitForStructuredStreamingOperationStopped`
  returns `Bool`. Watcher arm at `ModelRuntime.swift:1199-1208` checks
  the return; on budget breach throws
  `Self.structuredStreamingProviderTimeoutError()` WITHOUT calling
  `onIdleTimeout()`. New test
  `testIdleBreachFailsClosedWhenOperationStopBudgetExhausted` asserts
  the fail-closed path AND that `onIdleTimeout` is not called.
- **B-r3-M-1:** `synthesizeIdleTimeoutResultOrThrow` now takes
  `modelHash: String?`; threads through
  `validObservedModelHash(...)`. Caller at `ModelRuntime.swift:686-690`
  passes `modelHash: snapshot.modelHash`. All 4 test call-sites
  updated; success-path test now asserts
  `result.modelHashObserved == "aaa...a" (64-char hex)`.
- **D-r3-M-1 + E-r3-M-1:** Path string `../KNOWN_GAPS.md` →
  `../../KNOWN_GAPS.md` in 2 fixture READMEs.

## Smoke after r3 absorption
- phase3-binary: 646 / 7 skipped / 0 failures (+1 vs r2's 645)
- phase4-coordinator: green except for pre-existing time-bomb in
  `TestReceiptKeysReturnsPreviousKeyInGraceWindow` (out-of-scope,
  pre-existing from PR #124 SPEC-015 receipts)
- phase5-gateway: 206 / 0 failures

## Lane charter (r4 defensive)

Primary objective: verify r3 absorbed findings actually close cleanly
and the inline edits did not introduce regressions. Scan for any
fresh-surface issue from the 4 r3 fixes.

Each lane: 0/0/0 OR finds CRITICAL/HIGH/MEDIUM. Bar: 0/0/0.

### Lane A — Codex architect
- Verify A-r3-M-1 closes: budget-breach path throws before snapshot.
  Operation that hangs past 100ms can no longer produce a buyer-
  visible success on a stale buffer.
- Cross-flow consistency: the new `Bool` return on the wait helper
  doesn't break any other caller (grep for it).
- B-r3-M-1 closure: `synthesizeIdleTimeoutResultOrThrow` properly
  threads modelHash through `validObservedModelHash`, matching
  pre-r2 inline behavior.

### Lane B — Codex code
- Code review the 4 modified files. Anything subtle in the watcher
  arm change (race between the wait return and other group arms)?
- Verify no test caller of `synthesizeIdleTimeoutResultOrThrow`
  remained un-updated (would fail compile).
- `validObservedModelHash(nil)` semantics — does it correctly return
  `nil`?

### Lane C — Codex security
- Money-path posture re-verification: A-r3-M-1 fail-closed path is
  the correct posture (better to lose a buyer's possibly-valid
  output than emit success on flux). No new DoS surface
  (deadlock-by-hung-provider closed by the bounded wait; fail-close
  ensures terminal frame eventually emits).
- Citation correctness in the new test
  `testIdleBreachFailsClosedWhenOperationStopBudgetExhausted` —
  does it actually exercise the fail-closed path?

### Lane D — Codex product-design
- Verify the 2 README path fixes resolve correctly:
  `partial_content_negative/{cline,vercel}_partial_then_error/README.md`
  → `../../KNOWN_GAPS.md` points at the existing file.
- Spot-check the existing 2 top-level fixture READMEs still use the
  correct `../KNOWN_GAPS.md` (they're at depth 1, so that's right).

### Lane E — Claude critic (blind-spot adversarial)
- Hostile read of the r3 absorption diff (`git diff 63e625e..HEAD`).
  Did the inline edits introduce any new finding?
- Specifically: race between the operation-task's
  `defer markOperationStopped()` and the watcher's `Bool` return.
  What if operation marks-stopped exactly between the budget check
  and the return? Returns true vs false?
- `OnIdleCalledFlag` test-only helper: does it correctly avoid
  Swift 6 Sendable issues? Any subtle race?
- `validObservedModelHash` boundary cases: what if `snapshot.modelHash`
  is empty string, malformed hex, etc.? Does the helper preserve
  pre-r2 behavior on those edges?

### Lane F — Claude narrative (blind-spot continuity)
- r3 absorption commit message accuracy: 646 / 7 / 0 — verify
  against current HEAD.
- r3 narrative covers all 4 lane findings + the out-of-scope
  receipt-keys time-bomb.
- AC-V2 citation coverage unchanged.
- Test name patterns consistent.

## Output format

Same per-lane format as r1/r2/r3:

```
# SPEC-019 v0.2 IMPL r4 audit — lane <X>

## Verdict
<READY TO LOCK | NEEDS REVISION>

## CRITICAL (N)
## HIGH (N)
## MEDIUM (N)
## Notes (N) [optional]
```

**Bar:** 0 CRITICAL + 0 HIGH + 0 MEDIUM. Do NOT edit files. SPEC text
immutable.

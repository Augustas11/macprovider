# SPEC-019 v0.2 IMPL — Round 3 audit prompt (per-lane)

You are auditing the SPEC-019 v0.2 IMPL after r2 absorption.

**Audit anchor:** `impl/spec-019-v0-2` HEAD (r2 absorption `3cadcde` +
traceability commit on top).

r2 narrative: `specs/SPEC-019-v0_2-IMPL-r2-audit.md` (0C + 3H + 6M;
A/C/F READY at r2). r2 absorption prompt:
`specs/ABSORB_SPEC_019_v0_2_IMPL_r2_PROMPT.md`.

## What changed in r2 absorption (commit 3cadcde)

**Convergent absorption (4 themes — must verify closure):**

- **T-r2-1** multipleOf Int64 trap: `Int64(exactly:)` replaces
  unchecked `Int64(value)` cast in
  `JSONSchemaValidator.swift:278-286`. Boundary guards removed. New
  tests for `Int64.max` / `Int64.min` / negative integer path.
- **T-r2-2** Buffer-as-of-close TOCTOU: idle watcher reorders to
  markTimedOut → cancel → await `operationStopped` → snapshot →
  validate. New `operationStopped` field on
  `StructuredStreamingIdleState`. Production `defer
  idleState.markOperationStopped()`.
- **T-r2-3** Coord WS→SSE wire test: extended
  `phase4-coordinator/internal/buyer/structured_output_ws_detail_test.go`
  with `TestForwardWSStreamingMapsResponseByteCapExceededToSSE` and
  `TestForwardWSStreamingMapsProviderTimeoutToSSE`.
- **T-r2-4** Idle-breach helper: extracted
  `synthesizeIdleTimeoutResultOrThrow(accumulator:request:)` static
  helper. `StreamingIdleTimeoutValidatesBufferTests` rewritten to
  call it directly.

**Singular (1 item):**
- **D-r2-M-3** Composite-render matrix: added Qwen3+tool-history +
  Llama-3.3+tool-history JSON files; `assert_fixture.py` extended.

**Deferred (Decision 2γ):**
- **D-r2-H-1 + D-r2-M-1 + D-r2-M-2 + E-N-4** Fixture authenticity →
  v0.2.x. Tracking issue **#235** opened. `KNOWN_GAPS.md` added.
  README notes in 4 fixture directories.

**Cleanup:**
- E-N-1 dead `multipleOf >= leastNormalMagnitude` removed.
- E-N-2 dead `catch is DrainCancelledError where idleState.timedOut`
  removed.
- E-N-3 `testMultipleOfIntegerPathRejectsFloatingDrift` renamed.

**Smoke after r2 absorption:**
- phase3-binary: 645 / 7 skipped / 0 failures (+7 vs 638)
- phase4-coordinator: 393 (+2 vs 391)
- phase5-gateway: 206

## Anchors

- **IMPL under audit:** worktree HEAD on
  `/Users/augstar/macprovider-impl-spec-019-v0-2/`. Full diff:
  `git diff 521fe28..HEAD`. r2 delta: `git diff 34bbab6..HEAD`.
- **r2 narrative:** `specs/SPEC-019-v0_2-IMPL-r2-audit.md`.
- **SPEC v0.2.4 LOCKED:** `specs/SPEC-019-structured-output.md`.
  AC-V2-* set normative; do NOT propose SPEC edits.
- **Tracking issue:** #235 (fixture authenticity, deferred to v0.2.x).

## Lane charter

Each lane has dual mandate:
1. **Verify r2 closures** — did each r2 finding actually close
   cleanly?
2. **Fresh-surface audit** — does r2 absorption introduce NEW
   findings? In particular: the operationStopped barrier (new
   synchronization primitive), the Int64(exactly:) change (relies on
   correct Swift stdlib behavior on the boundary), the matrix-cell
   fixture expansion (4 new JSON files), the cleanup edits (3
   removals/renames).

### Lane A — Codex architect
- Verify T-r2-1 closes the Int64 trap: the new `exactIntegerValue`
  handles `Int64.max` cleanly; no new trapping path remains.
- Verify T-r2-2 closes TOCTOU: the operationStopped barrier is set
  before the watcher reads the snapshot in every code path.
- Cross-module consistency: does the helper-extraction in T-r2-4
  preserve the AC-V2-9 contract semantics across both branches
  (validates-and-returns vs throws-provider_timeout)?
- New surface: any new race introduced by the operationStopped
  barrier? E.g., can the operation `defer
  markOperationStopped()` race with `markFinished()` such that the
  watcher reads a stale buffer?

### Lane B — Codex code
- Verify the `Int64(exactly:)` swap landed. Read
  `JSONSchemaValidator.swift:278-286` against the absorption prompt
  expected shape.
- T-r2-2 production code path: is the new
  `markOperationStopped()` actually called on EVERY exit path of the
  operation (success, error, cancellation)?
- T-r2-4 helper: is `synthesizeIdleTimeoutResultOrThrow` actually
  the production code-path called by the watcher? Or is it duplicated
  somewhere?
- D-r2-M-3 matrix JSON files: are they actually byte-equivalent
  between streaming and non-streaming variants? Lane B should sample
  one pair and diff.
- Cleanup items: E-N-1/2/3 each landed without breaking compile or
  test discoverability?

### Lane C — Codex security
- Re-verify the 4-code money-path holds after r2 absorption. The
  Int64(exactly:) fix is in JSONSchemaValidator — does it affect the
  validation-fail → FaultBreakerQualifying classification path?
- T-r2-2 reorder: any new race between idle-watcher cancel and the
  inferenceGate.withPermit? Provider could hold permit while
  watcher polls, blocking other requests.
- TOCTOU: even with the markOperationStopped barrier, can the
  100ms-max poll budget be exceeded by a malicious provider
  (artificial delays in deferred cleanup)? What does watcher do
  then?
- D-r2-H-1/M-1/M-2 deferred: is the deferral text in KNOWN_GAPS.md
  honest about the gap, or does it understate the security
  implication (e.g., a malicious SDK could publish a body
  shape-compatible with the assertion but semantically wrong)?

### Lane D — Codex product-design
- Verify D-r2-M-3 matrix is now complete: 6 cells (base, Qwen3,
  Llama-3.3, generic-tool-history, Qwen3+tool-history,
  Llama-3.3+tool-history). All 6 assert byte-equivalence?
- Verify deferred-fixture KNOWN_GAPS.md is clear about what is
  versus is not asserted by the current fixtures.
- Verify the tracking issue #235 body is comprehensive enough for a
  fresh contributor to pick up the v0.2.x work.
- New: do any new fixture artifacts in r2 introduce unrelated drift
  (e.g., schema-bound differs from v0.1.5 baseline)?

### Lane E — Claude critic (blind-spot adversarial)
- Hostile read of the r2 absorption diff (`git diff 34bbab6..HEAD`).
  Each new line — does it actually fix the finding it claims to
  fix?
- T-r2-1 `Int64(exactly:)`: what about `Int64.min` boundary
  semantics? `Double(Int64.min)` is representable exactly as
  `-9.223372036854776e18`, but `Int64(exactly: -9223372036854775808.0)`
  — does Swift return nil or actual Int64.min? Spot-check with a
  fixture.
- T-r2-2 100ms-max poll budget: what happens if the operation closes
  cleanly but `defer { markOperationStopped() }` fires AFTER the
  poll budget elapses? Does the validator see partial state?
- T-r2-3 wire tests: do they actually exercise `forwardWSStreaming`
  end-to-end, or are they mocking the WS frame at a level that
  misses real failure modes?
- Cleanup items: E-N-3 rename — did the test get renamed without
  changing its body to actually exercise the FP-fallback path it now
  claims to test?

### Lane F — Claude narrative (blind-spot continuity)
- r2 absorption commit message accuracy: 645 / 7 / 0, 393, 206 — do
  these match current HEAD?
- Issue #235 body matches the deferral scope in r2 narrative.
- KNOWN_GAPS.md tone + content: does it tell the right story for a
  future contributor (or v0.2.x picker)?
- Test naming: do the new tests follow the patterns established in
  the codebase?
- AC-V2 citation coverage: still complete after r2 absorption (no
  citation drift)?

## Output format

Same per-lane format as r1/r2:

```
# SPEC-019 v0.2 IMPL r3 audit — lane <X>

## Verdict
<READY TO LOCK | NEEDS REVISION>

## CRITICAL (N)
## HIGH (N)
## MEDIUM (N)
## Notes (N) [optional]
```

**Bar:** 0 CRITICAL + 0 HIGH + 0 MEDIUM. Do NOT edit files. Do NOT
propose SPEC edits. Constrain to IMPL surface only.

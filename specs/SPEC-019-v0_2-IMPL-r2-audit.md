# SPEC-019 v0.2 IMPL — Round 2 audit narrative

**Anchor:** `impl/spec-019-v0-2` HEAD (post r1 absorption + traceability)
**Audited diff:** `git diff e5e9995..HEAD`
**Round:** r2
**Lanes:** 4 codex + 2 Claude blind-spot

## Per-lane verdicts

| Lane | Verdict | C | H | M |
|---|---|---|---|---|
| A architect (codex) | READY TO LOCK | 0 | 0 | 0 |
| B code (codex) | NEEDS REVISION | 0 | 1 | 0 |
| C security (codex) | READY TO LOCK | 0 | 0 | 0 |
| D product-design (codex) | NEEDS REVISION | 0 | 1 | 3 |
| E critic (Claude, adversarial) | NEEDS REVISION | 0 | 1 | 3 |
| F narrative (Claude) | READY TO LOCK | 0 | 0 | 0 |

**Totals: 0 CRITICAL, 3 HIGH, 6 MEDIUM.** A + C + F clean.

## r1 closure confirmations (all 5 themes verified)

Lane F verified every r1-claimed artifact against the diff. All 5
convergent themes + 7 singular items have IMPL artifacts and test
artifacts. 13 AC-V2 citations across 5 source files. Smoke counts
match commit message verbatim (638 phase3, 391 phase4, 206 phase5).

The convergent r1 issue (2-code-vs-4-code asymmetry) IS fully closed at
all 3 sites; lane C confirms money-path holds end-to-end for the 4
codes.

## New findings introduced by r1 absorption

### T-r2-1: multipleOf Int64 trap (1 HIGH — convergent B + E)

B-r2-H-1 + E-r2-H-1.

**Site:** `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:278-286`.

```swift
private static func exactIntegerValue(_ value: Double) -> Int64? {
    guard value.isFinite,
          value.truncatingRemainder(dividingBy: 1) == 0,
          value >= Double(Int64.min),
          value <= Double(Int64.max) else { return nil }
    return Int64(value)
}
```

**The bug:** `Double(Int64.max) = 9223372036854775808.0 = 2^63`, which
is `Int64.max + 1`. The guard `value <= Double(Int64.max)` accepts the
boundary value `2^63`, but `Int64(2^63)` traps the process.

**Trivially reachable:**
- StrictJSONParser parses `9223372036854775807` as `.int(Int64.max)`.
- `numericInstanceValue(.int(...))` returns `Double(Int64.max)` →
  `2^63` (FP rounding).
- Schema `{"type":"integer","multipleOf":1}` triggers
  `exactIntegerValue(2^63)` → trap.

**Money-path impact:** Provider process aborts. Buyer's session lost.
Adversarial buyer can engineer prompts that elicit max-int64 from any
schema using `multipleOf: <integer>`. DoS regression introduced by
the T-3 absorption.

**Resolution (Decision 1A — locked-in design call):**

Use `Int64(exactly: value)` which returns `Int64?` and never traps:

```swift
private static func exactIntegerValue(_ value: Double) -> Int64? {
    guard value.isFinite,
          value.truncatingRemainder(dividingBy: 1) == 0 else { return nil }
    return Int64(exactly: value)
}
```

The redundant boundary guards (`Int64.min` / `Int64.max`) can be
removed because `Int64(exactly:)` handles them correctly.

Add tests in `JSONSchemaValidatorTests.swift`:
- `Int64.max` (`9223372036854775807`) against `multipleOf:1` → reject
  cleanly (no crash) per validation flow.
- `Int64.min` (`-9223372036854775808`) against `multipleOf:1` → ditto.
- Negative integer `-100` against `multipleOf:2` → accept.
- Negative integer `-101` against `multipleOf:2` → reject (validation
  failure, not crash).

### T-r2-2: buffer-as-of-close TOCTOU (1 MEDIUM — Lane E)

E-r2-M-1.

**Site:** `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:668-687`
(idle watcher arm) + `:1138-1180` (TaskGroup mechanics).

**The bug:** Watcher reads `accumulator.content` snapshot S BEFORE the
operation task is cancelled. Operation continues appending deltas
(both to accumulator AND to SSE wire) until `group.cancelAll()` after
`group.next()` returns. Watcher validates S; buyer's wire content is
`S ++ extras`. Validated set ⊂ buyer-visible set. AC-V2-9b intent
("buffer-as-of-close") not honored — close ≠ snapshot read.

**Resolution (Decision 3ε — locked-in design call):**

Reorder the watcher arm:
1. `markTimedOut()` first.
2. Cancel the operation task via `idleCancellation` (the dedicated
   token added in B-M-1 absorption).
3. Briefly await the operation task's termination (poll
   `idleState.operationStopped` or use a CheckedContinuation set when
   the operation closure returns).
4. THEN read `accumulator.content`.
5. Validate, return success-or-throw.

Add a flag/continuation on `StructuredStreamingIdleState`:
`private(set) var operationStopped = false` + `func
markOperationStopped()`. Call the marker from the operation's defer
or at the end of the operation closure. Watcher polls with brief
sleeps until set or until a sub-budget elapses (say 100ms — long
enough to drain in-flight appends, short enough to not extend the
buyer-visible timeout).

### T-r2-3: coord-side WS→SSE wire test missing for new codes (1 MEDIUM — Lane E)

E-r2-M-2.

**Site:** `phase4-coordinator/internal/buyer/structured_output_ws_detail_test.go`
(new file from r1 absorption).

Tests only `isSpec019ProviderDetailCode(code)` (predicate) and
`writeSSEError(rr, ...)` (output formatting). Does NOT exercise
`forwardWSStreaming` at `server.go:2347-2350` — the actual production
branch that maps a WS `end.Status` to an SSE write for the two new
codes.

**Resolution:** Add a coord-level test that mounts the WS handler,
feeds a synthetic WS end-frame with `status:"response_byte_cap_exceeded"`
(and one with `status:"provider_timeout"`), and asserts the buyer SSE
output contains the literal code in `error.code`, `settlement_ran:true`,
and the right `request_id`.

### T-r2-4: idle-breach test reimplements catch-translate (1 MEDIUM — Lane E)

E-r2-M-3.

**Site:** `phase3-binary/Tests/macprovider-cliTests/StreamingIdleTimeoutValidatesBufferTests.swift:31-67`.

Production catch-translate at `ModelRuntime.swift:680-687`:
```swift
do {
    return try Self.validateStructuredStreamingCompletion(synthetic, ...)
} catch {
    throw Self.structuredStreamingProviderTimeoutError()
}
```

Test reimplements the same translation in a test closure rather than
calling the production code path. Production regression invisible to
this test.

**Resolution:** Either (a) extract production catch-translate into a
named static helper
(`synthesizeIdleTimeoutResultOrThrow(accumulator:request:)`) and
assert that helper directly, OR (b) reach into the production path
via a stub `ModelRuntime.stream(...)` call. Pick (a) — smaller
surface change.

## Deferred (Decision 2γ — locked-in design call)

### T-r2-5: Fixture authenticity (D-r2-H-1 + D-r2-M-1 + D-r2-M-2 + E-N-4) — DEFERRED

D-r2-H-1: AC-V2-5 Cline fixture is static, not proven live.
`"model":"fixture-model"` reveals hand-crafted body; `package-lock.json`
is a 20-line stub, not real `npm install` output.

D-r2-M-1: AC-V2-12 Vercel fixture — no JS/TS harness invokes real
Zod + `ai` + `createOpenAICompatible`.

D-r2-M-2: AC-V2-13 partial-content negative fixtures — Python over
hand-written SSE, no actual SDK exercise.

E-N-4: Pinned-versions assertions pass against hand-authored
lockfiles. "Letter satisfied; reality theater."

**Resolution:** DEFER to v0.2.x. Open a GitHub tracking issue
"SPEC-019 v0.2 IMPL fixture authenticity — JS/TS harness + real SDK
capture". Add a `KNOWN_GAPS.md` (or comment on each fixture README)
documenting:

- "v0.2 IMPL fixtures assert byte-shape against a captured body but
  the body is static, not regenerated from a live SDK invocation."
- "v0.2.x will add a JS/TS harness under `test/integration/spec_019/<name>/regenerate.{ts,sh}`
  that performs the real SDK call and overwrites the committed
  captured body."
- "Until then, the spec-level liveness guarantee is provenance via
  documentation (Cline commit + package-lock pins) plus the
  byte-shape assertion."

This does NOT modify the LOCKED SPEC text. The deferral is recorded
in IMPL artifacts only.

## D-r2-M-3: Composite-render matrix completeness (1 MEDIUM)

AC-V2-14 requires byte-equivalence for **Qwen3 AND Llama-3.3** with
**empty-tool-history AND non-empty-tool-history**. Current fixture
has 4 artifacts (base, Qwen3, Llama-3.3, generic tool-history) but
the matrix calls for 6 (the 2 missing cells are Qwen3+tool-history
and Llama-3.3+tool-history).

**Resolution:** Add 4 more JSON files (2 family × 2 streaming-mode for
tool-history) and extend `assert_fixture.py` to enforce
byte-equivalence on the new matrix cells.

## Singular Notes (non-blocking)

- E-N-1: `multipleOf >= .leastNormalMagnitude` guard at line 179 is
  dead code (line 178 `multipleOf > 1e-300` already excludes all
  subnormals). Harmless redundancy. **Resolution:** remove or annotate
  as belt-and-suspenders.
- E-N-2: `catch is DrainCancelledError where idleState.timedOut`
  clause at line 1168 is dead code after B-M-1 removed `token.fire()`
  from idle path. **Resolution:** remove or comment as legacy.
- E-N-3: `testMultipleOfIntegerPathRejectsFloatingDrift` is misnamed
  — it tests the FP-fallback path because `numeric: 1.0000000001` is
  not integer-representable. **Resolution:** rename to
  `testMultipleOfFPFallbackRejectsFloatingDrift` AND add a true
  integer-path test (e.g., `Int64(100), multipleOf: Int64(3)` →
  reject).

## r2 absorption plan

**Target:** new commits on top of current HEAD.

**Convergent (4 themes — must close):**
- T-r2-1: multipleOf `Int64(exactly:)` (1H closure, both B + E)
- T-r2-2: buffer-as-of-close TOCTOU reorder (1M closure)
- T-r2-3: coord-side WS→SSE wire test (1M closure)
- T-r2-4: idle-breach production catch-translate helper + test (1M closure)

**Singular (1 item):**
- D-r2-M-3: composite-render matrix completion (Qwen3+tool-history +
  Llama-3.3+tool-history)

**Deferred (4 items):**
- D-r2-H-1, D-r2-M-1, D-r2-M-2, E-N-4 — fixture authenticity → v0.2.x.
  Open tracking issue. Add `KNOWN_GAPS.md` or per-README notes.

**Notes (3 dead-code / rename items — must absorb):**
- E-N-1, E-N-2, E-N-3 — clean up.

**Lock convention:** 0 CRITICAL + 0 HIGH + 0 MEDIUM across all 6
lanes.

## Per-lane round files

- Lane A codex: `codex-spec-019-v0-2-impl-...10-09-32-757Z.md`
- Lane B codex: `codex-spec-019-v0-2-impl-...10-09-20-383Z.md`
- Lane C codex: `codex-spec-019-v0-2-impl-...10-10-01-538Z.md`
- Lane D codex: `codex-spec-019-v0-2-impl-...10-10-21-229Z.md`
- Lane E Claude: `tasks/a9c255826143a7b23.output`
- Lane F Claude: `tasks/a1e18291680d1fe6f.output`

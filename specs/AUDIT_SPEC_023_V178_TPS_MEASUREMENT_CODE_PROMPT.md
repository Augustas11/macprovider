---
role: code-audit
version: 1.0
date: 2026-07-03
target_pr: v1.7.8 fix TPS measurement in Stage1 probe (Track A4)
lens: CODE — correctness, edge cases, coding errors
audit_bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW/INFO acceptable if documented.
---

# CODE audit — SPEC-023 v1.7.8 TPS measurement fix

Audit for correctness bugs on the current diff. Report CRITICAL/HIGH/
MEDIUM/LOW/INFO with file:line and concrete defect scenarios. No
speculative findings.

## Context

v1.7.7 M5 install analysis via `macprovider-cli autotune --recommend
--json` showed:

- qwen3-coder-30b-a3b: measured 3.7 TPS vs 25 TPS gate → not eligible
- gpt-oss-20b: measured 3.6 TPS vs 30 TPS gate → not eligible

MLX warm-generation throughput on M-Base is 25-40 tok/s for these
models. The measured 3-4 TPS is a 10× under-report driven by two
compounding bugs in `Stage1Prober.probeOnce`:

**Bug 1** (line 580 pre-v1.7.8):
`outputTokens = generatedText.split(\.isWhitespace).count`
This counts **whitespace-separated English words**, not tokens.
English averages ~0.75 words per token, so under-counts by ~1.3×.

**Bug 2** (line 581 pre-v1.7.8):
`elapsed = ended.timeIntervalSince(started)`
`started` is the time of the HTTP POST, before the request is even
sent. So `elapsed` includes TTFT — the full prefill wall-clock. For
a 3200-token prompt on M-Base, prefill can dominate (5-30s even
after v1.7.7's prewarm). Generation of 64 tokens takes 1-2s. The
denominator is 3-15× too large.

## The fix

At `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
`probeOnce`:

1. Add `deltaCount` counter incremented once per SSE content delta
   received. MLX serve emits one delta per generated token, so this
   is a much closer proxy to true token count than word count.

2. Replace `elapsed = ended.timeIntervalSince(started)` with
   `generationElapsed = ended.timeIntervalSince(firstTokenAt)` —
   only measures time from first token to last, excluding TTFT.

3. `throughputTPS = Double(outputTokens) / generationElapsed` where
   `outputTokens = max(1, deltaCount)`.

`ttftMS` calculation unchanged (still `firstTokenAt - started`).

Version bump: 1.7.7 → 1.7.8.

## Tests added

- `testStage1ProberTPSCountsDeltasAndDividesByGenerationTime` — new
  mock (`slowTTFTFastDeltasScript`) emits 20 SSE deltas fast after a
  deliberate 1.5s TTFT delay. Post-v1.7.8 TPS ≈ 20 / 0.02 = 1000+ tok/s.
  Pre-v1.7.8 total-elapsed math would produce ~13 TPS (20 deltas /
  1.5s). Asserts `medianTPS > 50` — impossible to hit with pre-v1.7.8
  math but easy to hit post-v1.7.8. Also asserts `p95TTFTMS > 1000`
  (TTFT contract unaffected by A4).

Full suite: **802/802 pass** (was 801, +1 new).

## What to audit

1. **Division by zero** — `generationElapsed = max(0.001, ...)` matches
   the pre-v1.7.8 pattern for `elapsed`. Confirm no path can reach
   division by zero even if `firstTokenAt == ended` (both same clock
   sample would give elapsed = 0, but `max(0.001, ...)` prevents that).

2. **Delta counting when `content.isEmpty`** — SSE loop skips empty
   content via `guard ... content.isEmpty else { continue }`. Confirm
   deltas ONLY count when content is non-empty (matches
   `generatedText += content` semantics).

3. **First delta counted correctly** — the `firstTokenAt = clock()`
   assignment and `deltaCount += 1` both happen inside the same guard
   scope, after the empty check. Are they in the correct order? Any
   race where deltaCount = 0 but firstTokenAt is set?

4. **`.infinity` TTFT path** — when no first token arrives, the early
   return at line 590-596 returns `throughputTPS: 0` and doesn't use
   the deltaCount. Correct — but confirm deltaCount could genuinely be
   nonzero in this path (empty-content-only deltas would count against
   deltaCount but firstTokenAt would remain nil).

   Wait — re-examine: the code path `guard let content =
   contentDelta..., !content.isEmpty else { continue }` skips empty
   content BEFORE the `firstTokenAt` assignment AND the deltaCount
   increment. So deltaCount only increments on non-empty content. If
   all deltas are empty, `firstTokenAt` stays nil and the early
   return fires. Correct.

5. **Realistic TPS bounds** — the new mock test asserts `medianTPS >
   50`. Is that too tight for CI runners with slow OS timing?
   Alternative would be to relax to `> 30` to accommodate loaded
   runners. Consider stability.

6. **Interaction with the pre-existing prewarm at line ~465** — prewarm
   throws away its result. But it DOES call `probeOnce` which now counts
   deltas locally. Is there any state that persists between prewarm
   and the real probe that could inflate deltaCount for the real probe?
   (Answer should be no: `deltaCount` is a `var` inside `probeOnce`,
   scoped to each invocation. Confirm.)

## Files to read

- `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
- `phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift`

## Reply format

```
## CODE audit — v1.7.8

CRITICAL: <count>
HIGH: <count>
MEDIUM: <count>
LOW: <count>
INFO: <count>

### CRITICAL
[if none: "None."]
### HIGH
### MEDIUM
### LOW
### INFO
### Verdict
```

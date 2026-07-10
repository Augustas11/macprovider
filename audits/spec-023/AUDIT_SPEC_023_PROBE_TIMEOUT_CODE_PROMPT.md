---
role: code-audit
version: 1.0
date: 2026-07-02
target_pr: v1.7.5 Stage1 probe timeout + infeasible-reason persistence
lens: CODE — correctness, edge cases, coding-error patterns
audit_bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW/INFO acceptable if documented.
---

# CODE audit — SPEC-023 v1.7.5 probe timeout + diagnostics

You are a code-review specialist. Independently audit this change for
**correctness bugs and coding errors**. Do not defer to earlier reviewer
opinions. Report findings as CRITICAL / HIGH / MEDIUM / LOW / INFO with
concrete file:line references and a defect-scenario sketch.

## Context

macprovider-cli v1.7.4 shipped SPEC-023 autotune-recommend, but the M5
32GB Tier C operator install kept returning "donor mode only" after
model downloads completed. Root cause: `Stage1Iterator.swift:522` set
`URLRequest.timeoutInterval = max(1, TimeInterval(Stage1Prober.maxTokens))`
= 64 seconds. `URLRequest.timeoutInterval` is an **idle timeout** — max
seconds without any bytes arriving from the server. For an MLX 30B MoE
prefilling a ~3200-token probe on M-Base hardware, TTFT can exceed 64s
before the first byte, so the probe URLSession threw `.timedOut` before
any measurement was possible. Every candidate returned
`.infeasible(reason:nErr:)`. Worse, the `.infeasible(reason:)` string
was silently discarded — the persisted `last-recommendation.json` had
`benchmark_id: null` with no clue why.

## The change under review (Fix A + Fix B)

### Fix A — Realistic probe idle timeout
- `Stage1Prober` now takes an optional `probeIdleTimeoutSec: TimeInterval`
  init parameter, defaulting to `defaultProbeIdleTimeoutSec = 300`
  seconds (5 minutes).
- Value is clamped to `max(1, probeIdleTimeoutSec)` on stored assignment.
- `probeOnce` now uses `request.timeoutInterval = probeIdleTimeoutSec`
  instead of the buggy `TimeInterval(maxTokens)` expression.
- File: `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`

### Fix B — Persist `.infeasible` reasons + emit stderr warn lines
- `AutotuneRecommendationBenchmarker.benchmarks(...)` return type
  changed from `[String: CandidateBenchmark]` to a new
  `BenchmarkOutcomes` struct carrying both `benchmarks` and a
  `diagnostics: [String: String]` map.
- `.infeasible(reason:nErr:)` results now write
  `"\(reason) (n_err=\(nErr))"` into `diagnostics[modelKey]`.
- Rows skipped by pre-probe RAM/tier/runtime-status gates ALSO write a
  specific reason string. Prior code used `guard ... else { continue }`
  and dropped the reason.
- `AutotuneRecommendResult` gained a `probeDiagnostics: [String: String]`
  field (defaulted `[:]` for source compat).
- `storedStateJSON()` emits `"probe_diagnostics":{...}` with keys sorted
  lexicographically for deterministic output.
- `LastRecommendationState` decodes `probe_diagnostics` via
  `decodeIfPresent(...) ?? [:]` so pre-v1.7.5 files still parse.
- `AutotuneCommand.runAutotuneRecommend` now writes each diagnostic to
  stderr as `[warn] spec-023 probe: <modelKey>: <reason>` before
  invoking `engine.recommend()`, and attaches `outcomes.diagnostics` to
  the result post-hoc.
- Files:
  - `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
  - `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift`

### Version bump
- `CoordinatorClient.binaryVersion`: `1.7.4` → `1.7.5`.

## Tests added
- `testStage1ProberDefaultIdleTimeoutIsSafeForLargePrefill`
- `testStage1ProberClampsSubSecondTimeoutToOne`
- `testBenchmarksReturnsInfeasibleDiagnostics`
- `testBenchmarksDiagnosesRowsSkippedByRAMGate`
- `testBenchmarksDiagnosesRowsSkippedByBandwidthGate`
- `testStoredStateJSONIncludesProbeDiagnostics`
- `testStoredStateJSONEmitsEmptyDiagnosticsObjectWhenNone`
- `testLastRecommendationStateDecodesProbeDiagnostics`
- `testLastRecommendationStateDecodesOldJSONWithoutProbeDiagnostics`
- Result: `swift test` 781/781 pass (was 772 in v1.7.4).

## What to audit

Correctness bugs and coding errors. Non-exhaustive checklist:

1. **Timeout value chosen (300s)** — does it correctly represent an
   idle timeout in URLSession semantics? Any hardware/model combination
   where 300s is still insufficient? Any concern that it masks
   legitimately-broken servers (a server that hangs forever)?
2. **Clamp `max(1, probeIdleTimeoutSec)`** — is this the right lower
   bound? Any way a caller can bypass the clamp?
3. **`BenchmarkOutcomes` return-type change** — could any caller silently
   miss the diagnostics? Are all existing call sites updated?
4. **Diagnostic key coverage** — does every code path that skips a
   candidate write a diagnostic entry, or are there silent-drop paths?
5. **Ordering / determinism** — `storedStateJSON()` sorts by key; is
   that consistent with how `probeDiagnostics` is populated?
6. **JSON emission safety** — is `jsonEscaped` on both keys and values?
   Are quotes/backslashes/newlines in reason strings handled?
7. **Backwards compatibility** — old `last-recommendation.json` files
   without `probe_diagnostics`. Test covers happy path; are there weird
   partial files that break?
8. **stderr write blocking** — `FileHandle.standardError.write(...)`
   can block on a full pipe. Is this concerning inside `benchmarks()`
   caller or okay?
9. **Concurrency / actor isolation** — `AutotuneRecommendationBenchmarker`
   is a struct-with-vars. Any data-race concerns introduced by the
   change to `BenchmarkOutcomes`?
10. **`probeDiagnostics` on `AutotuneRecommendResult`** — is it always
    populated where it should be, or does any code path emit a result
    without diagnostics that a user would benefit from?

## Files to read

- `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
- `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift`
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
- `phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift`

## Reply format

```
## CODE audit — v1.7.5

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

Findings that do NOT reproduce as concrete bugs on the current diff
must be omitted or downgraded to INFO. No speculative "consider
adding X" nits at HIGH+ unless there's a real defect scenario.

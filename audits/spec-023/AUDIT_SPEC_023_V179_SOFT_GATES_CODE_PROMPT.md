---
role: code-audit
version: 1.0
date: 2026-07-03
target_pr: v1.7.9 soft-signal TPS + TTFT eligibility gates (Track A5 Option B)
lens: CODE — correctness, edge cases, coding errors
audit_bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW/INFO acceptable if documented.
---

# CODE audit — SPEC-023 v1.7.9 soft TPS + TTFT gates

Audit for correctness bugs on the current diff. Report CRITICAL/HIGH/
MEDIUM/LOW/INFO with file:line and concrete defect scenarios.

## Context

v1.7.8 M5 32GB Tier C install produced:
- qwen3-coder-30b-a3b: TPS=23.4 (vs 25 gate), net=$0.0178/hr, `eligible=false`
- gpt-oss-20b: TPS=16.7 (vs 30 gate), net=$0.0054/hr, `eligible=false`
- llama-3.1-8b: TPS=23.4 (vs 20 gate ✓), net=$0.0020/hr (below $0.005 threshold)

Every candidate had positive net income projections but was blocked by
the CATALOG TPS/TTFT gate at
`AutotuneRecommendEngine.isEligible` — a warm-service QoS target
calibrated for M-Pro/M-Max hardware. M-Base Tier C sustains below-
gate TPS, so all install-time recommendations get vetoed → donor mode
→ drop-out cliff.

Pattern precedent: v1.7.6 A2a relaxed `swapDetected` from hard-block
to soft-signal + `.swapObservedUnderLoad` warning. Same principle
here: TPS/TTFT are QoS aspirations, `expected_net_usd_per_hour >=
paidThreshold` is the real financial gate.

## The change

At `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`:

1. Two new warnings: `.tpsBelowGate = "tps_below_gate"` and
   `.ttftAboveGate = "ttft_above_gate"`.

2. `isEligible`:
   ```swift
   // Pre-v1.7.9:
   guard benchmark.sustainedTPS >= candidate.benchGate.minSustainedTPS,
         benchmark.ttftMS <= candidate.benchGate.max4KTTFTMS,
         !benchmark.thermalThrottleDetected
   else { return false }
   // Post-v1.7.9:
   return !benchmark.thermalThrottleDetected
       && Self.cachedBenchmarkAdmitted(...)
   ```

3. `donorModeCompatible`: same relaxations, inheriting paid-tier
   behavior.

4. In `recommend()` post-selection warning-insertion loop (which
   already fires warnings only for the actually-recommended
   candidate per codex CODE-LOW-1 from v1.7.6), added:
   ```swift
   if let benchmark = request.benchmarks[target.catalogKey],
      let candidateRow = request.candidateCatalog.rows[target.catalogKey] {
       if benchmark.sustainedTPS < Double(candidateRow.benchGate.minSustainedTPS) {
           warnings.insert(.tpsBelowGate)
       }
       if benchmark.ttftMS > candidateRow.benchGate.max4KTTFTMS {
           warnings.insert(.ttftAboveGate)
       }
   }
   ```

Version bump: 1.7.8 → 1.7.9.

## Tests added

- `testTPSBelowGateNoLongerBlocksEligibilityButEmitsWarning`
- `testTTFTAboveGateNoLongerBlocksEligibilityButEmitsWarning`
- `testNoTPSWarningWhenBenchmarkClearsGate`
- `testDonorModeInheritsTPSAndTTFTRelaxation`

Full suite: **806/806 pass** (was 802, +4).

## What to audit

1. **Type coercion in warning comparison** — `benchmark.sustainedTPS`
   is `Double`, `benchGate.minSustainedTPS` is `Int`. The cast
   `Double(candidateRow.benchGate.minSustainedTPS)` should preserve
   value. Any way an integer > 2^53 loses precision here? (Unlikely
   for TPS gates < 100 but confirm.)

2. **Warning scope correctness** — the tps/ttft warnings are inside
   the same `attachTargets` loop that fires `.swapObservedUnderLoad`.
   Confirm they only fire for the ACTUALLY-recommended candidate
   (or donor fallback), not any lower-ranked scored candidate.

3. **Interaction with `expected_net_usd_per_hour < paidThreshold`
   filter** — recommended is nulled if net < $0.005/hr. In that case,
   `recommended = nil`, so `attachTargets` becomes
   `donorFallback.map(...)`. Do the tps/ttft warnings fire correctly
   for the donor fallback too? Verify with the fallback path.

4. **Edge case: benchmark absent** — `request.benchmarks[target.catalogKey]`
   could be nil (e.g., if benchmarker returned .infeasible). Then no
   tps/ttft warning fires. Correct — no benchmark = no measurement
   to compare against.

5. **Thermal throttle interaction** — thermal throttle is a hard-block
   in `isEligible`. But the warning check runs after selection, and
   selection excludes thermal-throttled candidates. So tps/ttft
   warnings can't co-exist with thermal-throttle at scoring time.
   Confirm this is the desired ordering.

6. **Donor-mode fallback path** — `donorModeCompatible` no longer
   checks TPS or TTFT. Is there ANY code path where a candidate would
   have been rejected by TPS/TTFT in donor mode but is now admitted?
   Confirm that's intentional (matches paid-tier philosophy).

7. **Test `testDonorModeInheritsTPSAndTTFTRelaxation`** uses
   extreme values (TPS=1, TTFT=100_000ms). Verify these still pass
   the OTHER admission checks (RAM, tier, thermal, cached
   benchmark). Otherwise the test asserts the wrong thing.

## Files to read

- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
  (esp. `AutotuneRecommendWarning`, `isEligible`,
  `donorModeCompatible`, warning-attach loop in `recommend()`)
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
- `phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift`

## Reply format

```
## CODE audit — v1.7.9

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

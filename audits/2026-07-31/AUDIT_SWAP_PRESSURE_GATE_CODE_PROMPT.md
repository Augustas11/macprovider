# Codex CODE audit — swap-gate → memory-pressure fix (branch fix/swap-pressure-gate)

You are a correctness-focused code auditor. Report defects only; DO NOT edit any files.

## What to read
- Full fix diff: `/Users/augstar/macprovider-poc/scratchpad/swap-pressure-fulldiff.patch`
- Changed source (authoritative, read in full):
  - `/Users/augstar/macprovider-swap-pressure-gate/phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
  - `/Users/augstar/macprovider-swap-pressure-gate/phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift`

## Context
This is money-path provider-admission code. Previously paid eligibility was vetoed by `swapDetected = afterPageouts > beforePageouts` on a machine-wide cumulative `vm_stat` "Pageouts" counter sampled once before/after the probe — a zero-threshold, non-process-scoped signal that false-blocked ~100% of legitimate 8GB installs. The fix replaces the signal with `kern.memorystatus_vm_pressure_level` (via `sysctlbyname`), interval-samples it (~500ms) across the probe into a series, and redefines `swapDetected` as sustained CRITICAL (>=3 samples AND >=50% `.critical`). WARNING-majority is advisory-only (`swapObservedUnderLoad`, local telemetry, not on the wire). The `swap_detected` wire field, `CandidateBenchmark` shape, and the eligibility veto call site are intentionally unchanged. PR #742's protection against a genuine 32GB thrash incident must still hold.

## Audit focus (rate each finding CRITICAL/HIGH/MEDIUM/LOW/INFO with file:line + concrete failure scenario)
1. **Concurrency:** the background `Task` sampler loop, the `ProbeSafetySampleBuffer` locking, `defer { samplingTask.cancel() }` + explicit cancel, and the snapshot after cancel. Any data race, use-after-cancel, leaked task, or lost/duplicated sample? Is the buffer's `@unchecked Sendable` locking actually correct (lock around every read and write)? Can the sampler Task outlive the loop iteration or run against a torn-down runner? Interaction with the existing `interruptFlag`/SIGTERM handling (ARCH-M-1) between candidates.
2. **assess() edge cases:** empty series; series of length 1 or 2 (can it ever wrongly block or wrongly pass?); mixed unknowns diluting the critical majority (`criticalCount * 2 >= pressureLevels.count` uses total count including unknown/warning — is that the intended and safe behavior?); all-unknown fail-closed; exactly-50% boundary; warning+critical mixes.
3. **Signal correctness:** `MemoryPressureLevel.current()` — sysctl size handling, the 1/2/4 mapping, error/unknown mapping, endianness/type width of the Int32 read. Any case where a healthy machine reads `.critical`, or a thrashing machine reads `.normal`?
4. **Sampling cadence:** first interval sample only fires at t=500ms after a t=0 sync sample, so probes shorter than ~1s yield <3 samples and can NEVER trip swapDetected. Is that a correctness gap for a genuinely-thrashing fast probe? Does thrash reliably lengthen the probe enough to accrue >=3 samples?
5. **Behavior preservation:** confirm the `swap_detected` wire field, `CandidateBenchmark`, evidence serialization (`AutotuneHardwareEvidence.swift`), and the `isEligible` veto are truly unchanged in effect. Confirm the transcript `swap_observed_under_load` warning still fires when a node IS blocked (so operators see why).
6. **Test adequacy:** do the new/changed tests actually pin the behavior (sustained-critical blocks; incidental-warning passes; advisory flag set; single-transient-unknown passes; all-unknown fail-closed; the existing "swapping qwen3-coder-30b must never win" test still meaningful)? Any missing case (e.g. <3 samples, exactly 50%, telemetry side effects)?

## Output
A ranked list, most-severe first. For each: severity, file:line, one-sentence defect, concrete failure scenario. If zero C/H/M, say so explicitly. Do not restate the design; only defects.

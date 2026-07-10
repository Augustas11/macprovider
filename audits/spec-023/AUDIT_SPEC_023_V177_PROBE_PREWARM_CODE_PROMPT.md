---
role: code-audit
version: 1.0
date: 2026-07-03
target_pr: v1.7.7 Stage1 probe prewarm (Track A3)
lens: CODE — correctness, edge cases, coding errors
audit_bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW/INFO acceptable if documented.
---

# CODE audit — SPEC-023 v1.7.7 Stage1 probe prewarm

Audit for correctness bugs on the current diff. Report findings CRITICAL/
HIGH/MEDIUM/LOW/INFO with file:line references and concrete defect
scenarios. Reject speculative "consider also X" findings without a real
break scenario.

## Context

v1.7.6 M5 32GB install still exited `no_eligible_paid_model` despite
default-tier fallthrough + swap tolerance. Diagnosis:

`Stage1Prober.probeOnce` at
`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift` measures
**cold-start TTFT** — wall-clock from HTTP POST to first byte on a
freshly-spawned MLX subprocess. That includes model load (10-30s) +
prefill of the padded 3200-token prompt (30-90s on M-Base).

Catalog `candidate.benchGate.max4KTTFTMS` encodes **warm-service SLO**:
2500ms for llama-3.1-8b, 3000ms for qwen3-coder-30b-a3b. The
`isEligible` check compares the cold-start TTFT (30-90s) against a
warm-service SLO (2500-3000ms) and fails every candidate.

`ProviderPreWarmer` exists in the code (used by Stage 2 hill-climb)
but `AutotuneRecommendationBenchmarker.benchmarks()` → `Stage1Prober.probe`
never invoked it. `stage1Replicates` defaults to 1, so there's no
warm-second-sample either.

## The change

At `Stage1Iterator.swift` `probe()` after `waitForReady == .ready`:

```swift
// v1.7.7 Track A3: prewarm the subprocess before measuring TTFT.
// ...doc comment explaining the fix...
_ = try? await probeOnce(model: model, port: port, targetContext: targetContext)
if case .processExited(let rc, let stderrTail) = try await runner.waitForReady(timeout: 0.05) {
    return .infeasible(
        reason: "provider exited during Stage 1 prewarm rc=\(rc): \(stderrTail)",
        nErr: max(1, replicates)
    )
}
```

Prewarm uses the SAME padded prompt as the real probe so MLX prefill
KV cache (if any) is populated for the exact prompt the real probe
will send. Prewarm errors are swallowed via `try?` — a cold-start
transient failure should not veto the run, but a subprocess exit
between prewarm and the real probe IS detected and returned as
infeasible with a `Stage 1 prewarm` reason string.

Version bump: `CoordinatorClient.binaryVersion` 1.7.6 → 1.7.7 + test
assertion strings updated.

## Tests added

- `testStage1ProberPrewarmAbsorbsFirstColdStartFailure` — new mock
  returns HTTP 500 on FIRST /v1/chat/completions POST, 200 SSE
  thereafter. Pre-v1.7.7 would return `.infeasible` (real probe hits
  500). Post-v1.7.7 returns `.feasible` (prewarm eats the 500).
- `testStage1ProberDetectsProcessExitBetweenPrewarmAndProbe` — new
  mock exits(1) after responding to first POST. Prober must detect
  the exit and return `.infeasible` with a prewarm-scoped reason.

Existing SSE mocks are `while True: server.accept()` loops so they
handle the extra prewarm request without disruption.

Full suite: **793/793 pass** (was 791, +2 new).

## What to audit

1. **`try?` on prewarm** — is this the right posture? Consider what
   happens when prewarm throws for a NON-cold-start reason (e.g.
   network layer, cancellation). Any way that swallowed error masks
   a real issue?
2. **Subsequent `waitForReady(timeout: 0.05)` semantics** — the same
   pattern is used INSIDE the replicates loop at line 481. Confirm
   the post-prewarm check is placed correctly (after `try?` returns,
   before the real loop begins).
3. **Prewarm timing on hardware where the model actually is warm** —
   e.g. when the runner's snapshot dir is already loaded, prewarm
   completes fast. Any concern that on very-fast hardware the prewarm
   adds unnecessary latency? (Should be small — same request cost as
   one probe iteration.)
4. **`stopGraceSeconds` interaction** — the `defer runner.stop(...)`
   at line 443 fires after ALL prewarm + probe + waitForReady work.
   Any concern that a hanging prewarm on a truly-stuck subprocess
   prevents the defer from running until the URLRequest hits its
   300s idle timeout?
5. **Return-type consistency** — the new `.infeasible(reason:
   "provider exited during Stage 1 prewarm ...")` uses
   `nErr: max(1, replicates)`, matching the sibling paths at line
   451 and 456. Correct?
6. **Race between prewarm response and post-check** — mock exits(1)
   after responding to prewarm; the check runs on `waitForReady(timeout:
   0.05)`. Is 50ms enough for the OS to observe subprocess exit? Look
   at how the existing loop's post-check (line 481) handles this.

## Files to read

- `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
  (esp. `probe()` around the new prewarm block)
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
  (version bump)
- `phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift`
  (2 new tests + mock helpers)

## Reply format

```
## CODE audit — v1.7.7

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

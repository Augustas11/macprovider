---
role: architect-audit
version: 1.0
date: 2026-07-03
target_pr: v1.7.7 Stage1 probe prewarm (Track A3)
lens: ARCHITECTURE — layering, contract, evolution
audit_bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW/INFO acceptable if documented.
---

# ARCHITECT audit — v1.7.7 Stage1 probe prewarm

Audit for structural / evolution issues on the current diff.

## Context

`Stage1Prober.probeOnce` measures wall-clock TTFT of a POST to the
local MLX subprocess. The catalog's `benchGate.max4KTTFTMS` was set
to warm-service latency (2500-3000ms). Cold-start on M-Base can
take 30-90s. Every candidate failed eligibility.

v1.7.7 adds a prewarm request immediately after `waitForReady == .ready`.
Prewarm uses the SAME padded prompt as the real probe so any prefill
caching benefit MLX offers is captured.

## What to audit

### 1. Prewarm placement — SPEC-023 contract alignment

SPEC-023 v0.1 documents the Stage 1 probe flow but does not (yet)
name a prewarm step. Consider:
- Is this an implicit contract change that should be recorded in
  SPEC-023 v0.2?
- Should the prewarm behavior be a normative REQUIRED step or
  MAY-implement discretion?
- What happens if a future implementation drops the prewarm — does
  it reintroduce the v1.7.6 cliff silently?

### 2. Duplication of "prewarm" concept

`ProviderPreWarmer` already exists (used by Stage 2 hill-climb). Now
Stage 1 has its OWN inline prewarm inside `Stage1Prober.probe`.
Consider:
- Is this the right factoring? Should Stage 1 use `ProviderPreWarmer`
  too, or does that produce coupling / injection burden?
- Should the prewarm be extracted into a `Stage1PreWarming` method
  so tests can inject alternate prewarm behavior?
- Any risk of the two prewarm implementations diverging over time?

### 3. Warm vs cold measurement contract

The TTFT gate in the catalog is now implicitly a "warm-service" TTFT
because the prober prewarms. Downstream consumers might not know this
about the measurement. Consider:
- Is `benchmark.ttftMS` documented anywhere as "warm-service" vs
  "cold-start"? If not, add a comment or SPEC note.
- Does any other code that reads `benchmark.ttftMS` assume cold-start
  semantics? Grep for consumers.

### 4. Replicates interaction

`stage1Replicates` defaults to 1. With prewarm, the ONE replicate is
measured warm. If `stage1Replicates > 1`, all replicates measure warm
(since MLX presumably keeps the model loaded across requests).
Consider:
- Is the prewarm cost amortized over 1 replicate today — could it
  become dominant if `stage1Replicates = 3` in future config?
- Should prewarm cost be logged/tracked separately?

### 5. Failure mode: prewarm passes, real probe fails

If prewarm succeeds but the real probe fails, current code lets the
existing per-replicate `catch` and post-check drive the outcome.
Confirm this maintains the same error-classification semantics as
before v1.7.7 for the failure case.

### 6. Failure mode: prewarm fails silently, real probe succeeds

The `try?` swallows prewarm errors. If prewarm hits a transient error
that would have surfaced production issues (e.g. memory pressure
during model load), the operator never sees it. Consider:
- Should there be a log line for prewarm failures visible to
  operators (currently they only see the aggregated infeasible-with-
  reason)?
- Is this an observability gap worth closing?

## Files to read

- `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
- `phase3-binary/Sources/macprovider-cli/ProviderPreWarmer.swift`
- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
- `specs/SPEC-023-installer-autotune-recommend.md`

## Reply format

```
## ARCHITECT audit — v1.7.7

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

---
role: architect-audit
version: 1.0
date: 2026-07-03
target_pr: v1.7.8 fix TPS measurement (Track A4)
lens: ARCHITECTURE
audit_bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW/INFO acceptable if documented.
---

# ARCHITECT audit — v1.7.8 TPS measurement fix

Audit for structural issues on the current diff.

## Context

`Stage1Prober.probeOnce` now returns `throughputTPS` computed as:
- `outputTokens = max(1, deltaCount)` — counts SSE content deltas
- `generationElapsed = max(0.001, ended.timeIntervalSince(firstTokenAt))`
- `throughputTPS = Double(outputTokens) / generationElapsed`

Pre-v1.7.8 used whitespace-word count and total elapsed (including
TTFT).

## What to audit

### 1. Measurement contract change

Catalog `min_sustained_tps` values (20-30 for various models) now
gate against warm-generation throughput semantics. Consider:
- Is this contract documented anywhere (SPEC-023, catalog schema, ADR)?
- If a future implementation reverts to total-elapsed, catalog gates
  would silently over-block again. Add a normative SPEC note?

### 2. SSE-delta-count assumption

The fix relies on "MLX serve emits one delta per token." Consider:
- Is this a stable contract of MLX serve? Any risk of a future MLX
  version batching tokens per chunk (e.g. 4 tokens per delta)?
- If MLX starts emitting multi-token deltas, TPS reports would drop
  by 4×. Silent under-report — provider would fail eligibility for
  no fault of theirs.
- Would a tokenizer-based measurement be more stable? (Tradeoff:
  need to embed a tokenizer.)

### 3. Interaction with prewarm (v1.7.7)

Prewarm calls `probeOnce` too — its result is discarded via `try?`.
Confirm the deltaCount local scoping is per-invocation. Any risk that
Swift async retains state that leaks between the prewarm's probeOnce
call and the real replicates loop's probeOnce calls?

### 4. Edge cases in the eligibility path

With correct TPS measurement, more candidates now clear the TPS gate.
Downstream `expectedNetUSDPerHour < paidThreshold` may become the new
bottleneck instead of TPS. Consider:
- Are there candidates that will now pass TPS but fail net-yield?
  (Yes: llama-3.1-8B at $0.027/M rate.)
- Is that behavior correct? (Yes — it means the catalog is honest
  about which models earn enough.)
- Should the `.recommendationBelowThreshold` warning surface differently
  now that it will fire more often?

### 5. Data-shape stability

`SingleProbeResult.throughputTPS` type/units unchanged (Double,
tokens/second). Downstream consumers (`benchmarks()` → `.feasible`
switch) don't care about the internal math change. Confirm no
serialization/persistence issue.

## Files to read

- `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
- `specs/SPEC-023-installer-autotune-recommend.md`

## Reply format

```
## ARCHITECT audit — v1.7.8

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

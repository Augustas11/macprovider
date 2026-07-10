---
role: architect-audit
version: 1.0
date: 2026-07-02
target_pr: v1.7.5 Stage1 probe timeout + infeasible-reason persistence
lens: ARCHITECTURE — layering, contracts, evolution, blast radius
audit_bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW/INFO acceptable if documented.
---

# ARCHITECT audit — SPEC-023 v1.7.5 probe timeout + diagnostics

You are an architecture-review specialist. Independently audit this
change through a **structural / evolution** lens — layer contracts,
persistence-schema stability, protocol / SPEC alignment, coupling to
external systems, and blast radius of future changes. Report only
findings that block correctness or produce measurable long-term cost.

## Context

macprovider-cli v1.7.5 fixes a v1.7.4 install regression:
- Fix A: `Stage1Prober` probe URLRequest was using a 64s idle timeout
  (`TimeInterval(maxTokens)`), which under-provisioned prefill on
  M-Base + 30B MoE. Now 300s default via constructor parameter.
- Fix B: `.infeasible(reason:)` and pre-probe gate rejections now
  surface to stderr and persist into `last-recommendation.json`
  as a new `probe_diagnostics` map.

`AutotuneRecommendationBenchmarker.benchmarks()` return type changed
from `[String: CandidateBenchmark]` to `BenchmarkOutcomes` struct with
`benchmarks` + `diagnostics` fields.

`AutotuneRecommendResult` gained `probeDiagnostics: [String: String]`
(defaulted `[:]` for source compat). `LastRecommendationState` gained
the same field and `decodeIfPresent(...) ?? [:]` for wire compat.

Binary version: 1.7.4 → 1.7.5.

## What to audit

### 1. `BenchmarkOutcomes` type shape

The new struct wraps benchmarks + diagnostics. Is this the right
representation?
- Should it also carry per-model gate metadata (RAM headroom, tier
  match) alongside diagnostics? Or is the current lean shape correct?
- Any concern that adding fields later will break Equatable / test
  fixtures?

### 2. `probeDiagnostics` map schema stability

Wire schema is `Map<String, String>` where the string value is
free-form. Consider:
- Is a flat map the right shape for future evolution? What if we later
  want to record per-model TTFT-observed / TPS-observed even when
  infeasible?
- Should the value be a struct `{reason, nErr}` instead of pre-joined
  `"reason (n_err=N)"`? Consumers may want to parse `nErr` separately.
- Does the JSON schema-version bump warrant a discriminator field
  (`schema_version` — but `last-recommendation.json` doesn't currently
  carry one)?

### 3. `last-recommendation.json` schema evolution

Persistence file was previously implicit-schema. Adding
`probe_diagnostics` maintains backward-compat via `decodeIfPresent`.
- Do downstream consumers exist that parse this file and would ignore
  unknown fields correctly? Check coordinator, portal, any dashboard.
- Should the file have a `schema_version` field so future changes are
  safer? Not necessarily this PR's job, but worth calling out.

### 4. Probe timeout as a contract

Extracting timeout from a hard-coded constant to an init parameter
opens configuration surface. Consider:
- Should this be surfaced as a CLI flag on `autotune --recommend` for
  operators on unusually slow hardware? Or is 300s always sufficient?
- Does the value belong on `Stage1Prober` or on the rate-card / catalog
  (per-model expected TTFT)?
- Where should the SPEC-023 v0.3 document be updated to record this
  contract? (specs/ — check.)

### 5. Stderr-warn coupling to caller

`AutotuneCommand.runAutotuneRecommend` iterates `outcomes.diagnostics`
and writes stderr. `benchmarks()` no longer emits directly. This is
correct separation (benchmarker is pure), but:
- Is there any risk that other callers of `benchmarks()` (existing or
  future) will skip the stderr emission and users won't see the
  warning?
- Should the emission be inside `benchmarks()` or a helper on
  `BenchmarkOutcomes`?

### 6. `.blocked` runtime-status treated as diagnostic-worthy

Prior code silently skipped `row.runtimeStatus == "blocked"`. New code
writes `"catalog row blocked by upstream"`. Is that the right message?
Should it distinguish "coordinator explicitly blocked" from "row
missing from catalog"?

### 7. Blast radius on Equatable / tests

`AutotuneRecommendResult` gained a mutable field. All existing
`Equatable` conformance-based tests still pass. Confirm no fixture is
frozen against the old shape and would produce misleading test
success/failure.

### 8. SPEC document alignment

SPEC-023 v0.3 documents Stage 1 probing. Should this PR also update
that SPEC to record:
- The 300s probe idle timeout as a normative contract
- The `probe_diagnostics` field as a normative output of the
  autotune-recommend flow
- Or is this deferred to a follow-up SPEC-023 v0.4?

## Files to read

- `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
  (esp. `BenchmarkOutcomes`, `AutotuneRecommendResult`,
  `LastRecommendationState`, `storedStateJSON`)
- `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift`
- `specs/SPEC-023-*.md` (any latest v0.x)
- `phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift`

## Reply format

```
## ARCHITECT audit — v1.7.5

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

Findings must cite the specific file:line and describe the concrete
future scenario that would surface the issue. Speculative
"consider also X" without a concrete break-scenario ⇒ INFO or drop.

# SPEC-029 - Sweep Workload-Class Stratification

**Version:** 0.1-draft
**Status:** Draft, research round. Implementation MUST NOT begin before maintainer review.
**Date drafted:** 2026-07-09
**Depends on:** SPEC-013, SPEC-023, SPEC-028, beta buyer harness workload/report schema.

SPEC-029 defines a class-aware sweep and candidate-publication shape for MacProvider autotune research. It produces per-workload winners as data. It does not introduce runtime request classification or class-routed serving.

## 1. Mission

MacProvider's beta harness already measures performance per workload, but serve-knob selection and static candidate recommendation are class-blind. SPEC-029 makes workload shape a first-class partition in sweep outputs so autotune can publish per-workload recommendations instead of one compromise config across short chat, medium chat, long context, code, and agent-style traffic.

This SPEC is a companion to SPEC-028. Speculative decoding adds draft-model and `num_draft_tokens` choices whose value depends on prompt/content shape. SPEC-029 defines how those choices are measured and published by workload without changing SPEC-028's provider runtime contract.

## 2. Scope

### In scope

- Workload-stratified sweep runs over the existing context/concurrency/kv search shape.
- Per-workload winner selection.
- Class-specific report rows and gates.
- Additive static-catalog schema for per-workload recommendation profiles.
- Open questions for future runtime routing/classification.

### Non-goals

- No buyer API change.
- No coordinator routing-policy change.
- No provider request-time classifier.
- No settlement, receipt, or billing schema change.
- No modification to SPEC-013 or SPEC-028.
- No requirement to regenerate old class-blind sweep reports.
- No implementation changes in this draft PR.

## 3. Terms

- **Workload name:** The beta harness registry key, such as `short_chat` or `code_completion`.
- **Corpus class:** The sampling category in `_WORKLOAD_CORPUS_MAP`, such as `short`, `medium`, or `code`.
- **Workload profile:** A static-catalog profile keyed by workload name containing measured profile metrics, the gate policy used to choose the winner, and recommended knobs.
- **Winner:** The selected serve-knob tuple for one workload name and one target model candidate.

## 4. Normative Requirements

### FR-1. Sweep partitioning

The sweep implementation MUST treat workload name as a partition/filter over the existing sweep grid, not as a single global optimization that emits one winner across all classes.

For every included workload name, the sweep MUST evaluate the configured context/concurrency/kv search cells and emit one class-local winner or one explicit no-winner result.

The sweep MUST preserve the existing class-blind run/report mode unless a later implementation SPEC explicitly removes it.

### FR-2. Included workloads

The v0.1 class-aware winner set MUST include these workload names:

- `short_chat`
- `medium_with_system`
- `long_context`
- `code_completion`
- `agent_style`

`streaming_check` MUST be treated as a streaming TTFT probe/gate in v0.1. It MUST NOT emit a separate serve-knob winner unless a future SPEC defines a runtime profile that can use it.

### FR-3. Trial and report identity

Class-aware sweep artifacts MUST record at least:

- target model identifier
- workload name
- corpus class, when known
- context limit cell
- concurrency cell
- kv-bit cell
- measured TTFT, total latency, error count, and stop-token leak state
- token counts and throughput when emitted by the response path
- `metric_unavailable_reason` when token counts or throughput are unavailable
- winner/no-winner decision and reason

Implementations SHOULD keep the existing `workload` field name when operating on beta harness rows and add a separate `workload_class` or `corpus_class` field only when both names must be represented.

For speculative search cells, artifacts MUST also record:

- draft model identifier
- draft model artifact SHA-256, when the candidate is runnable
- `num_draft_tokens`
- drafted token count, accepted token count, and acceptance rate when speculative decoding was attempted
- candidate source, such as a static `draft_candidates[]` row, local operator override, or research fixture

### FR-4. Winner tuple

For non-speculative rows, a winner tuple MUST include:

```text
(kv_bits, max_context_override, max_concurrency_override)
```

For SPEC-028 speculative rows, a winner tuple MAY additionally include:

```text
(draft_model, draft_model_artifact_sha256, num_draft_tokens)
```

When speculative decoding is enabled, `num_draft_tokens` MUST be selected per workload name. A single shared `num_draft_tokens` MAY be exported only as a legacy/default profile and MUST be derived from an explicit weighting policy.

Any workload profile whose `recommended` object contains `draft_model` MUST satisfy all of the following:

- The target/draft pair came from a sweep or fixture that satisfied SPEC-028 FR-4 compatibility and provenance checks, or the profile is explicitly marked with `non_runnable_reason`.
- `draft_model_artifact_sha256` is present for runnable profiles and is lowercase 64-hex.
- `num_draft_tokens` is an integer in the SPEC-028 range `1 <= N <= 16`.
- `max_concurrency_override` is not greater than `1` for runnable SPEC-028 v0.1 profiles.
- `max_context_override` does not exceed SPEC-028's effective draft-enabled context cap for the target RAM tier unless the profile is explicitly marked with `non_runnable_reason`.
- The profile SHOULD reference the row's SPEC-028 `draft_candidates[]` entry when the candidate was selected from the static catalog.

### FR-5. Tie-breaking

Tie-breaking MUST be class-local. No workload name may silently dominate another workload name's winner.

Within one workload name, the implementation MUST define deterministic tie-breakers. The recommended order for v0.1 is:

1. Zero hard failures and zero stop-token leaks.
2. Satisfies workload-specific TTFT gate.
3. Higher sustained throughput.
4. Lower TTFT.
5. Lower memory-risk posture, such as lower context or lower concurrency, when throughput is materially tied.
6. Stable lexical order of serialized tuple as a final deterministic fallback.

If a single legacy default is required, the default MUST be chosen from the per-workload winners using an explicit traffic-weighting policy documented in the report.

### FR-6. Gates

Sweep gates MUST be parameterizable by workload name.

The v0.1 default hard gate policy is:

| Workload name | Hard max p95 TTFT | Hard stop-token leak rate | Notes |
|---|---:|---:|---|
| `short_chat` | 8000 ms | 0 | Uses the existing class-blind 8s TTFT posture. |
| `medium_with_system` | 12000 ms | 0 | Allows additional prefill over short chat. |
| `long_context` | 60000 ms | 0 | Allows long-context prefill; still fails pathological stalls. |
| `code_completion` | 12000 ms | 0 | Keeps code continuation close to medium-chat latency. |
| `agent_style` | 20000 ms | 0 | Allows larger system/tool-catalog prompt shape. |
| `streaming_check` | 2000 ms | 0 | TTFT probe only; no serve-knob winner. |

Implementations MUST use these defaults unless a later SPEC or a maintainer-approved run manifest defines a replacement policy. Replacement policies MUST be serialized into the sweep report and static workload profile that used them.

At minimum:

- `long_context` MUST have an explicit TTFT/prefill gate separate from short chat.
- `streaming_check` MUST gate streaming TTFT.
- stop-token leak checks MUST be reportable per workload name.
- speculative acceptance metrics, when present, MUST be reported per workload name and target/draft pair.

Speculative acceptance rate is advisory in v0.1. It MUST be recorded when available, but it MUST NOT be a hard winner gate until a later SPEC defines a numeric threshold.

### FR-7. Static catalog extension

The static `autotune-candidates.json` schema MUST be extended additively inside each existing row with a `workload_profiles` map when SPEC-029 workload-specific recommendations are published.

The v0.1 field name is `workload_profiles`. Implementations MUST NOT publish the same data under `per_class` in v0.1.

```json
{
  "workload_profiles": {
    "code_completion": {
      "recommended": {
        "kv_bits": 4,
        "max_context_override": 20000,
        "max_concurrency_override": 1,
        "draft_model": "example/draft",
        "draft_model_artifact_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "num_draft_tokens": 4
      },
      "gate_policy": {
        "max_p95_ttft_ms": 12000,
        "max_stop_token_leak_rate": 0,
        "min_sustained_tps": null
      },
      "profile_metrics": {
        "median_tps": 8.5,
        "p95_ttft_ms": 2400,
        "stop_token_leak_rate": 0,
        "spec_decode_acceptance_rate": 0.42,
        "sample_count": 5
      },
      "source": "sweep-workload-class-2026-07"
    }
  }
}
```

`gate_policy` records the hard policy used for winner selection. `profile_metrics` records measured/advisory metrics. The nested workload profile MUST NOT reuse the top-level SPEC-023 `bench_gate` key; SPEC-023 `bench_gate.min_sustained_tps` and `bench_gate.max_4k_ttft_ms` remain advisory QoS signals for the existing recommendation engine.

`workload_profiles.<workload>.recommended` MUST use the same serve-knob names as SPEC-013/SPEC-028 config outputs. `profile_metrics` values MUST use milliseconds for TTFT, tokens per second for throughput, and a 0.0-1.0 fraction for rates. Nullable metrics MUST be encoded as JSON `null`, not omitted, when the sweep attempted the metric but the response path did not emit enough data.

Current consumers MUST be able to ignore the additive field. Implementations MUST NOT require current installer recommendation clients to understand workload profiles until the client SPEC is updated.

### FR-8. Static signing

Workload-profile catalog data MUST use the existing static autotune-catalog signing domain unless maintainers explicitly create a new trust domain.

Publishing any changed static catalog bytes MUST include a fresh signature sidecar using the SPEC-023 v4 static key process. SPEC-029 does not require a new public key.

### FR-9. Runtime classification boundary

SPEC-029 MUST NOT introduce a provider or coordinator request-time classifier.

Generated workload profiles are data for future consumers. A later SPEC MUST decide:

- whether buyer requests receive a workload label,
- whether classification occurs at the coordinator, provider, buyer, or offline recommendation layer,
- how a label affects routing, serve config, receipts, and auditability.

Until that SPEC exists, implementations MUST NOT silently switch serve knobs per request based on inferred workload class.

### FR-10. Report compatibility

Existing class-blind sweep reports MAY remain unchanged. Implementations SHOULD write class-aware reports alongside existing reports, not overwrite historical artifacts.

Reports MUST include enough metadata to reproduce winner selection, including search cells, workload name, gates, measured metrics, and tie-breaker reason.

## 5. Acceptance Criteria

- AC-1: A class-aware sweep can run every included workload name over the configured grid and emit one winner/no-winner result per workload.
- AC-2: `streaming_check` contributes TTFT gate/report data but does not emit a serve-knob winner.
- AC-3: Winner selection is deterministic and class-local.
- AC-4: SPEC-028 speculative rows can select `num_draft_tokens` per workload name.
- AC-5: Static catalog extension is additive, uses `workload_profiles`, and is ignored by existing clients that do not know the new field.
- AC-6: Changed static catalog bytes are re-signed with the SPEC-023 v4 static signing process.
- AC-7: No runtime request classifier or class-routed serving behavior is implemented under this SPEC.
- AC-8: Reports cite workload-specific gates and tie-breaker outcomes.
- AC-9: A decode/recommendation regression test proves current clients still accept a catalog row containing `workload_profiles`.
- AC-10: `streaming_check` reports TTFT, status/error, leak state, and gate outcome even when token counts and throughput are `null` because SSE usage was absent.

## 6. Open Questions

1. If a single legacy default must be exported, what traffic-weighting policy is authoritative?
2. Which follow-up SPEC owns runtime classification and class-routed serving?
3. Should a later client SPEC consume `workload_profiles` directly in installer recommendation, or should it first remain a report-only/feed-only artifact?

## 7. Evidence

- `beta/workloads.py:26` defines the workload-to-corpus mapping.
- `beta/report.py:59` summarizes rows per workload.
- `beta/harness.py:59` records workload, latency, throughput, token, and leak fields.
- `beta/DECISION_CRITERIA.md:57` through `beta/DECISION_CRITERIA.md:62` and `beta/DECISION_CRITERIA.md:89` through `beta/DECISION_CRITERIA.md:92` require per-workload decision metrics.
- `specs/SPEC-028-mlx-speculative-decoding.md:63` defines `--num-draft-tokens`.
- `specs/SPEC-028-mlx-speculative-decoding.md:202` through `specs/SPEC-028-mlx-speculative-decoding.md:215` allow autotune/static-catalog draft candidate extension points and reject blind grid multiplication.
- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift:439` decodes the current static catalog row shape.
- `specs/SPEC-023-installer-autotune-recommend.md:320` through `specs/SPEC-023-installer-autotune-recommend.md:342` define the v4 static signing process.
- `phase3-binary/dist/static/keys/README.md:32` describes the current static feed trust model.
- `scripts/resign-autotune-static.sh:1` through `scripts/resign-autotune-static.sh:3` describe the v4 static feed signing helper.
- `scripts/resign-autotune-static.sh:26` through `scripts/resign-autotune-static.sh:30` define byte-for-byte signing and sidecar shape.
- `scripts/resign-autotune-static.sh:42` pins the current static signing key ID used by the signing helper.

## 8. Research Constraints

The prompt referenced `.omc/logs/context-throughput-sweep-impl-notes.md` and `origin/spike/context-throughput-sweep`. Neither was available in the current repository state during drafting. This SPEC therefore avoids relying on undocumented 28-cell implementation details beyond the research prompt's own description.

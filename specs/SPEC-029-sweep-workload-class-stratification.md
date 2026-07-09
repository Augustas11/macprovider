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
- **Workload profile:** A static-catalog profile keyed by workload name containing measured gates and recommended knobs.
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
- measured TTFT, total latency, throughput, token counts, error count, and stop-token leak state
- winner/no-winner decision and reason

Implementations SHOULD keep the existing `workload` field name when operating on beta harness rows and add a separate `workload_class` or `corpus_class` field only when both names must be represented.

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

At minimum:

- `long_context` MUST have an explicit TTFT/prefill gate separate from short chat.
- `streaming_check` MUST gate streaming TTFT.
- stop-token leak checks MUST be reportable per workload name.
- speculative acceptance metrics, when present, MUST be reported per workload name and target/draft pair.

### FR-7. Static catalog extension

The static `autotune-candidates.json` schema SHOULD be extended additively inside each existing row with a workload profile map.

Recommended field name:

```json
{
  "workload_profiles": {
    "code_completion": {
      "recommended": {
        "kv_bits": 4,
        "max_context_override": 20000,
        "max_concurrency_override": 1,
        "draft_model": "example/draft",
        "draft_model_artifact_sha256": "lowercase-hex-sha256",
        "num_draft_tokens": 4
      },
      "bench_gate": {
        "min_sustained_tps": 8.5,
        "max_ttft_ms": 8000,
        "max_stop_token_leak_rate": 0
      },
      "source": "sweep-workload-class-2026-07"
    }
  }
}
```

The field MAY be named `per_class` only if maintainers choose that naming before implementation.

Current consumers MUST be able to ignore the additive field. Implementations MUST NOT require current installer recommendation clients to understand workload profiles until the client SPEC is updated.

### FR-8. Static signing

Workload-profile catalog data MUST use the existing static autotune-catalog signing domain unless maintainers explicitly create a new trust domain.

Publishing any changed static catalog bytes MUST include a fresh signature sidecar using the current accepted static key process. SPEC-029 does not require a new public key.

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
- AC-5: Static catalog extension is additive and ignored by existing clients that do not know the new field.
- AC-6: Changed static catalog bytes are re-signed with the existing static signing process.
- AC-7: No runtime request classifier or class-routed serving behavior is implemented under this SPEC.
- AC-8: Reports cite workload-specific gates and tie-breaker outcomes.

## 6. Open Questions

1. Should the static field be named `workload_profiles`, `per_class`, or another maintainer-preferred term?
2. If a single legacy default must be exported, what traffic-weighting policy is authoritative?
3. What numeric TTFT gates should apply to `long_context` and `streaming_check`?
4. Should speculative acceptance-rate thresholds become hard gates or advisory report fields in v0.1?
5. Which follow-up SPEC owns runtime classification and class-routed serving?

## 7. Evidence

- `beta/workloads.py:26` defines the workload-to-corpus mapping.
- `beta/report.py:59` summarizes rows per workload.
- `beta/harness.py:59` records workload, latency, throughput, token, and leak fields.
- `beta/DECISION_CRITERIA.md:54` and `beta/DECISION_CRITERIA.md:85` require per-workload decision metrics.
- `specs/SPEC-028-mlx-speculative-decoding.md:63` defines `--num-draft-tokens`.
- `specs/SPEC-028-mlx-speculative-decoding.md:202` allows autotune/static-catalog draft candidate extension points and rejects blind grid multiplication.
- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift:439` decodes the current static catalog row shape.
- `phase3-binary/dist/static/keys/README.md:32` describes the current static feed trust model.

## 8. Research Constraints

The prompt referenced `.omc/logs/context-throughput-sweep-impl-notes.md` and `origin/spike/context-throughput-sweep`. Neither was available in the current repository state during drafting. This SPEC therefore avoids relying on undocumented 28-cell implementation details beyond the research prompt's own description.

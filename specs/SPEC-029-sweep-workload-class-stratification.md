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
- **RAM-tier key:** One of `8gb`, `16gb`, `32gb`, or `64gb_plus`, derived from the sweep host's resolved provider RAM tier using the same ceil-rounded GiB thresholds as `ProviderCapacity`: at most 12 GiB maps to `8gb`; greater than 12 GiB and at most 24 GiB maps to `16gb`; greater than 24 GiB and at most 48 GiB maps to `32gb`; greater than 48 GiB maps to `64gb_plus`. When normalizing an existing provider tier string, map raw `64GB+` case-insensitively to `64gb_plus`; lowercase `8GB`, `16GB`, and `32GB` to `8gb`, `16gb`, and `32gb`. Any other provider tier string is invalid for SPEC-029 publication.
- **Evaluated candidate cell:** A configured search cell that the sweep attempted to classify, including a cell rejected at preflight as non-runnable. `no_cells_evaluated` applies only when the sweep enumerated zero cells for the workload/RAM-tier pair.
- **Workload profile:** A static-catalog profile keyed by workload name containing measured profile metrics, the gate policy used to choose the winner, and recommended knobs.
- **Winner:** The selected serve-knob tuple for one workload name and one target model candidate.

## 4. Normative Requirements

### FR-1. Sweep partitioning

The sweep implementation MUST treat `(workload name, RAM-tier key)` as the partition/filter over the existing sweep grid, not as a single global optimization that emits one winner across all classes or hardware tiers.

For every included workload name and measured RAM-tier key, the sweep MUST evaluate the configured context/concurrency/kv search cells and emit one partition-local winner or one explicit no-winner result.

The sweep MUST preserve the existing class-blind run/report mode unless a later implementation SPEC explicitly removes it.

### FR-2. Included workloads

The v0.1 class-aware winner set MUST include these workload names:

- `short_chat`
- `medium_with_system`
- `long_context`
- `code_completion`
- `agent_style`

`streaming_check` MUST be treated as a streaming TTFT probe/gate in v0.1. It MUST NOT emit a separate serve-knob winner unless a future SPEC defines a runtime profile that can use it.

New workload names added to the beta harness registry after this SPEC is locked are out of scope until a later SPEC revision explicitly adds them to the included workload set or marks them probe-only.

### FR-3. Trial and report identity

Class-aware sweep artifacts MUST record at least:

- target model identifier
- host RAM in bytes
- RAM-tier key
- workload name
- corpus class, when known
- context limit cell
- concurrency cell
- kv-bit cell
- measured TTFT, total latency, error/status state, and stop-token leak state
- token counts and throughput when emitted by the response path
- `metric_unavailable_reason` when token counts or throughput are unavailable
- winner/no-winner decision and reason

Implementations SHOULD keep the existing `workload` field name when operating on beta harness rows and add a separate `corpus_class` field only when both workload name and corpus class must be represented.

For speculative search cells, artifacts MUST also record:

- draft model identifier
- draft model artifact SHA-256 whenever the candidate cell includes `draft_model`
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

When speculative decoding is enabled, `num_draft_tokens` MUST be selected per workload name. A single shared `num_draft_tokens` MUST NOT be exported in v0.1 unless the report names the weighting policy and that policy is defined by a later SPEC revision or maintainer-approved run manifest.

Candidate cells that cannot satisfy artifact/provenance, tokenizer, probe, or capacity preconditions are not runnable. Non-runnable speculative candidate cells MUST NOT produce a `recommended` object. A non-runnable candidate cell counts as evaluated for no-winner-reason selection and MUST be classified through the FR-6 reason precedence.

Any tier-scoped workload profile whose `recommended` object contains `draft_model` MUST satisfy all of the following:

- The target/draft pair came from a sweep or fixture that satisfied SPEC-028 FR-4 compatibility and provenance checks.
- `draft_model_artifact_sha256` is present and is lowercase 64-hex.
- `num_draft_tokens` is an integer in the SPEC-028 range `1 <= N <= 16`.
- `max_concurrency_override` is not greater than `1` for runnable SPEC-028 v0.1 profiles.
- `max_context_override` does not exceed SPEC-028's effective draft-enabled context cap for the profile's RAM-tier key.
- The profile SHOULD reference the row's SPEC-028 `draft_candidates[]` entry when the candidate was selected from the static catalog.

SPEC-029 RAM-tier keys map to SPEC-028 draft context caps as follows:

| RAM-tier key | SPEC-028 draft context cap |
|---|---:|
| `8gb` | 8192 |
| `16gb` | 20000 |
| `32gb` | 50000 |
| `64gb_plus` | 120000 |

### FR-5. Tie-breaking

Tie-breaking MUST be partition-local. No workload name or RAM-tier key may silently dominate another partition's winner.

Within one workload/RAM-tier pair, the implementation MUST define deterministic tie-breakers. The recommended order for v0.1 is:

1. Zero hard failures and zero stop-token leaks.
2. Satisfies workload-specific TTFT gate.
3. Higher median throughput.
4. Lower TTFT.
5. Lower memory-risk posture, such as lower context or lower concurrency, when throughput is materially tied.
6. Stable lexical order of serialized tuple as a final deterministic fallback.

Single legacy/default export is blocked in v0.1 until the authoritative traffic-weighting policy is resolved. Implementations MUST NOT export a single default derived from per-workload winners unless the report names the weighting policy and that policy is defined by a later SPEC revision or maintainer-approved run manifest.

### FR-6. Gates

Sweep gates MUST be parameterizable by workload name.

The v0.1 default hard gate policy is:

| Workload name | Min samples | Hard max p95 TTFT | Hard stop-token leak rate | Advisory min median TPS | Notes |
|---|---:|---:|---:|---:|---|
| `short_chat` | 20 | 8000 ms | 0 | none | Uses the existing class-blind 8s TTFT posture. |
| `medium_with_system` | 20 | 12000 ms | 0 | none | Allows additional prefill over short chat. |
| `long_context` | 20 | 60000 ms | 0 | none | Allows long-context prefill; still fails pathological stalls. |
| `code_completion` | 20 | 12000 ms | 0 | none | Keeps code continuation close to medium-chat latency. |
| `agent_style` | 20 | 20000 ms | 0 | none | Allows larger system/tool-catalog prompt shape. |
| `streaming_check` | 20 | 2000 ms | 0 | none | TTFT probe only; no serve-knob winner. |

Implementations MUST use these defaults unless a later SPEC or a maintainer-approved run manifest defines a replacement policy. Replacement policies MUST be serialized into the sweep report and static workload profile that used them.

A workload/RAM-tier pair MUST NOT emit a winner unless the winning cell's successful sample count is at least the gate policy's `min_samples`. `profile_metrics.sample_count` on a winner profile MUST be the winning cell's successful sample count, not the aggregate count across every cell for that workload. When no winner is emitted, implementations MUST choose `no_winner_reason` by the precedence table below. On any no-winner profile, `profile_metrics.sample_count` MUST be the highest successful sample count observed for any candidate cell in that workload/RAM-tier pair, or `0` when no cell was evaluated. A maintainer-approved run manifest MAY replace p95 with observed maximum for a small exploratory run, but that run MUST NOT publish static-catalog workload recommendations.

No-winner reasons are a closed vocabulary in v0.1:

| Reason | Meaning |
|---|---|
| `insufficient_samples` | At least one candidate cell produced one or more successful samples, but no sampled cell reached `gate_policy.min_samples`. |
| `gate_unmet` | At least one candidate cell reached `gate_policy.min_samples`, but none of the cells that reached `min_samples` passed all hard TTFT and stop-token leak gates. |
| `hard_failure` | At least one candidate cell was evaluated, and every evaluated cell hard-failed: either non-runnable at preflight or hard-failed at runtime/request execution, so no cell produced a gate-eligible sample set. |
| `no_cells_evaluated` | Zero candidate cells were evaluated for the workload/RAM-tier pair. |

Non-runnable cells count as evaluated, but they are excluded from the `insufficient_samples` and `gate_unmet` sample-count conditions. In this table, "produced samples" means produced at least one successful, gate-eligible sample. A runtime-hard-failed cell is a cell that ran with zero successful samples. Such cells only determine `hard_failure` when every evaluated cell is non-runnable or otherwise hard-failing.

When more than one no-winner reason could apply, implementations MUST use the first matching reason in this precedence order:

1. `no_cells_evaluated`
2. `hard_failure`
3. `insufficient_samples`
4. `gate_unmet`

At minimum:

- `long_context` MUST have an explicit TTFT/prefill gate separate from short chat.
- `streaming_check` MUST gate streaming TTFT.
- stop-token leak checks MUST be reportable per workload name.
- speculative acceptance metrics, when present, MUST be reported per workload name and target/draft pair.

Speculative acceptance rate is advisory in v0.1. It MUST be recorded when available, but it MUST NOT be a hard winner gate until a later SPEC defines a numeric threshold.

### FR-7. Static catalog extension

The static `autotune-candidates.json` schema MUST be extended additively inside each existing row with a `workload_profiles` map when SPEC-029 workload-specific recommendations are published.

The v0.1 field name is `workload_profiles`. Implementations MUST NOT publish the same data under `per_class` in v0.1.

`workload_profiles` is a two-level map keyed first by workload name and then by RAM-tier key:

```text
workload_profiles.<workload_name>.<ram_tier_key> -> tier-scoped workload profile
```

The tier key MUST be one of `8gb`, `16gb`, `32gb`, or `64gb_plus`. Winner and no-winner status is scoped to one workload/RAM-tier pair. Publishing a second tier for the same workload MUST add a sibling tier key, not overwrite the existing tier profile.

```json
{
  "workload_profiles": {
    "code_completion": {
      "16gb": {
        "recommended": {
          "kv_bits": 4,
          "max_context_override": 20000,
          "max_concurrency_override": 1,
          "draft_model": "example/draft",
          "draft_model_artifact_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          "num_draft_tokens": 4
        },
        "gate_policy": {
          "min_samples": 20,
          "max_p95_ttft_ms": 12000,
          "max_stop_token_leak_rate": 0,
          "min_median_tps": null
        },
        "profile_metrics": {
          "median_tps": 8.5,
          "p95_ttft_ms": 2400,
          "stop_token_leak_rate": 0,
          "spec_decode_acceptance_rate": 0.42,
          "sample_count": 20
        },
        "source": "sweep-workload-class-2026-07"
      }
    }
  }
}
```

`gate_policy` records the hard policy used for winner selection. `profile_metrics` records measured/advisory metrics. The nested workload profile MUST NOT reuse the top-level SPEC-023 `bench_gate` key; SPEC-023 `bench_gate.min_sustained_tps` and `bench_gate.max_4k_ttft_ms` remain advisory QoS signals for the existing recommendation engine.

`workload_profiles.<workload>.<ram_tier>.recommended` MUST use the same serve-knob names as SPEC-013/SPEC-028 config outputs. `gate_policy.min_median_tps` is an optional/advisory floor over `profile_metrics.median_tps` and MUST be JSON `null` when no throughput floor was used for winner selection. `profile_metrics` values MUST use milliseconds for TTFT, tokens per second for throughput, and a 0.0-1.0 fraction for rates. Nullable metrics MUST be encoded as JSON `null`, not omitted, when the sweep attempted the metric but the response path did not emit enough data.

No-winner workloads MUST be represented in `workload_profiles` with a sentinel object instead of being silently omitted:

```json
{
  "workload_profiles": {
    "long_context": {
      "16gb": {
        "status": "no_winner",
        "no_winner_reason": "insufficient_samples",
        "gate_policy": {
          "min_samples": 20,
          "max_p95_ttft_ms": 60000,
          "max_stop_token_leak_rate": 0,
          "min_median_tps": null
        },
        "profile_metrics": {
          "median_tps": null,
          "p95_ttft_ms": null,
          "stop_token_leak_rate": null,
          "spec_decode_acceptance_rate": null,
          "sample_count": 3
        },
        "source": "sweep-workload-class-2026-07"
      }
    }
  }
}
```

Winner objects MUST either omit `status` or set `status` to `winner`. No-winner objects MUST omit `recommended`.
On no-winner profiles, `profile_metrics.sample_count` MUST be populated as defined in FR-6, and all other `profile_metrics` fields MUST be JSON `null`; measured values from rejected cells remain in the sweep report rather than the signed static catalog sentinel.

`streaming_check` is a probe/gate workload and is not part of the v0.1 `workload_profiles` winner/no-winner publication set.

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

Reports MUST include enough metadata to reproduce winner selection, including search cells, workload name, host RAM bytes, RAM-tier key, gates, measured metrics, and tie-breaker reason.

## 5. Acceptance Criteria

- AC-1: A class-aware sweep can run every included workload name over the configured grid for an evaluated RAM-tier key and emit one winner/no-winner result per workload/RAM-tier pair, with `streaming_check` remaining probe-only.
- AC-2: `streaming_check` contributes TTFT gate/report data but does not emit a serve-knob winner.
- AC-3: Winner selection is deterministic and class-local.
- AC-4: SPEC-028 speculative rows can select `num_draft_tokens` per workload name.
- AC-5: Static catalog extension is additive, uses `workload_profiles`, and is ignored by existing clients that do not know the new field.
- AC-6: Changed static catalog bytes are re-signed with the SPEC-023 v4 static signing process.
- AC-7: No runtime request classifier or class-routed serving behavior is implemented under this SPEC.
- AC-8: Reports cite workload-specific gates and tie-breaker outcomes.
- AC-9: A decode/recommendation regression test proves current clients still accept a catalog row containing `workload_profiles`.
- AC-10: `streaming_check` reports TTFT, status/error, leak state, and gate outcome even when token counts and throughput are `null` because SSE usage was absent.
- AC-11: Class-aware artifacts record the complete FR-3 field set, including `metric_unavailable_reason` when applicable and speculative drafted/accepted/acceptance metrics when speculative decoding was attempted.
- AC-12: No workload/RAM-tier pair emits a winner below `min_samples`; below-threshold pairs emit a `no_winner_reason`.
- AC-13: Draft-bearing workload profiles are keyed by RAM tier and satisfy the SPEC-028 draft context cap for that tier.
- AC-14: `no_winner_reason` is one of the closed v0.1 reason codes.

## 6. Open Questions

1. If a single legacy default must be exported, what traffic-weighting policy is authoritative?
2. Which follow-up SPEC owns runtime classification and class-routed serving?
3. Should a later client SPEC consume `workload_profiles` directly in installer recommendation, or should it first remain a report-only/feed-only artifact?

## 7. Evidence

- `beta/workloads.py:26` defines the workload-to-corpus mapping.
- `beta/report.py:59` summarizes rows per workload.
- `beta/harness.py:59` records workload, latency, throughput, token, and leak fields.
- `beta/DECISION_CRITERIA.md:57` through `beta/DECISION_CRITERIA.md:62` and `beta/DECISION_CRITERIA.md:89` through `beta/DECISION_CRITERIA.md:92` require per-workload decision metrics.
- `specs/SPEC-028-mlx-speculative-decoding.md:71` defines `--num-draft-tokens`.
- `specs/SPEC-028-mlx-speculative-decoding.md:202` through `specs/SPEC-028-mlx-speculative-decoding.md:215` allow autotune/static-catalog draft candidate extension points and reject blind grid multiplication.
- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift:439` decodes the current static catalog row shape.
- `specs/SPEC-023-installer-autotune-recommend.md:320` through `specs/SPEC-023-installer-autotune-recommend.md:342` define the v4 static signing process.
- `phase3-binary/dist/static/keys/README.md:32` describes the current static feed trust model.
- `scripts/resign-autotune-static.sh:1` through `scripts/resign-autotune-static.sh:3` describe the v4 static feed signing helper.
- `scripts/resign-autotune-static.sh:26` through `scripts/resign-autotune-static.sh:30` define byte-for-byte signing and sidecar shape.
- `scripts/resign-autotune-static.sh:42` pins the current static signing key ID used by the signing helper.

## 8. Research Constraints

The prompt referenced `.omc/logs/context-throughput-sweep-impl-notes.md` and `origin/spike/context-throughput-sweep`. Neither was available in the current repository state during drafting. This SPEC therefore avoids relying on undocumented 28-cell implementation details beyond the research prompt's own description.

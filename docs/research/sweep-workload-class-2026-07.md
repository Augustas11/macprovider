# Sweep Workload-Class Stratification Research Memo

**Date:** 2026-07-09
**Status:** Research memo for SPEC-029 v0.1-draft
**Scope:** Research and SPEC drafting only. No sweep, harness, autotune, runtime, or static-catalog implementation changes.

## Summary

MacProvider already measures buyer-harness behavior by workload name, but the autotune and static-candidate surfaces are still class-blind. The right v0.1 shape is to keep the existing context/concurrency/kv sweep shape and run it as parallel workload-class partitions, producing per-class winners as data. Runtime request classification and class-routed serving should stay out of scope until a later SPEC defines the trust, latency, and API boundary.

The current beta workload library exposes six workload names and maps them to five corpus classes: `short_chat -> short`, `medium_with_system -> medium`, `long_context -> long`, `code_completion -> code`, `agent_style -> agent`, and `streaming_check -> short` (`beta/workloads.py:26`). The report path already groups rows by workload and publishes per-workload medians (`beta/report.py:59`, `beta/report.py:118`). Decision criteria also ask for per-workload median throughput, streaming TTFT, and stop-token leak checks (`beta/DECISION_CRITERIA.md:57`, `beta/DECISION_CRITERIA.md:89`).

Two prompt references were unavailable in the current repository state: `.omc/logs/context-throughput-sweep-impl-notes.md` does not exist, and `origin/spike/context-throughput-sweep` is not a valid ref. Those absences should be treated as research constraints, not inferred evidence.

## A. Search-Space Shape

Use workload class as a partition/filter over the existing grid, not as one global 28 x K optimization with a single winner.

This is operationally equivalent to measuring K copies of the grid, but it keeps the semantics clean:

- Each partition has one winner for one traffic shape.
- Storage can add `workload_class` or `workload_name` to trial/report rows without changing the meaning of existing `runs.workload`.
- Failure gates and tie-breakers can be class-local.
- The implementation can reuse the existing per-workload report posture rather than invent a global compromise winner.

The existing harness schema records `workload`, token counts, TTFT, total latency, throughput, and leak flags, with an index on workload (`beta/harness.py:59`, `beta/harness.py:77`). That is enough evidence that workload is already a first-class reporting dimension. The missing surface is the sweep winner and catalog recommendation layer, not the buyer-harness measurement layer.

The v0.1 sweep should include these content-shape workload names:

- `short_chat`
- `medium_with_system`
- `long_context`
- `code_completion`
- `agent_style`

`streaming_check` should remain a probe/gate workload in v0.1, not a separate serve-knob winner. It maps to the `short` corpus category (`beta/workloads.py:26`) but has `stream=True` and is used to measure streaming TTFT behavior, not a distinct prompt/content family (`beta/workloads.py:231`). It should contribute streaming TTFT gates and report rows, and a later SPEC can promote a TTFT-only serving profile if there is a concrete runtime use for it.

## B. Winner-Picking Under SPEC-028

With speculative decoding, a winner is no longer only a serve-capacity tuple. The candidate profile can include:

```text
(kv_bits, max_context, max_batch, draft_model, num_draft_tokens)
```

`num_draft_tokens` should be per workload class for a given target/draft pair. SPEC-028 makes `num_draft_tokens` a provider serve knob (`specs/SPEC-028-mlx-speculative-decoding.md:63`) and explicitly identifies autotune/candidate-catalog extension points (`specs/SPEC-028-mlx-speculative-decoding.md:31`). It also warns that autotune must not blindly multiply every context/concurrency/kv cell by every draft candidate and shows `draft_candidates[]` with `workload_bias` as an additive static-row extension (`specs/SPEC-028-mlx-speculative-decoding.md:202`, `specs/SPEC-028-mlx-speculative-decoding.md:206`). That points to a staged shape: choose eligible target/draft candidates first, then tune per class.

Acceptance rate is expected to vary by content shape. A shared `num_draft_tokens` would reintroduce the compromise this SPEC is trying to avoid. The safer v0.1 policy is:

- Pick winners independently per class.
- Do not let one class dominate another class's winner.
- If a single legacy default must be exported, derive it from an explicit buyer-traffic weighting policy, not from hidden precedence.

There is no current request-time class classifier in the provider/coordinator path. Therefore v0.1 should publish per-class winners as data and keep runtime serving on the existing single chosen config until a follow-up routing SPEC decides how a buyer request gets a trusted class label.

## C. Static Candidate Shape

Extend the existing `autotune-candidates.json` row shape additively with a per-class profile map. Do not ship a sibling file in v0.1 unless catalog size or consumer separation proves it is needed.

The current static catalog is a signed object with top-level metadata and `rows`; each row carries model identity, RAM/bandwidth eligibility, advisory benchmark gates, runtime status, and notes. The Swift decoder uses a typed `Row` with coding keys for those known fields (`phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift:439`). Swift `Decodable` ignores unknown JSON keys by default when decoding keyed containers, so adding an unknown field to each row is backward-compatible for current consumers.

Recommended additive shape:

```json
{
  "model_id": "example/target",
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

Use `workload_profiles` rather than `per_class` in the normative SPEC because the keys are harness workload names in v0.1, not a general traffic taxonomy. The nested object should avoid the existing top-level `bench_gate` key so SPEC-023's advisory catalog gates are not confused with workload-specific gate policy and measured profile metrics.

The same static feed trust domain should sign the additive catalog. The current public key is baked into the installer recommendation code with key ID `streamvc-autotune-static-v4` (`phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift:684`), and the static-key README describes the single feed trust model and re-signing process (`phase3-binary/dist/static/keys/README.md:32`). A new key would imply a new trust domain; class profiles are still operator-curated candidate recommendations, so reusing the current static key is correct.

## D. Runtime Routing

This SPEC should not introduce runtime request classification.

The workload definitions live in the beta buyer harness (`beta/workloads.py:26`). They are corpus/sample labels, not request-time metadata. SPEC-028 is also explicit that v0.1 does not change buyer API, receipts, settlement, or coordinator routing (`specs/SPEC-028-mlx-speculative-decoding.md:11`, `specs/SPEC-028-mlx-speculative-decoding.md:38`). Introducing a classifier here would cross those boundaries.

If a later SPEC routes by class, the coordinator should own the canonical classification decision or pass a coordinator-derived class label through the request path. Provider-only classification is lower latency but inconsistent and easier to game. A coordinator-side label is more auditable and can be tied to routing policy, but it must be designed without adding a new buyer-visible field unless the API SPEC explicitly allows it.

For v0.1, the output is data:

- Per-workload benchmark rows.
- Per-workload winner recommendations.
- Open routing/classification questions for a follow-up SPEC.

## E. Sweep Artifacts and Gates

Existing sweep reports can stay as-is. Add class-aware reports alongside them.

The beta report already summarizes by workload (`beta/report.py:59`) and renders a per-workload median table (`beta/report.py:134`). That means class-aware report generation can be an additive report mode. Historical class-blind HTML should not be regenerated unless a specific release artifact requires it.

Gates should become class-parameterized where the metric is shape-sensitive:

- `long_context` should have explicit prefill/TTFT tolerance, because long prompt length changes the expected latency envelope.
- `streaming_check` should own streaming TTFT gates and should not choose a separate non-stream serve config in v0.1.
- `code_completion` and `agent_style` should track speculative acceptance rate and output correctness/leak checks more closely, because draft-token benefit depends on structured continuation shape.
- Stop-token leak gates should remain per workload because decision criteria already ask for stop-token leak rate per workload (`beta/DECISION_CRITERIA.md:89`).

SPEC-023 made static-catalog TPS and TTFT fields advisory rather than hard eligibility gates (`specs/SPEC-023-installer-autotune-recommend.md:35`). The class profile should preserve that posture for measured throughput and SPEC-023 top-level `bench_gate` fields, while SPEC-029 should separately serialize the workload-specific hard TTFT/leak gate policy used to choose a sweep winner.

## Recommended Next Step

Adopt SPEC-029 v0.1-draft as a research/specification artifact. Do not implement runtime class-routed serving until maintainers answer the routing/default-profile open questions.

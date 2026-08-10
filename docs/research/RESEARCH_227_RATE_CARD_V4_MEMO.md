# RESEARCH_227 - Rate-card v4 live-run close-out

Date: 2026-08-09

Status: **Components 1 and 2 complete.** Authenticated schema-v5 snapshot and
review-only proposal archived; no live rate card or apply path was changed.

## Executive conclusion

The first authenticated run exposed a real identity collision: the canonical
slug `z-ai/glm-5.2-20260616` maps to both `z-ai/glm-5.2` and
`z-ai/glm-5.2:batch`. The resolver now asks for the exact dated endpoint
document and accepts its ID only when it uniquely names one catalog candidate.
Missing, malformed, or mismatched confirmation still fails closed.

After that repair, a retry reached `tencent/hy3:free`, whose complete endpoint
document contained an exact `data.id` and `data.endpoints: []`. The owner
subsequently approved a narrow contract change based on OpenRouter's documented
HTTP 200 response shape: an authoritative empty provider set may remain as
demand-only evidence after one bounded confirmation request. It receives the
distinct status `no_provider_endpoints`; it must never produce a provider
floor, undercut target, policy addition, or rate proposal. Missing, null,
non-array, mismatched, malformed, or unconfirmed data still fails closed.

The prior snapshot/proposal were removed because they predated the approved
confirmation semantics and schema-v5 provenance. A fresh authenticated top-50
fetch and compute have now regenerated both artifacts. Component 3 remains the
sole apply authority.

## 1. Durable evidence and exact blocker

The archive retains
`openrouter-pricing-fetch-failure-2026-08-09T10-06-40Z.json`, the sanitized
receipt for the original GLM ambiguity. It records the UTC run, ranking window,
engine revision, credential-redacted command, nonzero exit status, sanitized
stderr, empty output inventory, and a self-digest. It is a blocker record, not
a snapshot substitute.

The subsequent generation established the empty-provider condition:

```text
data.id = "tencent/hy3:free"; data.endpoints = []
```

The final authenticated run used engine commit
`0453190e8384ca05d0cb7be0813fbd22e10d2c1f` and the UTC ranking window
2026-07-11 through 2026-08-09. It emitted 50 contiguous ranked rows after 55
successful source requests: rankings, catalog, 50 initial endpoint documents,
and three empty-set confirmations. The confirmed-empty identities are
`tencent/hy3:free`, `inclusionai/ling-3.0-flash:free`, and
`poolside/laguna-m.1:free`.

Committed evidence:

| Purpose | Artifact |
| --- | --- |
| Historical GLM failure | `openrouter-pricing-fetch-failure-2026-08-09T10-06-40Z.json` |
| Final fetch receipt | `openrouter-pricing-fetch-success-2026-08-10T10-05-13Z.json` |
| Final snapshot | `openrouter-pricing-snapshot-2026-08-10T10-05-29Z-34126a58ac6728ec.json` |
| Final compute receipt | `openrouter-pricing-compute-success-2026-08-10T10-06-14Z.json` |
| Final proposal | `openrouter-rate-card-proposal-2026-08-10T10-06-14Z-2a4ef8180e266e37.json` |

The snapshot semantic digest is
`sha256:37a1bef90beafd2cf16e2e3b53ed27bce022f8118151f7b1ecbd14ad2c0069b7`;
the proposal references that exact digest. File checksums and receipt
self-digests are recorded in the receipts. The exact receipt procedure and
canonical digest algorithm are specified in the archive README.

## 2. Resolver repair

For an ambiguous catalog canonical slug, fetch requests
`/api/v1/models/{author}/{dated-slug}/endpoints`, not an inferred regular or
`:batch` ID. The returned `data.id` is accepted only if it exactly and uniquely
matches one candidate. The normalized row then publishes that returned source
ID with `identity_resolution: endpoint_confirmed_catalog_candidate`.

Tests cover the full orchestration boundary: the exact dated request, regular
selection over `:batch`, emitted provenance, missing endpoint failure, ID
mismatch, malformed documents, the existing explicit-`:free` preference, and
dated-alias fallback. The resolver never strips `:batch` or guesses an alias.

## 3. Four current policy rows

Compute used exactly the final snapshot, current policy, and current read-only
rate-card reference. Its summary is `added=0`, `changed=0`, `unchanged=1`,
`dropped=3`, `blocked=55`, and `eligible=1`:

| Policy source model | Cohort result | Current completion rate | Live cheapest completion | Proposal result |
| --- | --- | ---: | ---: | --- |
| `openai/gpt-oss-20b` | Absent | 100000 credits/M | N/A | Dropped for review; no trusted market input in this cohort. |
| `google/gemma-4-26b-a4b-it` | Rank 32 | 240000 credits/M | $0.30/M (Cloudflare) | Unchanged at 240000 credits/M ($0.24/M), the 20% broad-fleet undercut target. |
| `nvidia/nemotron-3-nano-30b-a3b` | Absent | 160000 credits/M | N/A | Dropped for review; no trusted market input in this cohort. |
| `qwen/qwen2.5-coder-32b-instruct` | Absent | 850000 credits/M | N/A | Dropped for review; no trusted market input in this cohort. |

`dropped` is advisory proposal output, not an automatic deletion. No rate-card
row was changed. The other 49 demand rows have no verified policy mapping and
remain visible and blocked; six additional current rate-card rows lack policy
metadata and are also blocked.

## 4. Candidate screen from the validated cohort

The schema-v5 top-50 establishes demand only. It cannot by itself authorize a
policy addition; serving, license, residency, TPS, and paid-market evidence
remain required. No new policy row is proposed from this run.

### Strongest leads

`cohere/north-mini-code:free` (observed rank 42) is the strongest compact
coding lead. Cohere's card identifies Apache-2.0, code/agent specialization,
30B total parameters and 3B active parameters. The MLX Community 4-bit artifact
is approximately 18.5 GB. It is blocked by missing Mac-specific TPS evidence,
a narrow residency/profile decision, and a zero-dollar endpoint that provides
no paid market price to undercut.

```json
{
  "source_model_id": "cohere/north-mini-code:free",
  "canonical_model_id": "cohere/north-mini-code",
  "serving_path": {"verification_status": "verified", "reference": "https://huggingface.co/mlx-community/North-Mini-Code-1.0-4bit"},
  "license": {"commercial_permitted": true, "source_url": "https://huggingface.co/CohereLabs/North-Mini-Code-1.0", "verification_note": "Apache-2.0 model card."},
  "coding_specialist": true,
  "profile": {"kind": "coding_moe_candidate", "active_params_b": "3", "residency_gb": "18.5", "projected_tps": "unverified"},
  "blocking_reasons": ["no verified Mac TPS", "coding residency/profile decision required", "free endpoint has no undercuttable paid price"]
}
```

`poolside/laguna-s-2.1:free` (rank 18) is coding/agent focused and
activates about 8.5B of 117.6B parameters. Poolside's card identifies the
commercially usable OpenMDW-1.1 terms. The official MLX NVFP4 artifact is
currently about 71.9 GB and the card requires 128 GB unified memory; it is far
outside the current 45 GB residency ceiling. Its free endpoint also has no
undercuttable price. The upstream card's Apple Silicon throughput is not a
verified macprovider autotune result.

```json
{
  "source_model_id": "poolside/laguna-s-2.1:free",
  "canonical_model_id": "poolside/laguna-s-2.1",
  "serving_path": {"verification_status": "verified", "reference": "https://huggingface.co/poolside/Laguna-S-2.1-NVFP4-mlx"},
  "license": {"commercial_permitted": true, "source_url": "https://huggingface.co/poolside/Laguna-S-2.1-NVFP4", "verification_note": "OpenMDW-1.1 permits commercial and non-commercial use subject to its terms."},
  "coding_specialist": true,
  "profile": {"kind": "coding_moe_rejected", "active_params_b": "8.5", "residency_gb": "71.9", "projected_tps": "unverified for macprovider"},
  "blocking_reasons": ["residency exceeds 45 GB", "requires 128 GB unified memory", "free endpoint has no undercuttable paid price"]
}
```

`inclusionai/ling-3.0-flash:free` (rank 24) is described by OpenRouter
as a 124B MoE with approximately 5.1B active parameters. The upstream Hugging
Face record at revision `ecde16176a497adaff7419ff4de59da603c4edaa` identifies
MIT. The community MLX 4-bit artifact at revision
`137556d28dd03743cb85ce4bc2652b0710066603` occupies 70,025,342,631 bytes
(approximately 70.0 GB), beyond the 45 GB ceiling. It remains blocked by that
residency, missing Mac TPS evidence, and a free route with no paid price.

```json
{
  "source_model_id": "inclusionai/ling-3.0-flash:free",
  "canonical_model_id": "inclusionai/ling-3.0-flash",
  "serving_path": {"verification_status": "verified", "reference": "https://huggingface.co/Vontra/Ling-3.0-flash-MLX-4bit/tree/137556d28dd03743cb85ce4bc2652b0710066603"},
  "license": {"commercial_permitted": true, "source_url": "https://huggingface.co/inclusionAI/Ling-3.0-flash/tree/ecde16176a497adaff7419ff4de59da603c4edaa", "verification_note": "Pinned upstream Hugging Face metadata identifies MIT."},
  "profile": {"kind": "broad_fleet_moe_rejected", "active_params_b": "5.1", "residency_gb": "70.025", "projected_tps": "unverified"},
  "blocking_reasons": ["residency exceeds 45 GB", "no verified Mac TPS", "free route has no undercuttable paid price"]
}
```

`mistralai/mistral-nemo` (observed rank 43) has an Apache-2.0 base card and a
6.89 GB MLX Community 4-bit artifact. Its roughly 12B dense profile exceeds the
broad-fleet 8B active-parameter gate and there is no verified coding-specialist
profile or Mac TPS result.

```json
{
  "source_model_id": "mistralai/mistral-nemo",
  "canonical_model_id": "mistralai/mistral-nemo",
  "serving_path": {"verification_status": "verified", "reference": "https://huggingface.co/mlx-community/Mistral-Nemo-Instruct-2407-4bit"},
  "license": {"commercial_permitted": true, "source_url": "https://huggingface.co/mistralai/Mistral-Nemo-Instruct-2407", "verification_note": "Apache-2.0 model card."},
  "profile": {"kind": "broad_fleet_rejected", "active_params_b": "approximately 12", "residency_gb": "6.89", "projected_tps": "unverified"},
  "blocking_reasons": ["active parameters exceed broad-fleet 8B gate", "no verified coding-specialist profile", "no verified Mac TPS"]
}
```

### Remaining open-weight and closed rows

The other observed open-weight families (Xiaomi MiMo, DeepSeek V4/V3.2,
Tencent HY, Z-AI GLM, Nemotron Ultra/Super, MiniMax, StepFun, Kimi,
`gpt-oss-120b`, Gemma 31B/26B, and Laguna M) were not policy-ready: they were
obviously oversized for the current broad-fleet gate, lacked a verified local
serving/profile/license chain in this review, were free-only, or some
combination. This is a compact dismissal, not evidence that none can ever
qualify. Each needs the same serving, license, residency, TPS, and paid-market
checks in a valid future cohort.

The remaining Anthropic, Gemini, GPT, Grok, and similar hosted/proprietary rows
have no eligible open-weight local serving path and were dismissed at the
class/openness filter.

### Data-quality finding: free and zero-price rows

Free identity suffixes and zero prices are distinct from an empty endpoint
list. A non-empty, schema-valid active endpoint with a numeric zero price may
be retained as observed market data, but zero cannot produce a positive
undercut target and the row is blocked from rate computation. A complete,
exact-ID empty provider set is retained only after the bounded confirmation
described above, as `no_provider_endpoints`; it is also blocked from pricing.
Missing, malformed, mismatched, or unconfirmed endpoint data still aborts the
entire snapshot generation.

## 5. Existing policy license evidence

- `openai/gpt-oss-20b`: Apache-2.0 model card:
  https://huggingface.co/openai/gpt-oss-20b
- `google/gemma-4-26b-a4b-it`: Gemma 4 card identifies Apache-2.0:
  https://ai.google.dev/gemma/docs/core/model_card_4
- `nvidia/nemotron-3-nano-30b-a3b`: the pinned NVIDIA card identifies the
  **NVIDIA Nemotron Open Model License** and commercial readiness subject to
  its terms:
  https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16/blob/f303f4dd6fc8f7202071617038e9962b26a21c03/README.md
  The non-money-path policy evidence reference now points to this exact pinned
  applicability source; commercial permission was not changed.
- `qwen/qwen2.5-coder-32b-instruct`: Apache-2.0 model card:
  https://huggingface.co/Qwen/Qwen2.5-Coder-32B-Instruct

License permission does not replace serving-path verification, performance
evidence, or downstream legal review.

## 6. Close-out condition and boundary

Artifacts older than 48 hours are stale for pricing review. A future run must
complete authenticated `fetch`, archive its validated snapshot and receipt,
then run `compute` from exactly that snapshot and archive the untouched
proposal and receipt. Any required-source failure ends the chain. This tool has
no apply mode; Component 3 owns bounded-delta review, approval, and every live
rate-card write.

Components 1 and 2 now satisfy the V4 close-out condition: successful approved
fetch, committed snapshot, successful compute, committed proposal, four-row
movement interpretation, validated policy-coverage diff, candidate screen, and
license evidence. This is not an apply decision; Component 3 review remains
mandatory before any money-path change.

## Sources

- OpenRouter daily rankings: https://openrouter.ai/api/v1/datasets/rankings-daily
- OpenRouter catalog: https://openrouter.ai/api/v1/models
- North Mini Code: https://huggingface.co/CohereLabs/North-Mini-Code-1.0
- North Mini Code MLX: https://huggingface.co/mlx-community/North-Mini-Code-1.0-4bit
- Laguna S 2.1: https://huggingface.co/poolside/Laguna-S-2.1-NVFP4
- Laguna S 2.1 MLX: https://huggingface.co/poolside/Laguna-S-2.1-NVFP4-mlx
- Ling 3.0 Flash market identity: https://openrouter.ai/inclusionai/ling-3.0-flash
- Ling 3.0 Flash upstream: https://huggingface.co/inclusionAI/Ling-3.0-flash/tree/ecde16176a497adaff7419ff4de59da603c4edaa
- Ling 3.0 Flash MLX: https://huggingface.co/Vontra/Ling-3.0-flash-MLX-4bit/tree/137556d28dd03743cb85ce4bc2652b0710066603
- Mistral NeMo: https://huggingface.co/mistralai/Mistral-Nemo-Instruct-2407
- Mistral NeMo MLX: https://huggingface.co/mlx-community/Mistral-Nemo-Instruct-2407-4bit
- V3 policy baseline: `docs/research/RESEARCH_227_RATE_CARD_V3_MEMO.md`

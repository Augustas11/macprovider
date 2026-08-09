# RESEARCH_227 - Rate-card v4 live-run record and review handoff

Date: 2026-08-09

Status: Components 1 and 2 complete; review-only proposal emitted; no rate-card
or policy change applied.

## Executive conclusion

The repaired engine completed an authenticated, normalized OpenRouter top-50
fetch and computed a proposal from that exact snapshot and the current policy
and rate-card reference. It does not apply the proposal. Component 3 retains
the decision, guardrail, and write authority for
`phase3-binary/catalog/autotune/rate-card.json`.

The result is not a rate-card edit recommendation by itself. The complete
proposal has one eligible unchanged row and three policy rows dropped because
they are absent from the validated demand cohort. No hand-built price, partial
snapshot, policy edit, or rate-card write was made.

## 1. Durable live-run evidence

The following machine-generated files are committed unchanged under
`docs/research/openrouter-snapshots/`:

| Purpose | Artifact |
| --- | --- |
| Historical fail-closed attempt | `openrouter-pricing-fetch-failure-2026-08-09T10-06-40Z.json` |
| Successful fetch receipt | `openrouter-pricing-fetch-success-2026-08-09T10-21-21Z.json` |
| Validated snapshot | `openrouter-pricing-snapshot-2026-08-09T10-21-21Z-11d59af120144995.json` |
| Successful compute receipt | `openrouter-pricing-compute-success-2026-08-09T10-21-42Z.json` |
| Proposal from that snapshot | `openrouter-rate-card-proposal-2026-08-09T10-21-42Z-a92e86c20cf53c5b.json` |

The successful fetch used the documented daily rankings endpoint for the UTC
window 2026-07-10 through 2026-08-08. It produced 50 distinct ranked models
and 52 successful required source responses (rankings, catalog, and one
endpoint response per ranked model). Its normalized content digest is
`sha256:f8ce23f9e462b08ed8457f48a272664274149d5508c89590425e75f8ac0f0027`.
The success receipts record a credential-redacted command, engine revision,
exit status, output listing, and SHA-256 file checksum. The API credential was
provided only as `OPENROUTER_API_KEY` to the child process and is not recorded.

Compute used exactly that archived snapshot,
`scripts/openrouter_pricing_policy.json`, and the current reference
`phase3-binary/catalog/autotune/rate-card.json`. It emitted proposal summary:
`added=0`, `changed=0`, `unchanged=1`, `dropped=3`, `eligible=1`, and
`blocked=55`.

## 2. Resolver repair and retained historical failure

The first authenticated attempt at 2026-08-09T10:06:40Z failed closed with no
artifact because catalog canonical slug `z-ai/glm-5.2-20260616` mapped to both
`z-ai/glm-5.2` and `z-ai/glm-5.2:batch`. That failure receipt remains useful
historical evidence.

The resolver now requests the endpoint document for the exact dated ranking
permaslug. It accepts the returned endpoint ID only when it exactly and
uniquely matches one of the ambiguous catalog candidates. The live endpoint
returned `z-ai/glm-5.2`, selecting the regular identity. It does not strip or
ignore `:batch`, and an unmatched, missing, or malformed endpoint identity
continues to fail closed. Offline tests cover the regular-versus-`:batch`
success path, a mismatched endpoint ID, a malformed endpoint document, the
existing explicit-`:free` rule, and the existing dated-alias fallback.

During the successful retry, `tencent/hy3:free` returned a schema-valid empty
endpoint list. This is retained as `pricing_status:
no_active_priced_endpoint` and is blocked by compute; it is not treated as a
partial global fetch and no price is invented. Non-list or malformed endpoint
objects still fail closed.

## 3. Proposal interpretation and policy coverage

The current policy defines four source models. Their complete results are:

| Policy source model | Cohort result | Current completion rate | Live cheapest completion price | Proposal result |
| --- | --- | ---: | ---: | --- |
| `openai/gpt-oss-20b` | Absent from top-50 | 100000 credits/M | N/A | Dropped; no trusted live market input in this cohort. |
| `google/gemma-4-26b-a4b-it` | Rank 33 | 240000 credits/M | $0.30/M (Cloudflare) | Eligible and unchanged at 240000 credits/M ($0.24/M), the 20% broad-fleet undercut target. |
| `nvidia/nemotron-3-nano-30b-a3b` | Absent from top-50 | 160000 credits/M | N/A | Dropped; no trusted live market input in this cohort. |
| `qwen/qwen2.5-coder-32b-instruct` | Absent from top-50 | 850000 credits/M | N/A | Dropped; no trusted live market input in this cohort. |

The policy-coverage diff is one policy model present in the complete top-50 and
three policy models absent. The remaining 49 ranked models have no verified
policy mapping and are explicitly blocked rather than silently proposed. The
proposal also reports six existing rate-card rows without policy metadata as
blocked. These are coverage findings for owner review, not instructions to
remove, add, or reprice rows.

## 4. Candidate screening

No new policy row is proposed from this run. A ranked model needs all of the
following before it can enter `scripts/openrouter_pricing_policy.json`: a
verified MLX/GGUF serving path, commercially permissive license evidence, and
a profile that clears the applicable parameter, residency, and TPS gate. The
snapshot proves demand but does not prove the other conditions.

`mistralai/mistral-nemo` is rank 43 and is the nearest fully documented
illustrative candidate, but is not an addition. Its base card is Apache-2.0
and the MLX Community 4-bit serving artifact is 6.89 GB
([base](https://huggingface.co/mistralai/Mistral-Nemo-Instruct-2407),
[MLX](https://huggingface.co/mlx-community/Mistral-Nemo-Instruct-2407-4bit)).
It is a roughly 12B dense model, so it exceeds the broad-fleet 8B active
parameter gate; no verified coding-specialist profile or hardware-specific TPS
derivation is available in this record. Its policy-row-shaped screening record
is intentionally non-admissible:

```json
{
  "source_model_id": "mistralai/mistral-nemo",
  "canonical_model_id": "mistralai/mistral-nemo",
  "serving_path": {
    "verification_status": "verified",
    "reference": "https://huggingface.co/mlx-community/Mistral-Nemo-Instruct-2407-4bit"
  },
  "license": {
    "commercial_permitted": true,
    "source_url": "https://huggingface.co/mistralai/Mistral-Nemo-Instruct-2407",
    "verification_note": "Apache-2.0 base model card."
  },
  "profile": {
    "kind": "not-admissible-broad-fleet",
    "active_params_b": "approximately 12",
    "residency_gb": "6.89",
    "projected_tps": "unverified"
  },
  "blocking_reasons": [
    "broad-fleet active parameters exceed 8B",
    "no verified coding-specialist profile",
    "no hardware-specific projected TPS evidence"
  ]
}
```

This separates a realistic serving/license lead from an admissible policy
addition. It must not be copied into the machine-read policy without completing
the missing profile evidence.

## 5. License confirmations for existing policy rows

- `openai/gpt-oss-20b`: Apache-2.0 model card; commercial use is permitted
  under Apache-2.0. Source: https://huggingface.co/openai/gpt-oss-20b
- `google/gemma-4-26b-a4b-it`: the Gemma 4 model card identifies Apache-2.0.
  Source: https://ai.google.dev/gemma/docs/core/model_card_4
- `nvidia/nemotron-3-nano-30b-a3b`: the governing agreement is the **NVIDIA
  Nemotron Open Model License**, and the pinned NVIDIA model card describes
  commercial readiness subject to those terms. Source:
  https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16/blob/f303f4dd6fc8f7202071617038e9962b26a21c03/README.md
  The current policy still references a generic NVIDIA Open Model License URL;
  that evidence-reference mismatch is owner follow-up, not a policy change in
  this PR.
- `qwen/qwen2.5-coder-32b-instruct`: Apache-2.0 model card; commercial use is
  permitted under Apache-2.0. Source:
  https://huggingface.co/Qwen/Qwen2.5-Coder-32B-Instruct

License permission does not replace serving-path verification, performance
evidence, or legal review of downstream packaging.

## 6. Operational boundary

Artifacts older than 48 hours are stale for a pricing decision. A future
operator run must first complete authenticated `fetch`, archive its validated
snapshot and receipt, then run `compute` from that exact snapshot and archive
its proposal and receipt. A failed fetch ends the chain. This tool has no apply
mode; Component 3 owns bounded-delta review, staleness enforcement, approval,
and any live rate-card write.

## Sources

- OpenRouter daily rankings: https://openrouter.ai/api/v1/datasets/rankings-daily
- OpenRouter catalog: https://openrouter.ai/api/v1/models
- V3 policy and eligibility baseline:
  `docs/research/RESEARCH_227_RATE_CARD_V3_MEMO.md`

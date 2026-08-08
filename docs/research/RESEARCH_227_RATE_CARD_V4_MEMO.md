# RESEARCH_227 - Rate-card v4 research close-out

Date: 2026-08-09

Status: research close-out; no rate-card or policy changes applied

## Executive conclusion

The attempted live OpenRouter refresh produced useful demand evidence but did not
produce a trusted pricing snapshot. The engine failed closed while resolving a
dated ranking identity (notably `z-ai/glm-5.2-20260616`) against the catalog and
endpoint data. This is the correct outcome: no alias was guessed, no market price
was invented, and no proposal was generated from incomplete identity coverage.

The operator-provided top-50 table is therefore treated as **untrusted demand
evidence**, not as a schema-valid snapshot. It supports screening and research
triage only. On the evidence available in this close-out, there are **no new
policy additions ready for proposal**. The only clearly open-weight newcomer with
an MLX path that was independently checked, `mistral/mistral-nemo`, is a dense
12B model and fails the current broad-fleet active-parameter gate; it is not a
coding-specialist policy row either.

The existing four policy records remain supported. In particular,
`nvidia/nemotron-3-nano-30b-a3b` is commercially permitted under the NVIDIA Open
Model License and is **resolved, not blocked**.

## 1. Evidence boundary and attempted live run

No raw rankings response is archived in this repository because the attempt did
not produce a schema-valid engine snapshot. The durable evidence for this
close-out is the authenticated command, its exact fail-closed error, and the
empty output directory recorded below. The engine requires a normalized distinct
top-50 cohort, exact catalog identity coverage, and a complete endpoints
response for every selected model before it publishes a snapshot. Those
conditions were not met.

### Reproduction of the authenticated fetch fail-close

On 2026-08-09 I reran the documented fetch command from the repository with the
operator-provided API key supplied only to the child process environment. The
key is intentionally not recorded here. The run used an isolated temporary
output directory and these parameters:

```text
python scripts/openrouter_pricing_engine.py fetch --output-dir <temporary-dir> \
  --top-n 50 --demand-window-days 30 --retries 3 \
  --timeout-seconds 20 --generation-timeout-seconds 900
```

The authenticated command exited with status `2` and failed closed while
resolving the dated ranking identity:

```text
openrouter pricing engine: catalog response cannot uniquely resolve ranked model 'z-ai/glm-5.2-20260616' to an endpoint model id
```

The temporary output directory contained no artifacts (`ARTIFACTS=[]`), so no
snapshot was published. This directly reproduces the GLM-5.2 failure described
above: the engine refuses to guess an endpoint alias, and the failure prevents
the fetch from proceeding to a publishable normalized snapshot.

### Priced-row movements and proposal status

No live priced-row movement can be reported for any of the four policy models:

| Policy model | Shipped rate versus live proposal | Reason |
| --- | --- | --- |
| `openai/gpt-oss-20b` | Not computed | No validated snapshot was published, so there is no trusted cheapest-active-endpoint input for the undercut formula. |
| `google/gemma-4-26b-a4b-it` | Not computed | Same fail-closed snapshot prerequisite. |
| `nvidia/nemotron-3-nano-30b-a3b` | Not computed | Same fail-closed snapshot prerequisite; its license remains resolved and is not the blocker. |
| `qwen/qwen2.5-coder-32b-instruct` | Not computed | Same fail-closed snapshot prerequisite, including the coding baseline, market cap, and provider-payout floor calculations. |

Accordingly, `compute` was not run and no live proposal artifact exists to
archive. Reporting a numeric movement from raw rankings, a prior proposal, or a
hand-built price would violate the snapshot-digest and endpoint-provenance
contract. The clean hand-back is the exact fetch failure above; after identity
resolution is repaired, rerun `fetch`, then `compute` against that fresh
snapshot and the unchanged policy and rate-card references.

### Fail-closed/data-quality findings

The following separates what the pull actually established from what could not
be established because the run failed closed:

| Requested check | Live-pull result | Operational meaning |
| --- | --- | --- |
| Schema/provenance completeness | No schema-valid normalized snapshot was published. The complete catalog/endpoint contract was not established for the selected cohort. | Treat the run as provenance-incomplete; do not bypass allowlists or manually repair fields. |
| Missing endpoints | Endpoint completeness for every selected model was not established; the run stopped during identity/catalog resolution before a complete endpoint-backed snapshot could be produced. | Do not infer a missing endpoint or price. Re-run `fetch` and retain the failed-run logs. |
| Demand-cohort completeness | Completeness of the required normalized distinct top-50 cohort cannot be claimed after the fetch failure. | Do not construct a replacement snapshot by hand; a successful engine fetch is required before `compute`. |
| Identity resolution | `z-ai/glm-5.2-20260616` could not be safely resolved against the current catalog/endpoint identity. | Fail closed; do not alias it to `z-ai/glm-5-20260211` or another model. |

| Finding | Consequence |
| --- | --- |
| Dated/permaslug identities | A ranking slug can be absent or represented differently in the current catalog. Alias guessing is prohibited. |
| Ambiguous GLM-5.2 resolution | Fetch correctly failed closed rather than mapping it to `z-ai/glm-5` or another identity. |
| Catalog/endpoint coupling | Every selected model needs exact endpoint data; partial coverage cannot become a snapshot. |
| No published snapshot | `compute` must not be run against a hand-edited or reconstructed snapshot. |

## 2. Candidate screening

No candidate can be treated as a newly demanded model until a validated snapshot
exists. Demand alone would not admit a candidate in any event: verified
MLX/GGUF serving evidence, commercial-license evidence, and the current hardware
profile gates remain required.

### Component-2 verification: nearest candidate, not an addition

`mistral/mistral-nemo` has an Apache-2.0 base card and an MLX conversion:

- Base: https://huggingface.co/mistralai/Mistral-Nemo-Instruct-2407
- MLX: https://huggingface.co/mlx-community/Mistral-Nemo-Instruct-2407-4bit
- OpenRouter identity: https://openrouter.ai/mistralai/mistral-nemo

The HF metadata reports approximately 12.25B base-model parameters and an MLX
artifact of approximately 1.91 GB. The model is dense, so active parameters are
approximately 12B. A rough bandwidth-bound estimate is about 8-12 TPS on an
M-base-class system and 25-35 TPS on M-Max-class hardware, before runtime and
context overhead. It therefore exceeds the broad-fleet ≤8B active-parameter
gate, and it is not marked as a coding specialist. It is a blocked near-miss,
not a proposed policy addition.

### Proposed policy additions

```json
[]
```

This empty proposal is intentional. The live fetch did not satisfy the evidence
contract, and no newcomer passed all serving-path, license, hardware, demand,
and commercial-pricing gates without inference. Re-run `fetch` successfully
before considering any addition.

## 3. Existing policy license confirmations

- `openai/gpt-oss-20b`: Apache-2.0 on the model card; commercial use is allowed
  under Apache-2.0 obligations. Source: https://huggingface.co/openai/gpt-oss-20b
- `google/gemma-4-26b-a4b-it`: the Gemma 4 model card identifies Apache-2.0;
  commercial use remains permitted subject to that license and Google’s stated
  terms. Source: https://ai.google.dev/gemma/docs/core/model_card_4
- `nvidia/nemotron-3-nano-30b-a3b`: commercially permitted under the NVIDIA Open
  Model License, subject to its conditions. **Resolved; not blocked.** Source:
  https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/
- `qwen/qwen2.5-coder-32b-instruct`: Apache-2.0 on the model card; commercial
  use is allowed under Apache-2.0 obligations. Source:
  https://huggingface.co/Qwen/Qwen2.5-Coder-32B-Instruct

License permission does not replace serving-path verification, performance
benchmarks, or legal review of downstream packaging.

## 4. V4 decision and next action

Keep the current policy unchanged. Do not modify
`phase3-binary/catalog/autotune/rate-card.json`. Repair or clarify the OpenRouter
dated-model/catalog/endpoint identity contract, then run a fresh authenticated
`fetch`. Only a successfully validated snapshot should be passed to `compute`.

## Sources

- OpenRouter daily rankings: https://openrouter.ai/api/v1/datasets/rankings-daily
- OpenRouter catalog: https://openrouter.ai/api/v1/models
- V3 baseline and prior eligibility research:
  `docs/research/RESEARCH_227_RATE_CARD_V3_MEMO.md`

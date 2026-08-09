# RESEARCH_227 - Rate-card v4 failed-run hand-back and blocker record

Date: 2026-08-09

Status: blocked failed-run hand-back; no rate-card or policy changes applied

## Executive conclusion

The attempted live OpenRouter refresh did not produce a trusted pricing
snapshot. The engine failed closed while resolving a dated ranking identity
against the catalog and endpoint data. This is the correct outcome: no alias was
guessed, no market price was invented, and no proposal was generated from
incomplete identity coverage.

This is not an operational rate-card close-out. RESEARCH_227 remains blocked
until the identity issue is repaired and a successful authenticated `fetch` then
`compute` run produces a validated snapshot, proposal, priced-row movements,
and candidate-coverage diff. Candidate additions are blocked pending that
validated demand cohort. Existing policy license evidence is recorded below only
as confirmation of the pre-existing policy, not as a policy update.

## 1. Evidence boundary and attempted live run

No raw rankings response is archived in this repository because the attempt did
not produce a schema-valid engine snapshot. The durable evidence is the
credential-redacted machine-generated receipt at
`docs/research/openrouter-snapshots/openrouter-pricing-fetch-failure-2026-08-09T10-06-40Z.json`.
The engine requires a normalized distinct top-50 cohort, exact catalog identity
coverage, and a complete endpoints response for every selected model before it
publishes a snapshot. Those conditions were not met.

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
snapshot was published.

### Concrete GLM-5.2 resolver collision

The current catalog maps canonical slug `z-ai/glm-5.2-20260616` to both
`z-ai/glm-5.2` and `z-ai/glm-5.2:batch`. The dated endpoint resolves to the
regular `z-ai/glm-5.2` identity. The resolver has a deliberately narrow rule
for preferring the regular paid identity over an explicit `:free` variant, but
it has no corresponding regular-versus-`:batch` rule. Both catalog candidates
therefore remain valid and the resolver correctly fails closed rather than
guessing.

The follow-up blocker is an owner-reviewed resolver repair with fixtures/tests
covering this regular-versus-`:batch` canonical-slug collision. This hand-back
does not implement that rule, alter the policy, or manufacture a snapshot.

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
| Identity resolution | `z-ai/glm-5.2` and `z-ai/glm-5.2:batch` share canonical slug `z-ai/glm-5.2-20260616`; the resolver has no approved regular-versus-`:batch` rule. | Fail closed; add an owner-reviewed resolver rule and fixture before rerunning. |

| Finding | Consequence |
| --- | --- |
| Dated/permaslug identities | A ranking slug can be absent or represented differently in the current catalog. Alias guessing is prohibited. |
| GLM-5.2 regular-versus-`:batch` collision | Fetch correctly failed closed rather than guessing which shared-canonical catalog identity to use. |
| Catalog/endpoint coupling | Every selected model needs exact endpoint data; partial coverage cannot become a snapshot. |
| No published snapshot | `compute` must not be run against a hand-edited or reconstructed snapshot. |

## 2. Candidate screening

No candidate can be treated as newly demanded until a validated snapshot exists.
Demand alone would not admit a candidate in any event: verified
MLX/GGUF serving evidence, commercial-license evidence, and the current hardware
profile gates remain required.

### Component-2 verification: nearest candidate, not an addition

This is illustrative offline research only, not a demand-backed candidate
addition. `mistralai/mistral-nemo` has an Apache-2.0 base card and an MLX
conversion:

- Base: https://huggingface.co/mistralai/Mistral-Nemo-Instruct-2407
- MLX: https://huggingface.co/mlx-community/Mistral-Nemo-Instruct-2407-4bit
- OpenRouter identity: https://openrouter.ai/mistralai/mistral-nemo

The base model is approximately 12.25B parameters and the MLX Community 4-bit
repository reports a 6.89 GB artifact. The model is dense, so active parameters
are approximately 12B. No verified throughput benchmark or hardware-specific
derivation is recorded here; TPS is therefore not asserted. It already exceeds
the broad-fleet ≤8B active-parameter gate and is not marked as a coding
specialist. It is illustrative blocked research, not a proposed policy addition.

### Proposed policy additions

```json
[]
```

This empty proposal is intentional. The live fetch did not satisfy the evidence
contract, so no demand-backed candidate-coverage diff or policy addition can be
proposed. Re-run `fetch` successfully before considering any addition.

## 3. Existing policy license confirmations

- `openai/gpt-oss-20b`: Apache-2.0 on the model card; commercial use is allowed
  under Apache-2.0 obligations. Source: https://huggingface.co/openai/gpt-oss-20b
- `google/gemma-4-26b-a4b-it`: the Gemma 4 model card identifies Apache-2.0;
  commercial use remains permitted subject to that license and Google’s stated
  terms. Source: https://ai.google.dev/gemma/docs/core/model_card_4
- `nvidia/nemotron-3-nano-30b-a3b`: the NVIDIA Nemotron 3 model card identifies
  the governing agreement as the **NVIDIA Nemotron Open Model License** and
  describes the model as ready for commercial use, subject to those terms.
  **Resolved; not blocked.** Source: https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16/blob/f303f4dd6fc8f7202071617038e9962b26a21c03/README.md
  The pre-existing policy references a generic NVIDIA Open Model License URL;
  that evidence-reference mismatch is for owner follow-up and is not changed in
  this PR.
- `qwen/qwen2.5-coder-32b-instruct`: Apache-2.0 on the model card; commercial
  use is allowed under Apache-2.0 obligations. Source:
  https://huggingface.co/Qwen/Qwen2.5-Coder-32B-Instruct

License permission does not replace serving-path verification, performance
benchmarks, or legal review of downstream packaging.

## 4. Blocker and next action

Keep the current policy unchanged. Do not modify
`phase3-binary/catalog/autotune/rate-card.json`. Repair or clarify the OpenRouter
dated-model/catalog/endpoint identity contract, add the resolver fixture/test,
then run a fresh authenticated `fetch`. Only a successfully validated snapshot
should be passed to `compute`. RESEARCH_227 is not closed by this failed run.

## Sources

- OpenRouter daily rankings: https://openrouter.ai/api/v1/datasets/rankings-daily
- OpenRouter catalog: https://openrouter.ai/api/v1/models
- V3 baseline and prior eligibility research:
  `docs/research/RESEARCH_227_RATE_CARD_V3_MEMO.md`

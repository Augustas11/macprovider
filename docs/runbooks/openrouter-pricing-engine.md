# OpenRouter pricing proposal engine

## Safety boundary

This is a non-money-path operator tool. It writes only snapshots and proposals
to the `--output-dir` selected by the operator. It cannot apply a proposal and
does not modify `phase3-binary/catalog/autotune/rate-card.json`. Component 3
owns rate-card guardrails, review, and applying any accepted proposal.

## Commands

```bash
python3 scripts/openrouter_pricing_engine.py fetch \
  --output-dir /var/tmp/openrouter-pricing \
  --top-n 50 --demand-window-days 30 --retries 3 \
  --timeout-seconds 20 --generation-timeout-seconds 900

python3 scripts/openrouter_pricing_engine.py compute \
  --snapshot /var/tmp/openrouter-pricing/openrouter-pricing-snapshot-<timestamp>.json \
  --policy scripts/openrouter_pricing_policy.json \
  --rate-card phase3-binary/catalog/autotune/rate-card.json \
  --output-dir /var/tmp/openrouter-pricing
```

The commands are noninteractive and have useful exit codes, so an operator can
schedule `fetch` and then `compute` externally. Do not schedule an apply step:
there is intentionally no apply mode in this tool.

## Refresh and archive operations

Run the workflow once per day after the UTC ranking window closes. Archive
successful outputs under `docs/research/openrouter-snapshots/`; its README
defines the durable artifact contract. Retain timestamped snapshots and
proposals such as `openrouter-pricing-snapshot-<YYYYMMDDTHHMMSSZ>.json` and
`openrouter-rate-card-proposal-<YYYYMMDDTHHMMSSZ>-<digest8>.json`. Preserve
each artifact's content digest and review notes; never hand-edit an artifact.

Treat artifacts older than 48 hours as stale for a pricing decision. A stale
artifact may be used for historical research, but must not be promoted or used
as the current market basis without a successful refresh. An unattended job may
run `fetch` and, only after a successful validated snapshot, `compute`; persist
stdout, stderr, and exit status separately. A failed-closed fetch stops the
chain, emits no snapshot, and must not be followed by compute against raw,
partial, or manually repaired data. There is no unattended apply step.

## Sources and normalization

The fetcher uses documented OpenRouter API endpoints:

- demand: `https://openrouter.ai/api/v1/datasets/rankings-daily`;
- catalog/schema cross-check: `https://openrouter.ai/api/v1/models`;
- cheapest active provider price:
  `https://openrouter.ai/api/v1/models/{model-id}/endpoints`.

The documented daily dataset contains each day's top 50 public models by total
token usage plus an aggregated `other` row. The fetcher requests a bounded
UTC window (30 days by default), discards `other`, aggregates `total_tokens` by
`model_permaslug`, and selects the requested cohort of up to 50 observed
models. It does not claim to construct a global top-100 ranking, nor does it
infer demand from catalog/pricing data. A changed schema, unavailable response,
or insufficient daily-ranking cohort fails closed and emits no snapshot.

## Authentication

Set `OPENROUTER_API_KEY` in the environment before running `fetch` to send the
documented `Authorization: Bearer <token>` header to OpenRouter. An environment
variable keeps the credential out of shell history, command-line process
arguments, snapshots, proposals, and error output. It is required: the
documented rankings, models, and endpoints APIs require bearer authentication.
A missing key or failed request publishes nothing.

Daily ranking records are aggregated by `model_permaslug`, sorted by total-token
volume, and reduced to the requested number of distinct models. Each selected
model must appear in the catalog and have a complete endpoints response. The
normalizer chooses the lowest completion price among active (`status == 0`)
provider endpoints, breaking ties deterministically by prompt price and
provider name. Decimal strings—not binary floats—are used for stored money and
all calculations.

The snapshot schema is version `4`:

```json
{
  "schema_version": 4,
  "snapshot_type": "openrouter-pricing",
  "fetched_at": "2026-08-05T12:00:00Z",
  "content_digest": "sha256:<normalized-content-hash>",
  "source": {
    "rankings_url": "...",
    "pricing_url_or_urls": ["..."],
    "observed_schema_version_or_fingerprint": "...",
    "generator_version": "openrouter-pricing-engine-v1",
    "fetch_metadata": {
      "successful_source_count": 102,
      "observed_model_count": 50,
      "requested_top_n": 50,
      "demand_window_days": 30,
      "ranking_window_start_date": "2026-07-06",
      "ranking_window_end_date": "2026-08-04",
      "demand_metric": "aggregated_daily_total_tokens"
    }
  },
  "rows": [
    {
      "source_model_id": "provider/model",
      "canonical_model_id": "macprovider-model-key-or-source-id",
      "mapping_status": "exact|alias|unmapped",
      "demand": {
        "source_model_id": "provider/model",
        "rank": 1,
        "total_token_volume": "123",
        "ranking_date": "...",
        "ranking_model_permaslug": "provider/model"
      },
      "pricing": {
        "input_per_token": "0.00000003",
        "completion_per_token": "0.00000013",
        "input_per_mtok": "0.03",
        "completion_per_mtok": "0.13",
        "currency": "USD",
        "benchmark_provider": "CoreWeave"
      },
      "pricing_status": "active_priced",
      "source_metadata": {
        "ranking_model_permaslug": "provider/model",
        "catalog_canonical_slug": "provider/model",
        "catalog_name": "Provider: Model",
        "identity_resolution": "catalog|catalog_paid_variant|endpoint_alias_fallback"
      }
    }
  ]
}
```

`content_digest` is the SHA-256 of canonical JSON for the normalized semantic
payload, excluding operational `fetched_at` and the digest field itself. It is
not a content-addressable storage requirement; it is provenance and replay
evidence. The source schema field is a SHA-256 fingerprint of the explicit
allowlists for the rankings, catalog, endpoint, and pricing objects.

If a dated ranking model is no longer present in the catalog, the engine may
use the endpoint response for that exact dated ID only when OpenRouter returns
a valid current model ID. The snapshot records this as
`endpoint_alias_fallback` and leaves catalog-only metadata `null`; it never
guesses an alias from the model name.

An endpoint response that succeeds but has no active priced provider is retained
with `pricing_status: "no_active_priced_endpoint"` and `pricing: null`. This is
not treated as a partial fetch; Component 2 blocks that model rather than
inventing a market price.

## Fail-closed behavior

The command emits no final snapshot if any required fetch, validation,
normalization, or coverage step fails. It rejects bounded-retry exhaustion for
429/5xx/transport errors, malformed JSON, changed required schemas, missing
keys, empty ranking/catalog/endpoints results, blank identities, invalid or
negative pricing, duplicate normalized identities, and missing endpoint data
for a selected ranked model. A fully prepared file is atomically renamed only
after validation and digest calculation.

The source envelopes and fields used by normalization have explicit allowlists.
An unexpected field, required-field change, or type change fails closed rather
than being ignored or guessed.

`--timeout-seconds` is a finite, 1-60 second socket and wall-clock deadline
for each request. `--generation-timeout-seconds` is a finite 1-3600 second
deadline for the full fetch, including endpoint calls and retry backoff. A
`Retry-After` value is parsed in either seconds or HTTP-date form and is never
shortened: if waiting would pass the generation deadline, the run fails closed.

## Policy and eligibility

`scripts/openrouter_pricing_policy.json` is explicit and reviewable. It holds
data that OpenRouter cannot safely establish: canonical mappings, verified
Apple-Silicon serving paths, license evidence, active parameter count, 4-bit
residency, and projected TPS. Unknown snapshot models remain visible as
`blocked`; they are never inferred into a Macprovider identity.

Candidates must be in a complete snapshot covering the mandatory documented
daily top-50 demand cohort (aggregated total tokens over the fetch window), have a
verified MLX/MLX-Swift/production GGUF-Metal path, and have a commercially
permitted license. Broad-fleet models require active parameters at or below
8B, 4-bit residency at or below 18 GB, and projected M-base TPS of at least 30. Coding-dense rows require a coding-specialist flag, residency at or below
45 GB, and projected M-Max TPS of at least 20.

The policy's target rules are from `RESEARCH_227_RATE_CARD_V3_PROMPT.md`:

- broad-fleet target = cheapest active OpenRouter completion price less the
  configured 10–30% undercut;
- coding-dense target starts from the configured 10–30% premium over a
  general-purpose baseline, is capped to undercut market by at least 10%, and
  must produce at least $0.10/hour at its documented M-Max TPS.

The internal proposal rate is a completion-token rate in the existing
rate-card's integer `completion_rate_per_mtok` encoding. It is derived from
the reference row's `global_multiplier_ppm`, `provider_share_bps`, and the
rate-card `usd_per_million_credits` conversion; it is not hard-coded to a
one-to-one USD/credit assumption. Coding-dense's $0.10/hour floor uses the
resulting provider net payout after that row's share. The proposal records the
economics basis it used. It does not construct or write a live rate-card row;
Component 3 owns that conversion/review boundary.

### Nemotron-3

The policy records `nvidia/nemotron-3-nano-30b-a3b` as commercially permitted
under the [NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/).
NVIDIA states that models under that agreement are commercially usable, subject
to its terms. This is a policy evidence record, not a replacement for legal
review. If the policy's verification is removed or changed to non-permitted,
the engine deterministically blocks/drops the model and records the reason.

## Proposal contract

The proposal schema is version `1` and contains:

- source snapshot digest, policy version, and rate-card reference digest;
- summary counts;
- `added`, `changed`, `dropped`, `blocked`, and `unchanged` arrays;
- per-row demand/market inputs (or explicit `null` values when market data is
  unavailable), eligibility reasons, policy-evidence availability and URLs,
  and a computed completion-rate proposal where eligible.

`dropped` is strictly an advisory request for Component 3 review. It does not
remove a rate-card row. Every dropped row includes its current completion rate.
`blocked` records missing policy evidence, an unresolved license, failed
eligibility, free-only market pricing, missing economics, or an existing
rate-card row with no verified policy mapping.

## Offline verification

Fixtures under `scripts/tests/fixtures/openrouter_pricing/` are offline response
fixtures. `recorded-rankings-response-excerpt.json` is a provenance-labelled,
redacted documented-API response excerpt. The remaining small fixtures
are deterministic response-shape fixtures. None contains credentials or headers.

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts/tests/test_openrouter_pricing_engine.py
```

The suite covers valid normalization/digest behavior, 429 retry and exhaustion,
transport failure, malformed/empty/schema-drifted input, partial endpoints,
invalid pricing, duplicate canonical mappings, snapshot tampering, proposal
categories, unresolved Nemotron licensing, atomic write failure, and
rate-card-reference immutability.

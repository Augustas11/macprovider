# SPEC-044 - Malibu Model Catalog Economics

**Version:** 0.2.10

```json
{
  "spec_id": "SPEC-044",
  "title": "Malibu Model Catalog Economics",
  "version": "0.2.10",
  "path": "specs/SPEC-044-malibu-model-catalog-economics.md",
  "status": "draft",
  "owner": "@Augustas11",
  "authority_domains": ["malibu-model-economics-ux"],
  "supersedes": [],
  "depends_on": [
    "SPEC-001",
    "SPEC-005",
    "SPEC-010",
    "SPEC-011",
    "SPEC-013",
    "SPEC-020",
    "SPEC-023",
    "SPEC-025",
    "SPEC-032",
    "SPEC-033",
    "SPEC-046",
    "SPEC-047"
  ],
  "implementation_status": "pending-reconciliation",
  "production_status": "not-deployed",
  "last_reconciled_commit": null,
  "last_reconciled_at": null,
  "evidence": [],
  "requirement_id_migration": "complete",
  "gap": {
    "verdict": "DECISION_REQUIRED",
    "owner": "@Augustas11",
    "issue": "https://github.com/Augustas11/macprovider/issues/614",
    "rationale": "The operator-owned v0.2.10 authority retains the accepted Build 1 decisions and reconciles the reserved, unreachable v0.2 coordinator offer_rejected state with fail-closed local preparation and economics projection. Implementation, complete tests, signed release evidence, and the discovery/admission/settlement journeys remain pending."
  }
}
```

## 1. Purpose and scope

SPEC-044 defines the next Malibu provider-facing network economics experience: a native Mac app view that helps a provider understand which network-eligible models their machine can serve, what the signed catalog currently pays per token, which choices are locally ready, and which catalog choices need preparation before they can be safely served.

The user outcome is simple: a provider should not be trapped behind the single model selected during `macprovider-cli` install. Malibu should make better model choices legible, explain the economic upside in rate-card terms, and route every action through the installed CLI's signed, versioned transactions.

This spec is required because network-eligible model choice now crosses product UX, signed model catalog identity, autotune recommendation, rate-card projection, warm-swap safety, and money-facing copy. A static UI can be app-local; a multi-model economics UI is a release contract.

SPEC-044 is not the full model universe for Malibu. Provider-local bring-your-own-model discovery is owned by SPEC-046, and promotion from discovered candidate to network-admission state is owned by SPEC-047. SPEC-044 applies only when Malibu presents network eligibility, signed catalog economics, or actions that depend on those states.

One narrow local action is also in scope: a candidate whose signed catalog
artifact identity is current may be prepared into CLI-owned durable local
storage before it is offered or admitted. That action is local custody only;
it does not turn a discovered candidate into a network row or confer identity,
pricing, routing, settlement, or earning authority.

### Explicit non-goals

SPEC-044 does not create an open third-party model marketplace and does not own provider-local model discovery. Models shown with trusted catalog economics or network-dependent actions must still come from a network-eligible admission state and, when economics are shown, from the MacProvider-owned signed catalog/rate-card trust path. The v0.2 locally motivated `prepare_model` exception may consume a current signed catalog artifact binding solely to establish durable local readiness under R002/R003; it is not a network-dependent action.

SPEC-044 does not redefine billing rates, buyer pricing, provider payout formulas, settlement, or token accounting. SPEC-005 remains authoritative for billing formulas, routing price inputs, provider payout math, settlement economics, and rate-card calculation.

SPEC-044 does not authorize Malibu to download arbitrary weights, verify public feed signatures independently, mutate provider configuration directly, register a provider identity, store secrets, or bypass CLI-owned update/rollback/admission gates.

SPEC-044 does not promise revenue. The UI may show catalog rates, provider share, and relative network demand labels, but it must not show guaranteed hourly, daily, weekly, or monthly earnings.

## 2. Dependencies and authority

SPEC-044 owns `malibu-model-economics-ux`: the Malibu-facing presentation and local action contract for catalog model economics, readiness, trust warnings, copy restrictions, and model-selection affordances.

SPEC-001 owns provider wire-protocol compatibility and CLI/app control-surface boundaries. SPEC-044 consumes those boundaries through capability negotiation and versioned local projection calls.

SPEC-010 owns model catalog identity. SPEC-044 may reference model identifiers, supported model keys, and local artifact readiness, but it must not redefine catalog admission or supported-model identity.

SPEC-013 and SPEC-023 own autotune recommendation policy and installer-integrated initial model selection. SPEC-044 consumes recommendation output for ranking and preparation guidance without replacing the CLI's recommendation engine.

SPEC-005 owns billing formulas, rate math, provider reward calculation, and settlement economics. SPEC-044 consumes only the CLI's sanitized projection of SPEC-005 economics and may add provider-friendly labels within the copy constraints below. SPEC-044 does not consume the buyer API error contract or define any buyer-facing gateway surface.

SPEC-011 owns operator-pushed warm swap. SPEC-044 may expose a local switch action only when the CLI reports a warm-swap-safe transaction for a specific catalog model.

SPEC-020 and SPEC-025 own provider release/update authority and Malibu app lifecycle. SPEC-044 requires capability negotiation so old CLIs keep the current static model-switcher behavior rather than receiving unsupported calls.

SPEC-032 and SPEC-033 own hardware evidence and verifier boundaries. SPEC-044 consumes fit and eligibility states produced by those owner specs and must not infer trust from app-observed hardware alone.

SPEC-046 owns provider-local BYOM discovery and evaluation. SPEC-044 may display discovery or evaluation state only as a non-economics local-readiness signal when a later Malibu app version consumes the SPEC-046 CLI projection; it must not convert a discovered candidate into a network row.

SPEC-047 owns network model admission. SPEC-044 may present economics only for rows whose SPEC-047 admission state and owner-spec trust inputs permit signed catalog economics; it must hide economics for `local_only`, `not_offered`, `offerable`, `offer_submitted`, `offer_rejected`, `sandbox_probe_only`, `network_visible_unpriced`, `network_admitted_unsettled`, `withdrawn`, or `revoked` states.

## 3. Normative requirements

**SPEC-044-R001 - CLI-owned economics projection.** Malibu MUST obtain model economics, network readiness, trust state, and actions from an installed, signed `malibu-cli` projection. Catalog-economics generation negotiation has separate command-schema-manifest and flat-local-status grammars. For v1, the generation trio is selection capability `model_catalog_economics_v1`, command token `models catalog-economics.v1`, and required same-generation projection-schema companion `model_catalog_economics.v1`; v2 uses `model_catalog_economics_v2`, `models catalog-economics.v2`, and `model_catalog_economics.v2` respectively. The companion is required compatibility evidence and MUST NOT select a generation by itself.

In the manifest, a supported generation MUST have its own tier keyed byte-for-byte by that generation's selection capability. That tier MUST place the generation's selection capability in `local_status_capabilities` and its command token and schema companion in `command_schemas`; none of those three values may occur in another category. The tier MUST retain every other prerequisite required by the applicable manifest version. A new manifest MAY carry separate complete v1 and v2 tiers so one app build remains compatible with either installed CLI generation; those separate declarations are not a dual-generation CLI advertisement. Within one tier, a missing trio member, a wrong tier key, a value from both generations, a generation value in the wrong category, or any unrecognized generation-namespace value is malformed.

Fresh local status is one flat capability set. Among generation-namespace values it MUST contain exactly all three values for one generation and no value for the other generation. The generation-selection namespaces are closed to strings beginning `model_catalog_economics_v`, `models catalog-economics.v`, or `model_catalog_economics.v`; any value beginning one of those prefixes that is not one of the six exact v1/v2 values is unrecognized and malformed. Unrelated existing capability or schema values outside those three namespaces MUST NOT affect catalog-economics generation selection. Malibu selects v1 or v2 only when the flat status trio is exact, a complete correctly categorized manifest tier for that same generation exists, and the status evidence is fresh. Missing trio members, mixed or dual generations in flat status or within a tier, category misplacement, unrecognized generation-namespace values, stale status, a missing matching manifest tier, or any other manifest/status generation disagreement MUST silently show only the existing static current-model card, with no error indicator, no retry affordance, and no catalog-economics read, run, or cancel call.

The checked-in v1 manifest and current v1 flat status are conforming because the manifest places `model_catalog_economics_v1` in `local_status_capabilities`, places `models catalog-economics.v1` and `model_catalog_economics.v1` in `command_schemas`, and status carries that exact trio alongside unrelated values. A new Malibu manifest retaining a complete v1 tier selects v1 with the current old CLI. The current v1-only Malibu manifest paired with a v2-only CLI falls back without a call. A new Malibu manifest with a complete v2 tier selects v2 only with the exact v2 flat-status trio. Only after one valid generation trio is selected may a projection request be launched. If that request fails, times out, or returns a malformed envelope, Malibu MUST show the static current-model card with exact English source warning **model catalog unavailable**, warning code `projection_unavailable`, and a retry affordance, while exposing no catalog action or economics. A v1-only client MUST retain its existing fallback and MUST NOT invoke v2 run/cancel forms; a v2-serving CLI MUST NOT send a v2 envelope to a client that did not negotiate the exact v2 trio. Malibu MUST NOT fetch coordinator rate feeds, parse static feed files, verify feed signatures, compute billing rates from raw feed bytes, derive action eligibility from app-local heuristics, or present a SPEC-046 discovered candidate as a network economics row unless SPEC-047 admission state permits that presentation. Locally motivated preparation under R002/R003 is permitted only as a non-economics local-readiness action and MUST preserve the candidate's authoritative admission and earning disclosures.

**SPEC-044-R002 - Versioned row schema.** The CLI projection MUST emit a closed, versioned JSON envelope with `schema: "model_catalog_economics.v1"`, a wall-clock RFC3339 `generated_at`, a monotonic unsigned integer `projection_sequence`, a `source` object identifying the CLI build and feed provenance, an array of rows, and a projection-level `warnings` array. The v1 `source` object MUST include `cli_version`, `cli_build_commit`, `process_launch_id`, `process_started_at`, `projection_protocol_version`, `rate_card_source`, nullable `rate_card_digest`, nullable `rate_card_signature_digest`, nullable `demand_feed_digest`, nullable `candidate_feed_digest`, and `rate_card_max_age_seconds`; `process_launch_id` MUST be a lowercase hyphen-separated UUID v4 string generated fresh on CLI process start from at least 128 bits of CSPRNG entropy and MUST NOT be derivable from a PID, host serial, MAC address, host UUID, provider id, wallet, username, or any other hardware or identity value. `source.rate_card_source` MUST use the same closed enum as row `rate_source`: `live_signed`, `static_signed`, or `none`. `projection_sequence` MUST increase within a single CLI process for each newly generated projection and MAY reset after CLI restart; callers MUST use it only to order projections that have the same `source.process_launch_id`. When Malibu observes a new `source.process_launch_id`, it MUST treat the projection as a new CLI session, reset its ordering baseline, discard older in-flight projection ordering comparisons, and show a brief reconnecting or refreshing state before rendering the new projection. Each row MUST include model identity (`model_key`, `served_model_id`, `display_model_id`, nullable `action_model_id`), local state (`is_current`, `weights_present_locally`, `runtime_state`, nullable `estimated_gb`, `fit`, nullable `disabled_reason`, `warning_codes`), admission state (`admission`), economics (nullable `rate_card_version`, nullable `rate_card_generated_at`, nullable `rate_card_key`, `rate_source`, nullable `prompt_rate_usd_per_million_tokens`, nullable `completion_rate_usd_per_million_tokens`, nullable `provider_share_bps`, nullable `provider_prompt_payout_usd_per_million_tokens`, nullable `provider_completion_payout_usd_per_million_tokens`, `economics_state`), demand signals (nullable `demand_rank`, nullable `demand_weight`, nullable `ready_provider_count`, nullable `supply_deficit_score`), and actions (`switch`, `prepare`, `evaluate`, `adopt_recommendation`, `cleanup_staging`) as explicit objects with `available`, `requires_confirmation`, nullable `transaction_kind`, nullable `transaction_id`, nullable `action_timeout_seconds`, nullable `estimated_bytes`, and nullable `unavailable_reason`. The row `admission` object MUST include `state`, `source`, nullable `coordinator_event_id`, nullable `state_observed_at`, `catalog_economics_permitted`, and `settlement_capable`; `source` is `local_default` or `coordinator`, `state` MUST use the SPEC-046/SPEC-047 admission-state enum, `source: "local_default"` permits only `local_only`, `not_offered`, or `offerable` and MUST set `catalog_economics_permitted: false` and `settlement_capable: false`, `source: "coordinator"` permits only SPEC-047 coordinator states, `catalog_economics_permitted` MAY be true only when `source: "coordinator"` and `state` is `catalog_priced` or `settlement_capable`, and `settlement_capable` MAY be true only when `source: "coordinator"` and `state` is `settlement_capable`. Rows whose `admission` object is missing, malformed, stale relative to the signed rate-card evidence, or inconsistent with SPEC-047 MUST set `economics_state` to `blocked` or `unavailable`, null all money-facing payout fields, and make money-motivated actions unavailable. Row `warning_codes` MUST be an array of closed warning-code enum values that apply to that specific row; the top-level `warnings` array applies to the projection as a whole. `economics_state: "trusted"` MUST include non-null rate-card identity, provider-share, and prompt/completion catalog and payout fields, and MUST require `admission.catalog_economics_permitted: true`; Malibu MUST NOT render earning-eligible, settlement-ready, or paid-routing copy unless `admission.settlement_capable: true`. Rows with `rate_source: "none"` or `economics_state: "unavailable"` MUST set rate-card identity and all rate/payout numeric fields to null rather than placeholder zero values. Rows with `economics_state: "blocked"` MUST set money-facing rate/payout fields to null unless the CLI can still identify a verified signed rate card while blocking actions for a non-rate reason; Malibu MUST hide economics copy for blocked rows unless `economics_state` is `trusted`. Rows with `economics_state: "fallback"` or `"stale"` MAY include the signed/static/stale rate fields only as disabled warning context and MUST NOT render them as actionable trusted economics. For an available action, `transaction_kind`, `transaction_id`, and `action_timeout_seconds` MUST be non-null; `action_timeout_seconds` MUST be greater than zero and MUST NOT exceed 1800 seconds. For available `switch_model`, `prepare_model`, `switch_model_deferred`, `cleanup_staging`, `adopt_recommendation`, and any `evaluate_model` action with non-null `estimated_bytes` or `action_timeout_seconds` greater than 10 seconds, `requires_confirmation` MUST be true, and Malibu MUST enforce confirmation for those transaction kinds even if a malformed projection sets the flag false. For an unavailable action, `transaction_kind`, `transaction_id`, and `action_timeout_seconds` MUST be null. A row's `rate_source` MUST be equal to `source.rate_card_source` unless the row uses a more conservative value, where `none` is more conservative than `static_signed`, and `static_signed` is more conservative than `live_signed`. Closed v1 enum values are: `runtime_state` = `current`, `ready`, `catalog`, `needs_preparation`, `blocked`; `fit` = `fits`, `does_not_fit`, `unknown`; admission `source` = `local_default`, `coordinator`; admission `state` = `local_only`, `not_offered`, `offerable`, `offer_submitted`, `offer_rejected`, `sandbox_probe_only`, `network_visible_unpriced`, `network_admitted_unsettled`, `catalog_priced`, `settlement_capable`, `withdrawn`, `revoked`; `rate_source` = `live_signed`, `static_signed`, `none`; `economics_state` = `trusted`, `fallback`, `stale`, `blocked`, `unavailable`; warning codes = `feed_fallback`, `feed_stale`, `feed_signature_invalid`, `feed_generation_mismatch`, `rate_multiplier_unknown`, `model_not_local`, `model_not_supported`, `hardware_fit_unknown`, `hardware_does_not_fit`, `admission_state_missing`, `admission_state_not_settlement_capable`, `warm_swap_unavailable`, `action_unavailable`, `old_cli_fallback`, `projection_unavailable`, `projection_timeout`, `staging_cleanup_required`; action `transaction_kind` = `switch_model`, `switch_model_deferred`, `prepare_model`, `evaluate_model`, `adopt_recommendation`, `cleanup_staging`, or null when unavailable. The v1 transaction event stream MUST use a closed JSON-lines envelope with `schema: "model_catalog_transaction_event.v1"`, matching `transaction_id`, matching `transaction_kind`, `model_key`, monotonic per-transaction `event_sequence`, RFC3339 `emitted_at`, `state`, nullable `progress`, nullable `error_code`, and nullable `warning_code`. Closed event `state` values are `queued`, `running`, `cancel_requested`, `cancelled`, `succeeded`, `failed`, and `timed_out`; `progress`, when present, MUST include a localized-safe `stage_label_key` and at least one of `bytes_completed`/nullable `bytes_expected`, `percent_complete`, or `heartbeat`. Cancellation MUST be requested through the same CLI-owned transaction interface, MUST produce either `cancel_requested` followed by `cancelled` or a terminal `succeeded`/`failed` if the commit point has already passed, and MUST never require Malibu to kill the CLI process or delete files directly. Unknown enum values, unknown action transaction kinds, malformed event envelopes, or event transaction mismatches MUST make the affected row or transaction non-actionable and show a generic unsupported warning; they MUST NOT make Malibu reject the whole projection unless the projection envelope schema itself is unsupported.

**SPEC-044-R003 - Signed-feed trust and fallback states.** The CLI projection MUST identify whether rates came from a live signed feed, a signed static fallback, or no trusted feed. `economics_state: "trusted"` is permitted only when the CLI verifies the signed rate-card bytes, pairs them with the matching demand and candidate generated-at/policy version when those feeds are used for ranking, and can normalize the rate units through the owner-spec conversion rules. A live signed rate card is stale when `generated_at - rate_card_generated_at` is greater than `source.rate_card_max_age_seconds`; v1 `rate_card_max_age_seconds` MUST be at least 300 seconds and MUST NOT exceed 604800 seconds. Malibu MUST treat values outside that range as invalid projection input and fall back with warning code `projection_unavailable`. While the catalog view is visible, Malibu MUST refresh the projection or mark it unavailable before displaying it after `generated_at` is older than the smaller of 300 seconds and `source.rate_card_max_age_seconds`. A signed static fallback rate card MUST use `economics_state: "fallback"` unless a later owner spec defines a freshness proof that allows fallback data to be trusted. When multiple degraded economics conditions apply, the row MUST use the most conservative applicable state in this order: `blocked`, `unavailable`, `stale`, `fallback`, `trusted`; stale fallback data therefore uses `stale`. A row whose rate card is missing, stale, signature-invalid, generated-at mismatched against the demand/candidate feed set, or normalized through an unknown multiplier MUST set `economics_state` to `stale`, `fallback`, `blocked`, or `unavailable` as applicable and MUST disable all money-motivated actions. For v1, money-motivated actions are `switch`, `prepare`, `adopt_recommendation`, and any `evaluate` action that downloads data, mutates local cache/configuration, or is presented using rate, payout, provider-share, or network-demand copy; only a read-only hardware/model-fit evaluation may remain available when economics are not trusted, and it MUST hide or neutralize economics copy.

#### R002/R003 Build 1 v2 amendment

Build 1 preparation and published-artifact cleanup require capability
`model_catalog_economics_v2`, command-schema token
`models catalog-economics.v2`, and projection schema
`model_catalog_economics.v2`. The v2 envelope preserves every v1 field and
closed-enum rule except where this subsection explicitly adds a field or enum
value. The category-aware trio advertisement and fallback matrix in R001 applies; the
unchanged read command never selects a generation at request time. A client
that understands only v1 MUST use its existing fallback when paired with a
v2-only CLI and MUST NOT receive a v2 envelope. The exact invocation is owned
by SPEC-001-R003 (§6.14b).

For v2, Malibu allocates a monotonically increasing app-owned
`refresh_generation` before launching each projection read. This value is not
part of the CLI wire schema. Only a completion whose generation equals the
latest requested generation may replace visible projection state; every late
completion from an older generation is discarded regardless of its unrelated
`process_launch_id`, `generated_at`, or `projection_sequence`. Within that
accepted generation, a new `source.process_launch_id` identifies a CLI restart
and resets only the same-process sequence baseline. Superseding a projection
read MUST NOT cancel, kill, detach, stop draining, or otherwise disturb an
attached action worker.

Every v2 row adds nullable `candidate_id`, `provider_guidance`, and
`guidance_binding` as one all-or-none group. The group MUST be non-null for
every candidate-associated row and every row that exposes a local Prepare,
Evaluate, Adopt, or Switch action. `candidate_id` MUST match
`^byom_[a-z2-7]{52}$` and equal
the candidate ID in the single SPEC-046 or SPEC-047 source envelope used to
build the row. `provider_guidance` MUST contain exactly the five SPEC-046-R003
fields `state_label_key`, `state_meaning_key`, `next_action`, nullable
`transition_reason_code`, and `earning_path_class`, with the owner-spec field
values and closed enums copied verbatim. It MUST NOT be reconstructed from
admission state, economics, catalog identity, model names, or local action
eligibility.

The three fields MAY all be null only for a catalog-only row produced from a
validated signed catalog entry for which the immutable projection snapshot has
no matching SPEC-046/SPEC-047 candidate or local discovery source. Such a row
MUST use `runtime_state: "catalog"`, set `action_model_id` null, make every row
action unavailable with an exact reason, and MUST NOT render a candidate earning
verdict or claim local readiness. Because SPEC-047 admission is per-provider and
per-candidate, this all-null group has no admissible identity binding for
admission or economics. The row MUST remain non-trusted, MUST set
`economics_state` to `unavailable`, `rate_source` to `none`, every nullable
rate-card identity/rate/provider-share/payout field to null, and all demand
signals to null. Its required `admission` object MUST use `source:
"local_default"`, `state: "not_offered"`, null `coordinator_event_id`, null
`state_observed_at`, `catalog_economics_permitted: false`, and
`settlement_capable: false` solely as a conservative no-network-authority
sentinel; it is not a claim that a candidate exists. It MUST NOT use an
independently observed admission event,
model key, display name, served-model name, or signed rate row to construct a
positive admission case, and MUST expose no candidate-dependent action. A
catalog-only row MUST become candidate-associated on the first snapshot that
contains a matching validated owner-source candidate; partial group nullability
is malformed.
Malibu MUST place this exact catalog-only unavailable sentinel in the `Blocked`
section. It MUST NOT place it in `Network catalog`, `Current`, `Ready`, or
`Needs preparation`; the sentinel supplies neither trusted network economics
nor the independent local evidence required by those sections.

`guidance_binding` is closed and contains exactly `source_schema`,
`source_sha256`, `source_generated_at`, nullable `source_projection_sequence`,
nullable `source_coordinator_event_id`, `candidate_id`, `admission_source`, and
`admission_state`. For `admission_source: "local_default"`, `source_schema` MUST
be `provider_byom_discovery.v1`, `source_projection_sequence` MUST be the
non-null sequence from that source, and `source_coordinator_event_id` MUST be
null. For `admission_source: "coordinator"`, `source_schema` MUST be
`model_admission_status.v1`, `source_projection_sequence` MUST be null, and
`source_coordinator_event_id` MUST byte-for-byte equal the nullable event ID in
that exact source. It MAY be null only when the validated authoritative source
has `admission_state: "not_offered"` and explicitly carries a null
`coordinator_event_id`; every other coordinator state requires a non-null event
ID. The no-event case remains bound to the exact response bytes through
`source_sha256` and to its exact candidate, admission source/state, guidance,
and source timestamp through the remaining binding fields. A locally inferred
no-offer state or omission/malformation of the event field is invalid.
`source_sha256` is lowercase 64-hex SHA-256 over the exact bounded validated
UTF-8 source bytes, not a Malibu-generated join, and `source_generated_at` is
copied from the same source. For these v1 owner-source schemas,
`owner_source_max_age` is exactly 300 seconds; a later owner-spec amendment may
only narrow that bound for its source schema.

The row candidate ID, admission source/state/event, all five guidance values,
and every duplicated `guidance_binding` value MUST byte-for-byte equal that
single bound source. At v2 generation, checked wall-clock age MUST satisfy
`0 <= projection.generated_at - source_generated_at <= min(300 seconds,
owner_source_max_age)`; at Malibu rendering the same inequality uses the
current wall clock in place of `projection.generated_at`. A future source is
invalid. The
builder MUST load and validate the guidance source in the same immutable
projection snapshot as admission and artifact eligibility. Any missing, stale,
unknown, cross-candidate, cross-source, cross-event, cross-sequence,
digest-mismatched, or malformed binding invalidates the row: every action MUST
be unavailable, money fields MUST be null, and Malibu MUST show generic
unsupported copy. For a valid row Malibu MUST render the SPEC-001 earning
verdict mapped from the copied `earning_path_class` and the copied state
disclosure before fit, storage, preparation, demand, or economics detail.
Strict CLI and Malibu decoders MUST reject unknown binding/guidance fields and
unknown owner enums.

Each v2 action object adds nullable `artifact_identity_digest` to the v1 action
shape, and each row adds an explicit `cleanup_published` action. The closed v2 action
`transaction_kind` enum adds `cleanup_published_artifact`. This action targets
one exact reclaimable immutable object in the managed v3 namespace after
provider confirmation. An available cleanup action MUST carry a non-null
lowercase 64-hex `artifact_identity_digest` that binds the projection action to
the exact model/revision/artifact/release/root/receipt tuple; every other action
MUST set that field to null. Its source label is **Remove prepared model** and
its confirmation is **Remove this verified prepared model ({reclaimable_size}
of managed data)? The current model and legacy model files will be kept.**
`{reclaimable_size}` uses the same formatting rule as `{estimated_size}` below.
For an available cleanup action, `estimated_bytes` MUST equal the exact logical
prepared-data bytes represented by `{reclaimable_size}`. The UI MUST NOT
describe that logical value as bytes that will be recovered, freed, or made
available on the volume because APFS clones, compression, snapshots, and shared
allocation can make physical free-space change differ.
`artifact_identity_digest` is SHA-256 over the domain UTF-8 bytes
`macprovider.model_catalog.artifact_identity.v1`, followed in order by the exact
validated UTF-8 bytes of `display_model_id`, `model_revision`, `artifact_id`,
and `release_id`, then the lowercase ASCII bytes of `root_identity_digest` and
`receipt_sha256`; the domain and every field are independently prefixed by an
unsigned 32-bit big-endian byte length. No Unicode normalization or alternate
serialization is permitted. The managed object leaf is this same lowercase
64-hex digest, so receipt validation and inventory enumeration recompute it
without consulting a current catalog row.
`root.identity` is a closed versioned record containing exactly
`version: "model_catalog_root_identity.v1"`, a 32-byte root nonce encoded as
lowercase 64-hex, the canonical absolute UTF-8 root path, and the unsigned
64-bit decimal `st_dev` and `st_ino` of the validated opened root descriptor.
The nonce is generated once from 256 bits of CSPRNG entropy during atomic
v3-root bootstrap. `root_identity_digest` is SHA-256 over the exact ASCII domain
`macprovider.model_catalog.root_identity.v2`, followed in order by the exact
validated UTF-8 bytes of the record version and canonical path, the 32 decoded
raw nonce bytes, and the descriptor-observed device and inode encoded as
unsigned 64-bit big-endian integers; the domain and every variable-length field
are independently prefixed by an unsigned 32-bit big-endian byte length. The
recorded device/inode MUST equal the descriptor values before hashing. No
Unicode normalization, JSON serialization, decimal encoding of device/inode,
or current-configuration substitution is permitted.

Every bounded private lifecycle record that can require root reopening,
including projected-transaction reservations, active attempts, preparation and
cleanup phase records, terminal recovery records, and managed-object receipts,
MUST persist the same canonical path, device, inode, record version, and
`root_identity_digest`. The secret nonce remains only in the owner-mode `0600`
descriptor-relative `root.identity` record. Recovery uses the lifecycle
record's saved canonical path as its locator, reopens it component-by-component
without following symlinks, validates saved path/device/inode against the
descriptor and the descriptor-relative `root.identity`, and recomputes the
digest before use. Current configuration, scanning, a supplied projection
digest, or a lifecycle locator with mismatched identity is never root authority.
The nonce, path, device, inode, username, and hardware identifiers MUST NOT
appear in the projection; only the digest may be projected. Copying or rebinding
`root.identity` or a lifecycle record to another path, descriptor, device, or
inode MUST change or invalidate the digest and fail before any side effect.
The worker MUST revalidate the current projection transaction, digest, receipt,
root identity, and keep set under the common operation/cleanup lock before any
rename. A stale or mismatched binding fails before deletion. It is distinct
from `cleanup_staging`, which remains
limited to incomplete staging data and MUST reject published objects. Neither
action authorizes automatic garbage collection or legacy-object mutation.

The v2 envelope also adds required top-level `cleanup_targets`, an array of at
most 256 closed objects with exactly `artifact_identity_digest`,
`display_model_id`, `model_revision`, `artifact_id`, `release_id`, nullable
current `model_key`, required non-null `event_model_key`,
`root_identity_digest`, `receipt_sha256`, exact logical `estimated_bytes`,
`keep_set_status`, nullable `protected_reason`, and `cleanup`. The two SHA-256
digests are lowercase 64-hex;
`keep_set_status` is `protected` or `reclaimable`; `protected_reason` is
non-null exactly for `protected`; and `cleanup` uses the v2 action shape. The
array MUST contain every verified managed-v3 object in the usable inventory
exactly once, including objects with no current catalog row, ordered by
ascending `artifact_identity_digest`. A `reclaimable` entry MUST have one
available `cleanup_published_artifact` action carrying the same artifact digest
and `estimated_bytes`; a `protected` entry MUST have an unavailable action and
exact reason. Missing or stale receipt identity, malformed inventory, or
overflow makes the array empty and all published cleanup unavailable.
`row.cleanup_published`, if retained, MUST be byte-for-byte identical to
`cleanup_targets[i].cleanup` after each of those two closed action objects is
serialized as UTF-8 RFC 8785 JSON Canonicalization Scheme (JCS) bytes.
Implementations MUST reject duplicate or unknown action-object member names
and invalid/noncanonical numeric values before this comparison. Separately,
`row.cleanup_published.artifact_identity_digest` and
`cleanup_targets[i].cleanup.artifact_identity_digest` MUST each equal the
enclosing `cleanup_targets[i].artifact_identity_digest`, and both action
`estimated_bytes` values MUST each equal the enclosing
`cleanup_targets[i].estimated_bytes`. Thus the nested action equality cannot
substitute for the destructive target's digest and size binding. Malibu MUST
de-duplicate the two action projections by `artifact_identity_digest` and
keep one reachable action. Absence from the
current signed catalog MUST NOT make a reclaimable verified identity
unreachable.

`event_model_key` is the nonempty immutable historical model key captured in
the verified managed-object receipt when the object was published. It never
changes when the current catalog match disappears or changes. Every projected
cleanup action and every durable cleanup reservation, active-attempt, phase,
history, and terminal record MUST persist this exact value. The attached worker
MUST use it as the retained v1 event envelope's required `model_key`; current
nullable `model_key` is display/catalog correlation only and MUST NOT be used to
invent, replace, or suppress the event key. A missing or mismatched historical
key invalidates the receipt and makes cleanup unavailable.

The v2 envelope adds one required top-level `storage` object with exact fields:

- `schema: "model_catalog_storage.v1"`;
- nullable unsigned `managed_v3_published_bytes`,
  `managed_v3_reclaimable_bytes`, `managed_v3_object_count`,
  `configured_legacy_protected_bytes`,
  `configured_legacy_other_device_bytes`, `managed_budget_charge_bytes`, and
  `available_managed_budget_bytes`, plus non-null unsigned
  `global_managed_budget_bytes`;
- `configured_legacy_accounting_state`, whose closed values are `available`,
  `not_configured`, and `unavailable`;
- boolean `managed_v3_overflow_detected`; and
- `managed_budget_source`, whose closed values are `default` and `configured`.

All non-null integers MUST be in `0...9007199254740991`. The CLI MUST enumerate only verified objects under the dedicated managed v3
namespace. `managed_v3_object_count` is at most 256 in a usable projection. It
MUST read at most 257 directory entries to detect an externally seeded
overflow, set `managed_v3_overflow_detected: true`, disable preparation and
published cleanup, set all managed-v3 totals, charge, and available budget to
null, and MUST NOT truncate, delete, or claim the observed 257th entry is the
final entry. Malformed v3 inventory has the same null/fail-closed result without
setting the overflow boolean unless overflow was actually observed.
`managed_v3_reclaimable_bytes` MUST exclude the
current model, configured current/draft artifacts, active or prepared adoption
targets, selected or active preparation targets, live-worker targets, serving
verification targets, and identities bound to another root.

All byte fields in `storage`, `cleanup_targets.estimated_bytes`, and action
`estimated_bytes` are descriptor-relative logical byte counts. Starting from
the already identity-validated root descriptor, the CLI MUST open each path
component relative to its parent descriptor without following symlinks, walk
only the exact managed-object or configured-legacy tree, and classify every
entry with descriptor-relative metadata. It MUST require same-device,
owner-approved regular files with `st_nlink == 1` and reject symlinks, hard
links, device nodes, sockets, FIFOs, traversal, mount crossings, and any entry
or sum outside the existing file-count, depth, relative-path, or integer
bounds. Each directory contributes zero. Each accepted regular file contributes
exactly its nonnegative logical data-fork `st_size` once, including artifact
bytes, receipts, manifests, and other managed metadata files inside the measured
tree. Directory implementation bytes, extended attributes, resource forks,
filesystem allocation blocks, snapshots, APFS clone sharing, and compression
savings are excluded; sparse, cloned, and compressed regular files therefore
count by full logical `st_size`, subject to the same estimate and aggregate
caps. Each addition MUST use checked unsigned arithmetic and the complete walk
MUST be revalidated against the same bound descriptor before its result is
published or used for dispatch; a race or unstable descriptor identity fails
the affected managed inventory or configured-legacy accounting closed.

On macOS, every private root component, `root.identity`, including the
owner-mode `0600` `operation.lock`, `failure.lock`, and `cancel.lock`, reservation,
active/history/terminal state file, marker, staging or published artifact,
receipt, cleanup phase record, tombstone, and configured-legacy component that
is validated for use MUST have no extended ACL entries. During atomic creation
the CLI MUST create an owner-only, already-open, unpublished temporary namespace
entry. Through that descriptor it MUST strip every inherited ACL and verify an
empty extended ACL before writing the first sensitive byte. If stripping or
verification fails, it MUST write no sensitive byte, publish nothing, revalidate
the descriptor identity, and remove only that newly created empty object. For
every pre-existing sensitive node, any extended ACL entry, inherited or
explicit and whether allow or deny, is invalid; the CLI MUST reject it rather
than repair it implicitly. Mode bits do not substitute for this rule. ACL,
owner, type, mode, link count, device, and inode MUST be verified from the
opened descriptor (`acl_get_fd_np` or an equivalent descriptor-bound API), then
revalidated on the same descriptor, including another empty-ACL verification,
immediately before each rename, deletion, publication, or authority use. A
path-based ACL check is insufficient. Any ACL mutation or descriptor replacement
between validation and use fails closed without acting on the replacement.

Verified configured legacy current/draft trees outside the v3 namespace are
always protected. Their same-volume bytes populate
`configured_legacy_protected_bytes` and charge the managed budget; their
other-device bytes populate `configured_legacy_other_device_bytes` and do not
charge that root's budget. Therefore
`managed_budget_charge_bytes = managed_v3_published_bytes +
configured_legacy_protected_bytes`, and `available_managed_budget_bytes =
max(0, global_managed_budget_bytes - managed_budget_charge_bytes)`. An
unconfigured legacy object is unmanaged and MUST NOT be enumerated, imported,
receipted, renamed, repaired, or deleted. Filesystem free-space checks use the
checked product of the bound volume's current available-allocation count and
allocation-unit size; this physical-availability value is never reported as a
logical byte field. If a configured legacy tree cannot be safely
measured, the CLI MUST use `configured_legacy_accounting_state: "unavailable"`,
set both legacy byte fields, the charge, and available budget to null, disable
preparation and published cleanup, and preserve incumbent serving.
`not_configured` uses zero for both legacy byte fields; `available` requires
both to be non-null. When managed inventory is valid and legacy accounting is
`available` or `not_configured`, every managed-v3 total, charge, and available
budget MUST be non-null and satisfy the equations above. When managed inventory
is malformed or overfull, all managed-v3 totals, charge, and available budget
MUST be null regardless of legacy-accounting state.

The default `global_managed_budget_bytes` is exactly
`min(1099511627776, floor(volume_capacity_bytes * 70 / 100))`, implemented with
checked unsigned arithmetic that cannot overflow before division. An operator
may replace the default only with the positive integer
`model_preparation_budget_bytes` from the normal CLI configuration layering:
environment `MACPROVIDER_MODEL_PREPARATION_BUDGET_BYTES` overrides YAML
`model_preparation_budget_bytes`. Either configured value MUST be in the exact
range `1...1099511627776`; an invalid higher-precedence value MUST fail closed
rather than falling through to a lower-precedence value or the default.
`managed_budget_source` MUST report `configured` only for the selected valid
configured value and `default` otherwise. A new distinct publication requires
checked `managed_budget_charge_bytes + estimated_bytes <=
global_managed_budget_bytes` and a free object-count slot; failure of either
check MUST occur before network or staging side effects. An exact
already-published identity remains idempotently usable. Preparation separately
requires checked physical free space satisfying `available_capacity_bytes >=
2 * estimated_bytes + 1073741824` before transfer and again before publication,
measured from the bound root volume as stated above. Failure or overflow refuses
before the corresponding side effect. No budget failure authorizes deletion.

The exhaustive v2 preparation classification is:

Every preparation branch below requires the bound primary artifact to be
`mlx_safetensors` with SPEC-023 `verification_status: "verified"` in the
current signed artifact feed. `declared`, `blocked`, absent, signature-invalid,
or feed-drifted artifacts MUST make Prepare unavailable at projection and MUST
be rechecked at dispatch before network or staging access and immediately
before publication. The bound guidance/admission source and its freshness MUST
also be revalidated immediately before publication; drift preserves incumbent
serving and leaves no published object. A signed binding by itself is
insufficient.

| Admission source/state | Economics state | Preparation authority and presentation |
|---|---|---|
| `local_default` with `local_only`, `not_offered`, or `offerable` | `fallback`, `stale`, `blocked`, or `unavailable` | Locally motivated `prepare_model` MAY be available only when the verified signed primary `mlx_safetensors` artifact binding is current, `fit: fits`, `runtime_state: needs_preparation`, `action_model_id` is non-null, exact `estimated_bytes` is positive and at most 1 TiB, and no non-economic safety/storage block applies. Hide rates, payouts, provider share, and demand motivation; preserve the authoritative earning verdict and admission disclosure. |
| `local_default` with any state | `trusted` | Invalid projection combination. Hide economics and disable Prepare with generic unsupported/action-unavailable copy. |
| `coordinator` with `not_offered`, `offer_submitted`, `sandbox_probe_only`, `network_visible_unpriced`, `network_admitted_unsettled`, `withdrawn`, or `revoked` | `fallback`, `stale`, `blocked`, or `unavailable` | The same locally motivated eligibility and copy MAY apply. Hide rates, payouts, provider share, and demand motivation; preserve the wire earning verdict and admission disclosure. |
| `coordinator` with `offer_rejected` | Any | Reserved wire value with no reachable coordinator origin in SPEC-047 v0.2. Decode the known enum for compatibility, but treat a current row as inconsistent and non-actionable; do not offer Prepare or infer an authoritative rejection event. Hide economics and use generic unsupported/action-unavailable copy. |
| The reachable non-priced coordinator states in the first coordinator row | `trusted` | Invalid because `catalog_economics_permitted` is false. Hide economics and disable Prepare with generic unsupported/action-unavailable copy. |
| `coordinator` with `catalog_priced` or `settlement_capable`, with `catalog_economics_permitted: true` | `trusted` | Trusted-economics `prepare_model` MAY be available when the same artifact, fit, runtime, target, size, and safety/storage prerequisites pass. Trusted rates may be shown under R004; earning/settlement copy still follows the admission state. |
| `coordinator` with `catalog_priced` or `settlement_capable` | `fallback`, `stale`, `blocked`, or `unavailable` | Only the locally motivated classification MAY be available under the same prerequisites. Hide or neutralize rates, payouts, provider share, and demand for the action. |
| Any source/state mismatch, malformed admission, inconsistent booleans, or any other combination | Any | Unavailable. Hide economics and use generic unsupported/action-unavailable copy. |

For the current SPEC-047 v0.2 authority, `offer_rejected` remains one of the
12 closed admission enum values so a decoder can recognize the wire value, but
no coordinator origin can append it. A projected
`source: "coordinator", state: "offer_rejected"` row is therefore inconsistent
regardless of a claimed `coordinator_event_id`, observed time, economics class,
or otherwise verified local artifact. The CLI MUST project it with
`economics_state: "unavailable"`, `rate_source: "none"`, false
`catalog_economics_permitted` and `settlement_capable`, null rate-card identity,
rate, provider-share, payout, and demand fields, and every action unavailable.
Malibu MUST show only generic unsupported/action-unavailable copy for that row;
it MUST NOT present the claimed rejection as an authoritative admission event,
show paid-admission, trust, pricing, or earning copy, or enable
`prepare_model`. Neither CLI nor Malibu may synthesize a coordinator event to
make the row appear reachable. This restriction does not change locally
motivated Prepare for valid `local_default:not_offered` or authoritative
`coordinator:not_offered` and the other reachable matrix states.

For every locally motivated row, the exact app-localizable English source copy
is: label **Prepare locally**; detail **Download and verify this model for local
use. This does not offer it to the network or enable earnings.**; confirmation
**Download and verify {estimated_size} for local use?** For every trusted-
economics row, the exact source copy is: label **Prepare model**; detail
**Download and verify this model from the trusted catalog. Preparation does not
offer it to the network, change the running model, or guarantee earnings.**;
confirmation **Download and verify {estimated_size} from the trusted catalog?**
`{estimated_size}` is the localized display of the exact positive
`estimated_bytes`. It MUST be formatted as decimal gigabytes rounded upward to
the next 0.1 GB (`ceil(estimated_bytes / 100000000) / 10`), with one fractional
digit, the current locale's decimal separator and digits, and a localized `GB`
unit; this never understates the signed byte count. The local action MUST NOT be described as higher-paying,
network-ready, offer-ready, admission progress, or earning. Preparation ends at
durable local readiness and MUST NOT edit provider configuration, change the
running model, change admission/routing/economics, submit an offer, or create
settlement evidence.

The existing `model_catalog_transaction_event.v1` schema and seven states are
retained. Each line is capped at 16384 bytes. Only the attached worker emits
events and allocates a strictly increasing per-transaction `event_sequence`;
every event MUST match the invoked `transaction_id`, projected
`transaction_kind`, and the durable reservation's immutable non-null
`event_model_key`, which is emitted as retained envelope field `model_key`.
Candidate-associated row transactions reserve their row `model_key`; published
cleanup reserves the target's historical `event_model_key`, including for an
orphan whose current catalog `model_key` is null. The `transaction_id` is a canonical
lowercase hyphenated UUID v4 generated fresh when the CLI builds an available
projected action from at least 122 bits of CSPRNG entropy. After framing and
immutable projected-action identity validation, the attached run process
generates a distinct canonical lowercase hyphenated UUID v4 `attempt_id` from
the same minimum entropy source. A normal attempt records that ID in bounded
durable active, history, and marker state. An exit-3 pre-work failure records it
only in the terminal `failed_dispatch` record and bounded history defined
below; it never creates live attempt or marker state. Neither path adds the
attempt ID to the retained v1 event envelope. Parsers MUST require the exact
36-byte UUID grammar before either
identifier can select or name durable state, and MUST treat both identifiers as
opaque equality keys. The
cancel process emits none. Exactly one terminal state is allowed. The closed
event `error_code` values are `action_unavailable`, `stale_transaction`,
`operation_conflict`, `authority_unavailable`, `artifact_unqualified`,
`artifact_identity_mismatch`, `root_unavailable`, `root_identity_mismatch`,
`unsafe_filesystem_object`, `resource_limit_exceeded`,
`insufficient_disk_space`, `managed_budget_exceeded`,
`managed_object_limit_exceeded`, `managed_inventory_invalid`,
`transfer_failed`, `transfer_size_exceeded`, `verification_failed`,
`publication_failed`, `cleanup_failed`, `cancel_failed`, `timed_out`, and
`internal_error`. The closed event `warning_code` values are
`staging_cleanup_required`, `published_cleanup_available`,
`configured_legacy_accounting_unavailable`, `managed_inventory_overflow`, and
`cancellation_pending`. Unknown codes fail the affected transaction closed.
`error_code` MUST be non-null for `failed` and `timed_out` and null for every
other state; `warning_code` remains nullable and, when present, MUST use the
closed warning enum.
When several errors apply, the worker MUST select the first applicable class in
this precedence: malformed/stale action; operation conflict; authority or root
identity; filesystem/resource bounds; storage budget/inventory; transfer;
verification; publication or cleanup; cancellation; timeout; internal error.

The catalog-economics v2 lock graph is exhaustive. A path may hold one lock by
itself. Whenever it holds more than one lock, the only permitted acquisition
orders, retention boundaries, and release rules are:

1. A projection writer that creates, replaces, or removes any durable projected-
   transaction reservation takes `operation.lock`, then `failure.lock`, then
   `cancel.lock`. It retains all three from final immutable snapshot
   revalidation through atomic reservation publication, parent full-sync, and
   readback validation, then releases `cancel.lock`, `failure.lock`, and
   `operation.lock` in reverse order. Projection construction that has not yet
   taken these locks is speculative and cannot publish or remove a reservation.
2. A normal or pre-active worker creating `active.json`, a normal worker
   committing ordinary terminal/history state, and a startup or recovery worker
   compacting ordinary or failed-dispatch terminal/history state takes
   `operation.lock`, then `failure.lock`, then `cancel.lock`. It retains all
   three across every cancel-visible state change and its durability/readback
   barriers, then releases them in reverse order. A live worker may retain
   `operation.lock` while doing bounded work, but it MUST hold both subordinate
   locks before it creates active state, crosses a non-cleanup commit boundary,
   or mutates terminal/history state. A final marker check under this sequence
   retains all three through the applicable non-cleanup publication barrier,
   then releases them in reverse order.
3. A failure-only path creating, compacting, or evicting pending
   or historical `failed_dispatch` state takes `failure.lock` then
   `cancel.lock`, retains both across the complete atomic state transition and
   durability/readback barriers, and releases `cancel.lock` then `failure.lock`.
   A failure-only path takes `failure.lock` then `cancel.lock`; it never takes
   `operation.lock` or any cleanup, adoption, socket, or runtime authority.
4. A direct cancel process takes `failure.lock` then `cancel.lock`, retains both
   across its complete bounded predicate read and optional exact-marker
   publication/removal, then releases them in reverse order. It never takes
   `operation.lock`, a cleanup lock, `RecommendationAdoptionLock`, the control
   socket, or a runtime reservation, and it never mutates history, cleanup
   phase, artifact, model, adoption, or runtime state. Its only recovery work
   is the exact cancel-visible final-record parent barriers and readback below;
   it does not compact history, advance a cleanup phase, or replay worker work.
5. A live non-cleanup worker that already retains `operation.lock` may take
   `cancel.lock` directly only for one bounded periodic exact-marker read. It
   retains both only through that read, releases `cancel.lock` immediately, and
   does not read or mutate failed-dispatch pending/history, ordinary terminal/
   history, projected reservations, active state, or cleanup state, and does
   not create, remove, or alter any marker.
   Active creation, final marker check, commit, and terminal/history mutation
   use item 2 instead.
6. A published- or staging-cleanup mutation critical section takes
   `operation.lock`, then its one exact-target cleanup lock, then `cancel.lock`.
   It retains that sequence through the cleanup durability boundary specified
   below and releases `cancel.lock` before the cleanup lock. If the same worker
   must then commit or compact terminal/history state, it first durably
   readback-validates cleanup state, releases the cleanup lock, retains
   `operation.lock`, and only then takes `failure.lock` then `cancel.lock` under
   item 2. No path ever holds a cleanup lock and `failure.lock` together.
7. An adoption mutation takes `operation.lock`, then
   `RecommendationAdoptionLock`, then the control socket, then the runtime
   reservation. It releases the runtime reservation, socket, and adoption lock
   in reverse order while retaining `operation.lock`. Any later active or
   terminal/history mutation follows item 2; adoption/socket/runtime resources
   are never held with `failure.lock`, `cancel.lock`, or a cleanup lock.

No other nested acquisition or release order is permitted. In particular no
path holding `failure.lock`, `cancel.lock`, a cleanup lock, an adoption lock, a
control socket, or a runtime reservation may newly acquire `operation.lock`.
No path holding `cancel.lock` may newly acquire `failure.lock`. All lock files
use fixed process/file-descriptor resources; waiting never creates a task,
thread, descriptor, or waiter per retry.

Every syntactically and structurally valid `--run` has a constructive pre-work
lifecycle. Before semantic freshness, availability, or operation-conflict
checks, the initiating process MUST first validate the immutable projected
action identity: the bounded projected-transaction record, transaction ID and
kind, non-null historical `event_model_key`, saved root locator and identity,
complete immutable tuple, and projection/action binding digest MUST be present,
closed, and mutually equal. A syntax, framing, identifier, schema, or immutable
binding failure remains exit 2 and emits no event. After that validation the
process creates its fresh `attempt_id` and records one `CLOCK_MONOTONIC_RAW`
deadline immediately before its first attempt to acquire `failure.lock`.
`failure.lock` and then `cancel.lock` must both be acquired while elapsed time
is strictly less than 2.000 seconds; retries and spurious wakeups consume the
same total deadline. Both locks are required to inspect semantic dispatch state,
but lock ownership alone is not worker attachment. The process becomes the
attached failure worker only when it selects a semantic exit-3 result and begins
durable pending-record publication while retaining both locks. If both are not
held when elapsed time reaches 2.000
seconds, it releases any lock and every other resource it acquired, writes
exactly one UTF-8 stderr line `{"error_code":"dispatch_state_busy"}` followed
by LF, writes no stdout or event, exits 5, and makes zero durable/state/network/
staging/model/adoption/runtime mutation. This typed pre-attachment process
error is outside semantic exit 3 because durable worker attachment was never
established. Malibu maps `dispatch_state_busy` to an actionable retry, keeps the
projection outcome unresolved, and MUST NOT infer a terminal transaction.

While holding `failure.lock` then `cancel.lock`, the pre-attachment serializer
revalidates semantic action freshness and availability and the serialized
cancel-visible conflict view. A process whose check finds stale, unavailable,
or already-active state becomes the attached failure worker and records that
result while retaining both locks. Otherwise
it releases both locks in reverse order and makes exactly one nonblocking
acquisition attempt on `operation.lock`; it MUST NOT wait for that lock.
Failure to acquire it is `operation_conflict`: within the original failure-only
2.000-second deadline the process reacquires `failure.lock` then `cancel.lock`,
revalidates that stale or unavailable has not won under the error precedence,
becomes the attached failure worker, and records the winning exit-3 result. If
it cannot reacquire both before the
original deadline, it returns the exact pre-attachment `dispatch_state_busy`
result above with no event or mutation. The conflict reporter never acquires
`operation.lock` and is not a second active attempt.

Successful nonblocking acquisition changes the process into a pre-active normal
worker. While holding `operation.lock`, it records a new one-total
`CLOCK_MONOTONIC_RAW` deadline and acquires `failure.lock` then `cancel.lock`;
both must be held strictly before 2.000 seconds. It repeats the semantic and
cancel-visible conflict checks and creates the one live `active.json` attempt
only if they still pass. A newly stale or unavailable result is recorded by an
attached failure worker under all three locks without creating live state. Deadline
expiry releases every held lock and resource and returns the same exact
`dispatch_state_busy` stderr/no-event/exit-5 result with zero mutation. No
durable handoff claim exists between the failure-only and pre-active episodes,
so a crash in that interval leaves no claim or live attempt to recover.

For semantic `stale_transaction`, `action_unavailable`, or
`operation_conflict`, the attached pre-work process MUST, before writing stdout,
atomically persist and read back one private record no larger than 16,384 bytes.
The closed record contains exactly `schema: "model_catalog_failed_dispatch.v1"`,
`transaction_id`, fresh `attempt_id`,
`transaction_kind`, immutable non-null `event_model_key`, `root` containing the
complete saved root locator/identity object, `tuple_sha256`,
`projection_binding_sha256`, `event_sequence: 1`, `terminal_state: "failed"`,
the applicable `error_code`, and `live_attempt: false`. Both digests are
lowercase 64-hex and bind the exact validated tuple and exact bounded projected-
action reservation bytes; the root object has the path/device/inode/version/
digest fields required of every private reopening record. The record contains
no model path outside that private root locator, feed body, URL, provider
credential or identifier, prompt, completion, raw error, or other unbounded
text. It creates no `active.json`, cancellation marker, staging or network work,
model mutation, runtime/adoption mutation, or incumbent displacement.

All `failed_dispatch` pending/history creation, compaction, recovery, and
oldest-terminal eviction occurs while holding at least `failure.lock` then
`cancel.lock`; startup/recovery first holds `operation.lock` as required by
graph item 2.
Pending failed-dispatch plus ordinary terminal history share one global limit of
256 records and an aggregate 262,144-byte cap; a failed-dispatch record consumes
both limits exactly like an ordinary terminal record, and at most one pending
record exists. The writer first constructs the complete bounded replacement
history in a recognized unique temp, including idempotent incorporation of any
prior pending record and deterministic eviction, fully syncs the temp, atomically
renames it, fully syncs its parent, and readback-validates it. It then publishes
the new pending record through its own synced unique temp, atomic rename, parent
full-sync, and readback validation. Compaction uses the same order: first publish
and readback-validate a history snapshot containing the pending terminal record,
then unlink the pending record, full-sync its parent, and read back the coherent
history. A crash may leave the same record in both places; identity-based
recovery deduplicates it. It MUST never leave a durable interval in which a
previously durable terminal record exists in neither place. Eviction is part of
the replacement history snapshot and never a delete-before-copy operation.

The successful new-pending publication/readback is the failed-dispatch terminal
publication point. A direct cancel linearizes its predicate while holding the
same `failure.lock` then `cancel.lock`. Whenever that failed dispatch is durable
in pending or history at the cancel linearization point, cancel MUST return
`terminal` with the record's exact `attempt_id`, never `recorded`,
`already_recorded`, `stale`, or `not_active`, and it MUST never create a marker.
An uninterrupted writer retains both locks through the pending parent barriers
and readback; lock availability alone is not evidence of a crash or of
publication. If those locks become available after an interrupted final rename,
a surviving pending final is only a roll-forward candidate. Direct cancel,
while retaining both locks, MUST complete only that final's parent `fsync` and
`F_FULLFSYNC` and exact-record readback before applying `terminal`. Startup or
recovery does the same under `operation.lock`, then `failure.lock`, then
`cancel.lock`. Both paths MUST first validate the bounded closed record,
transaction/attempt/kind, immutable event key, saved root identity, tuple and
projection-binding digests, and exact final leaf. A surviving projected action
MUST match the digests and identity. If it was already retired, the protected
pending final remains the roll-forward witness; a separately durable matching
history copy corroborates it but is not required. Both paths MUST reject a
different, malformed, or conflicting final. Neither path may infer publication
from a temp alone. If validation, either barrier, or
readback fails, direct cancel exits 5 without an acknowledgement or marker and
recovery fails closed without a terminal claim; neither emits or replays stdout.
Injected cancel reads between every temp sync, rename, parent barrier,
readback, pending unlink, history replacement, eviction, and recovery step
therefore observe only the state on one side of an uninterrupted lock-protected
transition. After an interrupted rename, the roll-forward checks apply.

Once the pending record is durable, the attached process releases
`cancel.lock` then `failure.lock`, emits exactly one terminal event with matching
transaction ID/kind, `model_key: event_model_key`, `event_sequence: 1`,
`state: "failed"`, null progress and warning, and the recorded error code. No
lock is held while stdout is written or flushed. The process then exits 3 and
does not reacquire a lock. The next failure-only writer compacts this complete
pending record before publishing another one; startup/recovery may compact it
under graph item 2. Failure to make the initial pending record durable emits no
unbound event and exits 5.

A crash before the final rename leaves only a recognized unique temp for bounded
cleanup and no terminal claim. A surviving exact pending final after rename but
before its parent barriers/readback follows the conditional roll-forward above;
if the final is absent after power loss, the temp cannot establish a terminal
claim. A crash after the pending record is durable but before event flush, after
event flush but before compaction, or during compaction preserves the same
immutable terminal record. Recovery takes
`operation.lock`, then `failure.lock`, then `cancel.lock`, compacts it exactly
once into history, never creates live state, never emits replacement stdout
without an attached invocation, and never replays network, staging,
cancellation, adoption, or model work. The app treats an interrupted stream as
interrupted and refreshes; recovery does not fabricate delivery.

The contract makes no scheduler-fairness or starvation-free claim. Under
continuous arrivals every acquisition episode has fixed waiter, descriptor,
memory, and two-second monotonic bounds; timeout releases partial ownership and
preserves the last durable coherent state. Deterministic lock-trace tests MUST
cover every graph path and every pairwise overlap among projection publication,
failed-dispatch creation/compaction/eviction/recovery, pre-active creation,
ordinary terminal/history compaction, direct cancellation, both cleanup paths,
and adoption. They must prove the permitted order, exact retention/release
points, absence of reverse acquisition and deadlock, coherent fail-closed
resource release under sustained arrivals, no second live attempt, no
cancellation marker for a failed dispatch, and no incumbent displacement.

Machine transport is constant-space. Projection-read stdout is capped at
4,194,304 bytes and cancel-ack stdout at 4,096 bytes. The attached run adapter
MUST incrementally validate UTF-8 and split JSONL while retaining at most one
16,384-byte partial line plus fixed decoder state; it MUST reject a partial line
immediately when the next byte would exceed the cap, MUST NOT retain complete
worker stdout, and MUST continue draining or applying bounded OS-pipe
backpressure until worker termination. Worker stderr is always drained but
retained only through 65,536 bytes; excess bytes are discarded and the
diagnostic is marked truncated. The CLI MUST emit no more than 10 event lines
per monotonic second after an initial burst of at most eight state-transition
lines.

Decoded event delivery MUST use one fixed-capacity queue of at most 64 events
per attached worker, reserve one slot for a terminal event, and schedule at most
one MainActor drain task. When full, the reader MAY replace only an older
nonterminal progress/heartbeat event for the same transaction with its newer
validated successor. It MUST preserve event-sequence validation and every
state-transition, warning, error, and terminal event. If coalescing cannot make
space, the reader MUST apply bounded pipe backpressure rather than allocate more
memory; an event-rate violation or a terminal event that cannot be admitted
fails the transaction closed while a discard drain continues to EOF. Tests MUST
not require retaining unbounded diagnostic or progress history.

Cancellation uses the exact SPEC-001-R003 `--cancel` form and returns one JSON
object capped at 4096 bytes with exactly `schema`, `transaction_id`, nullable
`attempt_id`, `outcome`, and `observed_at`. `schema` is
`model_catalog_transaction_cancel_ack.v1`; `observed_at` is RFC3339; and the
closed outcomes are `recorded`, `already_recorded`, `terminal`, `not_active`,
`stale`, and `busy`. `transaction_id` MUST byte-for-byte echo the validated requested
ID. `attempt_id` MUST be the matching opaque durable attempt ID for `recorded`,
`already_recorded`, or `terminal`; it MUST be null for `not_active`; for
`stale` it is the recognized prior or mismatched attempt ID when one can be
read safely and otherwise null; and it MUST be null for `busy`. `recorded`
means only that an exact-attempt cancellation marker is durable; it is not a
worker-observation, cancellation-success, or terminal claim. `busy` means only
that the bounded lock-acquisition deadline below expired. It is a syntactically
valid acknowledgement with exit 0, not an error or a claim about transaction
state.

The direct cancel process records one `CLOCK_MONOTONIC_RAW` deadline immediately
before attempting `failure.lock`, then acquires `failure.lock` followed by
`cancel.lock`. Both locks must be held while elapsed time is strictly less than
2.000 seconds; retries and spurious wakeups consume the same total deadline. If
both are not held when elapsed time reaches 2.000 seconds, it releases any held
lock and every other resource, returns exactly one valid `busy`
acknowledgement, and exits 0. It MUST NOT read state as though serialized,
create or remove a marker, mutate history or any cleanup phase, or infer any
in-lock predicate. Each cancel process uses one waiter and fixed memory/file-
descriptor resources; it MUST NOT create a task, thread, descriptor, or
additional waiter per retry or spurious wakeup.

After acquiring `failure.lock` then `cancel.lock`, the cancel process MUST
validate bounded active, terminal-history, failed-dispatch pending, projected-
transaction, and marker records and choose the first matching predicate in this
total precedence:

1. `terminal`: the requested transaction has a durable matching ordinary or
   failed-dispatch attempt whose terminal state was committed, regardless of a
   leftover exact marker;
2. `already_recorded`: the requested transaction is the durable current
   nonterminal attempt and an exact marker for its transaction and attempt is
   already durable;
3. `recorded`: the requested transaction is the durable current nonterminal
   attempt without its exact marker; the cancel process removes only a
   validated marker bound to an older attempt, durably creates and readback-
   validates the current exact marker, and then acknowledges;
4. `stale`: validated bounded state proves that the requested transaction
   existed but is no longer the cancellable current attempt, including a
   different current attempt or a mismatched prior-attempt marker; and
5. `not_active`: no active, terminal, failed-dispatch pending, projected, or
   bounded-history record recognizes the requested transaction and no marker
   names it.

`busy` is outside this in-lock precedence. A malformed record fails the cancel
command closed with exit 5 and no acknowledgement rather than being classified
as `not_active`. All writers of cancel-visible active, terminal, failed-
dispatch, projected-reservation, and marker state hold the compatible lock
sequence from the exhaustive graph, so no such publication, compaction, or
eviction can change the predicate while the direct cancel retains both locks.
For any surviving final-path active, ordinary terminal/history, failed-dispatch
pending, projected-reservation, or exact-marker record used to choose an
acknowledgement, the direct cancel MUST validate its closed schema, exact
transaction/attempt and applicable immutable/root bindings, then complete that
final's parent `fsync` and `F_FULLFSYNC` and read back the same bounded record
while retaining `failure.lock` then `cancel.lock`. This barrier-only rule also
applies to `cancel.json` before `already_recorded`; a final-path read cannot
show whether its original writer finished the barriers. An intact unique temp
without its final is never a committed witness. Any contradictory identity,
failed barrier, or failed readback causes exit 5 with no acknowledgement or
marker. The direct cancel cannot repair logical state or perform cleanup-object
barriers; the distinct cleanup-phase recovery rule below applies to those
phase finals.
The worker checks a durable marker at least every 250 ms and in each bounded
work loop.
If cancellation wins before the applicable commit point, the worker emits
`cancel_requested` once and then terminal `cancelled` after cleanup. After the
commit point it emits only `succeeded` or `failed`. For ordinary terminal
compaction the worker retains `operation.lock`, takes
`failure.lock` then `cancel.lock`, durably commits terminal/history state,
removes only the exact matching marker, and releases all three in reverse order.
A new worker takes the same operation-then-failure-then-cancel order and removes
only a stale prior-attempt marker before persisting its new attempt. Thus a late marker
cannot cross terminal or new-attempt boundaries. The acknowledgement carries
no event sequence or terminal-success assertion; Malibu continues the worker
stream and refreshes the projection for authoritative state.

For preparation and other non-cleanup transactions, the publication commit
point is the durable exclusive object rename plus destination-parent full-sync.
A marker observed before that point wins: the worker emits
`cancel_requested`, restores or removes only attempt-owned unpublished state,
then emits terminal `cancelled`. At or after that point cancellation is too
late and the worker emits only terminal `succeeded` or `failed`.

Published cleanup uses durable phases `intent`, `tombstoned`, and `removed`.
Under the fixed operation/cleanup locks, the worker first persists and
full-syncs `intent` with the exact transaction, attempt, immutable
`event_model_key`, tuple, receipt, saved root locator/identity, final leaf,
reserved same-parent tombstone leaf, and expected byte and file totals. It
recomputes the keep set before rename and clears the intent if the target became
protected. The sole cleanup commit evidence is a durable, readback-validated
`tombstoned` phase record. A rename or parent barrier without a surviving valid
`tombstoned` final is precommit and reversible. A surviving valid phase final
after an interrupted phase rename is a conditional postcommit cancellation
fence: recovery must finish its exact barriers and readback before deletion or
terminal success.

Immediately before the exclusive final-to-tombstone rename, the worker retains
the operation/cleanup locks, takes `cancel.lock`, performs the final exact-marker
check, and holds `cancel.lock` without interruption across the rename,
successful `fsync` and `F_FULLFSYNC` of the shared `objects` parent, persistence
and full-sync of `tombstoned`, and readback validation of that phase. Only then
may it release `cancel.lock`. It subsequently descriptor-validates and removes
only the recorded tombstone contents and leaf, fully syncs the parent, persists
and readback-validates `removed`, clears the record, and refreshes inventory.
After the final cleanup state is durable it releases the cleanup lock while
retaining `operation.lock`. Only then may it take `failure.lock` followed by
`cancel.lock` to commit ordinary terminal/history state; it never holds the
cleanup lock and `failure.lock` together.

Cancellation wins whenever an exact marker is durable before the worker's
protected `tombstoned` publication, or before recovery when no valid
`tombstoned` final survived. A marker recorded after a valid `tombstoned` final
survives an interrupted publication does not reverse that phase, provided
recovery validates and rolls it forward under the rules below. Under `intent`,
if no rename occurred, the worker durably
clears the intent; if the final is absent and the tombstone is present, it
renames the descriptor-validated tombstone back to the exact final leaf, fully
syncs the parent, verifies restoration, and durably clears intent. It then emits
`cancel_requested` and terminal `cancelled`. Once `tombstoned` is durable,
cancellation is too late: the worker or recovery completes exact deletion and
emits `succeeded`, or retains recoverable state and fails with
`cleanup_failed`.

Published-cleanup recovery never scans or guesses and uses only the recorded
tuple, immutable event key, saved root locator/identity, final, and tombstone
identity. Recovery takes the operation lock, then the cleanup lock, then
`cancel.lock`, matching the worker's global order, and holds all three while it
mutates recovery state. A surviving `tombstoned` final, including one renamed
before an interrupted parent barrier/readback, takes precedence over a later
exact marker only after recovery validates the closed phase, exact transaction/
attempt/target, saved root locator/identity, and descriptor-observed target
state, completes both `fsync` and `F_FULLFSYNC` of the recorded object's parent
and the phase-record parent, and readback-validates the same phase and target
identity. Before any resumed deletion it MUST observe final absent and the
exact tombstone present; only then may it delete that tombstone. A barrier or
readback failure, conflicting phase, mismatched root or target, or
contradictory final/tombstone survival fails closed with no deletion or success
claim. If no valid `tombstoned` final survives a power loss, the existing
`intent` and exact-marker rules govern. With `intent`, final present and
tombstone absent means an exact marker clears intent and cancels; without a
marker, recovery rechecks
the keep set and resumes rename or clears protected intent. With `intent`, final
absent and tombstone present means an exact marker restores and fully syncs the
final and cancels; without a marker, recovery revalidates the tombstone, repeats
the parent barriers, durably commits and readback-validates `tombstoned`, and
resumes deletion. Both present or both absent fails closed. With `tombstoned`,
tombstone present resumes exact deletion; tombstone absent and final absent
fails closed without separately durable `removed` evidence, including after a
crash between successful deletion and `removed` publication; final present
fails closed. Such ambiguous recovery retains the phase, surfaces recoverable
`cleanup_failed` for operator reconciliation, and makes no success claim. With
`removed`, both absent permits record clear and any target present fails closed.
Recovery MUST
NOT report `cancelled` after durable `tombstoned` evidence.
Before recovery commits or compacts ordinary terminal/history state it must
durably readback-validate the applicable cleanup state, release the cleanup
lock while retaining `operation.lock`, and then acquire `failure.lock` followed
by `cancel.lock`. Recovery never holds a cleanup lock and `failure.lock`
together.

The direct cancel process takes `failure.lock` then `cancel.lock`. It validates
bounded active, history, failed-dispatch pending, marker, and cleanup phase
records solely to select the total acknowledgement predicate, and it may
durably remove a validated stale marker or create/readback-validate the current
exact marker as specified above. It MUST NOT mutate terminal/history or recovery
state; take an operation, cleanup, or adoption lock, control socket, or runtime
reservation; rename or restore a final or tombstone; repeat an object-parent
barrier; advance, clear, repair, or otherwise mutate a cleanup phase record;
delete an artifact; or emit an event. If a worker or recovery path holds either
required lock, the bounded cancel call waits only until its shared monotonic
deadline. A process that acquires the lock in time observes the
resulting phase; one that does not returns `busy` without mutation. After a
crash leaves `intent` with only the tombstone, a cancel process that obtains the
lock before recovery and before its deadline records the exact marker and leaves
recovery untouched; recovery then restores the final. If recovery obtains the
ordered locks first and sees no marker, it may complete the barriers and durable
`tombstoned` phase before releasing the lock, after which a new marker is
postcommit. These two successful lock acquisitions are the observable
linearization order; `busy` establishes no state order.
If a valid `tombstoned` final survived an interrupted phase publication, direct
cancel may still record an exact marker under the ordinary active-attempt
predicate, but the acknowledgement promises only marker durability; recovery
applies the postcommit phase precedence above and ignores that later marker.

Staging cleanup is separate and uses an attempt-owned recorded target plus the
same reversible `intent` to same-parent tombstone to `tombstoned` to `removed`
discipline inside the attempt's staging parent. Durable, readback-validated
`tombstoned` is its sole commit evidence. Its worker or recovery owns all phase
mutation under operation/cleanup-then-cancel lock order and holds `cancel.lock`
across the final marker check, rename, parent `fsync`/`F_FULLFSYNC`, and durable
phase commit. Its direct cancel process takes `failure.lock` then `cancel.lock`,
records the exact marker, and never mutates staging recovery state. A precommit
crash with a marker restores and preserves the staging root plus
`staging_cleanup_required`; the same state without a marker resumes and commits
cleanup. After durable `tombstoned`, cleanup or recovery removes only the
recorded tombstone and terminates `succeeded` or recoverable `cleanup_failed`,
never `cancelled`. A retry resumes the durable phase for the same identity and
MUST NOT create a second tombstone, delete published or legacy data, or turn
incomplete recovery into success.
The published-cleanup interrupted-phase rule applies equally to staging: a
surviving exact `tombstoned` final fences a later marker only after recovery
under `operation.lock`, the exact staging-cleanup lock, then `cancel.lock`
revalidates the closed phase, attempt, saved root, staging parent and recorded
target identities, completes that parent's and the phase parent `fsync` and
`F_FULLFSYNC`, and readback-validates the same phase and target. Deletion
requires final absent and exact tombstone present; any contradictory object or
phase survival, failed barrier/readback, or mismatched identity fails closed
without deletion or success. Direct cancel may record a marker per its active
predicate but cannot advance the phase; recovery ignores a marker later than
the surviving valid `tombstoned` final. If that final is absent after power
loss, the durable `intent` and marker rules apply. Under `tombstoned`, both
target leaves absent without separately durable `removed` evidence fails
closed, including after deletion but before `removed` publication; it retains
the phase, surfaces recoverable `cleanup_failed` for operator reconciliation,
and makes no success claim.
Before committing ordinary terminal/history state, the worker or recovery path
durably readback-validates staging cleanup state, releases the staging cleanup
lock while retaining `operation.lock`, and then acquires `failure.lock` followed
by `cancel.lock`; the cleanup and failure locks are never held together.

The supported cancellation-latency profile uses a monotonic start at completion
of the exact cancellation marker's parent full-sync, worker observation at its
validated marker read, transport cancellation at entry to
`URLSessionTask.cancel()`, and completion when terminal `cancelled` JSONL is
flushed. It applies only to a scheduled worker on supported Apple Silicon with
a local APFS authority/staging volume, in metadata or stalled-transfer phase,
with no publication or tombstone, at most 8 MiB across at most 16 staging files,
no injected syscall fault, every required sync completing within 250 ms, and no
harness-induced scheduler suspension. Under that profile marker observation
and entry to `URLSessionTask.cancel()` MUST occur within 250 ms plus a declared
50 ms measurement tolerance, and terminal `cancelled` MUST be flushed within
2.000 seconds of the start. Outside that profile only the 250 ms watchdog and
bounded-loop checks, heartbeat, action timeout, and truthful delayed-response
behavior are normative; the worker MUST never emit terminal state before
durable cleanup to meet timing. Tests MUST use an injected monotonic clock and
measure the marker barrier, validated observation, cancellation call, and
terminal flush separately.

The two-second cancel-lock acquisition deadline is separate from that worker
cancellation-latency profile. A `busy` acknowledgement creates no marker, so the
profile's start event does not occur. Slow or stuck tombstone durability may
therefore produce `busy` without weakening the continuous-lock interval or the
profile that applies after a marker is durably recorded.

**SPEC-044-R004 - Rate math display contract.** Malibu MUST display network catalog rates as rates, not income. Provider payout rates MUST be displayed in USD per 1,000,000 tokens, matching the schema field unit, with at least two significant figures and labels that distinguish prompt and completion rates when both are shown. When showing provider economics, Malibu MUST label them as provider share of catalog rates and MUST disclose that actual rewards depend on eligible demand, uptime, accepted requests, trust state, routing, token mix, settlement, and any active sanctions or probation. That variability disclosure MUST be persistently visible within the same scrollable container as rate-bearing rows, MUST NOT require hover, expansion, navigation, or a separate tooltip to be discovered, and MUST meet the same localization and screen-reader accessibility requirements as the rate labels themselves. Malibu MUST NOT display or imply a specific dollar amount attributed to a time period, including hourly, daily, weekly, monthly, annual, or "up to" projections. The UI MUST NOT show copy such as "earns", "guaranteed", "daily revenue", "hourly pay", "will pay", "potential earnings", "estimated daily", "up to $X/day", "average payout", "projected return", "higher-paying", or any absolute payout projection unless a later billing-owner spec defines a verified earnings forecast contract.

**SPEC-044-R005 - Provider-friendly ranking.** Malibu SHOULD sort and group rows to help providers discover better opportunities, using a deterministic order that prefers current model visibility first, then locally ready trusted provider completion payout rate, then recommended or high-demand models that fit the machine, then preparation-required rows, then blocked rows. Rows with incomplete trust or economics MUST be visible only with a standardized localized warning that includes the localized `economics_state` meaning and at least one localized row `warning_codes` value explaining the limitation. Non-actionable rows whose `disabled_reason` is null and whose row `warning_codes` array is empty MUST be hidden until the CLI can provide a testable reason. Any action with `available: true` constitutes a testable reason to show the row when the rest of the row satisfies this spec.

A v2 row with a valid locally motivated `prepare_model` action MUST remain
visible in `Needs preparation` regardless of its non-trusted economics state;
its ordering MUST ignore rate, payout, provider share, and demand fields.

The authoritative total row order is the following tuple, compared in order.
This R005 tuple is the sole row-ordering authority; no recommendation rank,
display name/id, localized comparison, or second bucket/ranking tuple may
precede, replace, extend, or break ties after it:

1. the R008 section rank `Current` = 0, `Ready` = 1, `Network catalog` = 2,
   `Needs preparation` = 3, and `Blocked` = 4, ascending;
2. `provider_completion_payout_usd_per_million_tokens`, descending, with null
   after every non-null value;
3. `demand_rank`, ascending, with null after every non-null value;
4. `supply_deficit_score`, descending, with null after every non-null value;
5. `demand_weight`, descending, with null after every non-null value;
6. `ready_provider_count`, ascending, with null after every non-null value; and
7. the unique canonical row identity, ascending by unsigned UTF-8 bytes.

Numeric values are compared by their validated JSON numeric value, without
localized formatting or string conversion. For any row whose `economics_state`
is not `trusted`, tuple components 2 through 6 are treated as null regardless of
carried disabled-context values; this includes every locally motivated row. The
canonical row identity is the tagged wire tuple (`candidate`, `candidate_id`)
when `candidate_id` is non-null, otherwise (`catalog`, `model_key`); tag and
value are separate UTF-8 byte strings, each prefixed by its unsigned 32-bit
big-endian byte length, with no Unicode or case normalization. The projection
MUST contain no duplicate canonical row identity.
A duplicate makes the entire projection malformed and forces the R008 static
fallback with no economics or action dispatch. Display names and locale-aware
comparison APIs MUST NOT participate in this order.

**SPEC-044-R006 - Action gating.** Malibu MUST expose immediate `Switch` only when the row names an exact CLI-supported `action_model_id`, the local artifact is verified present, the CLI reports the model fits, warm-swap is available, and the CLI returns a `switch_model` transaction. When warm-swap is unavailable but the model is verified local, fits, and the CLI returns a `switch_model_deferred` transaction, Malibu MAY expose a distinct restart-or-defer switch affordance that states serving will restart, drain, or resume under CLI control before the model changes. Malibu MUST expose `Prepare`, `Evaluate`, `Adopt`, or `Clean up` only when the CLI returns a typed transaction for that exact row. In the `model_catalog_economics.v1` envelope, any row with `action_model_id: null` MUST set every action object's `available` field to `false`, every action object's `transaction_kind`, `transaction_id`, and `action_timeout_seconds` to null, row `disabled_reason` to a nonempty value, and every unavailable action's `unavailable_reason` to a nonempty value. Malibu MUST treat any row that violates this invariant as non-actionable and display the generic unsupported warning rather than trusting the action object. Discovery-only legacy browse rows with null `action_model_id`, legacy `actionable: false`, or no available typed action MUST remain non-actionable in Malibu and MUST NOT be converted into SPEC-044 action rows by the app.

In v2 the R006 null-action invariant covers `cleanup_published` as well.
Published cleanup is available only for one exact reclaimable v3 object with
the required digest, known positive reclaimable bytes, available accounting,
no inventory overflow, and explicit provider confirmation. It is unavailable
for staging, legacy, current, configured current/draft, active/prepared
adoption, selected/active preparation, live-worker, serving-verification, and
different-root targets.

**SPEC-044-R007 - Preparation safety.** Any model preparation transaction shown by Malibu MUST require explicit provider confirmation, state the expected download/cache size and trust source, use a CLI-owned isolated staging directory, verify signed catalog identity before promotion, support cancellation before commit, clean or report resumable cleanup instructions for partial staging artifacts on cancel/failure, and leave the current serving model unchanged on failure. An `adopt_recommendation` transaction that downloads, caches, stages, promotes, or otherwise prepares model artifacts, or whose action object has non-null `estimated_bytes`, is a model preparation transaction for this requirement and MUST satisfy the same confirmation, staging, cancellation, cleanup, progress, and failure invariants as `prepare_model`. If the CLI cannot satisfy those preparation invariants for an unprepared recommended model, it MUST expose `prepare_model` first and keep `adopt_recommendation` unavailable until the model is locally ready. An `evaluate_model` transaction that downloads data, mutates local cache or configuration, prepares model artifacts, has non-null `estimated_bytes`, or has `action_timeout_seconds` greater than 10 seconds MUST satisfy the same confirmation, progress, cancellation, delayed-response, and failure-visibility invariants as preparation transactions; if it stages or promotes model artifacts, it MUST also satisfy the isolated staging, signed-identity verification, cleanup, and current-model-unchanged invariants for `prepare_model`. When `estimated_bytes` is non-null, the confirmation MUST display that estimate; when `estimated_bytes` is null, the confirmation MUST state that the size is unavailable before the provider confirms. For any preparation, cleanup, or long-running evaluation transaction with `action_timeout_seconds` greater than 10 seconds, the CLI MUST emit progress events at least every 10 seconds while active, including a stage label and either bytes completed/expected, percent complete, or an indeterminate but live heartbeat; Malibu MUST surface a live progress indicator and cancellation affordance while those events are current. Progress events are current for no more than 30 seconds after the last observed progress, heartbeat, or terminal event. If no progress or terminal event arrives within that 30-second window and `action_timeout_seconds` has not elapsed, Malibu MUST show a localized delayed-response state, keep the cancellation affordance prominently visible, and MUST NOT declare success until a terminal event and refreshed projection arrive. The CLI MUST emit warning code `staging_cleanup_required` when a partial staging artifact is detected at startup or after cancel/failure and cannot be automatically removed. When `staging_cleanup_required` is present, Malibu MUST surface a labeled cleanup affordance that invokes a CLI-owned `cleanup_staging` transaction when available, states estimated recoverable bytes when known, and MUST NOT delete staging files directly. Malibu MUST NOT start hidden downloads or mutate model symlinks directly.

`cleanup_staging` and `cleanup_published_artifact` are separate
transactions. The former cannot target published bytes; the latter follows the
v2 digest and keep-set rules and cannot target staging or legacy bytes.
Progress, cancellation, and terminal events for both come only from the
attached worker.

**SPEC-044-R008 - UX layout and state model.** Malibu MUST present model rows in stable sections that distinguish `Current`, `Ready`, `Network catalog`, `Needs preparation`, and `Blocked` states. Section headers MUST be localized display copy that follows R004/R009 and MUST NOT be rendered directly from enum names. Each row MUST show at least display name, fit state, approximate size when known, local readiness, provider completion payout rate when trusted, network demand signal label when trusted, and one primary action or disabled reason. Rows whose economics are not `trusted` MUST NOT appear in `Network catalog` based on stale, fallback, blocked, or unavailable rates; they MUST appear in `Needs preparation` when only local preparation blocks a non-money action, otherwise in `Blocked` or an equivalent warning subsection that may still contain explicitly read-only actions such as `Evaluate`. Rows with `fit: unknown` MUST NOT appear in `Network catalog` with an action available unless the confirmation dialog prominently states that hardware fit is unknown and the action is a read-only evaluation or preparation path that the CLI can reverse without changing the current serving model. Malibu MUST select v2, v1, or static fallback by the category-aware manifest-tier and flat-status trio matrix in R001. If no exact supported status trio has one complete correctly categorized matching manifest tier, including no supported
catalog-economics trio, or if the generation evidence contains any missing
member, partial, dual-generation, mixed-generation, category-misplaced,
unrecognized generation-namespace, or stale advertisement, or the matching
manifest tier is missing, the view MUST degrade to the existing static current-model
card with no error indicator, no retry affordance, no action or economics, and
no catalog-economics read, run, or cancel call. If and only if the CLI advertises
one valid complete flat-status trio with a matching manifest tier but the projection
request then fails, times out, or returns a malformed envelope, Malibu MUST show
the static current-model card with exact English source warning **model catalog
unavailable**, warning code `projection_unavailable`, and a retry affordance,
with no catalog action or economics.

For v2, a valid locally motivated preparation row belongs in `Needs
preparation`; it MUST NOT be placed in `Network catalog` from local custody
or non-trusted economics. The exact all-null catalog-only unavailable sentinel
from R002 belongs in `Blocked` and MUST NOT appear in `Network catalog`,
`Current`, `Ready`, or `Needs preparation`. Absence of any exact v2 trio member permits v1 only when
the exact v1 flat-status trio and complete v1 manifest tier are present; otherwise Malibu uses the
legacy fallback without attempting a catalog-economics call or v2 action.

**SPEC-044-R009 - Trust-preserving copy and localization.** All new Malibu strings for rates, potential, warnings, actions, and disabled reasons MUST be app-localizable, screen-reader accessible, and written as operator guidance rather than marketing. Warning copy MUST clearly distinguish "network catalog rate unavailable" from "model cannot be served" from "model needs preparation". Localization tests MUST cover the forbidden earnings-claim meanings from R004 in every shipped locale, not only the English source strings. Every shipped locale with right-to-left layout support MUST verify that row ordering, numeric rate labels, section grouping, and action buttons remain readable and navigable; if Malibu ships no right-to-left locale for this release, the release evidence MUST state that RTL is out of scope.

The exact English source verdict for `earning_path_class:
"settlement_capable"` is **Eligible to earn on qualifying settled requests**.
Every localization MUST preserve conditional eligibility and MUST NOT imply
current income, current serving, current demand, a guaranteed request, or a
guaranteed settlement. The verdict comes only from the valid owner-source
guidance binding and does not override R004's rate-versus-income rule.

The exact English source state meaning for `local_only` is **Retained as local
inventory only; this admission state does not claim the model is prepared,
installed, ready, reachable, or usable.** Any positive readiness or usability
copy requires independent validated readiness/runtime evidence for the same row
and projection. The exact English source meaning for
`local_default:not_offered` is **Coordinator offer state is unavailable or has
not been queried.** and MUST NOT assert that no offer has ever existed. The
exact English source meaning for `coordinator:not_offered` is **Coordinator
reports no active network offer for this model.** and requires authoritative
SPEC-047 readback. Every shipped localization and accessibility fixture MUST
preserve this source distinction.

The exact R002/R003 local, trusted, and published-cleanup English source
strings and deterministic localized size substitution are part of this
requirement.

**SPEC-044-R010 - Privacy and secret boundary.** The projection and Malibu UI MUST NOT expose provider bearer tokens, wallet secrets, private config paths, raw signed feed bytes, hardware serials, MAC addresses, stable hardware UUIDs, provider identity UUIDs, raw verifier transcripts, private model cache paths, or full coordinator authorization errors. The ephemeral `source.process_launch_id` UUID is permitted only inside the local CLI-to-Malibu projection protocol for ordering and reconnect handling; Malibu MUST NOT render it in provider-visible UI, and diagnostics MUST redact or omit it unless a later support spec defines an approved redaction format. Diagnostics MAY expose redacted feed identity, model key, CLI version, and reason codes sufficient for support.

The v2 storage object and cancellation acknowledgement MUST NOT expose root
or artifact paths, receipts, usernames, provider/config identities, attempt
state beyond the opaque attempt ID, or unbounded filesystem/error text. The
cleanup digest is opaque and MUST NOT be rendered.

**SPEC-044-R011 - Reconciliation after action.** After any switch, prepare, evaluate, adopt, or cleanup transaction completes, Malibu MUST refresh the CLI projection and reconcile the visible current model, readiness, rates, warning state, and staging cleanup state from the new projection before declaring success. If Malibu previously requested cancellation for a transaction and later receives a `succeeded` terminal event for the same `transaction_id`, Malibu MUST show a distinct localized disclosure that the cancellation request was received but the action had already committed before it could take effect. When a refreshed projection is available, Malibu MUST display the resulting outcome (such as model ready, switch pending, or cleanup completed) alongside that disclosure rather than presenting an unqualified success state. When the refreshed projection is not available, Malibu MUST keep that cancellation-too-late disclosure visible, state that the model state refresh is required and the outcome is not yet known, and surface warning code `projection_timeout` after the timeout bound rather than declaring a completed model change. If Malibu dispatches an available action and receives no terminal CLI event within the action's `action_timeout_seconds`, Malibu MUST show failed or needs-attention state with warning code `projection_timeout`. If Malibu receives a terminal CLI event without a matching refreshed projection, Malibu MUST show pending for no more than the shorter of 30 seconds after the terminal event and the time remaining before `action_timeout_seconds` elapses from the original action dispatch; after that bound, Malibu MUST show failed or needs-attention state with warning code `projection_timeout`, not a completed model change. If a refreshed projection later arrives after Malibu has shown `projection_timeout`, Malibu MUST update the model-state display from that projection, clear the `projection_timeout` warning, and, when a cancellation-too-late disclosure was shown for the same transaction, keep that disclosure visible with the resolved state rather than replacing it with unqualified success.

A cancel acknowledgement with `recorded` or `already_recorded` proves only
marker custody. Malibu MUST continue consuming the attached worker's event
stream and MUST NOT render cancellation complete until that worker emits
terminal `cancelled`; `terminal`, `not_active`, and `stale` likewise
require a fresh projection before Malibu represents current artifact state.
`busy` proves only that the cancel process did not acquire both `failure.lock`
and `cancel.lock` within the one total 2.000-second monotonic deadline. Malibu
MUST allow at most one live cancel subprocess
per transaction, coalesce or disable repeated cancel triggers while it is live,
and release every process/pipe resource after acknowledgement and exit. It MUST
NOT represent the transaction as cancelled and MAY issue a later distinct
cancel call while it continues the one attached worker stream and projection
reconciliation.

**SPEC-044-R012 - Release evidence.** A Malibu release that enables this experience by default MUST include automated tests assigned to the following acceptance lanes; an unassigned generic test claim is insufficient:

- **CLI projection/unit lane:** exact schema closure; 256-bit root-nonce and at
  least 128-bit process-launch/122-bit transaction/attempt CSPRNG construction;
  process restart/sequence reset; live/static/missing signature trust; exact
  rate-card and owner-source freshness boundaries; generated-at and feed-set
  mismatch; provider-share, prompt/completion catalog-rate, payout, demand, and
  ranking calculations; candidate/guidance all-or-none catalog-only handling;
  coordinator `not_offered` with and without a durable event; row warning-code
  attribution; and every preparation/action eligibility gate.
- **Malibu model/UI/accessibility lane:** strict Swift decoding; app-owned
  refresh-generation ordering for both A/B completion orders and CLI restart;
  refresh timeout and action dispatch between replies without terminating the
  action worker; provider-share/rate/demand rendering; deterministic ranking
  when trusted and rate-neutral ranking when not trusted; section grouping;
  catalog-only non-trusted display; immediate/deferred switch, Prepare, Evaluate, Adopt,
  staging cleanup, and published cleanup gating; confirmation and disabled
  copy; progress/reconciliation; localization; screen readers; and every
  shipped RTL locale.
- **Built-CLI/production-adapter integration lane:** exact category-aware
  manifest-tier/flat-status trio compatibility matrix, read/run/cancel grammar and exit status, bounded read
  and acknowledgement stdout, incremental JSONL with arbitrary chunks and
  overlong no-newline input, 65,536-byte stderr truncation/drain, sustained
  maximum event rate, fixed 64-event delivery capacity/coalescing/backpressure,
  direct-cancel `busy` after the shared failure-then-cancel two-second monotonic
  deadline with bounded repeated waiters; exact pre-attachment
  `dispatch_state_busy` stderr/no-event/exit-5 handling for failure-only and
  operation-owning pre-active acquisition; and exact built-CLI stdout/stderr
  through Malibu's production adapter.
- **Filesystem/recovery/security lane:** root locator and digest construction,
  copied/rebound/remounted roots, preparation and both cleanup state machines,
  orphan historical event correlation, bounded storage accounting, and the
  descriptor/ACL race matrix below.
- **Signed journey lane:** production journey-result evidence governed by
  `requires_signed_journey_result` proving that an old CLI receives static
  fallback and a compatible CLI renders trusted rates without secrets or
  unsupported actions, with the provider-visible provider-share/rate/demand,
  ranking, action-gating, cancellation, and reconciliation outcomes captured.

For v2 the R012 evidence also MUST cover exact read/run/cancel grammar and exit
status, one exact flat-status generation trio with a matching manifest tier,
strict v2 decoding, every
preparation-matrix branch, exact and localized action copy, event code/state
closure, worker-only sequencing, all six cancellation-ack outcomes and races,
storage nullability and bounds, 255/256/idempotent/257 object admission,
managed-budget/free-space refusal, legacy accounting/protection, digest-bound
published cleanup, bounded complete cleanup-target reachability, and the
absence of automatic garbage collection.

Published-cleanup tests MUST positively compare `row.cleanup_published` with
the matching `cleanup_targets[i].cleanup` as UTF-8 RFC 8785 JCS bytes and then
independently compare both action digests and exact logical byte counts with the
enclosing target. Distinct one-fault fixtures MUST independently change (1) the
enclosing target `artifact_identity_digest`, (2) the enclosing target
`estimated_bytes`, (3) `row.cleanup_published.artifact_identity_digest`, (4)
`cleanup_targets[i].cleanup.artifact_identity_digest`, (5)
`row.cleanup_published.estimated_bytes`, (6)
`cleanup_targets[i].cleanup.estimated_bytes`, (7) transaction kind in each
nested action copy, (8) transaction id in each nested action copy, and (9) every
other action field in each nested action copy, one field at a time. Two further
fixtures MUST change both nested action copies to the same new
`artifact_identity_digest`, and then to the same new `estimated_bytes`, while
leaving the enclosing target unchanged. Those fixtures preserve action-to-action
JCS equality and therefore prove each copy is independently checked against the
enclosing target. A separate
fixture MUST move an otherwise valid action, unchanged, to another target.
Every fixture MUST be refused before provider confirmation, reservation,
rename, or deletion, with outside-root, protected-object, and legacy sentinels
unchanged.

The release test corpus MUST additionally prove all of the following exact
boundaries:

- launch the built CLI and route its exact stdout, stderr, and exit status
  through Malibu's production process adapter and strict decoder for v1 and v2
  reads, every terminal run outcome, all six cancellation acknowledgements,
  partial/chunked JSONL, malformed-v2 negatives, and byte-exact compatibility
  fixtures for current manifest/current v1 status, new Malibu/old v1 CLI,
  current Malibu/new v2-only CLI, and new v2 manifest/status. The negative
  matrix MUST remove each trio member one at a time; add one opposite-generation
  member; misplace each manifest member into the other category; exercise both
  complete generations and every mixed-generation set in flat status or one
  tier; inject one unrecognized value under each of
  `model_catalog_economics_v`, `models catalog-economics.v`, and
  `model_catalog_economics.v`; make status stale; remove the matching manifest
  tier; and disagree across surfaces in both directions. Unrelated capabilities
  and schemas outside those namespaces MUST leave valid selection unchanged.
  For every negative prove the static
  current-model card, no error indicator, no retry, and zero read/run/cancel
  calls. For each valid matching trio separately inject projection failure,
  timeout, and malformed output and prove exact **model catalog unavailable**,
  `projection_unavailable`, retry, no action, and no economics. Prove
  old-Malibu/new-v2-CLI static fallback,
  new-Malibu/old-v1-CLI v1 read, exactly one read for each supported
  matching trio, and zero catalog-economics calls for every negative;
- reject unknown or mismatched `candidate_id`, guidance-source fields/digest,
  owner-spec guidance fields/enums, admission correlation, coordinator event,
  state timestamp, future source time, and the 300-second freshness boundary;
  exercise every matrix branch with verbatim SPEC-046/SPEC-047 guidance and
  prove guidance renders first. Accept all-null candidate/guidance/binding only
  for a true catalog-only row and require the exact sentinel:
  `runtime_state: "catalog"`, null `action_model_id`,
  `economics_state: "unavailable"`, `rate_source: "none"`, admission
  `source: "local_default"` plus `state: "not_offered"`, null
  `coordinator_event_id` and `state_observed_at`, false
  `catalog_economics_permitted` and `settlement_capable`, all nullable
  rate-card/rate/share/payout fields null, all demand fields null, every action
  unavailable, no earning or readiness claim, and exact placement in `Blocked`.
  Reject placement in `Network catalog`, `Current`, `Ready`, or `Needs
  preparation` as distinct one-fault section changes. Apply one-fault negatives for
  every other known or unknown economics state, rate source, admission source or
  state, non-null event or observation time, either authorization boolean set
  true, any non-null money/demand field, non-catalog runtime state, non-null
  `action_model_id`, any non-null member of the
  candidate/guidance/binding group, or any available action, including with a
  valid signed rate row or an unrelated coordinator admission event. Reject
  every partial-null combination, every attempted
  model-key/display-name/served-name/cross-candidate admission join, and every
  candidate/local-action row with the group absent;
- exercise `local_default:not_offered`, `coordinator:not_offered`, and both
  source-transition directions under every economics class; require the exact
  R009 source meanings and reject any local-default offer-history assertion;
  test primary
  artifact status `verified`, `declared`, `blocked`, absent, and each signed-feed
  drift boundary, proving only current `verified` is eligible at projection and
  dispatch and remains eligible at the immediate prepublication recheck. For
  coordinator `not_offered`, test both an exact event-backed response and the
  authoritative explicit-null-event response; reject null for every other
  coordinator state and reject any no-event row with a candidate/source/digest,
  timestamp, state, or guidance mismatch;
- retain `offer_rejected` in the 12-value closed admission decoder, then inject
  only synthetic current `coordinator:offer_rejected` inputs with both a null
  event id and a claimed syntactically valid event id, each economics class,
  and even otherwise valid signed artifact, fit, and storage prerequisites.
  Every case MUST remain an inconsistent, non-actionable row with
  `economics_state: "unavailable"`, `rate_source: "none"`, both admission
  authorization booleans false, all nullable rate-card/rate/share/payout and
  demand fields null, and all actions unavailable. One-fault mutations of each
  forbidden field or action MUST fail closed in Malibu; require no Prepare,
  authoritative rejection, paid admission, trust, pricing, or earning copy and
  no synthesized coordinator event. Reprove valid `local_default:not_offered`
  and authoritative `coordinator:not_offered` preparation positives separately;
- table-test the in-lock cancellation-ack predicate precedence under concurrent
  active, ordinary terminal, failed-dispatch pending/history, projected,
  exact-marker, mismatched-marker, and new-attempt states, including transaction
  echo and exact attempt nullability. Direct cancel MUST trace
  `failure.lock` then `cancel.lock` under one injected `CLOCK_MONOTONIC_RAW`
  deadline. Exercise acquisition immediately below and exactly at 2.000 seconds
  for contention on the first lock and on the second after the first is held.
  At expiry require release of any partial lock, exact `busy` with null attempt,
  exit 0, no state read, no marker/history/phase mutation, and fixed waiter/task/
  descriptor/memory counts under sustained arrivals. After timely acquisition,
  prove the process performs only bounded predicate reads and exact-marker
  create/removal; it takes no operation, cleanup, adoption, socket, or runtime
  authority and never performs history compaction or recovery;
- race cancel, crash, recovery, and retry at rename, after each parent barrier,
  before/during/after durable phase persistence, and before and after every
  preparation, published-cleanup, and staging-cleanup commit phase. Inject a
  crash after the parent barrier but before durable `tombstoned`, then prove a
  marker recorded before recovery restores the final when no `tombstoned` final
  survived, while a surviving exact `tombstoned` final fences a later marker
  only after recovery revalidates phase/root/target and completes both parent
  `fsync`/`F_FULLFSYNC` barriers and readback. Prove both published and staging
  recovery fail closed on mismatched or contradictory final/tombstone state,
  failed barriers/readback, and both target leaves absent without separately
  durable `removed` evidence; report `cleanup_failed`, retain the phase for
  operator reconciliation, and claim no deletion or success. Prove worker and
  recovery hold operation-then-cleanup-then-cancel across final marker check,
  rename, barriers,
  and durable phase commit; after durable cleanup state they release cleanup
  before acquiring operation-then-failure-then-cancel for terminal/history
  compaction. Prove cleanup and failure locks never overlap. A live cancel cannot
  acquire `cancel.lock` inside the protected interval; the only marker race after
  rename/barrier and before `tombstoned` follows a crash that released the locks;
  lock availability alone must not be used as proof of interruption;
- table-test the exit-3 pre-work lifecycle after valid immutable action identity.
  For stale, unavailable, and conflict, require a fresh attempt and one durable
  closed `model_catalog_failed_dispatch.v1` record with the exact transaction/
  kind/event-key/root/tuple/projection binding, sequence 1, matching failure code,
  and `live_attempt: false` before exactly one terminal failed event and exit 3.
  A failure-only path traces `failure.lock` then `cancel.lock` under one total
  two-second deadline. A pre-active path holding `operation.lock` has one new
  total two-second deadline to acquire `failure.lock` then `cancel.lock`. At
  either deadline, require all locks/resources released, exact single stderr
  line `{"error_code":"dispatch_state_busy"}` plus LF, empty stdout, exit 5,
  no event, actionable Malibu retry without terminal inference, and zero durable,
  state, network, staging, model, adoption, runtime, or incumbent mutation;
- inject reads between every failed-dispatch unique-temp sync, atomic rename,
  parent full-sync, readback, replacement-history publication, deterministic
  eviction, pending publication/unlink, and recovery step. Prove writers hold
  `failure.lock` then `cancel.lock` for the entire transition, history is
  published before pending unlink, crash duplicates deduplicate by identity, and
  no durable terminal exists in neither place. Whenever the failed dispatch is
  durable in pending or history at the cancel linearization point, direct cancel
  must return only `terminal` with the exact attempt and create no marker. Cover
  crash before pending rename (temp only), after final rename but before each
  parent barrier/readback, after durable record and before event flush, after
  event flush and before later compaction, and during compaction; require bounded temp
  recovery, idempotent history compaction, no fabricated stdout, and no work
  replay. For a surviving exact pending final, require direct cancel under
  `failure.lock` then `cancel.lock` and startup under all three locks to finish
  its parent barriers/readback before terminal inference; test a retired
  projected reservation and matching history copy, mismatch and barrier fault,
  exact exit 5/no acknowledgement/no marker on direct-cancel failure, and no
  replayed stdout. Exercise all cancel-visible final records, especially
  `cancel.json`, active, history, and reservation, at final rename before
  barriers/readback: valid finals may support acknowledgements only after exact
  validation and their own parent barriers/readback; temp-only does not.
  Saturate and evict across the shared 256-record/262,144-byte cap;
- run deterministic lock-trace tests for projection-reservation writers,
  failure-only creation/compaction/eviction, pre-active/live active creation,
  ordinary terminal/history compaction, startup and failed-dispatch recovery,
  direct cancellation, published cleanup, staging cleanup, and adoption. Exercise
  every pairwise overlap and assert the exhaustive permitted orders exactly:
  operation-failure-cancel, failure-cancel, the periodic read-only
  operation-cancel path, operation-cleanup-cancel, and operation-adoption-
  socket-runtime. Assert exact reverse releases and the
  cleanup-to-terminal release/reacquire boundary, no other nested order, no
  cleanup/failure overlap, no lock held across stdout, no reverse acquisition or
  deadlock, bounded fail-closed resources under continuous arrivals, no second
  live attempt, no cancellation marker for failed dispatch, and no incumbent
  displacement. Do not claim or infer scheduler fairness or starvation freedom;
- inject volume capacities immediately below, at, and above the default
  1-TiB/70-percent crossover and non-divisible capacities; test checked
  overflow; YAML-only, environment-only, and both-source precedence; reject
  zero, negative, non-integer, and greater-than-1-TiB overrides; assert
  `managed_budget_source`; and test physical free space one byte below, exactly
  at, and one byte above `2 * estimated_bytes + 1073741824`;
- exercise descriptor-relative logical accounting for regular files,
  directories, receipts, metadata, hard links, symlinks, sparse files, special
  files, APFS clones/compression, cross-device configured legacy, every checked
  sum boundary, and physical-free-space divergence. Prove root nonce entropy,
  exact canonical digest construction over nonce, version, path, device, and
  inode; lifecycle locator persistence and restart after configuration drift;
  descriptor revalidation; copied records with rewritten metadata; rebound path,
  remount/device change, inode reuse, path replacement, restoration of the
  original descriptor, and that projected digests reveal no
  path/device/inode/identity value. Create each sensitive node under an inherited
  ACL and prove inheritance is stripped before publication; reject every
  existing extended ACL and inject post-validation ACL mutation and descriptor
  replacement before each authority use. For every newly created sensitive
  node, prove the owner-only temporary entry is already open but unpublished,
  inherited ACLs are stripped and verified empty through its descriptor before
  the first sensitive byte, and descriptor identity plus empty ACL are
  revalidated before publication/use; on failure prove only the newly created
  empty object is removed. When configured-legacy
  accounting is unavailable, assert Prepare is unavailable, stale direct
  dispatch refuses before network/staging, published cleanup is unavailable,
  affected fields have the required nullability, and incumbent serving is
  unchanged;
- prove `cleanup_targets` contains every verified managed object exactly once
  in digest order at 0, 1, 255, and 256 objects; prove protected targets are
  disabled, every reclaimable orphan without a current catalog row remains
  reachable, row/target duplicates are identical and de-duplicated, and
  malformed/257-entry inventories fail closed. Run an orphan target with its
  immutable historical `event_model_key` through success, cancel, crash
  recovery, retry, and the built production adapter, and reject missing or
  mismatched event keys in its receipt/reservation/events; and
- property-test size formatting at 1 byte, 99,999,999 bytes, every exact
  100,000,000-byte boundary and boundary plus one through 1 TiB, across locales
  including non-Latin digits. The displayed preparation size MUST never
  understate `estimated_bytes`, and cleanup action `estimated_bytes` MUST equal
  the descriptor-measured logical bytes. Exercise the frozen cancellation
  profile on supported Apple Silicon and local APFS in metadata and
  stalled-transfer phases, with its exact file/byte, sync, fault, and scheduler
  predicates; assert observation and cancel-call entry within 300 ms (the
  250-ms contract plus exactly 50 ms measurement tolerance) and terminal flush
  within 2.000 seconds. Exercise flowing transfer, verification, copy,
  publish-ready, large cleanup, scheduler starvation, injected faults, and slow
  barriers only under the functional watchdog/loop, heartbeat, action-timeout,
  delayed-response, and no-premature-terminal requirements. Table-test
  simultaneous failures across
  every adjacent event-error precedence class and assert the exact error code,
  terminal state, exit status, and unchanged side-effect boundary. Stream
  sustained valid events at the maximum permitted rate through arbitrary UTF-8
  chunk boundaries, then test one-byte-overlong partial input without newline,
  unbounded attempted stdout/stderr, slow MainActor delivery, queue saturation,
  progress coalescing, terminal-slot preservation, and producer backpressure;
  assert memory remains bounded and pipes reach EOF without one task per line.
  Permute equal-display-name rows across multiple locales and input/feed orders;
  cover null and equal payout/demand fields, duplicate rate/demand values, the
  bytewise canonical-identity tie-break, and duplicate canonical identities.
  Assert identical total order in every locale and fail-closed static fallback
  for a duplicate identity.

## 4. Implementation, tests, and journeys

The intended implementation is a CLI-first projection, then an app-only presentation layer:

1. Preserve the exact SPEC-001-R003 read/run/cancel forms under `models catalog-economics`; do not add aliases or a transaction-status command.
2. Make a v2-serving CLI advertise exactly `model_catalog_economics_v2`, `models catalog-economics.v2`, and `model_catalog_economics.v2` in flat local status while omitting all three v1 generation values; retain the complete v1 manifest tier and add a separate v2 tier with the selection capability in `local_status_capabilities` and the command token plus schema companion in `command_schemas`.
3. Extend Malibu model management decoding with a new envelope while keeping the current `models_list.v1` and browse behavior as fallback paths.
4. Replace the static switcher modal with a sectioned catalog view that supports current, ready, network-catalog, preparation-required, and blocked rows.
5. Wire only CLI-owned typed transactions into action buttons; all other rows are informational.
6. Add post-action refresh and failure reconciliation so the UI never declares a model change from a stale terminal event alone.

The first journey id is `JOURNEY-MALIBU-MODEL-ECONOMICS`. The journey should cover a current static qwen3-8b install, a compatible CLI with trusted live or static rates, a stale/mismatched feed set, an uninstalled catalog model with a trusted provider payout rate, a verified locally ready model, an unsupported browse-only model, and an old CLI fallback.

## 5. Open gaps

| Requirement/domain | Verdict | Owner | Issue | Evidence needed |
|---|---|---|---|---|
| `SPEC-044-R001..R012` | `DECISION_REQUIRED` | `@Augustas11` | `#614` | Implement the approved v0.2.10 projection, category-aware compatibility negotiation, transaction, failed-dispatch, cancellation, preparation-copy, cleanup, and accounting authority; then decide promotion only after automated tests and signed release evidence. |
| `malibu-model-economics-ux` | `DECISION_REQUIRED` | `@Augustas11` | `#614` | Implement the operator-approved CLI-owned projection and Malibu rendering without app-side feed verification; production enablement remains an operator decision. |
| `SPEC-046/SPEC-047 integration` | `DECISION_REQUIRED` | `@Augustas11` | `#1240` | Approval that SPEC-044 is narrowed to network economics and does not own provider-local BYOM discovery or network admission. |

## 6. Evidence

Current implementation evidence predates the v0.2.10 Build 1 authority and is
partial and non-conformant:

- `phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift` already capability-gates model management and classifies current, ready, preparation-required, and blocked rows, but its row schema does not carry rate-card economics.
- `phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagementViews.swift` already has a model switcher modal and recommendation copy surface, but it mostly renders the current autotuned model and disabled advisory actions.
- `phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift` already emits `models_list.v1` with verified local artifact checks.
- `phase3-binary/Sources/macprovider-cli/ModelsBrowseCommand.swift` already emits discovery-only browse rows with null actions and non-actionable state.
- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift` already loads signed candidate, demand, and rate-card feeds and projects rate signals for recommendations.
- `phase5-gateway/internal/router/public_feeds.go`, `phase4-coordinator/internal/buyer/autotune_feeds.go`, and `phase4-coordinator/internal/buyer/rate_card.go` already expose and verify rate-card feed material used by the CLI path.

No requirement becomes conformant from this authority amendment. The v2
projection, worker/cancel behavior, UI, tests, and signed journey evidence must
still land.

Issue #1240 records the direction change that SPEC-044 is a network economics UX contract, not the only source of Malibu model discovery.

## 7. Current contract notes

The desired provider copy is comparative and bounded: "Provider share rate", "Fits this Mac", "Needs preparation", "Catalog rate unavailable", and "Network demand signal" are acceptable labels. "Earn $X/day", "best paying", "guaranteed payout", and "serve this to get paid more" are not acceptable labels.

The `Network catalog` section is a discovery lane, not a promise that traffic will arrive. A high-rate model may still be disabled because it does not fit, lacks local verified weights, has stale economics, lacks enough demand, fails trust state, or has no safe CLI transaction.

The selection capability `model_catalog_economics_v1` and schema discriminator `model_catalog_economics.v1` are intentionally different strings: the capability selects the generation, while the schema value identifies the JSON envelope and is also a required compatibility companion in the manifest and flat status. The companion never selects a generation alone.

The current Malibu recommendation path may remain as a companion callout, but the catalog view must not require a recommendation run to show signed rates for supported models. Recommendation scores can rank rows only when the feed set is trusted and the CLI marks the signal current.

The app should preserve the current provider mental model: Malibu observes and asks the signed CLI to do work; the CLI owns custody, model artifacts, feed validation, update/recovery, admission, and billing-derived economics.

## 8. Changelog and history

- 0.2.10 - Aligns Build 1 preparation with SPEC-047 v0.1.9: the closed decoder
  still recognizes `offer_rejected`, but no v0.2 coordinator origin can append
  it. A current coordinator row claiming that state is inconsistent and cannot
  authorize Prepare, paid admission, trusted/priced economics, or any action;
  the valid local and coordinator `not_offered` paths remain eligible under
  their existing prerequisites. Synthetic negative fixtures prove the boundary
  without inventing a coordinator event. Conformance remains pending.
- 0.2.9 - Closes the interrupted-final-rename gap: exact surviving cancel-visible
  finals require parent barriers and readback before a direct-cancel claim;
  failed-dispatch pending may roll forward without stdout replay; and published
  or staging `tombstoned` finals conditionally fence later cancellation only
  after exact recovery validation and barriers. Contradictory or ambiguous
  cleanup state fails closed, including the deletion-before-`removed` crash
  window, which requires operator reconciliation. Conformance remains pending.
- 0.2.8 - Resolves the formal v9 authority finding by freezing distinct
  manifest-category and flat-status grammars for the shipped three-value v1
  advertisement and future v2 trio; the projection-schema companion remains
  required without becoming a generation selector; unknown-value fatality is
  limited to three exact generation namespaces; separate v1/v2 manifest tiers
  preserve staged app/CLI upgrade compatibility; and byte-exact fixtures cover
  each member removal, addition, category misplacement, stale/cross-surface
  disagreement, unrelated values, and both upgrade orders. Conformance remains
  pending.
- 0.2.7 - Resolves the formal v7 authority findings: one exhaustive lock graph
  governs projection publication, failure-only processing, normal and recovery
  state, direct cancellation, cleanup, and adoption; all cancel-visible failed-
  dispatch state uses failure-then-cancel serialization; direct cancel and pre-
  attachment run paths have one total two-second monotonic deadline and exact
  fail-closed outcomes; terminal pending/history movement is copy-before-delete
  with a precise cancel linearization point; and release tests cover every lock
  trace, pairwise overlap, durability interleaving, and sustained-arrival bound.
  Conformance remains pending.
- 0.2.6 - Resolves the formal v6 authority findings: every malformed or stale
  catalog-economics advertisement uses the silent no-call static card while
  failures after a valid exclusive pair use the exact unavailable warning and
  retry; exit-3 stale, unavailable, and conflict results use a bounded non-live
  failed-dispatch record and terminal event under a separate failure lock;
  current cross-spec references select v0.2.6; and cleanup acceptance mutates
  each action copy independently plus both copies together against an unchanged
  enclosing target. Conformance remains pending.
- 0.2.5 - Resolves the formal v5 authority findings: one exact readiness-safe
  `local_only` source string; distinct truthful local-default and coordinator
  `not_offered` meanings; exact `Blocked` placement for the catalog-only
  unavailable sentinel with four forbidden-section negatives; and distinct
  enclosing/action/cross-target destructive-cleanup fault proofs. Conformance
  remains pending.
- 0.2.4 - Corrects the formal v4 authority findings: R005 remains the sole
  exact row-ranking tuple; catalog-only acceptance locks every exact null/false
  sentinel field; local-only copy is admission-only; published cleanup compares
  the row action to the target's nested action under UTF-8 RFC 8785 JCS and
  separately binds the enclosing digest and size; and the closed admission
  inventory is consistently 12 values. Conformance remains pending.
- 0.2.3 - Corrects the formal v3 authority findings: conditional
  settlement-eligibility copy; catalog-only all-null rows remain non-trusted;
  descriptor-first ACL clearing before sensitive writes; a two-second monotonic
  cancel-lock deadline and `busy` acknowledgement; a complete locale-independent
  total ranking order with duplicate rejection; and constructible post-crash,
  continuous-lock cleanup races. Conformance remains pending.
- 0.1.0 - Initial draft. Defines CLI-owned model catalog economics projection, provider-safe rate display, preparation/switch action gates, stale-feed behavior, privacy boundary, and release evidence for a friendlier Malibu model selection experience.
- 0.1.1 - Draft amendment for issue #1240. Narrows SPEC-044 to network-eligible economics and delegates provider-local BYOM discovery/admission to SPEC-046 and SPEC-047.
- 0.2.0 - Operator authority for Build 1. Freezes the catalog-economics
  read/run/cancel grammar, compatible v2 projection and storage accounting,
  exhaustive local/trusted preparation matrix and copy, worker-only event and
  cancellation acknowledgement contracts, and distinct provider-confirmed
  published-artifact cleanup. Conformance remains pending.
- 0.2.1 - Corrects the Build 1 authority gate: exclusive v1/v2 advertisement;
  exact SPEC-046/047 guidance correlation and freshness; coordinator
  `not_offered`; verified-artifact eligibility; total cancel acknowledgement
  precedence; cleanup commit/recovery rules; descriptor-relative logical byte
  accounting and truthful copy; complete bounded cleanup targets; and exact
  release-test boundaries. Conformance remains pending.
- 0.2.2 - Closes the formal v2 authority review: complete cross-surface
  advertisement pairs; exact coordinator no-event binding; all-or-none
  catalog-only guidance; authenticated and externally locatable root identity;
  immutable orphan event keys; worker/recovery-owned tombstone linearization;
  app-owned refresh generations; bounded JSONL transport; deterministic macOS
  ACL rejection; and acceptance-lane release tests. Conformance remains pending.

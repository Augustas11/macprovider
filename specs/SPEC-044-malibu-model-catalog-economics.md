# SPEC-044 - Malibu Model Catalog Economics

**Version:** 0.2.1

```json
{
  "spec_id": "SPEC-044",
  "title": "Malibu Model Catalog Economics",
  "version": "0.2.1",
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
    "rationale": "The operator-owned v0.2.1 authority defines the corrected Build 1 preparation, cancellation, published-cleanup, guidance-correlation, and storage-accounting contracts. Implementation, complete tests, signed release evidence, and the discovery/admission/settlement journeys remain pending."
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

**SPEC-044-R001 - CLI-owned economics projection.** Malibu MUST obtain model economics, network readiness, trust state, and actions from an installed, signed `malibu-cli` projection. The v1 envelope is advertised only by the complete pair `model_catalog_economics_v1` and `models catalog-economics.v1`; the Build 1 preparation/storage envelope is a breaking extension advertised only by the complete pair `model_catalog_economics_v2` and `models catalog-economics.v2`. Advertisement is exclusive: a CLI serving v2 MUST omit both v1 values, a CLI serving v1 MUST omit both v2 values, and a CLI MUST NOT advertise both generations or only one value of either pair. Malibu MUST select v2 only for the complete v2 pair, otherwise v1 only for the complete v1 pair, and otherwise the legacy static fallback without invoking `models catalog-economics`; it MUST treat dual or partial advertisement as malformed. Thus an old Malibu paired with a new v2-only CLI makes no catalog-economics call, and a new Malibu paired with an old v1-only CLI requests only v1. A v1-only client MUST retain its existing fallback and MUST NOT invoke v2 run/cancel forms; a v2-serving CLI MUST NOT send a v2 envelope to a client that did not negotiate the exact v2 pair. Malibu MUST NOT fetch coordinator rate feeds, parse static feed files, verify feed signatures, compute billing rates from raw feed bytes, derive action eligibility from app-local heuristics, or present a SPEC-046 discovered candidate as a network economics row unless SPEC-047 admission state permits that presentation. Locally motivated preparation under R002/R003 is permitted only as a non-economics local-readiness action and MUST preserve the candidate's authoritative admission and earning disclosures.

**SPEC-044-R002 - Versioned row schema.** The CLI projection MUST emit a closed, versioned JSON envelope with `schema: "model_catalog_economics.v1"`, a wall-clock RFC3339 `generated_at`, a monotonic unsigned integer `projection_sequence`, a `source` object identifying the CLI build and feed provenance, an array of rows, and a projection-level `warnings` array. The v1 `source` object MUST include `cli_version`, `cli_build_commit`, `process_launch_id`, `process_started_at`, `projection_protocol_version`, `rate_card_source`, nullable `rate_card_digest`, nullable `rate_card_signature_digest`, nullable `demand_feed_digest`, nullable `candidate_feed_digest`, and `rate_card_max_age_seconds`; `process_launch_id` MUST be a lowercase hyphen-separated UUID v4 string generated fresh on CLI process start from at least 128 bits of CSPRNG entropy and MUST NOT be derivable from a PID, host serial, MAC address, host UUID, provider id, wallet, username, or any other hardware or identity value. `source.rate_card_source` MUST use the same closed enum as row `rate_source`: `live_signed`, `static_signed`, or `none`. `projection_sequence` MUST increase within a single CLI process for each newly generated projection and MAY reset after CLI restart; callers MUST use it only to order projections that have the same `source.process_launch_id`. When Malibu observes a new `source.process_launch_id`, it MUST treat the projection as a new CLI session, reset its ordering baseline, discard older in-flight projection ordering comparisons, and show a brief reconnecting or refreshing state before rendering the new projection. Each row MUST include model identity (`model_key`, `served_model_id`, `display_model_id`, nullable `action_model_id`), local state (`is_current`, `weights_present_locally`, `runtime_state`, nullable `estimated_gb`, `fit`, nullable `disabled_reason`, `warning_codes`), admission state (`admission`), economics (nullable `rate_card_version`, nullable `rate_card_generated_at`, nullable `rate_card_key`, `rate_source`, nullable `prompt_rate_usd_per_million_tokens`, nullable `completion_rate_usd_per_million_tokens`, nullable `provider_share_bps`, nullable `provider_prompt_payout_usd_per_million_tokens`, nullable `provider_completion_payout_usd_per_million_tokens`, `economics_state`), demand signals (nullable `demand_rank`, nullable `demand_weight`, nullable `ready_provider_count`, nullable `supply_deficit_score`), and actions (`switch`, `prepare`, `evaluate`, `adopt_recommendation`, `cleanup_staging`) as explicit objects with `available`, `requires_confirmation`, nullable `transaction_kind`, nullable `transaction_id`, nullable `action_timeout_seconds`, nullable `estimated_bytes`, and nullable `unavailable_reason`. The row `admission` object MUST include `state`, `source`, nullable `coordinator_event_id`, nullable `state_observed_at`, `catalog_economics_permitted`, and `settlement_capable`; `source` is `local_default` or `coordinator`, `state` MUST use the SPEC-046/SPEC-047 admission-state enum, `source: "local_default"` permits only `local_only`, `not_offered`, or `offerable` and MUST set `catalog_economics_permitted: false` and `settlement_capable: false`, `source: "coordinator"` permits only SPEC-047 coordinator states, `catalog_economics_permitted` MAY be true only when `source: "coordinator"` and `state` is `catalog_priced` or `settlement_capable`, and `settlement_capable` MAY be true only when `source: "coordinator"` and `state` is `settlement_capable`. Rows whose `admission` object is missing, malformed, stale relative to the signed rate-card evidence, or inconsistent with SPEC-047 MUST set `economics_state` to `blocked` or `unavailable`, null all money-facing payout fields, and make money-motivated actions unavailable. Row `warning_codes` MUST be an array of closed warning-code enum values that apply to that specific row; the top-level `warnings` array applies to the projection as a whole. `economics_state: "trusted"` MUST include non-null rate-card identity, provider-share, and prompt/completion catalog and payout fields, and MUST require `admission.catalog_economics_permitted: true`; Malibu MUST NOT render earning-eligible, settlement-ready, or paid-routing copy unless `admission.settlement_capable: true`. Rows with `rate_source: "none"` or `economics_state: "unavailable"` MUST set rate-card identity and all rate/payout numeric fields to null rather than placeholder zero values. Rows with `economics_state: "blocked"` MUST set money-facing rate/payout fields to null unless the CLI can still identify a verified signed rate card while blocking actions for a non-rate reason; Malibu MUST hide economics copy for blocked rows unless `economics_state` is `trusted`. Rows with `economics_state: "fallback"` or `"stale"` MAY include the signed/static/stale rate fields only as disabled warning context and MUST NOT render them as actionable trusted economics. For an available action, `transaction_kind`, `transaction_id`, and `action_timeout_seconds` MUST be non-null; `action_timeout_seconds` MUST be greater than zero and MUST NOT exceed 1800 seconds. For available `switch_model`, `prepare_model`, `switch_model_deferred`, `cleanup_staging`, `adopt_recommendation`, and any `evaluate_model` action with non-null `estimated_bytes` or `action_timeout_seconds` greater than 10 seconds, `requires_confirmation` MUST be true, and Malibu MUST enforce confirmation for those transaction kinds even if a malformed projection sets the flag false. For an unavailable action, `transaction_kind`, `transaction_id`, and `action_timeout_seconds` MUST be null. A row's `rate_source` MUST be equal to `source.rate_card_source` unless the row uses a more conservative value, where `none` is more conservative than `static_signed`, and `static_signed` is more conservative than `live_signed`. Closed v1 enum values are: `runtime_state` = `current`, `ready`, `catalog`, `needs_preparation`, `blocked`; `fit` = `fits`, `does_not_fit`, `unknown`; admission `source` = `local_default`, `coordinator`; admission `state` = `local_only`, `not_offered`, `offerable`, `offer_submitted`, `offer_rejected`, `sandbox_probe_only`, `network_visible_unpriced`, `network_admitted_unsettled`, `catalog_priced`, `settlement_capable`, `withdrawn`, `revoked`; `rate_source` = `live_signed`, `static_signed`, `none`; `economics_state` = `trusted`, `fallback`, `stale`, `blocked`, `unavailable`; warning codes = `feed_fallback`, `feed_stale`, `feed_signature_invalid`, `feed_generation_mismatch`, `rate_multiplier_unknown`, `model_not_local`, `model_not_supported`, `hardware_fit_unknown`, `hardware_does_not_fit`, `admission_state_missing`, `admission_state_not_settlement_capable`, `warm_swap_unavailable`, `action_unavailable`, `old_cli_fallback`, `projection_unavailable`, `projection_timeout`, `staging_cleanup_required`; action `transaction_kind` = `switch_model`, `switch_model_deferred`, `prepare_model`, `evaluate_model`, `adopt_recommendation`, `cleanup_staging`, or null when unavailable. The v1 transaction event stream MUST use a closed JSON-lines envelope with `schema: "model_catalog_transaction_event.v1"`, matching `transaction_id`, matching `transaction_kind`, `model_key`, monotonic per-transaction `event_sequence`, RFC3339 `emitted_at`, `state`, nullable `progress`, nullable `error_code`, and nullable `warning_code`. Closed event `state` values are `queued`, `running`, `cancel_requested`, `cancelled`, `succeeded`, `failed`, and `timed_out`; `progress`, when present, MUST include a localized-safe `stage_label_key` and at least one of `bytes_completed`/nullable `bytes_expected`, `percent_complete`, or `heartbeat`. Cancellation MUST be requested through the same CLI-owned transaction interface, MUST produce either `cancel_requested` followed by `cancelled` or a terminal `succeeded`/`failed` if the commit point has already passed, and MUST never require Malibu to kill the CLI process or delete files directly. Unknown enum values, unknown action transaction kinds, malformed event envelopes, or event transaction mismatches MUST make the affected row or transaction non-actionable and show a generic unsupported warning; they MUST NOT make Malibu reject the whole projection unless the projection envelope schema itself is unsupported.

**SPEC-044-R003 - Signed-feed trust and fallback states.** The CLI projection MUST identify whether rates came from a live signed feed, a signed static fallback, or no trusted feed. `economics_state: "trusted"` is permitted only when the CLI verifies the signed rate-card bytes, pairs them with the matching demand and candidate generated-at/policy version when those feeds are used for ranking, and can normalize the rate units through the owner-spec conversion rules. A live signed rate card is stale when `generated_at - rate_card_generated_at` is greater than `source.rate_card_max_age_seconds`; v1 `rate_card_max_age_seconds` MUST be at least 300 seconds and MUST NOT exceed 604800 seconds. Malibu MUST treat values outside that range as invalid projection input and fall back with warning code `projection_unavailable`. While the catalog view is visible, Malibu MUST refresh the projection or mark it unavailable before displaying it after `generated_at` is older than the smaller of 300 seconds and `source.rate_card_max_age_seconds`. A signed static fallback rate card MUST use `economics_state: "fallback"` unless a later owner spec defines a freshness proof that allows fallback data to be trusted. When multiple degraded economics conditions apply, the row MUST use the most conservative applicable state in this order: `blocked`, `unavailable`, `stale`, `fallback`, `trusted`; stale fallback data therefore uses `stale`. A row whose rate card is missing, stale, signature-invalid, generated-at mismatched against the demand/candidate feed set, or normalized through an unknown multiplier MUST set `economics_state` to `stale`, `fallback`, `blocked`, or `unavailable` as applicable and MUST disable all money-motivated actions. For v1, money-motivated actions are `switch`, `prepare`, `adopt_recommendation`, and any `evaluate` action that downloads data, mutates local cache/configuration, or is presented using rate, payout, provider-share, or network-demand copy; only a read-only hardware/model-fit evaluation may remain available when economics are not trusted, and it MUST hide or neutralize economics copy.

#### R002/R003 Build 1 v2 amendment

Build 1 preparation and published-artifact cleanup require capability
`model_catalog_economics_v2`, command-schema token
`models catalog-economics.v2`, and projection schema
`model_catalog_economics.v2`. The v2 envelope preserves every v1 field and
closed-enum rule except where this subsection explicitly adds a field or enum
value. The exclusive advertisement and fallback matrix in R001 applies; the
unchanged read command never selects a generation at request time. A client
that understands only v1 MUST use its existing fallback when paired with a
v2-only CLI and MUST NOT receive a v2 envelope. The exact invocation is owned
by SPEC-001-R003 (§6.14b).

Every v2 row adds required non-null `candidate_id`, `provider_guidance`, and
`guidance_binding`. `candidate_id` MUST match `^byom_[a-z2-7]{52}$` and equal
the candidate ID in the single SPEC-046 or SPEC-047 source envelope used to
build the row. `provider_guidance` MUST contain exactly the five SPEC-046-R003
fields `state_label_key`, `state_meaning_key`, `next_action`, nullable
`transition_reason_code`, and `earning_path_class`, with the owner-spec field
values and closed enums copied verbatim. It MUST NOT be reconstructed from
admission state, economics, catalog identity, model names, or local action
eligibility.

`guidance_binding` is closed and contains exactly `source_schema`,
`source_sha256`, `source_generated_at`, nullable `source_projection_sequence`,
nullable `source_coordinator_event_id`, `candidate_id`, `admission_source`, and
`admission_state`. For `admission_source: "local_default"`, `source_schema` MUST
be `provider_byom_discovery.v1`, `source_projection_sequence` MUST be the
non-null sequence from that source, and `source_coordinator_event_id` MUST be
null. For `admission_source: "coordinator"`, `source_schema` MUST be
`model_admission_status.v1`, `source_projection_sequence` MUST be null, and
`source_coordinator_event_id` MUST be the non-null event ID from that source.
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
`root_identity_digest` is SHA-256 over the exact ASCII domain
`macprovider.model_catalog.root_identity.v1` followed by one zero byte and the
32 raw bytes of a root nonce generated once from a CSPRNG during atomic v3-root
bootstrap. The nonce and the canonical path, `st_dev`, and `st_ino` of the
opened root descriptor are stored only in the owner-mode `0600` internal
`root.identity` record; the nonce, path, device, inode, username, and hardware
identifiers MUST NOT appear in the projection. Every projection, dispatch,
publication, cleanup, and recovery MUST reopen the saved canonical path
component-by-component without following symlinks, validate the descriptor's
device/inode plus the owner/type/mode/link-count of its descriptor-relative
`root.identity` record, and recompute the digest from that record before using
the root. A supplied projection digest or current configuration path is never
root authority.
The worker MUST revalidate the current projection transaction, digest, receipt,
root identity, and keep set under the common operation/cleanup lock before any
rename. A stale or mismatched binding fails before deletion. It is distinct
from `cleanup_staging`, which remains
limited to incomplete staging data and MUST reject published objects. Neither
action authorizes automatic garbage collection or legacy-object mutation.

The v2 envelope also adds required top-level `cleanup_targets`, an array of at
most 256 closed objects with exactly `artifact_identity_digest`,
`display_model_id`, `model_revision`, `artifact_id`, `release_id`, nullable
current `model_key`, `root_identity_digest`, `receipt_sha256`, exact logical
`estimated_bytes`, `keep_set_status`, nullable `protected_reason`, and
`cleanup`. The two SHA-256 digests are lowercase 64-hex;
`keep_set_status` is `protected` or `reclaimable`; `protected_reason` is
non-null exactly for `protected`; and `cleanup` uses the v2 action shape. The
array MUST contain every verified managed-v3 object in the usable inventory
exactly once, including objects with no current catalog row, ordered by
ascending `artifact_identity_digest`. A `reclaimable` entry MUST have one
available `cleanup_published_artifact` action carrying the same artifact digest
and `estimated_bytes`; a `protected` entry MUST have an unavailable action and
exact reason. Missing or stale receipt identity, malformed inventory, or
overflow makes the array empty and all published cleanup unavailable. A row
cleanup action, if retained, MUST be a byte-identical projection of its
corresponding top-level entry; Malibu MUST de-duplicate them by
`artifact_identity_digest` and keep one reachable action. Absence from the
current signed catalog MUST NOT make a reclaimable verified identity
unreachable.

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
| `coordinator` with `not_offered`, `offer_submitted`, `offer_rejected`, `sandbox_probe_only`, `network_visible_unpriced`, `network_admitted_unsettled`, `withdrawn`, or `revoked` | `fallback`, `stale`, `blocked`, or `unavailable` | The same locally motivated eligibility and copy MAY apply. Hide rates, payouts, provider share, and demand motivation; preserve the wire earning verdict and admission disclosure. |
| Those non-priced coordinator states | `trusted` | Invalid because `catalog_economics_permitted` is false. Hide economics and disable Prepare with generic unsupported/action-unavailable copy. |
| `coordinator` with `catalog_priced` or `settlement_capable`, with `catalog_economics_permitted: true` | `trusted` | Trusted-economics `prepare_model` MAY be available when the same artifact, fit, runtime, target, size, and safety/storage prerequisites pass. Trusted rates may be shown under R004; earning/settlement copy still follows the admission state. |
| `coordinator` with `catalog_priced` or `settlement_capable` | `fallback`, `stale`, `blocked`, or `unavailable` | Only the locally motivated classification MAY be available under the same prerequisites. Hide or neutralize rates, payouts, provider share, and demand for the action. |
| Any source/state mismatch, malformed admission, inconsistent booleans, or any other combination | Any | Unavailable. Hide economics and use generic unsupported/action-unavailable copy. |

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
`transaction_kind`, and `model_key`. The `transaction_id` is a canonical
lowercase hyphenated UUID v4 generated fresh when the CLI builds an available
projected action from at least 122 bits of CSPRNG entropy. At invocation the
worker generates a distinct canonical lowercase hyphenated UUID v4 `attempt_id`
from the same minimum entropy source; it records that ID in bounded durable
active, history, and marker state but does not add it to the retained v1 event
envelope. Parsers MUST require the exact 36-byte UUID grammar before either
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

Cancellation uses the exact SPEC-001-R003 `--cancel` form and returns one JSON
object capped at 4096 bytes with exactly `schema`, `transaction_id`, nullable
`attempt_id`, `outcome`, and `observed_at`. `schema` is
`model_catalog_transaction_cancel_ack.v1`; `observed_at` is RFC3339; and the
closed outcomes are `recorded`, `already_recorded`, `terminal`, `not_active`,
and `stale`. `transaction_id` MUST byte-for-byte echo the validated requested
ID. `attempt_id` MUST be the matching opaque durable attempt ID for `recorded`,
`already_recorded`, or `terminal`; it MUST be null for `not_active`; for
`stale` it is the recognized prior or mismatched attempt ID when one can be
read safely and otherwise null. `recorded` means only that an exact-attempt
cancellation marker is durable; it is not a worker-observation,
cancellation-success, or terminal claim.

While holding `cancel.lock`, the cancel process MUST validate bounded active,
terminal-history, projected-transaction, and marker records and choose the
first matching predicate in this total precedence:

1. `terminal`: the requested transaction has a durable matching attempt whose
   terminal state was committed, regardless of a leftover exact marker;
2. `already_recorded`: the requested transaction is the durable current
   nonterminal attempt and an exact marker for its transaction and attempt is
   already durable;
3. `recorded`: the requested transaction is the durable current nonterminal
   attempt without its exact marker; the cancel process removes only a
   validated marker bound to an older attempt, durably creates and
   readback-validates the current exact marker, and then acknowledges;
4. `stale`: validated bounded state proves that the requested transaction
   existed but is no longer the cancellable current attempt, including a
   different current attempt or a mismatched prior-attempt marker; and
5. `not_active`: no active, terminal, projected, or bounded-history record
   recognizes the requested transaction and no marker names it.

A malformed record fails the cancel command closed with exit 5 and no
acknowledgement rather than being classified as `not_active`. Concurrent
terminal compaction cannot change the result within this decision because the
worker holds `cancel.lock` across its durable terminal commit, exact-marker
sweep, and operation-lock release.

The cancel process serializes marker mutation with a bounded cancel lock. The
worker checks the marker at least every 250 ms and in each bounded work loop.
If cancellation wins before the applicable commit point, the worker emits
`cancel_requested` once and then terminal `cancelled` after cleanup. After the
commit point it emits only `succeeded` or `failed`. For terminal compaction the
worker holds the operation lock, takes the cancel lock, durably commits terminal
state, removes only the exact matching marker, releases the operation lock
while retaining the cancel lock, and then releases the cancel lock. A new
worker takes locks in the same operation-then-cancel order and removes only a
stale prior-attempt marker before persisting its new attempt. Thus a late marker
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
full-syncs `intent` with the exact transaction, tuple, receipt, saved root
identity, final leaf, reserved same-parent tombstone leaf, and expected byte and
file totals. It recomputes the keep set before rename and clears the intent if
the target became protected. Its commit point is the exclusive
final-to-tombstone rename followed by successful `fsync` and `F_FULLFSYNC` of
the shared `objects` parent. Immediately before rename, the worker takes
`cancel.lock` while retaining the operation/cleanup locks, performs the final
exact-marker check, and retains `cancel.lock` through the rename, parent
barrier, and durable readback-validated `tombstoned` phase update. Only after
that parent barrier may the worker persist and full-sync `tombstoned`, and it
MUST do so before releasing `cancel.lock`. It then descriptor-validates and removes
only the recorded tombstone contents and leaf, fully syncs the parent, persists
`removed`, clears the record, and refreshes inventory.

Before the published-cleanup commit barrier, cancellation wins. If no rename
occurred, the worker durably clears `intent`; if rename occurred but the parent
barrier did not commit, it renames the descriptor-validated tombstone back to
the exact final leaf, fully syncs the parent, and durably clears `intent`. It
then emits `cancel_requested` and terminal `cancelled`. At or after the parent
barrier, cancellation cannot produce `cancelled`: the worker or recovery MUST
advance through `tombstoned` and `removed`, complete exact deletion and emit
`succeeded`, or retain recoverable state and fail with `cleanup_failed`.

Published-cleanup recovery never scans or guesses and uses only the recorded
tuple, saved root, final, and tombstone identity. With `intent`, final present
and tombstone absent means recheck the keep set and then resume rename or clear
intent; final absent and tombstone present means consult the exact-attempt
durable cancellation marker, restoring and fully syncing the final for a
matching pre-commit marker, or repeating the parent barrier and advancing to
`tombstoned` for an absent or nonmatching marker. Both present or both absent
fails closed. With `tombstoned`, tombstone present resumes exact deletion;
tombstone absent and final absent repeats the parent barrier and advances to
`removed`; final present fails closed. With `removed`, both absent permits
record clear and any target present fails closed. Recovery MUST NOT report
`cancelled` after the durable tombstone barrier.

The cancel process performs cleanup-record recovery while holding
`cancel.lock`, before creating a new marker. For `intent` with final absent and
tombstone present, an already-durable exact-attempt marker proves cancellation
won the worker's final check and requires restoration. If no exact marker is
already durable, the cancel process repeats the parent `fsync` and
`F_FULLFSYNC`, durably advances the record to `tombstoned`, and only then may it
record the new exact marker; that marker is necessarily post-commit and cannot
authorize restoration. A malformed or unsafe record fails the cancel command
closed. Because the worker holds `cancel.lock` from its final marker check
through the durable `tombstoned` update, and the cancel process resolves this
recovery state before marker creation, every crash leaves recoverable evidence
of whether cancellation preceded or followed the cleanup commit barrier.

Staging cleanup is separate and uses an attempt-owned recorded target plus the
same reversible `intent` to same-parent tombstone to `removed` discipline
inside the attempt's staging parent. Its commit point is the exclusive
staging-to-tombstone rename followed by successful parent `fsync` and
`F_FULLFSYNC`. It uses the same final marker check and holds `cancel.lock`
through the rename, parent barrier, and durable readback-validated
`tombstoned` update. Its cancel process likewise resolves `intent` plus only a
tombstone under that lock before creating a new marker, so only an
already-durable exact marker authorizes pre-commit restoration. Before the
commit barrier cancellation preserves or restores the staging root, retains
`staging_cleanup_required`, and terminates `cancelled`; after it, cleanup or
recovery removes only the recorded tombstone and terminates `succeeded` or
recoverable `cleanup_failed`, never `cancelled`. A retry resumes the durable
phase for the same identity and MUST NOT create a second tombstone, delete
published or legacy data, or turn incomplete recovery into success.

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

**SPEC-044-R004 - Rate math display contract.** Malibu MUST display network catalog rates as rates, not income. Provider payout rates MUST be displayed in USD per 1,000,000 tokens, matching the schema field unit, with at least two significant figures and labels that distinguish prompt and completion rates when both are shown. When showing provider economics, Malibu MUST label them as provider share of catalog rates and MUST disclose that actual rewards depend on eligible demand, uptime, accepted requests, trust state, routing, token mix, settlement, and any active sanctions or probation. That variability disclosure MUST be persistently visible within the same scrollable container as rate-bearing rows, MUST NOT require hover, expansion, navigation, or a separate tooltip to be discovered, and MUST meet the same localization and screen-reader accessibility requirements as the rate labels themselves. Malibu MUST NOT display or imply a specific dollar amount attributed to a time period, including hourly, daily, weekly, monthly, annual, or "up to" projections. The UI MUST NOT show copy such as "earns", "guaranteed", "daily revenue", "hourly pay", "will pay", "potential earnings", "estimated daily", "up to $X/day", "average payout", "projected return", "higher-paying", or any absolute payout projection unless a later billing-owner spec defines a verified earnings forecast contract.

**SPEC-044-R005 - Provider-friendly ranking.** Malibu SHOULD sort and group rows to help providers discover better opportunities, using a deterministic order that prefers current model visibility first, then locally ready trusted provider completion payout rate, then recommended or high-demand models that fit the machine, then preparation-required rows, then blocked rows. Rows with incomplete trust or economics MUST be visible only with a standardized localized warning that includes the localized `economics_state` meaning and at least one localized row `warning_codes` value explaining the limitation. Non-actionable rows whose `disabled_reason` is null and whose row `warning_codes` array is empty MUST be hidden until the CLI can provide a testable reason. Any action with `available: true` constitutes a testable reason to show the row when the rest of the row satisfies this spec.

A v2 row with a valid locally motivated `prepare_model` action MUST remain
visible in `Needs preparation` regardless of its non-trusted economics state;
its ordering MUST ignore rate, payout, provider share, and demand fields.

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

**SPEC-044-R008 - UX layout and state model.** Malibu MUST present model rows in stable sections that distinguish `Current`, `Ready`, `Network catalog`, `Needs preparation`, and `Blocked` states. Section headers MUST be localized display copy that follows R004/R009 and MUST NOT be rendered directly from enum names. Each row MUST show at least display name, fit state, approximate size when known, local readiness, provider completion payout rate when trusted, network demand signal label when trusted, and one primary action or disabled reason. Rows whose economics are not `trusted` MUST NOT appear in `Network catalog` based on stale, fallback, blocked, or unavailable rates; they MUST appear in `Needs preparation` when only local preparation blocks a non-money action, otherwise in `Blocked` or an equivalent warning subsection that may still contain explicitly read-only actions such as `Evaluate`. Rows with `fit: unknown` MUST NOT appear in `Network catalog` with an action available unless the confirmation dialog prominently states that hardware fit is unknown and the action is a read-only evaluation or preparation path that the CLI can reverse without changing the current serving model. Malibu MUST select v2, v1, or static fallback by the complete exclusive advertisement matrix in R001. If neither complete supported pair is advertised, or advertisement is partial or dual-generation, the view MUST degrade to the existing static current-model card with no catalog-economics call and no error indicator. If the CLI advertises one complete supported pair but the projection request fails, times out, or returns a malformed envelope, Malibu MUST show the static current-model card with a distinct "model catalog unavailable" warning, warning code `projection_unavailable`, and a retry affordance.

For v2, a valid locally motivated preparation row belongs in `Needs
preparation`; it MUST NOT be placed in `Network catalog` from local custody
or non-trusted economics. Absence of either exact v2 value permits v1 only when
the complete v1 pair is exclusively advertised; otherwise Malibu uses the
legacy fallback without attempting a catalog-economics call or v2 action.

**SPEC-044-R009 - Trust-preserving copy and localization.** All new Malibu strings for rates, potential, warnings, actions, and disabled reasons MUST be app-localizable, screen-reader accessible, and written as operator guidance rather than marketing. Warning copy MUST clearly distinguish "network catalog rate unavailable" from "model cannot be served" from "model needs preparation". Localization tests MUST cover the forbidden earnings-claim meanings from R004 in every shipped locale, not only the English source strings. Every shipped locale with right-to-left layout support MUST verify that row ordering, numeric rate labels, section grouping, and action buttons remain readable and navigable; if Malibu ships no right-to-left locale for this release, the release evidence MUST state that RTL is out of scope.

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

**SPEC-044-R012 - Release evidence.** A Malibu release that enables this experience by default MUST include automated tests for the CLI projection schema, feed trust/fallback/staleness priority states, row warning-code attribution, rate math normalization and display units, browse-row non-actionability, immediate and deferred switch gating, Swift decoding, UI grouping, projection-failed fallback, CLI restart sequencing, disabled-action copy, progress rendering, localization/accessibility coverage including any shipped RTL locale, staging cleanup/reporting, and post-action reconciliation. Production promotion MUST additionally capture signed release evidence, using the repository journey-result signing format governed by `requires_signed_journey_result`, that an old CLI receives the static fallback UI and a compatible CLI renders trusted rates without exposing secrets or unsupported actions.

For v2 the R012 evidence also MUST cover exact read/run/cancel grammar and exit
status, exclusive v1/v2 advertisement, strict v2 decoding, every
preparation-matrix branch, exact and localized action copy, event code/state
closure, worker-only sequencing, all cancellation-ack outcomes and races,
storage nullability and bounds, 255/256/idempotent/257 object admission,
managed-budget/free-space refusal, legacy accounting/protection, digest-bound
published cleanup, bounded complete cleanup-target reachability, and the
absence of automatic garbage collection.

The release test corpus MUST additionally prove all of the following exact
boundaries:

- launch the built CLI and route its exact stdout, stderr, and exit status
  through Malibu's production process adapter and strict decoder for v1 and v2
  reads, every terminal run outcome, all five cancellation acknowledgements,
  partial/chunked JSONL, malformed-v2 negatives, old-Malibu/new-v2-CLI static
  fallback, and new-Malibu/old-v1-CLI read-only fallback;
- reject unknown or mismatched `candidate_id`, guidance-source fields/digest,
  owner-spec guidance fields/enums, admission correlation, coordinator event,
  state timestamp, future source time, and the 300-second freshness boundary;
  exercise every matrix branch with verbatim SPEC-046/SPEC-047 guidance and
  prove guidance renders first;
- exercise `local_default:not_offered`, `coordinator:not_offered`, and both
  source-transition directions under every economics class; test primary
  artifact status `verified`, `declared`, `blocked`, absent, and each signed-feed
  drift boundary, proving only current `verified` is eligible at projection and
  dispatch and remains eligible at the immediate prepublication recheck;
- table-test the total cancellation-ack predicate precedence under concurrent
  active, terminal, projected, history, exact-marker, mismatched-marker, and
  new-attempt states, including transaction echo and exact attempt nullability;
  race cancel, crash, recovery, and retry before/after every preparation,
  published-cleanup, and staging-cleanup commit phase, including marker creation
  after the parent barrier but before an attempted `tombstoned` phase write;
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
  exact digest construction, descriptor revalidation, copied-record rejection,
  and that projected digests reveal no path/device/inode/identity value. When configured-legacy
  accounting is unavailable, assert Prepare is unavailable, stale direct
  dispatch refuses before network/staging, published cleanup is unavailable,
  affected fields have the required nullability, and incumbent serving is
  unchanged;
- prove `cleanup_targets` contains every verified managed object exactly once
  in digest order at 0, 1, 255, and 256 objects; prove protected targets are
  disabled, every reclaimable orphan without a current catalog row remains
  reachable, row/target duplicates are identical and de-duplicated, and
  malformed/257-entry inventories fail closed; and
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
  terminal state, exit status, and unchanged side-effect boundary.

## 4. Implementation, tests, and journeys

The intended implementation is a CLI-first projection, then an app-only presentation layer:

1. Preserve the exact SPEC-001-R003 read/run/cancel forms under `models catalog-economics`; do not add aliases or a transaction-status command.
2. Advertise only `model_catalog_economics_v2` and `models catalog-economics.v2` in the capability surfaces Malibu already uses for model management, omitting both v1 values.
3. Extend Malibu model management decoding with a new envelope while keeping the current `models_list.v1` and browse behavior as fallback paths.
4. Replace the static switcher modal with a sectioned catalog view that supports current, ready, network-catalog, preparation-required, and blocked rows.
5. Wire only CLI-owned typed transactions into action buttons; all other rows are informational.
6. Add post-action refresh and failure reconciliation so the UI never declares a model change from a stale terminal event alone.

The first journey id is `JOURNEY-MALIBU-MODEL-ECONOMICS`. The journey should cover a current static qwen3-8b install, a compatible CLI with trusted live or static rates, a stale/mismatched feed set, an uninstalled catalog model with a trusted provider payout rate, a verified locally ready model, an unsupported browse-only model, and an old CLI fallback.

## 5. Open gaps

| Requirement/domain | Verdict | Owner | Issue | Evidence needed |
|---|---|---|---|---|
| `SPEC-044-R001..R012` | `DECISION_REQUIRED` | `@Augustas11` | `#614` | Implement the approved v0.2.1 projection, transaction, cancellation, preparation-copy, cleanup, and accounting authority; then decide promotion only after automated tests and signed release evidence. |
| `malibu-model-economics-ux` | `DECISION_REQUIRED` | `@Augustas11` | `#614` | Implement the operator-approved CLI-owned projection and Malibu rendering without app-side feed verification; production enablement remains an operator decision. |
| `SPEC-046/SPEC-047 integration` | `DECISION_REQUIRED` | `@Augustas11` | `#1240` | Approval that SPEC-044 is narrowed to network economics and does not own provider-local BYOM discovery or network admission. |

## 6. Evidence

Current implementation evidence predates the v0.2.1 Build 1 authority and is
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

The capability name `model_catalog_economics_v1` and schema discriminator `model_catalog_economics.v1` are intentionally different strings: the capability gates whether Malibu may request the projection, while the schema value identifies the JSON envelope returned by that projection.

The current Malibu recommendation path may remain as a companion callout, but the catalog view must not require a recommendation run to show signed rates for supported models. Recommendation scores can rank rows only when the feed set is trusted and the CLI marks the signal current.

The app should preserve the current provider mental model: Malibu observes and asks the signed CLI to do work; the CLI owns custody, model artifacts, feed validation, update/recovery, admission, and billing-derived economics.

## 8. Changelog and history

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

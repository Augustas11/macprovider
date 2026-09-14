# SPEC-044 - Malibu Model Catalog Economics

**Version:** 0.1.2

```json
{
  "spec_id": "SPEC-044",
  "title": "Malibu Model Catalog Economics",
  "version": "0.1.2",
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
    "rationale": "Malibu currently exposes a model switcher, but the production experience is static around the model chosen during installer autotune. The next release needs a CLI-owned catalog and economics projection before the app can safely show additional catalog models, signed catalog rates, readiness, and preparation/switch actions without making earning guarantees or bypassing provider safety gates."
  }
}
```

## 1. Purpose and scope

SPEC-044 defines the next Malibu provider-facing network economics experience: a native Mac app view that helps a provider understand which network-eligible models their machine can serve, what the signed catalog currently pays per token, which choices are locally ready, and which catalog choices need preparation before they can be safely served.

The user outcome is simple: a provider should not be trapped behind the single model selected during `macprovider-cli` install. Malibu should make better model choices legible, explain the economic upside in rate-card terms, and route every action through the installed CLI's signed, versioned transactions.

This spec is required because network-eligible model choice now crosses product UX, signed model catalog identity, autotune recommendation, rate-card projection, warm-swap safety, and money-facing copy. A static UI can be app-local; a multi-model economics UI is a release contract.

SPEC-044 is not the full model universe for Malibu. Provider-local bring-your-own-model discovery is owned by SPEC-046, and promotion from discovered candidate to network-admission state is owned by SPEC-047. SPEC-044 applies when Malibu presents network eligibility, signed catalog economics, or catalog actions, including the explicitly non-economic local preparation and activation exception below.

### Explicit non-goals

SPEC-044 does not create an open third-party model marketplace and does not own provider-local model discovery. Models shown with trusted catalog economics must still come from a network-eligible admission state and the MacProvider-owned signed catalog/rate-card trust path. The R003 local bootstrap exception permits authenticated primary-artifact preparation, measured evaluation, and confirmed activation before admission; it grants no network or economic authority.

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

**SPEC-044-R001 - CLI-owned economics projection.** Malibu MUST obtain model economics, network readiness, trust state, and actions from an installed, signed `macprovider-cli` projection advertised by a capability named `model_catalog_economics_v1` or a later compatible capability. Malibu MUST NOT fetch coordinator rate feeds, parse static feed files, verify feed signatures, compute billing rates from raw feed bytes, derive action eligibility from app-local heuristics, or present a SPEC-046 discovered candidate as a network economics row unless SPEC-047 admission state permits that presentation.

**SPEC-044-R002 - Versioned row schema.** The CLI projection MUST emit a closed, versioned JSON envelope with `schema: "model_catalog_economics.v1"`, a wall-clock RFC3339 `generated_at`, a monotonic unsigned integer `projection_sequence`, a `source` object identifying the CLI build and feed provenance, an array of rows, and a projection-level `warnings` array. The v1 `source` object MUST include `cli_version`, `cli_build_commit`, `process_launch_id`, `process_started_at`, `projection_protocol_version`, `rate_card_source`, nullable `rate_card_digest`, nullable `rate_card_signature_digest`, nullable `demand_feed_digest`, nullable `candidate_feed_digest`, and `rate_card_max_age_seconds`; `process_launch_id` MUST be a lowercase hyphen-separated UUID v4 string generated fresh on CLI process start from at least 128 bits of CSPRNG entropy and MUST NOT be derivable from a PID, host serial, MAC address, host UUID, provider id, wallet, username, or any other hardware or identity value. `source.rate_card_source` MUST use the same closed enum as row `rate_source`: `live_signed`, `static_signed`, or `none`. `projection_sequence` MUST increase within a single CLI process for each newly generated projection and MAY reset after CLI restart; callers MUST use it only to order projections that have the same `source.process_launch_id`. When Malibu observes a new `source.process_launch_id`, it MUST treat the projection as a new CLI session, reset its ordering baseline, discard older in-flight projection ordering comparisons, and show a brief reconnecting or refreshing state before rendering the new projection. Each row MUST include model identity (`model_key`, `served_model_id`, `display_model_id`, nullable `action_model_id`), local state (`is_current`, `weights_present_locally`, `runtime_state`, nullable `estimated_gb`, `fit`, nullable `disabled_reason`, `warning_codes`), admission state (`admission`), economics (nullable `rate_card_version`, nullable `rate_card_generated_at`, nullable `rate_card_key`, `rate_source`, nullable `prompt_rate_usd_per_million_tokens`, nullable `completion_rate_usd_per_million_tokens`, nullable `provider_share_bps`, nullable `provider_prompt_payout_usd_per_million_tokens`, nullable `provider_completion_payout_usd_per_million_tokens`, `economics_state`), demand signals (nullable `demand_rank`, nullable `demand_weight`, nullable `ready_provider_count`, nullable `supply_deficit_score`), and actions (`switch`, `prepare`, `evaluate`, `adopt_recommendation`, `cleanup_staging`) as explicit objects with `available`, `requires_confirmation`, nullable `transaction_kind`, nullable `transaction_id`, nullable `action_timeout_seconds`, nullable `estimated_bytes`, and nullable `unavailable_reason`. The row `admission` object MUST include `state`, `source`, nullable `coordinator_event_id`, nullable `state_observed_at`, `catalog_economics_permitted`, and `settlement_capable`; `source` is `local_default` or `coordinator`, `state` MUST use the SPEC-046/SPEC-047 admission-state enum, `source: "local_default"` permits only `local_only`, `not_offered`, or `offerable` and MUST set `catalog_economics_permitted: false` and `settlement_capable: false`, `source: "coordinator"` permits only SPEC-047 coordinator states, `catalog_economics_permitted` MAY be true only when `source: "coordinator"` and `state` is `catalog_priced` or `settlement_capable`, and `settlement_capable` MAY be true only when `source: "coordinator"` and `state` is `settlement_capable`. Rows whose `admission` object is missing, malformed, stale relative to the signed rate-card evidence, or inconsistent with SPEC-047 MUST set `economics_state` to `blocked` or `unavailable`, null all money-facing payout fields, and make money-motivated actions unavailable. Row `warning_codes` MUST be an array of closed warning-code enum values that apply to that specific row; the top-level `warnings` array applies to the projection as a whole. `economics_state: "trusted"` MUST include non-null rate-card identity, provider-share, and prompt/completion catalog and payout fields, and MUST require `admission.catalog_economics_permitted: true`; Malibu MUST NOT render earning-eligible, settlement-ready, or paid-routing copy unless `admission.settlement_capable: true`. Rows with `rate_source: "none"` or `economics_state: "unavailable"` MUST set rate-card identity and all rate/payout numeric fields to null rather than placeholder zero values. Rows with `economics_state: "blocked"` MUST set money-facing rate/payout fields to null unless the CLI can still identify a verified signed rate card while blocking actions for a non-rate reason; Malibu MUST hide economics copy for blocked rows unless `economics_state` is `trusted`. Rows with `economics_state: "fallback"` or `"stale"` MAY include the signed/static/stale rate fields only as disabled warning context and MUST NOT render them as actionable trusted economics. For an available action, `transaction_kind`, `transaction_id`, and `action_timeout_seconds` MUST be non-null; `action_timeout_seconds` MUST be greater than zero and MUST NOT exceed 1800 seconds. For available `switch_model`, `prepare_model`, `switch_model_deferred`, `cleanup_staging`, `adopt_recommendation`, and any `evaluate_model` action with non-null `estimated_bytes` or `action_timeout_seconds` greater than 10 seconds, `requires_confirmation` MUST be true, and Malibu MUST enforce confirmation for those transaction kinds even if a malformed projection sets the flag false. For an unavailable action, `transaction_kind`, `transaction_id`, and `action_timeout_seconds` MUST be null. A row's `rate_source` MUST be equal to `source.rate_card_source` unless the row uses a more conservative value, where `none` is more conservative than `static_signed`, and `static_signed` is more conservative than `live_signed`. Closed v1 enum values are: `runtime_state` = `current`, `ready`, `catalog`, `needs_preparation`, `blocked`; `fit` = `fits`, `does_not_fit`, `unknown`; admission `source` = `local_default`, `coordinator`; admission `state` = `local_only`, `not_offered`, `offerable`, `offer_submitted`, `offer_rejected`, `sandbox_probe_only`, `network_visible_unpriced`, `network_admitted_unsettled`, `catalog_priced`, `settlement_capable`, `withdrawn`, `revoked`; `rate_source` = `live_signed`, `static_signed`, `none`; `economics_state` = `trusted`, `fallback`, `stale`, `blocked`, `unavailable`; warning codes = `feed_fallback`, `feed_stale`, `feed_signature_invalid`, `feed_generation_mismatch`, `rate_multiplier_unknown`, `model_not_local`, `model_not_supported`, `hardware_fit_unknown`, `hardware_does_not_fit`, `admission_state_missing`, `admission_state_not_settlement_capable`, `warm_swap_unavailable`, `action_unavailable`, `old_cli_fallback`, `projection_unavailable`, `projection_timeout`, `staging_cleanup_required`; action `transaction_kind` = `switch_model`, `switch_model_deferred`, `prepare_model`, `evaluate_model`, `adopt_recommendation`, `cleanup_staging`, or null when unavailable. The v1 transaction event stream MUST use a closed JSON-lines envelope with `schema: "model_catalog_transaction_event.v1"`, matching `transaction_id`, matching `transaction_kind`, `model_key`, monotonic per-transaction `event_sequence`, RFC3339 `emitted_at`, `state`, nullable `progress`, nullable `error_code`, and nullable `warning_code`. Closed event `state` values are `queued`, `running`, `cancel_requested`, `cancelled`, `succeeded`, `failed`, and `timed_out`; `progress`, when present, MUST include a localized-safe `stage_label_key` and at least one of `bytes_completed`/nullable `bytes_expected`, `percent_complete`, or `heartbeat`. Cancellation MUST be requested through the same CLI-owned transaction interface, MUST produce either `cancel_requested` followed by `cancelled` or a terminal `succeeded`/`failed` if the commit point has already passed, and MUST never require Malibu to kill the CLI process or delete files directly. Unknown enum values, unknown action transaction kinds, malformed event envelopes, or event transaction mismatches MUST make the affected row or transaction non-actionable and show a generic unsupported warning; they MUST NOT make Malibu reject the whole projection unless the projection envelope schema itself is unsupported.

**SPEC-044-R003 - Signed-feed trust and fallback states.** The CLI projection MUST identify whether rates came from a live signed feed, a signed static fallback, or no trusted feed. `economics_state: "trusted"` is permitted only when the CLI verifies the signed rate-card bytes, pairs them with the matching demand and candidate generated-at/policy version when those feeds are used for ranking, and can normalize the rate units through the owner-spec conversion rules. A live signed rate card is stale when `generated_at - rate_card_generated_at` is greater than `source.rate_card_max_age_seconds`; v1 `rate_card_max_age_seconds` MUST be at least 300 seconds and MUST NOT exceed 604800 seconds. Malibu MUST treat values outside that range as invalid projection input and fall back with warning code `projection_unavailable`. While the catalog view is visible, Malibu MUST refresh the projection or mark it unavailable before displaying it after `generated_at` is older than the smaller of 300 seconds and `source.rate_card_max_age_seconds`. A signed static fallback rate card MUST use `economics_state: "fallback"` unless a later owner spec defines a freshness proof that allows fallback data to be trusted. When multiple degraded economics conditions apply, the row MUST use the most conservative applicable state in this order: `blocked`, `unavailable`, `stale`, `fallback`, `trusted`; stale fallback data therefore uses `stale`. A row whose rate card is missing, stale, signature-invalid, generated-at mismatched against the demand/candidate feed set, or normalized through an unknown multiplier MUST set `economics_state` to `stale`, `fallback`, `blocked`, or `unavailable` as applicable and MUST disable all money-motivated actions. For legacy protocol version `1`, money-motivated actions are `switch`, `prepare`, `adopt_recommendation`, and any `evaluate` action that downloads data, mutates local cache/configuration, or is presented using rate, payout, provider-share, or network-demand copy; only a read-only hardware/model-fit evaluation may remain available when economics are not trusted, and it MUST hide or neutralize economics copy. Protocol version `2` permits only the narrow non-economic bootstrap exception below; all other money-motivated action gates remain unchanged.

**R002/R003 compatibility and local bootstrap amendment (v0.1.2).** The CLI
MUST advertise `model_catalog_transactions_v1` for preparation, transaction
readback/cancellation/result, and owned-staging cleanup. It MUST advertise
`model_catalog_local_activation_v1` only when those transactions and the existing
`model_recommendation_apply_switch_v1` adoption capability are implemented.
Malibu MUST explicitly request `models catalog-economics --local-activation
--json` only after negotiating both new capabilities and the adoption capability.
This opt-in returns the closed `model_catalog_economics.v1` protocol-2 shape defined below with
`source.projection_protocol_version: "2"`; the default invocation retains `"1"`
and its stricter action rules. Protocol 2 adds only the fields specified below; no admission state or economic authority is added.
A client MUST reject unknown protocol versions conservatively and MUST NOT infer
support from CLI version numbers or merely from available action objects.

With that negotiation, an exact CLI-supported primary MLX artifact authenticated
under SPEC-010 and SPEC-023 may expose `prepare_model` before network admission.
A verified locally ready copy of that exact primary target may expose a confirmed
`evaluate_model` through `models recommend-prepared`, then `adopt_recommendation`
only for the resulting fresh, measured, eligible `autotune_recommend.v1` document.
These actions MAY be available while admission is a valid local-default or
non-paid coordinator state and economics are `blocked` or `unavailable`
because economic display authority is unavailable (including admission not yet
priced). Preparation requires fresh authenticated artifact/candidate identity,
not economic display authority. They MUST NOT bypass invalid, stale,
missing, unsupported, non-primary, or mismatched artifact authority, fit/config
safeguards, or a coordinator revocation/sanction. Preparation may report unknown
fit with explicit confirmation; activation MUST establish fit and all existing
adoption preconditions. Signed rate/candidate/demand freshness and consistency
required by the recommendation producer and validator remain mandatory: missing
required evidence blocks activation, and catalog thresholds MUST NOT substitute
for measured benchmarks or an eligible recommendation.

For every such bootstrap row, all rate/payout/provider-share numeric fields and
all demand fields MUST be null; Malibu MUST suppress economics, ranking by
network demand, earning, and paid-routing claims even when internal authenticated
rates are used to validate recommendation configuration. Confirmation MUST state
the authenticated artifact trust source, exact target, and local implications;
activation confirmation MUST state that local activation does not authorize paid
routing. Readiness, completed preparation, local benchmark success, action
availability, or local activation MUST NOT change admission, make economics
`trusted`, or imply settlement capability. Existing paid routing, signed offer,
coordinator admission, and receipt/settlement gates remain mandatory.

**SPEC-044-R004 - Rate math display contract.** Malibu MUST display network catalog rates as rates, not income. Provider payout rates MUST be displayed in USD per 1,000,000 tokens, matching the schema field unit, with at least two significant figures and labels that distinguish prompt and completion rates when both are shown. When showing provider economics, Malibu MUST label them as provider share of catalog rates and MUST disclose that actual rewards depend on eligible demand, uptime, accepted requests, trust state, routing, token mix, settlement, and any active sanctions or probation. That variability disclosure MUST be persistently visible within the same scrollable container as rate-bearing rows, MUST NOT require hover, expansion, navigation, or a separate tooltip to be discovered, and MUST meet the same localization and screen-reader accessibility requirements as the rate labels themselves. Malibu MUST NOT display or imply a specific dollar amount attributed to a time period, including hourly, daily, weekly, monthly, annual, or "up to" projections. The UI MUST NOT show copy such as "earns", "guaranteed", "daily revenue", "hourly pay", "will pay", "potential earnings", "estimated daily", "up to $X/day", "average payout", "projected return", "higher-paying", or any absolute payout projection unless a later billing-owner spec defines a verified earnings forecast contract.

**SPEC-044-R005 - Provider-friendly ranking.** Malibu SHOULD sort and group rows to help providers discover better opportunities, using a deterministic order that prefers current model visibility first, then locally ready trusted provider completion payout rate, then recommended or high-demand models that fit the machine, then preparation-required rows, then blocked rows. Rows with incomplete trust or economics MUST be visible only with a standardized localized warning that includes the localized `economics_state` meaning and at least one localized row `warning_codes` value explaining the limitation. Non-actionable rows whose `disabled_reason` is null and whose row `warning_codes` array is empty MUST be hidden until the CLI can provide a testable reason. Any action with `available: true` constitutes a testable reason to show the row when the rest of the row satisfies this spec.

**SPEC-044-R006 - Action gating.** Malibu MUST expose immediate `Switch` only when the row names an exact CLI-supported `action_model_id`, the local artifact is verified present, the CLI reports the model fits, warm-swap is available, and the CLI returns a `switch_model` transaction. When warm-swap is unavailable but the model is verified local, fits, and the CLI returns a `switch_model_deferred` transaction, Malibu MAY expose a distinct restart-or-defer switch affordance that states serving will restart, drain, or resume under CLI control before the model changes. Malibu MUST expose `Prepare`, `Evaluate`, `Adopt`, or `Clean up` only when the CLI returns a typed transaction for that exact row. Nontrusted local preparation/evaluation/adoption MUST additionally satisfy the R002/R003 capability and exact-target exception; cleanup is a non-economic recovery action restricted to an existing CLI-owned transaction and MUST NOT require trusted rates or currently available feed authority to remove its owned staging. An adoption action MUST consume the complete CLI-produced recommendation, revalidate its age, hardware/runtime identity, exact artifact hash and authenticated feed bindings, and use the unchanged CLI/runtime lock, journal, and rollback protocol. In the `model_catalog_economics.v1` envelope, any row with `action_model_id: null` MUST set every action object's `available` field to `false`, every action object's `transaction_kind`, `transaction_id`, and `action_timeout_seconds` to null, row `disabled_reason` to a nonempty value, and every unavailable action's `unavailable_reason` to a nonempty value. Malibu MUST treat any row that violates this invariant as non-actionable and display the generic unsupported warning rather than trusting the action object. Discovery-only legacy browse rows with null `action_model_id`, legacy `actionable: false`, or no available typed action MUST remain non-actionable in Malibu and MUST NOT be converted into SPEC-044 action rows by the app.

**SPEC-044-R007 - Preparation safety.** Any model preparation transaction shown by Malibu MUST require explicit provider confirmation, state the expected download/cache size and trust source, use a CLI-owned isolated staging directory, verify signed catalog identity before promotion, support cancellation before commit, clean or report resumable cleanup instructions for partial staging artifacts on cancel/failure, and leave the current serving model unchanged on failure. An `adopt_recommendation` transaction that downloads, caches, stages, promotes, or otherwise prepares model artifacts, or whose action object has non-null `estimated_bytes`, is a model preparation transaction for this requirement and MUST satisfy the same confirmation, staging, cancellation, cleanup, progress, and failure invariants as `prepare_model`. If the CLI cannot satisfy those preparation invariants for an unprepared recommended model, it MUST expose `prepare_model` first and keep `adopt_recommendation` unavailable until the model is locally ready. An `evaluate_model` transaction that downloads data, mutates local cache or configuration, prepares model artifacts, has non-null `estimated_bytes`, or has `action_timeout_seconds` greater than 10 seconds MUST satisfy the same confirmation, progress, cancellation, delayed-response, and failure-visibility invariants as preparation transactions; if it stages or promotes model artifacts, it MUST also satisfy the isolated staging, signed-identity verification, cleanup, and current-model-unchanged invariants for `prepare_model`. When `estimated_bytes` is non-null, the confirmation MUST display that estimate; when `estimated_bytes` is null, the confirmation MUST state that the size is unavailable before the provider confirms. For any preparation, cleanup, or long-running evaluation transaction with `action_timeout_seconds` greater than 10 seconds, the CLI MUST emit progress events at least every 10 seconds while active, including a stage label and either bytes completed/expected, percent complete, or an indeterminate but live heartbeat; Malibu MUST surface a live progress indicator and cancellation affordance while those events are current. Progress events are current for no more than 30 seconds after the last observed progress, heartbeat, or terminal event. If no progress or terminal event arrives within that 30-second window and `action_timeout_seconds` has not elapsed, Malibu MUST show a localized delayed-response state, keep the cancellation affordance prominently visible, and MUST NOT declare success until a terminal event and refreshed projection arrive. The CLI MUST emit warning code `staging_cleanup_required` when a partial staging artifact is detected at startup or after cancel/failure and cannot be automatically removed. When `staging_cleanup_required` is present, Malibu MUST surface a labeled cleanup affordance that invokes a CLI-owned `cleanup_staging` transaction when available, states estimated recoverable bytes when known, and MUST NOT delete staging files directly. Malibu MUST NOT start hidden downloads or mutate model symlinks directly.

**R007 transaction and recovery amendment (v0.1.2).** SPEC-001 §6.14a owns
exact command spelling. Preparation, measured prepared-only evaluation, and
cleanup MUST use the unchanged `model_catalog_transaction_event.v1` JSONL
stream and closed transaction kinds `prepare_model`, `evaluate_model`, and
`cleanup_staging`. Each operation MUST be bound to a CLI-owned private journal,
transaction UUID, exact target, and authenticated input digests. Unknown,
foreign-owner, or cross-target transaction IDs MUST fail closed. Repeated status
and cancellation requests MUST preserve monotonic event ordering and the original
terminal truth. Status/result access MUST reconcile an interrupted owner before
claiming a terminal outcome; a restart MUST NOT silently resume destructive work
or manufacture success. Recommendation results are retrieved separately through
`models transaction result` and MUST NOT be inserted into the closed event stream.

The CLI MUST serialize conflicting preparation, recommendation evaluation, and
adoption operations with its existing config/runtime transaction authority, while
keeping status and cancellation available. Preparation MUST use isolated
transaction-owned staging, bounded available-space checks, and cancellation
checks during metadata fetch, download, hash verification, and durable copy.
Publication of the fully verified temporary durable copy through an atomic
operation is the preparation commit point. The CLI MUST revalidate the captured
signed catalog/artifact authority immediately before publication, reject changed
or stale authority, and MUST NOT overwrite or remove incumbent artifacts during
repair. Active and recovery-journal-referenced artifacts MUST remain protected.
Cancellation before commit MUST stop owned work and remove only owned staging
or report `staging_cleanup_required`; after commit it MUST report the committed
outcome so R011 can disclose cancellation too late. Cleanup MUST be idempotent,
transaction-scoped, and incapable of deleting arbitrary paths, another
transaction's staging, published artifacts, or active/recovery references.
Preparation MUST NOT alter serving configuration or activate a model.

`models recommend-prepared` MUST resolve one exact verified durable primary
artifact using the same configured/env-root precedence as discovery and serving.
It MUST pass a complete prefetched-artifact map to the real recommendation
benchmarker and take the verified-existing-artifact branch. Missing map entries,
missing/corrupt bytes, or hash/revision mismatch MUST fail before runner creation;
there MUST be no downloader fallback, hidden preparation, synthetic benchmark
from catalog thresholds, or config application. The real candidate runner MUST
produce the measured benchmark/fit values used by the existing recommendation
engine and full `autotune_recommend.v1` evidence. This is a confirmed long-running
`evaluate_model`, with a deadline no greater than 1800 seconds, live progress,
memory-pressure monitoring, safe drain/restore lifecycle, and CLI-owned
cancellation forwarded to its probe child. The owner MUST wait for child
termination and restore the prior serving lifecycle on completion, cancellation,
timeout, and recoverable crash before reporting a settled local outcome.
Background check-only remains estimate-only and MUST NOT supply this adoption
recommendation. Only later explicit adoption may replace the incumbent.

**SPEC-044-R008 - UX layout and state model.** Malibu MUST present model rows in stable sections that distinguish `Current`, `Ready`, `Network catalog`, `Needs preparation`, and `Blocked` states. Section headers MUST be localized display copy that follows R004/R009 and MUST NOT be rendered directly from enum names. Each row MUST show at least display name, fit state, approximate size when known, local readiness, provider completion payout rate when trusted, network demand signal label when trusted, and one primary action or disabled reason. Rows whose economics are not `trusted` MUST NOT appear in `Network catalog` based on stale, fallback, blocked, or unavailable rates; they MUST appear in `Needs preparation` when only local preparation blocks a non-money action, otherwise in `Blocked` or an equivalent warning subsection that may still contain explicitly read-only actions such as `Evaluate`. Under the negotiated R003 bootstrap exception, verified local artifacts MAY instead appear in `Ready` or `Current` with local-only evaluation/activation copy, and unprepared targets MAY appear in `Needs preparation`; those sections MUST remain distinct from priced, admitted, and settled states. Rows with `fit: unknown` MUST NOT appear in `Network catalog` with an action available unless the confirmation dialog prominently states that hardware fit is unknown and the action is a read-only evaluation or preparation path that the CLI can reverse without changing the current serving model. The managed catalog UI MUST additionally negotiate `model_catalog_read_lifecycle_v1` from fresh authenticated local status and its checked-in compatibility manifest, together with every required catalog/local-activation/transaction/adoption capability. A version floor alone MUST NOT authorize the new read protocol. Unsupported, missing, stale or partial capability combinations MUST show only existing observed current-model/status evidence and clear update, repair or refresh guidance; they MUST NOT launch catalog-economics, list/browse fallback, verification or fresh-result subprocesses to probe compatibility. Missing catalog capability is not a projection execution error. An authorized projection request that fails, times out or returns malformed data MUST show a distinct unavailable warning and retry affordance only after its owned reader is reclaimed. Exact pending-pin status/cancel controls retain their separate authorization; catalog support MUST NOT replace their pin checks.

**SPEC-044-R009 - Trust-preserving copy and localization.** All new Malibu strings for rates, potential, warnings, actions, and disabled reasons MUST be app-localizable, screen-reader accessible, and written as operator guidance rather than marketing. Warning copy MUST clearly distinguish "network catalog rate unavailable" from "model cannot be served" from "model needs preparation". Localization tests MUST cover the forbidden earnings-claim meanings from R004 in every shipped locale, not only the English source strings. Every shipped locale with right-to-left layout support MUST verify that row ordering, numeric rate labels, section grouping, and action buttons remain readable and navigable; if Malibu ships no right-to-left locale for this release, the release evidence MUST state that RTL is out of scope.

**SPEC-044-R010 - Privacy and secret boundary.** The projection and Malibu UI MUST NOT expose provider bearer tokens, wallet secrets, private config paths, raw signed feed bytes, hardware serials, MAC addresses, stable hardware UUIDs, provider identity UUIDs, raw verifier transcripts, private model cache paths, or full coordinator authorization errors. The ephemeral `source.process_launch_id` UUID is permitted only inside the local CLI-to-Malibu projection protocol for ordering and reconnect handling; Malibu MUST NOT render it in provider-visible UI, and diagnostics MUST redact or omit it unless a later support spec defines an approved redaction format. Diagnostics MAY expose redacted feed identity, model key, CLI version, and reason codes sufficient for support.

**SPEC-044-R011 - Reconciliation after action.** After any switch, prepare, evaluate, adopt, or cleanup transaction completes, Malibu MUST refresh the CLI projection and reconcile the visible current model, readiness, rates, warning state, and staging cleanup state from the new projection before declaring success. If Malibu previously requested cancellation for a transaction and later receives a `succeeded` terminal event for the same `transaction_id`, Malibu MUST show a distinct localized disclosure that the cancellation request was received but the action had already committed before it could take effect. When a refreshed projection is available, Malibu MUST display the resulting outcome (such as model ready, switch pending, or cleanup completed) alongside that disclosure rather than presenting an unqualified success state. When the refreshed projection is not available, Malibu MUST keep that cancellation-too-late disclosure visible, state that the model state refresh is required and the outcome is not yet known, and surface warning code `projection_timeout` after the timeout bound rather than declaring a completed model change. If Malibu dispatches an available action and receives no terminal CLI event within the action's `action_timeout_seconds`, Malibu MUST show failed or needs-attention state with warning code `projection_timeout`. If Malibu receives a terminal CLI event without a matching refreshed projection, Malibu MUST show pending for no more than the shorter of 30 seconds after the terminal event and the time remaining before `action_timeout_seconds` elapses from the original action dispatch; after that bound, Malibu MUST show failed or needs-attention state with warning code `projection_timeout`, not a completed model change. If a refreshed projection later arrives after Malibu has shown `projection_timeout`, Malibu MUST update the model-state display from that projection, clear the `projection_timeout` warning, and, when a cancellation-too-late disclosure was shown for the same transaction, keep that disclosure visible with the resolved state rather than replacing it with unqualified success.

**SPEC-044-R012 - Release evidence.** A Malibu release that enables this experience by default MUST include automated tests for the CLI projection schema, feed trust/fallback/staleness priority states, row warning-code attribution, rate math normalization and display units, browse-row non-actionability, immediate and deferred switch gating, Swift decoding, UI grouping, projection-failed fallback, CLI restart sequencing, disabled-action copy, progress rendering, localization/accessibility coverage including any shipped RTL locale, staging cleanup/reporting, and post-action reconciliation. The bootstrap extension MUST additionally test confirmed preparation, real prepared-only recommendation production without any downloader calls, explicit activation before admission with null economics, capability/protocol downgrade, cancellation at every preparation phase and publication race, crash/reconnect recovery, ownership/target rejection, cleanup confinement, and fresh projection before success. Fixture tests MUST NOT be represented as physical-model or production qualification. Production promotion MUST additionally capture signed release evidence, using the repository journey-result signing format governed by `requires_signed_journey_result`, that an old CLI receives the static fallback UI and a compatible CLI renders trusted rates without exposing secrets or unsupported actions.

## 4. Implementation, tests, and journeys

The intended implementation is a CLI-first projection, then an app-only presentation layer:

1. Add a CLI command or local status endpoint, for example `models catalog-economics --json`, that combines signed model catalog rows, signed rate-card projection, demand/recommendation signals, local artifact readiness, and typed action descriptors. The invocation spelling is illustrative; Malibu must use the capability-negotiated interface advertised by the CLI rather than hardcoding this example command.
2. Advertise `model_catalog_economics_v1` in the same capability surface Malibu already uses for model management.
3. Extend Malibu model management decoding with a new envelope while keeping the current `models_list.v1` and browse behavior as fallback paths.
4. Replace the static switcher modal with a sectioned catalog view that supports current, ready, network-catalog, preparation-required, and blocked rows.
5. Wire only CLI-owned typed transactions into action buttons; all other rows are informational.
6. Add post-action refresh and failure reconciliation so the UI never declares a model change from a stale terminal event alone.

The first journey id is `JOURNEY-MALIBU-MODEL-ECONOMICS`. The journey should cover a current static qwen3-8b install, a compatible CLI with trusted live or static rates, a stale/mismatched feed set, an uninstalled catalog model with a trusted provider payout rate, a verified locally ready model, an unsupported browse-only model, and an old CLI fallback.

## 5. Open gaps

| Requirement/domain | Verdict | Owner | Issue | Evidence needed |
|---|---|---|---|---|
| `SPEC-044-R001..R012` | `DECISION_REQUIRED` | `@Augustas11` | `#614` | Product approval of the economics UX copy, CLI projection schema, typed action set, automated test mapping, and signed release journey. |
| `malibu-model-economics-ux` | `DECISION_REQUIRED` | `@Augustas11` | `#614` | Authority acceptance that Malibu may present signed catalog economics only as a CLI-owned projection and not as app-side feed verification. |
| `SPEC-046/SPEC-047 integration` | `DECISION_REQUIRED` | `@Augustas11` | `#1240` | Approval that SPEC-044 is narrowed to network economics and does not own provider-local BYOM discovery or network admission. |

## 6. Evidence

Current implementation evidence is partial and non-conformant:

- `phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift` already capability-gates model management and classifies current, ready, preparation-required, and blocked rows, but its row schema does not carry rate-card economics.
- `phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagementViews.swift` already has a model switcher modal and recommendation copy surface, but it mostly renders the current autotuned model and disabled advisory actions.
- `phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift` already emits `models_list.v1` with verified local artifact checks.
- `phase3-binary/Sources/macprovider-cli/ModelsBrowseCommand.swift` already emits discovery-only browse rows with null actions and non-actionable state.
- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift` already loads signed candidate, demand, and rate-card feeds and projects rate signals for recommendations.
- `phase5-gateway/internal/router/public_feeds.go`, `phase4-coordinator/internal/buyer/autotune_feeds.go`, and `phase4-coordinator/internal/buyer/rate_card.go` already expose and verify rate-card feed material used by the CLI path.

No requirement is conformant until the new projection, UI, tests, and signed journey evidence land.

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

## Protocol-2 transaction control and recovery amendment (v0.1.2)

This amendment governs R002, R007, R010 and R011. The unshipped protocol-2 action shape adds nullable `operation_generation`; available prepare/evaluate/cleanup actions MUST carry a canonical lowercase UUID reserved by the CLI under its journal lock before projection. An adoption action MUST carry its successful source evaluation generation. Other legacy kinds and unavailable actions MUST carry null. The new `model_catalog_transaction_event.v1` stream MUST additionally carry that exact generation. Replay identity is UUID/kind/generation/sequence; sequence is monotonic within the generation and a replay need not begin at one. Landed protocol 1 MUST omit these additions and retain its original shape. No client may synthesize a generation for legacy journals or pending records.

Protocol 2 MUST emit top-level `recoveries`, including an empty array, and nullable `source.transaction_context_sha256`. The latter is a lowercase 64-character SHA-256 digest for local routing only; available local transaction/recovery actions require it. It MUST NOT confer readiness or admission authority. Private paths, config bytes, user/home identities and root metadata MUST NOT appear in the projection, diagnostics or UI. Protocol 1 MUST omit both fields. Protocol-2 clients MAY interpret absent recoveries as empty, but MUST reject duplicate targets/UUIDs, malformed entries, unknown fields or foreign actions. Each recovery is exactly `{target_model_id, model_key, action}`: canonical historical target, historical key used only for transcript validation, and an available confirmed cleanup_staging action with matching UUID/generation, 1800-second timeout and null size/reason.

Cleanup discovery MUST read only validated private journal evidence, independently of current feed freshness, supported-model list, discovery or fit. Expose one recovery per exact case-sensitive target ordered by createdAt then UUID; subsequent refresh exposes the next. Corrupt/unsafe records MUST remain preserved and non-actionable. Render a separate Staging cleanup section with transaction-based UI identity; never merge/rekey a current model row or use historical keys for current identity, offers or economics. Ordinary rows retain unavailable cleanup_staging. Cleanup confirmation names target/owned staging and preservation of published/active artifacts. Dispatch requires confirmation, compatible authenticated CLI evidence and no other pending mutation. Matching terminal plus fresh validated projection is required before success; unavailable feeds alone MUST NOT hide recoverable staging.

The app MUST persist an owner-private bounded pin and pending selector atomically before starting mutation: UUID, target, key, kind, generation, timing/cancel intent, verified CLI signature/CDHash/team/identifier/capabilities, fixed config identity/hash, user/kernel home, opaque context digest and snapshot identity. Missing, unsafe or legacy pin state is recovery-required and blocks new mutation. The configured executable path is comparison-only, never a persisted arbitrary launch input. Config/code replacement MUST NOT silently refresh authorization.

A verified private CLI snapshot MAY service exact status/cancel/result while measurement drains the live incumbent. Capture through a safely opened source descriptor, validate strict signature and live-peer identity, bound one completed snapshot to512MiB and total temporary/completed storage to1GiB, publish atomically in a0700 directory with0700 executable, and revalidate before use. No suspended child or supervisor target is required. Source replacement after validation may execute only the already verified private snapshot. Snapshot resources/signing require actual evidence; missing resources fail closed. Orphan snapshot cleanup is bounded under the same metadata lock and cannot delete CLI journals/staging/models. The trusted operator UID remains the security boundary.

Offline controls MUST be typed status/cancel/result only, bind the persisted exact selector, and independently validate configured source plus private snapshot, config and context. No live-peer fallback may authorize new prepare/evaluate/cleanup/adopt/offer during drain. Result additionally requires an exact successful evaluation. Helpers MUST have a ten-second execution cutoff, independent early child parent/EOF/deadline guard, one cross-app inherited same-open-description flock held until child exit, and bounded output (8MiB stdout/result,64KiB stderr and JSONL/partial line). Parent and child MUST retain the lock without explicit shared LOCK_UN; no helper may overlap a delayed reap. Timeout/abandonment may terminate only the exact directly spawned control helper, never owner/incumbent/probe/process group. It MUST preserve uncertain transaction state and persisted cancel intent. Cancel has priority after an in-flight helper is reclaimed. GUI crash and pre-argument child startup, descriptor inheritance, flooding and repeated timeout behavior require real subprocess tests. Helper exit is not transaction cancellation.

App admission status, fresh offer and retry MUST use separate predicates with fresh current supported target and live peer, never offline authorization. Status permits every recognized state without requiring fit/weights. Confirmed fresh offer requires ready/fitting and local_only/not_offered/offerable/revoked/withdrawn/offer_rejected. Confirmed retry requires ready/fitting and offer_submitted/sandbox_probe_only/network_admitted_unsettled/catalog_priced; the CLI original journal and fresh coordinator state remain authoritative. Unknown, settlement_capable and network_visible_unpriced do not permit either mutation. Missing retry journal is actionable failure, never implicit re-offer. A failed admission action MUST leave status refresh usable. None of these predicates grants paid readiness.

### Transaction snapshot resource custody amendment (v0.1.2)

A private transaction payload MUST preserve the signed CLI's required installed resource layout, including adjacent `mlx.metallib`, without canonical-install re-exec or resource-path environment overrides. Pin version2 binds the fixed executable/data closure and exact relative inventory/digests under the existing owner-private installed-resource trust boundary. Native CLI signature/CDHash remains mandatory; a copied resource hash MUST NOT be presented as signing provenance or catalog/economic authority. Existing signed compatibility/catalog validation remains independently required. Reject unsafe nodes, unknown selected descendants, executable-bearing data bundles and size/count/depth excess. Publish a complete private payload atomically and durably before pending authorization/dispatch; version1 pins cannot silently acquire new resources or authority.

Resource preflight is part of the request lifecycle. Start the existing ten-second control deadline before bulk reads, hashing and native verification, perform those operations off the main actor, and retain at most one owned validation worker and exact request/lease. Abandonment permanently revokes its dispatch/pending-mutation authorization. Noninterruptible filesystem work may retain its precise descriptors/leases until it returns; report bounded uncertain/busy state, admit no replacement worker queue, and never dispatch when stale work later completes. Transfer the remaining absolute deadline to an authorized helper rather than resetting it. Initial payload capture uses its separate bounded responsive lifecycle with identical late-authorization fencing. A write already in progress at revocation may preserve exact durable pending as launch-not-confirmed; it MUST NOT silently authorize a later launch.

Pending-backed payload recovery requires full executable closure, inventory/hash and native-code validation. Retire the intact payload before clearing pending. No-pending disposal MUST use a distinct deletion-only safe-subset predicate under the fixed locks and private root identity: missing or partially copied allowlisted members may be reclaimed, but unsafe/unknown/substituted nodes or conflicting/malformed pending evidence block disposal. Partial payloads MUST NOT execute or restore authorization. Interrupted construction and per-member deletion must remain safely recoverable without deleting installed resources, model artifacts or CLI transaction history. Metal-resource loading, actual pinned MLX expression evaluation, signed snapshot execution and actual-model settlement are separate evidence classes.

### Owned catalog reads and exact-target verification amendment (v0.1.2)

The unshipped protocol-2 local projection MUST include a closed per-row `local_verification` object containing only `state`, one of `not_applicable`, `missing`, `unverified`, `verified`, `invalid`, `incomplete`. Protocol1 MUST omit it and preserve its standalone CLI contract. `missing` requires an actual bounded absence observation; observation failure is not absence. `verified` requires this read's complete exact signed-primary artifact/config verification. Local weight-presence readiness and evaluate/adopt availability MUST NOT derive from metadata, historical seals or a previous read. Unverified/incomplete existing artifacts use `verification_required` (except independently current-serving state), `local_verification_required`, and explicit local-files-need-verification copy; they MUST NOT be presented as missing or offered an overwrite/preparation shortcut. Observed invalid artifacts use `local_artifact_invalid`. Non-applicable rows gain no local authority. Durable observations, including incomplete/invalid ones, MUST shadow sibling cache metadata. Coordinator admission, prices and settlement remain independently authoritative.

Quick local projections MUST NOT hash weight contents. An explicit target verification read hashes exactly one currently signed canonical model/revision/artifact identity, sharing one request-local inspection between discovery and action construction; consumers MUST NOT independently rehash. The app offers Verify local files and Stop verification, shows measured bytes and liveness without invented percentages, and discloses prolonged work. Prepare/evaluate success recovery uses this same read and its final fresh projection without immediately restarting the hash. Cancelled/failed/cleanup recovery uses complete fresh quick projection where ready bytes are not required. A failed read MUST preserve exact pending custody and historical mutation truth, offer an explicit retry after reader exit, and MUST NOT rerun the mutation owner.

Managed reads use `models catalog-economics --json --config FIXED_CONFIG --local-activation --app-read-request UUID --app-read-mode quick|verify --read-lock-fd 199 --read-lifetime-fd 200`. Verify additionally requires `--verify-local-model CANONICAL_MODEL_ID --expected-context-sha256 DIGEST`; quick forbids them. UUIDs/digests are canonical. No model/provider/coordinator/socket/cache/namespace/origin/skip override is permitted on this bound path, including skip-coordinator-status. The app MUST NOT inject its former redundant socket override. Verify MUST compare the expected opaque context against existing-root-only finalization before hashing or reservations, consume the same safely captured config throughout, and revalidate context/root identity at emission. It MUST NOT create a missing root to satisfy a supplied context. Fresh result restoration uses only the exact read-only transaction result selector with mode `result`, expected context and the same read descriptors/ten-second lifecycle. Offline pinned control-r4 flags and app-read flags are mutually exclusive; no new mutation or heartbeat privilege is granted.

Quick/result reads retain a ten-second total budget. Verify retains a 1,800-second absolute budget from reservation including executable preflight, first accepted event within ten seconds, at most five seconds between liveness events, fifteen-second liveness failure and sixty-second no-byte-advance failure once hashing starts. Initial/final nonhash phases each fit ten seconds without resetting the absolute budget. Nested reservation, recommendation and complete recovery enumeration MUST receive the caller's remaining budget, not reset per-action eight-second deadlines. An incomplete enumeration MUST report unavailable, not an empty or truncated complete recovery set. Expiry prevents further reservation/publication; an already durable partial journal transition retains ordinary exact recovery. No replacement reader or late result is authorized by timeout.

Verify stdout is closed JSONL `model_catalog_read_event.v1` with exactly `schema`, `request_id`, `event_sequence`, `target_model_id`, `model_key`, `kind`, `bytes_completed`, `error_code`, `projection`. Sequence starts at1 and strictly increases; request/target/key remain exact. Kinds are `accepted`, `progress`, `completed`, `failed`; bytes is a nonnegative monotonic UInt64 of bytes actually hashed. Heartbeats are not byte progress or readiness. Projection is null except for the single completed terminal; error is null except failed, using `verification_incomplete`, `artifact_invalid`, `authority_changed`, `context_changed`, `read_limit_exceeded`. Completion requires the full validated fresh projection, zero process exit and EOF, with no trailing event/data. Reject unknown/duplicate keys, malformed/oversized/out-of-order/mismatched envelopes and fabricated progress. Limits are8MiB total stdout,64KiB stderr,1MiB per line and4,096 events. Encode/measure supported projection/recovery capacity and conservatively preflight final response size before expensive hashing. Overflow MUST preserve custody with explicit unavailable guidance; never truncate recoveries or grant readiness. A high-count complete below-limit fixture and exact/over-limit cases are required evidence; no universal disk-throughput claim follows from these transport limits.

For an owned verify read, preflight MUST encode the complete prospective
`completed` event with the production event encoder, including the exact repeated
outer request/target/model identifiers, maximum applicable sequence and byte
widths, projection, and terminating newline. The 2 KiB conservative reserve is
additional to that measured framed content; it is not a substitute for counting
accepted variable strings or escaping. A stable oversized current observation
MUST fail before artifact hashing, and the actual final framed event MUST be
checked again before emission. The read MUST bind the selected demand, candidate,
rate, and artifact feed bytes, signer identities, effective versions, and trust/
fallback classes across hashing; any changed or expired selection fails rather
than silently changing economics or authority in the same read.

Complete owned recovery enumeration requires every active-index member to have
decidable, stable primary and applicable origin/provenance evidence under the
original request and current helper budgets. Missing, unsafe, unreadable,
undecodable, changed, or otherwise undecidable active evidence is incomplete,
never an empty recovery set. Recommendation reconciliation/index preparation
MUST occur before the initial cleanup inventory; action construction MUST retain
the same budgets; and a final complete inventory plus compact membership/primary/
provenance witnesses MUST be revalidated after action-side journal work and
before emission. No journal-mutating helper may run after that final witness
check. Both recovered-success and newly committed-success evaluation-index paths
MUST propagate read, validation, publication, durability, cancellation, and
budget failures. If an exact recommendation pointer may already be durable when
acknowledgment fails, preserve that durable truth for a later fully validated
read; do not report false pointer absence, erase it, or emit a completed
projection from the failed read.

Verification MUST use the existing canonical artifact hash and strict relative-path policy, bounded enumeration (10,000 entries,4,096-byte relative paths,8MiB config capture), overflow checks and streamed large files. Check the original budget/cancellation before and after enumeration/open/read and between at-most1MiB chunks. Use no-follow descriptor-relative regular-file opens, reject unsafe links/placement, and compare open-file identity/size/mtime/ctime and complete bounded metadata snapshots before/after hashing and at final root/parent placement revalidation. Re-resolve current signed target/feed and admission/runtime/hardware observations after hashing through the same consumed config; authority change/expiry invalidates the result. Final timestamps/sequence describe publication, not read start. This is an observation-window guarantee under the trusted operator-UID boundary; execution-time verification remains required and local inspection grants no network or economic authority.

The app MUST own one exact read handle/nonce and directly spawned child from preflight through actual exit/reap, including cancellation, timeout, app death and delayed filesystem return. Executable verification runs off the main actor and uses the trusted installed managed-peer executable/resources; abandonment forbids late spawn. A separate fixed private `ModelTransactions/catalog-read.lock` (0600, parent0700) provides cross-app single flight and is inherited as the same flock open description on FD199. FD200 is the read-only end of the app lifetime pipe. CLI verifies the expected fixed lock inode/mode/owner and held lock plus pipe direction, and installs its own early parent/EOF/deadline monitor before config/resources/hash work. Read-only self-exit MUST NOT signal a mutation owner/provider/candidate. Keep the lock until exact child exit without explicit shared unlock. The app revokes nonce, closes lifetime output, sends TERM only to its unreaped direct child and KILL after one-second grace if necessary, then reaps; it MUST NOT release the slot simply because a UI continuation completed. Noncooperative kernel I/O retains an honest busy/waiting state until reap, with no replacement queue, PID-after-reap signal or process-group kill. Controls keep independent custody/resources and must remain usable during long reads.

The new lifecycle capability MUST be advertised only by implementing CLI code and required by the app manifest plus fresh managed-peer evidence, even at the existing observed version floor. Unsupported peers retain status-only/update guidance without a legacy generic-run fallback; standalone protocol1 remains available. Changing the complete manifest digest may invalidate older pending pins: do not weaken that check or promise transparent upgrade recovery. Test old-manifest rejection and independently valid current-manifest pending controls when fresh catalog capability is unsupported. Actual app refresh/verification/result producers MUST supply their unchanged captured argv to a real parsed CLI fixture; separate hardcoded equivalent arrays are insufficient. Real subprocess timeout, parent death, delayed progress beyond ten seconds, lock exclusion, bounded output and exact pending-reconciliation tests are required in addition to Xcode/CLI unit tests. Production-signed snapshots, real-model throughput and settled requests remain separate qualification evidence.

# SPEC-036 — Compute-Integrity Receipt Companion

**Status:** v0.1-draft
**Date:** 2026-07-10
**Depends on:** SPEC-015 v0.4.2, SPEC-022 v0.1.5, SPEC-026 v0.26, SPEC-030 v0.1-draft (Losslessness Probe — shared distribution-snapshot / support-selection / TV-interval / probe-transport primitive)
**Companion research:** `docs/research/compute-integrity-receipt-2026-07.md`

**Numbering + dependency note (2026-07-22).** This spec was drafted as `SPEC-030`
against `SPEC-029` before the 2026-07-10 corpus-hygiene renumber. It is now
canonical **SPEC-036** to resolve the collision with
`SPEC-030-losslessness-probe.md`, and its shared measurement primitive dependency
is rewired from the pre-renumber `SPEC-029` to canonical **SPEC-030 (Losslessness
Probe)**, which owns the distribution-snapshot / `support_selection_v1` /
TV-interval / authenticated-probe-transport machinery this spec composes on. The
compose-vs-duplicate reconciliation and this renumber are recorded in
`beta/DECISION_CRITERIA.md` Entry 181, which lands in this delivery's decision-log
PR (merged last so it reflects shipped state).
The settlement-bearing wire constant remains `compute_integrity_probe_v1`
(distinct from SPEC-030's non-settlement `losslessness_probe_v1`); it is the
SPEC-036 carrier and is intentionally NOT renamed, since nothing is shipped yet
and a distinct settlement profile is a load-bearing safety boundary (FR-6).

## 1. Purpose

SPEC-036 defines an additive compute-integrity drift gate for MacProvider paid
settlement. It extends the SPEC-022 settlement decision with coordinator-owned
provider/model drift state while preserving the existing SPEC-015 v0.4 receipt
wire shape.

The problem: SPEC-015 v0.4 receipts prove that a provider signed a strict
settlement tuple binding request identity, route snapshot, model id, model hash,
prompt/output hashes, usage, and terminal state. They do not prove that the
provider actually computed the output with the pinned model if the provider can
lie about its local computation and still sign a syntactically valid receipt.

SPEC-036 adds a measurable drift state:

```text
quarantined_compute_drift
```

When the effective compute-integrity policy is in enforce mode, a covered paid
request whose request-start covered compute-integrity key is in
`quarantined_compute_drift` MUST NOT create buyer final debit, provider credit,
earnings visibility, settlement-sweep inclusion, or payout readiness.

## 2. Scope

In scope:

- Coordinator-owned compute-integrity canary state keyed by provider, model,
  target model hash, tokenizer identity, sampler stage, target generation,
  sampling profile, corpus version, and threshold version.
- Provider-vs-reference TV-distance measurement composed on the SPEC-030
  (Losslessness Probe) distribution-snapshot / `support_selection_v1` /
  TV-interval primitive, specialized to a provider-vs-trusted-reference arm.
- Hybrid reference-source policy: trusted coordinator reference as enforcement
  authority, N-provider consensus as telemetry.
- Additive settlement-verifier context and reason code.
- New-provider billable-routing gate after SPEC-026 onboarding identity is
  established.
- Warn-only to enforce migration path.
- Operator/auditor evidence export.

Out of scope:

- Any change to SPEC-015 v0.4 receipt tuple fields.
- Any change to SPEC-015 v0.4 `usage` fields.
- Rewriting SPEC-022's top-level settlement outcome enum.
- Redefining the shared measurement algorithms; SPEC-036 composes on SPEC-030
  (Losslessness Probe) §FR-3 (transport/auth/load-bound policy values),
  §FR-7 (`support_selection_v1` construction), and §FR-9 (TV-interval computation)
  rather than re-specifying them. SPEC-036 does NOT inherit SPEC-030 §FR-4's
  digest/replay wire framing — it owns its settlement-bearing digest preimage,
  replay binding, Tier-2 carrier, and result variants (FR-6), reusing only the
  encrypted-carrier structural pattern by substituting the profile discriminator.
- Covert canaries or buyer-indistinguishable probes.
- Hardware attestation, binary attestation, or cryptographic proof that a
  malicious provider honestly ran a model.
- Buyer-issued quarantine-grade canaries.

## 3. Definitions

**Compute-integrity canary:** A coordinator-issued non-billable probe that asks
a provider to produce compact next-token probability snapshots at selected
measurement positions and compares them against a coordinator-held reference
distribution for the same model/hash/profile/corpus key.

**Trusted reference:** A coordinator-controlled MacProvider runtime admitted
only when its loaded model hash matches the signed catalog hash for the model
under test.

**Consensus reference:** A telemetry-only aggregate from at least three
independent providers that are not the candidate under test.

**Reference event:** A coordinator record binding a single trusted-reference
source snapshot to the complete corpus-position set for one covered key, with the
retained compact evidence needed to recompute the TV interval for every
provider/reference union support used by a verdict.
The payload key set is closed over: `model_id`, `target_model_hash`,
`tokenizer_identity`, `sampler_stage`, `sampling_profile`, `corpus_version`,
`threshold_version`, `reference_source_id`, `reference_failure_domain_id`,
`computed_reference_distribution_summary`, `runtime_build_provenance_digest` AND
`golden_fixture_validation_digest` (both required for every enforce-counted
reference — golden fixture is additional, never a substitute; FR-5),
`refresh_timestamp`, `support_selection`,
`normalization_basis`, `k`, `position_set_digest`, and a closed `positions[]`
array. `position_set_digest` is the SHA-256 over the RFC 8785/JCS canonical JSON array
`[[prompt_id, position_index], ...]` of the pairs covered by the event, sorted by a
total order: ascending bytewise UTF-8 `prompt_id` first, then ascending numeric
`position_index`. This fixes both the pair's JSON shape (a two-element array) and
the sort, so equivalent position sets always produce the same digest. Each `positions[]` element is closed over `prompt_id`, `position_index`,
`token_prefix_digest`, `context_hash`, `reference_top_k_token_ids`,
`reference_top_k_probabilities` (the reference's own probability for each of its
top-K ids), `reference_full_distribution_ref` (either inline offline per-token
reference probabilities, or `retained_evidence_object_digest` plus a retained
object, sufficient for the coordinator to recompute the reference probability for
ANY provider-selected token and the reference tail mass outside ANY valid returned
union), and `reference_greedy_tail_bound`. Every reference event MUST bind its `reference_top_k_token_ids` at the maximum
`k = 256` as an ordered (non-increasing probability, ascending token id tie-break)
list; the `K = 64` probe uses the deterministic length-64 prefix, and a mandatory
`K = 64 → 256` retry (FR-7) — including reference-vs-reference fault retries (FR-5)
— MUST reuse the SAME reference-event digest, so both K levels derive from one
immutable snapshot. A reference event is created before any
provider probe, so it MUST NOT store provider-dependent union probabilities or a
single union tail scalar; the per-verdict union reference probabilities and union
tail mass are computed at verdict time from `reference_full_distribution_ref` and
stored in the per-verdict evidence (FR-7), bound back to this event's
`reference_event_digest`. A single reference event MUST cover the complete
corpus-position set for its covered key (one `positions[]` per source snapshot), so
that a verdict and its audit replay draw every position from the same event.

Reference quorum (FR-5) counts **distinct independent source snapshots whose
`position_set_digest` values are identical**: two reference events covering
different position sets do NOT satisfy quorum. The stored `reference_event_digest`
is an outer field and `payload.reference_event_digest` MUST NOT exist. The digest
MUST be SHA-256 over the RFC 8785/JCS canonical object
`{type:"reference_event_v1", schema_version:"reference_event_v1", payload}`.

**Stable provider identity:** The durable coordinator provider-account row that
survives SPEC-026 re-onboarding, admission-key rotation, and recovery for the same
provider — normally the durable `provider_id` account record, NOT the rotatable
SPEC-026 admission/registration key (which may be regenerated through recovery
while preserving the account). SPEC-026 admission-key rotation or recovery MUST
preserve `stable_provider_identity`; only creation of a genuinely new provider
account row is a new stable identity, and a new account row is a new identity
unless an explicit, dual-approved cross-identity migration record links it to the
prior one. A new `assigned_id`, a new `target_generation`, an admission-key
rotation, or a recovery MUST NOT clear active compute-integrity quarantine or block
state, nor reset the sub-threshold accumulators (FR-10, FR-12), for the same stable
provider identity.

**Overlay key (canonical accumulator/risk key):** `(stable_provider_identity,
model_id, target_model_hash, tokenizer_identity, sampler_stage, corpus_version,
threshold_version, <coverage-scope sampling-profile dimension>)`. The
coverage-scope sampling-profile dimension is identical to the window key's: the
named `sampling_profile` when the policy uses per-profile windows, and the constant
`__all_profiles__` when the policy uses an all-profile window. The overlay key
excludes the provider-mutable dimensions `assigned_id` and `target_generation` and
excludes `provider_id`. It is scope-consistent with the window key on the profile
dimension, so accumulators are never merged across profiles that the policy scopes
separately.

**Stable-identity risk overlay:** The coordinator-owned state layer keyed by the
overlay key. It is the **single canonical owner** of active
`quarantined_compute_drift` and `blocked:<reason>` state and of the three rolling
accumulators — the `quarantine_candidate`/`warn` window count, the 24-hour
abusive-inconclusive count, and the 24-hour onboarding-failure count. Because the
overlay key excludes `assigned_id` and `target_generation`, these carry across warm
swaps, same-hash reloads, provider reconnects, target-generation increments, and
admission-key rotation, so provider-originated churn on a mutable key dimension
cannot launder an active quarantine or reset an in-progress accumulator (FR-10,
FR-12). Request-start capture (FR-4) MUST consult the overlay for the request's
overlay key: an active overlay quarantine/block is inherited as the request-start
state.

**Swap-laundering overlay:** A higher-level coordinator-owned state layer keyed by
`(stable_provider_identity, model_id)` — spanning all hashes, tokenizers,
generations, and profiles for that provider and model. It owns
`blocked:swap_laundering_suspected` (FR-12). Request-start capture (FR-4) MUST
consult the swap-laundering overlay before the per-key stable-identity risk overlay;
an active swap-laundering block denies all covered paid routing/settlement for that
provider/model until dual-approved manual review.

**Compute-integrity key:** `(stable_provider_identity, provider_id,
assigned_id, model_id, target_model_hash, tokenizer_identity,
sampler_stage, target_generation, sampling_profile, corpus_version,
threshold_version)`. This full key labels an individual canary result and its
request-start capture row; it is NOT the accumulator owner.

**Window key:** `(stable_provider_identity, model_id, target_model_hash,
tokenizer_identity, sampler_stage, target_generation, corpus_version,
threshold_version, <coverage-scope sampling-profile dimension>)` — the named
`sampling_profile` for per-profile windows, `__all_profiles__` for all-profile
windows. The window key owns the positive measurement/verdict state (`unknown`,
`pending`, `verified`, `warn`, `expired`) and the rolling verdict window. Window
and overlay keys MUST NOT include `assigned_id`. The overlay key is exactly the
window key with `target_generation` removed.

**Sampler stage:** The normative probability-capture point. V0.1 allowed values
are `pre_temperature_logits`, `post_temperature_logits`, and
`post_sampler_probabilities`. A policy MUST choose exactly one sampler stage for
each covered key. V0.1 enforce mode supports only `post_sampler_probabilities`,
defined as the full-vocabulary next-token probability distribution after the
sampling-profile processors and before the stochastic draw, mapped to SPEC-030's
`post_processors_post_sampling_profile_next_emitted_token` capture point.
`pre_temperature_logits` and `post_temperature_logits` are observe/warn-only
until a future SPEC-030 addendum defines their provider-side capture mechanism
and normalization basis.

**Compute-integrity state:** One of `unknown`, `pending`, `verified`,
`warn`, `quarantined_compute_drift`, `blocked:<reason>`, or `expired`.

**Drift candidate:** A single canary result whose provider-vs-reference
`tv_lower` exceeds the active quarantine-candidate threshold after required K
retry and validation.

**Warn-only mode:** Policy mode that computes and emits compute-integrity state
but MUST NOT alter buyer debit, provider credit, earnings, payout readiness, or
buyer-facing claims. Warn-only onboarding results MAY be surfaced as readiness
telemetry, but MUST NOT block covered paid routing.

**Enforce mode:** Policy mode in which request-start
`quarantined_compute_drift` makes the settlement outcome `quarantined` with
reason `compute_drift_quarantined`.

**Covered paid routing eligibility:** In enforce mode, covered paid routing is
allowed only when the request-start compute-integrity state is fresh
`verified` or fresh `warn` for a window whose sampling-profile coverage
subsumes the buyer request. `unknown`, `pending`,
`quarantined_compute_drift`, `blocked:<reason>`, `expired`, unreadable state,
stale reference events, or uncovered sampling profiles MUST fail closed.

## 4. Threat Model

SPEC-036 v0.1 is not a cryptographic proof of honest computation. It detects
measurable divergence from an approved reference distribution under
coordinator-issued probes. It is useful against implementation drift, stale or
wrong model artifacts, broken sampler paths, low-effort substitution, and
providers that cannot make their output distribution match the trusted
reference.

SPEC-036 v0.1 does not defeat a malicious provider that can identify overt
probes and return perfect reference-matching distributions only for those
probes. Covert or independently verifiable probes require a later spec because
they interact with buyer traffic, billing, receipts, and abuse resistance.

## 5. Normative Requirements

### FR-1 Policy surface

The coordinator MUST expose exactly one authoritative
`compute_integrity_settlement` policy surface.

The policy MUST include:

- `policy_version`.
- `mode`: `observe`, `warn_only`, or `enforce`.
- `enabled_at`.
- Covered `model_ids`.
- Covered target model hash or signed-catalog selector.
- Covered tokenizer identity.
- `sampler_stage`.
- `normalization_basis`.
- Covered `entrypoints`.
- Covered sampling profiles.
- Sampling-profile coverage rule: per-profile windows or all-profile windows.
- Required reference source mode: `trusted_reference` or `hybrid`.
- `reference_fault_check_version`: the version identifier of the active
  reference-vs-reference fault ruleset (the FR-5 predicate, independence rules, and
  fault thresholds). It is coordinator-owned; changing it invalidates prior
  reference-set admissibility evidence and forces reference re-admission for every
  covered key.
- `hardware_runtime_class`: the reference/provider hardware+runtime class the policy
  covers (see FR-8 threshold keying). A policy MUST cover exactly one class per
  covered key or declare the reference set representative of the covered classes.
- `corpus_version`.
- `threshold_version`.
- `window_size_days`, default 7 (the rolling verdict-counting window).
- `positive_state_freshness_ttl_hours`, default 24 (the maximum age of the newest
  eligible canary before `verified`/`warn` expires as `window_ttl_expired`). Enforce
  activation MUST refuse a policy whose TTL is less than twice the scheduled per-key
  canary cadence, so a single missed probe does not routinely expire payable state.
- `min_window_canaries`, default 5.
- `quarantine_candidate_count`, default 3.
- `clear_pass_count`, default 5.
- Reference freshness TTL, default 24 hours.
- Abusive inconclusive limit, default more than 3 inconclusive probe results
  in 24 hours for the same key.
- `disclosure_copy_version` and `disclosure_copy_digest` (FR-15).
- `reference_unavailable_auto_downgrade`: optional automatic **policy-mode**
  downgrade (enforce → warn_only) — NOT a per-row settlement override — so a total
  reference-fleet outage does not empty the paid pool. When set, a whole-covered-set
  reference-staleness condition MAY auto-flip the policy mode to `warn_only` for a
  bounded window (`auto_downgrade_max_minutes`, capped, dual-approval-required to
  extend) with an audit record. Because the flip changes the mode only for **new**
  admissions (which then capture `warn_only`, i.e. no money effect), it never
  reclassifies an already-captured row and preserves SPEC-022 request-start
  immutability. Already-captured coordinator-attributable non-payable rows remain
  non-payable (fail closed); SPEC-036 never settles a captured covered enforce row
  as payable except from a fresh `verified`/`warn` capture. **Carve-out:** the
  auto-downgrade suspends only new-verdict capability; it MUST NOT release adjudicated
  provider-attributable state. A key carrying an active `quarantined_compute_drift`,
  `blocked:swap_laundering_suspected`, `blocked:manual_review_required`, or
  `blocked:abusive_inconclusive` — verdicts already established from admissible
  references, independent of live references — MUST continue to be excluded from
  covered paid routing and settlement throughout the downgrade window, so a
  reference outage (or an induced one) cannot launder an adjudicated quarantine. Honest-provider
  compensation for delivered work voided by a coordinator-attributable lapse, if any,
  MUST use the operator-funded non-buyer instrument (FR-17) — subject to that
  instrument's per-provider daily caps and anti-Sybil eligibility as a distinct
  capped "voided-work compensation" category — outside the SPEC-022 settlement
  money-path. The trigger scope SHOULD match the reference-staleness scope: for a
  sharded fleet a partial outage MAY downgrade only the affected model/shard scope,
  so honest keys outside the outage are neither voided nor needlessly downgraded (for
  the minimal 2-node fleet any node loss drops every key below quorum, so the trigger
  is effectively whole-set).
- `circuit_breaker_policy`: a closed object defining deterministic activation.
  It MUST include `rolling_window_minutes` (positive integer), `event_time_basis`
  (enum `transition_recorded_at`), the in-scope transition set (fixed to new
  `quarantined_compute_drift` and new `blocked:reference_fault` transitions,
  deduplicated per covered key so repeated transitions on one key count once),
  `model_scope_threshold` (positive integer count of distinct covered keys per
  covered model within the window), `fleet_scope_threshold` (positive integer count
  of distinct covered keys across the policy within the window), and the boundary
  convention `activates_at_or_above` (`>=`). Scope precedence is
  whole-policy > model > key: a fleet-threshold breach activates the whole-policy
  breaker; otherwise a model-threshold breach activates that model's breaker. It MUST
  also include `quiet_window_minutes` (positive integer): the FR-16 clear
  quiet-window duration, measured on `transition_recorded_at`, with a
  `no_in_scope_transitions_for_at_least` (`>=`) boundary.
- `flapping_window_policy_v0_1`: disabled by default. When enabled, this object
  MUST include: `enabled` boolean; `lookback_window_days` positive integer;
  `metric` enum `median_tv_lower_margin_to_quarantine` or
  `max_position_tv_lower_margin_to_quarantine`; `threshold_margin` finite
  non-negative number; `min_pass_count`, `min_warn_count`, and
  `min_quarantine_candidate_count` non-negative integers; `action` enum
  `blocked:manual_review_required` or `none`; `clear_rule` enum
  `dual_approval` or `clear_pass_count_sequence`; and `audit_fields` containing
  metric values, canary ids, action, approver, and clear evidence.

Activation MUST refuse any covered route, trusted-reference event, window, or
request-start capture that lacks an exact policy match for the covered model,
hash/catalog selector, paid entrypoint, tokenizer, sampler stage, normalization
basis, actual covered sampling profile or profile set, sampling-profile coverage
rule, required reference source mode, corpus version, and threshold version.

`observe` and `warn_only` MAY compute verdicts and emit audit events, but MUST
NOT change buyer debit, provider credit, earnings, payout readiness, or
buyer-facing verification claims.

`enforce` MUST refuse activation unless:

- SPEC-030 (Losslessness Probe) is at least v0.1-draft and the implementation
  exposes the inherited authentication, load-bound, support-selection, and
  TV-bound primitives (SPEC-030 §FR-3, §FR-7, §FR-9) required by SPEC-036 FR-6 and
  FR-7. (The digest preimage, replay binding, encrypted carrier, and result
  variants are SPEC-036-owned per FR-6, not inherited from SPEC-030 §FR-4.)
- SPEC-036 enforce is subordinate to SPEC-022. The SPEC-022
  `verified_model_settlement` policy MUST itself be in `enforce` mode for the
  covered models and paid entrypoints that SPEC-036 enforce covers, and SPEC-036's
  covered `model_ids`/`entrypoints` MUST be a subset of SPEC-022's enforce
  coverage. SPEC-036 MUST NOT change money outcomes for any request where SPEC-022
  is not itself in enforce. Activation MUST refuse a SPEC-036 enforce coverage set
  that is not fully subsumed by SPEC-022 enforce coverage.
- All covered models have signed catalog entries.
- At least two independent fresh trusted reference events are active for every
  covered `(model_id, target_model_hash, tokenizer_identity, sampler_stage,
  sampling_profile, corpus_version, threshold_version)` key. Single-reference
  operation is allowed only for observe or warn-only keys and MUST NOT activate
  enforce for that key.
- The active `compute_integrity_settlement.sampler_stage` has a SPEC-036-defined
  provider-side capture mechanism and coherent `normalization_basis`. In v0.1,
  enforce activation MUST refuse `pre_temperature_logits` and
  `post_temperature_logits`.
- The active threshold version has an approved calibration record that meets
  the FR-8 minimum sample, coverage, tail-mass, and false-positive target
  requirements.
- Settlement storage can persist request-start compute-integrity state.
- Billing and payout storage already exclude non-`verified` SPEC-022 outcomes.
- Disclosure surfaces use approved copy that says SPEC-036 is an overt
  distribution-drift detector, not cryptographic proof of honest computation,
  hardware integrity, or binary integrity.
- Signed third-party audit bundles from FR-13 are available for every
  settlement-impacting quarantine.
- Operator deactivation, circuit-breaker, and manual-review controls from
  FR-16 are implemented.
- Stable-identity Sybil resistance holds. Because quarantine/block inheritance
  (FR-12) binds to `stable_provider_identity`, enforce MUST refuse activation for any
  provider track unless a **named stable-device/operator-identity authority**
  guarantees that creating a new `stable_provider_identity` carries a cost the
  coordinator can rate-limit and correlate (so a quarantined operator cannot cheaply
  mint a fresh clean identity). SPEC-026's App Attest surface is optional and
  client-dormant on the shipped CLI/`mp-*` track and permits many attestation keys
  per device, so it does NOT by itself supply this invariant; enforce is therefore
  categorically **unavailable** for a track lacking a pre-vetted provider-account
  regime or an equivalent identity authority, regardless of supply or calibration
  (§6.1). Naming that authority and its cost model is `maintainer-approval-required
  at LOCK`; until it exists, the affected track remains observe/warn-only.

### FR-2 Receipt compatibility

SPEC-036 MUST NOT add fields to SPEC-015 v0.4 receipts.

SPEC-036 MUST NOT add fields to SPEC-015 v0.4 `usage`.

SPEC-036 MUST NOT require a future `receipt_version` to enter warn-only mode.

Future receipt versions MAY bind a digest of the request-start
compute-integrity state, but that is outside SPEC-036 v0.1.

### FR-3 Settlement outcome mapping

SPEC-036 MUST NOT introduce a fifth top-level SPEC-022 settlement outcome in
v0.1.

When mode is `enforce` and the covered request's request-start
compute-integrity state is `quarantined_compute_drift`, settlement MUST return:

- SPEC-022 `receipt_verification_outcome = "quarantined"`.
- `reason = "compute_drift_quarantined"`.

`zero_settled` MUST NOT be used for compute-integrity drift because drift is a
trust failure, not a verified non-creditable terminal outcome.

SPEC-036 is an additional enforce-mode AND-gate on top of SPEC-022 receipt
verification; it never relaxes a SPEC-022 non-creditable outcome and only ever
narrows creditability further. For covered enforce rows, compute-integrity
quarantine overrides SPEC-022 R-8.1/R-8.4 final debit and provider-credit
eligibility even when the SPEC-015 receipt is cryptographically valid.
Implementations MUST record the orthogonal SPEC-015 cryptographic/schema verifier
result in an internal audit field such as `receipt_crypto_result`, and SPEC-022
money rules MUST read the settlement field that SPEC-036 sets to `quarantined`; the
SPEC-015 verifier result MUST remain independent and MUST NOT be overwritten by the
compute-integrity gate.

The request-start capture (FR-4) MUST record an atomic composite-policy snapshot
binding the SPEC-022 `verified_model_settlement` policy version and mode together
with the SPEC-036 `compute_integrity_settlement` policy version and mode in effect
at request start. Settlement MUST read that captured composite snapshot; a later
change to either policy MUST NOT retroactively change an already-admitted attempt.
If the captured snapshot shows SPEC-022 was not in enforce for the request's
coverage, SPEC-036 MUST NOT alter the request's money outcome.

**Effective enforce is a runtime conjunction, not just an activation check.**
SPEC-036's effective enforce for any new admission is the conjunction of SPEC-036's
configured mode and SPEC-022's *current* enforce coverage for that request. If
SPEC-022 is rolled back out of enforce (or its coverage narrows below SPEC-036's)
while SPEC-036 remains configured `enforce`, SPEC-036 MUST behave as warn-only /
no-effect for new admissions in the now-uncovered scope: it MUST NOT deny covered
paid routing or block onboarding on compute-integrity grounds where SPEC-022 is no
longer enforcing, so SPEC-036 never exercises routing/onboarding authority beyond
SPEC-022's effective money authority. Rows already captured under a composite
snapshot where both policies were enforce keep their captured outcome (immutability).

In enforce mode, a covered paid request MUST NOT create buyer final debit,
provider credit, earnings visibility, settlement-sweep inclusion, or payout
readiness unless the captured request-start compute-integrity state is fresh
`verified` or fresh `warn` for a covered sampling-profile window. Captured
`unknown`, `pending`, `quarantined_compute_drift`, `blocked:<reason>`,
`expired`, stale, unreadable, or uncovered-profile state MUST fail closed. The
coordinator MAY hold such a row pending until a bounded settlement deadline — the
SPEC-022 route-snapshot settlement deadline for the row (SPEC-036 MUST NOT extend
it); at deadline it MUST settle as `quarantined` with a specific reason. A captured
`pending` row is immutable and MUST remain non-payable: it settles
`compute_integrity_pending_deadline` at the deadline and MUST NOT be promoted to
payable by a canary that finalizes after request start (that would violate
request-start immutability). Covered paid routing already requires a fresh
`verified`/`warn` state at request start (§3), so a `pending` key should not be
forwarded as covered paid work in the first place; if it was (e.g. state changed
between admission and capture), the immutable `pending` capture fails closed.

Compute-integrity settlement reasons are closed over this v0.1 enum:

- `compute_drift_quarantined`.
- `compute_integrity_unknown`.
- `compute_integrity_pending_deadline`.
- `compute_integrity_expired`.
- `compute_integrity_reference_stale`.
- `compute_integrity_threshold_stale`.
- `compute_integrity_unreadable`.
- `compute_integrity_uncovered_profile`.
- `compute_integrity_reference_missing`.
- `compute_integrity_calibration_missing`.
- `compute_integrity_circuit_breaker_hold`.
- `compute_integrity_blocked_abusive_inconclusive`.
- `compute_integrity_blocked_reference_fault`.
- `compute_integrity_blocked_manual_review_required`.
- `compute_integrity_blocked_swap_laundering_suspected`.

Implementations MUST NOT emit ad hoc compute-integrity settlement reason strings
for covered paid settlement.

Captured compute-integrity states MUST map to settlement reasons by this
deterministic table before applying the expired and blocked sub-tables below:

- `quarantined_compute_drift` -> `compute_drift_quarantined`.
- `unknown` -> `compute_integrity_unknown`.
- `pending` at bounded settlement deadline ->
  `compute_integrity_pending_deadline`.
- unreadable captured state -> `compute_integrity_unreadable`.
- uncovered sampling profile -> `compute_integrity_uncovered_profile`.

For captured `expired` state, `expiry_cause` MUST map to settlement reasons by
this deterministic table:

- `reference_stale` -> `compute_integrity_reference_stale`.
- `threshold_stale` -> `compute_integrity_threshold_stale`.
- `window_ttl_expired` -> `compute_integrity_expired`.
- `target_generation_changed` -> `compute_integrity_expired`. A target model hash
  change increments `target_generation` (SPEC-030 generation semantics), so a
  hash change expires via `target_generation_changed`; `catalog_changed` covers
  signed-catalog rotations that do not themselves change the loaded hash.
- `tokenizer_changed` -> `compute_integrity_expired`.
- `sampler_stage_changed` -> `compute_integrity_expired`.
- `corpus_changed` -> `compute_integrity_expired`.
- `catalog_changed` -> `compute_integrity_expired`.
- `sampling_profile_uncovered` -> `compute_integrity_uncovered_profile`.
- `hardware_class_changed` -> `compute_integrity_expired`.
- `state_unreadable` -> `compute_integrity_unreadable`.

The `expiry_cause` enum above is closed. Under-sampled windows are NOT an `expired`
cause: an under-sampled key MUST remain `pending` (never `expired`) so its captured
state settles as `compute_integrity_pending_deadline` at the bounded deadline, not
as a spurious expiry. Unknown `expiry_cause` values MUST be rejected before
settlement or fail closed as `compute_integrity_unreadable`.

The circuit-breaker hold is NOT a member of the compute-integrity state enum; it is
a separately captured flag that acts as an additional non-payable AND-gate over an
otherwise-payable underlying state. If a circuit-breaker hold is active for the
covered key, model, or whole policy **at request-start capture**, the coordinator
MUST record the captured `circuit_breaker_active = true` and `circuit_breaker_scope`
(FR-4) alongside the underlying captured compute-integrity state (which is preserved
unchanged, e.g. `verified` or `warn`). At settlement, a captured
`circuit_breaker_active = true` MUST make the row non-payable and settlement MUST
derive reason `compute_integrity_circuit_breaker_hold`, regardless of the underlying
state. To preserve SPEC-022 request-start immutability, settlement reads only the
captured request-start composite snapshot (FR-4): a circuit-breaker that activates
*after* request-start MUST NOT retroactively reclassify an already-admitted row — it
stops new admissions for the affected scope instead (FR-16). Emergency clawback of
already-delivered work whose reference set is later found suspect is out of scope for
SPEC-036 v0.1 and requires manual review plus a future SPEC-022/SPEC-015 amendment;
SPEC-036 v0.1 MUST NOT encode a post-start hold as a terminal `quarantined` outcome.

`blocked:<reason>` states MUST map to the closed settlement reason enum as
follows:

- `blocked:reference_missing` -> `compute_integrity_reference_missing`.
- `blocked:calibration_missing` -> `compute_integrity_calibration_missing`.
- `blocked:abusive_inconclusive` ->
  `compute_integrity_blocked_abusive_inconclusive`.
- `blocked:reference_fault` -> `compute_integrity_blocked_reference_fault`.
- `blocked:manual_review_required` ->
  `compute_integrity_blocked_manual_review_required`.
- `blocked:swap_laundering_suspected` ->
  `compute_integrity_blocked_swap_laundering_suspected`.

Reference-set admissibility status (FR-4) MUST map deterministically to the closed
reason enum for any covered enforce row that is not `admissible`:

- `missing_quorum` -> `compute_integrity_reference_missing`.
- `reference_fault` -> `compute_integrity_blocked_reference_fault`.
- `stale_reference` -> `compute_integrity_reference_stale`.
- `independence_failed` -> `compute_integrity_blocked_reference_fault`.
- `provenance_missing` -> `compute_integrity_blocked_reference_fault`.
- `schema_invalid` -> `compute_integrity_unreadable`.
- any unknown admissibility status -> `compute_integrity_unreadable` (fail closed).

Any request-start capture whose key fields (compute-integrity key, sampling-profile
coverage, reference-set admissibility, composite-policy snapshot) fail to verify
against the route snapshot and request sampler at settlement MUST fail closed as
`compute_integrity_unreadable`. Settlement MUST NOT emit any reason string outside
the FR-3 closed enum for covered paid settlement.

**Fail-closed is unconditional at the row level.** Every non-payable request-start
condition — provider-attributable (`quarantined_compute_drift`, provider-caused
blocks, abusive-inconclusive) and coordinator-attributable (reference
missing/stale/fault, calibration/threshold stale, circuit-breaker hold, unscheduled
`window_ttl_expired`/`unknown`/`pending`) alike — MUST fail closed at settlement. A
captured covered enforce row is settled payable ONLY from a fresh `verified`/`warn`
capture; SPEC-036 has no per-row degrade-to-payable path. Availability during a
coordinator-attributable outage is handled by the pre-admission
`reference_unavailable_auto_downgrade` mode flip (FR-1), which affects only new
admissions, and honest-provider compensation for voided delivered work, if any, is
an operator-funded non-buyer path (FR-17) — never a SPEC-022 buyer-debit/provider-
credit settlement. The enforce activation record MUST acknowledge that under
`fail_closed` semantics a coordinator-attributable lapse voids the affected
delivered work unless the operator funds compensation (`maintainer-approval-required
at LOCK`).

**Reason precedence.** When more than one non-payable condition holds for a covered
enforce row, settlement MUST apply exactly one reason by this total order (highest
precedence first); the first matching condition wins and lower ones are recorded in
the audit row (FR-14) but not emitted as the settlement reason:

1. `compute_integrity_unreadable` (any unreadable/schema-invalid/unverifiable
   capture, including missing/malformed breaker or admissibility metadata).
2. `compute_integrity_uncovered_profile`.
3. `compute_integrity_blocked_swap_laundering_suspected`.
4. `compute_integrity_blocked_manual_review_required`.
5. `compute_integrity_blocked_reference_fault` /
   `compute_integrity_reference_missing` / `compute_integrity_reference_stale`
   (reference-set admissibility failures, in that sub-order).
6. `compute_integrity_calibration_missing` / `compute_integrity_threshold_stale`.
7. `compute_drift_quarantined` (active `quarantined_compute_drift`).
8. `compute_integrity_blocked_abusive_inconclusive`.
9. `compute_integrity_circuit_breaker_hold` (breaker flag over an otherwise-payable
   underlying state; because drift/blocks rank higher, a drift-quarantined row keeps
   `compute_drift_quarantined` rather than being masked by the breaker reason).
10. `compute_integrity_expired` / `compute_integrity_reference_stale` (per expiry
    cause), `compute_integrity_unknown`, `compute_integrity_pending_deadline`.

### FR-4 Request-start state capture

For every covered paid request attempt, the coordinator MUST persist the
request-start compute-integrity state alongside the route-time verification
snapshot or in an immutable row linked to that snapshot.

The captured state MUST include:

- `stable_provider_identity`.
- `provider_id`.
- `assigned_id`.
- `model_id`.
- `target_model_hash`.
- `tokenizer_identity`.
- `sampler_stage`.
- `sampling_profile`.
- `sampling_profile_coverage_mode`.
- `compute_integrity_policy_version`.
- `compute_integrity_policy_mode`.
- `compute_integrity_policy_digest`: digest of the full active SPEC-036 policy
  object (so the exact money rule in force at request start is provable).
- Composite SPEC-022 binding: `spec022_policy_version`, `spec022_policy_mode`,
  `spec022_coverage_digest`, `spec022_effective_enforce` (boolean), and the linked
  `spec022_route_snapshot_digest`. Every money-affecting change to either policy MUST
  bump the respective policy version; a missing or unreadable composite-binding field
  MUST fail closed as `compute_integrity_unreadable`.
- `hardware_runtime_class` and its immutable `hardware_runtime_class_digest` (the
  covered class the captured state was measured/calibrated under; a mismatch between
  this and the route snapshot's provider class fails closed as
  `compute_integrity_uncovered_profile`).
- `compute_integrity_state`.
- `expiry_cause` when state is `expired`.
- `compute_integrity_window_id`.
- `reference_set_id`.
- `reference_event_digests` for all active trusted references used by the
  verdict.
- `reference_source_ids`, `reference_failure_domain_ids`, and source-independence
  evidence for every reference counted toward quorum.
- Runtime-build provenance digests AND golden-fixture validation digests (both,
  non-substitutable per FR-5) for every reference counted toward quorum.
- Reference refresh timestamps.
- `reference_set_admissibility_digest`, computed over the
  `reference_set_admissibility_v1` RFC 8785/JCS object. That object MUST contain
  `type = "reference_set_admissibility_v1"`,
  `schema_version = "reference_set_admissibility_v1"`,
  `reference_set_id`, full covered `(model_id, target_model_hash,
  tokenizer_identity, sampler_stage, sampling_profile, corpus_version,
  threshold_version)` key, `reference_set_admissibility_status`,
  `reference_quorum_count`, `reference_fault_check_version`, and a
  `references[]` array sorted by `reference_event_digest`. Each `references[]`
  item MUST bind `reference_event_digest`, `reference_source_id`,
  `reference_failure_domain_id`, source-independence evidence digest,
  runtime-build provenance digest AND golden-fixture validation digest (both,
  non-substitutable), and refresh timestamp.
- `reference_set_admissibility_status`. Allowed values are `admissible`,
  `missing_quorum`, `reference_fault`, `stale_reference`,
  `independence_failed`, `provenance_missing`, and `schema_invalid`. Unknown
  values MUST fail closed. Only `admissible` can support payable `verified` or
  payable `warn`.
- `reference_quorum_count`.
- `reference_fault_check_version`.
- `circuit_breaker_active`: a non-null boolean captured on every covered enforce
  row. `circuit_breaker_scope`: a closed enum `key` | `model` | `policy`, present
  exactly when `circuit_breaker_active = true` and null otherwise. Missing,
  malformed, or inconsistent breaker fields (e.g. `active` absent, or `active=true`
  with null scope) MUST fail closed as `compute_integrity_unreadable`.
- `threshold_version`.
- `corpus_version`.
- `target_generation`.
- `signed_catalog_digest`: the digest of the signed catalog entry that bound the
  covered `(model_id, target_model_hash)` at request start.
- `captured_at`.

Settlement MUST read the captured request-start state (including the captured
composite-policy snapshot and captured circuit-breaker state), not the current
provider or breaker state at settlement time. The circuit-breaker state is
captured at request start alongside `circuit_breaker_scope`/`circuit_breaker_active`
as fields separate from `compute_integrity_state`. A row admitted while the breaker
was inactive (`circuit_breaker_active = false`) settles from its captured underlying
state even if the breaker later activates; a row admitted while the breaker was
active (`circuit_breaker_active = true`) preserves its underlying captured state but
settles non-payable with derived reason `compute_integrity_circuit_breaker_hold`.
This keeps settlement a pure function of immutable request-start state, per SPEC-022.

At request-start capture, the coordinator MUST deterministically re-evaluate
reference freshness, threshold freshness, window TTL, target generation,
tokenizer identity, sampler stage, sampling-profile coverage, and the
`signed_catalog_digest` bound to the covered `(model_id, target_model_hash)`. A
`signed_catalog_digest` that differs from the digest that backed the positive state
(a signed-catalog rotation that does not itself change the loaded hash) MUST expire
the positive state with `expiry_cause = catalog_changed`. If any freshness,
catalog, or coverage check fails, the captured state MUST be `expired` with an
`expiry_cause` or `blocked:<reason>`, not a stale stored `verified`. Settlement
MUST verify the captured key fields, reference-set admissibility status, and
sampling-profile coverage against the route snapshot and request sampler before
treating `verified` or `warn` as payable.

### FR-5 Reference source

The coordinator MUST maintain trusted reference events for every covered
`(model_id, target_model_hash, tokenizer_identity, sampler_stage,
sampling_profile, corpus_version, threshold_version)`.

Trusted reference admission MUST verify:

- The reference runtime is coordinator-controlled.
- The loaded model hash equals the signed catalog hash.
- The tokenizer identity matches the candidate-provider tokenizer identity.
- The reference runtime version and corpus version are recorded.
- Each enforce-mode reference source MUST satisfy the closed independence predicate
  below against every other source counted toward the same covered key's quorum. Two
  sources are independent iff ALL THREE of: (a) independent operator-controlled
  source identity; (b) independent hardware failure domain (distinct physical host
  and power/network fault domain); and (c) independent runtime-build/kernel
  provenance. All three are REQUIRED and none is substitutable — two references that
  share a runtime build/kernel could share a compromised-or-buggy distribution and
  both pass a limited golden fixture, so a shared software failure domain MUST NOT
  count as two independent references. A signed golden-distribution fixture at
  admission and every refresh is an ADDITIONAL mandatory admission check (FR-5
  admissibility), never a substitute for any of (a)–(c). Consequently the funded
  reference fleet MUST provide at least two references that differ in operator
  identity, hardware failure domain, AND runtime-build/kernel provenance per covered
  key (see FR-17); this is one reason v0.1 enforce is not reachable with a single
  cloned reference node (§6.1). Reconciliation with the class model (FR-8): "independent
  runtime-build/kernel provenance" means **independently produced builds within the
  same `hardware_runtime_class` numeric-equivalence band** — the class is a band
  chosen so that independently-produced conforming builds still agree within the
  `tau_reference_fault` floors, so requiring build independence does not
  reference-fault-lock enforce and does not false-fail an honest provider of that
  class. This is the reachable operating point; two builds so divergent that they
  exceed `tau_reference_fault` are, by definition, different classes and MUST NOT be
  quorum peers. The honest limit of this design: two independent builds within one
  band give **outage/operator independence and protection against
  build-specific-but-out-of-band defects**, but a subtle in-band correlated bug
  present in both builds is not caught — which is why the golden-fixture check
  (validation against a signed reference distribution) is retained as an additional
  mandatory admission check, and why §4's threat model disclaims full compute-integrity
  proof.

Hybrid mode SHOULD also collect N-provider consensus telemetry with N >= 3, but
consensus telemetry MUST NOT create automatic quarantine in v0.1 without a fresh
trusted-reference event for the same key.

Reference-set admissibility:

- In enforce mode, every covered key MUST have at least two independent fresh
  trusted reference events for the same model/hash/tokenizer/sampler-stage/
  profile/corpus/threshold key.
- The coordinator MUST compare active trusted references over the same corpus,
  support-selection rule, K, sampling profile, and the identical measurement
  position set (see the reference-event `positions[]` requirement in §3).
- The pairwise reference-vs-reference fault predicate is deterministic and uses
  the same conservative `tv_upper` interval as provider verdicts: for each
  unordered pair of active admissible trusted references, the coordinator computes
  `tv_upper` per shared position over the `compute_integrity_support_selection_v1`
  union of the two references' top-K, applying the same K=64→256 retry and tail
  handling as FR-7. The pair is in `reference_fault` when
  `median(tv_upper) >= tau_reference_fault_median` OR any position
  `tv_upper >= tau_reference_fault_position`. A covered key is in
  `reference_fault` if ANY active reference pair is in `reference_fault`. All
  active reference pairs MUST be below both fault thresholds before any provider
  result can count as `pass`, `warn`, or `quarantine_candidate`. A reference pair
  whose comparison cannot resolve below the fault thresholds because the required
  K=256 retry fails or a side's tail mass stays above the K=256 tail ceiling MUST
  be treated as `reference_fault` (fail closed), setting
  `reference_set_admissibility_status = reference_fault`, which maps to
  `compute_integrity_blocked_reference_fault` (FR-3).
- If quorum is missing or trusted references disagree, the key MUST move to
  `blocked:reference_missing` for missing quorum or `blocked:reference_fault`
  for trusted-reference disagreement; provider drift counters MUST NOT
  increment; and manual review plus fresh reference admission MUST be required
  before enforce resumes for that key.
- For provider verdicts, quarantine candidates MUST be based on an agreed
  reference envelope: the provider must exceed the quarantine threshold against
  all active admissible trusted references, while pass requires satisfying pass
  thresholds against every active admissible trusted reference.
- Auditor bundles MUST include all trusted reference digests used for the
  verdict and the reference-vs-reference disagreement metrics.

Every reference event and probe event used for TV computation, verdict
assignment, state transition, calibration, or settlement-impacting audit MUST
retain either inline compact per-position evidence or a digest plus retained
object reference sufficient to recompute the TV interval until the audit
retention deadline. The retained evidence MUST cover reference probabilities for
the returned provider/reference union support, reference tail mass, provider
compact evidence, K, sampler stage, `prompt_id`, `position_index`,
`token_prefix_digest`, `context_hash`, and the full covered key.

Hybrid mode MUST NOT be advertised as a reference-drift safety property unless
N-provider participation is funded and active. In v0.1, consensus telemetry MUST
be either disabled unless a configured network/operator budget exists, or paid
from capped non-buyer credits with per-provider daily caps and anti-Sybil
eligibility. Buyer usage, SPEC-015 usage, and uncapped MALIBU rewards MUST NOT
fund consensus telemetry.

Reference events MUST refresh at least every 24 hours and immediately after
catalog rotation, reference runtime/build update, runtime-build provenance digest
change, signed golden-fixture validation digest change, tokenizer identity
change, sampler stage change, corpus version change, or threshold version change.

### FR-6 Probe schema and SPEC-030 (Losslessness Probe) inheritance

Compute-integrity probes compose on SPEC-030 (Losslessness Probe) at the
**algorithm and policy layer** but **own their settlement-bearing wire framing**.
This boundary is deliberate: reusing SPEC-030's *math* is safe, but reusing its
*wire payload* would blur the settlement/telemetry trust boundary. The two layers
are:

**Inherited by normative reference (identical algorithm/policy — SPEC-036 does not
re-derive these):**

- The transport/auth/load-bound *policy values* of SPEC-030 §FR-3: an
  authenticated provider-control channel, a single-use unpredictable nonce of at
  least 128 bits, expiry no more than 120 seconds after issuance, `K` limited to
  64 or 256, at most 4 prompts and 8 stochastic measurement positions per result,
  and non-billable provider probe work (see also FR-17).
- The `support_selection_v1` shared-support **construction rule** (SPEC-030 §FR-7)
  as the base of a SPEC-036-owned multi-arm **generalization**: SPEC-030's two-arm
  (provider + one reference, ≤ `2K`) union is generalized here to an
  `(N+1)`-arm union over the provider top-K and the top-K of all `N` active
  references (≤ `(N+1)K`), with full-distribution probabilities reported over the
  union and tail mass outside it, including SPEC-030's small-vocabulary exception.
  This is a documented generalization, not an identical two-arm reuse.
- The TV lower/upper interval **formula** and canonical median rule (SPEC-030 §FR-9).

SPEC-036 carries the support-selection rule under the settlement-scoped constant
`compute_integrity_support_selection_v1` (its reference arms are the coordinator-held
trusted references, not SPEC-030's provider plain path); the construction is the same
rule generalized from two arms to `(N+1)` arms for `N` active references
(§FR-6/§FR-7), not the literal two-arm SPEC-030 wire construction.

**Owned by SPEC-036 (settlement-bearing wire framing — NOT inherited from
SPEC-030, which frames these for its own `losslessness_probe_v1` profile):**

- The probe **profile discriminator** `compute_integrity_probe_v1`, distinct from
  `losslessness_probe_v1`. SPEC-036 MUST NOT reuse SPEC-030's `losslessness_probe_v1`
  request/result payload fields, `type`, or `schema_version`.
- The **digest preimage.** Unlike SPEC-030 §FR-4 (which digests the inner payload
  only), SPEC-036 domain-separates by digesting the full canonical object
  `{type, schema_version, payload}` (see the envelope definitions below). This is a
  deliberate override, not an inheritance; the two profiles therefore produce
  different digests by construction, which is intended.
- The **Tier-2 encrypted carrier** (see "Encrypted carrier" below), which SPEC-030
  §FR-4 defines only for `losslessness_probe_v1.*` frame types.
- The **result variants** (`measurement` and `provider_inconclusive`; see the
  result payload below).
- The **concurrency bound.** Per-provider concurrent `compute_integrity_probe_v1`
  probes are limited to 1, tracked separately from SPEC-030's
  `losslessness_probe_v1` concurrency; the aggregate per-provider probe concurrency
  across both profiles MUST NOT exceed 2, and both MUST yield to buyer inference load
  bounds. Because both profiles share the one authenticated WS control channel and
  the aggregate cap, the policy MUST define an explicit scheduler priority between
  them; the default is that settlement-bearing `compute_integrity_probe_v1` probes
  take priority over non-settlement `losslessness_probe_v1` probes when both are due,
  so compute-integrity freshness/time-to-quarantine SLOs (FR-17) are not starved by
  losslessness scheduling. The FR-17 throughput model MUST account for this shared
  contention.

SPEC-036 introduces exactly one genuinely new measurement arm on top of the
inherited math: the comparison is **provider-vs-coordinator-held-trusted-reference**
(cross-node), not SPEC-030's provider **plain-vs-spec** self-consistency. Everything
downstream of the raw compact distributions (reference admission/quorum, the
settlement-gating consumer, and the `quarantined_compute_drift` state) is specified
in FR-2/FR-3/FR-5/FR-10 of this spec and is not inherited. SPEC-036 MUST still treat
SPEC-030's losslessness results as non-settlement telemetry unless a later SPEC-030
addendum explicitly changes that boundary.

**Encrypted carrier.** For cleartext provider-control sessions, the WS frame is the
outer envelope defined below. For encrypted Tier-2 provider-control sessions,
SPEC-036 MUST use a dedicated provider-control carrier — never the buyer
`inference_request` carrier and never SPEC-030's `losslessness_probe_v1.*` carrier —
formed by substituting the compute-integrity profile discriminator into SPEC-030
§FR-4's carrier structure:

- Request visible frame: `type = "compute_integrity_probe_v1.encrypted_request"`,
  `request_id = probe_id`, `stream = false`, `encrypted = true`, and `enc`.
- Request AAD: visible frame type, direction `c2p`, `request_id`, `stream = false`,
  `provider_id`, `assigned_id`, and sequence number.
- Request plaintext envelope: `type = "compute_integrity_probe_v1.request_plaintext"`
  with `payload` equal to the cleartext request outer envelope.
- Result visible frame: `type = "compute_integrity_probe_v1.encrypted_result"`,
  `request_id = probe_id`, `stream = false`, `encrypted = true`, and `enc`.
- Result AAD: visible frame type, direction `p2c`, `request_id`, `stream = false`,
  `provider_id`, `assigned_id`, and sequence number.
- Result plaintext envelope: `type = "compute_integrity_probe_v1.result_plaintext"`
  with `payload` equal to the cleartext result outer envelope.

The digest inputs remain the cleartext outer envelopes defined below; Tier-2
encryption authenticates the carrier and plaintext envelope only and does not change
the digest preimage.

**Result kind.** Every `compute_integrity_probe_v1.result` MUST carry
`result_kind = "measurement"` or `result_kind = "provider_inconclusive"`. A
`provider_inconclusive` result MUST carry a `provider_reason_code` drawn from the
closed set `inconclusive:model_swap`, `inconclusive:unsupported_sampler`,
`inconclusive:reference_unavailable`, `inconclusive:position_mismatch`,
`inconclusive:missing_distribution`, or `inconclusive:timeout`, MUST carry the
actual identities known at failure time or null with an `identity_unavailable_reason`,
and MUST NOT carry authoritative distributions; the coordinator MUST NOT compute TV,
`pass`, `warn`, or `quarantine_candidate` from a `provider_inconclusive` result.

`compute_integrity_probe_v1.request` MUST use an outer envelope containing:

- `type = "compute_integrity_probe_v1.request"`.
- `schema_version = "compute_integrity_probe_v1.request"`.
- `payload`: the canonical request payload.
- `probe_request_digest`: SHA-256 over the RFC 8785/JCS canonical form of the
  object `{type, schema_version, payload}` excluding only
  `probe_request_digest`.

The request `payload` MUST include:

- `schema_version = "compute_integrity_probe_v1.request"`, matching the outer
  envelope.
- `probe_id`.
- `nonce`.
- `expires_at`.
- `model_id`.
- `target_model_hash`.
- `tokenizer_identity`.
- `sampler_stage`.
- `target_generation`.
- `sampling_profile`.
- `corpus_version`.
- `threshold_version`.
- `support_selection = "compute_integrity_support_selection_v1"`.
- `normalization_basis = "full_distribution"` for v0.1
  `post_sampler_probabilities`; future sampler stages MUST define their own
  coherent basis before enforce use.
- `k`: integer, exactly 64 or 256.
- `positions`: a closed array (length 1..8) where each element is an object with
  exactly `prompt_id` (string), `prompt_ref` (string; an allowlisted synthetic
  corpus reference or redacted prompt handle — never buyer-origin content),
  `position_index` (non-negative integer), `token_prefix_digest`
  (`sha256:<hex>` over the exact teacher-forced token prefix), `context_hash`
  (`sha256:<hex>`), and `reference_top_k_sets` (a closed array with one entry per active admissible
  trusted reference for the covered key, each `{reference_event_digest,
  reference_top_k_token_ids}` where `reference_top_k_token_ids` is an array of
  `min(k, vocab_size)` non-negative integer token ids, no duplicates, ordered by
  non-increasing reference probability with ascending token id as tie-break — length
  exactly `k` unless the vocabulary is smaller, matching SPEC-030 §FR-7's
  small-vocabulary exception). Carrying every active reference's top-K in one probe
  lets the provider report probabilities over the combined support so the
  coordinator can compute provider-vs-reference TV against every active reference
  from a single result (FR-7). `reference_top_k_token_ids`
  is mandatory for every probe used for TV computation, verdict assignment, state
  transition, or calibration; it MAY be omitted only for schema dry-runs that
  cannot affect calibration or state.

The request payload key set is closed: any additional key MUST cause the provider
to reject the probe and MUST cause the coordinator to reject a result that echoes
an out-of-schema request.

`compute_integrity_probe_v1.result` MUST use an outer envelope containing:

- `type = "compute_integrity_probe_v1.result"`.
- `schema_version = "compute_integrity_probe_v1.result"`.
- `payload`: the canonical result payload.
- `probe_request_digest`: an echo of the issued `probe_request_digest`.
- `probe_result_digest`: SHA-256 over the RFC 8785/JCS canonical form of the
  object `{type, schema_version, payload}` excluding only `probe_result_digest`.

The result `payload` MUST include:

- `schema_version = "compute_integrity_probe_v1.result"`, matching the outer
  envelope.
- `probe_id`.
- `nonce`.
- `probe_request_digest`.
- `result_kind`: `"measurement"` or `"provider_inconclusive"` (see FR-6 "Result
  kind"). The payload is a discriminated union on `result_kind`; each variant's key
  set is closed exactly as specified below.
- Identity echoes: `model_id`, `target_model_hash`, `tokenizer_identity`,
  `target_generation`, `sampling_profile`, `corpus_version`, `threshold_version`.
  In the `provider_inconclusive` variant each identity echo MAY be null, in which
  case the payload MUST carry a non-empty `identity_unavailable_reason` string.
- `support_selection`, `normalization_basis`, and `sampler_stage` echoes.
- For `result_kind = "provider_inconclusive"`, the payload MUST additionally carry
  exactly `provider_reason_code` (from the FR-6 closed inconclusive set) and, when
  any identity echo is null, `identity_unavailable_reason`; it MUST NOT carry
  `positions` or `validation_metadata`.
- For `result_kind = "measurement"`, a `positions` array (same length and order as
  the request) where each element is an object with exactly: `prompt_id`,
  `position_index`, `token_prefix_digest`, `context_hash` (echoes),
  `provider_top_k_token_ids` (array of `min(k, vocab_size)` integer ids, no
  duplicates, ordered by non-increasing probability with ascending token id
  tie-break; length is exactly `k` unless the vocabulary is smaller, matching the
  small-vocabulary exception),
  `support_token_ids` (numeric-ascending union of the provider top-K and the top-K
  of ALL references in `reference_top_k_sets`; length is between `k` and
  `(N+1)*k` for N active references, unless the vocabulary is smaller),
  `provider_support_probabilities` (one finite probability in `[0,1]` per
  `support_token_ids` entry), and `provider_tail_mass` (finite, in `[0,1]`, the
  mass outside `support_token_ids`).
- `validation_metadata` (measurement variant only): an object with exactly
  `provider_measured_at` (RFC3339 UTC), `provider_execution_ms` (non-negative
  integer), `provider_final_k` (64 or 256), and `provider_scalar_verdict` (a
  nullable number; advisory only and non-authoritative — the coordinator MUST
  derive the verdict itself per FR-7). No other keys are permitted.

Each result-kind variant's payload key set is closed. The coordinator recomputes
reference probabilities and reference tail mass over `support_token_ids` itself
(FR-7) from the reference event's `reference_full_distribution_ref` and MUST NOT
accept reference-side probabilities from the provider.

The coordinator MUST reject results whose echoed identity fields, nonce,
`type`, `schema_version`, `probe_request_digest`, `probe_result_digest`, expiry,
position identifiers, teacher-forced prefix digests, context hashes, or
union-support fields do not match the issued request and corpus position. The
coordinator MUST reject replay of a duplicate `probe_request_digest` outside the
issued probe attempt and MUST log digest mismatches as validation failures.

The coordinator MUST validate compact distributions before computing TV:

- All probabilities and tail masses are finite and in `[0, 1]`.
- Token ids are valid for `tokenizer_identity`.
- Provider top-K token ids are length K (unless vocabulary size is smaller than
  K, mirroring SPEC-030 §FR-7/§FR-8), ordered by non-increasing probability with
  ascending token id as tie-break, and contain no duplicates.
- The shared support is exactly the union of the provider top-K and the top-K of
  every reference in `reference_top_k_sets`, with one probability per support token.
- Shared-support length is between K and `(N+1)*K` for N active references, unless
  vocabulary size is smaller (small-vocabulary exception as SPEC-030 §FR-7).
- `abs(sum(provider_support_probabilities) + provider_tail_mass - 1.0) <= 1e-5`
  (the same fixed tolerance as SPEC-030 §FR-8; maintainers MAY approve a wider
  tolerance only under a new `threshold_version`).
- Reference probabilities and tail mass are recomputed by the coordinator over
  the same support, not accepted from the provider.
- `support_selection`, `normalization_basis`, and `sampler_stage` match the
  issued request.
- `prompt_id`, `position_index`, `token_prefix_digest`, and `context_hash` match
  the issued corpus position before TV computation.

Prefix or position mismatches MUST finalize as
`inconclusive:position_mismatch`, MUST NOT increment drift counters, and MUST
count toward the abusive inconclusive rule unless the coordinator attributes the
mismatch to its own corpus issuance fault.

Malformed distributions MUST finalize as `inconclusive:malformed_distribution`
and MUST count toward the abusive inconclusive rule unless the coordinator
attributes the malformed result to its own reference or transport fault.

### FR-7 TV computation

For each measurement position and **each active admissible reference** `r`, the
coordinator MUST compute a provider-vs-reference `r` TV interval over the combined
`compute_integrity_support_selection_v1` shared support (`support_token_ids` = the
union of provider top-K and every reference's top-K). The coordinator sends every
reference's top-K in `reference_top_k_sets`, the provider returns its own top-K plus
probabilities over the combined support, and the coordinator recomputes reference
`r`'s probabilities and tail mass over that same support (from `r`'s
`reference_full_distribution_ref`, §3) before computing, per reference `r`:

```text
support_diff_r = sum(abs(p_provider(token) - p_reference_r(token)))
tv_lower_r = 0.5 * (support_diff_r + abs(provider_tail_mass - reference_tail_mass_r))
tv_upper_r = 0.5 * (support_diff_r + provider_tail_mass + reference_tail_mass_r)
```

A single provider result therefore yields one TV interval per active reference over
one shared support. The FR-5 agreed-envelope rule aggregates across references:
`pass` requires the pass predicate to hold against every active admissible
reference; `quarantine_candidate` requires the quarantine predicate to hold against
every active admissible reference. Each reference's tail mass is computed against
the larger combined `(N+1)`-arm support, so a reference's tail can only be **lower**
than it would be against a two-arm support (more tokens in the union means less mass
outside it); the K-retry/tail predicates below apply to each `tv_*_r` in turn against
the combined support.

The provider MUST NOT supply the authoritative verdict. The coordinator verdict
MUST be derived from raw compact distributions, tail masses, identity fields,
and the active threshold record.

At K=64, the coordinator MUST retry at K=256 before assigning `pass`, `warn`,
or `quarantine_candidate` if any of these predicates is true:

- Either side's tail mass exceeds `0.01`.
- `median(tv_upper) >= tau_warn_median` (at or above the warning threshold, same
  boundary convention as SPEC-030 §FR-10).
- Any position `tv_upper >= tau_warn_position`.
- `median(tv_lower) >= tau_quarantine_median - 0.005`.
- Any position `tv_lower >= tau_quarantine_position - 0.005`.

At K=256, if either tail mass exceeds `0.005`, the result MUST be
`inconclusive:tail_mass_high` and MUST NOT increment drift counters.

If a mandatory K=256 retry fails, times out, or cannot complete before expiry,
the result MUST be `inconclusive:k_retry_failed`, MUST NOT increment drift
counters, and MUST count toward the abusive inconclusive rule unless the
coordinator attributes the failure to its own reference, scheduling, or
transport fault.

### FR-8 Threshold calibration

Thresholds MUST be keyed by `(model_id, target_model_hash, tokenizer_identity,
sampler_stage, sampling_profile, corpus_version, threshold_version,
hardware_runtime_class)`. `hardware_runtime_class` is required because MLX/Metal
next-token numerics are not bit-identical across Apple-Silicon generations or MLX
builds, especially in the tail and at higher temperature — exactly where TV is
measured — so a reference of one class judging a provider of another class would
produce systematic false positives. **v0.1 restriction:** enforce covers only
providers whose `hardware_runtime_class` matches (or is bounded by) the trusted
reference set's class; providers outside the covered class(es) remain
observe/warn-only, and FR-15 disclosure MUST state which hardware/runtime classes an
enforce policy covers. A later version MAY calibrate per class with a
class-representative reference set. Because the policy pins exactly one
`hardware_runtime_class` per covered key, the class is a **policy invariant that is
constant within every measurement, reference, window, overlay, and request-start
identity for that key** (it therefore need not be an additional discriminator in
those tuples); it is bound instead via the FR-4 `hardware_runtime_class_digest`
capture and the FR-12 `hardware_class_changed` expiry, which together prove a
captured verdict, its reference set, and the paid request all belong to the covered
class and force expiry when a provider's class changes.

The threshold record MUST include:

- `threshold_version`.
- `baseline_median_tv_upper_p99`.
- `baseline_position_tv_upper_p99`.
- `tau_warn_median`.
- `tau_warn_position`.
- `tau_quarantine_median`.
- `tau_quarantine_position`.
- `tau_reference_fault_median`.
- `tau_reference_fault_position`.
- Calibration source and sample count.
- Minimum eligible canary count.
- Measurement-position count.
- Provider/model/hash/tokenizer/sampler-stage/profile coverage.
- Calibration time window.
- Baseline tail-mass feasibility rate.
- Baseline median and max `tv_upper`.
- Approved false-positive target.
- Approval timestamp and approver group.

Initial threshold formulas:

```text
tau_warn_median = max(0.015, baseline_median_tv_upper_p99 + 0.005)
tau_warn_position = max(0.030, baseline_position_tv_upper_p99 + 0.010)
tau_quarantine_median = max(0.060, baseline_median_tv_upper_p99 + 0.050)
tau_quarantine_position = max(0.120, baseline_position_tv_upper_p99 + 0.080)
tau_reference_fault_median = max(0.010, baseline_median_tv_upper_p99 + 0.003)
tau_reference_fault_position = max(0.020, baseline_position_tv_upper_p99 + 0.006)
```

Maintainers MAY approve wider thresholds for specific model/profile keys, but
the approval MUST be recorded with rationale and a new `threshold_version`.
The false-positive target MUST be a numeric budget, and enforce activation MUST
refuse a key whose calibration record does not include a **measured** realized
false-quarantine rate (from the warn-only period, over the covered
`hardware_runtime_class`) at or below that numeric budget — an aspirational target
without measured validation is insufficient. Enforce activation MUST refuse
thresholds whose calibration record does not meet the approved minimum eligible
canary count, position count, coverage, tail-mass, and measured false-positive
budget for the covered key. A covered enforce key
with missing approved calibration MUST move to `blocked:calibration_missing` and
settle non-payable covered traffic with `compute_integrity_calibration_missing`
until calibration is complete or the key is removed from enforce coverage.

### FR-9 Single-canary verdicts

The coordinator MUST assign exactly one final verdict per valid canary:

- `pass`: median `tv_upper <= tau_warn_median`, every position
  `tv_upper <= tau_warn_position`, identities stable, reference fresh, and no
  pending K retry.
- `warn`: warning threshold exceeded but quarantine-candidate threshold not met.
- `quarantine_candidate`: median `tv_lower > tau_quarantine_median` or any
  position `tv_lower > tau_quarantine_position`, after required K retry.
- `inconclusive`: validation, identity, transport, tail, reference, timeout, or
  sampler failure.

The coordinator-assigned `inconclusive` sub-reason is drawn from this closed
coordinator final-inconclusive enum (distinct from the provider-supplied
`provider_reason_code` of FR-6), each with the stated counter effect; none increments
the drift counter, and each is attributable-to-coordinator-fault-exempt from the
abusive rule when the coordinator caused it:

- `inconclusive:identity_reject` (echoed identity/nonce/`probe_request_digest`/
  `probe_result_digest`/`type`/`schema_version`/expiry mismatch, or duplicate-digest
  replay) — abusive event.
- `inconclusive:position_mismatch` (prefix/position/context mismatch) — abusive event
  unless coordinator corpus-issuance fault.
- `inconclusive:malformed_distribution` (any FR-6 distribution-validation failure) —
  abusive event unless coordinator reference/transport fault.
- `inconclusive:tail_mass_high` (FR-7 K=256 tail ceiling exceeded) — no abusive
  increment unless repeated > 3 in 24h.
- `inconclusive:k_retry_failed` (FR-7 mandatory K=256 retry could not complete) —
  abusive event unless coordinator reference/scheduling/transport fault.
- `inconclusive:coordinator_timeout` (initial K=64 probe timed out, produced no
  result, or failed transport before any provider result) — abusive event unless
  coordinator scheduling/transport fault; no `probe_result_digest`.
- `inconclusive:provider_inconclusive` (a well-formed `provider_inconclusive`
  result) — counter effect per the mapped `provider_reason_code`, by this closed
  mapping: `inconclusive:model_swap` → no abusive increment (treated as `expired`
  identity change); `inconclusive:unsupported_sampler` → abusive event;
  `inconclusive:reference_unavailable` → abusive event UNLESS the coordinator
  independently confirms an actual reference outage for that key at that time (a
  provider-supplied `reference_unavailable` is not self-authenticating and MUST NOT
  by itself suppress the abusive-inconclusive counter, else a provider could spam it
  to keep a stale `verified` window payable within its TTL);
  `inconclusive:position_mismatch`, `inconclusive:missing_distribution`,
  `inconclusive:timeout` → abusive event.

`warn` MUST NOT block covered paid routing by itself.

### FR-10 Window state machine

State ownership is canonical: the coordinator MUST maintain positive
measurement/verdict state (`unknown`, `pending`, `verified`, `warn`, `expired`)
and the rolling verdict window per **window key**, and MUST maintain active
`quarantined_compute_drift`/`blocked:<reason>` state and the three rolling
accumulators (quarantine-candidate window count, 24-hour abusive-inconclusive
count, 24-hour onboarding-failure count) per **overlay key** (§3). Every rule below
that refers to "the key" or "the same key" applies to the window key for positive
state and to the overlay key for quarantine/block state and accumulators; the two
differ only by `target_generation`, which the overlay key omits. A canary result
labeled by a compute-integrity key contributes to the window key and overlay key
obtained by projecting away `provider_id`/`assigned_id` (and, for the overlay,
`target_generation`).

Allowed states:

- `unknown`: no valid result.
- `pending`: probe issued and result not finalized.
- `verified`: latest window satisfies pass rules, freshness TTL, reference-set
  admissibility, payable-window prerequisites, and the verified pass rule.
- `warn`: latest window satisfies payable-window prerequisites and the latest
  valid result is warning-class below the quarantine-candidate threshold.
- `quarantined_compute_drift`: active window met quarantine rule and the key is
  removed from covered paid routing.
- `blocked:reference_missing`: missing trusted-reference quorum blocks covered
  paid routing until reference admission is restored.
- `blocked:calibration_missing`: missing approved calibration blocks covered
  paid routing until calibration is complete or the key is removed from enforce
  coverage.
- `blocked:abusive_inconclusive`: repeated abusive inconclusive results block
  covered paid routing until manual review or fresh pass sequence.
- `blocked:reference_fault`: trusted-reference disagreement blocks covered paid
  routing until fresh reference admission and manual review.
- `blocked:manual_review_required`: flapping or operator-flagged state blocks
  covered paid routing until dual-approved manual review and any required fresh
  pass sequence.
- `blocked:swap_laundering_suspected`: suspected generation or identity
  laundering blocks covered paid routing until dual-approved manual review and
  any required fresh pass sequence.
- `expired`: prior state exceeded freshness TTL or was invalidated by target
  generation, corpus, threshold, tokenizer, sampler stage, or catalog change.

Positive-state recomputation (mandatory, not sticky): the effective state is a
deterministic function of the current window and overlay, recomputed on **every
finalized eligible canary** and at every request-start capture, by this ordered
resolution (first match wins):

1. If the swap-laundering overlay or per-key overlay carries
   `blocked:<reason>` or `quarantined_compute_drift` → that block/quarantine state.
2. Else if a freshness/invalidation check fails (TTL, target generation, tokenizer,
   sampler stage, corpus, threshold, catalog) → `expired` with the FR-3
   `expiry_cause`.
3. Else if there is no valid result for the window key yet → `unknown`.
4. Else if the verified pass rule and payable-window prerequisites hold →
   `verified`.
5. Else if the payable-window prerequisites hold and the latest valid result is
   warning-class below the quarantine-candidate threshold → `warn`.
6. Else → `pending` (under-sampled, or the latest verdict is a
   `quarantine_candidate` that does not yet satisfy the window quarantine rule).

Only steps 4–5 are payable. In particular, an intervening `quarantine_candidate`
that does not satisfy the window quarantine rule resolves to `pending` at step 6 —
an implementation MUST NOT retain a sticky `verified` across it. `unknown` and
`expired` are preserved as distinct states (they carry distinct settlement reasons
per FR-3) and MUST NOT be collapsed into `pending`.

Abusive inconclusive rule:

- More than 3 `inconclusive` results in 24 hours for the same key, excluding
  coordinator-attributable reference outages, MUST move the key to
  `blocked:abusive_inconclusive`.
- `blocked:abusive_inconclusive` MUST deny covered paid routing and payable
  settlement until manual review or a fresh pass sequence clears the key.

Payable-window prerequisites:

- At least `min_window_canaries` eligible canaries are required before a key can
  become `verified` or payable `warn`.
- The newest eligible canary in the window MUST be no older than
  `positive_state_freshness_ttl_hours`; otherwise the window expires as
  `window_ttl_expired` (non-payable). "Fresh `verified`/`warn`" throughout this
  spec means this TTL is satisfied. This bounds payability to recently-measured
  provider compute even when no new probe has been scheduled.
- The latest window MUST have fresh trusted-reference quorum, fresh thresholds,
  covered sampling-profile scope, and no active `blocked:<reason>` state.
- The latest window MUST NOT satisfy the quarantine rule.
- Under-sampled windows MUST remain `pending` (never `expired`) and MUST NOT
  authorize covered paid routing or payable settlement in enforce mode. A
  warning-class result on an under-sampled, `unknown`, `pending`, or `expired`
  key MUST NOT become payable `warn`.

Verified pass rule:

- The latest `clear_pass_count` eligible canaries **within `window_size_days`**
  MUST be `pass` unless policy approves a stricter per-key pass quorum. Eligible
  canaries older than `window_size_days` MUST NOT count toward the pass sequence, so
  an aged-out window becomes under-sampled → `pending`.

Window quarantine rule:

- The rolling window is 7 days by default.
- At least `min_window_canaries` eligible canaries are required.
- At least `quarantine_candidate_count` of the latest `min_window_canaries`
  eligible canaries MUST be `quarantine_candidate`, regardless of intervening
  `pass` results.
- If `flapping_window_policy_v0_1.enabled` is true, the trigger is the exact
  conjunction: over `lookback_window_days`, the key has at least `min_pass_count`
  `pass`, at least `min_warn_count` `warn`, and at least
  `min_quarantine_candidate_count` `quarantine_candidate` results, AND the
  configured `metric` is at or below `threshold_margin` (i.e., persistently near
  the quarantine boundary). The metrics are defined per eligible canary in the
  lookback as its non-negative margin below the quarantine threshold:
  `canary_median_margin = tau_quarantine_median - median(tv_lower)` and
  `canary_position_margin = tau_quarantine_position - max_position(tv_lower)` (a
  smaller margin means closer to quarantine; margins below 0 are clamped to 0).
  `median_tv_lower_margin_to_quarantine` is the canonical median (SPEC-030 §FR-9
  lower-middle rule) of `canary_median_margin` over the lookback;
  `max_position_tv_lower_margin_to_quarantine` is the minimum of
  `canary_position_margin` over the lookback (the closest any position came to
  quarantine). The trigger boundary is `<=` (`metric <= threshold_margin`). When
  all conjuncts hold, the
  key MUST take the configured `action`. If `action = none`, no state change occurs
  (telemetry only). If `action = blocked:manual_review_required`, the coordinator
  MUST move the key to `blocked:manual_review_required` and persist the predicate
  evidence and configured `clear_rule` in the audit log. A `clear_rule` of
  `dual_approval` clears via dual-approved manual review; a `clear_rule` of
  `clear_pass_count_sequence` clears via `clear_pass_count` consecutive `pass`
  results over at least 24 hours. This is the sole exception to the general rule
  that `blocked:manual_review_required` clears only by dual approval, and it applies
  ONLY when the flapping policy's own `clear_rule` is configured to
  `clear_pass_count_sequence`.
- The trusted reference event set MUST be fresh.

Clear rule:

- `quarantined_compute_drift` clears only after `clear_pass_count` consecutive
  `pass` results over at least 24 hours on the overlay key, or through an explicit
  dual-approved overlay transition that records old/new overlay-key bindings and
  evidence. A `target_generation` change never clears the overlay (the overlay key
  omits `target_generation`). A `corpus_version` or `threshold_version` change
  produces a new overlay key; to prevent operator-rotation amnesty, an active
  `quarantined_compute_drift`/`blocked:<reason>` on the prior overlay MUST write an
  adverse-state lineage tombstone keyed by `(stable_provider_identity, model_id,
  target_model_hash, tokenizer_identity, sampler_stage)` that the coordinator MUST
  consult at request-start capture for the successor corpus/threshold key. While a
  tombstone is unresolved, the successor key MUST NOT regain eligibility through the
  short FR-11 onboarding gate; it regains eligibility only through the full FR-10
  clear rule (`clear_pass_count` consecutive passes over ≥24h) or dual-approved
  manual review that explicitly retires the tombstone.
- `blocked:abusive_inconclusive` clears only after dual-approved manual review
  or `clear_pass_count` consecutive `pass` results over at least 24 hours for
  the same key while the rolling abusive-inconclusive window is below threshold.
- `blocked:reference_missing` clears only after fresh reference admission
  restores quorum for the full covered key.
- `blocked:calibration_missing` clears only after an approved calibration record
  satisfies FR-8 for the full covered key, or after policy removes the key from
  enforce coverage.
- `blocked:reference_fault` clears only after fresh reference admission restores
  reference-set admissibility and manual review records the reference-fault
  resolution.
- `blocked:manual_review_required` and `blocked:swap_laundering_suspected` clear
  only through dual-approved manual review followed by any required fresh pass
  sequence for the same key. The sole exception is a `blocked:manual_review_required`
  entered by `flapping_window_policy_v0_1` whose configured `clear_rule` is
  `clear_pass_count_sequence`, which clears per that configured rule (FR-10 window
  quarantine rule).
- The scheduler MUST support targeted burst probing for onboarding,
  quarantined, or recovering keys so onboarding and 5-pass clear sequences are
  not stretched by the default background cadence unless operator rate limits
  are exhausted.

### FR-11 Onboarding gate

SPEC-036 MUST NOT block the SPEC-026 local App onboarding flow before identity
registration is complete.

After identity registration and before covered paid routing, each new
`(stable_provider_identity, model_id, target_model_hash, tokenizer_identity,
sampler_stage, target_generation, sampling_profile, corpus_version,
threshold_version)` onboarding key MUST pass compute-integrity onboarding when
policy mode is `enforce`, unless the active policy explicitly requires an
all-profile window whose coverage subsumes the buyer request.

In `warn_only`, onboarding computes readiness telemetry only. It MUST NOT block
covered paid routing, provider earnings opportunity, payout readiness, or
buyer-facing claims.

The onboarding gate applies only when neither the swap-laundering overlay
`(stable_provider_identity, model_id)` nor the per-key stable-identity risk overlay
(the canonical overlay key of §3: `(stable_provider_identity, model_id,
target_model_hash, tokenizer_identity, sampler_stage, corpus_version,
threshold_version, <coverage-scope sampling-profile dimension>)`) carries an active
`quarantined_compute_drift` or `blocked:<reason>` state. If the overlay is
quarantined or blocked, the onboarding gate MUST NOT run and MUST NOT produce
payable state; the key inherits the overlay state and only the FR-10 clear rule or
dual-approved manual review can restore eligibility. The onboarding gate is never a
path to bypass an active overlay quarantine.

The default onboarding gate is:

- 5 `pass` canaries.
- At least 30 minutes elapsed between first and final pass.
- Same `model_id`, `target_model_hash`, `tokenizer_identity`, `sampler_stage`,
  `target_generation`, `sampling_profile` or approved all-profile coverage mode,
  corpus version, and threshold version.

A first failed onboarding gate SHOULD schedule exponential backoff and a second
attempt. Two failed full gate attempts within 24 hours MUST move the key to
`blocked:manual_review_required` in enforce mode.

Provider-facing onboarding surfaces MUST expose
`compute_integrity_onboarding_pending`, `compute_integrity_onboarding_failed`,
or `compute_integrity_onboarding_verified`; failed reason; next retry time;
backoff schedule; manual-review contact path; covered sampling profile or
all-profile coverage mode; and an expected wall-clock target.
The policy SHOULD define an initial covered model set so providers are not
silently gated for every model/hash before they opt in.

### FR-12 Warm-swap and generation handling

Positive (payable) compute-integrity state — `verified` and payable `warn` — MUST
NOT carry across target-generation boundaries.

On target model hash change (which also increments `target_generation`), completed
warm-swap, same-hash runtime reload, provider reconnect without continuity proof,
tokenizer identity change, sampler stage change, corpus version change, threshold
version change, or a provider `hardware_runtime_class` change, the affected exact
key's positive state MUST move to `expired` and covered paid routing MUST require
fresh compute-integrity state. A `hardware_runtime_class` change specifically
expires with `expiry_cause = hardware_class_changed` and, because the covered class
is policy-pinned per key (FR-8), a provider whose class no longer matches the covered
class becomes uncovered (observe/warn-only) rather than measured against a
mismatched-class threshold/reference.

Expiry of positive state MUST NOT expire the stable-identity risk overlay.
Active `quarantined_compute_drift`, active `blocked:<reason>` state, and the three
rolling accumulators live on the overlay key (§3; the window key minus
`target_generation`) and MUST persist across every `target_generation` /
`assigned_id` / admission-key change above. A provider MUST NOT return to payable
routing on a generation-churned key while the overlay carries active quarantine or
block state; such a request MUST inherit that state as its request-start state
(FR-4) and settle non-payable.

`target_model_hash` and `tokenizer_identity` are part of the per-key overlay, so a
per-key overlay quarantine is measured against a specific model artifact and does not
by itself transfer to a genuinely different artifact (`corpus_version` and
`threshold_version` are coordinator-controlled and not provider-launderable). To
close the artifact-cycling gap without penalizing benign operation, SPEC-036 defines
a second, higher-level **swap-laundering overlay** keyed by
`(stable_provider_identity, model_id)` — spanning all hashes/tokenizers/generations
for that provider and model. FR-4 request-start capture MUST consult the
swap-laundering overlay **before** the per-key overlay; an active
`blocked:swap_laundering_suspected` at swap-laundering scope MUST deny covered paid
routing and payable settlement for every covered key of that provider/model until
dual-approved manual review.

The escalation trigger is deterministic and distinguishes provider-mutable
*changes* from benign reconnects: a **provider-originated change** of
`target_model_hash`, `tokenizer_identity`, or `target_generation` (NOT a
continuity-proven reconnect and NOT a same-hash reload, which are exempt) MUST move
the swap-laundering overlay to `blocked:swap_laundering_suspected` when, at the time
of the change, the provider's per-key overlay for the prior artifact carries any of:
active `quarantined_compute_drift` or `blocked:<reason>` state, a non-zero
quarantine-candidate window count, a non-zero 24-hour abusive-inconclusive count, or
a non-zero 24-hour onboarding-failure count. This carries provider-attributable risk
(drift, abusive-inconclusive blocks, onboarding-failure blocks, and all three
accumulators) across hash/tokenizer churn, closing the escape path, while a clean
provider (no active risk) changing artifacts is not penalized. A single benign
`warn` with no accumulated risk and no artifact change does NOT trigger escalation.

If a provider re-onboards and receives a new `assigned_id`, the coordinator MUST
look up active `quarantined_compute_drift` and `blocked:<reason>` state on the
stable-identity risk overlay. Active quarantine or block state MUST be inherited by
the new assigned id until the normal clear rule or manual-review rule clears it.
The coordinator MUST also carry forward the active rolling
`quarantine_candidate`/`warn` window, the 24-hour abusive-inconclusive count,
and the 24-hour onboarding-failure count on the overlay. A new `assigned_id`, a new
`target_generation`, an admission-key rotation, or a recovery MUST NOT reset
sub-threshold accumulators or clear active quarantine/block state. A cleared
overlay is required before a new exact key may earn payable state; the shorter FR-11
onboarding gate MUST NOT be used to clear or bypass an active overlay quarantine —
only the FR-10 clear rule (`clear_pass_count` consecutive passes over at least 24
hours) or dual-approved manual review clears it.

### FR-13 Third-party audit

The auditor bundle is a signed artifact using the same signed-artifact profile as
the coordinator's existing signed journey/settlement evidence: an outer envelope
`{type:"compute_integrity_auditor_bundle_v1", schema_version:"compute_integrity_auditor_bundle_v1", payload}`,
a `bundle_digest` computed as SHA-256 over the RFC 8785/JCS canonical form of that
object (excluding `bundle_digest` and `signature`), and a detached `signature` over
`bundle_digest` by a coordinator auditor-signing key whose public key is resolvable
and rotatable through the coordinator's existing signing-key discovery mechanism
(the same key lifecycle as SPEC-015 receipt-key resolution). A verifier verifies the
signature over `bundle_digest`, recomputes `bundle_digest` from the payload, then
recomputes the TV intervals from the retained evidence. Before enforce activation,
the coordinator MUST expose this signed read-only auditor bundle for every
settlement-impacting state, with `payload` containing:

- Policy version and mode.
- Provider/model/hash/tokenizer/sampler-stage/profile key.
- Current provider/model state.
- Window id and threshold version.
- Threshold record digest: SHA-256 over the RFC 8785/JCS canonical object
  `{type:"compute_integrity_threshold_record_v1", schema_version:"compute_integrity_threshold_record_v1", payload}`
  where `payload` is the closed FR-8 threshold record (excluding the digest itself).
- Reference event digests and retained evidence object digests for every trusted
  reference used by the verdict.
- Reference source ids, failure-domain ids, source-independence evidence,
  runtime-build provenance digests AND golden-fixture validation digests (both), refresh
  timestamps, and the full `reference_set_admissibility_v1` object for every
  trusted reference counted toward quorum.
- Inline compact per-position evidence or signed retained-object references with
  retrieval authorization, schema/version, K, threshold record digest, all trusted
  reference digests, provider/reference union support probabilities, tails,
  sampler stage, prompt/position/prefix/context identifiers, and the canonical
  aggregation rule.
- Per-position `prompt_id`, `position_index`, `token_prefix_digest`, and
  `context_hash` digests used by the probe and reference events.
- Latest canary event digests.
- Redacted TV interval summaries.
- State-transition audit log.
- Request-start snapshot digest and settlement row id when present. The
  request-start snapshot digest is SHA-256 over the RFC 8785/JCS canonical object
  `{type:"compute_integrity_request_start_snapshot_v1", schema_version:"compute_integrity_request_start_snapshot_v1", payload}`
  where `payload` is the closed FR-4 captured-state object (the composite SPEC-022 +
  SPEC-036 capture, not the SPEC-022 route snapshot alone).
- Timestamps, retention policy, and redaction policy.

Third parties MUST NOT be able to issue quarantine-grade probes in v0.1.

Third-party measurements MAY be stored as allegations or diagnostic evidence,
but MUST NOT automatically change compute-integrity state.

### FR-14 Audit logging

The coordinator MUST audit:

- Reference event creation.
- Probe issuance.
- Probe result finalization.
- Threshold-version approval.
- State transition.
- Enforce-mode activation/refusal.
- Manual review clear/block decisions.
- Every SPEC-036 settlement decision using the closed reason enum, including the
  captured request-start state, effective reason, circuit-breaker status,
  request-start snapshot digest, and settlement row id.

Audit rows MUST include enough identifiers to join reference event, provider
probe, request-start snapshot, and settlement row without exposing raw prompts
or buyer output beyond existing retention rules.

### FR-15 Disclosure

The active policy MUST bind a `disclosure_copy_version` and a
`disclosure_copy_digest` (SHA-256 over the approved copy set). Each buyer, provider,
public, and auditor surface MUST publish the approved copy for the bound
`disclosure_copy_version` and MUST record the copy version/digest it is serving. A
surface is **stale** when its served `disclosure_copy_version`/digest does not equal
the active policy's bound version/digest, or when a required surface is absent.
Enforce activation MUST refuse while any required surface is missing or stale.

Buyer, provider, public, and auditor surfaces MUST use approved disclosure copy
before enforce activation.

The disclosure copy MUST state:

- SPEC-036 is an overt distribution-drift detector against approved references.
- SPEC-036 v0.1 is not cryptographic proof of honest computation.
- SPEC-036 v0.1 is not hardware integrity, runtime binary integrity, or covert
  canary attestation.
- Covered models, policy mode, sampling-profile coverage, and
  unknown/pending/expired semantics.
- `warn` means measurable drift above the warning threshold was detected, but
  only fresh `warn` windows satisfying payable-window prerequisites,
  sampling-profile coverage, and no active `blocked:<reason>` or circuit-breaker
  hold may be routed and billed in enforce mode. In observe or warn-only mode,
  `warn` is telemetry/readiness state only.
- In enforce mode, `quarantined_compute_drift` means paid routing and payable
  settlement are blocked for the covered key; in observe or warn-only mode it is
  telemetry/readiness state only.
- `verified` and `warn` reflect the latest detection window, not a real-time
  proof about the in-flight request; background drift detection can lag by the
  FR-17 time-to-quarantine SLO and can be about 5 days at the default cadence.

Buyer-facing claims such as "proved honest computation", "guaranteed model
integrity", or "cryptographic compute proof" MUST NOT be used for SPEC-036 v0.1.

Labeling honesty: the machine-readable state `quarantined_compute_drift` and reason
`compute_drift_quarantined` denote **measured divergence from an approved reference
distribution**, not a proven integrity or honesty failure (benign cross-hardware or
runtime numeric variance can contribute, which is why enforce is class-restricted per
FR-8). Provider-facing status and block-reason strings MUST use drift-neutral,
non-accusatory language (e.g. "reference-distribution drift hold", not "integrity
violation") and MUST point to the appeal/manual-review path (FR-16).

### FR-16 Operator controls and manual review

The coordinator MUST expose an operator control to revert
`compute_integrity_settlement.mode` from `enforce` to `warn_only` during an
incident. The downgrade action does not depend on enforce activation checks.
Because settlement is a pure function of immutable request-start state (FR-3, FR-4),
a rollback to `warn_only` simply stops NEW rows from being captured under enforce
(new `warn_only`-captured rows have no money effect, per the warn-only definition);
it does not, and need not, retroactively change any already-captured row's money
outcome. Rows already captured non-payable under enforce (including
`compute_integrity_circuit_breaker_hold` captures) keep that captured outcome; rows
already captured payable under enforce keep that captured outcome. Reactivating
enforce after rollback MUST satisfy all FR-1 preconditions again.

The coordinator MUST implement a circuit breaker that fails closed for affected
covered keys, covered models, or the whole policy when new
`quarantined_compute_drift` or `blocked:reference_fault` transitions **meet or
exceed** (`>=`, matching the FR-1 `circuit_breaker_policy` boundary) the configured
model-level or fleet-level threshold in a rolling window. The circuit
breaker acts by **denying new covered paid admissions** for the affected scope and
by treating the trusted reference set as suspect until fresh reference admission and
manual review complete; new rows admitted while the breaker is active capture
`circuit_breaker_active = true` (from which settlement derives reason
`compute_integrity_circuit_breaker_hold`; the breaker is a captured flag, not a
state). Consistent with SPEC-022 immutability (FR-3, FR-4), the breaker MUST NOT
retroactively reclassify a row already admitted while it was inactive; such rows
settle from their captured payable state. Circuit-breaker activation MUST preserve
existing `quarantined_compute_drift` and `blocked:<reason>` states.

The breaker's routing/settlement effect on **new buyer admissions** applies only
where SPEC-036 is in effective enforce (FR-3 runtime conjunction). The breaker state
itself survives an `enforce → warn_only` rollback and continues to protect
already-captured rows and to deny in-scope enforce admissions, but under warn_only
(or where SPEC-022 is not enforce) new admissions have no money effect regardless,
so warn-only's "MUST NOT alter money" and the breaker's "deny/hold" do not conflict:
the breaker constrains only enforce-effective new admissions and immutable captured
rows.

Circuit-breaker state MUST be one of:

- `inactive`: no hold applies; new admissions capture their normal request-start
  state.
- `active`: the breaker is evaluated atomically **before provider forwarding**, and
  new covered paid admissions in the affected scope MUST be rejected (not forwarded
  as billable buyer work that is then guaranteed non-payable). The coordinator MAY
  record an audit-only rejection row noting the breaker, and the captured
  `circuit_breaker_active = true` / derived `compute_integrity_circuit_breaker_hold`
  path is retained only as defensive settlement handling for an
  invariant-violation/race where a row was nonetheless forwarded — never as a
  permitted admission branch.
- `override_routing_only`: a dual-approved temporary routing override is active for
  the named scope. To avoid knowingly-uncompensated work, an override MUST NOT route
  billable buyer traffic that would capture a non-payable request-start state; it
  MAY open only operator-funded, non-buyer probe/reference/diagnostic traffic.
- `cleared`: fresh reference admission, quiet-window, and manual-review clear
  requirements have succeeded and new rows again capture their normal request-start
  state.

Circuit-breaker clear requires all of:

- A configured quiet window with no new in-scope `quarantined_compute_drift` or
  `blocked:reference_fault` transitions.
- Fresh reference admission and reference-set admissibility for every affected
  covered key.
- Dual-approved manual review of the breaker evidence bundle.
- Audit rows recording previous state, new state, scope, quiet-window bounds,
  reference-set digests, approvers, reason, and timestamp.

An `override_routing_only` record MUST include scope, expiry, rationale,
approvers, and auditor-visible evidence; its maximum expiry is 4 hours unless a
stricter policy value is configured. An override MUST NOT change any already-captured
row's money outcome and MUST NOT open billable buyer traffic under an active breaker
(operator-funded non-buyer traffic only). Only a transition to `cleared` restores
normal payable request-start capture for rows admitted after the clear timestamp.

Manual review MUST define:

- Required evidence bundle and replay/check commands.
- Provider notification and appeal path.
- Operator SLA target.
- Dual approval for clear/block decisions affecting paid routing.
- Reference-fault rollback procedure.
- Audit fields for actor, evidence digests, decision, rationale, and expiry.

### FR-17 Cost, capacity, and funding

Compute-integrity probes are non-billable.

All SPEC-036 probe, trusted-reference, and consensus-telemetry work MUST NOT create
buyer debit, provider credit, provider earnings, payout readiness, or any uncapped
MALIBU / reward accrual, and MUST NOT appear in SPEC-015 v0.4 `usage`. This
prohibition applies to all three workload classes (provider probe responses,
coordinator-controlled trusted-reference forward passes, and optional consensus
telemetry), not only to consensus. Any operator compensation for this work MUST use
an explicitly capped operator/network-funded instrument with per-provider daily caps
and anti-Sybil eligibility (see FR-5); buyer usage, SPEC-015 usage, and uncapped
MALIBU rewards MUST NOT fund it.

V0.1 probe/reference costs MUST be operator/network funded. They MUST NOT be
passed through to buyers as usage and MUST NOT appear in SPEC-015 v0.4 `usage`.

Capacity MUST be budgeted as:

```text
daily_canaries =
  stable_provider_identities
  * covered_model_hash_tokenizer_sampler_stage_profile_corpus_threshold_keys
  * canaries_per_key_per_day

daily_reference_forward_pass_units =
  daily_canaries
  * active_reference_replicas
  * prompts_per_canary
  * positions_per_prompt
  * prompt_token_equivalent_per_position
```

The earlier example of 100 providers x 10 models x 1 canary/key/day is only a
lower-bound toy estimate. Enforce budgets MUST include model hash, tokenizer,
sampler-stage, sampling-profile cardinality, at least two active reference
replicas, onboarding burst headroom, quarantine/recovery burst headroom, and
reference-refresh capacity. Standby nodes do not satisfy the
two-active-reference precondition unless they continuously produce fresh
comparable reference events.

Enforce activation MUST demonstrate reference-event refresh throughput (completed
reference events per unit time) greater than or equal to
`covered_key_cardinality * active_reference_replicas / freshness_ttl` — i.e.
enough to keep at least `active_reference_replicas` (≥ 2) fresh reference events per
covered key within the TTL — plus the deployment's expected warm-swap churn and
retry headroom, with an operator-approved reference-freshness availability SLO. The
enforce activation record MUST state the maximum covered
`(model × hash × tokenizer × sampler_stage × sampling_profile × hardware_runtime_class)`
cardinality the funded reference fleet sustains within the TTL, and catalog/coverage
expansion beyond that cardinality MUST be gated on added reference capacity —
otherwise newly-covered keys fail closed as `compute_integrity_reference_stale`,
which fails closed (non-payable) per FR-3, with availability preserved by the
pre-admission `reference_unavailable_auto_downgrade` mode flip (FR-1).

At the default background budget, a key receives about 1 canary per day. The
spec therefore MUST disclose that default background detection, onboarding, and
clear latency can be about 5 days before retries, outages, or targeted bursts.
Enforce deployment MUST set operator-approved time-to-onboard,
time-to-quarantine, and time-to-clear SLOs and provision background or targeted
burst capacity to meet them.

The initial deployment budget MUST assume either:

- at least two continuously active hosted M4 Pro reference nodes at about
  $698/month for a small covered set, deployed as two **distinct hosts in distinct
  hardware failure domains under independent operator identities** (a single
  identical M4 Pro node cloned within one fault/operator domain does NOT satisfy the
  FR-5 quorum), plus additional idle standby and sharding capacity when
  resident-model count or warm-swap latency cannot refresh all covered
  model/hash/tokenizer/sampler-stage keys within the freshness TTL. The two nodes
  MUST also differ in runtime-build/kernel provenance (FR-5 dimension (c)); a signed
  golden-fixture validation at admission and every refresh is an additional required
  check, not a substitute for operator, hardware, or runtime-build independence. A
  pair of identically-provisioned cloned nodes therefore does NOT satisfy enforce
  quorum; or
- an equivalent self-hosted reference fleet with the same redundancy, sharding,
  freshness, and audit properties.

## 6. Migration

1. **Draft:** Land SPEC-036 and research memo. No code or existing spec edits.
2. **Observe:** Implement reference and canary telemetry with no money effect.
3. **Warn-only:** Emit onboarding readiness, drift, reference, disclosure, and
   audit-bundle telemetry with no money effect and no paid-routing block.
4. **Enforce:** Capture request-start compute-integrity state and map
   `quarantined_compute_drift` to SPEC-022 `quarantined` with reason
   `compute_drift_quarantined`.

Before enforce activation, every covered
`(model_id, target_model_hash, tokenizer_identity, sampler_stage,
sampling_profile, corpus_version, threshold_version)` key MUST complete an
approved warn-only calibration gate. Corpus or threshold-version changes
invalidate prior warn-only calibration for enforce until the new full key
completes its gate. The default per-key gate is at
least 30 days of warn-only data, at least 100 eligible canaries, a hard minimum of
at least 10 distinct stable provider identities in the calibration sample (the
"when available" relaxation is removed: a key that cannot reach the diversity floor
MUST remain observe/warn-only, since burst probing raises canary COUNT but cannot
raise identity DIVERSITY, and false-positive validation strength depends on
diversity — maintainers MAY approve a statistically justified lower floor with
recorded rationale, below which the key stays warn-only), and at least one relevant
trusted-reference refresh after the latest reference runtime/build,
runtime-build provenance digest, signed golden-fixture validation digest,
tokenizer, sampler-stage, corpus, threshold, or catalog change. A fleet-wide
summary gate MAY also require at least 10,000 eligible canaries, at least 100
distinct
provider/model/hash/tokenizer/sampler-stage keys, and
at least three reference refresh or catalog/model rotation events, but
fleet-wide evidence MUST NOT substitute for a missing covered-key calibration.
A risk waiver MAY only remove that key from enforce coverage or keep it in
observe/warn-only mode; a covered enforce key with missing per-key calibration
MUST fail closed as `compute_integrity_calibration_missing`.

Rows started before enforce activation are not retroactively reclassified and
settle under their request-start policy mode. Existing covered keys are
evaluated prospectively at enforce activation: active
`quarantined_compute_drift`, `blocked:<reason>`, `expired`, stale, unreadable,
or under-sampled states MUST carry forward or fail closed until the normal
fresh-pass or manual-review clear rule succeeds.

### 6.1 v0.1 enforce reachability and honest scope

SPEC-036 v0.1 normatively specifies the full observe → warn_only → enforce ladder,
but **enforce is explicitly maintainer-gated and is not claimed to be reachable at
current beta supply**, and v0.1 primarily delivers observe/warn-only drift telemetry.
This is a deliberate, recorded scope decision (DECISION_CRITERIA Entry 181), for
these reasons:

- **Accrual vs cadence.** At the default ~1 canary/key/day cadence (FR-17), the
  per-key gate's ≥100 *eligible* canaries takes on the order of 100+ days (not 30),
  and the "≥10 distinct stable provider identities when available" clause is
  unreachable with the one-to-few controllable providers of the current beta.
  Enforce for a real covered set therefore requires either dedicated burst-probing
  budget with a stated wall-clock, or more supply, or both. The 30-day floor is a
  floor, not the binding constraint.
- **Proportionality.** SPEC-036 is an *overt* detector (§4): it is defeated by a
  provider that recognizes the `compute_integrity_probe_v1` frame, and fresh `warn`
  remains payable, so enforce blocks only the gross-substitution quarantine tail —
  overlapping what the SPEC-022 hash gate already covers. Enforcing before the
  honest-provider protections above (hardware-class restriction, measured-FP gate,
  reference-outage auto-downgrade, tightened swap-laundering) are validated
  would risk net-harming honest providers more than it deters cheating.
- **Identity authority is a hard prerequisite, not a supply problem.** Enforce's
  Sybil precondition (FR-1) requires a named stable-device/operator-identity
  authority that the shipped SPEC-026 App-Attest track does not provide (it is
  optional/client-dormant and allows many keys per device). Until a pre-vetted
  provider-account regime or equivalent authority exists, enforce is architecturally
  unavailable for the shipped track — adding reference capacity or calibration data
  cannot unblock it.
- **Honest disclosure.** FR-11 provider-facing "expected wall-clock target" MUST be
  set from the true accrual budget (which may be ~100 days for a new key at default
  cadence), stated separately from the FR-15 ~5-day *detection* lag. FR-15 MUST NOT
  imply enforce is imminent where supply/calibration/identity cannot support it.

Enforce activation for any covered key is therefore permitted only after the
maintainer group ratifies, per key: sufficient supply/burst budget to accrue the
gate within a stated wall-clock, a measured-FP budget met over the covered
`hardware_runtime_class` (FR-8), an independent two-hardware-failure-domain reference
set (FR-5/FR-17), and the disclosure surfaces (FR-15). Absent that ratification the
key remains observe/warn-only. This keeps v0.1 lockable as a normative artifact while
being honest that its money-affecting mode turns on only when supply and validation
exist.

## 7. Acceptance Criteria

Before SPEC-036 can move toward LOCK:

1. A threshold-calibration fixture covers records keyed by the full 8-tuple
   `(model_id, target_model_hash, tokenizer_identity, sampler_stage,
   sampling_profile, corpus_version, threshold_version, hardware_runtime_class)`,
   baseline p99 fields, minimum sample/position counts, a numeric false-positive
   budget with a measured realized false-quarantine rate at or below it, threshold-
   version changes, and activation refusal when calibration is missing, underpowered,
   or lacks the measured-FP validation. It also proves enforce is class-restricted:
   a provider whose `hardware_runtime_class` differs from the covered class cannot
   enter enforce and remains observe/warn-only.
2. A reference-event fixture covers trusted reference admission, signed catalog
   hash match, tokenizer identity match, sampler stage, reference-set and
   reference-event digests, source and failure-domain independence,
   both runtime-build provenance AND signed golden-fixture validation digests
   (non-substitutable), freshness TTL, and refresh on reference runtime/build update,
   runtime-build provenance digest change, signed golden-fixture validation
   digest change, tokenizer, sampler-stage, corpus, threshold, and catalog
   change. It proves old reference events become inadmissible after
   runtime-build provenance digest changes and signed golden-fixture validation
   digest changes.
3. A probe-schema and TV computation test covers `compute_integrity_probe_v1`
   RFC 8785/JCS canonical `probe_request_digest`/`probe_result_digest`
   computation over `{type, schema_version, payload}` with request/result domain
   separation, result echo of `probe_request_digest`, duplicate request-digest
   replay rejection, identity echoes, nonce/digest/expiry rejection,
   reference-top-K union support, per-position prompt/prefix/context binding,
   prefix or position mismatch rejection as `inconclusive:position_mismatch`,
   provider-vs-reference tail-mass lower/upper bounds, explicit K=64 to K=256
   retry predicates, high-tail inconclusive, and coordinator-owned verdict
   computation.
4. A window-state test covers `quarantine_candidate_count` of the latest
   `min_window_canaries` eligible canaries, proves intervening passes do not
   reset quarantine-candidate counting, quarantine removing paid routing,
   abusive inconclusive
   `blocked:abusive_inconclusive`, 5-pass clear, expired target generation,
   stale-verified request-start re-evaluation, and
   `blocked:manual_review_required` clear. It also proves
   `flapping_window_policy_v0_1` disabled-by-default behavior, schema
   validation, trigger predicate with numeric fixtures for the
   `median_tv_lower_margin_to_quarantine` and
   `max_position_tv_lower_margin_to_quarantine` metric formulas, `none` versus
   `blocked:manual_review_required` action, required audit fields, and both
   `clear_rule` variants. It also proves under-sampled windows remain `pending`
   (never `expired`) and cannot authorize paid routing or payable settlement, and
   that accumulator ownership is on the overlay key (accumulators are not merged
   across policy-separated profiles and are not reset by `assigned_id`/generation
   churn).
5. A settlement test proves request-start `quarantined_compute_drift` maps to
   `outcome=quarantined` and `reason=compute_drift_quarantined`, never
   `zero_settled`, while the SPEC-015 receipt-verifier result remains
   orthogonal. It proves a captured `circuit_breaker_active = true` flag makes a
   preserved underlying `verified`/`warn` row non-payable with derived reason
   `compute_integrity_circuit_breaker_hold` (the breaker is a separate flag, not a
   compute-integrity state). It also proves SPEC-022 subordination: activation
   refuses when SPEC-022 is not enforce or does not subsume SPEC-036's coverage;
   SPEC-036 does not alter money outcome when the captured composite snapshot shows
   SPEC-022 was not enforce; and changing either captured policy after request
   start leaves the row's settlement unchanged (request-start immutability).
6. A compatibility test proves no compute-integrity fields are added to
   SPEC-015 v0.4 receipts or `usage`, and an accounting fixture proves that
   provider probe responses, coordinator trusted-reference forward passes, and
   consensus telemetry create no buyer debit, provider credit, earnings, payout
   readiness, or uncapped MALIBU/reward accrual, and that any compensation uses a
   capped operator-funded instrument (FR-17).
7. An onboarding test proves a SPEC-026 v2 provider can complete local
   onboarding; warn-only does not block billable routing; enforce blocks
   billable routing until the compute-integrity onboarding gate passes for the
   covered sampling profile or approved all-profile coverage mode; and
   provider-facing pending/failed/verified status plus retry metadata and
   coverage mode are visible.
8. A warm-swap/re-onboarding test proves positive compute-integrity state expires
   across target-generation boundaries and cannot be laundered by
   provider-originated ready-state updates or SPEC-026 re-onboarding with a new
   `assigned_id`, admission-key rotation, or recovery. It proves the overlay
   inherits active quarantine/block state and does not reset partially accumulated
   quarantine windows, abusive-inconclusive counts, or onboarding-failure counts
   for the same stable identity across `assigned_id`/`target_generation` churn, and
   that request-start capture consults the overlay so a generation-churned key
   settles non-payable while the overlay is quarantined. It also proves that
   a provider-originated `target_model_hash`/`tokenizer_identity` change made while
   the per-key overlay carries active risk (a non-zero quarantine-candidate/abusive-
   inconclusive/onboarding-failure accumulator or an active block) escalates to a
   `blocked:swap_laundering_suspected` block at `(stable_provider_identity, model_id)`
   swap-laundering scope, while a benign `warn` with no accumulated risk and a
   continuity-proven reconnect or same-hash reload do NOT escalate.
9. An audit/export test proves reference events, probe digests, state
   transitions, and settlement quarantine rows are linkable by digest/id without
   exposing raw buyer prompts or outputs; signed auditor bundles exist before
   enforce; and a verifier can recompute settlement-impacting TV intervals from
   exported inline compact evidence or signed retained-object references with
   retrieval authorization, schema/version, K, threshold record digest, all
   trusted reference digests, provider/reference union support probabilities,
   tails, sampler stage, prompt/position/prefix/context identifiers, and the
   canonical aggregation rule.
10. Enforce activation tests prove startup or activation refuses when trusted
    reference, calibration, settlement capture, disclosure, or storage
    preconditions are missing.
11. A sampling-profile coverage test proves settlement denies covered paid
    requests whose buyer sampling profile is not covered by the captured fresh
    window.
12. A disclosure test proves each required buyer, provider, public, and auditor
    surface exposes approved copy; activation refuses when any required surface is
    missing or stale; and approved copy forbids honest-computation,
    cryptographic-proof, hardware-integrity, and binary-integrity claims.
13. An operator-control test proves manual-review dual approval, enforce to
    warn-only deactivation without retroactive payability changes, rollback not
    disabling active circuit-breaker holds, full FR-1 preconditions before
    reactivating enforce, fail-closed circuit-breaker activation on
    quarantine/reference-fault spikes, `override_routing_only` not making held
    settlement payable, and `cleared` transition only after quiet-window, fresh
    reference admission, dual approval, and audit-field requirements are met.
14. A capacity test proves configured background and targeted burst canary rates
    meet the operator-approved time-to-onboard, time-to-quarantine, and
    time-to-clear SLO, and that the reference fleet sustains freshness across
    the full covered key set under modeled warm-swap churn.
15. A reference-quorum test proves missing trusted-reference quorum produces
    `blocked:reference_missing`, trusted-reference disagreement produces
    `blocked:reference_fault`, duplicate or non-independent reference sources
    cannot satisfy enforce quorum, that two references sharing a runtime-build/kernel
    provenance FAIL quorum (map to `independence_failed`) even when both pass
    golden-fixture validation — i.e. golden fixture is an additional mandatory check
    and never substitutes for operator, hardware-failure-domain, or
    runtime-build/kernel independence — that missing runtime-build provenance and
    missing golden-fixture validation each independently fail admission,
    pass/quarantine verdicts use the agreed envelope across all active admissible
    trusted references, both suppress provider drift counters, and both appear in
    auditor bundles.
16. A closed-reason test proves every enforce-mode non-payable
    compute-integrity state maps to the v0.1 settlement reason enum.
17. A sampler-stage test proves sampler stage is included in keys, thresholds,
    request-start capture, expiry triggers, and probe identity validation, and
    that v0.1 enforce refuses sampler stages without defined capture and
    normalization semantics.

## 8. Resolved v0.1 Decisions

The five drafting open questions are resolved for v0.1 as follows. Each item
marked **maintainer-approval-required at LOCK** is a defensible v0.1 default that
the MacProvider SPEC Maintainers group must ratify before enforce activation; the
default holds unless maintainers record a stricter value in the LOCK PR or
`beta/DECISION_CRITERIA.md`.

1. **Enforce reference mode — trusted-reference-only is permitted; funded hybrid
   is NOT mandatory in v0.1.** Enforce for a covered key requires at least two
   independent fresh trusted reference events (FR-1, FR-5); the coordinator-held
   trusted reference is the sole enforcement authority. N-provider consensus is
   telemetry-only and MUST NOT create automatic quarantine without a fresh
   trusted-reference event (FR-5). Rationale: funded N≥3 independent-provider
   participation is not available at beta scale, and two independence-checked
   trusted references already give a defensible enforcement envelope; mandating
   hybrid would block enforce indefinitely. Rejected alternative: mandatory
   funded hybrid — deferred to a future version when consensus funding
   (item 5) exists. *Maintainer-approval-required at LOCK* for making hybrid
   mandatory on any specific covered key.

2. **Initial threshold floors `0.015/0.030/0.060/0.120` are accepted as the v0.1
   warn-only calibration-period defaults.** They are floors under the FR-8
   `max(floor, baseline_p99 + delta)` formulas, so they only widen for noisier
   keys and never tighten below the floor. No key may enter enforce on floors
   alone: FR-8 still requires an approved per-key calibration record meeting the
   minimum sample/position/coverage/tail-mass/false-positive-target requirements.
   *Maintainer-approval-required at LOCK* for the final per-key threshold table.

3. **New-provider onboarding gate is 5 `pass` canaries over at least 30 minutes**
   (FR-11), not a longer fixed 24-hour pre-routing window. Rationale: paired with
   FR-10 targeted burst probing for onboarding keys, 5 passes over ≥30 minutes is
   achievable without multi-day latency while still resisting single-shot
   laundering; the stricter 24-hour clock is retained where it matters most —
   quarantine and block *clear* rules (FR-10) still require `clear_pass_count`
   consecutive passes over at least 24 hours. Rejected alternative: a blanket
   24-hour pre-routing hold for all new providers — rejected as onboarding-UX
   hostile for the marginal laundering resistance it adds over the 30-minute
   burst gate plus stable-identity inheritance (FR-12). *Maintainer-approval-
   required at LOCK* for lengthening the onboarding gate on high-risk model sets.

4. **The proposed per-covered-key warn-only calibration gate is adopted as the
   minimum enforce timeline** (Migration §6): at least 30 warn-only days, at least
   100 eligible canaries, at least 10 distinct stable provider identities when
   available, and at least one relevant trusted-reference refresh after the latest
   reference runtime/build, runtime-build provenance digest, signed golden-fixture
   validation digest, tokenizer, sampler-stage, corpus, threshold, or catalog
   change. Fleet-wide evidence MAY be additionally required but MUST NOT substitute
   for a missing covered-key gate. *Maintainer-approval-required at LOCK* if
   maintainers require longer observation or larger per-key samples.

5. **Consensus-telemetry funding is not required for v0.1 enforce**, because
   enforce is trusted-reference-only (item 1). If consensus telemetry is enabled,
   it MUST be funded only from capped non-buyer operator/network credits with
   per-provider daily caps and anti-Sybil eligibility (FR-5, FR-17). Buyer usage,
   SPEC-015 v0.4 `usage`, and uncapped MALIBU rewards MUST NOT fund it. The
   concrete capped-credit instrument for a future mandatory-hybrid mode is
   deferred to that later version and its funding decision. *Maintainer-approval-
   required at LOCK* before any mandatory-hybrid enforce deployment.

## 9. Non-Goals

- Proving hardware integrity.
- Proving runtime binary integrity.
- Proving malicious-provider honesty under overt probes.
- Adding buyer-facing canary issuance.
- Changing buyer API request or response schema.
- Changing SPEC-015 v0.4 receipt shape.
- Changing SPEC-022 outcome enum in v0.1.

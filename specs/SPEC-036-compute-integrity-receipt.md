# SPEC-036 — Compute-Integrity Receipt Companion

**Status:** v0.1-draft
**Date:** 2026-07-10
**Depends on:** SPEC-015 v0.4.2, SPEC-022 v0.1.5, SPEC-026 v0.26, SPEC-030 v0.1 (Losslessness Probe — shared distribution-snapshot / support-selection / TV-interval / probe-transport primitive)
**Companion research:** `docs/research/compute-integrity-receipt-2026-07.md`

**Numbering + dependency note (2026-07-22).** This spec was drafted as `SPEC-030`
against `SPEC-029` before the 2026-07-10 corpus-hygiene renumber. It is now
canonical **SPEC-036** to resolve the collision with
`SPEC-030-losslessness-probe.md`, and its shared measurement primitive dependency
is rewired from the pre-renumber `SPEC-029` to canonical **SPEC-030 (Losslessness
Probe)**, which owns the distribution-snapshot / `support_selection_v1` /
TV-interval / authenticated-probe-transport machinery this spec composes on. See
`beta/DECISION_CRITERIA.md` Entry 181 for the compose-vs-duplicate reconciliation.
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
- Redefining the probe transport or distribution-snapshot mechanism; SPEC-036
  composes on SPEC-030 (Losslessness Probe) §FR-3 (transport/auth/load bounds),
  §FR-4 (probe identity/replay binding), §FR-7 (`support_selection_v1`), and
  §FR-9 (TV-interval computation) rather than re-specifying them.
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

**Reference event:** A coordinator record containing model id, target model
hash, tokenizer identity, sampler stage, sampling profile, corpus version,
threshold version, reference source id, reference failure-domain id,
computed reference distribution summary, runtime-build provenance digest or
golden-fixture validation digest, refresh timestamp, per-position prompt
identifiers, position indexes, teacher-forced prefix digests, context hashes, and
retained compact evidence needed to recompute the TV interval for every provider
union support used by a verdict. The stored `reference_event_digest` is an outer
field and `payload.reference_event_digest` MUST NOT exist. The digest MUST be
SHA-256 over the RFC 8785/JCS canonical object
`{type:"reference_event_v1", schema_version:"reference_event_v1", payload}`.
The payload key set is closed over: `model_id`, `target_model_hash`,
`tokenizer_identity`, `sampler_stage`, `sampling_profile`, `corpus_version`,
`threshold_version`, `reference_source_id`, `reference_failure_domain_id`,
`computed_reference_distribution_summary`, `runtime_build_provenance_digest` or
`golden_fixture_validation_digest`, `refresh_timestamp`, `prompt_id`,
`position_index`, `token_prefix_digest`, `context_hash`, `support_selection`,
`normalization_basis`, `k`, `reference_top_k_token_ids`,
`reference_union_support_probabilities`, `reference_tail_mass`, and
`retained_evidence_object_digest` when evidence is not inline.

**Stable provider identity:** The coordinator identity that survives SPEC-026
re-onboarding for the same provider trust root, such as a provider signing key,
hardware-bound registration key, or other approved identity binding. A new
`assigned_id` MUST NOT clear active compute-integrity quarantine or block state
for the same stable provider identity.

**Compute-integrity key:** `(stable_provider_identity, provider_id,
assigned_id, model_id, target_model_hash, tokenizer_identity,
sampler_stage, target_generation, sampling_profile, corpus_version,
threshold_version)`.

**Window key:** `(stable_provider_identity, model_id, target_model_hash,
tokenizer_identity, sampler_stage, target_generation, corpus_version,
threshold_version)` without `sampling_profile` when policy requires all profiles
to pass, or with `sampling_profile` when a rollout covers only a named profile
set. Window accumulators MUST NOT include `assigned_id`.

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
- `corpus_version`.
- `threshold_version`.
- `window_size_days`, default 7.
- `min_window_canaries`, default 5.
- `quarantine_candidate_count`, default 3.
- `clear_pass_count`, default 5.
- Reference freshness TTL, default 24 hours.
- Abusive inconclusive limit, default more than 3 inconclusive probe results
  in 24 hours for the same key.
- Circuit-breaker thresholds for fleet or model-level quarantine spikes.
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
  exposes the inherited authentication, replay, load-bound, and TV-bound
  primitives (SPEC-030 §FR-3, §FR-4, §FR-7, §FR-9) required by SPEC-036 FR-6 and
  FR-7.
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
verification. For covered enforce rows, compute-integrity quarantine overrides
SPEC-022 R-8.1/R-8.4 final debit and provider-credit eligibility even when the
SPEC-015 receipt is cryptographically valid. Implementations SHOULD record the
orthogonal SPEC-015 cryptographic/schema verifier result in an internal audit
field such as `receipt_crypto_result`, but SPEC-022 money rules MUST read the
settlement field that SPEC-036 sets to `quarantined`.

In enforce mode, a covered paid request MUST NOT create buyer final debit,
provider credit, earnings visibility, settlement-sweep inclusion, or payout
readiness unless the captured request-start compute-integrity state is fresh
`verified` or fresh `warn` for a covered sampling-profile window. Captured
`unknown`, `pending`, `quarantined_compute_drift`, `blocked:<reason>`,
`expired`, stale, unreadable, or uncovered-profile state MUST fail closed. The
coordinator MAY hold such a row pending until a bounded settlement deadline; at
deadline it MUST settle as `quarantined` with a specific reason.

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
- `target_generation_changed` -> `compute_integrity_expired`.
- `tokenizer_changed` -> `compute_integrity_expired`.
- `sampler_stage_changed` -> `compute_integrity_expired`.
- `corpus_changed` -> `compute_integrity_expired`.
- `catalog_changed` -> `compute_integrity_expired`.
- `sampling_profile_uncovered` -> `compute_integrity_uncovered_profile`.
- `state_unreadable` -> `compute_integrity_unreadable`.

Unknown `expiry_cause` values MUST be rejected before settlement or fail closed
as `compute_integrity_unreadable`.

If a circuit-breaker hold is active for the captured covered key, model, or
whole policy at settlement time, captured `verified` or `warn` state MUST fail
closed as `compute_integrity_circuit_breaker_hold` until the FR-16
circuit-breaker state reaches `cleared`.

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
- `compute_integrity_state`.
- `expiry_cause` when state is `expired`.
- `compute_integrity_window_id`.
- `reference_set_id`.
- `reference_event_digests` for all active trusted references used by the
  verdict.
- `reference_source_ids`, `reference_failure_domain_ids`, and source-independence
  evidence for every reference counted toward quorum.
- Runtime-build provenance digests or golden-fixture validation digests for every
  reference counted toward quorum.
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
  runtime-build provenance digest or golden-fixture validation digest, and
  refresh timestamp.
- `reference_set_admissibility_status`. Allowed values are `admissible`,
  `missing_quorum`, `reference_fault`, `stale_reference`,
  `independence_failed`, `provenance_missing`, and `schema_invalid`. Unknown
  values MUST fail closed. Only `admissible` can support payable `verified` or
  payable `warn`.
- `reference_quorum_count`.
- `reference_fault_check_version`.
- `circuit_breaker_scope` and `circuit_breaker_active` at capture when active.
- `threshold_version`.
- `corpus_version`.
- `target_generation`.
- `captured_at`.

Settlement MUST read the captured request-start state, not the current provider
state at settlement time, except that settlement MUST also re-evaluate FR-16
circuit-breaker holds for the captured covered key, covered model, or whole
policy before treating captured `verified` or `warn` as payable.

At request-start capture, the coordinator MUST deterministically re-evaluate
reference freshness, threshold freshness, window TTL, target generation,
tokenizer identity, sampler stage, and sampling-profile coverage. If any
freshness or coverage check fails, the captured state MUST be `expired` with an
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
- Each enforce-mode reference source MUST have source and failure-domain
  independence from every other source counted toward the same covered key's
  quorum. Independence is proven by independent runtime-build/kernel/hardware
  provenance, or by independently validated runtime-build/kernel/hardware
  failure domains that are additionally validated against a signed
  golden-distribution fixture at admission and every refresh. Two sources sharing
  a runtime build, kernel, hardware failure domain, or operator-controlled source
  identity MUST NOT both count toward the two-reference enforce quorum even when
  both pass the golden fixture.

Hybrid mode SHOULD also collect N-provider consensus telemetry with N >= 3, but
consensus telemetry MUST NOT create automatic quarantine in v0.1 without a fresh
trusted-reference event for the same key.

Reference-set admissibility:

- In enforce mode, every covered key MUST have at least two independent fresh
  trusted reference events for the same model/hash/tokenizer/sampler-stage/
  profile/corpus/threshold key.
- The coordinator MUST compare active trusted references over the same corpus,
  support-selection rule, K, and sampling profile.
- Pairwise reference-vs-reference TV MUST remain within the calibrated
  `reference_fault` threshold before any provider result can count as `pass`,
  `warn`, or `quarantine_candidate`.
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

Compute-integrity probes compose on the SPEC-030 (Losslessness Probe) shared
measurement machinery and MUST inherit only the following SPEC-030 primitives, by
the cited SPEC-030 sections, rather than re-specifying them:

- Authenticated provider-control channel (SPEC-030 §FR-3).
- Single-use unpredictable nonce (SPEC-030 §FR-3).
- Expiry no more than 120 seconds after issuance (SPEC-030 §FR-3).
- Request/result digest binding over an outer envelope with an inner `payload`
  computed by RFC 8785/JCS (SPEC-030 §FR-4).
- K limited to 64 or 256 (SPEC-030 §FR-3).
- At most 4 prompts and 8 stochastic measurement positions per result
  (SPEC-030 §FR-3).
- Per-provider concurrent compute-integrity probes limited to 1 (SPEC-030 §FR-3).
- Provider probe work is non-billable (SPEC-030 §FR-3, §FR-17).
- The `support_selection_v1` shared-support construction rule (SPEC-030 §FR-7):
  the numeric-ascending union of the two arms' top-K token ids, with
  full-distribution probabilities reported over the union and tail mass outside
  it. SPEC-036 carries this rule under the settlement-scoped constant
  `compute_integrity_support_selection_v1` (its second arm is the coordinator-held
  trusted reference, not SPEC-030's provider plain path); the construction
  algorithm is identical and inherited by normative reference.
- TV lower/upper bound computation over compact distributions and tails
  (SPEC-030 §FR-9).

SPEC-036 introduces exactly one genuinely new measurement arm on top of that
inherited machinery: the comparison is **provider-vs-coordinator-held-trusted-
reference** (cross-node), not SPEC-030's provider **plain-vs-spec** self-
consistency. Everything downstream of the raw compact distributions that differs
(reference admission/quorum, the settlement-gating consumer, and the
`quarantined_compute_drift` state) is specified in FR-2/FR-3/FR-5/FR-10 of this
spec and is not inherited.

The two probe profiles are deliberately kept as distinct wire constants because
their trust consumers differ: SPEC-030 `losslessness_probe_v1` is non-settlement
implementation-health telemetry, while SPEC-036 `compute_integrity_probe_v1`
gates paid settlement. SPEC-036 MUST NOT reuse SPEC-030's `losslessness_probe_v1`
request/result payload fields, `type`, or `schema_version` for
settlement-impacting compute-integrity probes. SPEC-030's prohibitions on
settlement use apply to SPEC-030 `losslessness_probe_v1` verdicts, not to
SPEC-036 `compute_integrity_probe_v1` verdicts. SPEC-036 MUST still treat
SPEC-030's losslessness results as non-settlement telemetry unless a later
SPEC-030 addendum explicitly changes that boundary. Sharing the `support_selection_v1`
and TV-interval definitions across the two profiles is a normative-reference
reuse of the same algorithm, not a reuse of the settlement-bearing wire payload.

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
- For each measurement position: `prompt_id`, redacted prompt handle,
  `position_index`, `token_prefix_digest`, and `context_hash` over the exact
  teacher-forced token prefix to be measured.
- K value.
- Reference top-K token ids for each measurement position. These are mandatory
  for every probe used for TV computation, verdict assignment, state transition,
  or calibration. They MAY be omitted only for schema dry-runs that cannot affect
  calibration or state.

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
- Identity echo fields for model, hash, tokenizer, generation, profile, corpus,
  and threshold.
- Provider top-K token ids and probabilities for each position.
- Provider probabilities over the union of provider top-K and reference top-K
  token ids for each position.
- Provider tail mass outside that union.
- Echoes of `prompt_id`, `position_index`, `token_prefix_digest`, and
  `context_hash` for every measurement position.
- `support_selection`, `normalization_basis`, and `sampler_stage` echoes.
- Timing and validation metadata.

The coordinator MUST reject results whose echoed identity fields, nonce,
`type`, `schema_version`, `probe_request_digest`, `probe_result_digest`, expiry,
position identifiers, teacher-forced prefix digests, context hashes, or
union-support fields do not match the issued request and corpus position. The
coordinator MUST reject replay of a duplicate `probe_request_digest` outside the
issued probe attempt and MUST log digest mismatches as validation failures.

The coordinator MUST validate compact distributions before computing TV:

- All probabilities and tail masses are finite and in `[0, 1]`.
- Token ids are valid for `tokenizer_identity`.
- Provider top-K token ids are length K, ordered by non-increasing probability,
  and contain no duplicates.
- The shared support is exactly the union of reference top-K and provider top-K
  token ids, with one probability per support token.
- Shared-support length is between K and 2K.
- `sum(provider_support_probabilities) + provider_tail_mass` equals 1 within
  the approved numeric tolerance.
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

For each measurement position, the coordinator MUST compute provider-vs-reference
TV intervals over `compute_integrity_support_selection_v1` shared support. The
coordinator sends reference top-K token ids for the position, the provider
returns its own top-K plus probabilities over the union of reference top-K and
provider top-K, and the coordinator recomputes reference probabilities and tail
mass over the same union before computing:

```text
support_diff = sum(abs(p_provider(token) - p_reference(token)))
tv_lower = 0.5 * (support_diff + abs(provider_tail_mass - reference_tail_mass))
tv_upper = 0.5 * (support_diff + provider_tail_mass + reference_tail_mass)
```

The provider MUST NOT supply the authoritative verdict. The coordinator verdict
MUST be derived from raw compact distributions, tail masses, identity fields,
and the active threshold record.

At K=64, the coordinator MUST retry at K=256 before assigning `pass`, `warn`,
or `quarantine_candidate` if any of these predicates is true:

- Either side's tail mass exceeds `0.01`.
- `median(tv_upper) > tau_warn_median`.
- Any position `tv_upper > tau_warn_position`.
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
sampler_stage, sampling_profile, corpus_version, threshold_version)`.

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
Enforce activation MUST refuse thresholds whose calibration record does not meet
the approved minimum eligible canary count, position count, coverage,
tail-mass, and false-positive target for the covered key. A covered enforce key
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

`warn` MUST NOT block covered paid routing by itself.

### FR-10 Window state machine

The coordinator MUST maintain compute-integrity state per compute-integrity key.

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

Abusive inconclusive rule:

- More than 3 `inconclusive` results in 24 hours for the same key, excluding
  coordinator-attributable reference outages, MUST move the key to
  `blocked:abusive_inconclusive`.
- `blocked:abusive_inconclusive` MUST deny covered paid routing and payable
  settlement until manual review or a fresh pass sequence clears the key.

Payable-window prerequisites:

- At least `min_window_canaries` eligible canaries are required before a key can
  become `verified` or payable `warn`.
- The latest window MUST have fresh trusted-reference quorum, fresh thresholds,
  covered sampling-profile scope, and no active `blocked:<reason>` state.
- The latest window MUST NOT satisfy the quarantine rule.
- Under-sampled windows MUST remain `pending` or `expired` and MUST NOT
  authorize covered paid routing or payable settlement in enforce mode. A
  warning-class result on an under-sampled, `unknown`, `pending`, or `expired`
  key MUST NOT become payable `warn`.

Verified pass rule:

- The latest `clear_pass_count` eligible canaries in the window MUST be `pass`
  unless policy approves a stricter per-key pass quorum.

Window quarantine rule:

- The rolling window is 7 days by default.
- At least `min_window_canaries` eligible canaries are required.
- At least `quarantine_candidate_count` of the latest `min_window_canaries`
  eligible canaries MUST be `quarantine_candidate`, regardless of intervening
  `pass` results.
- If `flapping_window_policy_v0_1.enabled` is true, a key with the configured
  pass/candidate mix and near-threshold predicate in the configured lookback
  window MUST take the configured action. If that action is
  `blocked:manual_review_required`, the coordinator MUST persist the predicate
  evidence and configured clear rule in the audit log.
- The trusted reference event set MUST be fresh.

Clear rule:

- `quarantined_compute_drift` clears only after `clear_pass_count` consecutive
  `pass` results over at least 24 hours for the same key, or after manual review
  creates a new threshold/corpus/generation key.
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
  sequence for the same key.
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

Compute-integrity state MUST NOT carry across target-generation boundaries.

On target model hash change, completed warm-swap, same-hash runtime reload,
provider reconnect without continuity proof, tokenizer identity change, sampler
stage change, corpus version change, or threshold version change, the affected
key MUST move to `expired` and covered paid routing MUST require fresh
compute-integrity state.

If a provider repeatedly changes generation after `warn` or
`quarantine_candidate` results, the coordinator SHOULD move the key to
`blocked:swap_laundering_suspected` until manual review.

If a provider re-onboards and receives a new `assigned_id`, the coordinator MUST
look up active `quarantined_compute_drift` and `blocked:<reason>` state by
stable provider identity. Active quarantine or block state MUST be inherited by
the new assigned id until the normal clear rule or manual-review rule clears it.
The coordinator MUST also carry forward the active rolling
`quarantine_candidate`/`warn` window, the 24-hour abusive-inconclusive count,
and the 24-hour onboarding-failure count for the same stable provider identity,
model, hash, tokenizer, sampler stage, generation, profile, corpus, and
threshold key. A new `assigned_id` MUST NOT reset sub-threshold accumulators.

### FR-13 Third-party audit

Before enforce activation, the coordinator MUST expose a signed read-only
compute-integrity auditor bundle for every settlement-impacting state:

- Policy version and mode.
- Provider/model/hash/tokenizer/sampler-stage/profile key.
- Current provider/model state.
- Window id and threshold version.
- Threshold record digest.
- Reference event digests and retained evidence object digests for every trusted
  reference used by the verdict.
- Reference source ids, failure-domain ids, source-independence evidence,
  runtime-build provenance digests or golden-fixture validation digests, refresh
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
- Request-start snapshot digest and settlement row id when present.
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

### FR-16 Operator controls and manual review

The coordinator MUST expose an operator control to revert
`compute_integrity_settlement.mode` from `enforce` to `warn_only` during an
incident. The downgrade action does not depend on enforce activation checks, but
mode rollback MUST NOT disable active circuit-breaker routing or settlement
holds. Opening traffic while a circuit-breaker hold is active requires a
separate dual-approved override record with scope, expiry, rationale, and
auditor-visible evidence. Reactivating enforce after rollback MUST satisfy all
FR-1 preconditions again.

The coordinator MUST implement a circuit breaker that fails closed for affected
covered keys, covered models, or the whole policy when new
`quarantined_compute_drift` or `blocked:reference_fault` transitions exceed the
configured model-level or fleet-level threshold in a rolling window.
Circuit-breaker activation MUST preserve existing `quarantined_compute_drift`
and `blocked:<reason>` states, hold or deny affected covered paid routing and
payable settlement, and treat the trusted reference set as suspect until fresh
reference admission and manual review complete. A policy-mode rollback MUST NOT
make already captured non-payable request-start states payable, and an active
circuit-breaker hold MUST make otherwise captured payable `verified` or `warn`
rows non-payable with `compute_integrity_circuit_breaker_hold`.

Circuit-breaker state MUST be one of:

- `inactive`: no hold applies.
- `active`: affected routing is denied or held and affected settlement is
  non-payable as `compute_integrity_circuit_breaker_hold`.
- `override_routing_only`: dual-approved temporary routing override is active for
  the named scope, but captured rows still settle non-payable as
  `compute_integrity_circuit_breaker_hold` while the breaker hold remains active.
- `cleared`: fresh reference admission, quiet-window, and manual-review clear
  requirements have succeeded and new rows may settle according to their captured
  request-start state.

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
stricter policy value is configured. Override MUST NOT make already captured or
currently held settlement rows payable. Only transition to `cleared` ends the
settlement hold for future rows captured after the clear timestamp.

Manual review MUST define:

- Required evidence bundle and replay/check commands.
- Provider notification and appeal path.
- Operator SLA target.
- Dual approval for clear/block decisions affecting paid routing.
- Reference-fault rollback procedure.
- Audit fields for actor, evidence digests, decision, rationale, and expiry.

### FR-17 Cost, capacity, and funding

Compute-integrity probes are non-billable.

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

Enforce activation MUST demonstrate reference-refresh throughput greater than or
equal to covered-key cardinality divided by the freshness TTL under the
deployment's expected warm-swap churn rate, with an operator-approved
reference-freshness availability SLO.

At the default background budget, a key receives about 1 canary per day. The
spec therefore MUST disclose that default background detection, onboarding, and
clear latency can be about 5 days before retries, outages, or targeted bursts.
Enforce deployment MUST set operator-approved time-to-onboard,
time-to-quarantine, and time-to-clear SLOs and provision background or targeted
burst capacity to meet them.

The initial deployment budget MUST assume either:

- at least two continuously active hosted M4 Pro reference nodes at about
  $698/month for a small covered set, plus additional idle standby and sharding
  capacity when resident-model count or warm-swap latency cannot refresh all
  covered model/hash/tokenizer/sampler-stage keys within the freshness TTL.
  Active references intended to satisfy enforce quorum also need independent
  runtime-build provenance or independent signed golden-fixture validation; or
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
least 30 days of warn-only data, at least 100 eligible canaries, at least 10
distinct stable provider identities when available, and at least one relevant
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

## 7. Acceptance Criteria

Before SPEC-036 can move toward LOCK:

1. A threshold-calibration fixture covers records keyed by `(model_id,
   target_model_hash, tokenizer_identity, sampler_stage, sampling_profile,
   corpus_version, threshold_version)`, baseline p99 fields, minimum
   sample/position counts, false-positive target, threshold-version changes, and
   activation refusal when calibration is missing or underpowered.
2. A reference-event fixture covers trusted reference admission, signed catalog
   hash match, tokenizer identity match, sampler stage, reference-set and
   reference-event digests, source and failure-domain independence,
   runtime-build provenance or signed golden-fixture validation digests,
   freshness TTL, and refresh on reference runtime/build update,
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
   validation, trigger predicate, `none` versus `blocked:manual_review_required`
   action, required audit fields, and clear rule. It also proves under-sampled
   `verified` windows cannot authorize paid routing or payable settlement.
5. A settlement test proves request-start `quarantined_compute_drift` maps to
   `outcome=quarantined` and `reason=compute_drift_quarantined`, never
   `zero_settled`, while the SPEC-015 receipt-verifier result remains
   orthogonal. It also proves an active circuit-breaker hold makes captured
   `verified` or `warn` rows non-payable with
   `compute_integrity_circuit_breaker_hold`.
6. A compatibility test proves no compute-integrity fields are added to
   SPEC-015 v0.4 receipts or `usage`.
7. An onboarding test proves a SPEC-026 v2 provider can complete local
   onboarding; warn-only does not block billable routing; enforce blocks
   billable routing until the compute-integrity onboarding gate passes for the
   covered sampling profile or approved all-profile coverage mode; and
   provider-facing pending/failed/verified status plus retry metadata and
   coverage mode are visible.
8. A warm-swap/re-onboarding test proves compute-integrity state expires across target
   generation boundaries and cannot be laundered by provider-originated ready
   state updates or SPEC-026 re-onboarding with a new `assigned_id`. It also
   proves re-onboarding does not reset partially accumulated quarantine windows,
   abusive-inconclusive counts, or onboarding-failure counts for the same stable
   provider identity.
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
    cannot satisfy enforce quorum, golden-fixture validation may substitute for
    runtime-build provenance only after source and failure-domain independence is
    proven, pass/quarantine verdicts use the agreed envelope across all active
    admissible trusted references, both suppress provider drift counters, and
    both appear in auditor bundles.
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

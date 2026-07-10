# SPEC-030 Compute-Integrity Receipt Companion

**Status:** v0.1-draft
**Date:** 2026-07-10
**Depends on:** SPEC-015 v0.4.2, SPEC-022 v0.1.4, SPEC-026, SPEC-029 v0.1-draft
**Companion research:** `docs/research/compute-integrity-receipt-2026-07.md`

## 1. Purpose

SPEC-030 defines an additive compute-integrity drift gate for MacProvider paid
settlement. It extends the SPEC-022 settlement decision with coordinator-owned
provider/model drift state while preserving the existing SPEC-015 v0.4 receipt
wire shape.

The problem: SPEC-015 v0.4 receipts prove that a provider signed a strict
settlement tuple binding request identity, route snapshot, model id, model hash,
prompt/output hashes, usage, and terminal state. They do not prove that the
provider actually computed the output with the pinned model if the provider can
lie about its local computation and still sign a syntactically valid receipt.

SPEC-030 adds a measurable drift state:

```text
quarantined_compute_drift
```

When the effective compute-integrity policy is in enforce mode, a covered paid
request whose request-start provider/model key is in
`quarantined_compute_drift` MUST NOT create buyer final debit, provider credit,
earnings visibility, settlement-sweep inclusion, or payout readiness.

## 2. Scope

In scope:

- Coordinator-owned compute-integrity canary state keyed by provider, model,
  target model hash, target generation, sampling profile, corpus version, and
  threshold version.
- Provider-vs-reference TV-distance measurement using the SPEC-029
  distribution snapshot primitive.
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
- Designing the probe transport or distribution snapshot mechanism; SPEC-030
  inherits SPEC-029.
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
hash, tokenizer identity, sampling profile, corpus version, threshold version,
reference source, reference result digest, and computed reference distribution
summary.

**Compute-integrity key:** `(provider_id, assigned_id, model_id,
target_model_hash, target_generation, sampling_profile, corpus_version,
threshold_version)`.

**Window key:** The compute-integrity key without `sampling_profile` when policy
requires all profiles to pass, or with `sampling_profile` when a rollout covers
only a named profile set.

**Compute-integrity state:** One of `unknown`, `pending`, `verified`,
`warn`, `quarantined_compute_drift`, `blocked`, or `expired`.

**Drift candidate:** A single canary result whose provider-vs-reference
`tv_lower` exceeds the active quarantine-candidate threshold after required K
retry and validation.

**Warn-only mode:** Policy mode that computes and emits compute-integrity state
but MUST NOT alter buyer debit, provider credit, earnings, payout readiness, or
buyer-facing claims.

**Enforce mode:** Policy mode in which request-start
`quarantined_compute_drift` makes the settlement outcome `quarantined` with
reason `compute_drift_quarantined`.

## 4. Threat Model

SPEC-030 v0.1 is not a cryptographic proof of honest computation. It detects
measurable divergence from an approved reference distribution under
coordinator-issued probes. It is useful against implementation drift, stale or
wrong model artifacts, broken sampler paths, low-effort substitution, and
providers that cannot make their output distribution match the trusted
reference.

SPEC-030 v0.1 does not defeat a malicious provider that can identify overt
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
- Covered `entrypoints`.
- Covered sampling profiles.
- Required reference source mode: `trusted_reference` or `hybrid`.
- `corpus_version`.
- `threshold_version`.
- `window_size_days`, default 7.
- `min_window_canaries`, default 5.
- `quarantine_candidate_count`, default 3.
- `clear_pass_count`, default 5.
- Reference freshness TTL, default 24 hours.

`observe` and `warn_only` MAY compute verdicts and emit audit events, but MUST
NOT change buyer debit, provider credit, earnings, payout readiness, or
buyer-facing verification claims.

`enforce` MUST refuse activation unless:

- SPEC-029 is at least v0.1-draft and the implementation exposes the inherited
  probe primitive.
- All covered models have signed catalog entries.
- At least one trusted reference source is active for every covered model/hash.
- The active threshold version has an approved calibration record.
- Settlement storage can persist request-start compute-integrity state.
- Billing and payout storage already exclude non-`verified` SPEC-022 outcomes.
- Disclosure surfaces can distinguish compute-integrity observe/warn-only from
  enforce.

### FR-2 Receipt compatibility

SPEC-030 MUST NOT add fields to SPEC-015 v0.4 receipts.

SPEC-030 MUST NOT add fields to SPEC-015 v0.4 `usage`.

SPEC-030 MUST NOT require a future `receipt_version` to enter warn-only mode.

Future receipt versions MAY bind a digest of the request-start
compute-integrity state, but that is outside SPEC-030 v0.1.

### FR-3 Settlement outcome mapping

SPEC-030 MUST NOT introduce a fifth top-level SPEC-022 settlement outcome in
v0.1.

When mode is `enforce` and the covered request's request-start
compute-integrity state is `quarantined_compute_drift`, settlement MUST return:

- `outcome = "quarantined"`.
- `receipt_result = "invalid"` or a future internal non-payable result class.
- `reason = "compute_drift_quarantined"`.

`zero_settled` MUST NOT be used for compute-integrity drift because drift is a
trust failure, not a verified non-creditable terminal outcome.

### FR-4 Request-start state capture

For every covered paid request attempt, the coordinator MUST persist the
request-start compute-integrity state alongside the route-time verification
snapshot or in an immutable row linked to that snapshot.

The captured state MUST include:

- `compute_integrity_policy_version`.
- `compute_integrity_policy_mode`.
- `compute_integrity_state`.
- `compute_integrity_window_id`.
- `reference_event_digest`.
- `threshold_version`.
- `corpus_version`.
- `target_generation`.
- `captured_at`.

Settlement MUST read the captured request-start state, not the current
provider state at settlement time.

### FR-5 Reference source

The coordinator MUST maintain trusted reference events for every covered
`(model_id, target_model_hash, sampling_profile, corpus_version,
threshold_version)`.

Trusted reference admission MUST verify:

- The reference runtime is coordinator-controlled.
- The loaded model hash equals the signed catalog hash.
- The tokenizer identity matches the candidate-provider tokenizer identity.
- The reference runtime version and corpus version are recorded.

Hybrid mode SHOULD also collect N-provider consensus telemetry with N >= 3, but
consensus telemetry MUST NOT create automatic quarantine in v0.1 without a fresh
trusted-reference event for the same key.

Reference events MUST refresh at least every 24 hours and immediately after
catalog rotation, reference runtime update, tokenizer identity change, corpus
version change, or threshold version change.

### FR-6 Probe inheritance

Compute-integrity probes MUST inherit the SPEC-029 distribution snapshot
primitive:

- Authenticated provider-control channel.
- Single-use unpredictable nonce.
- Expiry no more than 120 seconds after issuance.
- Request/result digest binding.
- K limited to 64 or 256.
- At most 4 prompts and 8 stochastic measurement positions per result.
- Per-provider concurrent compute-integrity probes limited to 1.
- Provider probe work is non-billable.

The compute-integrity probe profile name is `compute_integrity_probe_v1`.

### FR-7 TV computation

For each measurement position, the coordinator MUST compute provider-vs-reference
TV intervals over shared support:

```text
support_diff = sum(abs(p_provider(token) - p_reference(token)))
tv_lower = 0.5 * (support_diff + abs(provider_tail_mass - reference_tail_mass))
tv_upper = 0.5 * (support_diff + provider_tail_mass + reference_tail_mass)
```

The provider MUST NOT supply the authoritative verdict. The coordinator verdict
MUST be derived from raw compact distributions, tail masses, identity fields,
and the active threshold record.

If either side's tail mass exceeds `0.01` at K=64, or if the result is within
`0.005` of a warning or quarantine threshold, the coordinator MUST retry at
K=256 before assigning `pass`, `warn`, or `quarantine_candidate`.

At K=256, if either tail mass exceeds `0.005`, the result MUST be
`inconclusive:tail_mass_high` and MUST NOT increment drift counters.

### FR-8 Threshold calibration

Thresholds MUST be keyed by `(model_id, target_model_hash, sampling_profile,
corpus_version, threshold_version)`.

The threshold record MUST include:

- `threshold_version`.
- `baseline_median_tv_upper_p99`.
- `baseline_position_tv_upper_p99`.
- `tau_warn_median`.
- `tau_warn_position`.
- `tau_quarantine_median`.
- `tau_quarantine_position`.
- Calibration source and sample count.
- Approval timestamp and approver group.

Initial threshold formulas:

```text
tau_warn_median = max(0.015, baseline_median_tv_upper_p99 + 0.005)
tau_warn_position = max(0.030, baseline_position_tv_upper_p99 + 0.010)
tau_quarantine_median = max(0.060, baseline_median_tv_upper_p99 + 0.050)
tau_quarantine_position = max(0.120, baseline_position_tv_upper_p99 + 0.080)
```

Maintainers MAY approve wider thresholds for specific model/profile keys, but
the approval MUST be recorded with rationale and a new `threshold_version`.

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
- `verified`: latest window satisfies pass rules and freshness TTL.
- `warn`: latest valid result is warning-class.
- `quarantined_compute_drift`: active window met quarantine rule.
- `blocked`: missing reference, missing calibration, repeated abusive
  inconclusive results, or suspected swap laundering blocks covered paid routing
  until manual review or fresh pass sequence.
- `expired`: prior state exceeded freshness TTL or was invalidated by target
  generation, corpus, threshold, tokenizer, or catalog change.

Window quarantine rule:

- The rolling window is 7 days by default.
- At least 5 eligible canaries are required.
- At least 3 of the latest 5 eligible canaries MUST be
  `quarantine_candidate`.
- No intervening `pass` may exist after the first candidate in the counted
  sequence.
- The trusted reference event set MUST be fresh.

Clear rule:

- `quarantined_compute_drift` clears only after 5 consecutive `pass` results
  over at least 24 hours for the same key, or after manual review creates a new
  threshold/corpus/generation key.

### FR-11 Onboarding gate

SPEC-030 MUST NOT block the SPEC-026 local App onboarding flow before identity
registration is complete.

After identity registration and before covered paid routing, each new
provider/model/hash key MUST pass compute-integrity onboarding when policy mode
is `warn_only` or `enforce`.

The default onboarding gate is:

- 5 `pass` canaries.
- At least 30 minutes elapsed between first and final pass.
- Same `model_id`, `target_model_hash`, `target_generation`, corpus version,
  and threshold version.

A first failed onboarding gate SHOULD schedule exponential backoff and a second
attempt. Two failed full gate attempts within 24 hours MUST move the key to
`manual_review`.

### FR-12 Warm-swap and generation handling

Compute-integrity state MUST NOT carry across target-generation boundaries.

On target model hash change, completed warm-swap, same-hash runtime reload,
provider reconnect without continuity proof, tokenizer identity change, corpus
version change, or threshold version change, the affected key MUST move to
`expired` and covered paid routing MUST require fresh compute-integrity state.

If a provider repeatedly changes generation after `warn` or
`quarantine_candidate` results, the coordinator SHOULD move the key to
`blocked:swap_laundering_suspected` until manual review.

### FR-13 Third-party audit

The coordinator SHOULD expose read-only compute-integrity evidence:

- Current provider/model state.
- Window id and threshold version.
- Reference event digest.
- Latest canary event digests.
- Redacted TV interval summaries.
- State-transition audit log.

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
- Settlement quarantine caused by `compute_drift_quarantined`.

Audit rows MUST include enough identifiers to join reference event, provider
probe, request-start snapshot, and settlement row without exposing raw prompts
or buyer output beyond existing retention rules.

### FR-15 Cost and funding

Compute-integrity probes are non-billable.

V0.1 probe/reference costs MUST be operator/network funded. They MUST NOT be
passed through to buyers as usage and MUST NOT appear in SPEC-015 v0.4 `usage`.

The default capacity budget for 100 providers x 10 models is 1,000
provider/model canaries per day. At 4 prompts x 8 positions x 512
prompt-token-equivalent per position, that is 16.384M reference
token-equivalent forward-pass units per day.

The initial deployment budget MUST assume either:

- one hosted M4 Pro reference node at about $349/month, or
- two hosted M4 Pro reference nodes at about $698/month for active/standby or
  model-shard capacity.

## 6. Migration

1. **Draft:** Land SPEC-030 and research memo. No code or existing spec edits.
2. **Observe:** Implement reference and canary telemetry with no money effect.
3. **Warn-only:** Require new provider/model keys to pass onboarding
   compute-integrity canaries before covered paid routing, but do not quarantine
   historical providers for settlement.
4. **Enforce:** Capture request-start compute-integrity state and map
   `quarantined_compute_drift` to SPEC-022 `quarantined` with reason
   `compute_drift_quarantined`.

Before enforce activation, the fleet MUST complete at least 30 days of
warn-only data, at least 10,000 eligible canaries, at least 100 distinct
provider/model/hash keys, and at least three reference refresh or catalog/model
rotation events.

Existing providers are not retroactively quarantined when enforce mode activates.
Rows started before enforce activation settle under their request-start policy
mode.

## 7. Acceptance Criteria

Before SPEC-030 can move toward LOCK:

1. A threshold-calibration fixture covers per-model/per-profile threshold
   records, baseline p99 fields, threshold-version changes, and activation
   refusal when calibration is missing.
2. A reference-event fixture covers trusted reference admission, signed catalog
   hash match, tokenizer identity match, reference digest, freshness TTL, and
   refresh on corpus/threshold/catalog change.
3. A TV computation test covers provider-vs-reference shared support, tail-mass
   lower/upper bounds, K=64 to K=256 retry, high-tail inconclusive, and
   coordinator-owned verdict computation.
4. A window-state test covers 3 of latest 5 quarantine candidates, intervening
   pass reset, 5-pass clear, expired target generation, and manual review clear.
5. A settlement test proves request-start `quarantined_compute_drift` maps to
   `outcome=quarantined` and `reason=compute_drift_quarantined`, never
   `zero_settled`.
6. A compatibility test proves no compute-integrity fields are added to
   SPEC-015 v0.4 receipts or `usage`.
7. An onboarding test proves a SPEC-026 v2 provider can complete local
   onboarding while billable routing remains blocked until the
   compute-integrity onboarding gate passes.
8. A warm-swap test proves compute-integrity state expires across target
   generation boundaries and cannot be laundered by provider-originated ready
   state updates.
9. An audit/export test proves reference events, probe digests, state
   transitions, and settlement quarantine rows are linkable by digest/id without
   exposing raw buyer prompts or outputs.
10. Enforce activation tests prove startup or activation refuses when trusted
    reference, calibration, settlement capture, disclosure, or storage
    preconditions are missing.

## 8. Open Questions

1. Should v0.1 enforce allow trusted-reference-only mode, or should hybrid mode
   be mandatory for all enforce deployments?
2. Are the initial fixed threshold floors (`0.015/0.030/0.060/0.120`) acceptable
   for the first warn-only calibration period?
3. Should the new-provider gate require 5 passes over 30 minutes, or a longer
   24-hour window before paid routing for arbitrary providers?
4. Should consensus telemetry be compensated with provider credits, MALIBU
   rewards, or no direct reward in v0.1?
5. What public disclosure wording is allowed before covert canaries exist?

## 9. Non-Goals

- Proving hardware integrity.
- Proving runtime binary integrity.
- Proving malicious-provider honesty under overt probes.
- Adding buyer-facing canary issuance.
- Changing buyer API request or response schema.
- Changing SPEC-015 v0.4 receipt shape.
- Changing SPEC-022 outcome enum in v0.1.

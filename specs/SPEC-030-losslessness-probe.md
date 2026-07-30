# SPEC-030 — Losslessness Probe

**Status:** v0.1-draft
**Date:** 2026-07-09
**Depends on:** SPEC-015 v0.4.2, SPEC-022, SPEC-028
**Companion research:** `docs/research/losslessness-probe-2026-07.md`

**Numbering note:** Promoted to canonical **SPEC-030** (2026-07-10, corpus-hygiene
pass; moved from `specs/design/spec-029/`) to resolve a number collision with
`SPEC-029-sweep-workload-class-stratification.md`. The on-wire protocol constant
remains `losslessness_probe_v1` and the JCS fixtures remain under
`phase4-coordinator/test/jcs_fixtures/spec029/`; those code identifiers are
intentionally NOT renamed here — renaming a shipped wire constant is a
back-compat-bearing code change, out of scope for this doc relocation.

## 1. Purpose

SPEC-030 defines an overt, coordinator-issued probe that measures whether a provider's speculative decoding path preserves the target model's next-token distribution under selected stochastic sampling profiles.

The v0.1 probe is cooperative implementation-health evidence. It can gate stochastic speculative-decoding eligibility for the exact provider/model/draft/profile key under test, but it does not prove malicious-provider honesty, compute integrity, or model-weight integrity. Stronger claims require a later covert or independently verifiable probe spec.

The probe is not a buyer API feature, not a settlement receipt field, and not a billable usage dimension.

## 2. Scope

In scope:

- A coordinator-owned `losslessness_probe_v1` profile under the provider canary subsystem.
- A v0.1 WS provider-control request/result protocol.
- Provider-side measurement of plain target and speculative target next-token distributions at a normative sampler hook.
- Coordinator-side distribution validation, TV interval computation, verdict assignment, eligibility state, and operator dashboard state.
- Probe-local target and draft artifact identity binding.
- Warm-swap handling for target model and draft model changes.
- Key-scoped stochastic speculative-decoding disablement after repeated confirmed failures or repeated abusive inconclusive results.

Out of scope:

- Any change to SPEC-015 v0.4 settlement receipt tuples or `usage` fields.
- Any change to SPEC-022 settlement semantics.
- Any buyer-visible `/v1/chat/completions` request or response field.
- Covert canaries or indistinguishable buyer-like probes.
- Compute-integrity attestation for model weights, runtime binaries, or hardware.
- General provider-readiness sanctions from losslessness results alone.
- Authorizing stochastic speculative decoding without the separate SPEC-028 rollout decision that consumes this probe state.

## 3. Definitions

**Plain path:** Target-model decoding without draft-model speculation.

**Spec path:** Target-model decoding with a configured draft model and target verification, using the same production sampler transforms and speculative accept/reject logic that stochastic speculative decoding would use.

**Sampling profile:** The sampler parameters under test, at minimum `temperature` and `top_p`.

**Measurement position:** A coordinator-selected decode position in a versioned synthetic prompt corpus. The provider does not choose positions.

**Distribution capture point:** The categorical distribution over the next emitted token after production logit processors, temperature, top-p/top-k/min-p filters enabled by the sampling profile, and speculative accept/reject logic. The returned probabilities are full-distribution probability masses, not top-K-renormalized values.

**Shared support:** The ordered union of the plain path's top-K token ids and the spec path's top-K token ids for one measurement position. Both paths report probabilities for every token in this support. Tail mass is the probability mass outside the shared support.

**Tail mass:** The full-distribution probability mass outside the reported shared support.

**TV lower bound:** The minimum total-variation distance consistent with reported shared-support probabilities and aggregate tail masses outside that shared support.

**TV upper bound:** The maximum total-variation distance consistent with reported shared-support probabilities and aggregate tail masses outside that shared support.

**Draft artifact binding:** A probe-local immutable draft identity from the SPEC-030 draft admission record. It includes `draft_model_id`, `draft_artifact_sha256`, `tokenizer_identity`, and `compatibility_check_digest`. It is not added to SPEC-015 receipts or provider heartbeat.

**Profile key:** `(provider_id, assigned_id, model_id, target_model_hash, target_generation, draft_model_id, draft_artifact_binding, draft_generation, sampling_profile, corpus_version, threshold_version)`.

**Grid key:** The profile key without `sampling_profile`. It represents the full required stochastic profile grid plus greedy control for one provider/model/draft/corpus/threshold identity.

**Target generation:** A coordinator-local monotonic integer for `(provider_id, assigned_id, model_id)` that identifies a continuous target-model runtime snapshot. It starts at `1` for the first ready target snapshot observed by the coordinator and increments on target model hash change, completed target warm-swap, target runtime reload, provider reconnect where continuity cannot be proven, or any same-hash target reload reported by the provider.

**Probe request digest:** RFC8785/JCS SHA-256 over the inner coordinator probe request payload, excluding `probe_request_digest` and any outer transport envelope.

**Probe result digest:** RFC8785/JCS SHA-256 over the inner provider probe result payload, excluding `probe_result_digest` and any outer transport envelope.

## 4. Threat Model

V0.1 probes are overt. A provider can know that it is handling `losslessness_probe_v1`.

Therefore SPEC-030 MUST NOT be used to claim that a malicious provider honestly ran the requested model or honestly reported distributions. V0.1 detects cooperative implementation bugs, sampler drift, stale artifacts, and operational regressions. A provider that fabricates matching plain/spec shared-support distributions can defeat the v0.1 proof surface.

The coordinator MUST present v0.1 results as self-attested implementation-health evidence. A fresh `pass_fresh` MAY allow stochastic speculative decoding only for the exact profile key after a separate rollout decision. It MUST NOT improve settlement trust, model authenticity trust, payout trust, or general provider readiness.

The approval owner for v0.1 corpus, threshold, calibration, retention, and rollout-consumer decisions is the **MacProvider SPEC Maintainers** group: repository maintainers responsible for SPEC-028, SPEC-030, and coordinator/provider release gates. Approval MUST be recorded in the PR or decision log that changes the relevant corpus, threshold, calibration, retention, or rollout rule.

## 5. Normative Requirements

### FR-1 Probe profile

The coordinator MUST define a distinct `losslessness_probe_v1` profile. It MUST NOT reuse nonce echo canary semantics for losslessness verdicts.

The coordinator MAY reuse the existing canary scheduler, jitter, and persistence infrastructure, but losslessness state MUST be stored separately from echo-canary pass/fail state.

### FR-2 Draft admission record

Before the coordinator can issue a losslessness probe for a draft model, it MUST have a coordinator-local `draft_admission_v1` record obtained through the authenticated provider-control channel.

`draft_admission_v1` MUST include:

- `provider_id`.
- `assigned_id`.
- `model_id`.
- `target_model_hash`.
- `target_generation`.
- `draft_model_id`.
- `draft_artifact_sha256`.
- `tokenizer_identity`.
- `compatibility_check_digest`.
- `draft_generation`.
- `created_at`.
- `expires_at`.

`compatibility_check_digest` MUST cover the provider's target/draft tokenizer equality check, draft-load compatibility check, and sampler-hook availability check. The coordinator MUST treat the record as provider self-attestation, not as model authenticity proof.

`draft_generation` MUST increment whenever the provider reloads the draft artifact, changes tokenizer identity, changes compatibility check output, or restarts without proving continuity. If the coordinator lacks a current `draft_admission_v1` record, probe issuance MUST be blocked with `inconclusive:draft_identity_unbound`.

This record is a provider-control/admission artifact only. It MUST NOT be added to SPEC-015 receipts, buyer responses, or provider heartbeat.

The coordinator owns `target_generation`. Probe requests MUST carry the coordinator-issued expected `target_generation`, and providers MUST echo the actual target generation observed at each measured position. Results MUST NOT authorize stochastic speculative decoding across a target-generation boundary, including same-hash reloads and reconnects where runtime continuity cannot be proven.

### FR-3 Transport, auth, and load bounds

V0.1 probes MUST use the authenticated provider WS control channel. HTTP provider-control fallback is out of scope for v0.1.

The coordinator MUST enforce:

- Coordinator-origin authentication using the existing provider-control session binding.
- A single-use unpredictable `probe_nonce` of at least 128 bits.
- `expires_at` no more than 120 seconds after issuance.
- Duplicate `probe_id`, duplicate nonce, or duplicate request digest rejection.
- Provider-side result binding to `probe_request_digest`.
- `K` limited to `64` or `256`.
- At most 4 prompts and 8 stochastic measurement positions per probe result.
- Per-provider concurrent losslessness probes limited to 1.
- A 60-second provider execution timeout.
- A default 60-minute cadence per provider/model/draft key, rotating one stochastic profile per slot.
- Full default stochastic grid coverage within 24 hours for every key that remains eligible and ready.
- Exponential backoff for repeated retryable inconclusive results, capped at 6 hours.
- Audit logging of request digest, result digest, auth principal, issuance time, result time, and final reason code.

Provider work for probes is non-billable and MUST NOT emit SPEC-015 settlement receipts.

### FR-4 Probe identity and replay binding

The wire protocol uses an outer envelope plus an inner JCS payload carried in a required `payload` field. The request digest is computed over RFC8785/JCS canonical JSON of the request `payload` before `probe_request_digest` is attached to the outer envelope. The result digest is computed over RFC8785/JCS canonical JSON of the result `payload` before `probe_result_digest` is attached to the outer envelope.

For cleartext provider-control sessions, the WS frame is the outer envelope below. For encrypted Tier-2 provider-control sessions, SPEC-030 MUST use a dedicated provider-control carrier, not the existing `inference_request` carrier:

- Request visible frame: `type = "losslessness_probe_v1.encrypted_request"`, `request_id = probe_id`, `stream = false`, `encrypted = true`, and `enc`.
- Request AAD: visible frame type, direction `c2p`, `request_id`, `stream = false`, `provider_id`, `assigned_id`, and sequence number.
- Request plaintext envelope: `type = "losslessness_probe_v1.request_plaintext"` and `payload` equal to the cleartext request outer envelope.
- Result visible frame: `type = "losslessness_probe_v1.encrypted_result"`, `request_id = probe_id`, `stream = false`, `encrypted = true`, and `enc`.
- Result AAD: visible frame type, direction `p2c`, `request_id`, `stream = false`, `provider_id`, `assigned_id`, and sequence number.
- Result plaintext envelope: `type = "losslessness_probe_v1.result_plaintext"` and `payload` equal to the cleartext result outer envelope.

The digest inputs remain the inner request/result payloads inside the cleartext outer envelope. Tier-2 encryption authenticates the carrier and plaintext envelope; it does not change the digest payload or tunnel probes through buyer inference frames.

Each request outer envelope MUST use the existing provider WS `type` discriminator and include:

- `type = "losslessness_probe_v1.request"`.
- `probe_id`.
- `probe_request_digest`.
- `payload`.

Each inner request payload MUST include:

- `probe_version = "losslessness_probe_v1"`.
- `probe_id`.
- `probe_nonce`.
- `expires_at`.
- `model_id`.
- Expected `target_model_hash`.
- Expected `target_generation`.
- `draft_model_id`.
- Expected `draft_artifact_binding`.
- Expected `draft_generation`.
- Expected `tokenizer_identity`.
- Sampling profile.
- `corpus_version`.
- `threshold_version`.
- Synthetic prompt payloads or allowlisted corpus references.
- Coordinator-selected measurement positions.
- Requested `K`.
- `support_selection = "support_selection_v1"`.
- Request bounds: max prompts, max positions, timeout, and expiry.

Each result outer envelope MUST use the existing provider WS `type` discriminator and include:

- `type = "losslessness_probe_v1.result"`.
- `probe_id`.
- `probe_request_digest`.
- `probe_result_digest`.
- `payload`.

Each inner result payload MUST include:

- `probe_id`.
- `probe_nonce`.
- `probe_request_digest`.
- `result_kind = "measurement"` or `result_kind = "provider_inconclusive"`.

For `result_kind = "measurement"`, the inner result payload MUST include:

- Actual `target_model_hash` and `target_generation` for every measured position.
- Actual `draft_artifact_binding` and `draft_generation` for every measured position.
- Actual `tokenizer_identity`.
- Returned distributions, support-selection metadata, and result metadata for every requested position.

For `result_kind = "provider_inconclusive"`, the inner result payload MUST include:

- `provider_reason_code`, limited to `inconclusive:model_swap`, `inconclusive:unsupported_sampler`, `inconclusive:draft_unavailable`, `inconclusive:position_mismatch`, `inconclusive:missing_distribution`, or `inconclusive:timeout`.
- The actual target and draft identities known at failure time, or null with an explanatory `identity_unavailable_reason`.
- No authoritative distributions. The coordinator MUST NOT compute TV or pass/warn/quarantine from this variant.

The coordinator MUST mark the result `inconclusive:model_swap` when the provider explicitly reports that target or draft generation changed while the probe was running. The coordinator MUST mark the result `inconclusive:identity_mismatch` when actual target or draft identity differs from expected identity without a declared in-flight swap, when measured positions mix identities, or when draft identity is unavailable.

### FR-5 Sampling profiles

The v0.1 default stochastic grid MUST include:

- `temperature=0.2`, `top_p=1.0`.
- `temperature=0.5`, `top_p=1.0`.
- `temperature=0.7`, `top_p=1.0`.
- `temperature=1.0`, `top_p=1.0`.

The coordinator MUST also run a `temperature=0.0`, `top_p=1.0` greedy control at least once per full-grid coverage window. The greedy control verdict is token-id equality for every requested position, with the same identity and replay checks as stochastic probes.

Verdicts MUST be keyed by exact sampling profile. The coordinator MUST NOT aggregate different temperatures into one sanctioning or eligibility verdict.

### FR-6 Prompt corpus and position selection

The v0.1 corpus MUST be coordinator-owned, synthetic, and versioned. It MUST NOT contain buyer-origin prompts, buyer outputs, secrets, credentials, private code, or production conversation material.

The corpus owner role is the SPEC-028/SPEC-030 maintainer group. Any corpus or threshold change MUST create a new `corpus_version` or `threshold_version`, and existing `pass_fresh` state for affected keys MUST become `expired`.

The coordinator MUST send exact prompts and exact measurement-position indexes. The provider MUST measure every requested position without substitution. Dropped, substituted, or extra positions MUST produce `inconclusive:position_mismatch`.

The versioned corpus metadata MUST include the offline position-selection record:

- Prompt id.
- Position index.
- Sampling profile.
- Token-prefix digest.
- Baseline entropy.
- Entropy profile key.
- Offline per-token plain probabilities sufficient to compute expected tail mass for any returned `support_token_ids` union at `K=64` and `K=256`.
- Whether the position is `high_entropy`.

The offline position-selection record is keyed by `(prompt_id, position_index, sampling_profile, corpus_version)`. Baseline entropy is Shannon entropy of the full next-token distribution under the plain path after the exact sampling profile transforms, normalized by `log(vocab_size)`. A position is `high_entropy` for that sampling profile when normalized entropy is at least `0.35`. The offline per-token plain probabilities are coordinator-owned validation aids derived from the same full-distribution corpus build. They MUST be sufficient for the coordinator to compute `expected_plain_tail_after_returned_union = 1 - sum(offline_plain_p[token] for token in support_token_ids)` for any valid returned shared support; they are not provider-provided verdicts. Each stochastic probe MUST include at least 8 measured positions, and at least 4 MUST be `high_entropy` for the exact sampling profile under test.

### FR-7 Compact distribution output

For every measured stochastic position, the provider MUST construct support with `support_selection_v1`:

1. Compute the plain path's full next-token distribution at the normative capture point.
2. Compute the spec path's full next-token distribution at the normative capture point.
3. Select `plain_top_k_token_ids`: the K highest-probability token ids in the plain distribution, descending by probability with ascending token id as tie-breaker.
4. Select `spec_top_k_token_ids`: the K highest-probability token ids in the spec distribution, using the same ordering.
5. Compute `support_token_ids`: the numeric-ascending union of `plain_top_k_token_ids` and `spec_top_k_token_ids`.
6. Report full-distribution probabilities for every `support_token_ids` entry in both paths.
7. Report tail mass as `1 - sum(probability over support_token_ids)` for each path.

`K` is the per-path top-K count. `support_token_ids` length MUST be at least `K` and at most `2K`, unless vocabulary size is smaller.

For each measured stochastic position, the provider MUST return:

- `position_index`.
- `context_hash` over the exact teacher-forced token prefix.
- `support_selection = "support_selection_v1"`.
- `plain_top_k_token_ids`.
- `spec_top_k_token_ids`.
- `support_token_ids`.
- `plain_support`: full-distribution probabilities for every token in `support_token_ids` for the plain path.
- `plain_tail_mass`.
- `spec_support`: full-distribution probabilities for every token in `support_token_ids` for the spec path.
- `spec_tail_mass`.
- `target_model_hash`, `target_generation`.
- `draft_artifact_binding`, `draft_generation`.
- `tokenizer_identity`.
- `normalization_basis = "full_distribution"`.
- `sampler_stage = "post_processors_post_sampling_profile_next_emitted_token"`.
- Optional trace counters: drafted tokens, accepted tokens, rejected tokens, and fallback target tokens for the position.

The provider MAY return a plain/plain baseline distribution for calibration. The coordinator MUST NOT require sampled-token histograms for the normative v0.1 verdict.

### FR-8 Distribution validation

Before computing a verdict, the coordinator MUST validate every returned distribution:

- Probabilities and tail masses are finite numbers in `[0,1]`.
- Token ids are non-negative integers valid for the tokenizer/vocabulary bound to `target_model_hash`.
- `support_selection` equals `support_selection_v1`.
- `normalization_basis` equals `full_distribution`.
- `sampler_stage` equals `post_processors_post_sampling_profile_next_emitted_token`.
- `plain_top_k_token_ids` and `spec_top_k_token_ids` have no duplicates, are length K unless vocabulary size is smaller, and are sorted by probability descending with ascending token id ties.
- `support_token_ids` equals the numeric-ascending union of `plain_top_k_token_ids` and `spec_top_k_token_ids`.
- `plain_support` and `spec_support` have exactly one finite probability for every token in `support_token_ids`.
- `abs(sum(plain_support.p) + plain_tail_mass - 1.0) <= 1e-5`.
- `abs(sum(spec_support.p) + spec_tail_mass - 1.0) <= 1e-5`.
- `support_token_ids` length is at least K and at most `2K`, unless vocabulary size is smaller.
- For high-entropy v0.1 `top_p=1.0` positions with `support_token_ids.length < vocab_size`, the returned `plain_tail_mass` MUST be at least `expected_plain_tail_after_returned_union - 1e-5`, computed from the coordinator-owned offline plain probabilities over the actual returned `support_token_ids` union. Lower plain tail values MUST be rejected as malformed because they are inconsistent with the offline full-distribution baseline and are consistent with top-K-renormalized evidence. This floor is not applied to `spec_tail_mass`, and low-entropy positions are not rejected on tail size alone.
- The returned `tokenizer_identity` equals the expected tokenizer identity from `draft_admission_v1`.
- `context_hash` matches the coordinator's expected teacher-forced token prefix.

Any validation failure MUST produce `inconclusive:malformed_distribution` and MUST increment the abusive-inconclusive counter defined in FR-14.

### FR-9 Coordinator TV interval computation

The coordinator MUST compute the canonical verdict from provider-returned compact distributions. Provider-returned scalar verdicts MAY be logged but MUST NOT be authoritative.

For any non-empty ordered numeric set, the canonical median is the lower middle value after ascending sort: index `(n - 1) / 2` using integer division. This deliberately avoids averaging middle values, so boundary decisions are identical across integer, decimal, and binary floating-point implementations.

For stochastic positions, the coordinator MUST compute:

```text
support_diff = sum_{token in support_token_ids} |p_plain(token) - p_spec(token)|
tv_lower = 0.5 * (support_diff + |plain_tail_mass - spec_tail_mass|)
tv_upper = 0.5 * (support_diff + plain_tail_mass + spec_tail_mass)
```

Because both paths report probabilities for the same shared support and both tail masses are outside that support, `tv_lower` is the minimum TV consistent with the compact evidence and `tv_upper` is the conservative TV upper bound. A pass decision MUST use `tv_upper`. A quarantine decision MUST use `tv_lower`. Values between those decisions require retry or inconclusive handling.

### FR-10 K and tail handling

The default requested K MUST be `64`.

If either side's tail mass exceeds `0.01`, if `tv_upper` is at or above a warning threshold, or if `tv_lower` is within `0.005` of a quarantine threshold, the coordinator MUST retry the probe at `K=256` before assigning `pass`, `warn`, or `quarantine_candidate`.

If the required `K=256` retry cannot complete, the result MUST be `inconclusive:k_retry_failed`. It MUST NOT increment the confirmed-failure counter, but it MUST follow the abusive-inconclusive handling in FR-14.

At `K=256`, if either side's tail mass exceeds `0.005`, the position MUST be marked `inconclusive:tail_mass_high`. High tail mass MUST NOT by itself increment the abusive-inconclusive counter or the confirmed-failure counter.

### FR-11 Calibration

Before any `quarantine_candidate` can count toward disablement, the coordinator MUST have an approved calibration baseline for `(target_model_hash, draft_artifact_binding, sampling_profile, corpus_version, threshold_version)`.

The calibration record MUST include:

- `calibration_id`.
- `target_model_hash`.
- `draft_artifact_binding`.
- `sampling_profile`.
- `corpus_version`.
- `threshold_version`.
- Baseline source: provider plain/plain hook or maintainer-approved local reference.
- Baseline sample count or measurement count.
- Baseline median and max `tv_lower`.
- Baseline median and max `tv_upper`.
- Approval timestamp and approver group.

Calibration is acceptable only when baseline max `tv_upper <= 0.01` and baseline median `tv_upper <= 0.005`, or when maintainers explicitly approve a wider threshold version. The quarantine threshold for the active threshold version MUST exceed baseline max `tv_upper` by at least `0.05`.

If calibration is missing or fails the acceptance rule, a result that would otherwise be `quarantine_candidate` MUST become `blocked:calibration_missing` and MUST NOT increment the confirmed-failure counter.

### FR-12 Verdict categories and reason codes

The coordinator MUST assign one status and one reason code:

- `pass`.
- `warn`.
- `quarantine_candidate`.
- `inconclusive`.
- `blocked`.

Required reason-code table:

`operator_action` is a closed enum. Allowed values are: `none`, `inspect_threshold_trend`, `inspect_provider_draft`, `approve_calibration_baseline`, `disable_spec_decode_key`, `retry_probe_with_backoff`, `inspect_provider_load`, `disable_sampler_profile`, `wait_ready_snapshot_reprobe`, `reload_or_disable_draft`, `create_draft_admission_record`, `inspect_generation_mismatch`, `inspect_control_channel_replay`, `fix_provider_serializer`, `fix_position_handling`, `fix_result_completeness`, `request_spec028_rollout_approval`, and `disable_stochastic_spec_decode`. Telemetry and dashboards MAY include a separate `operator_action_label` for runbook prose, but filtering, alerting, and tests MUST use the enum.

| Reason code | Status | Retryable | Counter effect | Next state | Operator action |
|---|---|---:|---|---|---|
| `pass:fresh` | `pass` | no | clear consecutive quarantine only | `pass_fresh` | none |
| `warn:threshold_exceeded` | `warn` | yes | none | `warn` | `inspect_threshold_trend` |
| `quarantine_candidate:tv_lower_exceeded` | `quarantine_candidate` | yes | increment confirmed-failure counter | `warn` until second consecutive candidate, then `disabled` | `inspect_provider_draft` |
| `blocked:calibration_missing` | `blocked` | no | none | `blocked` | `approve_calibration_baseline` |
| `blocked:greedy_control_failed` | `blocked` | no | increment greedy-control failure counter | `blocked` | `disable_spec_decode_key` |
| `inconclusive:tail_mass_high` | `inconclusive` | yes | no abuse unless repeated >3 in 24h | `inconclusive_retryable` | `retry_probe_with_backoff` |
| `inconclusive:k_retry_failed` | `inconclusive` | yes | abusive event | `inconclusive_retryable` or `blocked` at threshold | `inspect_provider_load` |
| `inconclusive:timeout` | `inconclusive` | yes | abusive event | `inconclusive_retryable` or `blocked` at threshold | `inspect_provider_load` |
| `inconclusive:unsupported_sampler` | `inconclusive` | no | abusive event | `blocked` | `disable_sampler_profile` |
| `inconclusive:model_swap` | `inconclusive` | yes | no abuse unless repeated >3 in 24h | `expired` | `wait_ready_snapshot_reprobe` |
| `inconclusive:draft_unavailable` | `inconclusive` | yes | abusive event | `inconclusive_retryable` or `blocked` at threshold | `reload_or_disable_draft` |
| `inconclusive:draft_identity_unbound` | `inconclusive` | no | abusive event | `blocked` | `create_draft_admission_record` |
| `inconclusive:identity_mismatch` | `inconclusive` | no | abusive event | `blocked` | `inspect_generation_mismatch` |
| `inconclusive:replay_or_expired` | `inconclusive` | no | abusive event | `blocked` | `inspect_control_channel_replay` |
| `inconclusive:malformed_distribution` | `inconclusive` | no | abusive event | `blocked` | `fix_provider_serializer` |
| `inconclusive:position_mismatch` | `inconclusive` | no | abusive event | `blocked` | `fix_position_handling` |
| `inconclusive:missing_distribution` | `inconclusive` | no | abusive event | `blocked` | `fix_result_completeness` |

`blocked:greedy_control_failed` MUST be emitted when the greedy control token-id equality check fails for any requested position.

The consecutive quarantine-candidate counter is keyed by profile key:

- `quarantine_candidate:tv_lower_exceeded` increments the counter by one.
- Any `pass` clears the counter.
- `warn` preserves the counter but does not increment it.
- `inconclusive` preserves the counter but does not increment it, while abusive inconclusive handling remains governed by FR-14.
- `blocked`, `disabled`, `expired`, target-generation change, draft-generation change, corpus-version change, or threshold-version change clears the counter for the old key because later results apply to a different or no-longer-eligible key.

Therefore `Q,Q` disables the profile key, `Q,W,Q` disables the profile key, `Q,inconclusive,Q` disables the profile key, and `Q,pass,Q` leaves the counter at one.

Recommended initial thresholds:

- `pass` requires all requested stochastic positions valid, all expected identities stable, no replay/expiry issue, no pending K retry, final per-position tail mass within the accepted ceiling, `tv_upper <= 0.02` for every position, and median `tv_upper <= 0.01`.
- `warn:threshold_exceeded` when any position has `tv_upper > 0.02` or median `tv_upper > 0.01`, unless quarantine criteria are met.
- `quarantine_candidate:tv_lower_exceeded` when any position has `tv_lower > 0.10` or median `tv_lower > 0.05`, after required K retry and with accepted calibration present.
- `inconclusive` for any required validation, identity, transport, tail, sampler, timeout, or position failure.

Thresholds are draft defaults. Locking this spec requires maintainer approval for the final threshold table and prompt corpus.

### FR-13 Eligibility and failure state machine

The coordinator MUST maintain `losslessness_profile_state` separately from echo-canary state and keyed by the profile key.

Allowed profile states:

- `unknown`: no valid result for the profile key.
- `pending`: probe issued and result not finalized.
- `pass_fresh`: latest result for this profile key passes and has not expired.
- `warn`: latest valid result is warning-class.
- `inconclusive_retryable`: latest inconclusive is retryable and below abuse threshold.
- `blocked`: repeated abusive inconclusive results, missing sampler support, missing calibration, or missing draft identity prevent stochastic spec decode for the profile key.
- `disabled`: repeated confirmed quarantine candidates disable stochastic spec decode for the profile key.
- `expired`: prior state exceeded freshness TTL or was invalidated by corpus/threshold/target/draft generation change.

Profile freshness TTL is 24 hours after the latest pass for the same profile key. `warn`, `inconclusive_retryable`, `blocked`, `disabled`, `unknown`, and `expired` MUST deny stochastic speculative-decoding eligibility for the profile key.

The coordinator MUST also maintain `losslessness_grid_state` keyed by the grid key. It is `all_profiles_fresh` only when every required stochastic sampling profile and the greedy control have `pass_fresh` profile state for the same grid key. Any missing, stale, warning, blocked, disabled, inconclusive, or expired profile state MUST make the grid state `not_ready`.

SPEC-030 only produces evidence for a SPEC-028 rollout decision. The rollout consumer rule is:

1. `all_profiles_fresh` is required before stochastic speculative decoding can be enabled for a grid key.
2. A SPEC-028 rollout PR or decision-log entry approved by MacProvider SPEC Maintainers MUST explicitly name the grid key, feature flag, allowed sampling profiles, and rollback condition.
3. Until that SPEC-028 approval exists, the dashboard operator action for `all_profiles_fresh` is `request_spec028_rollout_approval`; stochastic speculative decoding remains disabled.
4. If any profile state leaves `pass_fresh`, the grid state becomes `not_ready` and the SPEC-028 rollout consumer MUST disable stochastic speculative decoding for the affected grid key.

### FR-14 Disablement and abusive-inconclusive handling

A single `quarantine_candidate` MUST NOT degrade or disable general provider readiness.

Two consecutive `quarantine_candidate` results for the same profile key MUST transition that key to `disabled`. This disablement applies only to stochastic speculative decoding for that key. Echo-canary failure counters and non-speculative provider availability MUST remain unchanged.

Repeated abusive inconclusive results MUST fail closed for stochastic speculative decoding:

- `k_retry_failed`, `timeout`, `unsupported_sampler`, `draft_unavailable`, `draft_identity_unbound`, `identity_mismatch`, `replay_or_expired`, `malformed_distribution`, `position_mismatch`, and `missing_distribution` increment an abusive-inconclusive event log.
- `tail_mass_high` and `model_swap` do not increment the abusive-inconclusive counter unless they repeat more than 3 times in a 24-hour window for the same key.
- Three abusive inconclusive results in a 24-hour window MUST transition the key to `blocked`.

`blocked:greedy_control_failed` is an immediate deterministic-control block and increments only the greedy-control failure counter. It MUST NOT increment or be displayed inside the abusive-inconclusive count.

`pass` clears only the consecutive quarantine-candidate counter for the key. It MUST NOT delete the rolling 24-hour abusive-inconclusive event log. Echo-canary pass/fail state MUST NOT clear losslessness counters.

### FR-15 Telemetry event schema

The coordinator MUST publish probe results as out-of-band telemetry. The v0.1 event type is `losslessness_probe_v1`.

Normal issued-probe events MUST include:

| Field | Type |
|---|---|
| `event_type` | string, exactly `losslessness_probe_v1` |
| `event_subtype` | string, exactly `probe_result` |
| `probe_id` | string |
| `probe_request_digest` | `sha256:<hex>` string |
| `probe_result_digest` | `sha256:<hex>` string or null |
| `provider_id` | string |
| `assigned_id` | string |
| `profile_key` | object containing the profile-key fields |
| `grid_key` | object containing the grid-key fields |
| `model_id` | string |
| `target_model_hash` | string |
| `target_generation` | integer |
| `draft_model_id` | string |
| `draft_artifact_binding` | object |
| `draft_generation` | integer |
| `tokenizer_identity` | string |
| `sampling_profile` | object |
| `corpus_version` | string |
| `threshold_version` | string |
| `result_kind` | string, `measurement`, `provider_inconclusive`, `coordinator_timeout`, or `admission_blocked` |
| `metric_kind` | string, `tv`, `greedy_equality`, or `none` |
| `final_k` | integer or null |
| `position_k` | array of integers or null |
| `status` | string |
| `reason_code` | string |
| `retryable` | boolean |
| `operator_action` | operator-action enum string |
| `operator_action_label` | string or null |
| `median_tv_lower` | number or null |
| `max_tv_lower` | number or null |
| `median_tv_upper` | number or null |
| `max_tv_upper` | number or null |
| `max_tail_mass` | number or null |
| `greedy_positions_matched` | integer or null |
| `greedy_positions_failed` | integer or null |
| `mismatched_position_count` | integer or null |
| `position_count_requested` | integer |
| `position_count_used` | integer |
| `retry_attempts` | integer |
| `measured_at` | RFC3339 UTC timestamp |
| `stale_after` | RFC3339 UTC timestamp |
| `evidence_mode` | string, `inline` or `retained_ref` |
| `evidence_schema_version` | string |
| `evidence_digest` | `sha256:<hex>` string |
| `evidence_ref` | string or null |
| `evidence_retained_until` | RFC3339 UTC timestamp |

For pre-issuance blocked cases, such as missing `draft_admission_v1`, the coordinator MUST emit `event_subtype = "admission_blocked"`. In that event, `probe_request_digest`, `probe_result_digest`, `probe_id`, and result metrics follow the nullability rules below, but `provider_id`, `assigned_id`, `profile_key` or partial profile key, `grid_key` or partial grid key, `status`, `reason_code`, `retryable`, `operator_action`, `measured_at`, and `stale_after` MUST be present.

For stochastic measurement outcomes, `result_kind = "measurement"` and `metric_kind = "tv"`; TV/tail metric fields are required and greedy fields MUST be null. For greedy control outcomes, `metric_kind = "greedy_equality"`; greedy fields are required and TV/tail fields MUST be null. For provider-inconclusive outcomes or coordinator timeout/no-result outcomes, `metric_kind = "none"`; TV/tail and greedy fields MUST be null. `probe_result_digest` is required when a provider result payload exists and MUST be null for coordinator timeout/no-result outcomes.

The event MUST retain either inline compact per-position evidence or a digest plus retained object reference until `evidence_retained_until`.

Grid-level rollout telemetry MUST be emitted whenever `losslessness_grid_state` changes or a SPEC-028 rollout approval reference is added, removed, or superseded. The grid event MUST include:

| Field | Type |
|---|---|
| `event_type` | string, exactly `losslessness_probe_v1` |
| `event_subtype` | string, exactly `grid_state` |
| `grid_key` | object containing the grid-key fields |
| `losslessness_grid_state` | string, `all_profiles_fresh` or `not_ready` |
| `missing_profiles` | array of sampling-profile objects |
| `stale_profiles` | array of sampling-profile objects |
| `blocked_profiles` | array of sampling-profile objects |
| `not_ready_profiles` | array of objects containing `sampling_profile`, `profile_state`, `reason_code`, `stale_after`, and `operator_action` |
| `spec028_rollout_approval_status` | string, `absent`, `approved`, `superseded`, or `revoked` |
| `spec028_rollout_approval_ref` | string or null |
| `feature_flag` | string or null |
| `allowed_sampling_profiles` | array of sampling-profile objects |
| `rollback_condition` | string or null |
| `operator_action` | operator-action enum string |
| `operator_action_label` | string or null |
| `measured_at` | RFC3339 UTC timestamp |
| `stale_after` | RFC3339 UTC timestamp |

### FR-16 Operator dashboard contract

The operator dashboard MUST display a profile matrix by provider, model, target generation, draft artifact binding, draft generation, sampling profile, corpus version, and threshold version.

For each cell it MUST show:

- Eligibility state.
- Latest status and reason code.
- `measured_at` and `stale_after`.
- Consecutive quarantine-candidate count.
- Abusive-inconclusive count.
- Greedy-control failure count.
- Retryable flag.
- Operator action.
- Latest median/max `tv_lower` and `tv_upper`.
- Latest max tail mass.

The dashboard MUST also display a grid-level rollout row keyed by grid key. That row MUST show `losslessness_grid_state`, `not_ready_profiles` with each blocker profile state and reason code, SPEC-028 rollout approval status and reference, feature flag, allowed sampling profiles, rollback condition, and operator action. Its operator action MUST be `request_spec028_rollout_approval` when the grid is `all_profiles_fresh` but no current SPEC-028 approval exists, and `disable_stochastic_spec_decode` when any approved grid later becomes `not_ready`.

Dashboard aggregates MAY summarize provider health, but aggregates MUST NOT collapse sanctioning or eligibility across temperatures, target generations, draft generations, corpus versions, or threshold versions.

### FR-17 Receipt and usage invariants

SPEC-030 MUST NOT add fields to SPEC-015 v0.4 receipts or v0.4 `usage`.

SPEC-030 MUST NOT require a SPEC-022 settlement change.

SPEC-030 MUST NOT alter buyer token accounting, payout accounting, receipt verification, or external verifier behavior.

Future receipt versions MAY bind a digest of recent losslessness probe status, but that is outside v0.1.

### FR-18 Warm-swap handling

If the target model or draft model changes while a probe is running, the result MUST be `inconclusive:model_swap`.

Probe results MUST NOT carry across target or draft generation boundaries. After a new target snapshot becomes ready and draft compatibility is checked, the coordinator SHOULD schedule fresh probes for the affected profile keys.

Draft-load failure after a target swap MUST NOT fail the target-model swap. It MUST leave stochastic speculative decoding disabled for that model/draft key and emit `inconclusive:draft_unavailable` or `inconclusive:draft_identity_unbound`.

### FR-19 Data retention and privacy

Probe prompts and retained evidence MUST be synthetic or explicitly redacted coordinator-owned material. Buyer-origin content is prohibited.

Compact per-position evidence MUST be retained for 30 days by default, encrypted at rest, and accessible only to coordinator operators with audit-log access. Retention longer than 30 days requires maintainer approval and a documented reason.

Logs and dashboard views MUST NOT display raw prompt text by default. They MAY display prompt ids, corpus version, token-prefix digests, context hashes, and compact probability evidence.

### FR-20 No covert canaries

V0.1 probes are overt. The provider MAY know it is handling a losslessness probe.

Covert probes MUST be specified separately because they interact with buyer traffic, billing, receipts, and abuse resistance.

## 6. Non-Goals

- Proving a malicious provider honestly loaded a claimed model.
- Proving hardware, binary, or compute integrity.
- Certifying every possible prompt or sampler configuration.
- Replacing SPEC-028 acceptance-rate telemetry.
- Replacing existing echo canaries.
- Authorizing stochastic speculative decoding without a later rollout decision.
- Degrading general provider readiness from losslessness results alone.

## 7. Acceptance Criteria

Before SPEC-030 can move toward LOCK:

1. A protocol fixture covers the WS request/result JSON schema, required `payload` envelope field, cleartext and Tier-2 encrypted probe carriers, measurement and provider-inconclusive result variants, auth/session binding, nonce, expiry, inner-payload request digest, inner-payload result digest, replay rejection, timeout, and bounded K.
2. A draft-admission fixture covers `draft_admission_v1`, including draft artifact SHA-256, tokenizer identity, compatibility check digest, generation increment, expiry, and the no-heartbeat/no-receipt boundary.
3. A provider design identifies the exact Swift generation/sampler hook that emits full-distribution shared-support probabilities plus tail mass at the normative capture point for plain and spec paths.
4. A test fixture proves that extra losslessness fields are not added to SPEC-015 v0.4 receipts or `usage`.
5. A coordinator unit test covers distribution validation failures: duplicate support token ids, NaN, negative probability, shared-support length mismatch, invalid `normalization_basis`, missing or wrong `sampler_stage`, below-baseline high-entropy tail with partial support, inconsistent tail mass, wrong tokenizer identity, wrong context hash, and wrong K. It also covers a valid case where `support_token_ids.length > K` and `plain_tail_mass` is below the plain top-K-only tail but equals the expected tail outside the returned shared-support union.
6. A coordinator unit test covers `tv_lower` and `tv_upper` over shared support and equal-size disjoint tails outside the shared support.
7. A coordinator test proves missing or invalid `support_selection_v1`, missing top-K lists, and top-K-only submissions that omit full shared-support probabilities are rejected as malformed.
8. A coordinator unit test covers mandatory `K=64` retry to `K=256`, non-sanctioning retry failure, final tail ceilings for pass, and `inconclusive:tail_mass_high`.
9. A coordinator test covers accepted calibration, missing calibration, calibration failing the baseline-noise rule, and quarantine threshold margin over baseline max `tv_upper`.
10. A coordinator state-machine test covers profile-level `pass_fresh`, `warn`, `blocked`, `disabled`, and `expired`.
11. A coordinator state-machine test covers grid-level `all_profiles_fresh` and `not_ready`, including the case where one sampling profile is stale.
12. A coordinator test covers two consecutive `quarantine_candidate` results disabling stochastic spec decode only for the profile key while leaving echo-canary/general readiness unchanged.
13. A coordinator test covers rolling 24-hour abusive inconclusive handling and proves a later `pass` does not erase abusive events inside the window.
14. A coordinator test covers reason-code mapping for retryability, counter effect, next state, closed-enum operator action, and consecutive quarantine transitions for `Q,Q`, `Q,W,Q`, `Q,inconclusive,Q`, and `Q,pass,Q`, including `blocked:greedy_control_failed`.
15. A warm-swap and generation test covers `target_generation` owner/increment rules, same-hash reload, reconnect without continuity proof, `inconclusive:model_swap`, target/draft generation mismatch, draft identity missing, and old results not authorizing a new target or draft generation.
16. A corpus planning test rejects probe plans/results that do not meet exact position, exact-profile entropy, and high-entropy quota requirements.
17. A dashboard snapshot test covers reason codes, retryable flag, closed-enum operator action plus label, profile/grid state, `not_ready_profiles`, counters, `metric_kind`, nullable metrics for non-TV outcomes, and no cross-temperature aggregation for eligibility.
18. A privacy test or static fixture proves buyer-origin prompts are rejected from the corpus and raw prompt text is not displayed by default.
19. MacProvider SPEC Maintainers approve the v0.1 prompt corpus, threshold table, retention TTL, calibration process, and SPEC-028 rollout consumer rule.

## 8. Open Questions

These are not blockers to the v0.1 protocol shape but remain before LOCK:

1. Should the default 30-day evidence retention TTL be shorter for public beta?
2. Should a future SPEC-015 v0.5 bind a recent losslessness probe digest into settlement receipts?

## 9. References

- `docs/research/losslessness-probe-2026-07.md`.
- `specs/SPEC-028-mlx-speculative-decoding.md`.
- `specs/SPEC-015-receipts.md`.
- `specs/SPEC-022-verified-model-settlement.md`.
- Shard `specpipe.py`: <https://raw.githubusercontent.com/leyten/shard/master/phase0/specpipe.py>.
- `mlx-swift-lm` 3.31.4 `Evaluate.swift`: <https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/3.31.4/Libraries/MLXLMCommon/Evaluate.swift>.
- Leviathan, Kalman, and Matias, "Fast Inference from Transformers via Speculative Decoding": <https://arxiv.org/abs/2211.17192>.
- Chen et al., "Accelerating Large Language Model Decoding with Speculative Sampling": <https://arxiv.org/abs/2302.01318>.

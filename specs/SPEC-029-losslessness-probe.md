# SPEC-029 Losslessness Probe

**Status:** v0.1-draft
**Date:** 2026-07-09
**Depends on:** SPEC-015 v0.4.2, SPEC-022, SPEC-028
**Companion research:** `docs/research/losslessness-probe-2026-07.md`

## 1. Purpose

SPEC-029 defines an overt coordinator-issued probe that measures whether speculative decoding preserves the target model's next-token distribution under selected stochastic sampling profiles.

The probe is a governance gate for any future stochastic speculative-decoding rollout. It is not a buyer API feature, not a settlement receipt field, and not a billable usage dimension.

## 2. Scope

In scope:

- A coordinator-owned `losslessness_probe_v1` profile under the existing provider canary subsystem.
- Provider-side measurement of plain target and speculative target next-token distributions.
- Coordinator-side total-variation computation and verdict assignment.
- Out-of-band probe telemetry and operator-visible aggregate status.
- Warm-swap handling for target model and draft model changes.
- Thresholded integration with the existing canary failure counter after repeated confirmed failures.

Out of scope:

- Any change to SPEC-015 v0.4 settlement receipt tuples or `usage` fields.
- Any change to SPEC-022 settlement semantics.
- Any buyer-visible `/v1/chat/completions` request or response field.
- Covert canaries or indistinguishable buyer-like probes.
- Compute-integrity attestation for model weights or executable code.
- Stochastic speculative-decoding product enablement. This spec only defines a probe.

## 3. Definitions

**Plain path:** Target-model decoding without draft-model speculation.

**Spec path:** Target-model decoding with a configured draft model and target verification.

**Sampling profile:** The sampler parameters under test, at minimum `temperature` and `top_p`.

**Measurement position:** A decode position selected from a probe prompt where the provider returns next-token distribution evidence.

**TV distance:** Total-variation distance between two categorical distributions. For reported compact distributions, the coordinator computes `TV_bound` over the union of top-K token ids plus residual tail mass.

**Tail mass:** The probability mass not included in the reported top-K token list.

**Probe key:** `(provider_id, assigned_id, model_id, target_model_hash, draft_model_id, sampling_profile)`.

## 4. Normative Requirements

### FR-1 Probe profile

The coordinator MUST define a distinct `losslessness_probe_v1` profile. It MUST NOT reuse nonce echo canary semantics for losslessness verdicts.

The coordinator MAY implement this profile inside the existing canary scheduler, jitter, and sanction subsystem.

### FR-2 Out-of-band transport

The coordinator MUST issue v0.1 probes through an out-of-band provider-control path, such as a dedicated WS message type. It MUST NOT issue v0.1 probes as buyer-visible `/v1/chat/completions` traffic.

The provider MUST treat probe traffic as non-billable and MUST NOT emit SPEC-015 settlement receipts for probe measurements.

### FR-3 Probe identity

Each probe request MUST include:

- `probe_version = "losslessness_probe_v1"`.
- `probe_id`.
- `model_id`.
- Expected `target_model_hash`.
- `draft_model_id`.
- Sampling profile.
- Probe prompt or prompt corpus reference.
- Requested `K`.
- Measurement-position selection parameters.

Each probe result MUST include the actual target snapshot identity used for every measured position.

### FR-4 Sampling profiles

The v0.1 default stochastic grid MUST include:

- `temperature=0.2`, `top_p=1.0`.
- `temperature=0.5`, `top_p=1.0`.
- `temperature=0.7`, `top_p=1.0`.
- `temperature=1.0`, `top_p=1.0`.

The coordinator SHOULD also run a `temperature=0.0`, `top_p=1.0` greedy control. The greedy control verdict is token-id equality, not TV distance.

Verdicts MUST be keyed by exact sampling profile. The coordinator MUST NOT aggregate different temperatures into one sanctioning verdict.

### FR-5 Compact distribution output

For each measured stochastic position, the provider MUST return:

- `plain_topk`: top-K token ids and normalized probabilities for the plain path.
- `plain_tail_mass`.
- `spec_topk`: top-K token ids and normalized probabilities for the spec path.
- `spec_tail_mass`.
- `context_hash`.
- Position index.

The provider MAY return a plain/plain baseline distribution for calibration. The coordinator MUST NOT require sampled-token histograms for the normative v0.1 verdict.

### FR-6 Coordinator TV computation

The coordinator MUST compute the canonical verdict from provider-returned compact distributions. Provider-returned scalar verdicts MAY be logged but MUST NOT be authoritative.

For stochastic positions, the coordinator MUST compute:

```text
support = union(token ids in plain_topk, token ids in spec_topk)
TV_bound = 0.5 * (
  sum_{token in support} |p_plain(token) - p_spec(token)|
  + |plain_tail_mass - spec_tail_mass|
)
```

Missing tokens in either side's top-K list MUST be treated as probability zero inside the reported support.

### FR-7 K and tail handling

The default requested K MUST be `64`.

If either side's tail mass exceeds `0.01`, or if `TV_bound` is within `0.005` of a quarantine threshold, the coordinator SHOULD retry the probe at `K=256`.

At `K=256`, if either side's tail mass exceeds `0.005`, the position MUST be marked inconclusive. High tail mass MUST NOT by itself increment the canary failure counter.

### FR-8 Verdict categories

The coordinator MUST assign one of:

- `pass`.
- `warn`.
- `quarantine_candidate`.
- `inconclusive`.

Recommended initial thresholds:

- `warn` when median `TV_bound > 0.02` or any high-entropy position `TV_bound > 0.05`.
- `quarantine_candidate` when median `TV_bound > 0.05` or any high-entropy position `TV_bound > 0.10`, after any required K retry.
- `inconclusive` for high tail mass after retry, timeout, unsupported sampler, model swap, draft unavailable, missing distributions, or malformed result.

Thresholds are draft defaults. Locking this spec requires maintainer approval for the final threshold table and prompt corpus.

### FR-9 Sanction gating

A single `quarantine_candidate` MUST NOT immediately degrade or disable a provider.

The coordinator MAY feed the existing canary failure counter only after two consecutive `quarantine_candidate` results for the same probe key. `pass` clears the consecutive losslessness failure count for that probe key. `warn` and `inconclusive` MUST NOT increment it.

After the losslessness failure count is eligible for sanctioning, the existing canary threshold MAY degrade pinned providers or mark provisional providers unavailable.

### FR-10 Telemetry surface

The coordinator MUST publish probe results as out-of-band telemetry. The v0.1 event type is `losslessness_probe_v1`.

The event MUST include:

- `probe_id`.
- `provider_id`.
- `assigned_id`.
- `model_id`.
- `target_model_hash`.
- `draft_model_id`.
- Sampling profile.
- K used for the final verdict.
- Verdict status.
- Median and max `TV_bound`.
- Max tail mass.
- Positions measured.
- Timestamp.

The event MAY include compact per-position evidence for audit retention.

### FR-11 Receipt and usage invariants

SPEC-029 MUST NOT add fields to SPEC-015 v0.4 receipts or v0.4 `usage`.

SPEC-029 MUST NOT require a SPEC-022 settlement change.

SPEC-029 MUST NOT alter buyer token accounting, payout accounting, receipt verification, or external verifier behavior.

Future receipt versions MAY bind a digest of recent losslessness probe status, but that is outside v0.1.

### FR-12 Warm-swap handling

If the target model or draft model changes while a probe is running, the provider MUST return `inconclusive:model_swap` or equivalent structured error.

Probe results MUST NOT carry across target-swap boundaries. After a new target snapshot becomes ready and draft compatibility is checked, the coordinator SHOULD schedule a fresh probe for the new probe key.

Draft-load failure after a target swap MUST NOT fail the target-model swap. It MUST leave stochastic speculative decoding disabled for that model/draft pair and emit a warning or inconclusive probe result.

### FR-13 Prompt corpus

The v0.1 prompt corpus SHOULD include:

- Short general instruction prompts.
- Code-completion contexts.
- Tool-call-like JSON contexts.
- Multi-turn chat contexts.

Measurement positions SHOULD prefer higher-entropy next-token distributions. Low-entropy positions MAY be included as controls but SHOULD NOT dominate the verdict.

### FR-14 No covert canaries

V0.1 probes are overt. The provider MAY know it is handling a losslessness probe.

Covert probes MUST be specified separately because they interact with buyer traffic, billing, receipts, and abuse resistance.

## 5. Non-Goals

- Proving a malicious provider honestly loaded a claimed model.
- Proving hardware, binary, or compute integrity.
- Certifying every possible prompt or sampler configuration.
- Replacing SPEC-028 acceptance-rate telemetry.
- Replacing existing echo canaries.
- Authorizing stochastic speculative decoding without a later rollout decision.

## 6. Acceptance Criteria

Before SPEC-029 can move toward LOCK:

1. A coordinator design specifies the `losslessness_probe_v1` message, result event, storage table, and operator query path.
2. A provider design identifies the exact Swift generation/sampler hook that emits top-K probabilities plus tail mass for plain and spec paths.
3. A test fixture proves that extra losslessness fields are not added to SPEC-015 v0.4 receipts or `usage`.
4. A unit test covers coordinator TV computation with non-overlapping top-K token sets and tail masses.
5. A unit test covers `K=64` retry to `K=256` and the `inconclusive:tail_mass_high` path.
6. A coordinator test covers two consecutive `quarantine_candidate` results feeding the existing canary failure counter, while `warn` and `inconclusive` do not.
7. A warm-swap test covers `inconclusive:model_swap` and confirms old probe results do not authorize the new target snapshot.
8. Maintainers approve the v0.1 prompt corpus and threshold table.

## 7. Open Questions

1. Should v0.1 require `K=256` for all `temperature=1.0` probes, or keep `K=64` with retry?
2. What is the final normative prompt corpus and who owns updates to it?
3. Should operator dashboards show per-position compact evidence or only aggregate verdicts?
4. Should losslessness results become part of provider eligibility for stochastic spec decode only, or also affect general provider readiness?
5. What retention period is required for compact per-position evidence?
6. Does the provider-control WS path need an HTTP fallback in v0.1?
7. Should a future SPEC-015 v0.5 bind a digest of recent losslessness probe status into settlement receipts?

## 8. References

- `docs/research/losslessness-probe-2026-07.md`.
- `specs/SPEC-028-mlx-speculative-decoding.md`.
- `specs/SPEC-015-receipts.md`.
- `specs/SPEC-022-verified-model-settlement.md`.
- Shard `specpipe.py`: <https://raw.githubusercontent.com/leyten/shard/master/phase0/specpipe.py>.
- `mlx-swift-lm` 3.31.4 `Evaluate.swift`: <https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/3.31.4/Libraries/MLXLMCommon/Evaluate.swift>.
- Leviathan, Kalman, and Matias, "Fast Inference from Transformers via Speculative Decoding": <https://arxiv.org/abs/2211.17192>.
- Chen et al., "Accelerating Large Language Model Decoding with Speculative Sampling": <https://arxiv.org/abs/2302.01318>.

# Compute-Integrity Receipt Companion Research

**Date:** 2026-07-10
**Branch:** `feat/compute-integrity-receipt-companion`
**Requested by:** `specs/RESEARCH_COMPUTE_INTEGRITY_RECEIPT_PROMPT.md`
**Spec draft:** `specs/SPEC-030-compute-integrity-receipt.md`

## Summary

MacProvider should add compute-integrity drift as a companion settlement gate to
SPEC-022, not as a new SPEC-015 v0.4 receipt field. SPEC-015 v0.4 already keeps
the settlement receipt tuple and `usage` object strict
(`specs/SPEC-015-receipts.md:3803`, `specs/SPEC-015-receipts.md:4051`), and
SPEC-022 already says non-`verified` outcomes are excluded from provider credit,
earnings, settlement sweeps, and payout readiness
(`specs/SPEC-022-verified-model-settlement.md:529`).

Recommended v0.1 shape:

- Add coordinator-owned compute-integrity state keyed by
  `(provider_id, assigned_id, model_id, target_model_hash, target_generation,
  sampling_profile, corpus_version, threshold_version)`.
- Keep SPEC-015 v0.4 receipts unchanged. Settlement inherits the provider's
  request-start compute-integrity state and returns `quarantined` with reason
  `compute_drift_quarantined` when enforce mode is active.
- Use a hybrid reference source: coordinator-run trusted reference is the
  authority; N-provider consensus is telemetry and anomaly detection; periodic
  trusted-node audit catches consensus poisoning.
- Use warn-only for at least 30 days and 10,000 eligible compute-integrity
  canaries before enforce mode.
- For a 100-provider x 10-model fleet at one canary per provider/model/day, plan
  on 1,000 canaries/day. A hosted M4 Pro reference budget is about $0.012 to
  $0.023 per canary depending on one or two reference Macs; consensus telemetry
  at three replicas adds about $0.012/day-equivalent at the current high MoE
  rate-card row if paid as token opportunity cost.

The hard limitation is adversarial: SPEC-029 v0.1 probes are overt and explicitly
do not prove compute integrity (`specs/SPEC-029-losslessness-probe.md:72`,
`specs/SPEC-029-losslessness-probe.md:584`). This companion can close the
settlement policy gap for measurable drift, misconfiguration, degraded model
paths, and non-perfect cheating. It must not claim cryptographic proof that a
malicious provider honestly ran the target model until a later covert or
independently verifiable probe spec exists.

## Sources Checked

Local anchors:

- SPEC-015 v0.4 receipt profile and strict usage:
  `specs/SPEC-015-receipts.md:3`, `specs/SPEC-015-receipts.md:36`,
  `specs/SPEC-015-receipts.md:3803`, `specs/SPEC-015-receipts.md:4051`.
- SPEC-022 outcome model and money gate:
  `specs/SPEC-022-verified-model-settlement.md:302`,
  `specs/SPEC-022-verified-model-settlement.md:397`,
  `specs/SPEC-022-verified-model-settlement.md:529`,
  `specs/SPEC-022-verified-model-settlement.md:548`,
  `specs/SPEC-022-verified-model-settlement.md:839`.
- Current settlement verifier constants and v0.4 tuple shape:
  `phase4-coordinator/internal/billing/settlement_verifier.go:17`,
  `phase4-coordinator/internal/billing/settlement_verifier.go:35`,
  `phase4-coordinator/internal/billing/settlement_verifier.go:79`,
  `phase4-coordinator/internal/billing/settlement_verifier.go:321`,
  `phase4-coordinator/internal/billing/settlement_verifier.go:548`.
- SPEC-029 probe primitive and limits:
  `specs/SPEC-029-losslessness-probe.md:3`,
  `specs/SPEC-029-losslessness-probe.md:10`,
  `specs/SPEC-029-losslessness-probe.md:28`,
  `specs/SPEC-029-losslessness-probe.md:60`,
  `specs/SPEC-029-losslessness-probe.md:120`,
  `specs/SPEC-029-losslessness-probe.md:327`,
  `specs/SPEC-029-losslessness-probe.md:397`,
  `specs/SPEC-029-losslessness-probe.md:552`,
  `specs/SPEC-029-losslessness-probe.md:560`,
  `specs/SPEC-029-losslessness-probe.md:576`.
- SPEC-026 onboarding seams:
  `specs/SPEC-026-browserless-provider-onboarding.md:1893`,
  `specs/SPEC-026-browserless-provider-onboarding.md:1905`,
  `specs/SPEC-026-browserless-provider-onboarding.md:2169`,
  `specs/SPEC-026-browserless-provider-onboarding.md:2270`.
- Existing provider readiness/canary state:
  `phase4-coordinator/internal/pool/provider.go:32`,
  `phase4-coordinator/internal/pool/provider.go:153`,
  `phase4-coordinator/internal/pool/provider.go:488`,
  `phase4-coordinator/internal/pool/provider.go:1223`.
- Rate/cost anchors:
  `phase4-coordinator/dist/coordinator.yaml.example:179`,
  `phase4-coordinator/dist/coordinator.yaml.example:195`,
  `phase4-coordinator/coordinator.yaml.example:207`,
  `beta/catalog-expansion/P2-small-tier-catalog.md:180`,
  `beta/catalog-expansion/P1-gemma4-catalog-rollout.md:160`,
  `phase4-coordinator/internal/billing/formula.go:17`.

External anchors checked on 2026-07-10:

- MacStadium pricing lists hosted M4.S at $149/month and M4.L at $349/month:
  <https://macstadium.com/pricing>.
- Apple Mac mini power table lists 2024 M4 at 4W idle / 65W max and M4 Pro at
  5W idle / 140W max: <https://support.apple.com/en-us/103253>.

## A. Outcome Model Extension

SPEC-022 currently has exactly four settlement values: `verified`, `pending`,
`quarantined`, and `zero_settled`
(`specs/SPEC-022-verified-model-settlement.md:302`). The Go verifier mirrors
that as `SettlementOutcomePending`, `SettlementOutcomeVerified`,
`SettlementOutcomeQuarantined`, and `SettlementOutcomeZeroSettled`
(`phase4-coordinator/internal/billing/settlement_verifier.go:17`).

The new state should not be a fifth top-level settlement outcome in v0.1.
Instead:

- Fleet-time state: `compute_integrity_provider_state`.
- Settlement-time outcome: existing `quarantined`.
- Settlement reason: `compute_drift_quarantined`.

That keeps SPEC-022's money gate compatible with current storage and payout
rules: any row whose receipt-verification outcome is not `verified` is excluded
from provider credit, earnings, settlement sweeps, payout readiness, and SPEC-016
payout consumption (`specs/SPEC-022-verified-model-settlement.md:529`).

Drift is a provider/model/window fact, not a per-receipt cryptographic fact. A
single receipt can prove model-id, route snapshot, hashes, usage, terminal
state, and signature under v0.4
(`phase4-coordinator/internal/billing/settlement_verifier.go:321`), but it
cannot prove that the provider did not internally compute with a cheaper model
and then sign the expected tuple. Therefore settlement should read the
request-start compute-integrity state captured with the route snapshot. If the
state was `quarantined_compute_drift` at request start and policy mode is
`enforce`, the receipt may be structurally valid but still settles as
`quarantined`.

Additive verifier surface:

- Add optional input fields to the settlement context: compute-integrity policy
  mode/version, request-start compute state, reference digest, window id, and
  reason.
- Keep `SettlementVerifyResult.Outcome` as the current enum.
- Add `Reason = "compute_drift_quarantined"` when the inherited fleet-time state
  blocks settlement.
- Do not add fields to the v0.4 receipt tuple or `usage`; SPEC-015 and
  SPEC-029 both forbid optional receipt/usage expansion for these probes
  (`specs/SPEC-015-receipts.md:4051`,
  `specs/SPEC-029-losslessness-probe.md:552`).

## B. Reference Distribution Source

Decision: v0.1 should use a hybrid reference source with coordinator-run trusted
reference as authority and N-provider consensus as telemetry.

| Option | Strength | Failure mode | Verdict |
|---|---|---|---|
| Trusted reference node | Deterministic authority under operator control; easiest catalog/hash pinning; quarantines are explainable | Single point of operator misconfiguration or reference drift | Use as enforcement authority |
| N-provider consensus | Avoids relying on one box; scales across model fleet | Sybil/cartel poisoning and correlated provider bugs; circular if same providers under test create the reference | Use only as telemetry in v0.1 |
| Hybrid | Trusted node anchors the distribution; consensus detects reference-node drift and fleet anomalies | More moving parts and cost | Recommended |

Reference model-hash pinning:

1. The coordinator selects `model_id` and `target_model_hash` from the signed
   catalog already used by SPEC-022 route snapshots.
2. The trusted reference node is admitted only when its loaded model hash equals
   that signed catalog hash.
3. Each reference event stores `reference_model_hash`, `catalog_id`,
   `catalog_body_digest`, `reference_artifact_digest`, `tokenizer_identity`,
   `sampling_profile`, `corpus_version`, and `threshold_version`.
4. Candidate providers are compared only against reference events with identical
   `model_id`, `target_model_hash`, tokenizer identity, sampling profile, corpus,
   and threshold version.

Refresh cadence:

- Reference distributions are refreshed once per `target_model_hash` /
  sampling-profile / corpus-version / threshold-version every 24 hours.
- Refresh immediately after catalog rotation, reference-node binary/runtime
  update, prompt corpus update, tokenizer identity change, or threshold-version
  change.
- N-provider consensus summaries refresh opportunistically from the same
  canary cadence, but they cannot produce quarantine by themselves in v0.1.

## C. Threshold Semantics

SPEC-029 already defines TV lower/upper interval semantics for compact
probability snapshots (`specs/SPEC-029-losslessness-probe.md:54`) and draft
defaults for losslessness warning/quarantine thresholds
(`specs/SPEC-029-losslessness-probe.md:397`). Compute-integrity should reuse the
same metric shape but compare provider-vs-reference instead of plain-vs-spec.

Terminology:

- `epsilon_1`: canary-level warning threshold.
- `epsilon_2`: window-level quarantine threshold.
- `tau_warn`: model/profile calibrated `epsilon_1`.
- `tau_quarantine`: model/profile calibrated per-canary quarantine-candidate
  threshold used as input to `epsilon_2`.

Initial threshold formula:

```text
tau_warn_median =
  max(0.015, baseline_median_tv_upper_p99 + 0.005)

tau_warn_position =
  max(0.030, baseline_position_tv_upper_p99 + 0.010)

tau_quarantine_median =
  max(0.060, baseline_median_tv_upper_p99 + 0.050)

tau_quarantine_position =
  max(0.120, baseline_position_tv_upper_p99 + 0.080)
```

The fixed floors are intentionally wider than SPEC-029 losslessness defaults
because this comparison crosses machines and may compare different MLX runtime
builds, quantization kernels, and sampler implementations. The baseline term is
model/profile-specific: high-temperature and high-entropy prompts naturally have
wider numerical drift than low-temperature prompts. No global epsilon should be
used for all models and temperatures.

Single canary status:

- `pass`: median `tv_upper <= tau_warn_median` and every position
  `tv_upper <= tau_warn_position`.
- `warn`: warning threshold exceeded but quarantine-candidate threshold not met.
- `quarantine_candidate`: median `tv_lower > tau_quarantine_median` or any
  position `tv_lower > tau_quarantine_position`, after K=256 retry and with a
  valid reference.
- `inconclusive`: tail mass, identity, timeout, reference, or validation failure.

Window quarantine rule:

- Evaluate a rolling 7-day window per provider/model/hash/profile/corpus/
  threshold.
- Require at least 5 eligible canaries in the window.
- Quarantine when at least 3 of the latest 5 eligible canaries are
  `quarantine_candidate`, no intervening `pass` exists after the first
  candidate, and the trusted-reference event set is still fresh.
- Clear back to `verified` only after 5 consecutive `pass` results across at
  least 24 hours under the same key.

Statistical rationale:

The top-K probability snapshot path is not a repeated sampled-token test; the
dominant false-positive sources are numeric/kernel drift, tail truncation, and
reference-node drift. That is why thresholds are calibrated from
same-hash/same-runtime baselines and quarantine uses `tv_lower`, not
provider-supplied scalar verdicts. If maintainers tune the single-canary false
quarantine-candidate rate to at most 1%, then the probability of 3 or more false
candidates in 5 independent canaries is about:

```text
10 * 0.01^3 * 0.99^2 + 5 * 0.01^4 * 0.99 + 0.01^5 = 0.00000985
```

That is roughly 1 false window per 101,500 independent 5-canary windows before
accounting for correlation. Correlation is the real risk, so enforce mode still
requires a 30-day warn-only calibration period.

## D. Onboarding Integration

SPEC-026 has a clean onboarding flag and state matrix
(`specs/SPEC-026-browserless-provider-onboarding.md:1893`,
`specs/SPEC-026-browserless-provider-onboarding.md:1905`) and fresh installs
must reach `.live` within the onboarding acceptance criteria
(`specs/SPEC-026-browserless-provider-onboarding.md:2270`). Compute-integrity
should not block the local App onboarding flow itself in v0.1. It should gate
billable traffic assignment after the provider is identity-registered and before
the provider becomes eligible for covered paid routing.

Recommended state:

- `compute_integrity_onboarding_pending`: provider can connect and run
  non-billable probes, but receives no covered paid traffic for the model/hash
  key.
- `compute_integrity_onboarding_passed`: provider can receive covered paid
  traffic for that exact key when all other gates pass.
- `compute_integrity_onboarding_failed`: provider remains connected but is
  blocked from billable traffic for that key.
- `compute_integrity_manual_review`: operator can inspect failures and decide
  whether to reset the onboarding gate.

New providers should pass 5 canaries over at least 30 minutes against the
trusted reference before receiving covered paid traffic for a model/hash key.
Failure mode should be retryable: one failed gate schedules exponential backoff
and a second full gate attempt; two failed gate attempts within 24 hours move the
key to manual review. Permanent block is too strong for v0.1 because reference
and runtime calibration are still young.

## E. SPEC-011 Warm-Swap Interaction

The compute-integrity window must reset across target-generation boundaries.
SPEC-029 already defines `target_generation` as coordinator-owned and
incremented on target hash change, completed warm-swap, runtime reload,
unproven reconnect continuity, or same-hash target reload
(`specs/SPEC-029-losslessness-probe.md:64`). SPEC-029 also says probe results
must not carry across target/draft generation boundaries
(`specs/SPEC-029-losslessness-probe.md:560`).

Compute-integrity should use the same target-generation rule:

- A warm-swap invalidates the old compute-integrity window for routing.
- The new generation starts in `unknown` or `onboarding_pending`.
- The coordinator schedules fresh probes before covered paid traffic uses the
  new generation under enforce mode.

Warm-swap laundering is detectable if the coordinator records generation-change
events, old window state, and reason. A provider that repeatedly swaps after
warnings should enter `blocked:swap_laundering_suspected` for that model/hash
until manual review. That state blocks routing, but it should not mutate
historical settlement rows whose request-start state was clean.

## F. Third-Party Audit Surface

Third parties should be able to read compute-integrity evidence, not create
quarantine-grade evidence in v0.1.

Recommended surfaces:

- Public or buyer-safe read API for aggregate state:
  `/v1/providers/{provider_id}/compute-integrity` with redacted current status,
  model id, hash, profile, window id, threshold version, and latest event digest.
- Auditor export API for signed evidence bundles: reference events, provider
  probe result digests, computed TV intervals, and final state transitions.
- No direct third-party probe issuance in v0.1.

Reasoning:

Coordinator-issued probes are tied to provider-control auth, nonce/replay
checks, bounded K, freshness, and audit logging in SPEC-029
(`specs/SPEC-029-losslessness-probe.md:120`). A buyer or external auditor cannot
be assumed to have the same scheduling, identity, or anti-abuse context.
Third-party measurements can be useful allegations or diagnostic evidence, but
they should not be admissible for automatic quarantine until a later spec defines
auth, rate limits, challenge selection, and abuse handling.

## G. Migration Path

Phase 0 - draft/spec audit:

- Land `SPEC-030` as draft.
- Do not modify SPEC-015, SPEC-022, or code.

Phase 1 - observe/warn-only:

- Implement telemetry, reference generation, provider comparison, and dashboard
  state.
- Default mode `observe`.
- Emit `warn` and `quarantine_candidate` events, but never alter buyer debit,
  provider credit, earnings, payout readiness, or buyer-facing claims. This
  matches SPEC-022 observe-mode semantics
  (`specs/SPEC-022-verified-model-settlement.md:335`).
- Minimum observation window: 30 days, at least 10,000 eligible canaries, at
  least 100 provider/model/hash keys, and at least 3 catalog/model rotations or
  reference refresh cycles.

Phase 2 - new-provider gate:

- New provider/model/hash keys must pass onboarding compute-integrity canaries
  before covered paid routing.
- Existing providers are grandfathered into observe mode only; they are not
  quarantined retroactively.

Phase 3 - enforce:

- Covered paid traffic snapshots request-start compute-integrity state.
- If state is `quarantined_compute_drift`, settlement returns `quarantined` with
  reason `compute_drift_quarantined`.
- `zero_settled` remains reserved for verified non-creditable terminal outcomes,
  not trust failures (`specs/SPEC-022-verified-model-settlement.md:545`).

## H. Cost Accounting

Assumptions for concrete budgeting:

- Fleet: 100 providers x 10 model/hash keys = 1,000 provider/model keys.
- Cadence: 1 compute-integrity canary per provider/model key per day.
- Canary shape inherits SPEC-029 bounds: at most 4 prompts and 8 stochastic
  measurement positions per result (`specs/SPEC-029-losslessness-probe.md:126`).
- Average measured context: 512 prompt-token-equivalent per position.
- Daily reference workload: `1,000 * 4 * 8 * 512 = 16,384,000`
  prompt-token-equivalent forward-pass tokens/day.

Trusted reference node cost:

- Hosted M4.L Mac mini: $349/month, about $11.63/day or $0.0116/canary.
- Two-node active/standby or model-shard pool: about $23.26/day or
  $0.0233/canary.
- Self-hosted electricity-only M4 Pro at Apple max 140W and $0.15/kWh:
  `0.140 kW * 24h * $0.15 = $0.504/day`, or $0.00050/canary, excluding
  hardware depreciation and ops.

Consensus telemetry opportunity cost:

- The current public docs record `qwen3-8b` completion rate at 27,000
  credits/Mtok and `google-gemma-4-26b-a4b-it` at 240,000 credits/Mtok
  (`beta/catalog-expansion/P2-small-tier-catalog.md:180`,
  `beta/catalog-expansion/P1-gemma4-catalog-rollout.md:160`).
- With `usd_per_million_credits = 1.0` documented in config
  (`phase4-coordinator/dist/coordinator.yaml.example:179`), the high MoE row is
  $0.240/M completion-token-equivalent.
- One 16.384M-token-equivalent daily reference stream at $0.240/M is $3.93/day.
- N=3 consensus telemetry would therefore consume about $11.80/day of
  opportunity cost if compensated at the high row, or $0.0118/canary.

Funding decision:

- v0.1 should be network/operator funded, not buyer pass-through. Buyers did not
  request the probes, probes are non-billable under SPEC-029
  (`specs/SPEC-029-losslessness-probe.md:135`), and adding buyer-visible usage
  would violate the strict SPEC-015 v0.4 `usage` shape.
- Future staker-reward or provider-quality budgets can absorb consensus
  telemetry if the network moves beyond one trusted reference node.

## Self-Review

- Every A-H question is answered.
- SPEC-029 prerequisite is satisfied by `specs/SPEC-029-losslessness-probe.md`
  at v0.1-draft (`specs/SPEC-029-losslessness-probe.md:3`).
- Reference-source decision is explicit: hybrid, with trusted reference as
  enforcement authority.
- Thresholds are model/profile calibrated and include a window-level
  false-positive rationale.
- Cost accounting is concrete for 1,000 canaries/day.
- No code changes are required by this memo.

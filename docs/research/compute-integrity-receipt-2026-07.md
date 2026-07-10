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
  `(stable_provider_identity, provider_id, assigned_id, model_id,
  target_model_hash, tokenizer_identity, sampler_stage, target_generation,
  sampling_profile, corpus_version, threshold_version)`, with rolling windows
  and sub-threshold counters anchored to stable provider identity rather than
  `assigned_id`.
- Keep SPEC-015 v0.4 receipts unchanged. Settlement inherits the provider's
  request-start compute-integrity state and returns `quarantined` with reason
  `compute_drift_quarantined` when enforce mode is active.
- Recommend a hybrid reference source: coordinator-run trusted reference is the
  enforcement authority; N-provider consensus is telemetry and anomaly
  detection. The open question remains whether v0.1 enforce may run
  trusted-reference-only with two active independent references.
- Use warn-only calibration per covered model/hash/tokenizer/sampler-stage/
  profile/corpus/threshold key before enforce mode. Fleet-wide canary totals are
  additive evidence only and do not substitute for missing per-key calibration.
- For a 100-provider x 10-model fleet at one canary per provider/model/day, plan
  on 1,000 canaries/day. Enforce budgets assume at least two continuously active
  comparable trusted references for every covered key; one-reference operation is
  observe/warn-only only. Hosted M4 Pro reference budget is about $0.023 per
  canary before shard/burst headroom; consensus telemetry at three replicas adds
  about $0.0118/canary, about $11.80/day at N=3, at the current high MoE
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
  mode/version, request-start compute state, `reference_set_id`, all active
  trusted `reference_event_digests`, reference-set admissibility status/digest,
  quorum count, reference-fault check version, window id, circuit-breaker hold
  status/scope, expiry cause, and reason.
- Keep `SettlementVerifyResult.Outcome` as the current enum.
- Add a reason from the closed SPEC-030 enum when the inherited fleet-time state
  blocks settlement, including `compute_drift_quarantined` for
  `quarantined_compute_drift`.
- Do not add fields to the v0.4 receipt tuple or `usage`; SPEC-015 and
  SPEC-029 both forbid optional receipt/usage expansion for these probes
  (`specs/SPEC-015-receipts.md:4051`,
  `specs/SPEC-029-losslessness-probe.md:552`).

## B. Reference Distribution Source

Recommendation: v0.1 should use a hybrid reference source with coordinator-run
trusted reference as authority and N-provider consensus as telemetry. The open
question remains whether enforce may run trusted-reference-only with two active
independent references.

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
   `sampler_stage`, `sampling_profile`, `corpus_version`, and
   `threshold_version`.
4. Candidate providers are compared only against reference events with identical
   `model_id`, `target_model_hash`, tokenizer identity, sampler stage, sampling
   profile, corpus, and threshold version.

Refresh cadence:

- Reference distributions are refreshed once per `target_model_hash` /
  tokenizer-identity / sampler-stage / sampling-profile / corpus-version /
  threshold-version every 24 hours.
- Refresh immediately after reference runtime/build update, runtime-build
  provenance digest change, signed golden-fixture validation digest change,
  tokenizer identity change, sampler-stage change, prompt corpus update,
  threshold-version change, or catalog rotation.
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

- Evaluate a rolling 7-day window per stable provider/model/hash/tokenizer/
  sampler-stage/profile/corpus/threshold key.
- Require at least `min_window_canaries` eligible canaries in the window.
- Quarantine when at least `quarantine_candidate_count` of the latest
  `min_window_canaries` eligible canaries are `quarantine_candidate`, regardless
  of intervening `pass` results, and the trusted-reference event set is still
  fresh.
- Clear back to `verified` only after `clear_pass_count` consecutive `pass`
  results across at least 24 hours under the same key.

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
should not block the local App onboarding flow itself in v0.1. In warn-only mode
it should emit readiness telemetry only. Paid-routing blocks begin only in
enforce mode after the activation gates pass.

Recommended state:

- `compute_integrity_onboarding_pending`: provider can connect and run
  non-billable probes. In warn-only this is readiness telemetry only; in enforce
  the provider receives no covered paid traffic for the full
  stable-provider/model/hash/tokenizer/sampler-stage/generation/profile/corpus/
  threshold onboarding key unless an approved all-profile coverage mode subsumes
  the buyer request.
- `compute_integrity_onboarding_verified`: provider can receive covered paid
  traffic for that exact onboarding key or approved all-profile coverage mode
  when all other gates pass.
- `compute_integrity_onboarding_failed`: provider remains connected but is
  blocked from billable traffic for that covered key only in enforce mode.
- `blocked:manual_review_required`: operator can inspect failures and decide
  whether to reset the onboarding gate.

New providers should pass 5 canaries over at least 30 minutes against the
trusted reference before receiving covered paid traffic for a full
stable-provider/model/hash/tokenizer/sampler-stage/generation/profile/corpus/
threshold onboarding key in enforce mode, unless an approved all-profile
coverage mode subsumes the buyer request. Failure mode should be retryable: one
failed gate schedules exponential backoff and a second full gate attempt; two
failed gate attempts within 24 hours move the key to
`blocked:manual_review_required`. Permanent block is too strong for v0.1 because
reference and runtime calibration are still young.

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
  model id, hash, tokenizer identity, sampler stage, profile, corpus, threshold
  version, window id, latest reference-set id, and latest event digest.
- Auditor export API for signed evidence bundles: reference events, provider
  probe result digests, computed TV intervals, final state transitions, and the
  inline compact evidence or signed retained-object references needed to
  recompute settlement-impacting TV intervals for the provider/reference union
  support.
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
- Prepare approved disclosure copy before enforce: SPEC-030 is not
  cryptographic proof, hardware integrity, or binary integrity; `warn` remains
  payable in enforce when payable-window prerequisites are satisfied and the
  latest valid result is warning-class below the quarantine-candidate threshold;
  and `quarantined_compute_drift` blocks paid routing and payable settlement only
  in enforce.
- Minimum observation window: each covered model/hash/tokenizer/sampler-stage/
  profile/corpus/threshold key must collect at least 30 days of warn-only data,
  at least 100 eligible canaries, enough distinct stable provider identities for
  the approved calibration plan, and at least one relevant trusted-reference
  refresh after the latest reference runtime/build, runtime-build provenance
  digest, signed golden-fixture validation digest, tokenizer, sampler-stage,
  corpus, threshold, or catalog change. Fleet summaries can additionally require
  at least 10,000 eligible canaries, 100 covered keys, and 3 catalog/model
  rotations or reference refresh cycles, but they do not substitute for missing
  per-key calibration.

Phase 2 - enforce-ready onboarding telemetry:

- New stable provider/model/hash/tokenizer/sampler-stage/target-generation/
  profile/corpus/threshold keys emit onboarding readiness telemetry during
  warn-only; this phase still does not block paid routing.
- Existing providers are not retroactively reclassified during warn-only.

Phase 3 - enforce:

- Covered paid traffic snapshots request-start compute-integrity state.
- Enforce activation requires approved disclosure surfaces for buyer, provider,
  public, and auditor-facing copy.
- New stable provider/model/hash/tokenizer/sampler-stage/target-generation/
  profile/corpus/threshold keys must pass onboarding compute-integrity canaries
  before covered paid routing, unless an approved all-profile coverage mode
  subsumes the buyer request.
- Existing covered keys are evaluated prospectively at enforce
  activation; active `quarantined_compute_drift`, `blocked:<reason>`, `expired`,
  stale, unreadable, or under-sampled states fail closed until clear rules pass.
- If state is `quarantined_compute_drift`, settlement returns `quarantined` with
  reason `compute_drift_quarantined`; other non-payable compute-integrity states
  map to the closed SPEC-030 reason enum.
- `zero_settled` remains reserved for verified non-creditable terminal outcomes,
  not trust failures (`specs/SPEC-022-verified-model-settlement.md:545`).

## H. Cost Accounting

Assumptions for concrete budgeting:

- Fleet: 100 stable providers x 10 model/hash/tokenizer/sampler-stage/profile
  keys = 1,000 covered keys.
- Cadence: 1 compute-integrity canary per stable provider/model/hash/tokenizer/
  sampler-stage/profile key per day.
- Canary shape inherits SPEC-029 bounds: at most 4 prompts and 8 stochastic
  measurement positions per result (`specs/SPEC-029-losslessness-probe.md:126`).
- Average measured context: 512 prompt-token-equivalent per position.
- Daily reference workload per active reference replica:
  `1,000 * 4 * 8 * 512 = 16,384,000` prompt-token-equivalent forward-pass
  tokens/day. Two-replica enforce total: 32,768,000 forward-pass units/day before
  shard, burst, or refresh headroom.

Trusted reference node cost:

- Hosted M4.L Mac mini: $349/month, about $11.63/day before redundancy.
- Two continuously active reference nodes: about $23.26/day before model-shard
  capacity. Idle standby nodes are additional and do not count toward enforce
  quorum unless they continuously produce fresh comparable reference events.
- Per active self-hosted electricity-only M4 Pro reference at Apple max 140W and
  $0.15/kWh: `0.140 kW * 24h * $0.15 = $0.504/day`, or $0.00050/canary. The
  two-active-reference enforce minimum is $1.008/day, or $0.0010/canary, before
  hardware depreciation and ops.

Consensus telemetry opportunity cost:

- The current public docs record `qwen3-8b` completion rate at 27,000
  credits/Mtok and `google-gemma-4-26b-a4b-it` at 240,000 credits/Mtok
  (`beta/catalog-expansion/P2-small-tier-catalog.md:180`,
  `beta/catalog-expansion/P1-gemma4-catalog-rollout.md:160`).
- With `usd_per_million_credits = 1.0` documented in config
  (`phase4-coordinator/dist/coordinator.yaml.example:179`), the high MoE row is
  $0.240/M completion-token-equivalent.
- One 16.384M-token-equivalent daily reference stream at $0.240/M is $3.93/day;
  two active enforce references are $7.86/day before shard, burst, or refresh
  headroom.
- N=3 consensus telemetry would therefore consume about $11.80/day of
  opportunity cost if compensated at the high row, or $0.0118/canary.

Funding decision:

- v0.1 should be network/operator funded, not buyer pass-through. Buyers did not
  request the probes, probes are non-billable under SPEC-029
  (`specs/SPEC-029-losslessness-probe.md:135`), and adding buyer-visible usage
  would violate the strict SPEC-015 v0.4 `usage` shape.
- Future staker-reward or provider-quality budgets can absorb consensus
  telemetry, but enforce-mode reference budgets still require at least two
  continuously active comparable trusted references per covered key plus
  sharding, burst, and refresh capacity.

## Self-Review

- Every A-H question is answered.
- SPEC-029 prerequisite is satisfied by `specs/SPEC-029-losslessness-probe.md`
  at v0.1-draft (`specs/SPEC-029-losslessness-probe.md:3`).
- Reference-source recommendation is explicit: hybrid is recommended, trusted
  reference is enforcement authority, and trusted-reference-only enforce remains
  an open question.
- Thresholds are model/profile calibrated and include a window-level
  false-positive rationale.
- Cost accounting is concrete for 1,000 canaries/day and assumes two active
  trusted references before enforce.
- No code changes are required by this memo.

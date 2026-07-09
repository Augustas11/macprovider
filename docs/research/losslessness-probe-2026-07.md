# Losslessness Probe Research

**Date:** 2026-07-09
**Branch:** `feat/losslessness-probe`
**Requested by:** `specs/RESEARCH_LOSSLESSNESS_PROBE_PROMPT.md`

## Summary

MacProvider should add an overt, coordinator-issued losslessness probe before any stochastic speculative-decoding rollout. The probe should not ride the buyer API, buyer receipts, or SPEC-015 v0.4 `usage` object. Those surfaces are intentionally strict: SPEC-028 keeps speculative-decoding telemetry out of receipts, and the coordinator plus external verifier reject any extra v0.4 tuple or usage keys.

The safest v0.1 shape is:

- Use the existing coordinator canary scheduler and sanction plumbing as the operational lane, but add a new `losslessness_probe_v1` profile instead of overloading nonce echo canaries.
- Send probes out-of-band to providers through a dedicated WS/provider-control message, not as buyer-like `/v1/chat/completions` traffic.
- Ask providers for compact per-position distributions for plain target decoding and speculative decoding. The provider returns top-K normalized probabilities plus residual tail mass; the coordinator recomputes total-variation distance.
- Default to `K=64`, retry at `K=256` when tail mass or threshold proximity makes the result inconclusive, and do not rely on repeated sampled-token counts as the quarantine-grade mechanism.
- Rotate temperature settings across `{0.2, 0.5, 0.7, 1.0}` with `top_p=1.0`; keep `temperature=0.0` as a control for token-exact greedy equality.
- Publish probe results as out-of-band coordinator telemetry keyed by provider, model hash, draft model id, sampling profile, and probe id. Future SPEC-015 receipt versions may optionally bind a digest, but this research does not recommend changing v0.4 receipts.

This keeps the probe compatible with SPEC-028's buyer-invisible, provider-side optimization posture while giving the coordinator a quantitative gate for stochastic speculative decoding.

## Sources Checked

Local code/spec anchors:

- SPEC-028 scope and invariants: `specs/SPEC-028-mlx-speculative-decoding.md:11`, `:38-47`, `:136-164`, `:166-181`, `:183-195`.
- SPEC-015 receipt strictness: `specs/SPEC-015-receipts.md:1-4`, `:3804-3816`, `:4051-4062`, `:4742`.
- Coordinator settlement verifier strict keys: `phase4-coordinator/internal/billing/settlement_verifier.go:35-49`, `:321-354`, `:365-403`.
- External verifier strict keys: `phase7-verify/internal/verify/settlement.go:40-71`, `:417-445`.
- Buyer request validation/routing: `phase4-coordinator/internal/buyer/server.go:1445-1514`, `:1602-1644`, `:4167-4202`, `:4750-4868`.
- Existing coordinator canary config and loop: `phase4-coordinator/internal/config/config.go:255-265`; `phase4-coordinator/internal/ws/server.go:1827-1878`, `:1902-2100`.
- Existing canary sanction state: `phase4-coordinator/internal/pool/provider.go:908-970`.
- Provider request defaults and prompt hash fields: `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:47-55`, `:205-239`; `phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift:4-24`.
- Provider generation path: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:700-716`, `:850-866`, `:1297-1310`.
- Provider model-snapshot/warm-swap receipt binding: `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:238-321`, `:556-585`, `:743-755`, `:852-875`.

External anchors:

- Shard `specpipe.py`, distribution canary concept: <https://raw.githubusercontent.com/leyten/shard/master/phase0/specpipe.py>.
- `mlx-swift-lm` 3.31.4 `Evaluate.swift`, sampler and speculative iterator shape: <https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/3.31.4/Libraries/MLXLMCommon/Evaluate.swift>.
- Leviathan, Kalman, and Matias, "Fast Inference from Transformers via Speculative Decoding": <https://arxiv.org/abs/2211.17192>.
- Chen et al., "Accelerating Large Language Model Decoding with Speculative Sampling": <https://arxiv.org/abs/2302.01318>.
- Wei and Dudley, "Two-sample Dvoretzky-Kiefer-Wolfowitz inequalities": <https://collaborate.princeton.edu/en/publications/two-sample-dvoretzky-kiefer-wolfowitz-inequalities>.

## A. Canary Issuance Mechanism

### Existing surface

MacProvider already has a coordinator-side canary lane. Config exposes canary enablement, cadence, timeout, max tokens, failure threshold, and challenge templates. The WS server starts a canary loop when pool canaries are enabled, schedules jittered sweeps, dispatches probes, compares returned content against an expected string, and records pass/fail into the provider registry. After thresholded failures, provisional providers become unavailable and pinned providers degrade through canary recovery holds.

That machinery is useful for scheduling, rate limiting, and state transitions. The current canary body, however, is an echo challenge: it builds a normal chat request with a nonce prompt and expects a fixed text response. Losslessness needs a different probe type because the coordinator must compare distributions, not exact challenge text.

### Recommended v0.1 issuance

Add a distinct `losslessness_probe_v1` canary profile under the existing coordinator canary subsystem:

1. The coordinator selects ready providers with speculative decoding enabled and a known `(target_model_hash, draft_model_id)` pair.
2. It sends one probe per selected `(provider_id, assigned_id, model_id, target_model_hash, draft_model_id, sampling_profile)` per cadence slot.
3. It rotates sampling profiles over the day instead of issuing every temperature on every cadence.
4. It writes a result event and only feeds provider sanctions when the result is a confirmed losslessness failure, not when the provider reports `inconclusive`.

Default cadence should be light enough not to become synthetic load:

| Scope | Default |
|---|---:|
| Provider/model probe interval | 60 minutes |
| Temperature profiles per interval | 1 rotating profile |
| Full grid coverage | Every 24 hours per provider/model/draft pair |
| Probe max positions | 8 measured decode positions |
| Probe max prompt corpus entries | 4 prompts per result event |
| Per-provider concurrent probes | 1 |

The cadence should reuse the current canary jitter pattern so probes do not synchronize across the fleet.

### Temperature profile

SPEC-028 currently permits speculative decoding only for deterministic greedy requests. The losslessness probe exists to decide whether stochastic speculative decoding can later be allowed. It therefore must cover non-zero temperatures even before product traffic does.

Recommended grid:

- Control: `temperature=0.0`, `top_p=1.0`, greedy token-id equality.
- Stochastic: `temperature in {0.2, 0.5, 0.7, 1.0}`, `top_p=1.0`.
- Later extension: `top_p in {0.9, 0.95}` after the top-p sampler path is instrumented.

The provider request parser already defaults `temperature` and `top_p` to `1.0`, validates `temperature` in `[0.0, 2.0]`, and validates `top_p` in `[0.0, 1.0]`. The provider generation path forwards both values into `GenerateParameters`. The probe should therefore report results per `(temperature, top_p)` rather than collapsing all sampling modes into one pass/fail.

## B. Output Representation

### Why sampled output is not enough

Shard's `specpipe.py` uses a useful research pattern: compare plain target, speculative target, and a second plain baseline at the same content position, then judge whether plain-versus-spec distance is near the plain-versus-plain Monte Carlo noise floor. That is valuable for a research harness and for detecting large stochastic drift. It is not ideal as the default quarantine-grade MacProvider mechanism because repeated sampled-token tests need many draws to distinguish small total-variation deltas with high confidence.

For a finite K-bin categorical comparison, a conservative Hoeffding union bound over two empirical histograms is:

```text
P(max_i |p_hat_i - p_i| > delta) <= 2K exp(-2n delta^2)
TV(p_hat, p) <= K * delta / 2
```

Solving this for small epsilon and moderate K produces expensive probes. For example, `K=64`, `epsilon=0.03`, and `alpha=0.01` require tens of thousands of draws per distribution under this loose bound. Even sharper two-sample DKW-style bounds do not make sampled-token probing cheap enough for frequent fleet health checks at small epsilon.

### Recommended representation

Use compact probability snapshots, not generated samples, as the normative v0.1 result:

```json
{
  "probe_version": "losslessness_probe_v1",
  "probe_id": "2026-07-09T12:00:00Z/provider-a/...",
  "model_id": "mlx-community/...",
  "target_model_hash": "sha256:...",
  "draft_model_id": "mlx-community/...",
  "temperature": 0.7,
  "top_p": 1.0,
  "positions": [
    {
      "index": 0,
      "context_hash": "sha256:...",
      "plain_topk": [{"token_id": 123, "p": 0.201}],
      "plain_tail_mass": 0.006,
      "spec_topk": [{"token_id": 123, "p": 0.199}],
      "spec_tail_mass": 0.007,
      "plain_plain_baseline_topk": [{"token_id": 123, "p": 0.202}],
      "plain_plain_baseline_tail_mass": 0.006
    }
  ]
}
```

The coordinator recomputes:

```text
support = union(topk_token_ids(plain), topk_token_ids(spec))
TV_bound = 0.5 * (
  sum_{token in support} |p_plain(token) - p_spec(token)|
  + |plain_tail_mass - spec_tail_mass|
)
```

This is a bound over the reported support plus residual tail mass. It avoids leaking raw logits and avoids treating provider-supplied scalar verdicts as authoritative. The provider may include a scalar for local debugging, but the coordinator's recomputation is canonical.

### K/N choice

Recommended K:

- Start with `K=64`.
- Require each side to report residual tail mass.
- Mark a position `inconclusive:tail_mass_high` when either tail mass exceeds `0.01`.
- Retry inconclusive or near-threshold probes with `K=256` and a stricter `0.005` tail target.
- If `K=256` still has high tail mass, preserve the event as inconclusive and do not sanction.

Recommended N:

- `N=0` for the normative top-K probability path.
- Optional `sample_n=2000` only for a research or calibration lane that uses a plain/spec/plain baseline. This can expose gross implementation drift but should not be the v0.1 quarantine source.

The top-K path still needs numerical tolerance. `mlx-swift-lm` uses `ArgMaxSampler` when temperature is zero and otherwise applies sampling filters such as top-p/top-k/min-p before categorical sampling. The probe should capture probabilities after applying the same sampling profile that production stochastic decoding would use.

## C. TV-Distance Computation And Thresholds

### Computation ownership

The coordinator should own verdict computation:

- It knows the provider id, assigned id, state, current sanctions, and probe cadence.
- It can enforce consistent thresholds across providers.
- It can retry with larger K before sanctioning.
- It can persist raw compact evidence for audit without trusting a provider-side scalar.

The provider should own only the model-local measurement primitive: for each prompt position, run the plain target path and the speculative target path under the requested sampling profile and return compact distributions.

### Status categories

Use four categories:

| Category | Meaning |
|---|---|
| `pass` | All measured positions are under the profile threshold with acceptable tail mass. |
| `warn` | Drift exceeds warning threshold, but not enough to quarantine; or baseline is missing. |
| `quarantine_candidate` | Drift exceeds the quarantine threshold after retry with larger K and stable model snapshot. |
| `inconclusive` | Tail mass too high, provider swapped model mid-probe, timeout, unsupported sampler, missing telemetry, or transient probe failure. |

### Threshold proposal

Thresholds should be profile-specific and require a local reference baseline before they can trigger sanctions. Initial values:

| Metric | Warning | Quarantine candidate |
|---|---:|---:|
| Median `TV_bound` across positions | `> 0.02` | `> 0.05` |
| Any single high-entropy position `TV_bound` | `> 0.05` | `> 0.10` |
| Tail mass after K=256 retry | `> 0.005` | inconclusive, not quarantine |

High-entropy positions should be chosen because low-entropy positions can pass trivially. The prompt corpus should include short general chat, code completion, instruction following, and tool-call-like JSON contexts, then select measurement positions where the target distribution is not nearly deterministic.

Sanction gating:

1. A first `quarantine_candidate` emits a warning and schedules an immediate retry.
2. A second consecutive `quarantine_candidate` for the same `(provider_id, assigned_id, target_model_hash, draft_model_id, sampling_profile)` may feed the existing canary failure counter.
3. The existing thresholded canary sanction path can then degrade pinned providers or mark provisional providers unavailable.
4. `inconclusive` does not increment the canary failure counter.

This matches the current registry's thresholded failure model while preventing one noisy probe from removing a provider.

## D. Publishing Surface

### Do not modify SPEC-015 v0.4 receipts

SPEC-015 v0.4 settlement receipts have a strict 23-field tuple and a strict five-key `usage` object. The coordinator billing verifier and external verifier both enforce exact key sets and reject extra usage fields with `usage_shape_invalid`. SPEC-028 also explicitly says speculative-decoding accepted/drafted tokens are telemetry, not billable usage, and that SPEC-028 must not add fields to the SPEC-015 v0.4 settlement `usage`.

Therefore the losslessness probe must not add:

- `losslessness_probe_status` to v0.4 receipts.
- `spec_decode_losslessness_tv` to v0.4 `usage`.
- Any extra buyer response field that a settlement verifier might later treat as receipt-bound usage evidence.

### Recommended v0.1 surface

Publish out-of-band coordinator telemetry:

```json
{
  "event_type": "losslessness_probe_v1",
  "probe_id": "uuid-or-jcs-hash",
  "provider_id": "provider-a",
  "assigned_id": "assignment-id",
  "model_id": "mlx-community/...",
  "target_model_hash": "sha256:...",
  "draft_model_id": "mlx-community/...",
  "sampling_profile": {"temperature": 0.7, "top_p": 1.0, "top_k": null},
  "k": 64,
  "status": "pass",
  "median_tv_bound": 0.011,
  "max_tv_bound": 0.018,
  "max_tail_mass": 0.004,
  "positions_measured": 8,
  "created_at": "2026-07-09T12:00:00Z"
}
```

Storage should be coordinator-owned, queryable by operations, and optionally surfaced in aggregate provider status. Buyers do not need per-request visibility while stochastic speculative decoding is still gated. If a future buyer-facing receipt must bind the result, create a future SPEC-015 v0.5 field such as `losslessness_probe_result_digest`; do not retrofit v0.4.

## E. Temperature Handling

Temperature is a first-class part of the probe key. Current provider code parses and validates it, prompt canonicalization preserves the original request fields, and generation passes it into `mlx-swift-lm`.

The probe should define these rules:

- `temperature=0.0` is a greedy control. The expected invariant is token-id equality between plain and speculative decoding for the measured positions.
- `temperature>0.0` is measured by total-variation distance over the next-token categorical distribution after the requested sampler profile.
- Results are never aggregated across temperatures for a pass/fail verdict.
- The coordinator may display a provider-level aggregate, but sanctions must use the exact sampling profile.
- `top_p=1.0` is the v0.1 default. Top-p values below one should be a v0.2 extension because the probe must capture probabilities after truncation, not before.

This aligns with SPEC-028's current greedy-only production gate and gives maintainers evidence to decide whether a future `--allow-stochastic-spec-decode` flag is safe.

## F. Warm-Swap Interaction

Warm-swap and probe verdicts need explicit state handling. The provider HTTP path already captures model snapshots for serving and receipt binding, and SPEC-028 requires counters to reset on target-swap boundaries. A losslessness probe must be keyed to the same target model identity.

Recommended rules:

- A probe request includes the coordinator's expected `target_model_hash`.
- The provider returns the actual snapshot hash used for every measured position.
- If the provider swaps target model or draft model during the probe, the result is `inconclusive:model_swap`.
- A model swap triggers an immediate probe for the new `(target_model_hash, draft_model_id)` pair after the provider reports ready and draft compatibility checked.
- Old probe results do not carry forward across target-swap boundaries.
- Draft-load failure after a target swap leaves the provider serving without stochastic spec decode and emits `inconclusive:draft_unavailable` or `warn:draft_disabled`, not a losslessness failure.

Failing loudly as inconclusive is better than silently invalidating the result because operations need to see swap churn and because a stale pass must not authorize stochastic decoding for a new model snapshot.

## G. Covert Canary Seam

The v0.1 probe is overt: providers know they are being tested. That is acceptable for a first stochastic-losslessness gate because the main risk is an implementation bug or sampler mismatch, not a malicious provider optimizing only canary requests.

A future covert canary would require a different seam:

- Buyer-like traffic issued by coordinator-controlled accounts without a special provider-control message.
- No canary-specific headers, probe ids, or obvious prompt corpus.
- Private scoring after the response, using receipt/prompt hashes and a hidden challenge schedule.
- Budget controls so covert probes do not distort buyer billing or provider payout.
- A separate abuse model because malicious providers can still identify low-entropy or repeated prompt families.

That design crosses into buyer API, billing, and settlement semantics. It should remain out of scope for losslessness probe v0.1 and be handled in a later spec.

## Recommendation

Draft SPEC-029 as a narrow, overt, out-of-band probe:

- It extends coordinator canaries with a new probe profile and telemetry event.
- It does not change SPEC-015 v0.4 receipts, SPEC-022 settlement, SPEC-028 receipt invariants, buyer API fields, or billable usage.
- It uses coordinator-recomputed top-K plus tail TV bounds rather than provider-provided scalar verdicts.
- It treats warm-swap, high tail mass, missing sampler support, and timeouts as inconclusive.
- It requires repeated confirmed failures before feeding the current canary sanction path.

The main remaining human decisions are threshold ownership, whether K=64/K=256 is acceptable for v0.1, whether out-of-band telemetry is sufficient for rollout governance, and which prompt corpus becomes normative.

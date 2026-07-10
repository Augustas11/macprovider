# BUILD_SPEC_029_v0_1_IMPL_PROMPT - Losslessness Probe

You are starting a fresh implementation session in the MacProvider repo. You
have no memory of prior conversations. Read this prompt end-to-end before
writing code.

## 0. Workspace And Authority

Before editing anything, verify:

```bash
pwd
git status -sb
git fetch origin
sed -n '1,80p' CLAUDE.md
sed -n '1,40p' specs/SPEC-030-losslessness-probe.md
```

Work on a feature branch or isolated implementation worktree, never local
`main`:

```bash
git worktree add ../macprovider-impl-spec-029-losslessness -b impl/spec-029-losslessness-probe origin/main
cd ../macprovider-impl-spec-029-losslessness
```

If `specs/SPEC-030-losslessness-probe.md` is not present at the implementation
base, STOP and rebase onto the branch that contains SPEC-029.

SPEC-029 is allowed to drive implementation only after one of these is true:

1. `specs/SPEC-030-losslessness-probe.md` is marked `v0.1 LOCKED`; or
2. the user explicitly asks for a draft/prototype implementation from the
   current SPEC-029 draft.

If neither is true, STOP after preflight and report that SPEC-029 is still
draft. Do not silently implement a draft protocol as production behavior.

Controlling contract:

- `specs/SPEC-030-losslessness-probe.md`.
- `docs/research/losslessness-probe-2026-07.md` as non-normative background
  only.
- `specs/SPEC-028-mlx-speculative-decoding.md`.
- `specs/SPEC-015-receipts.md` v0.4.2 receipt invariants.
- `specs/SPEC-022-verified-model-settlement.md`.
- Repo rules: `AGENTS.md` and `CLAUDE.md`.

Clean-room boundary: do not inspect Darkbloom / layr-labs `d-inference`
source. SPEC-029 references public papers and public upstream MLX surfaces only.

## 1. Objective

Implement SPEC-029 v0.1 losslessness probes end-to-end:

- Coordinator-owned `losslessness_probe_v1` scheduling, request construction,
  replay/auth/load bounds, validation, TV interval computation, state machine,
  telemetry, and operator dashboard state.
- Provider-side draft admission, target/draft identity echo, cleartext and
  Tier-2 probe carrier handling, compact shared-support distribution output,
  provider-inconclusive result variants, and warm-swap handling.
- Corpus, calibration, threshold, privacy, and rollout-consumer gates required
  to make `all_profiles_fresh` usable as SPEC-028 evidence.

This is a probe/evidence surface only. It MUST NOT:

- change SPEC-015 v0.4 receipt tuple or `usage`;
- change SPEC-022 settlement semantics;
- add buyer-visible `/v1/chat/completions` request/response fields;
- route losslessness failures into echo-canary/general provider readiness;
- enable stochastic speculative decoding without the separate SPEC-028 rollout
  approval gate.

## 2. Required Reading

Read before coding:

1. `CLAUDE.md`.
2. `specs/SPEC-030-losslessness-probe.md` end-to-end.
3. `docs/research/losslessness-probe-2026-07.md` for context only; the SPEC is
   normative when they differ.
4. `specs/SPEC-028-mlx-speculative-decoding.md`, especially the provider
   target/draft lifecycle, telemetry, request gating, and warm-swap sections.
5. `specs/SPEC-015-receipts.md` v0.4 strict receipt/usage sections.
6. `specs/SPEC-022-verified-model-settlement.md` for money-path boundaries.
7. Coordinator WS/canary code:
   - `phase4-coordinator/internal/ws/server.go`
   - `phase4-coordinator/internal/ws/messages.go`
   - `phase4-coordinator/internal/ws/canary_store.go`
   - `phase4-coordinator/internal/ws/canary_test.go`
8. Coordinator config/stats/operator surfaces:
   - `phase4-coordinator/internal/config/config.go`
   - `phase4-coordinator/internal/stats/`
   - `phase4-coordinator/internal/ws/admin_endpoints.go`
9. Provider WS/Tier-2/runtime code:
   - `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
   - `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift`
   - `phase3-binary/Sources/macprovider-cli/Tier2ProviderSession.swift`
   - `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
   - `phase3-binary/Sources/macprovider-cli/HTTPServer.swift`
   - `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift`
10. Receipt and prompt-hash code to prove no SPEC-015 mutation:
    - `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift`
    - `phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift`
    - coordinator/gateway/verifier receipt tests.

## 3. Hard Gates

1. Feature gate all runtime behavior behind a disabled-by-default coordinator
   flag such as `losslessness_probe.enabled` and a provider capability flag.
   Fixtures, parsers, validators, and tests may land unconditionally.
2. Do not reuse echo-canary pass/fail counters for losslessness verdicts.
   Reuse only scheduling, jitter, persistence, and sweep plumbing where it
   stays behaviorally separate.
3. Do not use `inference_request` Tier-2 carrier frames for probes. SPEC-029
   requires dedicated encrypted request/result carriers.
4. Do not emit SPEC-015 receipts for probe traffic. Provider work is
   non-billable.
5. Do not add `draft_artifact_binding`, losslessness status, probe digest, or
   spec-decode counters to SPEC-015 v0.4 receipts or `usage`.
6. Do not make model-authenticity or malicious-provider honesty claims. v0.1 is
   self-attested cooperative implementation-health evidence.
7. Do not display raw prompt text by default. Corpus prompts must be synthetic
   coordinator-owned material; buyer-origin material is prohibited.
8. Stochastic speculative decoding remains disabled unless a SPEC-028 rollout
   PR or decision-log entry approved by MacProvider SPEC Maintainers names the
   grid key, feature flag, allowed profiles, and rollback condition.

## 4. Implementation Slices

Implement slices in order. Each slice must include focused tests before moving
on.

### Slice 0 - Preflight, Fixtures, And Version Gates

What lands:

1. Implementation notes file, for example
   `specs/SPEC-029-IMPL-NOTES.md`, recording:
   - SPEC-029 status and commit hash used as source of truth;
   - whether implementation is locked or explicitly draft-authorized;
   - baseline test command results;
   - any intentionally deferred operator/deploy work.
2. Golden protocol fixtures under a stable path such as
   `phase4-coordinator/test/jcs_fixtures/spec029/`:
   - cleartext request outer envelope;
   - cleartext result outer envelope;
   - measurement payload;
   - provider-inconclusive payload;
   - Tier-2 encrypted carrier metadata fixture with deterministic test keys;
   - admission-blocked telemetry fixture;
   - grid-state telemetry fixture.
3. Cross-language JCS parity tests for request/result payload digests:
   Swift provider code and Go coordinator code must compute the same
   `probe_request_digest` and `probe_result_digest`.
4. A no-receipt/no-usage fixture proving losslessness fields are rejected from
   or absent in SPEC-015 v0.4 receipt and `usage` strict shapes.

Tests:

- Go and Swift digest parity.
- Fixture decode/encode round trip.
- SPEC-015 strict receipt/usage no-extra-field tests.
- Baseline:

```bash
cd phase4-coordinator && go test ./...
cd ../phase3-binary && swift test
cd ../phase5-gateway && go test ./...
cd ../phase7-verify && go test ./...
```

### Slice 1 - Coordinator State, Corpus, Calibration, And Math

Likely files:

- `phase4-coordinator/internal/ws/losslessness*.go` new files.
- `phase4-coordinator/internal/ws/server.go`
- `phase4-coordinator/internal/ws/messages.go`
- `phase4-coordinator/internal/config/config.go`
- `phase4-coordinator/internal/stats/migrations/` if durable storage is needed.
- `phase4-coordinator/internal/stats/` or admin surfaces for dashboard data.

Requirements:

1. Define typed structs/enums for:
   - `draft_admission_v1`;
   - profile key and grid key;
   - sampling profile;
   - corpus version and threshold version;
   - measurement positions and offline position-selection records;
   - calibration records;
   - probe request/result envelopes;
   - reason codes, statuses, operator action enum, profile/grid states;
   - telemetry events and evidence retention references.
2. Implement coordinator-owned `target_generation`:
   - monotonic per `(provider_id, assigned_id, model_id)`;
   - starts at `1`;
   - increments on target hash change, completed warm-swap, runtime reload,
     same-hash reload, or reconnect where continuity cannot be proven;
   - invalidates stale profile/grid state across generation boundaries.
3. Implement profile/grid state machines exactly:
   - profile states: `unknown`, `pending`, `pass_fresh`, `warn`,
     `inconclusive_retryable`, `blocked`, `disabled`, `expired`;
   - grid states: `all_profiles_fresh`, `not_ready`;
   - profile freshness TTL is 24h;
   - no cross-temperature aggregation.
4. Implement the closed `operator_action` enum and optional label. Tests must
   fail if new reason codes use prose strings instead of enum values.
5. Implement canonical median: lower middle after ascending sort, index
   `(n - 1) / 2` with integer division.
6. Implement distribution validation:
   - finite probabilities/tail in `[0,1]`;
   - tokenizer-valid non-negative token IDs;
   - `support_selection_v1`;
   - `normalization_basis = "full_distribution"`;
   - `sampler_stage = "post_processors_post_sampling_profile_next_emitted_token"`;
   - plain/spec top-K sorted by probability desc, token-id asc tie;
   - shared support equals numeric-ascending union;
   - support probabilities exactly cover support IDs;
   - sum plus tail equals `1.0` within `1e-5`;
   - support length `K..2K` unless vocab smaller;
   - high-entropy plain-tail floor computed from offline plain probabilities
     over actual returned `support_token_ids`, not a K-only floor.
7. Implement TV interval math:

```text
support_diff = sum_{token in support_token_ids} |p_plain(token) - p_spec(token)|
tv_lower = 0.5 * (support_diff + |plain_tail_mass - spec_tail_mass|)
tv_upper = 0.5 * (support_diff + plain_tail_mass + spec_tail_mass)
```

   Pass decisions use `tv_upper`; quarantine decisions use `tv_lower`.
8. Implement K retry and tail handling:
   - default `K=64`;
   - retry at `K=256` when tail high, warning threshold hit, or within
     `0.005` of quarantine threshold;
   - failed required retry => `inconclusive:k_retry_failed`;
   - `K=256` tail > `0.005` => `inconclusive:tail_mass_high`.
9. Implement calibration gating:
   - no confirmed quarantine counter without accepted calibration for
     `(target_model_hash, draft_artifact_binding, sampling_profile,
     corpus_version, threshold_version)`;
   - baseline max/median `tv_upper` rules from SPEC-029;
   - missing/failing calibration maps to `blocked:calibration_missing`.
10. Implement counters exactly:
    - confirmed quarantine counter;
    - rolling 24h abusive-inconclusive event log;
    - greedy-control failure counter separate from abusive-inconclusive count;
    - `pass` clears only consecutive quarantine candidates, not rolling abuse.

Tests:

- AC-5 through AC-15 coordinator unit/state-machine tests.
- Boundary tests for `Q,Q`, `Q,W,Q`, `Q,inconclusive,Q`, `Q,pass,Q`.
- Valid shared-support case where support length > K and plain tail is below
  plain top-K-only tail but equals expected tail outside returned union.
- Missing calibration and failing calibration tests.
- Same-hash reload/reconnect/target-generation tests.

### Slice 2 - Coordinator Scheduling, Transport, Replay, And Telemetry

Likely files:

- `phase4-coordinator/internal/ws/server.go`
- `phase4-coordinator/internal/ws/relay.go`
- `phase4-coordinator/internal/ws/messages.go`
- `phase4-coordinator/internal/ws/losslessness*.go`
- `phase4-coordinator/internal/stats/` or admin/dashboard packages.

Requirements:

1. Add feature-gated `losslessness_probe_v1` scheduler:
   - 60-minute cadence per provider/model/draft key;
   - rotate one stochastic profile per slot;
   - full default stochastic grid plus greedy control within 24h for eligible
     ready keys;
   - one concurrent losslessness probe per provider;
   - 60s execution timeout;
   - exponential backoff for retryable inconclusive results, capped at 6h.
2. Issue only authenticated provider-control probes on accepted provider WS
   sessions. Reject duplicate `probe_id`, nonce, and request digest.
3. Build cleartext request/result envelopes with `type` discriminator and
   required `payload`.
4. Add Tier-2 dedicated carriers:
   - `losslessness_probe_v1.encrypted_request`;
   - `losslessness_probe_v1.request_plaintext`;
   - `losslessness_probe_v1.encrypted_result`;
   - `losslessness_probe_v1.result_plaintext`.
   Do not tunnel through `inference_request`.
5. Enforce bounds:
   - nonce >= 128 bits;
   - `expires_at` <= 120s after issuance;
   - `K` only 64 or 256;
   - <= 4 prompts;
   - <= 8 stochastic measurement positions;
   - request/result digest binding;
   - audit logging of request digest, result digest, auth principal, issuance
     time, result time, final reason.
6. Implement telemetry:
   - `probe_result`;
   - `admission_blocked`;
   - `grid_state`;
   - `result_kind` / `metric_kind` nullability rules;
   - TV metrics required only for stochastic measurement outcomes;
   - greedy fields required only for greedy controls;
   - timeout/no-result outcomes do not fake result digests or TV metrics;
   - retained evidence digest/ref fields and 30-day default TTL.
7. Implement operator/dashboard state:
   - profile matrix fields;
   - grid row fields;
   - `not_ready_profiles`;
   - SPEC-028 rollout approval status/ref/feature flag/allowed profiles/
     rollback condition.

Tests:

- AC-1 protocol fixture including cleartext + Tier-2 carriers.
- Replay rejection for duplicate IDs/nonces/digests.
- Timeout/no-result telemetry nullability.
- Provider-inconclusive telemetry nullability.
- Greedy-control telemetry.
- Grid-state event/dashboard snapshot tests.
- Proof that losslessness counters do not mutate echo-canary readiness or
  sanctions.

### Slice 3 - Provider Draft Admission And Probe Carrier Handling

Likely files:

- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
- `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift`
- `phase3-binary/Sources/macprovider-cli/Tier2ProviderSession.swift`
- `phase3-binary/Sources/macprovider-cli/ConfigApplier.swift`
- `phase3-binary/Sources/MacProviderCore/Config.swift`

Requirements:

1. Add provider-side config/capability for losslessness probes. Default off
   unless the coordinator feature gate and provider config allow it.
2. Create and send `draft_admission_v1` through authenticated provider-control
   channel:
   - provider/assigned/model/target identity;
   - target generation as issued by coordinator;
   - draft model ID;
   - draft artifact SHA-256;
   - tokenizer identity;
   - compatibility check digest;
   - draft generation;
   - created/expiry.
3. Increment `draft_generation` whenever draft artifact, tokenizer identity,
   compatibility check output, or restart-without-continuity changes.
4. Echo coordinator-issued target generation and actual target/draft identity
   per measured position.
5. Implement cleartext and Tier-2 dedicated carrier handlers for probe request
   and result. Reject unknown/malformed carriers without affecting active buyer
   inference.
6. Implement result variants:
   - `measurement`;
   - `provider_inconclusive` with allowed reason codes only.
7. Do not emit SPEC-015 receipts for probe traffic. Do not attach probe fields
   to buyer responses, heartbeat, or receipt material unless SPEC-029
   explicitly permits the field.
8. Warm-swap handling:
   - explicit in-flight target/draft generation change =>
     `inconclusive:model_swap`;
   - identity mismatch without declared swap =>
     `inconclusive:identity_mismatch`;
   - draft-load failure after target swap =>
     `inconclusive:draft_unavailable` or
     `inconclusive:draft_identity_unbound`.

Tests:

- Draft admission fixture and generation increment tests.
- Cleartext carrier decode/encode tests.
- Tier-2 carrier AAD/plaintext tests with deterministic keys.
- Provider-inconclusive result variant tests.
- No receipt/no heartbeat/no buyer-response pollution tests.
- Warm-swap and identity mismatch tests.

### Slice 4 - Provider Measurement Hook And Compact Distribution Output

Likely files:

- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
- new provider files such as `LosslessnessProbeRuntime.swift`.
- Swift tests under `phase3-binary/Tests/macprovider-cliTests/`.

Requirements:

1. Identify and document the exact Swift generation/sampler hook that
   represents:

```text
post_processors_post_sampling_profile_next_emitted_token
```

   This is AC-3 and must be in code comments or implementation notes.
2. Add a provider measurement path that is separate from buyer inference:
   - synthetic coordinator prompts only;
   - teacher-forced exact measurement positions;
   - no billing/receipt side effects;
   - no buyer-visible output.
3. For every stochastic position:
   - compute plain full next-token distribution at capture point;
   - compute spec full next-token distribution at capture point;
   - select plain/spec top-K by probability desc, token-ID asc;
   - compute numeric-ascending shared support union;
   - report full-distribution probabilities over shared support for both paths;
   - report tail masses outside shared support;
   - include tokenizer identity, context hash, target/draft identity,
     `normalization_basis`, `sampler_stage`, and optional trace counters.
4. For greedy control:
   - compare token IDs for every requested position;
   - return greedy metric fields, not TV fields.
5. Implement position mismatch detection: dropped, substituted, or extra
   positions => `inconclusive:position_mismatch`.
6. If upstream MLX APIs do not expose the required full-distribution capture
   point, STOP and surface a SPEC/implementation blocker. Do not fake compact
   probabilities from sampled-token histograms.

Tests:

- Deterministic top-K ordering and tie-break tests.
- Shared-support union and tail-mass tests.
- Missing/wrong sampler-stage test.
- Context-hash mismatch test.
- Greedy control pass/fail tests.
- Position mismatch tests.
- Provider-inconclusive path when sampler hook is unavailable.

### Slice 5 - SPEC-028 Rollout Consumer Gate And Privacy

Likely files:

- `phase4-coordinator/internal/ws/losslessness*.go`
- `phase4-coordinator/internal/stats/` or dashboard/admin code.
- SPEC-028 rollout config/feature flag code if already present.

Requirements:

1. Implement the SPEC-029 evidence side of the SPEC-028 rollout gate:
   - `all_profiles_fresh` required before stochastic speculative decoding can
     be enabled for a grid key;
   - no approval => operator action `request_spec028_rollout_approval`;
   - approved grid becomes `not_ready` => operator action
     `disable_stochastic_spec_decode`;
   - rollout consumer must disable stochastic spec decode for affected grid key.
2. If SPEC-028 rollout feature flag plumbing does not exist yet, implement
   only the losslessness evidence state and dashboard action; do not invent a
   production stochastic rollout bypass.
3. Retention/privacy:
   - 30-day default compact evidence retention;
   - encrypted-at-rest storage if evidence is retained;
   - raw prompt text hidden by default;
   - buyer-origin prompts rejected from corpus/admission.
4. Operator/dashboard aggregate views may summarize provider health but must
   not collapse sanctioning/eligibility across temperatures, target
   generations, draft generations, corpus versions, or threshold versions.

Tests:

- AC-11, AC-17, AC-18, AC-19 where automatable.
- Buyer-origin prompt rejection.
- Raw prompt hidden by default.
- No cross-temperature aggregation.
- Rollout approval absent/present/superseded/revoked dashboard rows.

## 5. Acceptance Criteria Mapping

The implementation is not complete until every SPEC-029 AC is covered:

- AC-1: protocol fixtures, auth/session binding, nonce, expiry, digests,
  replay, timeout, bounded K, cleartext and Tier-2 carriers.
- AC-2: draft admission fixture and no heartbeat/receipt boundary.
- AC-3: provider sampler hook design and tests.
- AC-4: no SPEC-015 receipt/usage mutation.
- AC-5 through AC-9: distribution validation, TV interval, support-selection,
  K retry, tail handling, calibration.
- AC-10 through AC-15: profile/grid state, disablement, rolling abuse, reason
  codes, operator actions, warm-swap/generation.
- AC-16: corpus planning and exact-profile high-entropy quota.
- AC-17: dashboard snapshot.
- AC-18: privacy/corpus tests.
- AC-19: maintainer approval artifact. If AC-19 is not available during
  implementation, keep production feature gates disabled and record the gap in
  implementation notes.

## 6. Audit-Loop Discipline

After each slice, write or update audit prompts under `specs/` using house
names, for example:

- `specs/AUDIT_SPEC_029_v0_1_IMPL_STEP_1_CODE_PROMPT.md`
- `specs/AUDIT_SPEC_029_v0_1_IMPL_STEP_1_SECURITY_PROMPT.md`
- `specs/AUDIT_SPEC_029_v0_1_IMPL_STEP_1_ARCHITECT_PROMPT.md`
- `specs/AUDIT_SPEC_029_v0_1_IMPL_STEP_1_ADVERSARIAL_PROMPT.md`
- `specs/AUDIT_SPEC_029_v0_1_IMPL_STEP_1_PRODUCT_PROMPT.md`

Run the required lanes:

1. Codex code lane.
2. Codex security lane.
3. Codex architect lane.
4. Claude subscription CLI adversarial verification lane.
5. Claude subscription CLI product design critic lane.

If Claude CLI is unavailable, record the exact failure and use Codex fallback
lanes for adversarial and product perspectives; do not pretend Claude ran.

Loop until every lane reports 0 Critical / 0 High / 0 Medium findings. Skip a
lane in a rerun once it has returned 0 C/H/M for that slice unless files or
behavior it audited changed materially.

Commit an audit rollup such as:

- `specs/SPEC-029-IMPL-STEP_1-audit.md`
- `specs/SPEC-029-IMPL-FULL-audit.md`

## 7. Required Test Commands

Run the narrowest relevant tests after each slice, then the full matrix before
final:

```bash
cd phase4-coordinator && go test ./internal/ws ./internal/config ./internal/stats ./internal/buyer
cd ../phase3-binary && swift test
cd ../phase5-gateway && go test ./...
cd ../phase7-verify && go test ./...
```

Before final:

```bash
git diff --check
cd phase4-coordinator && go test ./...
cd ../phase3-binary && swift test
cd ../phase5-gateway && go test ./...
cd ../phase7-verify && go test ./...
```

If a full test cannot run, document the blocker and run the next-best targeted
suite. Do not claim completion without fresh validation evidence.

## 8. Output Expectation

Deliver a complete implementation branch with:

- feature-gated coordinator and provider code;
- protocol fixtures and cross-language digest parity tests;
- durable or well-scoped in-memory state with explicit migration/config if
  persistence is required;
- operator/dashboard telemetry surfaces;
- no SPEC-015/SPEC-022/buyer API mutation;
- no production stochastic rollout without SPEC-028 approval;
- slice audit records converged to 0 C/H/M;
- final implementation notes listing commands run, known gaps, and AC mapping.

No TODO stubs in production paths. If an item is intentionally deferred because
SPEC-029 remains draft or AC-19 approvals are absent, keep the feature gate off,
record the deferral in implementation notes, and add tests proving the unsafe
path stays disabled.

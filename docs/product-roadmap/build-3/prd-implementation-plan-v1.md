# Product Build 3 — PRD and Implementation Plan

Plan revision: `build3-plan-v1`
Plan status: awaiting independent adversarial approval
Repository/base: `Augustas11/macprovider@1d2c930bad81704dd0acc0322226725d8b64aceb`
Scope: production compute observations and first-job visibility for one explicit covered key, with no economic activation or enforcement

## Product result

A provider serving one explicitly supported MLX configuration can see a truthful, narrowly scoped compute-observation state and follow a real request through receipt persistence, billing-mirror ingestion, reward accrual, and app/portal presentation. Every surface states the evidence boundary, its freshness, and recovery action. Missing, stale, revoked, mismatched, or incomplete evidence produces `unknown`, `pending`, `expired`, `warn`, or `blocked` as defined by the governed contract; it never becomes confirmed idleness or current earning by inference.

This build prepares an observe-only production path. It does not activate settlement enforcement, MALIBU emissions, withdrawal execution, payments, epochs, or production rollout.

## Explicit covered key

Build 3 covers exactly this initial configuration:

| Dimension | Required binding |
| --- | --- |
| Catalog artifact | `mlx-community/Llama-3.2-3B-Instruct-4bit` |
| Canonical priced model | `meta-llama/llama-3.2-3b-instruct` |
| Artifact manifest SHA-256 | `e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90` |
| Runtime | Native bundled MacProvider MLX runtime, exact release/build identity |
| Sampler stage | `post_sampler_probabilities` |
| Probe profile | `build3_llama32_3b_post_sampler_v1` |
| Probe behavior | Fixed prompt corpus, tokenizer identity, seed where meaningful, sampler parameters, token positions, probability encoding, and numeric tolerance defined by the profile manifest |
| Hardware class | One named Apple Silicon class established by calibration; no class is assumed before calibration |
| Provider lifecycle | Provider ID, current session, coordinator-issued model generation, and request-start capture |
| Policy materials | Corpus digest, reference-set digest, threshold digest, calibration digest, policy revision, and expiry |

The profile name is a contract label, not evidence. Its manifest must contain the exact tokenizer, prompt bytes, chat template, context construction, sampler processors, probability precision, target positions, timeouts, and resource ceilings used by both reference producers and providers.

Any change to one dimension creates a different covered key and returns the new key to `unknown` until independently referenced and calibrated. Unsupported models and nonmatching hardware/runtime/profile combinations remain explicitly uncovered.

## User journeys

### Journey A — provider becomes observable

1. The provider prepares and admits the exact catalog artifact through existing trusted model identity paths.
2. Coordinator creates a non-billable, bounded probe lease for the current provider session and model generation.
3. The Swift runtime executes the overt profile and returns only the governed probability observations plus binding metadata. It cannot choose its own key, reference, threshold, or generation.
4. Coordinator validates the lease, session, generation, covered key, bounds, replay identifier, and result schema before durable ingestion.
5. A durable evaluator compares the result with the currently approved, unexpired reference and calibration policy.
6. Provider and operator surfaces show the sanitized state, evidence time, expiry, coverage key, and exact limitation copy. Raw prompts, logits, provider secrets, internal thresholds where policy forbids publication, and other providers' data are not exposed.

### Journey B — first paid job visibility

1. A paid request captures the immutable model/artifact/runtime/profile/hardware/generation observation context at request start.
2. UI shows “request observed” or “receipt pending”; this stage is not current earning and cannot accrue a reward.
3. Receipt persistence and verification complete. Invalid, missing, late, or mismatched receipts remain pending/held/excluded under their existing contracts.
4. An immutable billing change event is mirrored into the reward database. Its source generation and event sequence establish completeness through a displayed source time.
5. Reward accrual consumes the verified request facts idempotently. Build 3 does not enable an emission schedule; tests use the existing explicitly configured test accrual path.
6. Coordinator returns separate provider-earnings freshness, billing-mirror freshness, compute-observation freshness, earning state, withdrawal state, payment availability, balances, and activity cursor.
7. Swift app and provider portal present the same stage and closed reason. Last-known balances remain labeled with their source timestamp when a newer source is unavailable.

### Journey C — evidence degrades

1. Policy, reference, calibration, profile, catalog identity, runtime build, hardware class, session generation, or explicit operator revocation changes.
2. The exact affected covered key is invalidated immediately and durably. An in-flight lease cannot restore a revoked generation or policy revision.
3. New reward projections show the observation as expired/unknown/blocked as appropriate. Historical ledger entries and eligible balances remain intact and independently labeled.
4. UI explains whether the safe recovery is waiting for a scheduled probe, restoring the supported runtime/artifact, reconnecting, adding a wallet, refreshing stale data, or contacting support.

### Journey D — portal activity recovery

1. Portal loads the first reward-activity page independently from summary state.
2. User requests older pages with the opaque cursor. Duplicate page requests are harmless; entries deduplicate by audit ID.
3. Activity failure leaves balances and eligibility intact, marks activity stale/unavailable, and offers retry.

## Ownership boundaries

| Owner | Responsibility | Explicit boundary |
| --- | --- | --- |
| SPEC-036 / compute-integrity package | Covered-key schema, probe/result contracts, policy lifecycle, evaluation, sanitized status, request-start observation capture | Does not define reward economics, prove physical computation generally, or authorize enforcement. |
| Coordinator WebSocket/runtime control | Lease scheduling, authenticated provider/session delivery, generation binding, cancellation, replay rejection, resource limits | Provider messages cannot create policy/reference/calibration or select pricing. |
| Swift provider runtime | Execute the exact supported profile and return bounded results | Cannot self-assert verified state, hardware class, artifact identity, reference, threshold, or reward status. |
| Billing/request log | Immutable request-start context, receipt settlement facts, billing change journal | Does not decide reward emission or UI copy. |
| Billing mirror | Lossless ordered change replication and explicit completeness watermark | Does not reinterpret settlement or claim real-time state after its source timestamp. |
| SPEC-021 / rewards | Idempotent accrual, independent earning/withdrawal/payment states, reward projection | Must consume request-bound evidence; current provider status cannot upgrade old work. No activation in this build. |
| SPEC-014 / provider portal | Truthful parity presentation, pagination, last-known/freshness states, recovery actions | Cannot infer current earning or idleness from an absent row, zero balance, pool readiness, or projection time. |
| Swift Malibu app | Same presentation contract as portal with independent refresh domains | Activity and projection failures cannot erase last-known balances. |
| Operators/governance | Approve reference producers, calibration, threshold/policy revisions, revocation, production qualification | Manual approval is recorded and auditable; it cannot bypass missing evidence or turn observe into enforce. |

## Dependency graph

```text
SPEC-036 covered-key + probe/status contract
  ├─> independent references + calibration policy
  ├─> durable observation store and revocation journal
  └─> coordinator lease/Swift MLX probe transport
          └─> sanitized live status source
                  └─> request-start immutable observation capture

receipt persistence + settlement verification
  └─> immutable billing change journal
          └─> mirror apply + completeness watermark
                  └─> idempotent test accrual

request-bound observation + receipt + mirror watermark + ledger projection
  └─> governed reward read model
          ├─> Malibu Swift app
          └─> provider portal + paginated activity
```

Implementation order follows this graph. Portal/app work may be developed against frozen fixtures after the response contract is approved, but acceptance cannot bypass upstream evidence.

## Feasibility gates before contract commitment

The current Swift provider cannot produce the required full-distribution observation. The adjacent SPEC-030 losslessness handler always returns `inconclusive:unsupported_sampler` through `LosslessnessProbeRuntime.providerInconclusiveForUnavailableSampler`, and SPEC-036 requires its own settlement-bearing wire framing even where it inherits SPEC-030 math and transport policy. Before approving runtime architecture:

1. Build a read-only/throwaway Swift feasibility spike against the repository's selected MLX Swift APIs for the exact model. Demonstrate extraction of the defined `post_sampler_probabilities` at the requested positions without altering generated output.
2. Record API provenance, tensor shape/dtype, normalization point, processor order, synchronization/copy cost, peak memory, cancellation behavior, and compatibility with the current runtime build.
3. Confirm the hook can be exposed through a clean-room repository-owned interface without inspecting d-inference source and without a new dependency. If a dependency change is required, stop for explicit dependency/governance review.
4. Compare the spike output across two independent executions using a provisional corpus. The result can validate feasibility and numeric encoding; it cannot approve references, calibration, or threshold.
5. If the hook is unavailable, unstable, changes output, breaches the resource ceiling, or cannot be implemented within repository/dependency rules, mark Slices 1–3 blocked. Continue only contract, mirror, and truthful UI work that does not imply observation availability.

The spike is disposable evidence and must not become a production bypass. Production code begins only after the exact profile and owned interface are approved in SPEC-036.

## Normative contract changes before runtime implementation

### 1. SPEC-036 covered-key and lifecycle contract

Update SPEC-036 and conformance mappings before implementing runtime changes:

- Add a versioned `compute_observation_policy.v1` identifying the exact covered key and policy materials.
- Define reference producer identity, provenance, signature, independence claim, captured runtime/artifact/hardware/profile, production time, expiry, and revocation. Require at least two fresh approved reference events from independently controlled execution environments for every positive covered key. A checked-in fixture may test parsing but cannot satisfy this prerequisite.
- Define a versioned calibration report with hardware matrix, sample counts, warm/cold handling, numeric precision, divergence distribution, chosen threshold, false-positive/false-negative analysis, and independent approval.
- Define probe lease/result envelopes, maximum prompts/positions/probability entries/bytes/duration/concurrency, non-billable semantics, cancellation, replay key, and provider/session/generation bindings.
- Define durable state transitions, monotonic policy revision, tombstones, expiry, and invalidation triggers. Unknown enum values fail closed.
- Define sanitized provider/operator fields and stable disclosure copy. Raw corpus content and raw probability payloads remain operator-restricted.
- Preserve `observe` as the only reachable Build 3 mode. Enforce remains rejected unless all existing SPEC-036 and SPEC-022 prerequisites are separately approved and qualified.

### 2. Billing change journal and mirror completeness contract

Update the governing billing/stats/rewards specs before schema work:

- Add immutable `billing_projection_events` in the source SQLite database. Every insert or settlement-relevant update to a request-credit row appends a monotonically increasing event sequence in the same transaction.
- Define source identity/generation. Replacing or restoring the source database changes generation and forces target rebootstrap; sequence alone cannot bridge generations.
- Mirror consumes event sequence, upserts the referenced request-credit state idempotently, and atomically persists target `applied_event_sequence`, source generation, `observed_source_max_sequence`, `source_observed_at`, and `last_success_at`.
- Define `complete_through`: true only when generation matches and applied sequence reaches the source maximum observed in the same read snapshot. It means complete through `source_observed_at`, not proof that no event happened later.
- Define a strict freshness budget. UI language is “complete through <time>” or “updates delayed”; it never says confirmed idle based only on absence.
- Keep bounded overlap and sweep as repair mechanisms. They are not the authority for freshness.

### 3. Reward projection contract

Update SPEC-021 and transport owners:

- Add independent `earning_state`, `withdrawal_state`, and `payment_state` with closed enums and closed reason codes. `payment_state` remains `unavailable` for MALIBU in Build 3.
- Include separate freshness envelopes for provider earnings, reward ledger/projection, compute observation, and billing mirror; include last-known timestamps and `complete_through` where applicable.
- Map compute state only for the exact request-start covered key. A positive current provider status cannot upgrade historical work and a later revocation cannot rewrite a settled historical observation; policy may hold future economic use through an explicit ledger event.
- `unknown`, unreadable, stale, mismatched, incomplete mirror, or uncovered state cannot produce “earning now.” Existing eligible balance and withdrawal eligibility remain independent.
- Availability of an observation does not enable reward accrual. The production feature gate and emission configuration remain off.

### 4. Provider presentation contract

Update SPEC-014 and Swift-facing schemas:

- Standardize reason-code vocabulary and required recovery actions.
- Replace “MALIBU is available to withdraw” with “MALIBU balance is eligible for withdrawal; payment execution is unavailable.”
- Expose activity as a separately refreshable cursor-paginated resource. Activity failure cannot overwrite summary state.
- Prohibit inferred idleness/current earning from missing work, zero balance, pool readiness, projection-generation time, or stale source data.

## Data model and migration plan

All migrations are additive first and reversible by disabling consumers. No destructive downgrade is required.

1. **Coordinator observation tables**: policy revisions, covered keys, reference events, calibration/threshold approvals, probe leases, probe results, evaluated events, current windows, and revocation tombstones. Store immutable events plus a derived current snapshot. Uniqueness covers policy revision and replay key. Retain raw evidence only under the operator retention policy; public status is derived and sanitized.
2. **SQLite billing event journal**: add the immutable event table and transactional triggers/call-site inserts for every request-credit mutation. Backfill one snapshot event per existing row under a new source generation. Verify row counts and content digests before declaring bootstrap complete.
3. **Postgres mirror state**: add source generation, applied/observed event sequences, source-observed time, last-success time, bootstrap state, and failure reason. Preserve existing request-ID cursor during compatibility mode.
4. **Reward response**: add fields while retaining current fields for one compatibility window. Old clients keep conservative `unknown` behavior. New clients reject unknown closed-enum values into an unavailable state rather than optimistic fallback.
5. **Activity endpoint**: retain opaque `before_id`; add stable page metadata if needed without changing ordering. Cursor reuse is idempotent.

Migration safety:

- Dry-run audits compare journal-derived target rows with the current overlap/sweep mirror.
- A dual-read shadow period logs differences without affecting user-visible earning state.
- A source-generation mismatch sets mirror unavailable and requires explicit rebootstrap.
- Rollback disables probe scheduling, live source consumption, and new response use; old schema columns/tables remain inert until a later cleanup PR.

## Implementation slices

### Slice 0 — governance and fixtures

- Complete the sampler-hook feasibility gate above and record its result. A passing spike proves implementability only.
- Update SPEC-036, SPEC-021, SPEC-014, the billing/stats owner spec, `AUTHORITY.json`, and `CONFORMANCE.json` as required.
- Add signed schema fixtures and negative vectors for policy, references, calibration, leases, results, status, mirror watermark, and reward response.
- Obtain plan reapproval if review changes architecture, contracts, scope, or test strategy.

### Slice 1 — durable observe-only source

- Implement durable observation repositories and immutable audit events.
- Add explicit policy install/revoke/read operations with authenticated operator authorization and bounded JSON parsing.
- Materialize sanitized status from durable events; inject the concrete source in coordinator startup only when `compute_observation.enabled=true`.
- Default off. A missing/unreadable store returns unavailable; it never silently falls back to in-memory verified state.

### Slice 2 — provider probe transport

- Add versioned coordinator-to-provider lease and provider-to-coordinator result/NAK messages.
- Bind lease to authenticated provider/session, generation, key, policy revision, nonce, issued/expiry times, and resource ceilings.
- Implement one concurrent probe per provider, queue limits, cancellation on disconnect/generation change/revocation, deadline cleanup, and replay rejection.
- Add Swift MLX execution for the exact profile through the approved repository-owned interface proven by the feasibility gate. Extract the governed post-sampler probability vector without changing the normal output path; do not inspect or reuse d-inference source.
- Keep probes overt, non-billable, rate-limited, and lower priority than paid work. Record cancellations and failures without labeling the provider idle.

### Slice 3 — evaluation, expiry, and status

- Validate result bounds before storage and evaluation.
- Evaluate against both currently approved references and the calibrated threshold. Define a conservative combination rule in SPEC-036; disagreement, missing source, or stale evidence cannot yield verified.
- Advance rolling windows only for matching generation/policy/key. Persist expiry and revocation tombstones.
- Publish sanitized provider/operator status with evidence timestamps, expiry, full digest bindings, coverage label, and `StatusCopyV1`-equivalent disclosure.
- Add metrics and audit logs listed below.

### Slice 4 — authoritative mirror watermark

- Add transactional billing events and source generation.
- Teach the mirror to consume events and atomically persist completeness state.
- Shadow-compare with current overlap/sweep ingestion, exercise delayed settlement updates, then switch the reward freshness source behind a default-off flag.
- Preserve sweeps for reconciliation and alarm on divergence.

### Slice 5 — governed reward projection

- Add observation and mirror-watermark dependencies to `BuildProviderRewardProjection`.
- Derive compute state from the request-start covered key; derive work recency only when the mirror is complete through a fresh source observation.
- Return independent earning, withdrawal, and payment states plus freshness/last-known fields.
- Keep emission and payment gates off. Existing eligible balances remain visible; no production reward amount changes are authorized.

### Slice 6 — Swift app and provider portal parity

- Update decoders for additive fields and conservative unknown-enum handling.
- Show request/receipt/mirror/accrual/presentation stage, observation coverage/freshness, source completeness time, and actionable recovery.
- Preserve independent USDC and MALIBU freshness plus last-known values.
- Replace misleading portal withdrawal language and remove idle inference.
- Add portal cursor pagination, retry, deduplication, and independent activity freshness matching the Swift behavior.

### Slice 7 — integration and qualification harness

- Extend integration harness for the full local service chain using governed deterministic fixtures.
- Add a physical-Mac journey runner that records chip, RAM, OS, Swift/runtime version, app/CLI version, model/artifact digest, profile/policy/reference/calibration digests, request/receipt IDs, mirror watermark, accrual ID, UI snapshots, and exact commands without secrets.
- Run actual MLX inference for the covered model. A deterministic Swift fixture is supplementary only.
- Produce a signed acceptance bundle. Production deployment, enforcement, and economics remain separate operator gates.

## Observability

Metrics use bounded labels; provider/request identifiers belong in restricted logs, not metric labels.

- Probe leases issued, accepted, cancelled, timed out, rejected, replayed, and resource-rejected.
- Probe execution/evaluation duration and queue depth.
- Current status counts by policy revision, covered key digest, hardware class, and closed state.
- Reference/calibration age, expiry horizon, revocation count, and source disagreement.
- Billing journal append failures, event lag, generation mismatch, reconciliation divergence, bootstrap state, `source_observed_at`, and `last_success_at`.
- Receipt-pending age, mirror-pending age, accrual-pending age, idempotency conflicts, and projection source age.
- App/portal typed endpoint failures and activity pagination failures without personal data.

Alerts:

- Any attempted positive state without two fresh approved independent references.
- Any status surviving a generation/policy/reference/profile/runtime/artifact revocation.
- Any billing mutation lacking a journal event.
- Mirror generation mismatch, stale completeness, or journal-versus-sweep divergence.
- UI reporting current earning/idle while a required source is stale/unavailable.

## Compatibility and failure recovery

- Old providers ignore or NAK the new message type and remain uncovered; they are not disconnected from plaintext serving solely for lacking Build 3 observation support.
- Old app/portal versions retain conservative unknown behavior from existing fields.
- Coordinator restart reconstructs current observation state from durable events; it does not mint a fresh positive state.
- Provider reconnect creates a new session binding. Old leases/results are rejected.
- A profile, artifact, runtime, hardware class, or generation change cancels outstanding leases and invalidates positive current state.
- Delayed receipts append later billing events and eventually reconcile idempotently.
- If reference/calibration or mirror source becomes unavailable, display last-known values with timestamps and stop claiming current earning; do not erase ledger balances.
- Operators can disable scheduling and source consumption independently. Revocation remains effective while scheduling is disabled.

## Hardware and external prerequisites

Local implementation tests can use bounded fixtures and a supported smaller Apple Silicon Mac. Acceptance for this build requires:

- A physical Apple Silicon Mac capable of loading the exact 3B 4-bit artifact with sufficient headroom for normal service plus the bounded probe.
- At least two independently controlled reference execution environments for the exact covered key and one representative calibration cohort for the named hardware class.
- Actual MLX inference through the production Swift provider path, not a mock backend.
- Xcode execution for the Malibu app and a real browser run for the provider portal against the same journey state.
- Available coordinator, billing SQLite, Postgres mirror/rewards, and gateway/services needed by the journey. Docker-dependent evidence requires a working Docker runtime.
- Operator review of captured evidence and explicit separate decisions for deployment or production qualification.

Lack of these prerequisites is a named qualification blocker, never a passed criterion.

## Rollback

1. Disable probe scheduling; providers continue existing supported inference paths.
2. Disable live observation consumption in reward projection; compute returns conservative unknown while balances remain visible.
3. Disable journal-based freshness consumption and return mirror status unavailable; retain event writes for diagnosis or disable them only after verifying no consumer relies on them.
4. Serve compatibility response fields and prior app/portal behavior with corrected truthful copy retained.
5. Keep revocation tombstones and immutable audit events. Rollback cannot resurrect a revoked positive status.

## Explicit non-goals

- Provider-wide compute-integrity claims.
- Cryptographic proof of physical computation, confidential compute, hardware attestation, runtime-binary attestation, anonymity, or relay blindness.
- SPEC-036 enforce mode or changes to paid admission/settlement decisions.
- Economic activation, reward-rate changes, epochs, emission activation, withdrawals, payouts, hot-wallet work, or operator secrets.
- Adding support for another model/runtime/profile/hardware class.
- Production deployment, pool authorization, or Trusted Pool qualification.
- Inspecting d-inference source.

## Acceptance and stop conditions

Implementation may be called locally complete only when:

1. Every implementation slice has its governed contracts and targeted tests.
2. The full diff passes code, security, and architecture audits with zero Critical, High, or Medium findings.
3. Targeted and broader checks pass fresh with no skipped/zero-selected substitution.
4. Default-off behavior, rollback, and truthful unknown/stale presentation are proven.

Hardware acceptance requires a separate physical-Mac evidence bundle satisfying the test specification. Production qualification requires separate deployment/operator evidence. Neither may be inferred from local completion.

## Roadmap-to-step map

| Requested outcome | Implementation step | Verification |
| --- | --- | --- |
| One production observation path | Slices 0–3 | Contract vectors, durable restart tests, Swift real-model probe, physical journey |
| Actual probes and references/calibration | Slices 0, 2, 3 | Two-source provenance validation, calibration report, disagreement/stale/revoked tests |
| Generation/expiry/revocation | Slices 1–3 | Reconnect, warm swap, policy/profile/runtime/catalog change and tombstone tests |
| Sanitized publication | Slices 1, 3 | Schema/redaction tests and provider/operator authorization tests |
| Governed reward mapping | Slices 4–5 | Request-bound observation plus watermark tests; economics-default-off regression |
| Portal parity | Slice 6 | Browser tests for independent states, copy, last-known values, recovery, pagination |
| First-job visibility | Slices 4–7 | Request → receipt → mirror event → accrual → app/portal evidence |
| Delayed receipts/reconciliation | Slices 4, 7 | Existing-row update event, lag, restart, replay and sweep-divergence tests |
| Stale observations/profile changes/revocation | Slices 1–3, 5–7 | State invalidation and no-current-earning UI tests |

# Product Build 3 — PRD and Implementation Plan

Plan revision: `build3-plan-v2`
Plan status: awaiting independent adversarial approval
Repository/base: `Augustas11/macprovider@1d2c930bad81704dd0acc0322226725d8b64aceb`
Scope: production compute observations and first-job visibility for one covered key; no enforcement, economic activation, payment execution, or deployment

## Decision and gate boundary

If approved, this revision authorizes only a bounded feasibility and evidence-production slice. It does **not** authorize the durable runtime source, reward projection, app, or portal implementation. The feasibility output, exact pilot manifest, independent reference evidence, calibration report, migration inventory, and revised implementation/test plan must pass a second independent GPT-5.6 Sol adversarial gate with zero Critical, High, and Medium findings before Slices 1–7 begin. That second gate is unconditional even when the feasibility result matches this plan.

The explicit candidate locator is frozen for the feasibility slice:

| Dimension | Exact candidate value |
| --- | --- |
| Canonical model key | `meta-llama/llama-3.2-3b-instruct` |
| MLX artifact repository | `mlx-community/Llama-3.2-3B-Instruct-4bit` |
| Artifact revision | `7f0dc925e0d0afb0322d96f9255cfddf2ba5636e` |
| Artifact manifest SHA-256 | `e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90` |
| CLI build under inspection | `1.8.123` at repository commit `1d2c930bad81704dd0acc0322226725d8b64aceb` |
| `mlx-swift-lm` | `3.31.4`, revision `bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57` |
| `mlx-swift` | `0.31.4`, revision `dc43e62d7055353c7f99fa071a4e71d29dfddc44` |
| `swift-transformers` | `1.3.4`, revision `c21fdcde390313a6d98d8e33a346f2c3486c3ab0` |
| Proposed sampler stage | `post_sampler_probabilities` |
| Proposed profile ID | `build3_llama32_3b_post_sampler_v1` |

The repository name ending in `4bit` is not sufficient quantization identity. The exact production pilot remains `unfrozen` until the feasibility runner records the prepared artifact's closed quantization descriptor, including quantization method, bits, group size, quantized tensor inventory, config digest, weight-index digest, and full artifact-manifest digest. Hardware is likewise `unfrozen` until calibration establishes a closed class predicate. An `unfrozen` or partially populated pilot manifest is never loadable by production code and never yields observation availability.

The second-gate input must include a closed `compute_observation_pilot.v1` manifest with no null, wildcard, inferred, or `TBD` load-bearing fields:

- the candidate values above plus release artifact digest and code-signing identity;
- quantization descriptor and digest;
- OS build range, Metal/runtime identity, exact chip identifiers, RAM bounds, GPU-core predicate, and canonical `hardware_runtime_class_digest`;
- tokenizer files and digests, chat-template bytes and digest, prompt corpus bytes and digest, context construction, seed semantics, sampler processor order and parameters, selected positions, probability dtype/encoding/rounding, normalization and tolerance rules;
- prompt/position/K/byte/duration/memory/concurrency limits;
- corpus, two reference-event, golden-fixture, calibration, threshold, policy, and expiry digests;
- compatibility behavior for older CLI, unsupported hardware, missing Tier-2 capability, and profile mismatch.

A change to any load-bearing field creates a new manifest digest and returns that key to `unknown` until another full evidence cycle and gate passes.

## Product result

For the one finally approved pilot manifest, a provider can see a sanitized, narrowly scoped compute-observation state and trace a real request through immutable request-start observation capture, receipt persistence, billing projection, test-only reward accrual, app presentation, and portal presentation. Every surface separates current observation, historical request evidence, ledger balance, withdrawal eligibility, payment availability, and source freshness.

Missing, stale, revoked, mismatched, unreadable, incomplete, or uncovered evidence produces a closed conservative state. It never becomes confirmed idleness, current earning, broad provider integrity, or physical-computation proof by inference.

## Code-grounded starting point

| Outcome | Status at base | Evidence and implication |
| --- | --- | --- |
| Production observation owner | Missing | `internal/ws/compute_integrity_status.go` defines an injected read seam; `cmd/coordinator/main.go` does not inject it. `computeintegrity.Store` is in-memory. |
| Probe primitives | Partial | `internal/computeintegrity/probe.go` validates DTOs. There is no SPEC-036 scheduler/result ingestion or Swift probability extraction. Existing `LosslessnessProbeRuntime.providerInconclusiveForUnavailableSampler` returns unsupported. |
| Exact MLX hook | Blocked pending feasibility | `Tests/mlx-stage-spikeTests` proves staged Llama forward/argmax only. It may skip without a model and does not expose the post-sampler distribution. It cannot satisfy this build's feasibility criterion. |
| Request-start compute capture | Partial | `billing/settlement_compute_integrity.go` stores immutable enforce-mode captures in `settlement_compute_integrity_captures`, but insertion is not transactionally linearized with live observation revision and is not projected to rewards. |
| Mirror completeness | Missing | `stats/billingmirror/mirror.go` mirrors mutable `ledger_request_credits` by ID/overlap/sweep and lacks an immutable event payload, lineage chain, and authoritative completeness watermark. |
| Reward mapping | Partial | `rewards/read_model.go` has earning/withdrawal enums. `projection.go` and `wallet_status.go` hardcode compute unknown. There is no payment state or total multi-source mapping. |
| App/portal presentation | Partial | Swift preserves independent freshness in useful paths; portal still collapses states and has misleading withdrawal copy and incomplete activity pagination. |

## User journeys

### Provider becomes observable

1. Provider serves the exact approved pilot manifest and has an authenticated current session/model generation.
2. The shared provider-work scheduler issues a bounded, overt, non-billable probe lease through the carrier allowed for the negotiated session.
3. The Swift runtime executes the exact profile without changing normal generation output and returns only the bounded governed vector and bound identities.
4. Coordinator validates session, generation, pilot digest, nonce, replay key, limits, references, calibration, and policy before appending a durable observation event.
5. A sanitized status shows state, covered-key digest, evidence time, expiry, source freshness, limitation copy, and recovery action. Raw prompts, logits, probability payloads, internal thresholds, secrets, and other-provider data stay private.

### First job is traceable

1. Request start enters the money SQLite writer protocol and atomically reads the authoritative observation revision, rechecks expiry/coverage, and persists route plus immutable request observation capture.
2. Receipt/verdict/finality changes append new complete billing-projection snapshots in the same transactions as their authoritative mutations.
3. Mirror verifies the event hash chain and applies event payloads rather than reconstructing old state from mutable tables.
4. Test-only accrual consumes the request-bound event once. Production emission and payment gates remain off.
5. App and portal show the same request stage and independently sourced earning, balance, withdrawal, payment, and freshness states.

### Evidence degrades

1. Reference, calibration, threshold, policy, catalog, artifact, runtime, profile, hardware class, session generation, or operator revocation changes.
2. The affected revision becomes invalid under the durable event order. New request starts cannot capture its prior positive state.
3. Earlier captures remain immutable historical facts. A later revocation cannot rewrite them; any prospective hold is a separate governed ledger event.
4. UI shows the closed reason and recovery action without implying current earning or current idleness.

### Activity independently recovers

Summary, USDC, observation, MALIBU ledger, and activity refresh independently. Activity cursor replay deduplicates by audit ID. An activity failure preserves last-known summary and balances with their original timestamps.

## Ownership and trust boundaries

| Owner | Authority | Boundary |
| --- | --- | --- |
| SPEC-036 / observation package | Pilot schema, reference/calibration admission, probe evaluation, lifecycle events, sanitized status | Narrow drift observation only; cannot prove hardware/runtime honesty or activate settlement/rewards. |
| Shared provider-work scheduler | Buyer-first work ordering, aggregate/per-profile limits, carrier selection, cancellation/fairness | Cannot create evidence or pricing authority. |
| Swift runtime | Execute exact approved profile and return bounded measurement/inconclusive result | Cannot choose identity, class, references, threshold, state, pricing, or reward status. |
| Money SQLite (`cfg.Storage.DBPath`) | Observation event order, current observation materialization, request-start captures, receipts/verdicts/credits, immutable billing projection journal | One writer protocol owns linearization. Raw current provider assertions have no authority. |
| External lineage anchor | Detect SQLite rollback/fork and authorize an accepted source incarnation | Contains no secret and grants no economic state; missing/mismatch fails unavailable. |
| Postgres mirror | Verify and apply event payloads plus source lineage/completeness watermark | Cannot reconstruct an old event from current SQLite rows or infer currentness beyond `source_observed_at`. |
| SPEC-021 rewards | Idempotent test accrual and independent reward status | Consumes request-bound facts; production activation stays off. |
| SPEC-014 portal and Malibu app | Truthful presentation and recovery actions | Cannot recompute policy or collapse independent states. |
| Operators/SPEC Maintainers | Evidence approval, lineage rotation, qualification and revocation | Manual approval cannot replace evidence or enable excluded production actions. |

## Dependency graph and gates

```text
Gate A: this R2 plan approval
  -> feasibility runner + exact pilot manifest
  -> independent reference/golden-fixture/calibration evidence
  -> mutation inventory + migration rehearsal evidence
  -> unconditional Gate B: revised plan/test + exact digests, zero C/H/M
       -> SPEC changes and closed fixtures
       -> money-SQLite observation authority + request-start capture
       -> shared scheduler + Swift profile runtime
       -> evaluation/status
       -> immutable billing projection journal + restore-safe mirror
       -> total reward status API
       -> app/portal parity
       -> local diff audits
       -> physical acceptance
       -> separately authorized production qualification
```

Gate B cannot approve a positive pilot unless all reference and calibration evidence below exists. A failed sampler hook, missing evidence source, missing representative hardware, unbounded resource result, or migration inventory gap keeps downstream implementation blocked.

## Normative contracts required before implementation

### Exact pilot and evidence contract

SPEC-036 must add `compute_observation_pilot.v1` and retain its existing stronger predicates:

- two counted reference sources must differ simultaneously in approved operator authority, physical host plus power/network failure domain, and independently produced runtime-build/kernel provenance within the same calibrated numeric-equivalence class;
- each source must pass signed golden-distribution validation at admission and every refresh; the golden fixture is additional and never substitutes for any independence axis;
- every reference record binds source key/signature, host/fault-domain attestation, build/kernel provenance, artifact/catalog/tokenizer/profile/pilot equality, production time, expiry, revocation status, and golden-fixture validation digest;
- the calibration record freezes the named hardware class and class digest, known-good cohort membership/adjudication digest, exact warm/cold sample and measurement-position counts, tail-feasibility numerator/denominator/rate, divergence distributions, threshold derivation, false-quarantine numerator/denominator/rate against a predeclared budget, approval, and expiry;
- fixtures prove parsing only. Physical evidence and independent approval are required before positive availability.

The Build 3 mode remains `observe`. Existing SPEC-036 enforce activation prerequisites remain intact and unreachable through this build.

### Observation authority and request-start linearization

The authoritative observation tables live in the same money SQLite database as `settlement_route_snapshots` and `settlement_compute_integrity_captures`. The schema has:

- append-only `compute_observation_events` with monotonic `event_seq`, event type, expected prior revision, pilot/key/generation, canonical payload, payload digest, prior event digest, event digest, and commit time;
- `compute_observation_current` derived rows with `current_revision`, source event digest, state, evidence/expiry times, and all pilot/reference/calibration/policy digests;
- immutable `request_compute_observation_captures` for observe-mode informational/reward evidence, separate from existing enforce settlement captures;
- revocation tombstones and retained sanitized audit metadata.

All observation writes, billing-projection writes, and covered request starts use one process-independent lineage-file `flock`, then `BEGIN IMMEDIATE`, in that order. No code may take the SQLite write transaction and then the lineage lock. Under the transaction:

1. Observation install/evaluate/revoke appends an event only when `current_revision` equals the supplied predecessor and materializes the next revision in the same transaction. A stale evaluator loses the CAS and cannot resurrect a tombstone.
2. Covered request start reads `compute_observation_current`, uses one transaction-captured UTC time, re-evaluates reference/threshold/window/catalog/profile/generation expiry, and inserts route snapshot plus applicable observation capture in the same transaction.
3. Whichever transaction commits first defines the revocation/request-start race. A request committed first keeps that historical capture; a revocation committed first forces the request to capture revoked/expired/unknown. There is no cross-database best-effort read.
4. Restart validates or deterministically replays the event chain into the materialized rows. A digest/revision mismatch makes the source unavailable. Restart never extends freshness.

Crash/fault tests cover every boundary: before event append, after append before materialization, before commit, after commit before lineage-anchor advancement, stale evaluator retry, request-start/revocation orderings, and restart during replay.

### Immutable billing projection journal

`billing_projection_event.v1` is a canonical immutable envelope appended in the same SQLite transaction as every source mutation that can change reward projection. The implementation inventory must enumerate and convert every mutation call site for route snapshot, observe/enforce compute capture, receipt arrival, receipt verification/verdict/finality, privacy/reward exclusion, quarantine/resolution, token/credit values, and reversal/void. A source mutation without its new complete event snapshot is a transaction failure.

Each event carries source incarnation, sequence, previous-event digest, canonical payload bytes, payload digest, event digest, event kind, request projection revision, and commit timestamp. The closed payload is a complete denormalized reward input:

- account-scope hash, request ID, attempt, provider/stable identity;
- route snapshot ID/digest and provider/model/canonical model/artifact/catalog/rate-card identity;
- receipt version/ID/digest, verification verdict/reason/digest, finality and terminal state;
- privacy, reward-exclusion, quarantine, reversal, and resolution facts with reason codes;
- prompt/completion/cache tokens, gross/provider credits, settlement mode, and authoritative timestamps;
- exact request-start observation capture kind, revision, pilot/key/generation, state, evidence/expiry, reference/calibration/policy digests, complete canonical capture and its digest;
- projection schema version and deterministic request projection revision.

Events represent complete snapshots, including absent/pending fields explicitly. The mirror consumes and retains the event payload/digest. It never looks up mutable SQLite rows to interpret an earlier sequence. Same sequence/digest replay is idempotent; same sequence with changed bytes, broken prior digest, lower request revision, or changed lineage is rejected and makes completeness unavailable.

### Restore-resistant source lineage and bootstrap

The source lineage anchor is an operator-owned file outside the SQLite database and outside repository/worktrees, defaulting under `/Users/augstar/.config/macprovider/operator-state/` for local qualification and an equivalent protected path in deployment. It contains no key material. It is mode `0600`, atomically replaced and directory-fsynced, and records accepted incarnation UUID, anchored event sequence/digest, and schema version. It must be excluded from ordinary SQLite backup/restore bundles.

Every journal-authoritative write holds the lineage `flock` through SQLite commit and anchor reconciliation. After a committed DB transaction, the writer proves that the database chain is the unique descendant of the anchored digest, then advances the external anchor atomically before allowing the next authoritative write. A crash after SQLite commit leaves the DB one valid descendant ahead; startup may verify and advance the anchor. An anchor ahead of the DB, a missing anchored sequence, digest divergence, sequence reuse, unknown incarnation, or fork fails closed and blocks projection availability.

The Postgres mirror also stores its accepted incarnation and every applied/observed sequence plus event digest. Startup compares both the external anchor and target checkpoint. An old full-database restore carrying the same embedded incarnation is detected because its chain is behind or diverges from at least one non-restored anchor. Intentional restore or new-source creation requires an offline, audited `new incarnation` operation; the running coordinator never silently invents or accepts one.

Online bootstrap is explicit:

1. Enter bounded maintenance/read-only mode, acquire lineage `flock`, acquire `BEGIN EXCLUSIVE`, and reject new money-path writes if the lock budget expires.
2. Install lineage/journal schema and mutation guards; create a pending new incarnation only through the operator bootstrap command.
3. Emit one complete snapshot event for every existing reward-projectable request from one locked snapshot. Record row count, ordered request-identity digest, final chain digest, and schema digest.
4. Verify all known mutation call sites use the journal transaction API and run the source-vs-event projection audit. Any mismatch rolls back the database transaction.
5. Commit, fsync/advance the external anchor, then release source writer exclusion. Normal writes now append tail events.
6. Bootstrap Postgres from sequence 1, verify chain/count/digest, catch the tail, and atomically set `ready` only when applied sequence/digest equals a source maximum/digest observed in one SQLite read snapshot.
7. During bootstrap or lineage uncertainty, APIs say updates unavailable. Rollback disables consumers and leaves additive tables inert; it never resumes the old cursor while claiming completeness.

Crash/restart is tested at every numbered phase, including old DB restore with the same embedded incarnation, in-place restore, sequence reuse, divergent fork, concurrent writes at each boundary, and target checkpoint ahead/behind/divergent.

### Tier-2 carrier and shared scheduler

SPEC-036's carrier rules are preserved exactly. Plain `compute_integrity_probe_v1.*` frames are rejected on an active Tier-2 session. Tier-2 requests/results use the SPEC-036 encrypted `inference_request` carrier with cleartext SPEC-036 digest preimages; encrypted frames without an active matching session are rejected. Carrier nonces and replay keys are domain-separated by protocol, direction, provider, session, and probe ID.

Provider hello capability negotiation advertises exact compute protocol/profile/carrier versions. Older providers or providers without the capability receive no probe. A typed NAK disables scheduling for that session/profile without disconnecting an otherwise compatible serving provider.

The compute-integrity and losslessness schedulers become one aggregate provider-work scheduler:

- buyer inference has absolute admission priority and may preempt queued probe work;
- per provider: one aggregate active probe, one queued item per profile, bounded total queue;
- global probe concurrency is configuration bounded;
- when both profiles become due together, compute integrity goes first, then losslessness; age promotion guarantees an accepted losslessness item begins within the declared maximum wait when buyer work permits;
- cancellation on paid work, disconnect, generation/profile/policy change, lease expiry, and shutdown releases all slots and records no idle inference;
- repeated unsupported NAKs are suppressed until capability/session change.

### Total reward status schema and mapping

SPEC-021 and SPEC-014 add `provider_reward_status.v2`. It contains four independent projections and four freshness envelopes:

| Projection | Closed states | Authority |
| --- | --- | --- |
| `recent_request_reward_state` | `eligible`, `held`, `excluded`, `pending`, `unavailable`, `none` | Immutable billing-projection payload for the request |
| `earning_state` | `earning`, `eligible_idle`, `held`, `capped`, `ineligible`, `unavailable` | Current mirror completeness + request evidence + current runtime/observation eligibility |
| `withdrawal_state` | `withdrawable`, `held`, `capped`, `ineligible`, `unavailable` | Reward ledger and canonical disposition/wallet predicate |
| `payment_state` | `unavailable` in Build 3 | Payment service capability; fixed reason `malibu_payment_execution_unavailable` |

Every projection carries exactly one primary reason, ordered secondary reasons, `observed_at`, `stale_after`, optional last-known value/time, and one recovery action from the closed set `none`, `retry`, `wait_for_probe`, `restore_supported_model`, `reconnect_provider`, `add_wallet`, `contact_support`. Unknown schema/enums/reasons map the affected projection to `unavailable` plus `contact_support`; they do not contaminate independently valid projections.

Request-state precedence is: malformed/unreadable source → `unavailable`; receipt/finality pending → `pending`; explicit exclusion, invalid receipt, wrong identity, quarantine, or observe-only economic exclusion → `excluded`; governed hold → `held`; complete verified request facts → `eligible`; no request within a fresh complete window → `none`.

Earning precedence is:

1. untrusted provider token or explicit current ineligibility → `ineligible`;
2. stale/incomplete billing mirror, unreadable request input, unknown/stale current observation, or missing runtime source → `unavailable`;
3. revoked/adverse observation, unsupported current pilot, battery/thermal pressure, or model unavailable → `ineligible`;
4. active provider/wallet cap → `capped`;
5. active provisional/demotion/governed hold → `held`;
6. fresh request state `eligible` inside the recent-work window → `earning`;
7. fresh complete mirror with no eligible recent request → `eligible_idle`.

Withdrawal precedence is independent of current compute and recent work: unreadable/stale ledger → `unavailable`; untrusted token, terminal exclusion/burn/retire, wallet missing/mismatch, or no eligible balance → `ineligible`; active cap → `capped`; active releasable hold → `held`; positive balance satisfying the canonical withdrawability predicate → `withdrawable`. A current unknown/revoked observation never rewrites an already accrued balance; only an explicit ledger disposition changes withdrawal eligibility.

`payment_state` is always `unavailable` in Build 3, regardless of withdrawal state. Required display copy for a positive withdrawal state is: **“MALIBU balance is eligible for withdrawal; payment execution is unavailable.”** There is no withdrawal action.

Freshness domains are `billing_mirror`, `reward_ledger`, `compute_observation`, and `usdc_earnings`, each with `state = fresh|stale|unavailable`, source observation time, stale-after, and completeness fields where applicable. A fresh USDC domain remains fresh when rewards are stale. Historical cleared holds/caps appear only in activity; they do not become current state.

Coordinator, Swift, and portal test vectors are generated from the same normative table. Property tests enumerate every state/reason input and all pairwise simultaneous conditions, proving precedence and independence.

## Data changes and compatibility

All migrations are additive. Old clients continue receiving current v1 fields for one declared compatibility window, but v1 omission never authorizes optimistic copy. New clients use v2 and fail only the affected projection closed on unknown values. Activity remains a separately fetched opaque-cursor resource and deduplicates by audit ID.

The observation source and journal default disabled. Missing/corrupt stores, lineage mismatches, unsupported providers, or missing Gate B evidence return unavailable. No in-memory verified fallback exists.

Rollback disables scheduling, source consumption, v2 presentation, and test accrual; it preserves immutable evidence and additive schema. Rollback never deletes history, rewrites captures, continues from an unverified cursor, or enables old misleading language.

## Phased implementation after Gate B

1. **Governance and schemas:** update SPEC-036, SPEC-021, SPEC-014, billing/mirror owners, `AUTHORITY.json`, `CONFORMANCE.json`, and closed fixtures.
2. **Observation authority:** add SQLite event/current/capture schema, CAS lifecycle, writer/lineage protocol, replay validation, authorization, retention, and sanitized reads.
3. **Shared scheduler/runtime:** capability negotiation, carrier rules, bounded scheduling, exact Swift profile hook, cancellation and unsupported behavior.
4. **Evaluation/status:** independently approved references and calibration, conservative multi-reference evaluation, expiry/revocation, public-safe status.
5. **Projection journal/mirror:** complete immutable event payloads, call-site conversion, bootstrap, lineage detection, target apply and completeness watermark.
6. **Rewards:** v2 schema, total mapping, test-only idempotent accrual consumption, paginated activity. Production emission remains off.
7. **Presentation:** app/portal parity, last-known data, independent refresh, truthful payment copy, accessibility.
8. **Verification:** targeted, broad, physical, and three-lane complete-diff reviews; production qualification remains separate.

Any material architecture, contract, scope, or test-strategy change reopens the plan gate before the changed work.

## Observability and failure recovery

Metrics and structured audit events cover probe queue/active/cancel/NAK by profile/carrier; evaluation by exact pilot and reason; stale CAS rejection; revocation latency; replay failures; SQLite transaction/lock latency; anchor lag/divergence; journal sequence/head; bootstrap phase; mirror applied/observed sequence and digest; source generation mismatch; reward mapping reason; activity pagination failure; and redaction failures.

No metric labels include prompts, raw probabilities, tokens, secrets, buyer identity, or unbounded provider-controlled strings. Alerts fire for lineage divergence, event-chain failure, source/target mismatch, stale observations, reference disagreement, and presentation-contract unknown values. Recovery is fail-closed and auditable: retry transient reads, replay deterministic materializations, require operator new-incarnation approval for intentional restore, and keep observation/rewards unavailable until proofs converge.

## Acceptance and hardware qualification

The paired `test-spec-v2` maps every claim to fresh evidence. Local implementation completion, fresh local verification, actual MLX evidence, physical end-to-end evidence, and production qualification are reported separately.

Positive pilot qualification requires the exact manifest, two independent reference environments meeting all three independence axes, representative class cohort, physical Apple Silicon, actual MLX inference, Xcode app, real browser, and local/deployed service topology evidence. A fixture, skipped model test, sampler-stage spike, one host, current provider assertion, successful status adapter, or mirror freshness alone cannot satisfy it.

## Explicit non-goals

- SPEC-036 enforce activation or settlement changes.
- MALIBU emission activation, withdrawal/payment execution, epochs, payout work, or economic policy changes.
- Production deployment, pool authorization, trusted-pool activation, release publication, hardware procurement, or operator-secret changes.
- Provider-wide integrity, confidential compute, anonymity, physical-computation proof, or malicious-provider honesty claims.
- Inspection of `d-inference` source or adoption of a new dependency without separate approval.
- Support for a second model/runtime/profile/hardware class.

## Roadmap outcome mapping

| Roadmap outcome | Implementation step | Verification |
| --- | --- | --- |
| One covered model/runtime/profile | Gate A evidence, frozen pilot at Gate B | B3-F/C/REF/CAL tests |
| Actual probes and justified references | Slices 2–4 | MLX, independence, golden-fixture, calibration evidence |
| Generation validity, expiry, revocation | Observation authority and shared scheduler | Transaction-order and crash matrix |
| Sanitized status | Evaluation/status | schema/redaction/auth tests |
| Governed reward mapping | Journal/mirror plus v2 total mapping | exhaustive/property vectors |
| Portal/app parity | Presentation slice | Xcode/browser state matrix |
| Request → receipt → reward | All upstream slices | correlated physical evidence bundle |
| No overclaim/activation | Every slice | default-off/config/negative economics tests and copy review |

# Product Build 3 — Test Specification

Test-spec revision: `build3-test-v1`
Plan pairing: `build3-plan-v1`
Repository/base: `Augustas11/macprovider@1d2c930bad81704dd0acc0322226725d8b64aceb`
Status: awaiting independent adversarial approval

## Evidence classes

Every test record states one of these classes. No class substitutes for a stronger one.

| Class | Meaning |
| --- | --- |
| U | Unit/property/schema test with in-memory or deterministic inputs |
| I | Local multi-component integration with real databases/services; may use deterministic compute fixtures |
| S | Swift package/CLI runtime test on Apple Silicon |
| X | Xcode Malibu app test/run |
| B | Real browser provider-portal test |
| M | Actual MLX inference with recorded model/artifact/runtime/hardware context |
| P | Physical end-to-end journey through provider and services |
| Q | Production qualification/deployed evidence approved by operators |

Skipped, timed-out, zero-selected, fixture-only, historical, unavailable-Docker, or interrupted runs are recorded as gaps. They do not pass a criterion requiring another class.

## Required fixtures and evidence

- Exact covered-key policy and profile manifests.
- Two valid independently produced reference events plus invalid, stale, revoked, cross-policy, wrong-artifact, wrong-runtime, wrong-hardware-class, and wrong-profile vectors.
- Calibration report and threshold with valid/invalid approval, expiry, sample-count, and numeric-bound vectors.
- Probe lease/result golden vectors for current, expired, cancelled, replayed, oversized, unknown-field, wrong-session, wrong-generation, and wrong-policy cases.
- Billing journal/mirror fixtures with insert, delayed receipt update, repeated update, source restore/generation change, crash between read/apply, retry, and reconciliation divergence.
- Reward projection fixtures covering every closed state/reason and independent freshness domain.
- Portal and Swift fixtures representing new clients, compatibility clients, unknown future enums, partial fields, stale fields, and activity page failures.

## Sampler-hook feasibility gate

| ID | Required class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-F001 | S/M | Throwaway spike extracts `post_sampler_probabilities` for the exact model/profile using repository-approved MLX APIs | Tensor stage, shape, dtype, processor order, normalization, and runtime/API provenance are recorded; normal output is unchanged. |
| B3-F002 | S/M | Repeat identical profile and compare serialized vectors | Difference is explained by specified numeric semantics and is suitable for later calibration; no threshold is inferred from this test. |
| B3-F003 | S/M | Cancel during load and observation, and apply the maximum bounded profile | Cancellation releases resources; peak memory/time/copy cost remain within a proposed ceiling without destabilizing paid inference. |
| B3-F004 | S | Unsupported runtime/API or inability to expose the exact stage | Returns a typed feasibility blocker. Observation-runtime slices remain unimplemented and no availability claim is made. |

These tests are a prerequisite for runtime architecture approval. They are not reference, calibration, integrity, reward, or production evidence.

## Contract and schema tests

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-C001 | U | Valid policy/profile/reference/calibration bundle for the exact key | Accepted with stable canonical digest. |
| B3-C002 | U | Unknown enum/field, duplicate JSON key, trailing JSON, noncanonical numeric value, invalid UTF-8, oversized field | Rejected with typed error; no durable state transition. |
| B3-C003 | U | One reference only, correlated/non-independent producers, expired/revoked reference, source disagreement | Cannot yield positive verified state. |
| B3-C004 | U | Calibration missing hardware class, sample counts, precision, threshold rationale, approval, or expiry | Rejected or state remains unknown. |
| B3-C005 | U | Covered-key dimension changes one at a time | Produces a distinct key and no inherited positive state. |
| B3-C006 | U | Sanitized status serialization | Contains allowed digests/times/states/disclosure only; excludes prompts, logits/raw probabilities, internal credentials, and other-provider data. |
| B3-C007 | U | Additive reward response consumed by old fixture | Old client remains conservative and functional. |
| B3-C008 | U | New client receives unknown future closed enum | Maps to unavailable/unknown, never earning/withdrawable/payable. |

## Durable observation source tests

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-O001 | I | Install valid policy and two references, restart coordinator | Identical current policy/reference identity restored; restart does not extend freshness. |
| B3-O002 | I | Duplicate policy/reference/result with same idempotency key and body | One logical event; deterministic response. |
| B3-O003 | I | Same idempotency key with different body | Conflict and audit event; no overwrite. |
| B3-O004 | I | Revoke reference, calibration, policy, or covered key | Affected current positive status invalidates durably and remains invalid after restart. |
| B3-O005 | I | Store missing/corrupt/unreadable | Endpoint and projection report unavailable; no in-memory verified fallback. |
| B3-O006 | I | Concurrent result, expiry, and revocation | Revocation/expiry wins according to versioned ordering; no transient positive snapshot after committed tombstone. |
| B3-O007 | I | Raw-evidence retention expiry | Public/audit minimum remains sufficient to explain state; sensitive payload is removed according to policy. |

## Probe transport and runtime tests

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-P001 | U/I | Lease delivered to wrong provider/session | Rejected before runtime execution. |
| B3-P002 | U/I | Provider reconnects or generation changes before/during probe | Lease cancelled; old result rejected; status not promoted. |
| B3-P003 | U/I | Lease expires, is cancelled, or is replayed | Result rejected with typed reason; resources released. |
| B3-P004 | U/I | Result exceeds prompt/position/probability/byte/time bounds or contains NaN/Inf | Rejected before persistence/evaluation of untrusted payload. |
| B3-P005 | U/I | Two leases race for one provider | At most one active runtime probe; bounded queue; paid inference priority preserved. |
| B3-P006 | S/M | Exact model/profile actual MLX execution | Returns correctly bound post-sampler probabilities within resource ceilings; records hardware/runtime/artifact context. |
| B3-P007 | S/M | Cancellation during model load and during generation | Stops promptly, reports cancelled, leaves provider able to serve the active model. |
| B3-P008 | S/M | Unsupported/nonmatching model, artifact, runtime, hardware class, or sampler feature | Typed unsupported/uncovered result; no fallback claim. |
| B3-P009 | I | Probe marked as billable or attempts to enter receipt/reward ledger | Rejected; no buyer debit, provider credit, or reward entry. |
| B3-P010 | I/P | Paid request arrives while probe is queued/running | Defined priority policy is observed; no starvation or false idle label. |

## Evaluation and lifecycle tests

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-E001 | U | Result inside calibrated threshold against both current references | Eligible to contribute to rolling verified window for exact key only. |
| B3-E002 | U | Result agrees with one reference and disagrees with the other | No verified state; source-disagreement reason and alert. |
| B3-E003 | U | Threshold boundary, precision rounding, deterministic repeat | Stable decision under specified numeric semantics. |
| B3-E004 | U/I | Policy/reference/calibration expires immediately after result | New status expires; request-start capture preserves the exact prior evidence time without upgrading future requests. |
| B3-E005 | I | Profile/runtime/artifact/catalog identity/hardware class changes | Generation advances or key changes; old positive status cannot apply. |
| B3-E006 | I | Revocation races with request start | Transaction/order rule deterministically captures pre-revocation evidence or blocks it; never mixes revisions. |
| B3-E007 | I | Abusive failures/flapping | Existing adverse overlay/cooldown semantics hold; no positive state via repeated reconnect. |
| B3-E008 | U/I | Uncovered model served successfully | Compute state remains uncovered/unknown; no provider-wide inference. |

## Billing journal and mirror tests

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-M001 | I | New request-credit row inserted | Journal event appended atomically with same source generation. |
| B3-M002 | I | Receipt arrives later and updates existing row | New event sequence emitted even though request row ID is unchanged. |
| B3-M003 | I | Transaction rolls back | Neither mutation nor journal event remains. |
| B3-M004 | I | Mirror applies batch then crashes before checkpoint, or checkpoints are retried | Idempotent replay; target state and applied sequence converge. |
| B3-M005 | I | Mirror observes source max and applies all events in one source snapshot | `complete_through` true only for matching generation and applied sequence; timestamp matches snapshot. |
| B3-M006 | I | New source event occurs after snapshot | UI claim remains bounded to prior `source_observed_at`; no confirmed-current-idle statement. |
| B3-M007 | I | Source DB restore/replacement resets sequence | Generation mismatch sets unavailable and requires rebootstrap; no silent cursor continuation. |
| B3-M008 | I | Journal consumer and bounded sweep disagree | Alert and conservative unavailable state; repair is auditable. |
| B3-M009 | I | Concurrent mirrors | Advisory lock/single writer prevents split checkpoints; result converges. |
| B3-M010 | I | Mirror stale while USDC provider earnings is fresh | Independent freshness returned and displayed. |

## Reward mapping and ledger tests

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-R001 | U/I | Fresh verified covered observation, verified receipt, complete fresh mirror, eligible configured test ledger | Earning state reflects verified work; test accrual is idempotent. Production activation remains off. |
| B3-R002 | U/I | Compute unknown with an eligible historical balance | Earning unavailable; withdrawal eligibility remains independent; payment unavailable; balance preserved. |
| B3-R003 | U/I | Historical hold or cap with current sources fresh | Current state and historical event are labeled separately; old cap/hold is not treated as current. |
| B3-R004 | U/I | Compute verified now but request-start capture was unknown/uncovered | Historical request is not upgraded and does not become reward-eligible. |
| B3-R005 | U/I | Compute revoked after request-start capture | Historical capture remains auditable; policy applies explicit prospective/hold behavior without rewriting facts. |
| B3-R006 | U/I | Mirror incomplete/stale/error | No current earning/idleness claim; last-known balance timestamp remains visible. |
| B3-R007 | U/I | Missing wallet with eligible balance | Earning state unaffected; withdrawal state `unavailable` with add-wallet action; payment remains unavailable. |
| B3-R008 | U/I | Provider/wallet caps and duplicate/replay accrual | Existing cap and idempotency protections hold. |
| B3-R009 | I | Receipt missing, invalid, mismatched model/artifact/provider, quarantined, observe-only, or excluded | No reward accrual; typed reason/audit entry where governed. |
| B3-R010 | I | Emission/payment feature flags remain default off | No production rewards, withdrawals, or payments are created by Build 3 observation availability. |

## App and portal parity tests

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-U001 | X/B | Fresh USDC with stale rewards | USDC shown fresh; rewards shown stale/last-known; no global stale collapse. |
| B3-U002 | X/B | Unknown compute plus eligible MALIBU balance | Independent earning/withdrawal/payment states; no “earning now.” |
| B3-U003 | X/B | Eligible MALIBU withdrawal state while payment service unavailable | Exact truthful language says balance eligibility and payment execution unavailable; no withdraw action. |
| B3-U004 | X/B | Missing wallet | Actionable add-wallet path; activity and balances preserved. |
| B3-U005 | X/B | Historical holds/caps | Displayed as historical with event time; not presented as current unless current source says so. |
| B3-U006 | X/B | No recent verified row and mirror freshness unavailable | “Work status unavailable/updates delayed,” never confirmed idle. |
| B3-U007 | X/B | Observation stale, profile changed, or revoked | Coverage/freshness/reason/recovery displayed; no broad integrity claim. |
| B3-U008 | X/B | Activity page 1, page 2, duplicate cursor request | Stable ordering, no duplicates, correct next cursor, independent loading state. |
| B3-U009 | X/B | Activity endpoint fails after summary succeeds | Summary/balances remain; activity is last-known or unavailable with retry. |
| B3-U010 | X/B | Summary refresh fails after prior success | Last-known values retain timestamp; stale indicator and retry; no zero reset. |
| B3-U011 | X/B | Unknown API enum or malformed partial response | Conservative unavailable state with actionable refresh/support; no optimistic default. |
| B3-U012 | X/B | Accessibility and narrow-window layout | State, time, action, pagination, and disclosure remain perceivable by keyboard/screen reader and without clipping. |

## End-to-end first-job acceptance

All of B3-A001 through B3-A004 must use the same evidence bundle and correlated identifiers.

| ID | Required class | Scenario | Required evidence/result |
| --- | --- | --- | --- |
| B3-A001 | M/P | Physical provider loads exact 3B 4-bit artifact and executes qualified profile | Hardware/chip/RAM/OS, runtime/app/CLI versions, artifact digest, covered-key/policy/reference/calibration digests, probe lease/result/verdict IDs, timing, and resource use recorded. |
| B3-A002 | P | Real nonstreaming paid job through actual MLX | Request-start capture binds provider/model/artifact/runtime/hardware/generation/profile observation; receipt persists and verifies. |
| B3-A003 | P | Same job advances through delayed mirror and configured test accrual | Billing event sequence, mirror `complete_through`, accrual external ref, ledger/audit IDs, and idempotent rerun recorded. No production economic activation. |
| B3-A004 | X/B/P | Malibu app and provider portal display the same job/state | Screens/API captures show request → receipt → mirror → accrual, independent freshness, truthful payment state, and paginated activity. |

The physical journey also repeats these failures:

- Cancel during probe and actual inference; reconnect and recover without corrupting the active model.
- Delay receipt beyond the first mirror pass, then reconcile the existing request row through a new journal event.
- Revoke the active reference/policy and prove the next request cannot inherit the old positive state.
- Change profile/generation and prove an in-flight old result is rejected.
- Make reward source stale while USDC remains fresh and verify both UI surfaces.

## Security tests

- Authentication/authorization matrix for provider status, operator policy/reference/calibration/revocation, and reward endpoints.
- Cross-provider lease/result/status access rejection.
- Replay, nonce collision, request smuggling, duplicate-key JSON, oversized/decompression payload, numeric NaN/Inf, timing and cancellation abuse.
- SQL transaction fault injection for observation events and billing journal.
- Redaction tests for logs, metrics, HTTP errors, evidence bundles, app diagnostics, and portal output.
- Resource-exhaustion tests for per-provider concurrency, global queue, CPU/GPU/memory/disk retention, and result payload caps.
- Verify probe traffic never creates buyer charges, provider credits, reward entries, or signed paid receipts.
- Verify current provider state cannot substitute for immutable request-start evidence.

## Broader verification commands

Exact commands may change with file ownership, but the final evidence must include:

```bash
cd phase4-coordinator && go test ./internal/computeintegrity -race -count=1
cd phase4-coordinator && go test ./internal/stats/billingmirror -race -count=1
cd phase4-coordinator && go test ./internal/rewards -race -count=1
cd phase4-coordinator && go test ./internal/billing -race -count=1
cd phase4-coordinator && go test ./internal/ws -race -count=1
cd phase4-coordinator && go test ./...
cd phase4-coordinator && go vet ./...
cd phase3-binary && swift test
cd frontdoor/provider-portal && node --test mining-health.test.mjs
make test-integration
make test-dist
python3 scripts/validate_spec_index.py
```

If Docker is unavailable, Docker-dependent integration is blocked and reported. Swift package tests do not substitute for Xcode app tests. Deterministic fixtures do not substitute for actual MLX inference.

## Independent diff-audit gate

After implementation, three independent GPT-5.6 Sol lanes inspect the complete base-to-head diff:

1. Code correctness and test adequacy.
2. Security, authorization, trust boundaries, resource abuse, and data exposure.
3. Architecture, normative contracts, lifecycle ordering, compatibility, rollback, economics, and UX truthfulness.

All Critical, High, and Medium findings must be corrected and the full affected diff re-reviewed. Low/Info findings may be carried only with an explicit disposition.

## Acceptance record template

For every criterion record:

- test ID and evidence class;
- exact command or journey runner revision;
- base/head commit;
- start/end time and duration;
- selected/passed/failed/skipped counts;
- hardware/runtime/model/artifact/profile/policy/reference/calibration context where applicable;
- service topology and whether Docker/deployed services were used;
- artifact paths and SHA-256 digests;
- result: passed, failed, or blocked;
- blocker and next required evidence.

Final reporting separates:

- implementation completion;
- fresh local verification;
- physical hardware verification;
- production qualification.

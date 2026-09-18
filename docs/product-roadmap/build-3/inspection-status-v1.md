# Product Build 3 — Current Implementation Inspection

Status: planning evidence only
Inspection revision: `build3-inspection-v1`
Repository: `Augustas11/macprovider`
Inspected base: `1d2c930bad81704dd0acc0322226725d8b64aceb` (`origin/main`, 2026-09-11)
Historical roadmap: `/private/tmp/macprovider-roadmap/.omx/plans/product-roadmap-422fc2f1.md` at `422fc2f13fc62c1ff8987522f822d9ef856e4a96`

The roadmap file was available. It is historical evidence only. This inspection used the freshly fetched base above and fresh tests listed below.

## Classification vocabulary

- **Landed**: implemented on the inspected base with fresh local evidence for the stated boundary.
- **Partial**: useful implementation exists, but the requested outcome is not complete.
- **Missing**: no production implementation was found.
- **Blocked**: code can be planned, but acceptance or qualification depends on unavailable external evidence, hardware, operator action, deployment, or governance approval.

## Outcome matrix

| Roadmap outcome | Status | Current evidence | Missing proof or implementation |
| --- | --- | --- | --- |
| Production compute-integrity source and ownership | **Missing** | `phase4-coordinator/internal/ws/compute_integrity_status.go` defines `ComputeIntegrityStatusSource`; `phase4-coordinator/internal/ws/server.go` stores it and exposes `WithComputeIntegrityStatusSource`. Tests inject `fakeComputeIntegrityStatusSource`. | `phase4-coordinator/cmd/coordinator/main.go` does not construct or inject a source. Production status endpoints therefore return `compute_integrity_status_unavailable`. The in-memory `computeintegrity.Store` in `phase4-coordinator/internal/computeintegrity/window.go` is not durable production ownership. |
| One covered model/runtime/profile | **Partial** | SPEC-036 primitives bind status to provider, generation, model, artifact, tokenizer, runtime build, hardware class, probe profile, corpus, threshold, and sampler stage. The signed tier-2 catalog contains `mlx-community/Llama-3.2-3B-Instruct-4bit`. | No production policy row, probe profile, runtime execution path, reference corpus, calibration, or durable covered-key lifecycle exists. |
| Actual probe execution | **Missing; provider sampler hook is a feasibility blocker** | `phase4-coordinator/internal/computeintegrity/probe.go` validates bounded probe requests and results. SPEC-036 inherits SPEC-030 algorithm/policy but requires its own settlement-bearing wire framing. | No coordinator scheduler/lease, compute-integrity transport handler, Swift MLX probability extraction, result ingestion, timeout/cancellation path, or non-billable accounting path is wired. The adjacent losslessness path returns `inconclusive:unsupported_sampler` in `CoordinatorClient.swift` through `LosslessnessProbeRuntime.providerInconclusiveForUnavailableSampler` because the current runtime exposes no full-distribution MLX sampler hook. |
| Independently justified references and calibration | **Missing / blocked** | `reference.go` and `threshold.go` validate reference, threshold, and calibration records. SPEC-036 describes the prerequisite. | No independently produced reference events, calibration campaign, provenance record, operator approval, or representative hardware evidence exists. Production qualification is blocked until those artifacts are produced and reviewed. |
| Generation-aware validity | **Partial** | `keys.go`, `window.go`, and `warmswap.go` key observations and invalidate warm-swap generations. Tests cover many state transitions. | No live generation source is bound to a production probe scheduler and provider runtime echo. No durable invalidation event survives coordinator restart. |
| Expiry and revocation | **Partial** | Closed states include expired/adverse outcomes; expiry logic and settlement fail-closed behavior exist. | No durable policy/reference/calibration/profile revocation API or event log is connected to the live source. Catalog/runtime/profile changes do not trigger production invalidation because no source is wired. |
| Sanitized provider/operator status | **Partial** | `computeintegrity.StatusSnapshot` and `StatusCopyV1` publish digest-only metadata and explicitly state that the signal is not proof of honest computation, hardware integrity, runtime integrity, or covert attestation. Provider and admin HTTP handlers exist. | They have no production backing source. Buyer/public coverage remains unavailable. Status freshness cannot be tied to durable observations. |
| Settlement capture and fail-closed interpretation | **Landed for the existing framework; unqualified in production** | `phase4-coordinator/internal/billing/settlement_compute_integrity.go` persists immutable request-start capture; `settlement_verifier.go` applies observe/enforce semantics and quarantine rules. Unit tests cover missing/unreadable captures, precedence, and no money effect in observe mode. | No production observation source supplies a qualified positive state. Enforce prerequisites are unmet and must remain disabled. |
| Governed reward-state mapping | **Missing** | `phase4-coordinator/internal/rewards/read_model.go` has closed compute states and separate earning/withdrawal states. | `BuildProviderRewardProjection` in `projection.go` and the wallet path in `wallet_status.go` hardcode `ComputeIntegrityStateUnknown`. No covered-key source or governance-approved mapping is connected. |
| Authoritative reward-mirror freshness watermark | **Missing** | `phase4-coordinator/internal/stats/billingmirror/mirror.go` tracks `LastRequestID`, `SweepAfterID`, `SourceMaxID`, overlap, and reconciliation sweep. | Rewards do not consume a source completeness watermark. An ID cursor cannot prove completeness for delayed updates to existing request rows. `recentWorkEligibilityFacts` correctly treats absence as unavailable rather than confirmed idle. |
| Receipt to mirror to accrual data path | **Partial** | `phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go` exercises receipt settlement, SQLite credits, mirror ingestion, Postgres accrual/audit, delayed mirror passes, concurrency, and rejection cases. | Evidence is deterministic fixture plus database integration. It does not run actual MLX inference, a physical provider, the app, portal, deployed services, or production references/calibration. |
| Independent earning and withdrawal states | **Landed in coordinator and Swift app** | `read_model.go` models them independently. `AgentSnapshot.swift`, `EarningsClient.swift`, and `DashboardWindow.swift` preserve historical values and display independent states. | Portal currently collapses the response through `primary_reason`; payment availability is not a first-class state. New compute and mirror freshness fields still need consumption. |
| Freshness and last-known values | **Partial** | Swift app maintains provider earnings freshness and MALIBU projection freshness separately and keeps last-known USDC. Projection has `generated_at`/`stale_after`. | Projection freshness is not the billing source completeness watermark. Portal does not provide equivalent source freshness and last-known presentation. |
| Actionable failures | **Partial** | Swift app maps closed reasons and preserves state on activity failures. Coordinator exposes typed reasons. | Portal copy conflates states and lacks recovery actions for stale rewards, missing wallet, activity failure, and payment unavailability. |
| Paginated reward activity | **Landed in coordinator and Swift app; partial in portal** | `phase4-coordinator/internal/rewards/audit.go` supplies `next_before_id`; Swift `RewardActivity.swift` and `DashboardWindow.swift` implement retry, refresh, and “Load older activity.” | Portal validates the embedded cursor but does not fetch subsequent `/v1/provider/malibu-reward-audit` pages or expose a load-more/retry interaction. |
| Truthful MALIBU payment language | **Landed in Swift app; missing in portal** | Swift copy says “eligible for withdrawal · payment execution not available yet.” | `frontdoor/provider-portal/index.html` still says “MALIBU is available to withdraw” and “Withdrawable,” which implies an operational payment path. |
| Unknown compute with eligible balance | **Partial** | Coordinator state model can represent earning unavailable while withdrawal remains independently eligible; tests cover this distinction. | Production projection hardcodes compute unknown and the portal collapses states, so the user journey is not consistently truthful across surfaces. |
| Historical holds and caps | **Partial** | Reward read-model and tests distinguish current earning reasons from historical/cap ledger information. | Portal parity and source freshness semantics are incomplete. No physical end-to-end presentation evidence exists. |
| Stale rewards with fresh USDC | **Landed in Swift app; missing in portal acceptance** | App has independent freshness domains and last-known values. | Portal needs equivalent behavior and tests. No Xcode/app acceptance run or browser-to-live-service run was performed in this planning phase. |
| Missing wallet | **Partial** | Coordinator provides the reason and Swift presents wallet guidance. | Portal needs an independent withdrawal state/action rather than a single health code. |
| Payment unavailability | **Partial** | Swift explicitly discloses unavailable MALIBU payment execution. SPEC-016 records payout runner default-off and production not deployed. | Portal must disclose the same. Build 3 must not activate or implement payout execution. |
| Real job: request → receipt → mirror → accrual → app/portal | **Blocked** | Component and deterministic integration foundations exist. | Requires a physical Apple Silicon provider, actual MLX inference, qualified one-key observation artifacts, deployed or local multi-service journey wiring, Xcode app run, portal browser run, and production/operator qualification. Planning and independent local implementation cannot claim this acceptance criterion. |

## Trust-boundary findings

1. Provider assertions, provider signatures, a status adapter, or one successful probe cannot establish physical computation. Positive observation requires qualified reference and calibration evidence for the exact covered key.
2. A compute observation is a narrow distribution-drift signal. It does not establish provider-wide integrity, hardware identity, confidential compute, runtime-binary integrity, or honest execution of every request.
3. A fresh projection timestamp is not proof that the billing mirror is complete. Delayed settlement can mutate an existing request row, so a monotonically increasing request ID alone is insufficient.
4. Reward eligibility must bind to the request-start covered key and independently verified receipt. Current provider state cannot retroactively upgrade a historical job.
5. Observation availability does not authorize SPEC-036 enforce mode, MALIBU reward activation, withdrawals, payouts, or production rollout.
6. The existing routing path constructs `computeintegrity.NewDefaultPolicy()` and remains dormant in `internal/buyer/route_snapshot.go` until an authoritative policy and dependency source exists. Build 3 must not replace that fail-safe default with a hardcoded pilot policy.

## Fresh verification performed

| Command | Result | Evidence boundary |
| --- | --- | --- |
| `cd phase4-coordinator && go test ./internal/computeintegrity -count=1` | PASS (`0.846s`) | Compute-integrity unit behavior only. |
| `cd phase4-coordinator && go test ./internal/rewards -count=1` | PASS (`0.700s`) | Rewards unit/integration tests selected by that package; no physical MLX or production service. |
| `cd phase4-coordinator && go test ./internal/ws -run 'ComputeIntegrity' -count=1` | PASS (`0.994s`) | Status handler tests with fake source. |
| `cd frontdoor/provider-portal && node --test mining-health.test.mjs` | PASS (9 tests, 0 failed/skipped) | Portal JavaScript harness only; not a browser-to-live-service journey. |

No skipped, timed-out, zero-selected, historical, fixture-only, or unavailable run is counted as physical or production acceptance.

## Current blockers

- No approved independent reference and calibration artifacts for the proposed covered key.
- No physical Build 3 end-to-end run has been executed.
- No production deployment or operator qualification has been authorized.
- SPEC-036, SPEC-021, SPEC-014, and related conformance entries require governance updates before contract changes.
- SPEC-016 payout execution remains default-off and production-unavailable; payout/epoch implementation and activation are explicit non-goals.

# MacProvider Product Roadmap After Rewards and Relay-Blind Implementation

## Scope and Recommendation

Inspected freshly fetched origin/main at `422fc2f13fc62c1ff8987522f822d9ef856e4a96`. The previous baseline was `6006f313`. This assessment counts landed code only. Three native agents separately inspected rewards, relay-blind execution, and model supply/Trusted Pools; the lead inspected throughput, payment boundaries, frontend ownership, and selected tests.

Recommendation: make the existing platform easier to use before adding another protocol layer. Run two small completion PRs immediately, make self-service catalog supply the next substantial feature, and turn the encrypted pilot into a supported buyer journey. Develop compute observations and capacity as bounded engineering tracks. Treat economic activation and production qualification separately from feature completeness.

This is a code-based product recommendation, not proof of deployment, release availability, customer demand, or production performance. Priority assumes the objective is broader usable supply and repeat buyer/provider use. A committed privacy design partner can move the private-buyer track ahead of supply; measured saturation can move capacity earlier.

## What Actually Landed

| Track | Landed | Remaining boundary |
| --- | --- | --- |
| Rewards / Mining Health, `422fc2f1` | Independent MALIBU earning/withdrawal presentation; coherent accrual/wallet projection selection; hardware evidence adapter; recent verified-work observation; actionable app UI and paginated reward activity; real settlement/mirror/accrual integration test code. | Compute source remains unknown, no authoritative mirror freshness watermark, portal parity incomplete, economic flags unchanged, no MALIBU payment execution. |
| Relay-blind pilot, `836d7e59` / PR #1467 | Provider key custody and pinned authority, reservations, reference buyer CLI, opaque relay transport, provider decryption and token checks, capped ordinary settlement, nonstreaming/streaming and durable recovery tests. | Operator pin provisioning, global pool only, observe-mode isolation, real-model encrypted journey qualification, public client integration, no positive verified-model settlement or useful-work rewards. |
| Model supply | Discovery/evaluation/offers, provider-wire probes, economics projections, signed artifact-feed producer/server/distribution. | CLI artifact-feed consumer and self-service preparation/action journey are still missing from the inspected merged snapshot; automatic probing stops at network_admitted_unsettled. |
| Trusted Pools | Durable administration, route isolation, policy and production-promotion gates. | Pilot qualification, current signed evidence, release/operator activation, and composition with relay-blind routing. |
| Capacity | Batching scheduler and paged-KV scaffolding. | Runtime reports no production scheduler backend; the engine bridge remains deferred. |

Evidence: [reward projection](/Users/augstar/macprovider-poc/phase4-coordinator/internal/rewards/projection.go:35), [reward presentation notes](/Users/augstar/macprovider-poc/docs/rewards-mining-health.md:1), [relay pilot evidence and limits](/Users/augstar/macprovider-poc/audits/privacy-pool-v01-implementation.md:1), [economics actions](/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift:423), [automatic probe target](/Users/augstar/macprovider-poc/phase4-coordinator/internal/ws/server.go:4223), [runtime backend gate](/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1870).

## Immediate Completion PRs

### A. Provider Portal Reward Parity

The app was updated; the web portal was not. The portal still maps its main health state from primary_reason and retains "MALIBU is available to withdraw" wording. Existing audit and eligibility APIs can support a bounded presentation fix.

Build: separate earning, held/eligible balance, and payment availability; preserve source freshness and last-known values; reuse existing history with pagination. Do not rebuild the reward ledger or change earning policy.

Accept when app and portal fixtures agree for unknown compute plus eligible balance, historical holds, caps, stale rewards plus fresh USDC, missing wallet, and unavailable payment execution. Add browser/Node coverage appropriate to the portal.

Evidence: [old wording](/Users/augstar/macprovider-poc/frontdoor/provider-portal/index.html:1451), [primary-reason mapping](/Users/augstar/macprovider-poc/frontdoor/provider-portal/index.html:1612).

### B. Buyer-Approved Provider Selection

The client verifies a local identity pin, but the coordinator selects the first eligible provider by assigned-session ordering without considering the buyer's accepted identities. A multi-provider deployment can hand a correctly behaving buyer a reservation it cannot trust.

Build a reviewed reservation contract for buyer-approved identities or an authenticated equivalent. Preserve opaque public routing, independent trust provisioning, and single-use binding. Selection is before encryption; do not introduce cross-provider ciphertext failover.

Accept when a buyer pinning A succeeds even when B sorts first, a buyer accepting A and B can use either, and expired/revoked/unapproved identities never produce a usable reservation. Test mixed providers, key rotation, concurrency, and no trusted candidates.

Evidence: [selection](/Users/augstar/macprovider-poc/phase4-coordinator/internal/buyer/relay_blind.go:243), [buyer pin validation](/Users/augstar/macprovider-poc/phase5-gateway/cmd/relay-blind-client/main.go:61).

## Ranked Substantive Roadmap

### 1. Self-Service Model Supply

Outcome: a provider can select a supported catalog model, prepare it safely, understand its pricing/admission state, and progress through an authoritative admission workflow.

Sequence:
1. Land signed artifact-feed CLI consumption: strict decoding, release/signer binding, freshness and baked fallback, exact artifact identity matching.
2. Implement a "Prepare catalog model" transaction for one primary MLX artifact: size/trust disclosure, staging, verification, cancellation, adoption and readiness reconciliation.
3. Add the authority-backed path from probed admission to catalog-priced and settlement-capable states, preserving current tier, hash, rate, drift and receipt requirements.
4. Expose the resulting executable actions in the existing Malibu model-management/economics UI.

A local slice-2c artifact-consumer worktree already exists; inspect and coordinate that effort before duplicating it. Its unmerged contents were not credited in this roadmap.

Accept when one real Mac completes catalog selection through preparation and valid admission, then serves a correctly settled request. Corrupt/cross-release artifacts must fail closed; cancellation preserves the previously serving model. Listed/non-primary/unsettled identities must not be promoted into paid routing merely because preparation succeeds.

Evidence: [current loader](/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift:1596), [feed server](/Users/augstar/macprovider-poc/phase4-coordinator/internal/buyer/catalog_artifacts_feed.go:320), [existing artifact store](/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/DurableModelArtifactStore.swift:85), [unavailable actions](/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift:423).

### 2. Supported Private Buyer Journey

Outcome: an invited buyer can provision trust and make encrypted requests through a supported client without manually assembling protocol details.

Build on completion PR B: package a supported client/library from the reference implementation; provide authenticated pin provisioning and replacement; expose useful typed errors and recovery status; integrate the deployed buyer workspace after inspecting its actual code. Preserve wallet/API authentication and no automatic encrypted-request replay.

The deployed buyer console is maintained in MalibuAI/malibu. This repository's frontdoor console is historical, so no claim about the current external UI is made here. Cross-repository ownership is an explicit planning dependency.

Accept when a new buyer completes nonstreaming and streaming requests against two independently pinned providers, understands key rotation and unavailable outcomes, and cannot confuse response visibility with request encryption. Run the complete encrypted path with real MLX weights and record model/artifact/hardware identity, cap enforcement, cancellation and recovery.

The current end-to-end Swift fixture is deterministic. A separate MLX selftest is useful but does not prove the encrypted hardware journey.

Evidence: [client](/Users/augstar/macprovider-poc/phase5-gateway/cmd/relay-blind-client/main.go:37), [fixture backend](/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/RelayBlindFixtureCommand.swift:107), [console ownership](/Users/augstar/macprovider-poc/frontdoor/console/README.md:12).

### 3. Production Compute Observations and First-Job Visibility

Outcome: Mining Health can distinguish verified current earning, uncertainty, and idle from authoritative data.

First build a bounded observation pilot for one covered model/runtime/profile key: real probe execution and ingestion, reference/calibration inputs, generation-aware state, expiry/revocation, and a sanitized production status source. Reuse existing compute-integrity primitives; do not infer provider-wide verification from one passing key.

Then define the governed mapping into reward eligibility. Add an authoritative mirror progress/freshness contract and expose observation lag separately from idle. Validate a real request through receipt, mirror, accrual and app/portal activity.

This is more than wiring an endpoint. Current projection explicitly sets compute unknown; the classifier cannot produce earning/eligible_idle through this path. Adding a mirror watermark alone cannot change that. Observation success also does not independently authorize enforce-mode or economic activation.

Accept when one real Mac produces attributable observations and a correctly sourced reward state; model change, restart, expired evidence and reference failure cannot retain unsupported positive state. Independently test fresh absence of work versus delayed mirror observations.

Evidence: [unknown source](/Users/augstar/macprovider-poc/phase4-coordinator/internal/rewards/projection.go:105), [earning precedence](/Users/augstar/macprovider-poc/phase4-coordinator/internal/rewards/read_model.go:233), [missing runtime source](/Users/augstar/macprovider-poc/phase4-coordinator/internal/ws/compute_integrity_status.go:84), [activation prerequisites](/Users/augstar/macprovider-poc/phase4-coordinator/internal/computeintegrity/activation.go:76).

### 4. Private Requests With Trusted-Pool and Verified-Settlement Policy

Outcome: selected organizations can combine pool policy and request encryption without weakening existing settlement guarantees.

Today these tracks do not compose: relay-blind routing rejects pool selection; enabling it under settlement enforce mode is rejected; relay-blind work is excluded from positive verification and MALIBU useful-work rewards.

Define and review the receipt/digest and routing-policy contracts first. Build pool-scoped reservations and lifecycle rechecks, then the governed verified-settlement integration. Restore existing plaintext guarantees and evidence where mapped implementation changed. Keep stronger compute/hardware claims separate from provider-signed receipt evidence.

Accept when allowed private-pool requests succeed, unauthorized members/models and revoked keys fail, receipt/digest substitution cannot settle, and ordinary enforce traffic remains unchanged. Reward eligibility for private traffic requires its own valid evidence path; do not remove exclusion flags just to make a dashboard show earnings.

Trusted Pool production qualification can proceed independently for a design partner; it need not wait for this composition feature.

Evidence: [pool rejection](/Users/augstar/macprovider-poc/phase4-coordinator/internal/buyer/relay_blind.go:177), [enforce-mode gate](/Users/augstar/macprovider-poc/phase4-coordinator/internal/config/config.go:2306), [explicit exclusions](/Users/augstar/macprovider-poc/phase4-coordinator/internal/buyer/billing_recorder.go:358), [pool promotion](/Users/augstar/macprovider-poc/phase4-coordinator/internal/trustpool/durable_store.go:3178).

### 5. Measured Network Capacity

Outcome: more concurrent buyer work per Mac with bounded latency, memory and cancellation behavior.

Use current queue/latency/capacity telemetry to establish a real-hardware baseline and representative request mix. Integrate the actual paged-KV/runtime bridge and production batching backend behind the existing gates, starting with a supported model/request subset.

Accept against explicit baseline-relative throughput, latency and memory gates agreed before implementation. Include heterogeneous lengths, cancellation, pressure, supported-feature parity, and serial fallback for unsupported tool/structured-output/logprob state. Runtime benchmarks, not scheduler unit tests, establish the gain.

Start a bounded hardware benchmark/bridge experiment in parallel with product work if engineering capacity permits. Promote full implementation earlier only if measured workload is capacity-constrained.

Evidence: [backend unavailable](/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1870), [feature representation gates](/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1887), [paged cache not injected](/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/PagedKVCache.swift:53).

### 6. Economic Maturity: Separate USDC From MALIBU

USDC: existing payout execution is a separately gated operator/release track. Review current deployment readiness and funding/reconciliation evidence, then qualify and activate only with explicit production authorization. It need not wait for unrelated privacy SDK or throughput work once its own prerequisites are met.

MALIBU: v0.2 accrual validation does not implement v0.4 epochs or token withdrawals. Build an epoch policy engine only when the issuance/cap/disposition policy and operating inputs are ready. Build MALIBU payment execution as a distinct contract and implementation, not as a UI toggle on the USDC runner.

Accept USDC payment only with confirmed transaction/reconciliation and safe duplicate/recovery behavior. Accept MALIBU issuance and withdrawal only with authoritative epoch/disposition accounting and independently tested transfer finality. Never imply historical eligible balances equal available payment execution.

Evidence: [USDC runner](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:131), [future MALIBU runner](/Users/augstar/macprovider-poc/phase4-coordinator/internal/rewards/withdrawal.go:17), [epoch unavailable guard](/Users/augstar/macprovider-poc/phase4-coordinator/internal/rewards/useful_work.go:26).

## Parallel Release and Evidence Track

Qualify the combined landed provider build, installer/updater and app packaging. Test real model execution and the complete encrypted journey, not two unrelated success reports. Verify current full Swift/Xcode status rather than treating historical baseline failures as current facts.

Re-capture protected journey evidence where required and retain explicit separation of local fixture, physical hardware, release-qualified and production evidence. Pools and privacy remain gated until their own prerequisites are discharged. No production activation is authorized by this roadmap.

## Fresh Validation in This Assessment

Passed:
- Coordinator: `go test ./internal/rewards -count=1`.
- Coordinator: `go test ./internal/relayblind ./internal/buyer -run 'RelayBlind|GoldenVector|KeyRecord|IdentityPin' -count=1`.
- Gateway: `go test ./internal/router -run RelayBlind -count=1` (executed in a multi-package command).
- Gateway: `go test ./internal/relayblind ./cmd/relay-blind-client -count=1`.

An initial RelayBlind name filter selected no tests in the crypto/client packages; both were subsequently rerun without that filter and passed. No no-test result is counted as validation.

Docker daemon was unavailable; PostgreSQL rewards journeys were inspected but not rerun. No fresh Swift/Xcode, encrypted hardware journey, deployed configuration, external buyer-console inspection or payment execution was performed. Landed commit/review notes report broader prior checks, but those are historical evidence, not new results from this session.

Confidence: high in the specific landed-code boundaries; medium in sequencing because customer commitments, load and available staffing were not supplied. The roadmap should be revisited after first real-model private use, self-service admission, and observed capacity data.


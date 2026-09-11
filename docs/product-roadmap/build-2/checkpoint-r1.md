# Product Build 2 planning checkpoint

**Checkpoint revision:** R1
**Status:** planning complete; implementation has not started and remains prohibited until the independent plan gate passes
**MacProvider branch:** `codex/product-build-2`
**MacProvider base:** `1d2c930bad81704dd0acc0322226725d8b64aceb` (`origin/main`)
**Malibu inspection base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13` (`MalibuAI/malibu` `origin/main`)
**Inspection date:** 2026-09-11

## Durable artifacts submitted to the plan gate

| Artifact | SHA-256 |
|---|---|
| `baseline-assessment.md` | `be9131d12ef5974938adf8a4fe552362141fec53f97092f7c952fef2b20a6947` |
| `prd-implementation-plan-r1.md` | `c5a68ba5b275f969dad0010f547e866b5621d16846f8ad16c342d6cb7df09b53` |
| `test-spec-r1.md` | `cbb4c5a58eb3e9cec2dc0419ba2e998bd1a4d8626da4997573bf572b45a9e6a4` |

The gate must review these exact bytes and both repository revisions. A revision to the plan or test specification changes its digest and requires a fresh review.

## Inspection result

- **Landed:** the default-off relay-blind transport pilot, signed provider identity/key verification, exact provider/session reservation binding, no-ciphertext-failover invariant, API-key and wallet request authentication, deterministic Swift provider nonstreaming/streaming journeys, and provider-plaintext disclosures in current pilot surfaces.
- **Partial:** reusable buyer client support, typed error handling, public recovery/status workflow, cancellation/reconnect/replay coverage through a supported client, and provider-plaintext truth across all buyer-facing surfaces.
- **Missing:** coordinator-side acceptable-identity filtering before encryption; A-only/A+B account trust profiles; authenticated provisioning/replacement/revocation; two-provider journeys; Malibu Request encryption UI/transport; and actual encrypted MLX end-to-end evidence.
- **Blocked/unproven:** actual MLX hardware acceptance and production qualification. The Malibu repository is available, but its implementation is a separate dependent repository change and was not started during this planning checkpoint.

The critical implementation boundary is explicit: an authenticated server profile read is synchronization/status only and cannot bootstrap client trust. The buyer must first import and confirm the public identity bundle locally. Buyer approval narrows coordinator selection but does not grant provider admission, model identity, pricing authority, verified settlement, or rewards.

## Fresh verification evidence

All commands ran from the Build 2 worktree at the exact MacProvider base before documentation was committed.

| Command | Fresh result |
|---|---|
| `cd phase4-coordinator && go test ./internal/relayblind ./internal/buyer -run 'RelayBlind|GoldenVector|KeyRecord|IdentityPin' -count=1` | PASS: `internal/relayblind` 1.766s; `internal/buyer` 1.459s. |
| `cd phase5-gateway && go test ./internal/relayblind ./cmd/relay-blind-client -count=1` | PASS: `internal/relayblind` 0.576s; client 1.149s. |
| `cd phase5-gateway && go test ./internal/router -run '^TestRelayBlind' -count=1` | PASS: 7.453s. |
| `cd test/integration && go test -run '^TestRelayBlind(ReservationFailClosedAcrossRealServices|DisabledEnvelopeDoesNotLeakOpaqueMaterial|ReplaySurvivesGatewayRestartAndEnableCycle|ConcurrentEnvelopeAdmitsAtMostOnce)$' -race -count=1 -timeout 5m` | PASS: 18.987s. Go-provider fail-closed/replay evidence only. |
| `cd test/integration && go test -run '^TestRelayBlindSwiftProvider(NonstreamEndToEnd|StreamEndToEnd)$' -count=1 -timeout 15m` | PASS: 162.212s. Real Swift provider process with deterministic `RelayBlindFixtureRuntime`; not actual MLX evidence. |
| `git diff --check` | PASS after restoring the test-generated `phase3-binary/Package.resolved` change. |

No fresh browser, actual MLX, deployed-service, or production test is claimed. No timed-out, skipped, zero-selected, fixture-only, or historical run is represented as higher-grade acceptance evidence.

## Required independent gate

An independent native GPT-5.6 Sol reviewer must inspect the code and challenge the exact R1 plan/test specification for feasibility, prerequisites, trust boundaries, economics, UX truthfulness, failure recovery, cross-repository ownership, and proof strength. Findings must include severity, evidence, consequence, and required correction. Implementation may begin only after the reviewer reports zero Critical, High, and Medium findings on the final exact revision.

The independent gate is pending at this checkpoint because the parent implementation lead owns reviewer allocation. This checkpoint does not claim approval.

## Handoff and blockers

1. Run the independent plan gate against the exact artifact digests above. Revise and recommit if any Critical, High, or Medium finding remains.
2. After approval, implement the MacProvider normative contract and acceptable-identity reservation binding before client or Malibu work.
3. Keep the Malibu change in its own fresh hidden worktree and dependent branch if the MacProvider API prerequisite is unmerged. Report its diff separately.
4. Run the physical-Mac actual MLX journey before claiming hardware acceptance. Deterministic Swift fixtures remain necessary but insufficient.
5. Keep deployment, release, production activation, verified private settlement, rewards, payouts, and Trusted Pools outside Build 2 authority.

Build 2 planning and most local implementation are independent of unfinished Build 1 BYOM work when they use an already-supported, cached model artifact. Hardware acceptance still depends on a suitable cached artifact and available Apple Silicon environment.

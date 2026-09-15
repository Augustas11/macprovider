# Product Build 4 assessment evidence v1

Assessment date: 2026-09-11  
Repository/worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-4`  
Branch: `codex/product-build-4`  
Inspected base: `1d2c930bad81704dd0acc0322226725d8b64aceb`  
Historical roadmap baseline: `422fc2f13fc62c1ff8987522f822d9ef856e4a96`

## Source inspection

- Read repository `AGENTS.md` and `CLAUDE.md` before writing.
- Read `/private/tmp/macprovider-roadmap/.omx/plans/product-roadmap-422fc2f1.md`. The historical roadmap file was present.
- Read the current `specs/AUTHORITY.json`, relevant `specs/CONFORMANCE.json` entries, SPEC-015, SPEC-022, SPEC-036, SPEC-041, and SPEC-042.
- Inspected current relay-blind gateway/coordinator/provider protocol types, durable reservation store, billing recorder, route snapshot and settlement verifier, trust-pool registry, ordinary pool routing, and focused tests.
- Queried open pull requests for relay-blind, pool, private, compute, observation, receipt, and settlement work. No relevant open pull request was returned.
- Compared relevant paths from `422fc2f1` to the inspected base. Subsequent relevant changes were BYOM artifact-identity additions to settlement snapshots; no SPEC-041/SPEC-042 private-pool composition contract landed.

## Fresh focused verification

All commands finished successfully and selected the named tests.

1. Pool identity route-snapshot binding and settlement reload:

   ```text
   cd phase4-coordinator
   go test ./internal/billing -run 'TestRouteSnapshotPoolID_(DigestBinding|RoundTripsThroughSettlementLoader)$' -count=1
   ok github.com/augstar/macprovider-coordinator/internal/billing 0.724s
   ```

2. Ordinary Trusted Pool revocation/generation protection plus relay-blind truthful disclosure:

   ```text
   cd phase4-coordinator
   go test ./internal/buyer -run 'TestPoolIsolation_(RevokedMemberRejectedImmediately|LoopFenceRejectsStaleBeforeDispatch|ActiveDispatchContextCancelledOnImmediateRevoke)$|TestRelayBlindErrorCarriesCompletePrivacyMetadata$' -count=1
   ok github.com/augstar/macprovider-coordinator/internal/buyer 0.727s
   ```

3. Gateway pool authorization/capability behavior and plaintext compatibility:

   ```text
   cd phase5-gateway
   go test ./internal/router -run 'TestPoolSelection_(AuthorizedAndCapable_EmitsHeader|Unauthorized_FailsClosedWithoutCapabilityFetch|OldCoordinatorNoAdvertisement_FailsClosed|WalletSessionCannotSelectPool)$|TestRelayBlindProbePreservesDefaultOffPlaintextCompatibility$' -count=1
   ok github.com/augstar/macprovider-gateway/internal/router 1.105s
   ```

4. Cross-service deliberate rejection of pool-scoped relay-blind reservation before quota or dispatch:

   ```text
   cd test/integration
   go test -run '^TestRelayBlindReservationRejectsPoolSelectionBeforeQuota$' -count=1
   PASS
   ok github.com/augstar/macprovider-integration 10.243s
   ```

## Evidence boundary

These tests prove that the inspected base retains its deliberate restrictions and selected plaintext/pool protections. They do not prove a private Trusted Pool request, a successor receipt contract, independently observed compute, actual MLX inference, deployment, production qualification, rewards, or payouts.

No source was changed and no Build 4 implementation test exists yet. The worktree contains planning artifacts only.

# Build 1 slice: runtime rate-card billing parity test specification v3

Status: proposed with `rate-card-runtime-parity-plan-v3.md` for base `7beeb8d8a5955eb225528cde53497326643e7d3a`. Supersedes v2 after independent Sol review found a Tier-2 staging-order gap. This spec is coordinator-only economics authority coverage, not full Product Build 1 acceptance.

## A. Buyer helper tests

1. `TestRuntimeRateCardParityNoSignedFeedIsNoop`: zero `AutotuneFeeds` returns nil for arbitrary rewards/USD.
2. `TestRuntimeRateCardParityAcceptsMatchingSignedFeed`: loaded signed feed rows/globals/USD match effective config and return nil.
3. `TestRuntimeRateCardParityRejectsRowKeyDrift`: missing row, extra row, and normalized projection key drift reject.
4. `TestRuntimeRateCardParityRejectsExactAliasOverrideDrift`: canonical signed/effective row A plus exact served alias row B that `billing.RateFor` would select rejects; identical alias A succeeds or is safely tolerated.
5. `TestRuntimeRateCardParityRejectsRateDrift`: prompt, prompt-cache-hit, completion drift each reject.
6. `TestRuntimeRateCardParityRejectsGlobalEconomicsDrift`: provider share, global multiplier, and USD conversion drift each reject.
7. `TestRuntimeRateCardParityRejectsMalformedRateCardBytes`: malformed bytes return error if helper parses bytes directly; signature trust remains covered by existing `LoadAutotuneFeeds` tests.

## B. Coordinator boot/SIGHUP seam tests

Add side-effect-free seams in `phase4-coordinator/cmd/coordinator`, such as `validateAutotuneRuntimeEconomics(feeds buyer.AutotuneFeeds, cfg config.Config) error` and a SIGHUP candidate-served-feed selector. Tests must prove call-site behavior.

1. `TestCoordinatorRuntimeRateCardParityAcceptsBootMatch`: matching signed feed/effective config returns nil.
2. `TestCoordinatorRuntimeRateCardParityRejectsBootOverlayDrift`: overlay drift returns error, and acceptance report cites source line ordering before `InsertConfigSnapshot`, listener setup, catalog/feed publication, and Tier-2 staging/publication.
3. `TestCoordinatorSIGHUPRuntimeRateCardParityRejectsNewFeedBeforeAnyStagingOrPublication`: candidate reloaded feed drift returns error before `tier2.ConfigureDefaultStrict`, any `StageTier2` hook, `wsServer.SetTier2Config`, `buyerServer.SetTier2Config`, `ReloadBillingConfigV05`, `buyerServer.SetBillingConfig`, `billingStore.SetSettlementConfig`, `wsServer.SetAutotuneCatalog`, `buyerServer.SetAutotuneFeeds`, and `RefreshTier2HashStatuses`.
4. `TestCoordinatorSIGHUPRuntimeRateCardParityRejectsRetainedLiveFeedDrift`: live server has signed feed A; reload clears paths or does not produce new feeds; effective billing drifts. Candidate selector uses incumbent feed A, validation rejects, and previous feed/billing state remains unchanged.
5. `TestCoordinatorSIGHUPRuntimeRateCardParityLeavesNoStagedTier2Material`: use the smallest fake/stub seam available to prove a parity rejection returns before any release-staging callback can record Tier-2 material; if no fake hook exists, the test must assert the pure validator is invoked before the call to `tier2.ConfigureDefaultStrict` and the acceptance report must cite exact line ordering.
6. `TestCoordinatorSIGHUPRuntimeRateCardParityNoopWhenNoLiveSignedFeed`: no reloaded feed and no incumbent signed feed no-ops so fallback deployments can reload billing config.

## C. Regression commands

Run at least:

```bash
cd phase4-coordinator && go test ./internal/buyer -run 'TestRuntimeRateCardParity|TestRateCardProjection|TestSetBillingConfigReloadsRateCardUSDCredits|TestLoadAutotuneFeeds' -count=1
cd phase4-coordinator && go test ./cmd/coordinator -run 'TestCoordinator.*RateCard.*Parity|Test.*SIGHUP.*RateCard' -count=1
```

After implementation stabilizes:

```bash
cd phase4-coordinator && go test ./internal/buyer ./cmd/coordinator -count=1
cd phase4-coordinator && go test ./... -run 'RateCard|AutotuneFeeds|SIGHUP|BillingConfig|Tier2' -count=1
```

Before PR handoff, run `make test-coordinator` unless blocked; report blockers without claiming pass.

## D. Acceptance evidence rules

- Skipped, zero-selected, timed-out, fixture-only, or historical runs do not count.
- Helper-only coverage is insufficient; boot and SIGHUP ordering need seam tests plus source-order evidence.
- No physical Mac, production coordinator, Docker, or MLX inference evidence is expected for this slice.

## E. Failure and rollback assertions

- Boot mismatch: no billing snapshot, listener, catalog/feed publication, or Tier-2 staging/publication.
- SIGHUP mismatch with new feeds: no Tier-2 staging, tier2 publication, billing reload, settlement config mutation, catalog swap, feed swap, or staged-material promotion.
- SIGHUP mismatch with retained live feed: previous signed feed and billing state remain live.
- No signed feed: fallback `/v1/rate-card` remains generated from effective config.

## F. Audit requirements

After implementation and tests, run independent GPT-5.6 Sol code, security, and architecture review lanes over the complete diff. The slice is not done until all Critical/High/Medium findings are fixed or a material scope change reopens the plan gate.

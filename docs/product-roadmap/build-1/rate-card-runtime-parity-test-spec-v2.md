# Build 1 slice: runtime rate-card billing parity test specification v2

Status: superseded by v3 after independent Sol plan-gate review found one Medium Tier-2 staging-order gap; kept for audit history. Was proposed with `rate-card-runtime-parity-plan-v2.md` for base `7beeb8d8a5955eb225528cde53497326643e7d3a`. Supersedes v1 after independent Sol review found coverage gaps. This spec covers coordinator-only economics authority; it is not full Product Build 1 acceptance evidence.

## A. Buyer helper tests

Add focused tests in `phase4-coordinator/internal/buyer`.

1. `TestRuntimeRateCardParityNoSignedFeedIsNoop`
   - Zero `AutotuneFeeds`, arbitrary effective rewards/USD.
   - Expect nil.

2. `TestRuntimeRateCardParityAcceptsMatchingSignedFeed`
   - Use existing signed feed fixture helpers or construct `AutotuneFeeds` through `LoadAutotuneFeeds`.
   - Effective rows, provider share, global multiplier, and USD match signed rows.
   - Expect nil.

3. `TestRuntimeRateCardParityRejectsRowKeyDrift`
   - Missing effective row for a signed row rejects.
   - Extra effective row absent from signed feed rejects.
   - Normalized alias that changes the public projection key set rejects.

4. `TestRuntimeRateCardParityRejectsExactAliasOverrideDrift`
   - Signed feed has canonical row `meta-llama/llama-3.1-8b` with rates A.
   - Effective config contains matching canonical row A and exact served alias row, such as `llama-3.1-8b`, with rates B that `billing.RateFor` would choose before normalized fallback.
   - Expect rejection even though public projection could collapse to the canonical row.
   - Also test identical alias row A succeeds or is harmless if the implementation chooses to allow identical duplicates.

5. `TestRuntimeRateCardParityRejectsRateDrift`
   - Prompt, prompt-cache-hit, and completion drift each reject.
   - Include omitted YAML cache-hit/default-to-prompt semantics where practical.

6. `TestRuntimeRateCardParityRejectsGlobalEconomicsDrift`
   - Provider share mismatch using `billing.ParseShareBps` semantics.
   - Global multiplier mismatch using `billing.ParseMultiplierPPM` semantics.
   - USD-per-million-credits mismatch.

7. `TestRuntimeRateCardParityRejectsMalformedRateCardBytes`
   - If helper parses bytes, malformed signed bytes return an error. Signature trust stays covered by existing `LoadAutotuneFeeds` tests.

## B. Coordinator boot/SIGHUP seam tests

Add the smallest side-effect-free seam in `phase4-coordinator/cmd/coordinator`, for example `validateAutotuneRuntimeEconomics(feeds buyer.AutotuneFeeds, cfg config.Config) error` and, for reload, a pure selector for the candidate served feed set. Tests must prove call-site behavior, not only buyer helper behavior.

1. `TestCoordinatorRuntimeRateCardParityAcceptsBootMatch`
   - Matching signed feed/effective config returns nil.

2. `TestCoordinatorRuntimeRateCardParityRejectsBootOverlayDrift`
   - Effective config after overlay changes a row/global/USD away from signed feed.
   - Validation returns error before boot reaches billing snapshot insertion.
   - Acceptance report must cite source line ordering before `InsertConfigSnapshot`, listener setup, and catalog/feed publication.

3. `TestCoordinatorSIGHUPRuntimeRateCardParityRejectsNewFeedBeforePublication`
   - Candidate reloaded feed has mismatch with effective config.
   - Test seam proves parity validation is called before `wsServer.SetTier2Config`, `buyerServer.SetTier2Config`, `ReloadBillingConfigV05`, `buyerServer.SetBillingConfig`, `billingStore.SetSettlementConfig`, `wsServer.SetAutotuneCatalog`, and `buyerServer.SetAutotuneFeeds`.
   - Source line-order proof is acceptable only with a focused seam test.

4. `TestCoordinatorSIGHUPRuntimeRateCardParityRejectsRetainedLiveFeedDrift`
   - Live server already serves signed feed A.
   - Reload config clears feed paths or otherwise does not produce `haveReloadedAutotune`, while effective rewards/USD drift from feed A.
   - Candidate served feed selector returns incumbent feed A for parity.
   - Validation rejects before any publication; previous feed and billing state remain unchanged in the tested seam or server fixture.

5. `TestCoordinatorSIGHUPRuntimeRateCardParityNoopWhenNoLiveSignedFeed`
   - No reloaded feed and no incumbent signed feed.
   - Validation no-ops so no-feed fallback deployments can still reload billing config.

## C. Existing regression tests to keep green

Run at least:

```bash
cd phase4-coordinator && go test ./internal/buyer -run 'TestRuntimeRateCardParity|TestRateCardProjection|TestSetBillingConfigReloadsRateCardUSDCredits|TestLoadAutotuneFeeds' -count=1
cd phase4-coordinator && go test ./cmd/coordinator -run 'TestCoordinator.*RateCard.*Parity|Test.*SIGHUP.*RateCard' -count=1
```

After implementation stabilizes, run:

```bash
cd phase4-coordinator && go test ./internal/buyer ./cmd/coordinator -count=1
cd phase4-coordinator && go test ./... -run 'RateCard|AutotuneFeeds|SIGHUP|BillingConfig' -count=1
```

Before PR handoff, run `make test-coordinator` unless runtime constraints block it; record any blocker without claiming the blocked check passed.

## D. Acceptance evidence rules

- Skipped, zero-selected, timed-out, fixture-only, or historical runs do not count as fresh acceptance evidence.
- Helper-only tests are insufficient; boot and SIGHUP call sites need seam tests plus source ordering evidence.
- No physical Mac, production coordinator, Docker, or MLX inference evidence is expected for this slice. Full Build 1 hardware qualification remains blocked.

## E. Failure and rollback assertions

- Boot mismatch: no billing snapshot, listener, tier2/catalog/admission publication, or feed serving after parity error.
- SIGHUP mismatch with new feeds: previous tier2, billing, settlement, catalog, and feed state remain live.
- SIGHUP mismatch with retained live feed: previous signed feed remains live and billing is not changed to drift from it.
- No signed feed: fallback `/v1/rate-card` remains generated from effective config.

## F. Audit requirements

After implementation and local tests, run independent GPT-5.6 Sol code, security, and architecture review lanes over the complete diff. The slice is not done until every Critical, High, and Medium finding is fixed or a material-scope change reopens the plan gate.

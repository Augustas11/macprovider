# Build 1 slice: runtime rate-card billing parity test specification v1

Status: superseded by v2 after independent Sol plan-gate review found High/Medium coverage gaps. Kept for audit history. Base was `7beeb8d8a5955eb225528cde53497326643e7d3a`. This test spec covers a coordinator-only economics authority guard. It is not fresh evidence of full Product Build 1 acceptance.

## Test inventory

### A. Buyer helper tests

Add focused tests in `phase4-coordinator/internal/buyer` for the runtime parity helper.

1. `TestRuntimeRateCardParityNoSignedFeedIsNoop`
   - Construct zero `AutotuneFeeds` and arbitrary effective `RewardsConfig`/USD.
   - Expect nil.
   - Purpose: preserve deployments that serve fallback generated `/v1/rate-card`.

2. `TestRuntimeRateCardParityAcceptsMatchingSignedFeed`
   - Build a signed loaded feed fixture using existing feed helper patterns, or construct an `AutotuneFeeds` whose `RateCardJSON` has already passed `LoadAutotuneFeeds` in the test.
   - Effective config rows, provider share, global multiplier, and USD match feed rows.
   - Expect nil.
   - Also compare helper acceptance to the current fallback projection for the same config.

3. `TestRuntimeRateCardParityRejectsRowKeyDrift`
   - Missing signed row from effective config: expect error containing `missing` and row key.
   - Extra effective config row absent from signed feed: expect error containing `extra` and row key.
   - Include a normalized alias case to prove matching uses the same normalized row map as `buildRecommendationRateCardRows`.

4. `TestRuntimeRateCardParityRejectsRateDrift`
   - Prompt rate mismatch.
   - Prompt cache hit rate mismatch, including a case where omitted YAML cache-hit defaults to prompt credits.
   - Completion rate mismatch.
   - Expect stable field-specific error text.

5. `TestRuntimeRateCardParityRejectsGlobalEconomicsDrift`
   - Provider share mismatch, using `billing.ParseShareBps` rounding semantics.
   - Global multiplier mismatch, using `billing.ParseMultiplierPPM` rounding semantics.
   - USD-per-million-credits mismatch.
   - Expect stable field-specific error text.

6. `TestRuntimeRateCardParityUsesValidatedFeedSemantics`
   - Ensure the helper does not accept malformed rate-card bytes directly as trusted input. If the helper parses bytes itself, malformed bytes must return an error; signed/tampered trust remains owned by existing `LoadAutotuneFeeds` tests.

### B. Coordinator boot/reload seam tests

Add the smallest testable seam that proves call-site enforcement, not only helper logic. Acceptable options:

- Extract a small unexported function in `cmd/coordinator/main.go`, for example `validateAutotuneRuntimeEconomics(feeds, cfg) error`, and test it from `main` package tests; or
- Add a coordinator reload test that exercises SIGHUP handler wiring without opening production listeners; or
- If no safe seam exists, add a testable wrapper with no side effects and cite direct boot/reload call-site line coverage in the acceptance report.

Required cases:

1. `TestCoordinatorRuntimeRateCardParityRejectsBootOverlayDrift`
   - Effective config after overlay differs from signed feed.
   - Function returns error before any billing snapshot/publish step is reachable.

2. `TestCoordinatorRuntimeRateCardParityAcceptsBootMatch`
   - Effective config matches signed feed.
   - Function returns nil.

3. `TestCoordinatorSIGHUPRuntimeRateCardParityRejectsBeforePublication`
   - Previous buyer server state has rate-card version A and billing config A.
   - Reload candidate has signed feed B but effective rewards or USD B' mismatch.
   - Reload path returns before `SetBillingConfig` and `SetAutotuneFeeds`; previous `AutotuneFeedsForTest()` and rate-card projection remain A.
   - If a full reload harness is too costly, split this into a call-order test around a helper that is called before publication, then verify with source references and a targeted unit test.

### C. Existing regression tests to keep green

Run at least:

```bash
cd phase4-coordinator && go test ./internal/buyer -run 'TestRuntimeRateCardParity|TestRateCardProjection|TestSetBillingConfigReloadsRateCardUSDCredits|TestLoadAutotuneFeeds' -count=1
cd phase4-coordinator && go test ./cmd/coordinator -run 'Test.*RateCard.*Parity|Test.*SIGHUP.*RateCard' -count=1
```

If `./cmd/coordinator` has no package tests or the helper lands elsewhere, replace the second command with the exact package/test names that cover boot/reload call sites and record the substitution.

After implementation stabilizes, run:

```bash
cd phase4-coordinator && go test ./internal/buyer ./cmd/coordinator -count=1
cd phase4-coordinator && go test ./... -run 'RateCard|AutotuneFeeds|SIGHUP|BillingConfig' -count=1
```

Broader validation before PR handoff should include at minimum `make test-coordinator` unless runtime or dependency constraints block it.

## Acceptance evidence rules

- A skipped, zero-selected, timed-out, or fixture-only run cannot be reported as passing an acceptance criterion it does not exercise.
- Historical CI from PR #1487 is not evidence for this slice.
- Helper-only tests are insufficient unless boot and SIGHUP call sites are also inspected and covered by a targeted seam test.
- No physical Mac or production coordinator evidence is expected for this slice; those remain named Build 1 qualification blockers.

## Failure and rollback assertions

- On boot mismatch, no listener, signed feed serving, or billing snapshot should occur after the parity error. If this cannot be observed directly in a unit test, the call must remain before the first side-effecting startup step and the acceptance report must cite the exact line ordering.
- On SIGHUP mismatch, live state must remain unchanged: previous feed bytes, previous billing config, previous rate-card version, and previous settlement config stay active.
- Removing configured signed feed paths should leave fallback `/v1/rate-card` generated from effective billing config.

## Audit requirements

After implementation and local tests, run independent GPT-5.6 Sol code, security, and architecture review lanes over the complete diff. The slice is not done until all Critical, High, and Medium findings are fixed or the plan gate is reopened for material changes.

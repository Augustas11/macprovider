# Audit lane: CODE REVIEW — Malibu first-run provider UX (P0–P3)

Independent code-review auditor. Review the COMPLETE fix diff as it will land.
Do not assume it is correct.

## What to review
Full diff (read first): `audits/2026-08-31-first-run-ux-reaudit/full-fix.diff`
Then the surrounding source:
- `phase3-binary/app/Sources/Malibu/Agent/AgentSnapshot.swift` (AgentSnapshotPresenter: miningHealth, isMalibuProjectionWarmingUp, usdcFullLine, usdcTodayDisplay, malibuFullLine, malibuHoldLine, malibuTodayCaption, rewardReasonNextAction, trustLine, trustCriteria, trustUnlockSummary, consolidatedStatus, TrustCriterion)
- `phase3-binary/app/Sources/Malibu/Dashboard/DashboardWindow.swift` (miningTone, phaseTone, trustTierDisclosure, somethingWrongSection, howEarningWorksSection, consolidated status card, advancedDiagnosticsExpanded)
- `phase3-binary/app/Sources/Malibu/Agent/EarningsClient.swift`, `MalibuAgent.swift`
- `phase3-binary/Sources/macprovider-cli/ProviderEarningsClient.swift` (ProviderEarningsSummary new fields + CodingKeys + decode + merge/factory reconstructors + merging(walletStatus:))

## Context / intent
Fixes a shipped-1.8.115 first-run dashboard that painted BENIGN new-account states (no wallet, MALIBU projection warming up, no earnings yet) as red alarms full of "n/a". The key case: a provider WITH USDC earnings but MALIBU projection unavailable must read calm, not red. A genuine telemetry/outage failure must still read as a problem. New per-criterion trust data is threaded CLI→app over the `provider_earnings` control-socket frame (4 optional fields).

## Focus (find real defects)
1. **State-classification correctness.** `isMalibuProjectionWarmingUp` must be TRUE only for the benign case and FALSE for (a) genuine outage/not-admitted, (b) a provider that really has MALIBU amounts. Can any real state be misclassified — e.g. a genuine failure shown as calm "warming up", or real earnings hidden as $0.00? Trace every branch of miningHealth/reason-code split.
2. **Honest numbers.** usdcFullLine/usdcTodayDisplay/malibuFullLine render $0.00 for "fresh, nothing yet" and a non-hero "—"/"not available" for genuine failure. Verify the fresh-vs-failure discriminator (providerEarningsFresh/hasObserved…/frame presence) is correct and cannot render a fabricated authoritative $0.00 during an actual fetch failure. The implementer flagged: fresh frame with `today` but missing wk/accrued/life renders those as $0.00 → could read "life < today". Assess severity.
3. **Wire-contract compat.** The 4 new fields on ProviderEarningsSummary / ProviderEarnings / provider_earnings frame: confirm decode is `decodeIfPresent` with safe defaults everywhere, all reconstructors/merge paths forward them, and an OLD app reading a NEW frame (and vice-versa) does not crash or misrender. Any CodingKey typo or missed merge path?
4. **Trust criteria rendering.** trustCriteria maps satisfied criterion IDs (SPEC-026 A1/A3/A4/E1/E2/E3) to 2 named rows. Off-by-one in "N of 2"? Can it show a criterion as done when it isn't, or claim Trusted grants something false?
5. **SwiftUI correctness.** New disclosures (trustTierDisclosure, somethingWrong, howEarningWorks) and consolidatedStatus card — any state that produces an empty/incoherent card, a missing next-action, or a retained dead control.
6. Test adequacy: do the added tests actually cover the warming-up-vs-outage split and the wire round-trip, or just pin copy?

## Output
Per finding: SEVERITY (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, concrete failure scenario, fix. End with `GATE: PASS` (0 C/H/M) or `GATE: FAIL`.

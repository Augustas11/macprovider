# CODE REVIEW RESULT - Malibu first-run provider UX

GATE: FAIL

## HIGH

1. `phase3-binary/Sources/macprovider-cli/ProviderEarningsClient.swift:298`
   Issue: `markingWalletStatusUnavailable()` turns a wallet-status schema/shape failure into a fresh MALIBU projection with `walletBound: false`, nil reward amounts, and `MalibuRewardEligibility.unavailableForMissingObject()`. The app then satisfies `AgentSnapshotPresenter.isMalibuProjectionWarmingUp` (`phase3-binary/app/Sources/Malibu/Agent/AgentSnapshot.swift:795`) for any buyer-serving provider, and `miningHealth` reaches the earlier `walletBound == false` branch (`AgentSnapshot.swift:625`) before it can report a genuine telemetry problem.
   Concrete failure scenario: provider earnings fetch succeeds with real USDC, but `/v1/provider/wallet-status` has schema drift or a decode-only shape change. `ProviderWalletStatusSummary` marks that response `unavailable`, `ControlMetricsBuilder` merges it via `markingWalletStatusUnavailable()`, and Malibu displays "No payout wallet yet" plus "MALIBU rewards warming up" even though the wallet/reward telemetry failed. That violates the lane requirement that genuine telemetry/outage failures must not be softened into the benign first-run warming state.
   Fix: Do not represent wallet-status unavailability as a fresh benign MALIBU projection or as an authoritative missing wallet. Preserve prior wallet truth where available, set `malibuProjectionFresh` false or carry an explicit unavailable reason, and make `isMalibuProjectionWarmingUp` exclude `telemetry_unavailable`/schema-drift sentinels. Add a regression test for a fresh earnings frame plus wallet-status schema drift.

2. `phase3-binary/app/Sources/Malibu/Agent/AgentSnapshot.swift:1830`
   Issue: `trustCriteria(_:)` marks the "Verified customer work" row done whenever `economicCriteria` is non-empty, and marks the "Time online" row done whenever `additionalCriteria` is non-empty. Those arrays carry raw SPEC-026 IDs, not those two display rows. The coordinator can emit `E1` in both economic and additional lists, and can emit the overlapping wallet-balance pair `E2`/`A3`; SPEC-026 says overlapping IDs do not satisfy the two distinct unlock slots.
   Concrete failure scenario: a provider has only the wallet-balance qualification, so the coordinator reports `economic_criteria: ["E2"]`, `additional_criteria: ["A3"]`, `criteria_met: 2`, `criteria_required: 2`, but remains Provisional because `E2` and `A3` overlap. Malibu renders "Verified customer work" as done, "Time online" as done, and `trustLine` can say "Provisional - 2 of 2 criteria met" (`AgentSnapshot.swift:1799`). The provider sees all criteria complete while Trusted is still correctly locked.
   Fix: Render criterion IDs by their actual meanings (`E1` receipts, `E2` wallet balance, `E3` operator promotion, `A1` uptime, `A3` wallet balance, `A4` App Attest), and compute/display the distinct unlock-pair status instead of using array non-emptiness. If the UI must stay at two rows, make the rows "Economic criterion" and "Distinct additional criterion" and treat overlapping `E2`/`A3` or duplicate `E1` as still pending the second distinct slot.

## MEDIUM

1. `phase3-binary/Sources/macprovider-cli/ProviderEarningsClient.swift:298`
   Issue: The unavailable-wallet reconstruction drops the four new trust-detail fields (`economicCriteria`, `additionalCriteria`, `verifiedReceiptCount`, `appAttested`) by relying on initializer defaults, while preserving the older aggregate fields such as `trustCriteriaMet` and `trustCriteriaRequired`.
   Concrete failure scenario: a prior/merged summary has `trustCriteriaMet == 1`, `trustCriteriaRequired == 2`, `economicCriteria == ["E1"]`, and `verifiedReceiptCount == 137`. A later wallet-status schema-drift cycle calls `markingWalletStatusUnavailable()`, which keeps the aggregate count but emits empty criteria arrays and nil counters. The app can then show "1 of 2 criteria met" while both named criteria rows appear pending.
   Fix: Forward the four new fields through `markingWalletStatusUnavailable()` when preserving the rest of the summary, or explicitly mark the entire trust-detail projection unavailable so the app does not mix stale aggregate counts with erased granular fields. Cover this merge path in `ProviderEarningsClientTests`.

## LOW

1. `phase3-binary/app/Sources/Malibu/Dashboard/DashboardWindow.swift:511`
   Issue: `miningTone(_:)` is now dead code. The status card switched to `phaseTone(_:)`, and `rg "miningTone\\("` finds only the function declaration.
   Concrete failure scenario: none user-facing today, but the dead mapping still encodes old alarm-color decisions for reason codes and can mislead the next dashboard change into reusing stale logic.
   Fix: Delete `miningTone(_:)` or rewire it intentionally if reason-code coloring is still needed.

## INFO

1. Test adequacy: The added tests cover the happy-path warming-up copy, a concrete held verdict, legacy app decode defaults, and direct JSON encoding of the new fields. They do not cover the wallet-status unavailable/schema-drift merge path, the complete control-socket envelope preserving the four new fields, or overlapping SPEC-026 criteria (`E1` duplicated across economic/additional, `E2`/`A3` overlap). Those gaps leave both blocking defects above unpinned.

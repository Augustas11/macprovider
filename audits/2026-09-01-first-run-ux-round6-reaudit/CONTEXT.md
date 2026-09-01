RE-AUDIT (round 6) of issue #1312 first-run dashboard P0-P3 status model, AFTER applying round-5 fixes.
Branch fix/first-run-provider-ux, two commits on origin/main. Full fix diff: audits/2026-09-01-first-run-ux-round6-reaudit/full-fix.diff (= git diff origin/main..HEAD).

Round-5 findings that were FIXED (verify they are correctly resolved and introduced no new defects):
- H1 (MalibuAgent.swift stub branch): a legacy all-zero stub metrics frame now sets malibuProjectionFresh=false, providerEarningsFresh=false, clears rewardTelemetryUnavailable before its early return, so stale Trusted-withdrawable state is not preserved.
- H2 (authoritativeBlockingRewardHealth): held_epoch_disposition now returns rewards_held before raw tier/amount logic (SPEC-021 precedence).
- Sec-M1 (trustUnlockSummary): eligibility-aware; a capped/held Trusted provider no longer reads "withdrawals are unlocked".
- Sec-M2 (miningHealth trusted_withdrawable branch): gated on displayRewardEligibility().withdrawalState == "withdrawable" (displayRewardEligibility exempts leftover-provisional holds).
- Sec-M3 (criterionName): unknown IDs render as "additional requirement", never raw.
- Arch-M1 (consolidatedStatus): .settingUp reserved for genuine initial states; isTemporarilyNotBuyerServing interruptions read .needsAttention.
- Arch-M2/Code-M1 (consolidatedStatus first gate + diagnostic override): a nonblocking .repairProviderSoftware CTA on a network-ready provider no longer forces .needsAttention; an action-less diagnostic that owns the status (update-in-progress) is surfaced (.live/neutral) instead of being overwritten by the earning display.

Carried LOW (documented, not fixed): MiningHealth.reasonCode string contract (enum suggestion); menu status not routed through consolidatedStatus (dashboard-only scope).

The #1199 repair fence must remain intact (canRepairProviderSoftware / ProviderSoftwareRepairCapabilityGate unchanged). Money-path honesty and redaction are the sensitivity.

Validation: Malibu app xcodebuild test = 534 tests, 0 failures (8 new regression tests included).

Report findings by severity (CRITICAL/HIGH/MEDIUM/LOW/INFO). Merge bar is 0 C/0 H/0 M. Focus on whether the fixes are correct and whether they introduced any NEW defect. If nothing at C/H/M, say so explicitly.

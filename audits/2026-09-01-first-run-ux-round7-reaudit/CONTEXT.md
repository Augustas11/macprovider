RE-AUDIT (round 7) of issue #1312 first-run dashboard P0-P3 status model, AFTER round-5 and round-6 fixes.
Branch fix/first-run-provider-ux, three commits on origin/main. Full fix diff: audits/2026-09-01-first-run-ux-round7-reaudit/full-fix.diff (= git diff origin/main..HEAD).

Round-6 findings FIXED in this diff (verify correct + no new defects):
- HIGH (stale amounts): hasMiningEarningsActivity now guards `s.providerEarningsFresh` before treating amount fields as earning activity.
- M(a) (accrual-only): the earnings-unavailable early branch now also requires `!s.malibuProjectionFresh`, so a fresh MALIBU verdict is honored via authoritativeBlockingRewardHealth / the malibuProjectionFresh block regardless of earnings-projection freshness.
- M(b) (diagnostic severity): consolidatedStatus now uses primaryDiagnosticFinding(s) + signatureID to classify — a benign .autoupdateInProgress reads .live/neutral; any other surfaced primary diagnostic (incl. action-less ones like credentialStoreUnavailable without a repair path) reads .needsAttention. Replaces the earlier executableAction==nil proxy.
- M(c): malibuHoldLine trust action uses distinctPairProgress (SPEC-026 §5.2), consistent with trustLine.

Prior round-5 fixes still in the diff: H1 (legacy stub demotes freshness), H2 (held_epoch_disposition precedence), trustUnlockSummary eligibility-aware, trusted_withdrawable gated on displayRewardEligibility, criterionName redaction, .settingUp reserved for genuine initial states (isTemporarilyNotBuyerServing interruptions -> .needsAttention), nonblocking repair CTA on ready not demoted.

The #1199 repair fence must remain intact (canRepairProviderSoftware / ProviderSoftwareRepairCapabilityGate unchanged). Money-path honesty + redaction are the sensitivity.

Validation: Malibu app xcodebuild test = 538 tests, 0 failures (12 new regression tests).

Report findings by severity (C/H/M/L/I). Merge bar is 0 C/0 H/0 M. Focus on whether the fixes are correct and introduced no NEW defect. Distinguish issues NEWLY introduced by this diff from any that are pre-existing in files this diff happens to touch. If nothing at C/H/M, say so explicitly.

# Revoked-build downgrade audit — R6 (VERIFICATION ONLY), ARCHITECTURE lane

Repository: current working directory, branch `cli/revoked-build-downgrade`
(head 25ac0293f). Do not edit files. Do not run network commands.

Verification of the R5 fix only. Fix diff: `audits/2026-10-10-revoked-build-downgrade/R6_FIX.diff`
(`git diff b647fe97a 25ac0293f`). No discovery sweep; report nothing outside
these items and the changed lines.

## Items to verify (from R5)

R5-M1 (Code lane, MEDIUM): removing the post-drain authorization check
(`AutoUpdater.swift` `ensureEligible(phase: .backup, downgrade:...)`) left
`testRevokedBuildDowngradeAbortsWhenAuthorizationIsWithdrawnDuringDrain`
passing, because the later activation gate refused with the same reason.
Fix: the test now also requires the refusal event's phase to be
`eligibility` with failure_class `trust_state_lost` (the activation-gate
refusal records phase `swap`). A local mutation run (post-drain check
removed) fails the test with phase "swap" != "eligibility".

R5-L1 (all lanes, LOW): the pending-marker assertion was vacuous because the
helper's TempHome was deleted on return. Fix: the helper reads the pending
marker before returning; the drain test asserts none, the post-eviction test
asserts the restored revoked build awaits readiness
(`awaiting_previous_readiness`, previous version 1.8.233).

R5-L2 (Code lane, LOW): the tampered-metadata ops test appended invalid
JSON, so parsing alone refused it. Fix: it now rewrites a field as valid JSON
and keeps the original signature, so only signature verification refuses.

## Output

One line per item: `ID — FIXED|PARTIAL|NOT FIXED — evidence (file:line)`,
then any regression in the changed lines as `SEVERITY — file:line — problem
— fix`. End with exactly one line: `VERDICT: C=<n> H=<n> M=<n> L=<n>`
counting only unfixed items and regressions in the changed lines.

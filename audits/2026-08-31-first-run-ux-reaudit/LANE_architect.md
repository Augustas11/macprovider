# Audit lane: ARCHITECTURE / UX-COHERENCE — Malibu first-run provider UX

Independent architecture auditor. Review the COMPLETE diff for design coherence,
completeness of the state model, and maintainability. Do not assume correct.

## What to review
Full diff (read first): `audits/2026-08-31-first-run-ux-reaudit/full-fix.diff`
Then `AgentSnapshot.swift`, `Dashboard/DashboardWindow.swift`, `EarningsClient.swift`,
`MalibuAgent.swift`, `ProviderEarningsClient.swift`.

## Context
Consolidates 4 previously-disagreeing status surfaces (header subtitle, Mining
Health panel, "Current state" card, trust line) into ONE authoritative
three-state model: Setting up / Live·Provisional / Earning·Trusted, plus a
needsAttention fallback. Adds trust-criteria disclosure, a "How earning works"
explainer, collapses recovery + advanced diagnostics.

## Questions
1. **State-model completeness.** Does `consolidatedStatus` cover EVERY reachable
   AgentSnapshot state (setting up, admitted-provisional, trusted, no-wallet,
   warming-up, genuine outage, fault, local-block/battery, quarantine, stopped)?
   Any state that falls through to an empty or wrong card, or lacks a next action?
   Is there exactly ONE next action per state (the stated goal)?
2. **Single source of truth.** After consolidation, is status computed in one
   place, or do header/card/tone still derive it independently and risk
   re-diverging? Are miningTone/phaseTone consistent with consolidatedStatus?
3. **Wire-contract placement.** Adding 4 fields to the provider_earnings frame to
   drive UI — is the control-socket frame the right layer, or should the app
   fetch trust criteria from its own coordinator endpoint? Does this coupling
   bloat a money-adjacent relay for a display concern? Judge the tradeoff.
4. **Duplication / drift risk.** New copy/logic vs existing ReferralProjection
   disclosure pattern — reused well or duplicated? Any two functions that must
   stay in sync but could drift (e.g. tone mapping vs reason codes)?
5. **Deferred items acceptable?** No granular uptime countdown (TODO); "additional"
   criterion always labeled "Time online". Are these safe as documented
   follow-ups, or do they leave a confusing/incorrect UI in a common state?
6. **Blast radius.** Does the consolidation remove/alter any surface other views,
   tests, or menu-bar code depend on?

## Output
Per finding: SEVERITY, file:line, design risk, recommended direction. End with
`GATE: PASS` (0 C/H/M) or `GATE: FAIL`.

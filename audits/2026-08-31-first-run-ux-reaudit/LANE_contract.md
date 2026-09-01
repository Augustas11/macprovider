# Audit lane: CONTRACT / TRUST-INTEGRITY — Malibu first-run provider UX

Independent auditor for the shared control-socket contract change and for any
risk of misrepresenting earnings/trust to the provider. Review the COMPLETE diff.

## What to review
Full diff (read first): `audits/2026-08-31-first-run-ux-reaudit/full-fix.diff`
Then:
- `phase3-binary/Sources/macprovider-cli/ProviderEarningsClient.swift` and the `provider_earnings` control-socket frame definition/producers it feeds
- `phase3-binary/app/Sources/Malibu/Agent/EarningsClient.swift`, `MalibuAgent.swift`, `AgentSnapshot.swift`
- `phase4-coordinator/internal/rewards/endpoints.go` + `unlock_types.go` (the authoritative source of economic_criteria/additional_criteria/verified_receipt_count/wallet_bound/app_attested per SPEC-026)
- `specs/SPEC-026*` (trust-tier / unlock criteria) for the normative meaning of Provisional/Trusted and the criterion IDs

## Focus
1. **Contract compatibility both directions.** The `provider_earnings` frame gains 4 optional fields (economicCriteria, additionalCriteria, verifiedReceiptCount, appAttested). Sweep BOTH sides (CLI producer + app consumer) and every merge/reconstruct path: an old CLI ↔ new app and new CLI ↔ old app must both work. No required-field assumption, no crash, no silent drop that changes displayed trust state. Confirm the frame is not consumed anywhere else (coordinator, logs, tests) that would break.
2. **No money/settlement logic touched.** Confirm this is display/relay only — nothing in billing/settlement/quota/payout changed. The frame relays already-computed values; verify it does not become a new source of truth for any money decision.
3. **Trust-label integrity (SPEC-026).** The UI now renders criteria "by name" and states what Trusted unlocks. Verify: (a) no normative tier label changed; (b) the app cannot show a provider as meeting a criterion it hasn't (map criterion IDs to names faithfully — the implementer labels the "additional" row "Time online" for the A1/uptime path but A3/A4 can also satisfy it; assess whether that can MISLEAD a provider about why they are/aren't Trusted); (c) "Reaching Trusted unlocks MALIBU reward withdrawals; USDC unaffected" is factually correct per spec.
4. **Calm-vs-alarm cannot hide a real fault.** The reason-code split makes warming-up/no-wallet calm. Confirm a genuine outage, not-admitted, quarantine, or fault state is NOT recolored calm — a provider must still see real problems. Check consolidatedStatus's needsAttention fallback covers fault/local-block/quarantine states.
5. **No sensitive data newly exposed** in the frame or logs (tokens, addresses).

## Output
Per finding: SEVERITY, file:line, concrete scenario, remediation. State explicitly whether any SPEC-026 normative change is needed (should be none). End with `GATE: PASS` (0 C/H/M) or `GATE: FAIL`.

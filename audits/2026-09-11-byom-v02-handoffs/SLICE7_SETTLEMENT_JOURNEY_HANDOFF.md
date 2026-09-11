# BYOM v0.2 slice 7 — real settlement journey on hardware (handoff)

**Epic:** #1453 (BYOM v0.2). **Owner (capture):** Steven (@SmtTheSE). **Operator (signing):** @Augustas11.
**Kind:** end-to-end journey on real Apple Silicon — capture is delegable; operator signing is not.

## Goal
Drive one candidate the whole way to `settlement_capable` on real hardware, CAPTURE
`JOURNEY-NETWORK-MODEL-ADMISSION`, then (operator) sign it; promote SPEC-047-R001..R008;
cut a release per `docs/runbooks/provider-cli-release-verification.md`.

## Split of duties
- **Steven (@SmtTheSE) — capture half (this handoff).** Run the full candidate stack
  LOCALLY on real hardware (as with the prior candidate stacks, #1346), drive a candidate
  through discover → offer → offer-time catalog match → operator decision → route →
  settlement, and capture the journey run manifest + evidence. redastare canary Mac is
  available (see the operator for `~/.ssh/redastare_canary_ed25519`). The Pearl isolated
  test coordinator is torn down; run local.
- **Operator (@Augustas11) — signing, not delegable.** The `settlement_capable` decision
  is dual-control operator credentials, and the operator signs
  `JOURNEY-NETWORK-MODEL-ADMISSION`. These use operator keys and stay with the operator.

## Frozen inputs (already merged)
- Decision path + admission states — SPEC-047-R001 (slice 4).
- Catalog identity, offer-time match — SPEC-010 v1.7/v1.8, SPEC-023 (slices 2–4).
- Intake evidence — SPEC-017 v0.2.1 / SPEC-047 v0.1.6 / SPEC-023 v0.10.4 (slice 5).

## Constraints
- **GGUF cannot reach `settlement_capable` until SPEC-010 R007(e).** Pick a candidate
  whose runtime path can actually settle, or capture the GGUF stop-at-`network_visible_unpriced`
  case explicitly and flag it.
- Release-asset proof per the runbook: SHA-256 BYTE identity between both embedded
  `macprovider-cli` binaries after final signing/notarization/stapling/packaging; verify
  the updater path from the previous stable; never `codesign --force --deep`; never patch
  an immutable public release in place.

## Deliverables
1. Captured journey artifacts (run manifest + captures) for one `settlement_capable` case.
2. Operator-signed `JOURNEY-NETWORK-MODEL-ADMISSION` (operator step).
3. Promotion of SPEC-047-R001..R008, gated on the signed journey.
4. Release cut verified per `docs/runbooks/provider-cli-release-verification.md`.

## Acceptance
- One `settlement_capable` case captured end-to-end on real hardware with a signed journey.
- SPEC-047 R001–R008 promotable from the captured evidence.
- Release-asset byte-identity proof recorded.

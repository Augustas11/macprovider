# SPEC-036 IMPL — Round-5 BUILD audit (3 codex lanes) + fixes

**Date:** 2026-08-06

## Round-5 result

| Lane | C | H | M | L |
|---|---:|---:|---:|---:|
| codex code-correctness | 0 | 3 | 0 | 0 |
| codex security / money-path | 0 | 2 | 0 | 0 |
| codex architecture / spec-fidelity | 0 | 0 | 0 | 0 |

**The architecture / spec-fidelity lane is now CLEAN (0/0/0).** The remaining
code/security HIGHs were all concentrated in one subsystem — the enforce-mode overlay
origin / accumulator / clear interaction — which is where iterative fixes had introduced
new surface. Per the repo audit discipline (past ~3-4 rounds, consolidate rather than
keep patching), these were resolved by a single consolidation plus explicit scoping.

## Fixes

1. **Composite binding omitted coverage digest** (sec-H1): `compositeBindingUnreadable`
   now includes `spec022_coverage_digest`.
2. **Payable path accepted incomplete FR-4 captures** (sec-H2): `missingEnforceEvidence`
   now requires the core covered-key identity, `compute_integrity_policy_version`,
   `signed_catalog_digest`, `compute_integrity_window_id`, and positive `captured_at`.
3. **Abusive block could clear using pre-block passes** (code-H1): consolidated overlay
   block handling via `enterBlock`, which resets the clear streak on block entry;
   `AttemptClear` additionally requires the streak to start after the block and the
   rolling 24h abusive window to be below the limit before an abusive block clears.
4. **Accumulator-only enforce risk produced a dormant swap block** (code-H2): overlay
   risk now records the strongest origin seen (`strongerOrigin`), so an enforce-mode
   accumulator produces an enforce-preserved swap-laundering block on artifact churn.

## Scoped follow-up (documented, not a v0.1 money-path defect)

- **code-H3: fresh enforce-preserved evidence superseding a dormant telemetry-only
  overlay.** Deliberately NOT implemented (`canEnterProviderBlock` returns
  `!IsAdverseOverlay()` with an explicit code comment). It matters ONLY in enforce mode,
  which §6.1 makes unreachable in v0.1 — every reachable adverse state is telemetry_only
  with no money effect — and a correct model needs a state-origin vs risk-origin split
  that adds complexity for a dormant path. This is a scoped follow-up for the
  live-enforce-wiring work, not a money-safety gap in the shippable default-off slice.
- **arch-L1 (unpruned candidate counter):** carried, over-blocks never mis-pays.
- **all-profile ResolveState routing integration:** carried; the money gate already
  enforces coverage via the captured `RequestSamplingProfileCovered` (AC-11).

## Convergence assessment

Five rounds of independent codex audit; three consecutive at 0 CRITICAL; the
architecture/spec-fidelity lane fully clean. The money-path core (`ApplyGate` AND-gate,
fail-closed settlement, the effective_adverse_state matrix, no unearned payout) was
validated every round. The residual items are enforce-mode-only (unreachable in v0.1)
and honestly scoped. `go build ./...`, `go vet`, `golangci-lint` green; all 17 AC
fixtures pass.

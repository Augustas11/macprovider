# Audit: ISS-165 R3 code lens — verify R2 fixes

R2 returned 0/3/2/1. R3 verifies on commit `f0c5350` against HEAD
of `spec/iss-165-spec-016-followups`. Tree: `git log --oneline -5`.

## R2 findings to verify

- **CODE/SEC HIGH (convergent)**: scan cap saturation prefix-
  starvation. Fix: drop `staleOutboxScanCap` ceiling entirely;
  scan now bounded only by predicate.
- **ARCH HIGH**: `dist/payout-runbook.md` BetterStack synthetic-
  alert list missing new v0.1.22 events. Fix: extended.
- **ARCH MED-1**: SPEC v0.1.22 prose vs code semantics mismatch.
  Fix: reconciled.
- **ARCH MED-2**: SPKI close-idle interface contract optional/
  silent. Fix: `payout_spki_drain_skipped_unsupported_client` WARN
  fires when an RPC client lacks `CloseIdleConnections`.
- **ARCH LOW**: per-cycle WARN repeat not documented. Fix: SPEC
  text + code comments now say so.

## Files to re-inspect

- `phase4-coordinator/internal/payout/orphans.go`
- `phase4-coordinator/internal/payout/chronic.go`
- `phase4-coordinator/cmd/coordinator/main.go`
- `phase4-coordinator/dist/payout-runbook.md`
- `specs/SPEC-016-payout-pipeline.md`
- `phase4-coordinator/internal/payout/iss165_a1_test.go`

## What I want (R3 code lens)

Verify the closures stuck. Specifically:

- Without the scan cap, does the SELECT have any *implicit*
  ceiling (SQLite default LIMIT, Go driver row buffer)? Confirm
  the entire candidate set is materialized.
- Does any code path still reference `staleOutboxScanCap` /
  `scan_cap_hit` (dead refs)?
- Test coverage adequate? With the cap removed, is the regression
  class still pinned?
- Memory concern: do we have a coarse upper bound for the
  candidate set in production? (If yes, document; if no, the LOW
  in R2 about per-cycle repeat may be insufficient.)

Find NEW code defects. Same severity + output format. End with
`## Convergence X/X/X/X → DECISION`.

# Audit: ISS-165 R3 architect lens — verify R2 fixes

R2 returned 1 HIGH + 2 MEDIUM + 1 LOW (arch). R3 verifies on
commit `f0c5350`. Tree: `spec/iss-165-spec-016-followups`.

## R2 ARCH findings to verify

- **HIGH**: runbook missing new events. Fix: extended.
- **MED-1**: SPEC v0.1.22 prose vs code mismatch. Fix: reconciled.
- **MED-2**: SPKI close-idle interface contract optional/silent.
  Fix: new WARN event + comment update.
- **LOW**: per-cycle WARN repeat documented now.

## What I want (R3 arch lens)

- Does the new `payout_spki_drain_skipped_unsupported_client`
  WARN deserve a §7.1 row + §9 alert filter entry? It's not in
  either; if it's an internal observability event that's fine,
  but the convention in SPEC-016 has been that any non-trivial
  event hits §7.1.
- Does the SPEC v0.1.22 change-log paragraph fully describe the
  R2 fix (scan-cap removal)? The R1+R2 audit narrative
  retroactively makes this a 2-round closure on what was
  originally a "LOW deferred from #164" — does the SPEC body
  still claim this is a simple LIMIT polish, or has the audit
  arc been recorded?
- Does the runbook §3 update normatively cover BOTH primary and
  secondary RPC labels for the new SPKI drain WARN? It's a
  per-label event so the synthetic-alert harness needs to verify
  each.
- Cross-spec: does SPEC-007 (explorer) or any other SPEC
  reference §7.1 events that would need the new WARN/PAGE
  visible? (Likely not, but check.)

Find NEW arch defects. Same severity + output format. End with
`## Convergence X/X/X/X → DECISION`.
